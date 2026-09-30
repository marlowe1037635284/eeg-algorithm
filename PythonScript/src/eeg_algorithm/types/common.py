from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray


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
    values: NDArray[np.float32]


@dataclass(frozen=True)
class SignalBlock:
    first_sequence_id: int
    timestamps_ns: NDArray[np.int64]
    values: NDArray[np.float32]


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

