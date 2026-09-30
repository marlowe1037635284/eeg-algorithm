from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.errors import CHANNEL_LAYOUT_MISMATCH, algorithm_error
from eeg_algorithm.types import ChannelLayout, ReferenceConfig, ReferenceMethod


class ReReferencer:
    def __init__(self, config: ReferenceConfig, layout: ChannelLayout) -> None:
        self._method = config.method
        self._mastoid_indices: tuple[int, ...] = ()
        if config.method is ReferenceMethod.BILATERAL_MASTOIDS:
            if len(config.mastoid_channels) != 2:
                raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "双侧乳突重参考必须指定两个通道", "ReReferencer")
            try:
                self._mastoid_indices = tuple(layout.channel_names.index(name) for name in config.mastoid_channels)
            except ValueError as exc:
                raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "乳突通道不存在", "ReReferencer") from exc

    def process_sample(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        return self.process_block(values[:, None])[:, 0]

    def process_block(self, values: NDArray[np.float32]) -> NDArray[np.float32]:
        if self._method is ReferenceMethod.OFF:
            return np.ascontiguousarray(values, dtype=np.float32)
        if self._method is ReferenceMethod.COMMON_AVERAGE:
            reference = np.mean(values, axis=0, keepdims=True)
        else:
            reference = np.mean(values[list(self._mastoid_indices), :], axis=0, keepdims=True)
        return np.ascontiguousarray(values - reference, dtype=np.float32)

