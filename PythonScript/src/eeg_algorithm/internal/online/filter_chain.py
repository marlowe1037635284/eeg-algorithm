from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray
from scipy.signal import butter

from eeg_algorithm.errors import (
    FREQUENCY_OUT_OF_RANGE,
    INVALID_ARGUMENT,
    algorithm_error,
)
from eeg_algorithm.types import OnlineProcessingConfig


@dataclass
class _IirStage:
    """保存一级滤波器的系数和历史。"""

    b_reverse: NDArray[np.float64]
    a_reverse: NDArray[np.float64]
    a0: float
    x_buffer: NDArray[np.float64]
    y_buffer: NDArray[np.float64]


class OnlineFilterChain:
    def __init__(
        self,
        config: OnlineProcessingConfig,
        sample_rate_hz: float,
        channel_count: int,
    ) -> None:
        self._sample_rate_hz = sample_rate_hz
        self._channel_count = channel_count
        self._stages: list[_IirStage] = []

        self.reconfigure(config)

    def _make_stage(
        self,
        cutoff: float | tuple[float, float],
        kind: str,
        order: int,
    ) -> _IirStage:
        """生成 b/a 系数，并初始化这一阶段的历史。"""

        b, a = butter(
            N=order,
            Wn=cutoff,
            btype=kind,
            fs=self._sample_rate_hz,
        )

        return _IirStage(
            # 历史排列为旧 → 新，所以提前反转系数。
            b_reverse=b[::-1].copy(),
            a_reverse=a[1:][::-1].copy(),
            a0=float(a[0]),
            x_buffer=np.zeros(
                (self._channel_count, len(b)),
                dtype=np.float64,
            ),
            y_buffer=np.zeros(
                (self._channel_count, len(a) - 1),
                dtype=np.float64,
            ),
        )

    def reconfigure(self, config: OnlineProcessingConfig) -> None:
        """根据外部配置创建滤波链，并重置历史。"""

        operation = "OnlineFilterChain.reconfigure"
        stages: list[_IirStage] = []

        # 保留原框架的阶数限制。
        for item in (
            config.high_pass,
            config.low_pass,
            config.notch,
        ):
            if item.order != 4:
                raise algorithm_error(
                    INVALID_ARGUMENT,
                    "v1滤波器阶数必须为4",
                    operation,
                )

        def check_frequency(
            value: float | None,
            name: str,
        ) -> float:
            if value is None:
                raise algorithm_error(
                    INVALID_ARGUMENT,
                    f"{name}启用时必须提供截止频率",
                    operation,
                )

            if not 0 < value < self._sample_rate_hz / 2:
                raise algorithm_error(
                    FREQUENCY_OUT_OF_RANGE,
                    f"{name}截止频率必须位于(0, Nyquist)内",
                    operation,
                )

            return value

        # 第一级：高通。
        if config.high_pass.enabled:
            cutoff = check_frequency(
                config.high_pass.low_hz,
                "高通",
            )
            stages.append(
                self._make_stage(
                    cutoff,
                    "highpass",
                    config.high_pass.order,
                )
            )

        # 第二级：低通。
        if config.low_pass.enabled:
            cutoff = check_frequency(
                config.low_pass.high_hz,
                "低通",
            )
            stages.append(
                self._make_stage(
                    cutoff,
                    "lowpass",
                    config.low_pass.order,
                )
            )

        # 第三级：陷波。
        if config.notch.enabled:
            lower = check_frequency(
                config.notch.low_hz,
                "陷波下限",
            )
            upper = check_frequency(
                config.notch.high_hz,
                "陷波上限",
            )

            if lower >= upper:
                raise algorithm_error(
                    FREQUENCY_OUT_OF_RANGE,
                    "陷波下限必须小于上限",
                    operation,
                )

            stages.append(
                self._make_stage(
                    (lower, upper),
                    "bandstop",
                    config.notch.order,
                )
            )

        # 全部创建成功后，才替换当前滤波链。
        self._stages = stages

    def process_sample(
        self,
        values: NDArray[np.float32],
    ) -> NDArray[np.float32]:
        """处理一个时间点的全部通道。"""

        return self.process_block(
            np.ascontiguousarray(
                values[:, None],
                dtype=np.float32,
            )
        )[:, 0]

    def process_block(
        self,
        values: NDArray[np.float32],
    ) -> NDArray[np.float32]:
        """输入和输出形状均为：(通道数, 采样点数)。"""

        # 创建副本，避免修改调用方的原始数据。
        output = np.array(
            values,
            dtype=np.float64,
            copy=True,
        )

        for stage in self._stages:
            # 每一级按时间顺序处理所有采样点。
            for index in range(output.shape[1]):
                # 1. 更新输入历史：旧 → 新。
                stage.x_buffer[:, :-1] = (
                    stage.x_buffer[:, 1:].copy()
                )
                stage.x_buffer[:, -1] = output[:, index]

                # 2. 输入系数 × 输入历史。
                input_part = np.sum(
                    stage.b_reverse * stage.x_buffer,
                    axis=1,
                )

                # 3. 反馈系数 × 输出历史。
                feedback_part = np.sum(
                    stage.a_reverse * stage.y_buffer,
                    axis=1,
                )

                # 4. 你的差分递推公式。
                current = (
                    input_part - feedback_part
                ) / stage.a0

                # 5. 保存输出历史。
                stage.y_buffer[:, :-1] = (
                    stage.y_buffer[:, 1:].copy()
                )
                stage.y_buffer[:, -1] = current

                # 本级结果成为下一级的输入。
                output[:, index] = current

        return np.ascontiguousarray(
            output,
            dtype=np.float32,
        )

    def reset(self) -> None:
        """保留系数，清空每一级滤波器的历史。"""

        for stage in self._stages:
            stage.x_buffer.fill(0)
            stage.y_buffer.fill(0)

