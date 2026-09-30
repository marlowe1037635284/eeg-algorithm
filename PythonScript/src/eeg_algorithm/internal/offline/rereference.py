from __future__ import annotations

import numpy as np

from eeg_algorithm.types import ChannelLayout, OfflineReferenceConfig, ReferenceConfig, SignalBlock

from eeg_algorithm.internal.common.array_utils import copy_block
from eeg_algorithm.internal.online.rereference import ReReferencer


def rereference_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: OfflineReferenceConfig,
) -> SignalBlock:
    if not config.enabled:
        return copy_block(signal)
    processor = ReReferencer(ReferenceConfig(config.method, config.mastoid_channels), layout)
    return copy_block(signal, np.ascontiguousarray(processor.process_block(signal.values), dtype=np.float32))

