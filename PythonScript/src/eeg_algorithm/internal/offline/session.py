from __future__ import annotations

import logging
from threading import RLock

from eeg_algorithm.errors import (
    INVALID_ARGUMENT,
    INVALID_STATE,
    PREPROCESSED_DATA_NOT_READY,
    STALE_DATA_VERSION,
    AlgorithmErrorInfo,
    algorithm_error,
)
from eeg_algorithm.types import (
    AbsoluteTimeRange,
    ChannelLayout,
    OfflineSessionState,
    OfflineSessionStatus,
    OfflineSpectrumQuery,
    OfflineSpectrumResult,
    OfflineTopographyQuery,
    OfflineTopographyResult,
    PreprocessConfig,
    PreprocessedDataset,
    PreprocessResult,
    SignalBlock,
)

from eeg_algorithm.internal.observability.context import get_logger, log_event
from eeg_algorithm.internal.validation import validate_block, validate_layout

from .pipeline import run_preprocessing_pipeline
from .selection import select_channel_segment, select_multichannel_segment
from .spectrum import compute_offline_spectrum
from .topography import compute_offline_topography


class OfflineSession:
    def __init__(self, session_id: int, layout: ChannelLayout, raw_signal: SignalBlock) -> None:
        validate_layout(layout, "create_offline_session")
        validate_block(raw_signal, len(layout.channel_names), "create_offline_session")
        self._id = session_id
        self._layout = layout
        self._raw = SignalBlock(raw_signal.first_sequence_id, raw_signal.timestamps_ns.copy(), raw_signal.values.copy())
        self._dataset: PreprocessedDataset | None = None
        self._state = OfflineSessionState.RAW_READY
        self._last_error: AlgorithmErrorInfo | None = None
        self._lock = RLock()
        self._logger = get_logger(__name__)
        log_event(self._logger, logging.INFO, "离线会话创建", code="OFFLINE_SESSION_CREATED", session_id=self._id)

    def preprocess(self, config: PreprocessConfig) -> PreprocessResult:
        with self._lock:
            self._ensure_open("run_preprocessing")
            if self._dataset is not None and config.preprocess_version <= self._dataset.preprocess_version:
                raise algorithm_error(INVALID_ARGUMENT, "新预处理版本必须大于当前版本", "run_preprocessing", session_id=self._id)
            previous = self._dataset
            self._state = OfflineSessionState.PREPROCESSING
            try:
                candidate = run_preprocessing_pipeline(self._raw, self._layout, config, session_id=self._id)
            except Exception:
                self._dataset = previous
                self._state = OfflineSessionState.PREPROCESSED if previous is not None else OfflineSessionState.RAW_READY
                raise
            self._dataset = candidate
            self._state = OfflineSessionState.PREPROCESSED
            return PreprocessResult(
                preprocess_version=candidate.preprocess_version,
                layout=candidate.layout,
                actual_time_range=candidate.actual_time_range,
                sample_count=candidate.signal.values.shape[1],
                processed_signal=candidate.signal if config.return_processed_signal else None,
                applied_steps=candidate.applied_steps,
                warnings=(),
            )

    def query_spectrum(self, query: OfflineSpectrumQuery) -> OfflineSpectrumResult:
        with self._lock:
            dataset = self._require_dataset(query.preprocess_version, "query_offline_spectrum")
            selected = select_channel_segment(dataset, query.channel_name, query.selected_range)
            return compute_offline_spectrum(selected, dataset.layout, query)

    def query_topography(self, query: OfflineTopographyQuery) -> OfflineTopographyResult:
        with self._lock:
            dataset = self._require_dataset(query.preprocess_version, "query_offline_topography")
            selected = select_multichannel_segment(dataset, query.selected_range)
            return compute_offline_topography(selected, dataset.layout, query)

    def get_preprocessed_data(self) -> PreprocessedDataset:
        with self._lock:
            self._ensure_open("get_preprocessed_data")
            if self._dataset is None:
                raise algorithm_error(PREPROCESSED_DATA_NOT_READY, "预处理数据尚未生成", "get_preprocessed_data", session_id=self._id)
            return self._dataset

    def status(self) -> OfflineSessionStatus:
        with self._lock:
            raw_range = AbsoluteTimeRange(int(self._raw.timestamps_ns[0]), int(self._raw.timestamps_ns[-1]))
            return OfflineSessionStatus(
                state=self._state,
                preprocess_version=None if self._dataset is None else self._dataset.preprocess_version,
                raw_time_range=raw_range,
                preprocessed_time_range=None if self._dataset is None else self._dataset.actual_time_range,
                raw_sample_count=self._raw.values.shape[1],
                preprocessed_sample_count=None if self._dataset is None else self._dataset.signal.values.shape[1],
                last_error=self._last_error,
            )

    def close(self) -> None:
        with self._lock:
            if self._state is OfflineSessionState.CLOSED:
                return
            self._dataset = None
            self._state = OfflineSessionState.CLOSED
            log_event(self._logger, logging.INFO, "离线会话关闭", code="OFFLINE_SESSION_CLOSED", session_id=self._id)

    def _require_dataset(self, version: int, operation: str) -> PreprocessedDataset:
        self._ensure_open(operation)
        if self._dataset is None:
            raise algorithm_error(PREPROCESSED_DATA_NOT_READY, "预处理尚未完成", operation, session_id=self._id)
        if version != self._dataset.preprocess_version:
            raise algorithm_error(STALE_DATA_VERSION, "查询使用了过期的预处理版本", operation, session_id=self._id)
        return self._dataset

    def _ensure_open(self, operation: str) -> None:
        if self._state is OfflineSessionState.CLOSED:
            raise algorithm_error(INVALID_STATE, "离线会话已经关闭", operation, session_id=self._id)

