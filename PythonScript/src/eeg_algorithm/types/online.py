from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import numpy as np
from numpy.typing import NDArray

from .common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from .enums import BandPreset, QualityFlag, ReferenceMethod, SessionState

if TYPE_CHECKING:
    from eeg_algorithm.errors import AlgorithmErrorInfo


@dataclass(frozen=True)
class ToggleFilterConfig:
    enabled: bool
    low_hz: float | None = None
    high_hz: float | None = None
    order: int = 4


@dataclass(frozen=True)
class OnlineProcessingConfig:
    config_version: int
    high_pass: ToggleFilterConfig
    low_pass: ToggleFilterConfig
    notch: ToggleFilterConfig
    asr_enabled: bool


@dataclass(frozen=True)
class ReferenceConfig:
    method: ReferenceMethod = ReferenceMethod.OFF
    mastoid_channels: tuple[str, ...] = ()


@dataclass(frozen=True)
class AsrConfig:
    cutoff: float = 20.0
    window_s: float | None = None
    overlap_ratio: float | None = None
    reference_duration_s: float | None = None


@dataclass(frozen=True)
class PhaseModelConfig:
    enabled: bool
    model_path: str
    target_channels: tuple[str, ...]
    device: str = "cpu"
    window_samples: int = 1


@dataclass(frozen=True)
class OnlineConfig:
    layout: ChannelLayout
    processing: OnlineProcessingConfig
    reference: ReferenceConfig
    asr: AsrConfig
    phase: PhaseModelConfig
    rolling_window_s: float
    return_processed_signal: bool = True


@dataclass(frozen=True)
class FrequencyBand:
    preset: BandPreset
    low_hz: float
    high_hz: float


@dataclass(frozen=True)
class TopographyQuery:
    request_id: int
    band: FrequencyBand
    window_s: float | None = None
    time_range: AbsoluteTimeRange | None = None
    grid_width: int = 64
    grid_height: int = 64


@dataclass(frozen=True)
class SpectrumQuery:
    request_id: int
    channel_name: str
    band: FrequencyBand
    window_s: float


@dataclass(frozen=True)
class PhaseValue:
    channel_name: str
    phase_rad: float
    valid: bool
    confidence: float | None = None


@dataclass(frozen=True)
class PhaseResult:
    sequence_id: int
    timestamp_ns: int
    values: tuple[PhaseValue, ...]
    processing_time_us: int
    quality_flags: tuple[QualityFlag, ...]


@dataclass(frozen=True)
class OnlineResult:
    config_version: int
    first_sequence_id: int
    last_sequence_id: int
    processed_signal: SignalBlock | None
    phase_results: tuple[PhaseResult, ...]
    quality_flags: tuple[QualityFlag, ...]
    processing_time_us: int


@dataclass(frozen=True)
class ConfigUpdateResult:
    config_version: int
    effective_sequence_id: int
    rolling_buffer_cleared: bool
    asr_refit_required: bool
    warmup_required: bool


@dataclass(frozen=True)
class TopographyResult:
    request_id: int
    config_version: int
    band: FrequencyBand
    actual_time_range: AbsoluteTimeRange
    grid_x: NDArray[np.float32]
    grid_y: NDArray[np.float32]
    grid_values: NDArray[np.float32]
    head_mask: NDArray[np.bool_]
    electrode_values: NDArray[np.float32]
    electrode_names: tuple[str, ...]
    peak_electrode: str
    peak_rms: float
    mean_rms: float

@dataclass(frozen=True)
class SpectrumResult:
    request_id: int
    config_version: int
    channel_name: str
    band: FrequencyBand
    actual_time_range: AbsoluteTimeRange
    frequencies_hz: NDArray[np.float32]
    psd: NDArray[np.float32]
    peak_frequencies_hz: dict[str, float | None]

@dataclass(frozen=True)
class SessionStatus:
    state: SessionState
    config_version: int
    last_processed_sequence_id: int | None
    average_processing_time_us: float
    p99_processing_time_us: float
    max_processing_time_us: int
    gap_count: int
    timeout_count: int
    warmup_remaining_samples: int
    rolling_buffer_duration_s: float
    last_error: AlgorithmErrorInfo | None

