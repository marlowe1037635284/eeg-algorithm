from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import signal as scipy_signal

from eeg_algorithm.types import (
    ArtifactDetectionConfig,
    ArtifactReport,
    ArtifactSegment,
    ChannelLayout,
    SignalBlock,
)

from eeg_algorithm.internal.common.filter_design import highpass_sos

# 伪迹异常类型标识（用于界面按类型区分标注）
ARTIFACT = "artifact"


def detect_artifacts_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: ArtifactDetectionConfig,
) -> ArtifactReport:
    """离线伪迹检测（与 ASR 去伪迹同级）。

    检测跳变伪迹与高频能量伪迹（任一命中即标记），返回伪迹异常段列表与逐样本掩码。
    本模块只检测并标注，不修改信号。
    """
    values = signal.values
    if not config.enabled:
        empty = np.zeros(values.shape, dtype=np.bool_)
        return ArtifactReport(segments=(), artifact_mask=empty)

    artifact_mask = _detect_artifacts(
        values,
        layout.sample_rate_hz,
        config.jump_ratio,
        config.high_freq_hz,
        config.high_freq_ratio,
    )
    segments = _extract_segments(artifact_mask, layout.channel_names, signal.timestamps_ns, ARTIFACT)
    return ArtifactReport(
        segments=tuple(segments),
        artifact_mask=np.ascontiguousarray(artifact_mask),
    )


def _detect_artifacts(
    values: NDArray[np.float32],
    sample_rate_hz: float,
    jump_ratio: float,
    high_freq_hz: float,
    high_freq_ratio: float,
) -> NDArray[np.bool_]:
    """伪迹检测：跳变伪迹 + 高频能量伪迹组合（任一命中即标记）。"""
    jump_mask = _detect_jumps(values, jump_ratio)
    high_freq_mask = _detect_high_freq(values, sample_rate_hz, high_freq_hz, high_freq_ratio)
    return jump_mask | high_freq_mask


def _detect_jumps(
    values: NDArray[np.float32],
    jump_ratio: float,
) -> NDArray[np.bool_]:
    """跳变/尖峰伪迹：一阶差分超过中位数差分的 jump_ratio 倍。"""
    mask = np.zeros(values.shape, dtype=np.bool_)
    if values.shape[1] < 2:
        return mask
    ratio = float(jump_ratio)
    if ratio <= 0:
        return mask
    for c in range(values.shape[0]):
        x = values[c]
        diff = np.abs(np.diff(x))
        median_diff = float(np.median(diff))
        if median_diff <= 0:
            continue
        jump = diff > ratio * median_diff
        idx = np.flatnonzero(jump)
        if idx.size:
            mask[c, idx + 1] = True  # 跳变发生处的样本
    return mask


def _detect_high_freq(
    values: NDArray[np.float32],
    sample_rate_hz: float,
    high_freq_hz: float,
    high_freq_ratio: float,
) -> NDArray[np.bool_]:
    """高频能量伪迹：1 秒窗口内高通分量能量占比超过 high_freq_ratio。"""
    mask = np.zeros(values.shape, dtype=np.bool_)
    n_channels, n_samples = values.shape
    nyquist = sample_rate_hz / 2.0
    if n_samples < 2 or not 0 < high_freq_hz < nyquist:
        return mask
    sos = highpass_sos(high_freq_hz, sample_rate_hz)
    window = max(1, int(round(sample_rate_hz)))
    ratio = float(high_freq_ratio)
    for c in range(n_channels):
        x = values[c]
        try:
            hf = scipy_signal.sosfiltfilt(sos, x)
        except ValueError:
            continue
        for start in range(0, n_samples, window):
            end = min(start + window, n_samples)
            orig_energy = float(np.sum(x[start:end] ** 2))
            hf_energy = float(np.sum(hf[start:end] ** 2))
            if orig_energy > 0 and (hf_energy / orig_energy) > ratio:
                mask[c, start:end] = True
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
