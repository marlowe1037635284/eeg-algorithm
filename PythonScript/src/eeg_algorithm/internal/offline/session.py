"""离线会话：保存不可变原始数据与当前有效预处理版本。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import (
    AlgorithmError,
    AlgorithmErrorInfo,
    ErrorCode,
    error,
)
from eeg_algorithm.internal.observability import get_logger
from eeg_algorithm.internal.offline.pipeline import run_preprocessing_pipeline
from eeg_algorithm.internal.offline.selection import (
    select_channel_segment,
    select_multichannel_segment,
)
from eeg_algorithm.internal.offline.spectrum import compute_offline_spectrum
from eeg_algorithm.internal.offline.topography import compute_offline_topography
from eeg_algorithm.internal.validation import validate_channel_layout, validate_channel_name
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from eeg_algorithm.types.enums import OfflineSessionState
from eeg_algorithm.types.offline import (
    OfflineSessionStatus,
    OfflineSpectrumQuery,
    OfflineSpectrumResult,
    OfflineTopographyQuery,
    OfflineTopographyResult,
    PreprocessConfig,
    PreprocessedDataset,
    PreprocessResult,
)

_log = get_logger("offline.session")


def _time_range(signal: SignalBlock, sample_rate_hz: float) -> AbsoluteTimeRange:
    ts = signal.timestamps_ns
    if ts.size == 0:
        return AbsoluteTimeRange(0, 0)
    dt = int(1e9 / sample_rate_hz)
    return AbsoluteTimeRange(int(ts[0]), int(ts[-1]) + dt)


class OfflineSession:
    """持有一份不可变原始数据，以及最多一份当前 ``PreprocessedDataset``。"""

    def __init__(self, layout: ChannelLayout, raw_signal: SignalBlock) -> None:
        validate_channel_layout(layout)
        self._layout = layout
        self._raw_signal = self._validate_raw(raw_signal, layout)
        self._raw_time_range = _time_range(self._raw_signal, layout.sample_rate_hz)
        self._preprocessed: PreprocessedDataset | None = None
        self._state = OfflineSessionState.RAW_READY
        self._last_error: AlgorithmErrorInfo | None = None
        self._session_id: int | None = None

        _log.info(
            "离线会话创建",
            extra={
                "operation": "create_offline_session",
                "session_id": None,
                "sample_count": self._raw_signal.values.shape[1],
            },
        )

    def _validate_raw(self, raw_signal: SignalBlock, layout: ChannelLayout) -> SignalBlock:
        values = np.asarray(raw_signal.values, dtype=np.float32)
        stamps = np.asarray(raw_signal.timestamps_ns, dtype=np.int64)
        c = len(layout.channel_names)
        if values.ndim != 2 or values.shape[0] != c:
            raise error(
                ErrorCode.CHANNEL_LAYOUT_MISMATCH,
                "原始数据通道数与布局不符",
                "create_offline_session",
            )
        if stamps.ndim != 1 or stamps.shape[0] != values.shape[1]:
            raise error(
                ErrorCode.SHAPE_MISMATCH,
                "时间戳长度与样本数不符",
                "create_offline_session",
            )
        if values.shape[1] == 0:
            raise error(ErrorCode.INVALID_ARGUMENT, "原始数据不能为空", "create_offline_session")
        if not np.isfinite(values).all():
            raise error(ErrorCode.INVALID_ARGUMENT, "输入数据包含 NaN 或 Inf", "create_offline_session")
        return SignalBlock(
            first_sequence_id=raw_signal.first_sequence_id,
            timestamps_ns=np.ascontiguousarray(stamps),
            values=np.ascontiguousarray(values),
        )

    # ---- 预处理 ----
    def preprocess(self, config: PreprocessConfig) -> PreprocessResult:
        self._ensure_operable("preprocess")
        if config.preprocess_version <= 0:
            raise error(ErrorCode.INVALID_ARGUMENT, "preprocess_version 必须大于 0", "run_preprocessing")
        if self._preprocessed is not None and config.preprocess_version <= self._preprocessed.preprocess_version:
            raise error(ErrorCode.INVALID_ARGUMENT, "preprocess_version 必须递增", "run_preprocessing")

        self._state = OfflineSessionState.PREPROCESSING
        try:
            dataset = run_preprocessing_pipeline(self._raw_signal, self._layout, config)
        except AlgorithmError as exc:
            self._last_error = exc.info
            self._state = self._recover_state_after_failure()
            _log.error(
                "离线预处理失败",
                extra={"operation": "run_preprocessing", "code": exc.info.code},
            )
            raise
        except Exception as exc:  # noqa: BLE001
            info = AlgorithmErrorInfo(
                code=ErrorCode.ALGORITHM_RUNTIME_ERROR,
                message=str(exc),
                operation="run_preprocessing",
                session_id=self._session_id,
            )
            self._last_error = info
            self._state = self._recover_state_after_failure()
            _log.error(
                "离线预处理失败",
                extra={"operation": "run_preprocessing", "code": info.code},
            )
            raise error(info.code, info.message, info.operation, info.session_id) from exc

        self._preprocessed = dataset
        self._state = OfflineSessionState.PREPROCESSED
        self._last_error = None

        processed_signal = dataset.signal if config.return_processed_signal else None
        return PreprocessResult(
            preprocess_version=dataset.preprocess_version,
            layout=dataset.layout,
            actual_time_range=dataset.actual_time_range,
            sample_count=dataset.signal.values.shape[1],
            processed_signal=processed_signal,
            applied_steps=dataset.applied_steps,
            warnings=(),
        )

    def _recover_state_after_failure(self) -> OfflineSessionState:
        # 失败时保留上一份有效结果；不存在上一版本则回到 RAW_READY。
        if self._preprocessed is None:
            return OfflineSessionState.RAW_READY
        return OfflineSessionState.PREPROCESSED

    # ---- 后处理查询 ----
    def query_spectrum(self, query: OfflineSpectrumQuery) -> OfflineSpectrumResult:
        dataset = self._require_preprocessed(query.preprocess_version, "query_offline_spectrum")
        validate_channel_name(dataset.layout, query.channel_name, "query_offline_spectrum")
        segment = select_channel_segment(dataset, query.channel_name, query.selected_range)
        return compute_offline_spectrum(segment, dataset.layout, query)

    def query_topography(self, query: OfflineTopographyQuery) -> OfflineTopographyResult:
        dataset = self._require_preprocessed(query.preprocess_version, "query_offline_topography")
        segment = select_multichannel_segment(dataset, query.selected_range)
        return compute_offline_topography(segment, dataset.layout, query)

    def get_preprocessed_data(self) -> PreprocessedDataset:
        self._ensure_operable("get_preprocessed_data")
        if self._preprocessed is None:
            raise error(
                ErrorCode.PREPROCESSED_DATA_NOT_READY,
                "离线预处理尚未完成",
                "get_preprocessed_data",
            )
        return self._preprocessed

    def status(self) -> OfflineSessionStatus:
        return OfflineSessionStatus(
            state=self._state,
            preprocess_version=self._preprocessed.preprocess_version if self._preprocessed else None,
            raw_time_range=self._raw_time_range,
            preprocessed_time_range=self._preprocessed.actual_time_range if self._preprocessed else None,
            raw_sample_count=self._raw_signal.values.shape[1],
            preprocessed_sample_count=self._preprocessed.signal.values.shape[1] if self._preprocessed else None,
            last_error=self._last_error,
        )

    def close(self) -> None:
        if self._state == OfflineSessionState.CLOSED:
            return
        self._state = OfflineSessionState.CLOSED
        self._preprocessed = None
        _log.info(
            "离线会话关闭",
            extra={"operation": "close_offline_session", "session_id": self._session_id},
        )

    def _set_session_id(self, session_id: int) -> None:
        self._session_id = session_id

    # ---- 内部 ----
    def _ensure_operable(self, operation: str) -> None:
        if self._state == OfflineSessionState.CLOSED:
            raise error(ErrorCode.INVALID_STATE, "会话已关闭", operation)
        if self._state == OfflineSessionState.PREPROCESSING:
            raise error(ErrorCode.INVALID_STATE, "预处理正在进行中", operation)

    def _require_preprocessed(self, preprocess_version: int, operation: str) -> PreprocessedDataset:
        self._ensure_operable(operation)
        if self._preprocessed is None:
            raise error(
                ErrorCode.PREPROCESSED_DATA_NOT_READY,
                "离线预处理尚未完成",
                operation,
            )
        if preprocess_version != self._preprocessed.preprocess_version:
            raise error(ErrorCode.STALE_DATA_VERSION, "preprocess_version 已过期", operation)
        return self._preprocessed
