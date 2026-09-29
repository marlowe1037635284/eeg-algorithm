"""离线重参考。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.enums import ReferenceMethod
from eeg_algorithm.types.offline import OfflineReferenceConfig


def rereference_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: OfflineReferenceConfig,
) -> SignalBlock:
    if not config.enabled:
        return signal
    values = signal.values
    if config.method == ReferenceMethod.COMMON_AVERAGE:
        ref = values.mean(axis=0, keepdims=True)
        values = values - ref
    elif config.method == ReferenceMethod.BILATERAL_MASTOIDS:
        names = set(config.mastoid_channels)
        indices = [i for i, name in enumerate(layout.channel_names) if name in names]
        if indices:
            ref = values[indices].mean(axis=0, keepdims=True)
            values = values - ref
    return SignalBlock(signal.first_sequence_id, signal.timestamps_ns, values.astype(np.float32))
