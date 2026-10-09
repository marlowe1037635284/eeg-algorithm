from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.types import (
    ArtifactSegment,
    ChannelLayout,
    QualityControlConfig,
    QualityReport,
    SignalBlock,
)

from eeg_algorithm.internal.common.array_utils import copy_block

# 异常类型标识（用于界面按类型区分标注）
NULL_VALUE = "null_value"
WEAK_SIGNAL = "weak_signal"
AMPLITUDE_OUTLIER = "amplitude_outlier"
LOW_CORRELATION = "low_correlation"


def run_quality_control(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: QualityControlConfig,
) -> tuple[SignalBlock, QualityReport]:
    """执行离线质检，可选线性插值修复。

    始终返回质检报告（检测到的异常段列表 + 逐样本掩码）；
    repair_enabled 为 True 时对异常样本做线性插值修复并返回修复后的信号。
    """
    values = signal.values
    empty = np.zeros(values.shape, dtype=np.bool_)

    channel_names = layout.channel_names
    timestamps = signal.timestamps_ns

    null_mask = _detect_null(values) if config.null_weak_enabled else empty
    weak_mask = (
        _detect_weak_signal(values, config.weak_signal_threshold_uv, layout.sample_rate_hz)
        if config.null_weak_enabled
        else empty
    )
    amplitude_mask = _detect_amplitude_outliers(values, config.amplitude_ratio) if config.amplitude_outlier_enabled else empty
    correlation_mask = _detect_low_correlation(values, config.correlation_threshold) if config.low_correlation_enabled else empty

    combined_mask = null_mask | weak_mask | amplitude_mask | correlation_mask

    segments: list[ArtifactSegment] = []
    segments += _extract_segments(null_mask, channel_names, timestamps, NULL_VALUE)
    segments += _extract_segments(weak_mask, channel_names, timestamps, WEAK_SIGNAL)
    segments += _extract_segments(amplitude_mask, channel_names, timestamps, AMPLITUDE_OUTLIER)
    segments += _extract_segments(correlation_mask, channel_names, timestamps, LOW_CORRELATION)

    repaired = config.repair_enabled and bool(combined_mask.any())
    if repaired:
        values = _repair_by_linear_interpolation(values, combined_mask)

    report = QualityReport(
        segments=tuple(segments),
        artifact_mask=np.ascontiguousarray(combined_mask),
        repaired=repaired,
    )
    return copy_block(signal, np.ascontiguousarray(values, dtype=np.float32)), report


def _detect_null(values: NDArray[np.float32]) -> NDArray[np.bool_]:
    """空值检测：NaN 或 Inf 的样本。"""
    return ~np.isfinite(values)


def _detect_weak_signal(
    values: NDArray[np.float32],
    threshold_uv: float,
    sample_rate_hz: float,
) -> NDArray[np.bool_]:
    """弱信号检测：非重叠 1 秒窗口内标准差低于阈值，视为电极脱落/平线。"""
    mask = np.zeros(values.shape, dtype=np.bool_)
    n_channels, n_samples = values.shape
    if n_samples == 0:
        return mask
    window = max(1, int(round(sample_rate_hz)))
    for c in range(n_channels):
        ch = values[c]
        for start in range(0, n_samples, window):
            end = min(start + window, n_samples)
            if np.nanstd(ch[start:end]) < threshold_uv:
                mask[c, start:end] = True
    return mask


def _detect_amplitude_outliers(
    values: NDArray[np.float32],
    amplitude_ratio: float,
) -> NDArray[np.bool_]:
    """异常 EEG 范围外值：每通道 |x| 超过 (1-ratio) 分位数视为异常。"""
    mask = np.zeros(values.shape, dtype=np.bool_)
    ratio = float(np.clip(amplitude_ratio, 0.0, 0.5))
    upper_q = 1.0 - ratio
    for c in range(values.shape[0]):
        ch = np.abs(values[c])
        if ch.size == 0:
            continue
        threshold = float(np.quantile(ch, upper_q))
        if threshold > 0:
            mask[c] = ch > threshold
    return mask


def _detect_low_correlation(
    values: NDArray[np.float32],
    correlation_threshold: float,
) -> NDArray[np.bool_]:
    """低相关性导联：通道与全通道中位数信号的皮尔逊相关系数低于阈值。"""
    n_channels, n_samples = values.shape
    mask = np.zeros(values.shape, dtype=np.bool_)
    if n_channels < 2 or n_samples < 2:
        return mask
    reference = np.median(values, axis=0)
    ref_std = np.nanstd(reference)
    if ref_std < 1e-9:
        return mask
    with np.errstate(invalid="ignore", divide="ignore"):
        for c in range(n_channels):
            ch = values[c]
            if np.nanstd(ch) < 1e-9:
                mask[c] = True  # 常数导联无法计算相关，视为低相关
                continue
            corr = float(np.corrcoef(ch, reference)[0, 1])
            if np.isfinite(corr) and corr < correlation_threshold:
                mask[c] = True
    return mask


def _extract_segments(
    mask: NDArray[np.bool_],
    channel_names: tuple[str, ...],
    timestamps: NDArray[np.int64],
    artifact_type: str,
) -> list[ArtifactSegment]:
    """从逐通道布尔掩码中提取连续异常段。"""
    segments: list[ArtifactSegment] = []
    for c in range(mask.shape[0]):
        idx = np.flatnonzero(mask[c])
        if idx.size == 0:
            continue
        starts = idx[np.r_[True, np.diff(idx) > 1]]
        ends = idx[np.r_[np.diff(idx) > 1, True]] + 1  # 开区间
        for s, e in zip(starts, ends):
            segments.append(
                ArtifactSegment(
                    channel_name=channel_names[c],
                    artifact_type=artifact_type,
                    start_sample=int(s),
                    end_sample=int(e),
                    start_timestamp_ns=int(timestamps[s]),
                    end_timestamp_ns=int(timestamps[e - 1]),
                )
            )
    return segments


def _repair_by_linear_interpolation(
    values: NDArray[np.float32],
    mask: NDArray[np.bool_],
) -> NDArray[np.float32]:
    """对异常样本用其左右正常样本做线性插值修复（边界外使用最近正常值）。"""
    repaired = values.copy()
    for c in range(values.shape[0]):
        if not mask[c].any():
            continue
        repaired[c] = _interp_channel(values[c], mask[c])
    return repaired


def _interp_channel(x: NDArray[np.float32], m: NDArray[np.bool_]) -> NDArray[np.float32]:
    out = x.copy()
    ok_idx = np.flatnonzero(~m)
    if ok_idx.size == 0:
        return out  # 整通道异常，无法插值，保留原值
    bad_idx = np.flatnonzero(m)
    out[bad_idx] = np.interp(bad_idx, ok_idx, x[ok_idx])
    return out
