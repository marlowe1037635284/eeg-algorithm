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

def band_peak_psd(
    frequencies: NDArray[np.float32],
    psd: NDArray[np.float32],
) -> tuple[
    float | None,
    float | None,
    float | None,
    float | None,
    float | None,
]:
    """返回Delta、Theta、Alpha、Beta、Gamma的最大PSD。"""
    bands = (
        (0.5, 4.0),
        (4.0, 8.0),
        (8.0, 13.0),
        (13.0, 30.0),
        (30.0, 45.0),
    )

    peaks = []
    for index, (low, high) in enumerate(bands):
        # 左闭右开；最后一个频段包含45 Hz。
        upper = frequencies <= high if index == 4 else frequencies < high
        mask = (frequencies >= low) & upper
        band_psd = psd[mask]

        peaks.append(
            float(np.max(band_psd))
            if band_psd.size else None
        )

    return peaks[0], peaks[1], peaks[2], peaks[3], peaks[4]