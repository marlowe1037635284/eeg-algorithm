"""Welch PSD 计算，供在线频谱与离线频谱复用。"""

from __future__ import annotations

import numpy as np
from scipy import signal


def welch_psd(
    x: np.ndarray,
    fs: float,
    freq_range_hz: tuple[float, float] | None = None,
    nperseg: int | None = None,
    overlap: float = 0.5,
) -> tuple[np.ndarray, np.ndarray]:
    """计算单边 Welch PSD。

    参数：
        x: 一维信号。
        fs: 采样率（Hz）。
        freq_range_hz: 返回频点范围；``None`` 表示返回全部有效频率。
        nperseg: 每段长度；``None`` 表示由 scipy 自动选择。
        overlap: 分段重叠比例，默认 0.5。

    返回：
        ``(frequencies_hz, psd)``，均为 ``float32``。
    """
    if nperseg is None:
        nperseg = min(len(x), 256)

    freqs, psd = signal.welch(
        x,
        fs=fs,
        nperseg=nperseg,
        noverlap=int(nperseg * overlap),
        scaling="density",
    )

    if freq_range_hz is not None:
        lo, hi = freq_range_hz
        mask = (freqs >= lo) & (freqs <= hi)
        freqs = freqs[mask]
        psd = psd[mask]

    return freqs.astype(np.float32), psd.astype(np.float32)
