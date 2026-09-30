from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import signal

from eeg_algorithm.errors import INSUFFICIENT_WINDOW_DATA, algorithm_error


def welch_psd(
    values: NDArray[np.float32],
    sample_rate_hz: float,
) -> tuple[NDArray[np.float32], NDArray[np.float32]]:
    samples = int(values.shape[-1])
    if samples < 4:
        raise algorithm_error(INSUFFICIENT_WINDOW_DATA, "频谱计算至少需要4个采样点", "welch_psd")
    nperseg = min(samples, max(4, int(round(sample_rate_hz * 2.0))))
    frequencies, psd = signal.welch(
        values,
        fs=sample_rate_hz,
        nperseg=nperseg,
        noverlap=nperseg // 2,
        detrend="constant",
        scaling="density",
        axis=-1,
    )
    return (
        np.ascontiguousarray(frequencies, dtype=np.float32),
        np.ascontiguousarray(psd, dtype=np.float32),
    )


def select_frequency_range(
    frequencies: NDArray[np.float32],
    psd: NDArray[np.float32],
    low_hz: float,
    high_hz: float,
) -> tuple[NDArray[np.float32], NDArray[np.float32]]:
    mask = (frequencies >= low_hz) & (frequencies <= high_hz)
    return np.ascontiguousarray(frequencies[mask]), np.ascontiguousarray(psd[..., mask])

