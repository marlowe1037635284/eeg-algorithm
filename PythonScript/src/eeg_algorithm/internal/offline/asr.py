from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import ASR_REFERENCE_REQUIRED, INVALID_ARGUMENT, algorithm_error
from eeg_algorithm.types import ChannelLayout, OfflineAsrConfig, SignalBlock

from eeg_algorithm.internal.common.array_utils import copy_block


def asr_clean_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: OfflineAsrConfig,
) -> SignalBlock:
    """Reference-statistics baseline behind the replaceable offline ASR boundary."""
    if not config.enabled:
        return copy_block(signal)
    if config.cutoff <= 0:
        raise algorithm_error(INVALID_ARGUMENT, "ASR cutoff必须大于0", "asr_clean_offline")
    if config.reference_range is None:
        reference = signal.values
    else:
        mask = (signal.timestamps_ns >= config.reference_range.start_timestamp_ns) & (
            signal.timestamps_ns <= config.reference_range.end_timestamp_ns
        )
        if not np.any(mask):
            raise algorithm_error(ASR_REFERENCE_REQUIRED, "ASR参考时间范围没有数据", "asr_clean_offline")
        reference = signal.values[:, mask]
    if reference.shape[1] < max(4, int(round(layout.sample_rate_hz))):
        raise algorithm_error(ASR_REFERENCE_REQUIRED, "ASR参考数据过短", "asr_clean_offline")
    mean = np.mean(reference, axis=1, dtype=np.float64)
    std = np.std(reference, axis=1, dtype=np.float64)
    std = np.maximum(std, np.maximum(np.abs(mean) * 1e-6, 1e-6))
    cleaned = np.clip(
        signal.values,
        mean[:, None] - config.cutoff * std[:, None],
        mean[:, None] + config.cutoff * std[:, None],
    )
    return copy_block(signal, np.asarray(cleaned, dtype=np.float32))

