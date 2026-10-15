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

def band_peak_frequencies(
    frequencies: NDArray[np.float32],
    psd: NDArray[np.float32],
) -> dict[str, float | None]:
    """输入单通道PSD，返回五个频段的峰值频率，单位Hz。"""
    bands = (
        ("delta", 0.5, 4.0),
        ("theta", 4.0, 8.0),
        ("alpha", 8.0, 13.0),
        ("beta", 13.0, 30.0),
        ("gamma", 30.0, 45.0),
    )

    peaks = {}
    for name, low, high in bands:
        # 左闭右开，避免边界点同时属于两个频段。
        mask = (frequencies >= low) & (frequencies < high)
        band_f = frequencies[mask]
        band_psd = psd[mask]

        if band_psd.size == 0:
            peaks[name] = None
        else:
            index = int(np.argmax(band_psd))
            peaks[name] = float(band_f[index])

    return peaks