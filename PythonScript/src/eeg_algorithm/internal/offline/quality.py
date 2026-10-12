from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy.interpolate import PchipInterpolator
from scipy.stats import rankdata

from eeg_algorithm.types import (
    ArtifactSegment,
    ChannelLayout,
    QualityControlConfig,
    QualityReport,
    SignalBlock,
)

from eeg_algorithm.internal.common.array_utils import copy_block
from eeg_algorithm.internal.observability.context import get_logger

_logger = get_logger(__name__)

# 异常类型标识（用于界面按类型区分标注）
NULL_VALUE = "null_value"
WEAK_SIGNAL = "weak_signal"
AMPLITUDE_OUTLIER = "amplitude_outlier"
LOW_CORRELATION = "low_correlation"

# ============================================================
# 电极分级（16 / 8 / 4）与固定邻居表（对齐 qc.py）
# ============================================================
FIXED_16_TARGET = ['Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4',
                   'O1', 'O2', 'F7', 'F8', 'T7', 'T8', 'Fz', 'Cz']
FIXED_8_TARGET = ['Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4']
FIXED_4_TARGET = ['F3', 'F4', 'P3', 'P4']
TARGET_BY_MODE = {4: FIXED_4_TARGET, 8: FIXED_8_TARGET, 16: FIXED_16_TARGET}
MODE_LADDER = (16, 8, 4)

NEIGHBOR_4 = {
    "F3": ["F4", "P3"],
    "F4": ["F3", "P4"],
    "P3": ["P4", "F3"],
    "P4": ["P3", "F4"],
}

NEIGHBOR_8 = {
    "FP1": ["FP2", "F3"],
    "FP2": ["FP1", "F4"],
    "F3": ["FP1", "F4", "C3"],
    "F4": ["FP2", "F3", "C4"],
    "C3": ["F3", "C4", "P3"],
    "C4": ["F4", "C3", "P4"],
    "P3": ["C3", "P4"],
    "P4": ["C4", "P3"],
}

NEIGHBOR_16 = {
    "FP1": ["FP2", "F7", "F3"],
    "FP2": ["FP1", "F4", "F8"],
    "F7": ["FP1", "F3", "T7"],
    "F3": ["FP1", "FZ", "F7", "C3"],
    "FZ": ["F3", "F4", "CZ"],
    "F4": ["FP2", "F8", "FZ", "C4"],
    "F8": ["FP2", "F4", "T8"],
    "T7": ["F7", "C3", "P3"],
    "C3": ["F3", "CZ", "T7", "P3"],
    "CZ": ["C3", "C4", "FZ"],
    "C4": ["F4", "CZ", "T8", "P4"],
    "T8": ["F8", "C4", "P4"],
    "P3": ["C3", "T7", "O1"],
    "P4": ["C4", "T8", "O2"],
    "O1": ["O2", "P3"],
    "O2": ["O1", "P4"],
}

NEIGHBOR_TABLE_BY_MODE = {
    4: NEIGHBOR_4,
    8: NEIGHBOR_8,
    16: NEIGHBOR_16,
}

# 通道名归一化时当作"参考电极"而剥离的尾部标记
REFERENCE_TOKENS = {'M1', 'M2', 'A1', 'A2', 'REF', 'AVG', 'CZ', 'FZ', 'PZ', 'LM', 'RM'}


def _strip_reference(name: str) -> str:
    """把 'F3-M2' / 'C4-M1' 归一化成 'F3' / 'C4'。"""
    name = str(name).strip()
    if '-' in name:
        head, _, tail = name.rpartition('-')
        if head.strip() and tail.strip().upper() in REFERENCE_TOKENS:
            return head.strip()
    return name


def _match_target_tier(ch_names: tuple[str, ...]) -> int | None:
    """按 16 → 8 → 4 依次匹配，返回被完整满足的最大一级，否则 None。"""
    upper = {str(c).upper().strip() for c in ch_names}
    for mode in MODE_LADDER:
        target = TARGET_BY_MODE[mode]
        if {t.upper() for t in target}.issubset(upper):
            return mode
    return None


def _build_neighbor_indices(ch_names: tuple[str, ...]) -> list[list[int]] | None:
    """按数据实际电极匹配分级，构建每个通道的邻居索引；无匹配返回 None。"""
    normalized = [_strip_reference(c).upper().strip() for c in ch_names]
    mode = _match_target_tier(tuple(normalized))
    if mode is None:
        return None
    table = NEIGHBOR_TABLE_BY_MODE[mode]
    result: list[list[int]] = []
    for name in normalized:
        if name in table:
            idx_list = [normalized.index(nb) for nb in table[name] if nb in normalized]
            result.append(idx_list if len(idx_list) >= 2 else [])
        else:
            result.append([])
    return result


def detect_quality(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: QualityControlConfig,
) -> QualityReport:
    """只执行质检检测（不修改信号），返回质检报告。"""
    null_mask, weak_mask, amplitude_mask, correlation_mask = _detect_all(
        signal.values, layout, config
    )
    return _build_report(
        signal, layout, null_mask, weak_mask, amplitude_mask, correlation_mask,
        repaired=False,
    )


def run_quality_control(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: QualityControlConfig,
) -> tuple[SignalBlock, QualityReport]:
    """执行离线质检，可选插值修复（算法对齐 qc.py）。

    始终返回质检报告；repair_enabled 为 True 时对空值与超范围样本做
    PCHIP/linear 插值修复并返回修复后的信号。
    """
    values = signal.values
    null_mask, weak_mask, amplitude_mask, correlation_mask = _detect_all(
        values, layout, config
    )

    if config.repair_enabled:
        bad_channels = _bad_channels(weak_mask, correlation_mask)
        values = _repair(values, layout.sample_rate_hz, config, bad_channels)

    report = _build_report(
        signal, layout, null_mask, weak_mask, amplitude_mask, correlation_mask,
        repaired=config.repair_enabled,
    )
    return copy_block(signal, values), report


def _detect_all(
    values: NDArray[np.float32],
    layout: ChannelLayout,
    config: QualityControlConfig,
) -> tuple[NDArray[np.bool_], NDArray[np.bool_], NDArray[np.bool_], NDArray[np.bool_]]:
    empty = np.zeros(values.shape, dtype=np.bool_)

    if config.null_weak_enabled:
        null_mask = _detect_null(values, config.nan_ratio_threshold)
        weak_mask = _detect_weak_signal(
            values, config.flat_var_threshold, config.weak_std_threshold, config.weak_ptp_threshold
        )
    else:
        null_mask = empty
        weak_mask = empty

    amplitude_mask = (
        _detect_amplitude_outliers(values, config.eeg_range, config.abnormal_ratio_threshold)
        if config.amplitude_outlier_enabled
        else empty
    )
    correlation_mask = (
        _detect_low_correlation(values, layout, config.correlation_threshold, config.corr_method)
        if config.low_correlation_enabled
        else empty
    )

    return null_mask, weak_mask, amplitude_mask, correlation_mask


def _build_report(
    signal: SignalBlock,
    layout: ChannelLayout,
    null_mask: NDArray[np.bool_],
    weak_mask: NDArray[np.bool_],
    amplitude_mask: NDArray[np.bool_],
    correlation_mask: NDArray[np.bool_],
    repaired: bool,
) -> QualityReport:
    combined = null_mask | weak_mask | amplitude_mask | correlation_mask

    segments: list[ArtifactSegment] = []
    segments += _extract_segments(null_mask, layout.channel_names, signal.timestamps_ns, NULL_VALUE)
    segments += _extract_segments(weak_mask, layout.channel_names, signal.timestamps_ns, WEAK_SIGNAL)
    segments += _extract_segments(amplitude_mask, layout.channel_names, signal.timestamps_ns, AMPLITUDE_OUTLIER)
    segments += _extract_segments(correlation_mask, layout.channel_names, signal.timestamps_ns, LOW_CORRELATION)

    return QualityReport(
        segments=tuple(segments),
        artifact_mask=np.ascontiguousarray(combined),
        repaired=repaired,
    )


def _detect_null(values: NDArray[np.float32], nan_ratio_threshold: float) -> NDArray[np.bool_]:
    """空值检测：NaN/Inf 样本；仅对通道级空值比例超阈值的通道标注。"""
    null = ~np.isfinite(values)
    if nan_ratio_threshold <= 0:
        return null
    mask = np.zeros(values.shape, dtype=np.bool_)
    ratio = null.mean(axis=1)
    for c in range(values.shape[0]):
        if ratio[c] > nan_ratio_threshold:
            mask[c] = null[c]
    return mask


def _detect_weak_signal(
    values: NDArray[np.float32],
    flat_var_threshold: float,
    weak_std_threshold: float,
    weak_ptp_threshold: float,
) -> NDArray[np.bool_]:
    """弱信号/平线检测（三口径）：方差/标准差/峰峰值任一低于阈值即整通道异常。"""
    n_ch, n_samples = values.shape
    mask = np.zeros(values.shape, dtype=np.bool_)
    if n_samples == 0:
        return mask
    var = np.nanvar(values, axis=1)
    std = np.nanstd(values, axis=1)
    ptp = np.nanmax(values, axis=1) - np.nanmin(values, axis=1)
    for c in range(n_ch):
        if (not np.isnan(var[c]) and var[c] < flat_var_threshold) or \
           (not np.isnan(std[c]) and std[c] < weak_std_threshold) or \
           (not np.isnan(ptp[c]) and ptp[c] < weak_ptp_threshold):
            mask[c] = True
    return mask


def _detect_amplitude_outliers(
    values: NDArray[np.float32],
    eeg_range: tuple[float, float],
    abnormal_ratio_threshold: float,
) -> NDArray[np.bool_]:
    """异常 EEG 范围外值：|x| 落在 eeg_range 之外，且通道级比例超阈值时标注。"""
    low, high = eeg_range
    abnormal = (values < low) | (values > high)
    mask = np.zeros(values.shape, dtype=np.bool_)
    ratio = abnormal.mean(axis=1)
    for c in range(values.shape[0]):
        if ratio[c] > abnormal_ratio_threshold:
            mask[c] = abnormal[c]
    return mask


def _detect_low_correlation(
    values: NDArray[np.float32],
    layout: ChannelLayout,
    correlation_threshold: float,
    corr_method: str,
) -> NDArray[np.bool_]:
    """低相关性导联：按固定邻居表取邻居相关系数绝对值中位数，低于阈值整通道异常。"""
    n_ch, n_samples = values.shape
    mask = np.zeros(values.shape, dtype=np.bool_)
    if n_ch < 2 or n_samples < 2:
        return mask
    neighbor_indices = _build_neighbor_indices(layout.channel_names)
    if neighbor_indices is None:
        return mask  # 非目标数据：无适用邻居布局，跳过低相关判定
    corr_stat = _compute_corr_stat(values, neighbor_indices, corr_method)
    for c in range(n_ch):
        if (not np.isnan(corr_stat[c])) and corr_stat[c] < correlation_threshold:
            mask[c] = True
    return mask


def _compute_corr_stat(
    values: NDArray[np.float32],
    neighbor_indices: list[list[int]],
    corr_method: str,
) -> NDArray[np.float64]:
    """每个通道取邻居相关系数（绝对值）的中位数；无邻居/无有效值保持 NaN。"""
    n_ch = values.shape[0]
    corr_vals = np.full(n_ch, np.nan)
    corr_mat = _corr_matrix(values, corr_method)
    np.fill_diagonal(corr_mat, np.nan)
    corr_mat = np.abs(corr_mat)
    for i in range(n_ch):
        nbr = neighbor_indices[i] if i < len(neighbor_indices) else []
        if len(nbr) == 0:
            continue
        others = corr_mat[i, nbr]
        valid = others[~np.isnan(others)]
        if len(valid) == 0:
            continue
        corr_vals[i] = float(np.median(valid))
    return corr_vals


def _corr_matrix(values: NDArray[np.float32], corr_method: str) -> NDArray[np.float64]:
    """通道间相关矩阵（pearson 或 spearman）；含 NaN 的通道整行整列保持 NaN。"""
    n_ch = values.shape[0]
    corr = np.full((n_ch, n_ch), np.nan)
    valid_ch = ~np.isnan(values).any(axis=1)
    if int(valid_ch.sum()) < 2:
        return corr
    d = values[valid_ch]
    if corr_method == "spearman":
        ranks = rankdata(d, axis=1)
        with np.errstate(divide="ignore", invalid="ignore"):
            z = (ranks - ranks.mean(axis=1, keepdims=True)) / ranks.std(axis=1, ddof=1, keepdims=True)
        m = z @ z.T / (d.shape[1] - 1)
    else:
        m = np.corrcoef(d)
    corr[np.ix_(valid_ch, valid_ch)] = m
    return corr


def _bad_channels(
    weak_mask: NDArray[np.bool_],
    correlation_mask: NDArray[np.bool_],
) -> set[int]:
    """弱信号 / 低相关坏导（整通道异常）的通道索引集合。"""
    bad: set[int] = set()
    for c in range(weak_mask.shape[0]):
        if weak_mask[c].any() or correlation_mask[c].any():
            bad.add(c)
    return bad


def _repair(
    values: NDArray[np.float32],
    sample_rate_hz: float,
    config: QualityControlConfig,
    bad_channels: set[int],
) -> NDArray[np.float32]:
    """按 qc.py 修复算法：只对空值与超范围样本插值，弱信号/低相关坏导不被插值。"""
    repaired = values.astype(np.float64).copy()
    low, high = config.eeg_range
    total_over_warn = 0
    for c in range(values.shape[0]):
        if (c in bad_channels) and (not config.repair_bad_channels):
            continue
        repaired[c], over_warn = _repair_channel(
            repaired[c], low, high, sample_rate_hz, config.interp_method, config.interp_warn_ms
        )
        total_over_warn += over_warn
    if total_over_warn:
        _logger.warning(
            "质检修复：有 %d 处缺口超过 %.0f ms 告警线（仍按 %s 插值填充）",
            total_over_warn, config.interp_warn_ms, config.interp_method,
        )
    return repaired.astype(np.float32)


def _repair_channel(
    x: NDArray[np.float64],
    low: float,
    high: float,
    sample_rate_hz: float,
    interp_method: str,
    interp_warn_ms: float,
) -> tuple[NDArray[np.float64], int]:
    """单通道时间轴插值：空值+超范围置 NaN，PCHIP/linear 插值，首尾不外推。"""
    n = x.size
    x = x.copy()
    x[~np.isfinite(x)] = np.nan
    x[(x < low) | (x > high)] = np.nan

    valid = ~np.isnan(x)
    if valid.sum() < 2:
        return x, 0

    idx = np.arange(n)
    first, last = int(idx[valid][0]), int(idx[valid][-1])

    if interp_method == "pchip":
        f = PchipInterpolator(idx[valid], x[valid])
        x_interp = np.asarray(f(idx), dtype=float)
    else:
        x_interp = np.interp(idx, idx[valid], x[valid])

    # 首尾缺口不做外推（PCHIP 外推会爆炸），改用边缘值
    before = idx < first
    after = idx > last
    if before.any():
        x_interp[before] = x[valid][0]
    if after.any():
        x_interp[after] = x[valid][-1]

    x_final = x.copy()
    warn_samples = None
    if interp_warn_ms is not None:
        warn_samples = interp_warn_ms / 1000.0 * sample_rate_hz
    over_warn = 0
    for st, ln in _iter_gaps(~valid):
        x_final[st:st + ln] = x_interp[st:st + ln]
        if warn_samples is not None and ln > warn_samples:
            over_warn += 1
    return x_final, over_warn


def _iter_gaps(mask_1d: NDArray[np.bool_]):
    """迭代 1D 布尔掩码里的连续 True 段，产出 (起始下标, 长度)。"""
    if not mask_1d.any():
        return
    v = np.concatenate(([0], mask_1d.view(np.int8), [0]))
    idx = np.flatnonzero(np.diff(v))
    for st, en in zip(idx[::2], idx[1::2]):
        yield int(st), int(en - st)


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
