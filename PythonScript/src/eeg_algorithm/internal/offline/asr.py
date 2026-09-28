"""离线 ASR 去伪迹（首版骨架，接口完整，透传信号）。"""

from __future__ import annotations

from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.offline import OfflineAsrConfig


def asr_clean_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: OfflineAsrConfig,
) -> SignalBlock:
    if not config.enabled:
        return signal
    # TODO: 实现完整 ASR 去伪迹算法，首版透传。
    return signal
