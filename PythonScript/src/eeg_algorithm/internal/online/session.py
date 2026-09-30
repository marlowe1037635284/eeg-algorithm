from __future__ import annotations

import logging
import time
from threading import RLock

import numpy as np

from eeg_algorithm.errors import (
    INVALID_ARGUMENT,
    INVALID_STATE,
    TIME_SEQUENCE_DISCONTINUITY,
    AlgorithmErrorInfo,
    algorithm_error,
)
from eeg_algorithm.types import (
    ConfigUpdateResult,
    GapInfo,
    OnlineConfig,
    OnlineProcessingConfig,
    OnlineResult,
    QualityFlag,
    SampleFrame,
    SessionState,
    SessionStatus,
    SignalBlock,
    SpectrumQuery,
    SpectrumResult,
    TopographyQuery,
    TopographyResult,
)

from eeg_algorithm.internal.observability.context import get_logger, log_event
from eeg_algorithm.internal.observability.performance import PerformanceAggregator
from eeg_algorithm.internal.validation import validate_block, validate_frame, validate_layout

from .asr import OnlineAsrProcessor
from .filter_chain import OnlineFilterChain
from .phase_decoder import PhaseDecoder
from .rereference import ReReferencer
from .rolling_buffer import RollingSignalBuffer
from .spectrum import compute_online_spectrum
from .topography import compute_online_topography


class OnlineSession:
    def __init__(self, session_id: int, config: OnlineConfig) -> None:
        self._validate_config(config)
        self._id = session_id
        self._config = config
        self._filter = OnlineFilterChain(config.processing, config.layout.sample_rate_hz, len(config.layout.channel_names))
        self._reference = ReReferencer(config.reference, config.layout)
        self._asr = OnlineAsrProcessor(config.asr, config.layout)
        self._asr.set_enabled(config.processing.asr_enabled)
        self._phase = PhaseDecoder(config.phase, config.layout)
        self._buffer = RollingSignalBuffer(config.layout, config.rolling_window_s)
        self._buffer.clear(config.processing.config_version)
        self._state = SessionState.WARMING_UP if config.phase.enabled else SessionState.CREATED
        self._last_sequence_id: int | None = None
        self._last_timestamp_ns: int | None = None
        self._durations_us: list[int] = []
        self._gap_count = 0
        self._timeout_count = 0
        self._last_error: AlgorithmErrorInfo | None = None
        self._lock = RLock()
        self._logger = get_logger(__name__)
        self._performance = PerformanceAggregator()
        log_event(self._logger, logging.INFO, "在线会话创建", code="ONLINE_SESSION_CREATED", session_id=self._id)

    def set_asr_reference(self, reference: SignalBlock) -> None:
        with self._lock:
            self._ensure_open("set_asr_reference")
            validate_block(reference, len(self._config.layout.channel_names), "set_asr_reference")
            duration_s = reference.values.shape[1] / self._config.layout.sample_rate_hz
            if duration_s < 60.0 or duration_s > 180.0:
                raise algorithm_error(
                    INVALID_ARGUMENT,
                    "ASR参考数据时长必须为60到180秒",
                    "set_asr_reference",
                    session_id=self._id,
                )
            fresh_filter = OnlineFilterChain(
                self._config.processing,
                self._config.layout.sample_rate_hz,
                len(self._config.layout.channel_names),
            )
            processed = self._reference.process_block(fresh_filter.process_block(reference.values))
            self._asr.fit_processed_reference(reference, processed)
            log_event(
                self._logger,
                logging.INFO,
                "在线ASR参考数据已设置",
                code="ASR_REFERENCE_SET",
                operation="set_asr_reference",
                session_id=self._id,
            )

    def update_processing_config(self, config: OnlineProcessingConfig) -> ConfigUpdateResult:
        with self._lock:
            self._ensure_open("update_processing_config")
            if config.config_version <= self._config.processing.config_version:
                raise algorithm_error(INVALID_ARGUMENT, "新配置版本必须大于当前版本", "update_processing_config")
            old = self._config.processing
            self._filter.reconfigure(config)
            self._asr.set_enabled(config.asr_enabled)
            asr_refit_required = False
            filters_changed = (old.high_pass, old.low_pass, old.notch) != (
                config.high_pass,
                config.low_pass,
                config.notch,
            )
            if filters_changed and self._asr.original_reference is not None:
                reference = self._asr.original_reference
                fresh_filter = OnlineFilterChain(config, self._config.layout.sample_rate_hz, len(self._config.layout.channel_names))
                processed = self._reference.process_block(fresh_filter.process_block(reference.values))
                self._asr.fit_processed_reference(reference, processed)
            elif filters_changed and config.asr_enabled:
                asr_refit_required = True
            self._config = OnlineConfig(
                layout=self._config.layout,
                processing=config,
                reference=self._config.reference,
                asr=self._config.asr,
                phase=self._config.phase,
                rolling_window_s=self._config.rolling_window_s,
                return_processed_signal=self._config.return_processed_signal,
            )
            effective = 0 if self._last_sequence_id is None else self._last_sequence_id + 1
            self._reset_stream_state(config.config_version)
            log_event(
                self._logger,
                logging.INFO,
                "在线处理配置更新",
                code="ONLINE_CONFIG_UPDATED",
                operation="update_processing_config",
                session_id=self._id,
                sequence_id=effective,
                config_version=config.config_version,
            )
            return ConfigUpdateResult(config.config_version, effective, True, asr_refit_required, True)

    def push_sample(self, frame: SampleFrame) -> OnlineResult:
        validate_frame(frame, len(self._config.layout.channel_names), "push_sample")
        block = SignalBlock(
            frame.sequence_id,
            np.ascontiguousarray([frame.timestamp_ns], dtype=np.int64),
            np.ascontiguousarray(frame.values[:, None], dtype=np.float32),
        )
        return self.push_block(block)

    def push_block(self, block: SignalBlock) -> OnlineResult:
        with self._lock:
            self._ensure_open("push_block")
            validate_block(block, len(self._config.layout.channel_names), "push_block")
            self._validate_continuity(block)
            if self._config.processing.asr_enabled and not self._asr.has_reference:
                from eeg_algorithm.errors import ASR_REFERENCE_REQUIRED

                raise algorithm_error(
                    ASR_REFERENCE_REQUIRED,
                    "ASR已启用但尚未设置参考数据",
                    "push_block",
                    session_id=self._id,
                    sequence_id=block.first_sequence_id,
                )
            started = time.perf_counter_ns()
            try:
                filtered = self._filter.process_block(block.values)
                referenced = self._reference.process_block(filtered)
                cleaned = self._asr.process_block(referenced)
                processed = SignalBlock(block.first_sequence_id, block.timestamps_ns, cleaned)
                phase_results = self._phase.update_block(
                    cleaned, block.first_sequence_id, block.timestamps_ns
                )
                self._buffer.append(processed, self._config.processing.config_version)
            except Exception:
                log_event(
                    self._logger,
                    logging.ERROR,
                    "在线数据处理失败",
                    code="ONLINE_PROCESSING_FAILED",
                    operation="push_block",
                    session_id=self._id,
                    sequence_id=block.first_sequence_id,
                    exc_info=True,
                )
                raise
            duration_us = (time.perf_counter_ns() - started) // 1000
            last_sequence = block.first_sequence_id + block.values.shape[1] - 1
            self._last_sequence_id = last_sequence
            self._last_timestamp_ns = int(block.timestamps_ns[-1])
            self._durations_us.append(int(duration_us))
            self._performance.record("push_block", int(duration_us), session_id=self._id)
            warmup = self._phase.warmup_remaining_samples
            self._state = SessionState.WARMING_UP if warmup else SessionState.RUNNING
            flags = (QualityFlag.WARMING_UP,) if warmup else (QualityFlag.OK,)
            return OnlineResult(
                config_version=self._config.processing.config_version,
                first_sequence_id=block.first_sequence_id,
                last_sequence_id=last_sequence,
                processed_signal=processed if self._config.return_processed_signal else None,
                phase_results=phase_results,
                quality_flags=flags,
                processing_time_us=int(duration_us),
            )

    def notify_gap(self, gap: GapInfo) -> None:
        with self._lock:
            self._ensure_open("notify_gap")
            if gap.first_missing_sequence_id > gap.last_missing_sequence_id:
                raise algorithm_error(INVALID_ARGUMENT, "数据缺口序列范围非法", "notify_gap")
            self._gap_count += 1
            self._reset_stream_state(self._config.processing.config_version)
            self._last_sequence_id = gap.last_missing_sequence_id
            self._last_timestamp_ns = gap.end_timestamp_ns
            self._state = SessionState.WARMING_UP
            log_event(
                self._logger,
                logging.WARNING,
                f"检测到数据缺口: {gap.reason}",
                code="TIME_SEQUENCE_DISCONTINUITY",
                operation="notify_gap",
                session_id=self._id,
                sequence_id=gap.first_missing_sequence_id,
            )

    def query_topography(self, query: TopographyQuery) -> TopographyResult:
        with self._lock:
            self._ensure_open("query_topography")
            snapshot = self._buffer.snapshot_multichannel(
                query.window_s, query.time_range, self._config.processing.config_version
            )
            return compute_online_topography(snapshot, self._config.layout, query, self._config.processing.config_version)

    def query_spectrum(self, query: SpectrumQuery) -> SpectrumResult:
        with self._lock:
            self._ensure_open("query_spectrum")
            snapshot = self._buffer.snapshot_channel(
                query.channel_name, query.window_s, self._config.processing.config_version
            )
            return compute_online_spectrum(snapshot, self._config.layout, query, self._config.processing.config_version)

    def reset(self) -> None:
        with self._lock:
            self._ensure_open("reset")
            self._reset_stream_state(self._config.processing.config_version)
            self._last_sequence_id = None
            self._last_timestamp_ns = None
            self._state = SessionState.WARMING_UP if self._config.phase.enabled else SessionState.CREATED
            log_event(self._logger, logging.INFO, "在线会话已重置", code="ONLINE_SESSION_RESET", session_id=self._id)

    def status(self) -> SessionStatus:
        with self._lock:
            durations = np.asarray(self._durations_us, dtype=np.float64)
            return SessionStatus(
                state=self._state,
                config_version=self._config.processing.config_version,
                last_processed_sequence_id=self._last_sequence_id,
                average_processing_time_us=float(durations.mean()) if durations.size else 0.0,
                p99_processing_time_us=float(np.percentile(durations, 99)) if durations.size else 0.0,
                max_processing_time_us=int(durations.max()) if durations.size else 0,
                gap_count=self._gap_count,
                timeout_count=self._timeout_count,
                warmup_remaining_samples=self._phase.warmup_remaining_samples,
                rolling_buffer_duration_s=self._buffer.available_duration_s(),
                last_error=self._last_error,
            )

    def close(self) -> None:
        with self._lock:
            if self._state is SessionState.CLOSED:
                return
            self._phase.close()
            self._buffer.clear(self._config.processing.config_version)
            self._state = SessionState.CLOSED
            log_event(self._logger, logging.INFO, "在线会话关闭", code="ONLINE_SESSION_CLOSED", session_id=self._id)

    def _reset_stream_state(self, config_version: int) -> None:
        self._filter.reset()
        self._asr.reset_stream_state()
        self._phase.reset()
        self._buffer.clear(config_version)

    def _validate_continuity(self, block: SignalBlock) -> None:
        if self._last_sequence_id is not None and block.first_sequence_id != self._last_sequence_id + 1:
            raise algorithm_error(
                TIME_SEQUENCE_DISCONTINUITY,
                "序列号不连续，请先调用notify_gap",
                "push_block",
                session_id=self._id,
                sequence_id=block.first_sequence_id,
            )
        if self._last_timestamp_ns is not None and int(block.timestamps_ns[0]) <= self._last_timestamp_ns:
            raise algorithm_error(
                TIME_SEQUENCE_DISCONTINUITY,
                "时间戳重复或倒退",
                "push_block",
                session_id=self._id,
                sequence_id=block.first_sequence_id,
            )

    def _ensure_open(self, operation: str) -> None:
        if self._state is SessionState.CLOSED:
            raise algorithm_error(INVALID_STATE, "在线会话已经关闭", operation, session_id=self._id)

    @staticmethod
    def _validate_config(config: OnlineConfig) -> None:
        validate_layout(config.layout, "create_online_session")
        if config.rolling_window_s <= 0:
            raise algorithm_error(INVALID_ARGUMENT, "rolling_window_s必须大于0", "create_online_session")
        if config.processing.asr_enabled:
            if config.asr.window_s is None or config.asr.window_s <= 0:
                raise algorithm_error(INVALID_ARGUMENT, "启用ASR时window_s必须大于0", "create_online_session")
            if config.asr.overlap_ratio is None or not 0 <= config.asr.overlap_ratio < 1:
                raise algorithm_error(INVALID_ARGUMENT, "启用ASR时overlap_ratio必须在[0,1)内", "create_online_session")
