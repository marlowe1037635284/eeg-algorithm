from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import signal

from eeg_algorithm.errors import INVALID_ARGUMENT, algorithm_error
from eeg_algorithm.types import OnlineProcessingConfig

from eeg_algorithm.internal.common.filter_design import bandstop_sos, highpass_sos, lowpass_sos


class OnlineFilterChain:
    def __init__(self, config: OnlineProcessingConfig, sample_rate_hz: float, channel_count: int) -> None:
        self._sample_rate_hz = sample_rate_hz
        self._channel_count = channel_count
        self._stages: list[tuple[NDArray[np.float64], NDArray[np.float64]]] = []
        self.reconfigure(config)

    def reconfigure(self, config: OnlineProcessingConfig) -> None:
        stages: list[NDArray[np.float64]] = []
        for item in (config.high_pass, config.low_pass, config.notch):
            if item.order != 4:
                raise algorithm_error(INVALID_ARGUMENT, "v1滤波器阶数必须为4", "OnlineFilterChain.reconfigure")
        if config.high_pass.enabled:
            if config.high_pass.low_hz is None:
                raise algorithm_error(INVALID_ARGUMENT, "高通启用时必须提供low_hz", "OnlineFilterChain.reconfigure")
            stages.append(highpass_sos(config.high_pass.low_hz, self._sample_rate_hz))
        if config.low_pass.enabled:
            if config.low_pass.high_hz is None:
                raise algorithm_error(INVALID_ARGUMENT, "低通启用时必须提供high_hz", "OnlineFilterChain.reconfigure")
            stages.append(lowpass_sos(config.low_pass.high_hz, self._sample_rate_hz))
        if config.notch.enabled:
            if config.notch.low_hz is None or config.notch.high_hz is None:
                raise algorithm_error(INVALID_ARGUMENT, "陷波启用时必须提供low_hz和high_hz", "OnlineFilterChain.reconfigure")
            stages.append(bandstop_sos(config.notch.low_hz, config.notch.high_hz, self._sample_rate_hz))
        self._stages = [
            (sos, np.zeros((sos.shape[0], self._channel_count, 2), dtype=np.float64)) for sos in stages
        ]

    def process_sample(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        return self.process_block(np.ascontiguousarray(values[:, None], dtype=np.float32))[:, 0]

    def process_block(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        output = np.asarray(values, dtype=np.float64)
        new_stages: list[tuple[NDArray[np.float64], NDArray[np.float64]]] = []
        for sos, zi in self._stages:
            output, next_zi = signal.sosfilt(sos, output, axis=1, zi=zi)
            new_stages.append((sos, next_zi))
        self._stages = new_stages
        return np.ascontiguousarray(output, dtype=np.float32)

    def reset(self) -> None:
        self._stages = [(sos, np.zeros_like(zi)) for sos, zi in self._stages]

