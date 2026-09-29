"""在线 ASR（Artifact Subspace Reconstruction）处理器。

首版提供完整接口与状态管理骨架；完整 ASR 去伪迹算法（参考子空间投影）
在后续版本实现，当前在启用且参考有效时透传处理后的信号。
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.online import AsrConfig, OnlineProcessingConfig


class OnlineAsrProcessor:
    def __init__(self, config: AsrConfig, layout: ChannelLayout) -> None:
        self._config = config
        self._layout = layout
        self._enabled = False
        self._reference_data: np.ndarray | None = None  # [C, N]
        self._reference_matrix: np.ndarray | None = None

    def fit_reference(self, reference: SignalBlock) -> None:
        """保存参考数据与参考矩阵。"""
        self._reference_data = np.ascontiguousarray(reference.values, dtype=np.float32)
        # 首版参考矩阵：单位阵，表示尚未建立去伪迹子空间（TODO 完整 ASR）。
        c = self._reference_data.shape[0]
        self._reference_matrix = np.eye(c, dtype=np.float32)

    def refit_reference(self, processing: OnlineProcessingConfig) -> None:
        """前置滤波变化时，用保存的原始参考数据重新拟合。"""
        if self._reference_data is not None:
            ref = SignalBlock(
                first_sequence_id=0,
                timestamps_ns=np.zeros(self._reference_data.shape[1], dtype=np.int64),
                values=self._reference_data,
            )
            self.fit_reference(ref)

    def set_enabled(self, enabled: bool) -> None:
        self._enabled = enabled

    def process_sample(self, values: np.ndarray) -> np.ndarray:
        return self._process(values)

    def process_block(self, values: np.ndarray) -> np.ndarray:
        return self._process(values)

    def reset_stream_state(self) -> None:
        """只清空业务流窗口，不删除参考数据。"""
        # 首版无额外流窗口状态，保留接口。
        return None

    def _process(self, values: np.ndarray) -> np.ndarray:
        if not self._enabled or self._reference_matrix is None:
            return values
        # TODO: 使用参考子空间投影去除伪迹成分。
        return values
