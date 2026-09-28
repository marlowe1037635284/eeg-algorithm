"""实时相位解码器。

首版提供模型加载与推理骨架。未提供模型或 PyTorch 不可用时，
返回 ``valid=False`` 与 ``WARMING_UP`` 标记。
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.types.common import ChannelLayout
from eeg_algorithm.types.enums import QualityFlag
from eeg_algorithm.types.online import PhaseModelConfig, PhaseResult, PhaseValue


class PhaseDecoder:
    def __init__(self, config: PhaseModelConfig, layout: ChannelLayout) -> None:
        self._config = config
        self._layout = layout
        self._enabled = config.enabled
        self._window_samples = max(1, config.window_samples)
        self._history: np.ndarray | None = None
        self._model = None
        if config.enabled:
            self._model = self._load_model()

    def _load_model(self):
        """加载 PyTorch 模型并进入 eval 模式。"""
        try:
            import torch  # noqa: F401
        except ImportError:
            return None
        # TODO: 从 self._config.model_path 加载模型并 eval()。
        return None

    def update_sample(
        self,
        values: np.ndarray,
        sequence_id: int,
        timestamp_ns: int,
    ) -> PhaseResult:
        return self._make_result(sequence_id, timestamp_ns, values)

    def update_block(
        self,
        values: np.ndarray,
        first_sequence_id: int,
        timestamps_ns: np.ndarray,
    ) -> tuple[PhaseResult, ...]:
        results = []
        for i in range(values.shape[1]):
            results.append(
                self._make_result(first_sequence_id + i, int(timestamps_ns[i]), values[:, i])
            )
        return tuple(results)

    def reset(self) -> None:
        self._history = None

    def close(self) -> None:
        self._model = None
        self._history = None

    def _make_result(
        self,
        sequence_id: int,
        timestamp_ns: int,
        values: np.ndarray,
    ) -> PhaseResult:
        valid = self._enabled and self._model is not None
        target = self._config.target_channels[0] if self._config.target_channels else ""
        if valid:
            phase = self._infer(values)
            flags = (QualityFlag.OK,)
        else:
            phase = 0.0
            flags = (QualityFlag.WARMING_UP,)
        return PhaseResult(
            sequence_id=sequence_id,
            timestamp_ns=timestamp_ns,
            values=(PhaseValue(channel_name=target, phase_rad=float(phase), valid=valid),),
            processing_time_us=0,
            quality_flags=flags,
        )

    def _infer(self, values: np.ndarray) -> float:
        # TODO: 在 torch.inference_mode() 中执行模型推理，返回弧度相位。
        return 0.0
