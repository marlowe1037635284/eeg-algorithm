"""在线重参考：OFF、双侧乳突、全脑平均。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.types.common import ChannelLayout
from eeg_algorithm.types.enums import ReferenceMethod
from eeg_algorithm.types.online import ReferenceConfig


class ReReferencer:
    """无历史状态。单点与数据块处理必须产生一致的逐采样结果。"""

    def __init__(self, config: ReferenceConfig, layout: ChannelLayout) -> None:
        self._config = config
        self._mastoid_indices: list[int] = []
        if config.method == ReferenceMethod.BILATERAL_MASTOIDS:
            names = set(config.mastoid_channels)
            self._mastoid_indices = [
                i for i, name in enumerate(layout.channel_names) if name in names
            ]

    def process_sample(self, values: np.ndarray) -> np.ndarray:
        return self._apply(values)

    def process_block(self, values: np.ndarray) -> np.ndarray:
        return self._apply(values)

    def _apply(self, values: np.ndarray) -> np.ndarray:
        method = self._config.method
        if method == ReferenceMethod.OFF:
            return values
        if method == ReferenceMethod.COMMON_AVERAGE:
            ref = values.mean(axis=0, keepdims=True)
            return values - ref
        if method == ReferenceMethod.BILATERAL_MASTOIDS:
            if not self._mastoid_indices:
                return values
            ref = values[self._mastoid_indices].mean(axis=0, keepdims=True)
            return values - ref
        return values
