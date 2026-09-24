"""在线因果滤波链：高通/低通/陷波，状态跨调用保留。"""

from __future__ import annotations

import numpy as np
from scipy.signal import sosfilt, sosfilt_zi

from eeg_algorithm.internal.common.filter_design import (
    bandstop_sos,
    highpass_sos,
    lowpass_sos,
)
from eeg_algorithm.types.online import OnlineProcessingConfig


class OnlineFilterChain:
    """执行顺序固定为高通/低通后陷波，使用因果 Butterworth SOS。"""

    def __init__(
        self,
        config: OnlineProcessingConfig,
        sample_rate_hz: float,
        channel_count: int,
    ) -> None:
        self._fs = sample_rate_hz
        self._channel_count = channel_count
        self._sos: list[tuple[np.ndarray, np.ndarray]] = []
        self._build(config)

    def _build(self, config: OnlineProcessingConfig) -> None:
        sos_list: list[np.ndarray] = []
        if config.high_pass.enabled:
            sos_list.append(
                highpass_sos(config.high_pass.low_hz, self._fs, config.high_pass.order)
            )
        if config.low_pass.enabled:
            sos_list.append(
                lowpass_sos(config.low_pass.high_hz, self._fs, config.low_pass.order)
            )
        if config.notch.enabled:
            sos_list.append(
                bandstop_sos(config.notch.low_hz, config.notch.high_hz, self._fs, config.notch.order)
            )
        self._sos = [(s, self._init_zi(s)) for s in sos_list]

    def _init_zi(self, sos: np.ndarray) -> np.ndarray:
        zi = sosfilt_zi(sos)  # (n_sections, 2)
        return np.repeat(zi[:, None, :], self._channel_count, axis=1)  # (n_sections, C, 2)

    def reconfigure(self, config: OnlineProcessingConfig) -> None:
        self._build(config)

    def process_block(self, values: np.ndarray) -> np.ndarray:
        y = np.asarray(values, dtype=np.float64)
        for i, (sos, zi) in enumerate(self._sos):
            y, zf = sosfilt(sos, y, axis=1, zi=zi)
            self._sos[i] = (sos, zf)
        return y.astype(np.float32)

    def process_sample(self, values: np.ndarray) -> np.ndarray:
        y = self.process_block(values[:, None])
        return y[:, 0]

    def reset(self) -> None:
        self._sos = [(s, self._init_zi(s)) for s, _ in self._sos]
