"""滤波系数设计。

在线链路使用因果 Butterworth SOS；离线链路使用双向零相位（filtfilt）。
"""

from __future__ import annotations

import numpy as np
from scipy import signal

DEFAULT_ORDER = 4


def highpass_sos(cutoff_hz: float, fs: float, order: int = DEFAULT_ORDER) -> np.ndarray:
    """因果高通二阶节。"""
    return signal.butter(order, cutoff_hz, btype="highpass", fs=fs, output="sos")


def lowpass_sos(cutoff_hz: float, fs: float, order: int = DEFAULT_ORDER) -> np.ndarray:
    """因果低通二阶节。"""
    return signal.butter(order, cutoff_hz, btype="lowpass", fs=fs, output="sos")


def bandpass_sos(low_hz: float, high_hz: float, fs: float, order: int = DEFAULT_ORDER) -> np.ndarray:
    """因果带通二阶节。"""
    return signal.butter(order, [low_hz, high_hz], btype="bandpass", fs=fs, output="sos")


def bandstop_sos(low_hz: float, high_hz: float, fs: float, order: int = DEFAULT_ORDER) -> np.ndarray:
    """因果带阻（陷波）二阶节。"""
    return signal.butter(order, [low_hz, high_hz], btype="bandstop", fs=fs, output="sos")


def bandpass_ba(low_hz: float, high_hz: float, fs: float, order: int = DEFAULT_ORDER) -> tuple[np.ndarray, np.ndarray]:
    """零相位带通系数（b, a），供 ``filtfilt`` 使用。"""
    return signal.butter(order, [low_hz, high_hz], btype="bandpass", fs=fs)


def bandstop_ba(low_hz: float, high_hz: float, fs: float, order: int = DEFAULT_ORDER) -> tuple[np.ndarray, np.ndarray]:
    """零相位带阻（陷波）系数（b, a）。"""
    return signal.butter(order, [low_hz, high_hz], btype="bandstop", fs=fs)
