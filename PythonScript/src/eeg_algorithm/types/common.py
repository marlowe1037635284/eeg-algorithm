"""通用 DTO：通道、采样数据、时间范围与数据缺口。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.types.enums import BandPreset


@dataclass(frozen=True)
class ElectrodePosition:
    channel_name: str
    x: float
    y: float
    z: float
    coordinate_system: str


@dataclass(frozen=True)
class ChannelLayout:
    channel_names: tuple[str, ...]
    sample_rate_hz: float
    positions: tuple[ElectrodePosition, ...] = ()
    unit: str = "uV"


@dataclass(frozen=True)
class SampleFrame:
    sequence_id: int
    timestamp_ns: int
    values: NDArray[np.float32]  # [C]


@dataclass(frozen=True)
class SignalBlock:
    first_sequence_id: int
    timestamps_ns: NDArray[np.int64]  # [N]
    values: NDArray[np.float32]       # [C, N]


@dataclass(frozen=True)
class AbsoluteTimeRange:
    start_timestamp_ns: int
    end_timestamp_ns: int


@dataclass(frozen=True)
class GapInfo:
    first_missing_sequence_id: int
    last_missing_sequence_id: int
    start_timestamp_ns: int
    end_timestamp_ns: int
    reason: str


@dataclass(frozen=True)
class FrequencyBand:
    """频段查询参数，被在线与离线查询共用。"""

    preset: BandPreset
    low_hz: float
    high_hz: float
