"""输入校验工具。

校验失败抛出 :class:`AlgorithmError`，且不得修改内部状态。
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout


def validate_channel_layout(layout: ChannelLayout) -> None:
    if not layout.channel_names:
        raise error(ErrorCode.INVALID_ARGUMENT, "通道名称不能为空", "validate_channel_layout")
    if len(set(layout.channel_names)) != len(layout.channel_names):
        raise error(ErrorCode.INVALID_ARGUMENT, "通道名称必须唯一", "validate_channel_layout")
    if layout.sample_rate_hz <= 0:
        raise error(ErrorCode.INVALID_SAMPLE_RATE, "采样率必须大于 0", "validate_channel_layout")


def validate_values(values: np.ndarray, channel_count: int, operation: str) -> np.ndarray:
    """校验 ``values`` 的通道维度，并返回 C-contiguous float32 视图。"""
    if values.ndim < 1:
        raise error(ErrorCode.SHAPE_MISMATCH, "信号数组维度不足", operation)
    if values.shape[0] != channel_count:
        raise error(
            ErrorCode.CHANNEL_LAYOUT_MISMATCH,
            f"通道数 {values.shape[0]} 与布局 {channel_count} 不符",
            operation,
        )
    if not np.isfinite(values).all():
        raise error(ErrorCode.INVALID_ARGUMENT, "输入数据包含 NaN 或 Inf", operation)
    return np.ascontiguousarray(values, dtype=np.float32)


def validate_frequency_range(low_hz: float, high_hz: float, nyquist: float, operation: str) -> None:
    if not (0 < low_hz < high_hz < nyquist):
        raise error(
            ErrorCode.FREQUENCY_OUT_OF_RANGE,
            f"频率范围 [{low_hz}, {high_hz}] 非法（Nyquist={nyquist}）",
            operation,
        )


def validate_time_range(
    time_range: AbsoluteTimeRange,
    data_range: AbsoluteTimeRange,
    operation: str,
) -> None:
    if time_range.start_timestamp_ns < data_range.start_timestamp_ns or \
            time_range.end_timestamp_ns > data_range.end_timestamp_ns:
        raise error(
            ErrorCode.TIME_RANGE_OUT_OF_RANGE,
            "选段范围超出数据时间范围",
            operation,
        )
    if time_range.start_timestamp_ns >= time_range.end_timestamp_ns:
        raise error(ErrorCode.INVALID_ARGUMENT, "时间范围起点必须小于终点", operation)


def validate_channel_name(layout: ChannelLayout, channel_name: str, operation: str) -> None:
    if channel_name not in layout.channel_names:
        raise error(
            ErrorCode.CHANNEL_LAYOUT_MISMATCH,
            f"导联 {channel_name} 不在当前通道布局中",
            operation,
        )
