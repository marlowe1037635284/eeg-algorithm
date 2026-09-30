from __future__ import annotations

import logging

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.errors import ASR_REFERENCE_REQUIRED, INVALID_ARGUMENT, algorithm_error
from eeg_algorithm.types import AsrConfig, ChannelLayout, SignalBlock

from eeg_algorithm.internal.observability.context import get_logger, log_event


class OnlineAsrProcessor:
    """Replaceable ASR boundary with a conservative reference-statistics baseline."""

    def __init__(self, config: AsrConfig, layout: ChannelLayout) -> None:
        if config.cutoff <= 0:
            raise algorithm_error(INVALID_ARGUMENT, "ASR cutoff必须大于0", "OnlineAsrProcessor")
        self._config = config
        self._layout = layout
        self._enabled = False
        self._original_reference: SignalBlock | None = None
        self._mean: NDArray[np.float32] | None = None
        self._std: NDArray[np.float32] | None = None
        self._logger = get_logger(__name__)

    @property
    def has_reference(self) -> bool:
        return self._mean is not None and self._std is not None

    @property
    def original_reference(self) -> SignalBlock | None:
        return self._original_reference

    def fit_reference(self, reference: SignalBlock) -> None:
        duration_s = reference.values.shape[1] / self._layout.sample_rate_hz
        expected = self._config.reference_duration_s
        if expected is not None and abs(duration_s - expected) > 1.0 / self._layout.sample_rate_hz:
            raise algorithm_error(INVALID_ARGUMENT, "ASR参考时长与配置不一致", "fit_reference")
        if duration_s < 60.0 or duration_s > 180.0:
            raise algorithm_error(INVALID_ARGUMENT, "ASR参考数据时长必须为60到180秒", "fit_reference")
        self._original_reference = reference
        self._fit_values(reference.values)
        log_event(self._logger, logging.INFO, "ASR参考数据拟合完成", code="ASR_REFERENCE_FITTED", operation="fit_reference")

    def fit_processed_reference(self, original: SignalBlock, processed_values: NDArray[np.float32]) -> None:
        self._original_reference = original
        self._fit_values(processed_values)

    def set_enabled(self, enabled: bool) -> None:
        self._enabled = enabled

    def process_sample(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        return self.process_block(values[:, None])[:, 0]

    def process_block(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        if not self._enabled:
            return np.ascontiguousarray(values, dtype=np.float32)
        if self._mean is None or self._std is None:
            raise algorithm_error(ASR_REFERENCE_REQUIRED, "ASR已启用但尚未设置参考数据", "OnlineAsrProcessor.process")
        low = self._mean[:, None] - self._config.cutoff * self._std[:, None]
        high = self._mean[:, None] + self._config.cutoff * self._std[:, None]
        return np.ascontiguousarray(np.clip(values, low, high), dtype=np.float32)

    def reset_stream_state(self) -> None:
        return

    def _fit_values(self, values: NDArray[np.float32]) -> None:
        mean = np.mean(values, axis=1, dtype=np.float64)
        std = np.std(values, axis=1, dtype=np.float64)
        floor = np.maximum(np.abs(mean) * 1e-6, 1e-6)
        self._mean = np.asarray(mean, dtype=np.float32)
        self._std = np.asarray(np.maximum(std, floor), dtype=np.float32)

