"""离线降采样。"""

from __future__ import annotations

import numpy as np
from scipy.signal import resample

from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.offline import ResampleConfig


def resample_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: ResampleConfig,
) -> tuple[SignalBlock, ChannelLayout]:
    if not config.enabled:
        return signal, layout
    src_rate = layout.sample_rate_hz
    target_rate = config.target_rate_hz
    n_src = signal.values.shape[1]
    n_out = max(1, int(round(n_src * target_rate / src_rate)))

    # 抗混叠重采样（FFT 方法）。
    values = resample(signal.values, n_out, axis=1).astype(np.float32)
    new_ts = np.linspace(
        signal.timestamps_ns[0], signal.timestamps_ns[-1], n_out
    ).astype(np.int64)

    new_layout = ChannelLayout(
        channel_names=layout.channel_names,
        sample_rate_hz=target_rate,
        positions=layout.positions,
        unit=layout.unit,
    )
    return SignalBlock(signal.first_sequence_id, new_ts, values), new_layout
