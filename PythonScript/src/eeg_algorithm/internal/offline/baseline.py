"""离线基线校正。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.types.common import SignalBlock
from eeg_algorithm.types.offline import BaselineConfig


def baseline_correct_offline(
    signal: SignalBlock,
    config: BaselineConfig,
) -> SignalBlock:
    if not config.enabled:
        return signal
    rng = config.baseline_range
    values = signal.values
    if rng is None:
        baseline_mean = values.mean(axis=1, keepdims=True)
    else:
        ts = signal.timestamps_ns
        mask = (ts >= rng.start_timestamp_ns) & (ts < rng.end_timestamp_ns)
        if not mask.any():
            baseline_mean = values.mean(axis=1, keepdims=True)
        else:
            baseline_mean = values[:, mask].mean(axis=1, keepdims=True)
    corrected = values - baseline_mean
    return SignalBlock(signal.first_sequence_id, signal.timestamps_ns, corrected.astype(np.float32))
