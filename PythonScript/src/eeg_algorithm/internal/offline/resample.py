from __future__ import annotations

from fractions import Fraction

import numpy as np
from scipy import signal as scipy_signal

from eeg_algorithm.errors import INVALID_SAMPLE_RATE, algorithm_error
from eeg_algorithm.types import ChannelLayout, ResampleConfig, SignalBlock


def resample_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: ResampleConfig,
) -> tuple[SignalBlock, ChannelLayout]:
    if not config.enabled or np.isclose(config.target_rate_hz, layout.sample_rate_hz):
        return signal, layout
    if not 0 < config.target_rate_hz <= layout.sample_rate_hz:
        raise algorithm_error(INVALID_SAMPLE_RATE, "目标采样率必须位于(0, 当前采样率]", "resample_offline")
    ratio = Fraction(config.target_rate_hz / layout.sample_rate_hz).limit_denominator(10_000)
    values = scipy_signal.resample_poly(signal.values, ratio.numerator, ratio.denominator, axis=1)
    count = values.shape[1]
    period_ns = 1_000_000_000.0 / config.target_rate_hz
    timestamps = np.rint(signal.timestamps_ns[0] + np.arange(count) * period_ns).astype(np.int64)
    new_layout = ChannelLayout(layout.channel_names, config.target_rate_hz, layout.positions, layout.unit)
    new_block = SignalBlock(
        signal.first_sequence_id,
        np.ascontiguousarray(timestamps),
        np.ascontiguousarray(values, dtype=np.float32),
    )
    return new_block, new_layout

