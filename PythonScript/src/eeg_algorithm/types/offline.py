from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

import numpy as np
from numpy.typing import NDArray

from .common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from .enums import OfflineSessionState, ReferenceMethod

if TYPE_CHECKING:
    from eeg_algorithm.errors import AlgorithmErrorInfo


@dataclass(frozen=True)
class HighPassConfig:
    enabled: bool
    cutoff_hz: float


@dataclass(frozen=True)
class LowPassConfig:
    enabled: bool
    cutoff_hz: float


@dataclass(frozen=True)
class NotchConfig:
    enabled: bool
    stop_low_hz: float = 48.0
    stop_high_hz: float = 52.0


@dataclass(frozen=True)
class OfflineReferenceConfig:
    enabled: bool
    method: ReferenceMethod = ReferenceMethod.OFF
    mastoid_channels: tuple[str, ...] = ()


@dataclass(frozen=True)
class OfflineAsrConfig:
    enabled: bool
    cutoff: float = 20.0
    window_s: float | None = None
    overlap_ratio: float | None = None
    reference_range: AbsoluteTimeRange | None = None


@dataclass(frozen=True)
class ArtifactDetectionConfig:
    """离线伪迹检测配置（与 ASR 去伪迹同级）。

    enabled: 是否执行伪迹检测（检测并返回伪迹异常段与掩码）。
    jump_ratio: 跳变阈值，一阶差分超过中位数差分的倍数，默认 5.0。
    high_freq_hz: 高频判定频率（Hz），默认 30.0。
    high_freq_ratio: 高频能量占比阈值，默认 0.5。
    """

    enabled: bool = True
    jump_ratio: float = 5.0
    high_freq_hz: float = 30.0
    high_freq_ratio: float = 0.5


@dataclass(frozen=True)
class ResampleConfig:
    enabled: bool
    target_rate_hz: float


@dataclass(frozen=True)
class QualityControlConfig:
    """离线质检与修复配置（检测/修复算法对齐 qc.py）。

    null_weak_enabled: 空值与弱信号检测开关（合并），默认 True。
    amplitude_outlier_enabled: 异常 EEG 范围外值检测开关，默认 True。
    low_correlation_enabled: 低相关性导联检测开关，默认 True。
    repair_enabled: 是否执行插值修复（off 仅标注，on 修复异常段），默认 False。

    空值:
    nan_ratio_threshold: 通道级空值比例阈值，默认 0.0。

    弱信号/平线（三口径）:
    flat_var_threshold: 平线判定方差阈值，默认 1e-3。
    weak_std_threshold: 弱信号标准差阈值（μV），默认 0.5。
    weak_ptp_threshold: 弱信号峰峰值阈值（μV），默认 5.0。

    超范围（绝对阈值）:
    eeg_range: EEG 幅度合法范围（μV），默认 (-100.0, 100.0)。
    abnormal_ratio_threshold: 通道级超范围样本比例阈值，默认 0.1。

    低相关（固定邻居表）:
    correlation_threshold: 邻居相关中位数阈值，默认 0.3。
    corr_method: 相关计算方法 spearman/pearson，默认 spearman。

    修复:
    interp_method: 插值方法 pchip/linear，默认 pchip。
    interp_warn_ms: 缺口超该时长告警（仍插值），默认 50.0。
    repair_bad_channels: 坏导也做时间维修复，默认 True。
    """

    null_weak_enabled: bool = True
    amplitude_outlier_enabled: bool = True
    low_correlation_enabled: bool = True
    repair_enabled: bool = False

    nan_ratio_threshold: float = 0.0

    flat_var_threshold: float = 1e-3
    weak_std_threshold: float = 0.5
    weak_ptp_threshold: float = 5.0

    eeg_range: tuple[float, float] = (-100.0, 100.0)
    abnormal_ratio_threshold: float = 0.1

    correlation_threshold: float = 0.3
    corr_method: str = "spearman"

    interp_method: str = "pchip"
    interp_warn_ms: float = 50.0
    repair_bad_channels: bool = True


@dataclass(frozen=True)
class ArtifactSegment:
    """单个异常数据段（用于界面标注）。"""

    channel_name: str
    artifact_type: str
    start_sample: int
    end_sample: int
    start_timestamp_ns: int
    end_timestamp_ns: int


@dataclass(frozen=True)
class ArtifactReport:
    """伪迹检测报告：异常段列表 + 逐样本掩码。"""

    segments: tuple[ArtifactSegment, ...]
    artifact_mask: NDArray[np.bool_]


@dataclass(frozen=True)
class QualityReport:
    """质检报告：异常段列表 + 逐样本掩码 + 是否已修复。"""

    segments: tuple[ArtifactSegment, ...]
    artifact_mask: NDArray[np.bool_]
    repaired: bool


@dataclass(frozen=True)
class PreprocessConfig:
    preprocess_version: int
    high_pass: HighPassConfig
    low_pass: LowPassConfig
    notch: NotchConfig
    reference: OfflineReferenceConfig
    asr: OfflineAsrConfig
    artifact: ArtifactDetectionConfig
    resample: ResampleConfig
    quality_control: QualityControlConfig = field(default_factory=QualityControlConfig)
    return_processed_signal: bool = True


@dataclass(frozen=True)
class OfflineSpectrumQuery:
    request_id: int
    preprocess_version: int
    channel_name: str
    selected_range: AbsoluteTimeRange
    frequency_range_hz: tuple[float, float] | None = None


@dataclass(frozen=True)
class OfflineTopographyQuery:
    request_id: int
    preprocess_version: int
    selected_range: AbsoluteTimeRange
    grid_width: int = 64
    grid_height: int = 64


@dataclass(frozen=True)
class OfflineStatisticsQuery:
    request_id: int
    preprocess_version: int
    selected_range: AbsoluteTimeRange


@dataclass(frozen=True)
class OfflineQualityQuery:
    request_id: int
    preprocess_version: int
    selected_range: AbsoluteTimeRange
    quality_control: QualityControlConfig


@dataclass(frozen=True)
class PreprocessedDataset:
    preprocess_version: int
    layout: ChannelLayout
    signal: SignalBlock
    actual_time_range: AbsoluteTimeRange
    applied_steps: tuple[str, ...]


@dataclass(frozen=True)
class PreprocessResult:
    preprocess_version: int
    layout: ChannelLayout
    actual_time_range: AbsoluteTimeRange
    sample_count: int
    processed_signal: SignalBlock | None
    applied_steps: tuple[str, ...]
    warnings: tuple[str, ...]
    quality_report: QualityReport | None = None
    artifact_report: ArtifactReport | None = None


@dataclass(frozen=True)
class OfflineSpectrumResult:
    request_id: int
    preprocess_version: int
    channel_name: str
    selected_range: AbsoluteTimeRange
    frequencies_hz: NDArray[np.float32]
    psd: NDArray[np.float32]


@dataclass(frozen=True)
class OfflineTopographyResult:
    """离线多频段脑电地形图结果（全频段 + δ/θ/α/β/γ 共 6 张）。

    grid_values 形状为 [6,H,W]，electrode_values 形状为 [6,C]，
    行顺序由 band_names 给出（full/delta/theta/alpha/beta/gamma）。
    """

    request_id: int
    preprocess_version: int
    selected_range: AbsoluteTimeRange
    band_names: tuple[str, ...]
    grid_x: NDArray[np.float32]
    grid_y: NDArray[np.float32]
    grid_values: NDArray[np.float32]
    head_mask: NDArray[np.bool_]
    electrode_values: NDArray[np.float32]
    electrode_names: tuple[str, ...]


@dataclass(frozen=True)
class OfflineStatisticsResult:
    """离线多通道统计指标结果（在预处理后选段数据上逐通道计算）。

    除 dominant_band 与 band_names 为名称外，其余字段均为长度等于通道数的 float32 数组；
    correlation_matrix 为 [C,C] 通道皮尔逊相关系数矩阵，band_energies 为 [C,5] 各频带能量。
    """

    request_id: int
    preprocess_version: int
    selected_range: AbsoluteTimeRange
    channel_names: tuple[str, ...]
    mean: NDArray[np.float32]
    std: NDArray[np.float32]
    rms: NDArray[np.float32]
    peak_to_peak: NDArray[np.float32]
    min_value: NDArray[np.float32]
    max_value: NDArray[np.float32]
    zero_crossing_rate: NDArray[np.float32]
    skewness: NDArray[np.float32]
    kurtosis: NDArray[np.float32]
    dominant_band: tuple[str, ...]
    correlation_matrix: NDArray[np.float32]
    band_names: tuple[str, ...]
    band_energies: NDArray[np.float32]


@dataclass(frozen=True)
class OfflineSessionStatus:
    state: OfflineSessionState
    preprocess_version: int | None
    raw_time_range: AbsoluteTimeRange
    preprocessed_time_range: AbsoluteTimeRange | None
    raw_sample_count: int
    preprocessed_sample_count: int | None
    last_error: AlgorithmErrorInfo | None
