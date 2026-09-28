"""离线 DTO：预处理配置、查询、数据集、结果与状态。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.errors import AlgorithmErrorInfo
from eeg_algorithm.types.common import (
    AbsoluteTimeRange,
    ChannelLayout,
    FrequencyBand,
    SignalBlock,
)
from eeg_algorithm.types.enums import (
    OfflineSessionState,
    ReferenceMethod,
)


@dataclass(frozen=True)
class BandPassConfig:
    enabled: bool
    low_cut_hz: float
    high_cut_hz: float


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
class ResampleConfig:
    enabled: bool
    target_rate_hz: float


@dataclass(frozen=True)
class BaselineConfig:
    enabled: bool
    baseline_range: AbsoluteTimeRange | None = None


@dataclass(frozen=True)
class PreprocessConfig:
    preprocess_version: int
    band_pass: BandPassConfig
    notch: NotchConfig
    reference: OfflineReferenceConfig
    asr: OfflineAsrConfig
    resample: ResampleConfig
    baseline: BaselineConfig
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
    frequency_band: FrequencyBand
    grid_width: int = 64
    grid_height: int = 64


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


@dataclass(frozen=True)
class OfflineSpectrumResult:
    request_id: int
    preprocess_version: int
    channel_name: str
    selected_range: AbsoluteTimeRange
    frequencies_hz: NDArray[np.float32]  # [F]
    psd: NDArray[np.float32]             # [F]


@dataclass(frozen=True)
class OfflineTopographyResult:
    request_id: int
    preprocess_version: int
    frequency_band: FrequencyBand
    selected_range: AbsoluteTimeRange
    grid_x: NDArray[np.float32]            # [W]
    grid_y: NDArray[np.float32]            # [H]
    grid_values: NDArray[np.float32]       # [H, W]
    head_mask: NDArray[np.bool_]           # [H, W]
    electrode_values: NDArray[np.float32]  # [C]
    electrode_names: tuple[str, ...]


@dataclass(frozen=True)
class OfflineSessionStatus:
    state: OfflineSessionState
    preprocess_version: int | None
    raw_time_range: AbsoluteTimeRange
    preprocessed_time_range: AbsoluteTimeRange | None
    raw_sample_count: int
    preprocessed_sample_count: int | None
    last_error: AlgorithmErrorInfo | None
