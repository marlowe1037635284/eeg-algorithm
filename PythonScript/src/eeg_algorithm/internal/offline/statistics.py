from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import stats

from eeg_algorithm.types import ChannelLayout, OfflineStatisticsResult, SignalBlock

from eeg_algorithm.internal.common.spectrum_core import welch_psd

# 频带能量与优势频带判定使用的标准频带：名称、下界、上界（Hz）。
_STANDARD_BANDS: tuple[tuple[str, float, float], ...] = (
    ("delta", 0.5, 4.0),
    ("theta", 4.0, 8.0),
    ("alpha", 8.0, 13.0),
    ("beta", 13.0, 30.0),
    ("gamma", 30.0, 45.0),
)
_BAND_NAMES: tuple[str, ...] = tuple(name for name, _, _ in _STANDARD_BANDS)


def compute_offline_statistics(
    multichannel_signal: SignalBlock,
    layout: ChannelLayout,
    query,  # OfflineStatisticsQuery
) -> OfflineStatisticsResult:
    """在预处理后选段数据上，逐通道计算时域与频域统计指标。"""
    values = np.asarray(multichannel_signal.values, dtype=np.float64)
    sample_rate_hz = layout.sample_rate_hz
    channel_names = layout.channel_names

    mean = np.mean(values, axis=1)
    std = np.std(values, axis=1, ddof=1)
    rms = np.sqrt(np.mean(np.square(values), axis=1))
    peak_to_peak = np.ptp(values, axis=1)
    min_value = np.min(values, axis=1)
    max_value = np.max(values, axis=1)
    zero_crossing_rate = _zero_crossing_rate(values, sample_rate_hz)
    skewness = stats.skew(values, axis=1, bias=False)
    kurtosis = stats.kurtosis(values, axis=1, bias=False, fisher=True)
    correlation_matrix = _correlation_matrix(values)
    band_energies, band_names = _band_energies(multichannel_signal.values, sample_rate_hz)
    dominant_band = _dominant_band(band_energies, band_names)

    return OfflineStatisticsResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        selected_range=query.selected_range,
        channel_names=channel_names,
        mean=_as_f32(mean),
        std=_as_f32(std),
        rms=_as_f32(rms),
        peak_to_peak=_as_f32(peak_to_peak),
        min_value=_as_f32(min_value),
        max_value=_as_f32(max_value),
        zero_crossing_rate=_as_f32(zero_crossing_rate),
        skewness=_as_f32(skewness),
        kurtosis=_as_f32(kurtosis),
        dominant_band=dominant_band,
        correlation_matrix=_as_f32(correlation_matrix),
        band_names=band_names,
        band_energies=_as_f32(band_energies),
    )


def _zero_crossing_rate(values: NDArray[np.float64], sample_rate_hz: float) -> NDArray[np.float64]:
    n_channels, n_samples = values.shape
    if n_samples < 2:
        return np.zeros(n_channels, dtype=np.float64)
    crossings = np.sum(np.diff(np.signbit(values), axis=1) != 0, axis=1)
    duration_s = n_samples / sample_rate_hz
    return crossings / duration_s if duration_s > 0 else np.zeros(n_channels, dtype=np.float64)


def _correlation_matrix(values: NDArray[np.float64]) -> NDArray[np.float64]:
    return np.asarray(np.corrcoef(values), dtype=np.float64)


def _band_energies(
    values: NDArray[np.float32],
    sample_rate_hz: float,
) -> tuple[NDArray[np.float64], tuple[str, ...]]:
    """计算各通道在每个标准频带内的 PSD 能量，返回 [C,5] 能量矩阵与频带名。"""
    n_channels = values.shape[0]
    num_bands = len(_STANDARD_BANDS)
    if values.shape[1] < 4:
        return np.zeros((n_channels, num_bands), dtype=np.float64), _BAND_NAMES

    frequencies, psd = welch_psd(values, sample_rate_hz)
    energies = np.zeros((n_channels, num_bands), dtype=np.float64)
    for i, (_, low, high) in enumerate(_STANDARD_BANDS):
        mask = (frequencies >= low) & (frequencies <= high)
        if mask.any():
            energies[:, i] = np.sum(psd[:, mask], axis=1, dtype=np.float64)
    return energies, _BAND_NAMES


def _dominant_band(band_energies: NDArray[np.float64], band_names: tuple[str, ...]) -> tuple[str, ...]:
    result: list[str] = []
    for energies in band_energies:
        if energies.max() <= 0:
            result.append("none")
        else:
            result.append(band_names[int(np.argmax(energies))])
    return tuple(result)


def _as_f32(values: NDArray[np.float64]) -> NDArray[np.float32]:
    return np.ascontiguousarray(values, dtype=np.float32)
