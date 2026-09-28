"""在线会话：校验、编排在线流水线、序列连续性与状态原子提交。"""

from __future__ import annotations

import time

import numpy as np

from eeg_algorithm.errors import AlgorithmError, AlgorithmErrorInfo, ErrorCode, error
from eeg_algorithm.internal.online.asr import OnlineAsrProcessor
from eeg_algorithm.internal.online.filter_chain import OnlineFilterChain
from eeg_algorithm.internal.online.phase_decoder import PhaseDecoder
from eeg_algorithm.internal.online.rereference import ReReferencer
from eeg_algorithm.internal.online.rolling_buffer import RollingSignalBuffer
from eeg_algorithm.internal.online.spectrum import SpectrumAnalyzer
from eeg_algorithm.internal.online.topography import TopographyAnalyzer
from eeg_algorithm.internal.observability import get_logger, record_performance
from eeg_algorithm.internal.validation import (
    validate_channel_layout,
    validate_channel_name,
    validate_values,
)
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, GapInfo, SampleFrame, SignalBlock
from eeg_algorithm.types.enums import QualityFlag, SessionState
from eeg_algorithm.types.online import (
    ConfigUpdateResult,
    OnlineConfig,
    OnlineProcessingConfig,
    OnlineResult,
    PhaseResult,
    SessionStatus,
    SpectrumQuery,
    SpectrumResult,
    TopographyQuery,
    TopographyResult,
)

_WARMUP_SAMPLES = 8

_log = get_logger("online.session")


class OnlineSession:
    def __init__(self, config: OnlineConfig) -> None:
        validate_channel_layout(config.layout)
        if config.processing.config_version <= 0:
            raise error(ErrorCode.INVALID_ARGUMENT, "config_version 必须大于 0", "create_online_session")
        if config.rolling_window_s <= 0:
            raise error(ErrorCode.INVALID_ARGUMENT, "rolling_window_s 必须大于 0", "create_online_session")

        self._config = config
        self._layout: ChannelLayout = config.layout
        self._config_version = config.processing.config_version
        self._channel_count = len(config.layout.channel_names)
        self._fs = config.layout.sample_rate_hz

        self._filter_chain = OnlineFilterChain(
            config.processing, self._fs, self._channel_count
        )
        self._rereferencer = ReReferencer(config.reference, self._layout)
        self._asr = OnlineAsrProcessor(config.asr, self._layout)
        self._asr.set_enabled(config.processing.asr_enabled)
        self._phase_decoder = PhaseDecoder(config.phase, self._layout)
        self._buffer = RollingSignalBuffer(self._layout, config.rolling_window_s)

        self._state = SessionState.WARMING_UP
        self._warmup_remaining = _WARMUP_SAMPLES
        self._last_sequence_id: int | None = None

        self._gap_count = 0
        self._timeout_count = 0
        self._total_us = 0.0
        self._max_us = 0.0
        self._us_samples: list[float] = []
        self._last_error: AlgorithmErrorInfo | None = None
        self._session_id: int | None = None

        _log.info(
            "在线会话创建",
            extra={"session_id": None, "operation": "create_online_session",
                   "config_version": self._config_version},
        )

    # ---- 数据流 ----
    def push_sample(self, frame: SampleFrame) -> OnlineResult:
        values = validate_values(np.asarray(frame.values), self._channel_count, "push_sample")
        return self._push(values, frame.sequence_id, np.array([frame.timestamp_ns], dtype=np.int64))

    def push_block(self, block: SignalBlock) -> OnlineResult:
        values = validate_values(block.values, self._channel_count, "push_block")
        n = values.shape[1]
        stamps = np.ascontiguousarray(block.timestamps_ns, dtype=np.int64)
        if stamps.shape[0] != n:
            raise error(ErrorCode.SHAPE_MISMATCH, "timestamps_ns 长度与样本数不符", "push_block")
        return self._push(values, block.first_sequence_id, stamps)

    def _push(self, values: np.ndarray, first_seq: int, stamps: np.ndarray) -> OnlineResult:
        self._ensure_operable("push")

        # 序列连续性检查
        expected = self._last_sequence_id + 1 if self._last_sequence_id is not None else None
        if expected is not None and first_seq != expected:
            self._handle_discontinuity(first_seq, stamps)

        start = time.perf_counter()
        try:
            filtered = self._filter_chain.process_block(values)
            reref = self._rereferencer.process_block(filtered)
            asr = self._asr.process_block(reref)

            if self._config.phase.enabled:
                phase_results = self._phase_decoder.update_block(asr, first_seq, stamps)
            else:
                phase_results: tuple[PhaseResult, ...] = ()

            block = SignalBlock(
                first_sequence_id=first_seq,
                timestamps_ns=stamps,
                values=np.ascontiguousarray(asr, dtype=np.float32),
            )
            self._buffer.append(block, self._config_version)
        except AlgorithmError:
            raise
        except Exception as exc:  # noqa: BLE001
            info = AlgorithmErrorInfo(
                code=ErrorCode.ALGORITHM_RUNTIME_ERROR,
                message=str(exc),
                operation="push",
                session_id=self._session_id,
                sequence_id=first_seq,
            )
            self._last_error = info
            self._state = SessionState.ERROR
            raise error(
                info.code, info.message, info.operation, info.session_id, info.sequence_id
            ) from exc

        elapsed_us = (time.perf_counter() - start) * 1e6
        self._record_timing(elapsed_us)
        record_performance("push", elapsed_us)

        n = values.shape[1]
        self._last_sequence_id = first_seq + n - 1
        self._advance_warmup(n)

        flags = self._current_flags()
        processed = block if self._config.return_processed_signal else None
        return OnlineResult(
            config_version=self._config_version,
            first_sequence_id=first_seq,
            last_sequence_id=self._last_sequence_id,
            processed_signal=processed,
            phase_results=phase_results,
            quality_flags=flags,
            processing_time_us=int(elapsed_us),
        )

    # ---- 配置 ----
    def set_asr_reference(self, reference: SignalBlock) -> None:
        self._asr.fit_reference(reference)

    def update_processing_config(self, config: OnlineProcessingConfig) -> ConfigUpdateResult:
        if config.config_version <= self._config_version:
            raise error(ErrorCode.INVALID_ARGUMENT, "新的 config_version 必须更大", "update_processing_config")
        self._filter_chain.reconfigure(config)
        self._asr.set_enabled(config.asr_enabled)
        self._buffer.clear(config.config_version)
        self._config_version = config.config_version
        self._warmup_remaining = _WARMUP_SAMPLES
        self._state = SessionState.WARMING_UP

        refit_required = config.asr_enabled and self._asr._reference_data is not None
        effective = self._last_sequence_id + 1 if self._last_sequence_id is not None else 0

        _log.info(
            "在线处理配置更新",
            extra={"operation": "update_processing_config", "config_version": config.config_version},
        )
        return ConfigUpdateResult(
            config_version=config.config_version,
            effective_sequence_id=effective,
            rolling_buffer_cleared=True,
            asr_refit_required=refit_required,
            warmup_required=True,
        )

    # ---- 缺口与重置 ----
    def notify_gap(self, gap: GapInfo) -> None:
        self._gap_count += 1
        self._filter_chain.reset()
        self._asr.reset_stream_state()
        self._phase_decoder.reset()
        self._buffer.clear(self._config_version)
        self._warmup_remaining = _WARMUP_SAMPLES
        self._state = SessionState.WARMING_UP
        _log.warning(
            "检测到在线数据缺口，流式状态已重置",
            extra={"operation": "notify_gap", "code": ErrorCode.TIME_SEQUENCE_DISCONTINUITY},
        )

    def reset(self) -> None:
        self._filter_chain.reset()
        self._asr.reset_stream_state()
        self._phase_decoder.reset()
        self._buffer.clear(self._config_version)
        self._warmup_remaining = _WARMUP_SAMPLES
        self._state = SessionState.WARMING_UP
        self._last_error = None

    # ---- 查询 ----
    def query_topography(self, query: TopographyQuery) -> TopographyResult:
        self._validate_topography_query(query)
        snapshot = self._buffer.snapshot_multichannel(
            query.window_s, query.time_range, self._config_version
        )
        return TopographyAnalyzer().compute(snapshot, self._layout, query, self._config_version)

    def query_spectrum(self, query: SpectrumQuery) -> SpectrumResult:
        validate_channel_name(self._layout, query.channel_name, "query_spectrum")
        if query.window_s <= 0:
            raise error(ErrorCode.INVALID_ARGUMENT, "window_s 必须大于 0", "query_spectrum")
        snapshot = self._buffer.snapshot_channel(
            query.channel_name, query.window_s, self._config_version
        )
        return SpectrumAnalyzer().compute(snapshot, self._layout, query, self._config_version)

    def _validate_topography_query(self, query: TopographyQuery) -> None:
        if (query.window_s is None) == (query.time_range is None):
            raise error(
                ErrorCode.INVALID_ARGUMENT,
                "window_s 与 time_range 必须且只能提供一个",
                "query_topography",
            )

    # ---- 状态 ----
    def status(self) -> SessionStatus:
        avg_us = self._total_us / len(self._us_samples) if self._us_samples else 0.0
        return SessionStatus(
            state=self._state,
            config_version=self._config_version,
            last_processed_sequence_id=self._last_sequence_id,
            average_processing_time_us=avg_us,
            p99_processing_time_us=self._p99(),
            max_processing_time_us=int(self._max_us),
            gap_count=self._gap_count,
            timeout_count=self._timeout_count,
            warmup_remaining_samples=self._warmup_remaining,
            rolling_buffer_duration_s=self._buffer.available_duration_s(),
            last_error=self._last_error,
        )

    def close(self) -> None:
        if self._state == SessionState.CLOSED:
            return
        self._phase_decoder.close()
        self._state = SessionState.CLOSED
        _log.info(
            "在线会话关闭",
            extra={"operation": "close_online_session", "session_id": self._session_id},
        )

    def _set_session_id(self, session_id: int) -> None:
        self._session_id = session_id

    # ---- 内部 ----
    def _ensure_operable(self, operation: str) -> None:
        if self._state == SessionState.CLOSED:
            raise error(ErrorCode.INVALID_STATE, "会话已关闭", operation)
        if self._state == SessionState.ERROR:
            raise error(
                ErrorCode.INVALID_STATE,
                "会话处于 ERROR 状态，仅允许 reset/get_online_status/close",
                operation,
            )

    def _handle_discontinuity(self, first_seq: int, stamps: np.ndarray) -> None:
        self._gap_count += 1
        self._filter_chain.reset()
        self._asr.reset_stream_state()
        self._phase_decoder.reset()
        self._buffer.clear(self._config_version)
        self._warmup_remaining = _WARMUP_SAMPLES
        self._state = SessionState.WARMING_UP
        _log.warning(
            "在线序列断裂，流式状态已重置",
            extra={
                "operation": "push",
                "code": ErrorCode.TIME_SEQUENCE_DISCONTINUITY,
                "session_id": self._session_id,
            },
        )

    def _advance_warmup(self, n: int) -> None:
        if self._state == SessionState.WARMING_UP:
            self._warmup_remaining = max(0, self._warmup_remaining - n)
            if self._warmup_remaining == 0:
                self._state = SessionState.RUNNING

    def _current_flags(self) -> tuple[QualityFlag, ...]:
        if self._state == SessionState.WARMING_UP:
            return (QualityFlag.WARMING_UP,)
        return (QualityFlag.OK,)

    def _record_timing(self, us: float) -> None:
        self._total_us += us
        self._max_us = max(self._max_us, us)
        self._us_samples.append(us)

    def _p99(self) -> float:
        if not self._us_samples:
            return 0.0
        values = sorted(self._us_samples)
        k = int((len(values) - 1) * 0.99)
        return values[k]
