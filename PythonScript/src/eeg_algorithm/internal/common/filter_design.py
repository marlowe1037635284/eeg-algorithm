from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import signal

from eeg_algorithm.errors import ALGORITHM_RUNTIME_ERROR, FREQUENCY_OUT_OF_RANGE, algorithm_error


def validate_frequency_edges(low_hz: float, high_hz: float, sample_rate_hz: float, operation: str) -> None:
    if not 0 < low_hz < high_hz < sample_rate_hz / 2:
        raise algorithm_error(FREQUENCY_OUT_OF_RANGE, "滤波频率必须位于(0, Nyquist)内", operation)


def highpass_sos(cutoff_hz: float, sample_rate_hz: float, order: int = 4) -> NDArray[np.float64]:
    if not 0 < cutoff_hz < sample_rate_hz / 2:
        raise algorithm_error(FREQUENCY_OUT_OF_RANGE, "高通截止频率非法", "highpass_sos")
    return signal.butter(order, cutoff_hz, btype="highpass", fs=sample_rate_hz, output="sos")


def lowpass_sos(cutoff_hz: float, sample_rate_hz: float, order: int = 4) -> NDArray[np.float64]:
    if not 0 < cutoff_hz < sample_rate_hz / 2:
        raise algorithm_error(FREQUENCY_OUT_OF_RANGE, "低通截止频率非法", "lowpass_sos")
    return signal.butter(order, cutoff_hz, btype="lowpass", fs=sample_rate_hz, output="sos")


def bandpass_sos(low_hz: float, high_hz: float, sample_rate_hz: float, order: int = 4) -> NDArray[np.float64]:
    validate_frequency_edges(low_hz, high_hz, sample_rate_hz, "bandpass_sos")
    return signal.butter(order, (low_hz, high_hz), btype="bandpass", fs=sample_rate_hz, output="sos")
 

def bandstop_sos(low_hz: float, high_hz: float, sample_rate_hz: float, order: int = 4) -> NDArray[np.float64]:
    validate_frequency_edges(low_hz, high_hz, sample_rate_hz, "bandstop_sos")
    return signal.butter(order, (low_hz, high_hz), btype="bandstop", fs=sample_rate_hz, output="sos")


def zero_phase_filter(values: NDArray[np.float32], sos: NDArray[np.float64], operation: str) -> NDArray[np.float32]:
    try:
        filtered = signal.sosfiltfilt(sos, values, axis=1)
    except ValueError as exc:
        raise algorithm_error(
            ALGORITHM_RUNTIME_ERROR,
            f"数据长度不足以执行零相位滤波: {exc}",
            operation,
        ) from exc
    return np.ascontiguousarray(filtered, dtype=np.float32)

