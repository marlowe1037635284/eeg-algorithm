from __future__ import annotations

import numpy as np
from numpy.typing import NDArray


from eeg_algorithm.types import (
    ArtifactDetectionConfig,
    ArtifactReport,
    ArtifactSegment,
    ChannelLayout,
    SignalBlock,
)

from scipy.signal import detrend, welch

# 伪迹异常类型标识（用于界面按类型区分标注）
ARTIFACT = "artifact"
# 第一步：阈值候选
ENABLE_AMPLITUDE = True
BASELINE_SEC = 0.5
UPDATE_SEC = 0.5
K_SIGMA = 5.0
MIN_STD_UV = 1.0
MERGE_GAP_SEC = 0.08

# 第二步：持续时间
ENABLE_DURATION = True
MIN_DURATION_SEC = 0.10
MAX_DURATION_SEC = 0.50

# 第三步：低频功率占比
ENABLE_SPECTRUM = True
SPECTRUM_LOW_HZ = 0.5
SPECTRUM_HIGH_HZ = 5.0
SPECTRUM_TOTAL_HIGH_HZ = 30.0
MIN_LOW_POWER_RATIO = 0.60
SPECTRUM_WINDOW_SEC = 2.0

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
    )
    segments = _extract_segments(artifact_mask, layout.channel_names, signal.timestamps_ns, ARTIFACT)
    return ArtifactReport(
        segments=tuple(segments),
        artifact_mask=np.ascontiguousarray(artifact_mask),
    )


def _detect_artifacts(
    values: NDArray[np.float32],
    sample_rate_hz: float,
) -> NDArray[np.bool_]:
    mask = np.zeros(values.shape, dtype=np.bool_)

    for c in range(values.shape[0]):
        x = np.asarray(values[c], dtype=np.float64)

        # 第一步：阈值候选，内部包含80 ms间隔合并。
        candidates = _detect_amplitude_candidates(x, sample_rate_hz)

        # 第二步：持续时间筛选。
        if ENABLE_DURATION:
            candidates = _filter_duration(candidates, sample_rate_hz)

        # 第三步：频谱筛选。
        if ENABLE_SPECTRUM:
            candidates = _filter_spectrum(x, candidates, sample_rate_hz)

        # 只有最终通过的候选，才写入掩码。
        for start, end in candidates:
            mask[c, start:end] = True

    return mask

def _detect_amplitude_candidates(x, fs):
    base_n = max(4, round(BASELINE_SEC * fs))
    block_n = max(1, round(UPDATE_SEC * fs))

    if len(x) <= base_n:
        return []

    mu = float(np.mean(x[:base_n]))
    sigma = max(float(np.std(x[:base_n])), MIN_STD_UV)
    flags = np.zeros(len(x), dtype=np.bool_)

    # 与上传脚本一致：False仍以2σ生成候选。
    k = K_SIGMA if ENABLE_AMPLITUDE else 2.0

    for left in range(base_n, len(x), block_n):
        right = min(len(x), left + block_n)
        abnormal = np.abs(x[left:right] - mu) > k * sigma
        flags[left:right] = abnormal

        # 整块没有超阈值点，才更新背景。
        if not abnormal.any() and right - left >= 4:
            mu = float(np.mean(x[left:right]))
            sigma = max(
                float(np.std(x[left:right])),
                MIN_STD_UV,
            )

    # 将连续True转成候选区间[start, end)。
    edges = np.diff(
        np.r_[False, flags, False].astype(np.int8)
    )
    starts = np.flatnonzero(edges == 1)
    ends = np.flatnonzero(edges == -1)

    # 合并间隔不超过80 ms的候选。
    gap = round(MERGE_GAP_SEC * fs)
    candidates = []

    for start, end in zip(starts, ends):
        start, end = int(start), int(end)

        if candidates and start - candidates[-1][1] <= gap:
            candidates[-1] = (candidates[-1][0], end)
        else:
            candidates.append((start, end))

    return candidates


def _filter_duration(candidates, fs):
    return [
        (start, end)
        for start, end in candidates
        if MIN_DURATION_SEC <= (end - start) / fs
        <= MAX_DURATION_SEC
    ]


def _filter_spectrum(x, candidates, fs):
    accepted = []
    win = max(16, round(SPECTRUM_WINDOW_SEC * fs))

    if len(x) < win:
        return accepted

    for start, end in candidates:
        mid = (start + end) // 2

        # 尽量以候选中心取窗；靠近边缘时向记录内部移动。
        left = max(0, min(mid - win // 2, len(x) - win))
        chunk = x[left:left + win]

        # 保留上传脚本的线性去趋势、Welch和补零设置。
        frequencies, psd = welch(
            detrend(chunk, type="linear"),
            fs=fs,
            nperseg=len(chunk),
            nfft=max(len(chunk), round(4 * fs)),
        )

        low_mask = (
            (frequencies >= SPECTRUM_LOW_HZ)
            & (frequencies <= SPECTRUM_HIGH_HZ)
        )
        total_mask = (
            (frequencies >= SPECTRUM_LOW_HZ)
            & (frequencies <= SPECTRUM_TOTAL_HIGH_HZ)
        )

        denominator = float(np.sum(psd[total_mask]))

        if denominator > 0:
            ratio = float(np.sum(psd[low_mask])) / denominator
            if ratio >= MIN_LOW_POWER_RATIO:
                accepted.append((start, end))

    return accepted

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
