"""离线滤波：零相位带通与陷波。"""

from __future__ import annotations

import numpy as np
from scipy.signal import filtfilt

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.common.filter_design import bandpass_ba, bandstop_ba
from eeg_algorithm.types.common import SignalBlock
from eeg_algorithm.types.offline import BandPassConfig, NotchConfig


def _min_length(values: np.ndarray) -> int:
    return max(1, values.shape[1] // 2)


def band_pass_filter(
    signal: SignalBlock,
    sample_rate_hz: float,
    config: BandPassConfig,
) -> SignalBlock:
    if not config.enabled:
        return signal
    b, a = bandpass_ba(config.low_cut_hz, config.high_cut_hz, sample_rate_hz)
    values = signal.values
    if values.shape[1] < 3 * max(len(a), len(b)):
        raise error(
            ErrorCode.ALGORITHM_RUNTIME_ERROR,
            "数据过短，无法完成零相位带通滤波",
            "band_pass_filter",
        )
    filtered = filtfilt(b, a, values, axis=1).astype(np.float32)
    return SignalBlock(signal.first_sequence_id, signal.timestamps_ns, filtered)


def notch_filter(
    signal: SignalBlock,
    sample_rate_hz: float,
    config: NotchConfig,
) -> SignalBlock:
    if not config.enabled:
        return signal
    b, a = bandstop_ba(config.stop_low_hz, config.stop_high_hz, sample_rate_hz)
    values = signal.values
    if values.shape[1] < 3 * max(len(a), len(b)):
        raise error(
            ErrorCode.ALGORITHM_RUNTIME_ERROR,
            "数据过短，无法完成零相位陷波",
            "notch_filter",
        )
    filtered = filtfilt(b, a, values, axis=1).astype(np.float32)
    return SignalBlock(signal.first_sequence_id, signal.timestamps_ns, filtered)
