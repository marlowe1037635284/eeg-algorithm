from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import (
    CHANNEL_LAYOUT_MISMATCH,
    FREQUENCY_OUT_OF_RANGE,
    INVALID_ARGUMENT,
    INVALID_SAMPLE_RATE,
    SHAPE_MISMATCH,
    TIME_RANGE_OUT_OF_RANGE,
    algorithm_error,
)
from eeg_algorithm.types import AbsoluteTimeRange, ChannelLayout, FrequencyBand, SampleFrame, SignalBlock


def validate_layout(layout: ChannelLayout, operation: str = "validate_layout") -> None:
    if not layout.channel_names or len(set(layout.channel_names)) != len(layout.channel_names):
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "通道名称必须非空且唯一", operation)
    if not np.isfinite(layout.sample_rate_hz) or layout.sample_rate_hz <= 0:
        raise algorithm_error(INVALID_SAMPLE_RATE, "采样率必须大于0", operation)
    position_names = [item.channel_name for item in layout.positions]
    if len(position_names) != len(set(position_names)):
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "电极坐标包含重复通道", operation)
    if any(name not in layout.channel_names for name in position_names):
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "电极坐标包含未知通道", operation)


def validate_frame(frame: SampleFrame, channel_count: int, operation: str) -> None:
    values = np.asarray(frame.values)
    if values.shape != (channel_count,):
        raise algorithm_error(SHAPE_MISMATCH, f"单点形状应为({channel_count},)", operation)
    if values.dtype != np.float32 or not values.flags.c_contiguous:
        raise algorithm_error(INVALID_ARGUMENT, "单点数据必须是连续float32数组", operation)
    if not np.isfinite(values).all():
        raise algorithm_error(INVALID_ARGUMENT, "单点数据包含NaN或Inf", operation)


def validate_block(block: SignalBlock, channel_count: int, operation: str) -> None:
    values = np.asarray(block.values)
    timestamps = np.asarray(block.timestamps_ns)
    if values.ndim != 2 or values.shape[0] != channel_count:
        raise algorithm_error(SHAPE_MISMATCH, f"数据块形状应为({channel_count},N)", operation)
    if timestamps.ndim != 1 or timestamps.shape[0] != values.shape[1]:
        raise algorithm_error(SHAPE_MISMATCH, "时间戳数量必须等于采样点数", operation)
    if values.shape[1] == 0:
        raise algorithm_error(INVALID_ARGUMENT, "数据块不能为空", operation)
    if values.dtype != np.float32 or not values.flags.c_contiguous:
        raise algorithm_error(INVALID_ARGUMENT, "数据块必须是C连续float32数组", operation)
    if timestamps.dtype != np.int64 or not timestamps.flags.c_contiguous:
        raise algorithm_error(INVALID_ARGUMENT, "时间戳必须是连续int64数组", operation)
    if not np.isfinite(values).all():
        raise algorithm_error(INVALID_ARGUMENT, "数据块包含NaN或Inf", operation)
    if timestamps.size > 1 and np.any(np.diff(timestamps) <= 0):
        raise algorithm_error(INVALID_ARGUMENT, "数据块时间戳必须严格递增", operation)


def validate_frequency_band(band: FrequencyBand, sample_rate_hz: float, operation: str) -> None:
    if not 0 < band.low_hz < band.high_hz < sample_rate_hz / 2:
        raise algorithm_error(FREQUENCY_OUT_OF_RANGE, "频率范围必须位于(0, Nyquist)内", operation)


def validate_time_range(value: AbsoluteTimeRange, operation: str) -> None:
    if value.start_timestamp_ns > value.end_timestamp_ns:
        raise algorithm_error(TIME_RANGE_OUT_OF_RANGE, "时间范围起点不能晚于终点", operation)

