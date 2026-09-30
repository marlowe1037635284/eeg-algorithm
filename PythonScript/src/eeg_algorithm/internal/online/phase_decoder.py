from __future__ import annotations

import logging
import math
import time
from collections import deque
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.errors import INVALID_ARGUMENT, MODEL_LOAD_FAILED, algorithm_error
from eeg_algorithm.types import ChannelLayout, PhaseModelConfig, PhaseResult, PhaseValue, QualityFlag

from eeg_algorithm.internal.observability.context import get_logger, log_event


class PhaseDecoder:
    def __init__(self, config: PhaseModelConfig, layout: ChannelLayout) -> None:
        self._config = config
        self._layout = layout
        self._history: deque[NDArray[np.float32]] = deque(maxlen=max(1, config.window_samples))
        self._model: Any = None
        self._torch: Any = None
        self._logger = get_logger(__name__)
        if not config.enabled:
            return
        if config.window_samples <= 0 or not config.target_channels:
            raise algorithm_error(INVALID_ARGUMENT, "相位模型窗口和目标通道配置非法", "PhaseDecoder")
        if any(name not in layout.channel_names for name in config.target_channels):
            raise algorithm_error(INVALID_ARGUMENT, "相位目标通道不存在", "PhaseDecoder")
        try:
            import torch

            path = Path(config.model_path)
            if not path.is_file():
                raise FileNotFoundError(path)
            if config.device == "cuda" and not torch.cuda.is_available():
                raise RuntimeError("CUDA不可用")
            self._torch = torch
            try:
                self._model = torch.jit.load(str(path), map_location=config.device)
            except Exception:
                self._model = torch.load(str(path), map_location=config.device, weights_only=False)
            self._model.eval()
            log_event(
                self._logger,
                logging.INFO,
                "相位模型加载完成",
                code="PHASE_MODEL_LOADED",
                operation="PhaseDecoder.__init__",
            )
        except Exception as exc:
            raise algorithm_error(MODEL_LOAD_FAILED, f"相位模型加载失败: {exc}", "PhaseDecoder") from exc

    @property
    def enabled(self) -> bool:
        return self._config.enabled

    @property
    def warmup_remaining_samples(self) -> int:
        if not self.enabled:
            return 0
        return max(0, self._config.window_samples - len(self._history))

    def update_sample(self, values: NDArray[np.float32], sequence_id: int, timestamp_ns: int) -> PhaseResult | None:
        if not self.enabled:
            return None
        started = time.perf_counter_ns()
        self._history.append(np.ascontiguousarray(values, dtype=np.float32))
        if len(self._history) < self._config.window_samples:
            targets = tuple(PhaseValue(name, 0.0, False) for name in self._config.target_channels)
            return PhaseResult(
                sequence_id,
                timestamp_ns,
                targets,
                (time.perf_counter_ns() - started) // 1000,
                (QualityFlag.WARMING_UP,),
            )
        try:
            window = np.stack(tuple(self._history), axis=1)[None, ...]
            tensor = self._torch.from_numpy(window).to(self._config.device)
            with self._torch.inference_mode():
                raw = self._model(tensor)
                if isinstance(raw, (tuple, list)):
                    raw = raw[0]
                output = raw.detach().to("cpu").numpy().reshape(-1)
            phases = self._decode_output(output)
            phase_values = tuple(
                PhaseValue(name, float(phase), True) for name, phase in zip(self._config.target_channels, phases)
            )
            flags = (QualityFlag.OK,)
        except Exception as exc:
            log_event(
                self._logger,
                logging.ERROR,
                f"相位推理失败: {exc}",
                code="PHASE_INFERENCE_FAILED",
                operation="PhaseDecoder.update_sample",
                sequence_id=sequence_id,
                exc_info=True,
            )
            phase_values = tuple(PhaseValue(name, 0.0, False) for name in self._config.target_channels)
            flags = (QualityFlag.MODEL_INVALID,)
        return PhaseResult(
            sequence_id,
            timestamp_ns,
            phase_values,
            (time.perf_counter_ns() - started) // 1000,
            flags,
        )

    def update_block(
        self,
        values: NDArray[np.float32],
        first_sequence_id: int,
        timestamps_ns: NDArray[np.int64],
    ) -> tuple[PhaseResult, ...]:
        results: list[PhaseResult] = []
        for index in range(values.shape[1]):
            result = self.update_sample(values[:, index], first_sequence_id + index, int(timestamps_ns[index]))
            if result is not None:
                results.append(result)
        return tuple(results)

    def reset(self) -> None:
        self._history.clear()

    def close(self) -> None:
        self._history.clear()
        self._model = None

    def _decode_output(self, output: NDArray[np.floating]) -> NDArray[np.float64]:
        count = len(self._config.target_channels)
        if output.size == count * 2:
            phases = np.arctan2(output[1::2], output[0::2])
        elif output.size >= count:
            phases = output[:count]
        else:
            raise ValueError(f"模型输出长度{output.size}小于目标数{count}")
        return ((np.asarray(phases, dtype=np.float64) + math.pi) % (2 * math.pi)) - math.pi

