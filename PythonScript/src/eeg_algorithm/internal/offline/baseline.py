from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import INVALID_ARGUMENT, TIME_RANGE_OUT_OF_RANGE, algorithm_error
from eeg_algorithm.types import BaselineConfig, SignalBlock

from eeg_algorithm.internal.common.array_utils import copy_block


def baseline_correct_offline(signal: SignalBlock, config: BaselineConfig) -> SignalBlock:
    if not config.enabled:
        return copy_block(signal)
    if config.baseline_range is None:
        raise algorithm_error(INVALID_ARGUMENT, "启用基线校正时必须指定baseline_range", "baseline_correct_offline")
    mask = (signal.timestamps_ns >= config.baseline_range.start_timestamp_ns) & (
        signal.timestamps_ns <= config.baseline_range.end_timestamp_ns
    )
    if not np.any(mask):
        raise algorithm_error(TIME_RANGE_OUT_OF_RANGE, "基线时间范围没有数据", "baseline_correct_offline")
    baseline = np.mean(signal.values[:, mask], axis=1, keepdims=True, dtype=np.float64)
    return copy_block(signal, signal.values - baseline)

