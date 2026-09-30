from __future__ import annotations

import numpy as np
import pytest

from eeg_algorithm.types import ChannelLayout, ElectrodePosition, SignalBlock


@pytest.fixture
def layout() -> ChannelLayout:
    names = ("F3", "F4", "P3", "P4")
    positions = (
        ElectrodePosition("F3", -0.6, 0.6, 0.5, "unit_sphere"),
        ElectrodePosition("F4", 0.6, 0.6, 0.5, "unit_sphere"),
        ElectrodePosition("P3", -0.6, -0.6, 0.5, "unit_sphere"),
        ElectrodePosition("P4", 0.6, -0.6, 0.5, "unit_sphere"),
    )
    return ChannelLayout(names, 100.0, positions)


@pytest.fixture
def signal_block(layout: ChannelLayout) -> SignalBlock:
    count = 1000
    t = np.arange(count, dtype=np.float64) / layout.sample_rate_hz
    values = np.vstack(
        [
            np.sin(2 * np.pi * 10 * t),
            np.sin(2 * np.pi * 10 * t + 0.3),
            np.sin(2 * np.pi * 6 * t),
            np.sin(2 * np.pi * 20 * t),
        ]
    ).astype(np.float32)
    timestamps = np.rint(t * 1_000_000_000).astype(np.int64)
    return SignalBlock(0, np.ascontiguousarray(timestamps), np.ascontiguousarray(values))

