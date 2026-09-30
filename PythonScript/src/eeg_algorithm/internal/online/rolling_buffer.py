from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import INSUFFICIENT_WINDOW_DATA, INVALID_ARGUMENT, algorithm_error
from eeg_algorithm.types import AbsoluteTimeRange, ChannelLayout, SignalBlock


class RollingSignalBuffer:
    def __init__(self, layout: ChannelLayout, capacity_s: float) -> None:
        if capacity_s <= 0:
            raise algorithm_error(INVALID_ARGUMENT, "滚动缓存时长必须大于0", "RollingSignalBuffer")
        self._layout = layout
        self._capacity_samples = max(1, int(np.ceil(capacity_s * layout.sample_rate_hz)))
        self._values = np.empty((len(layout.channel_names), 0), dtype=np.float32)
        self._timestamps = np.empty((0,), dtype=np.int64)
        self._first_sequence_id = 0
        self._config_version = -1

    def append(self, signal: SignalBlock, config_version: int) -> None:
        if self._values.shape[1] and config_version != self._config_version:
            raise algorithm_error(INVALID_ARGUMENT, "滚动缓存不能混合不同配置版本", "RollingSignalBuffer.append")
        if self._values.shape[1] == 0:
            self._first_sequence_id = signal.first_sequence_id
            self._config_version = config_version
        self._values = np.ascontiguousarray(np.concatenate((self._values, signal.values), axis=1), dtype=np.float32)
        self._timestamps = np.ascontiguousarray(np.concatenate((self._timestamps, signal.timestamps_ns)), dtype=np.int64)
        overflow = self._values.shape[1] - self._capacity_samples
        if overflow > 0:
            self._values = np.ascontiguousarray(self._values[:, overflow:])
            self._timestamps = np.ascontiguousarray(self._timestamps[overflow:])
            self._first_sequence_id += overflow

    def snapshot_multichannel(
        self,
        window_s: float | None,
        time_range: AbsoluteTimeRange | None,
        config_version: int,
    ) -> SignalBlock:
        self._check_version(config_version)
        if (window_s is None) == (time_range is None):
            raise algorithm_error(INVALID_ARGUMENT, "window_s和time_range必须且只能指定一个", "snapshot_multichannel")
        if window_s is not None:
            count = int(round(window_s * self._layout.sample_rate_hz))
            if count <= 0 or self._values.shape[1] < count:
                raise algorithm_error(INSUFFICIENT_WINDOW_DATA, "滚动缓存数据不足", "snapshot_multichannel")
            indices = np.arange(self._values.shape[1] - count, self._values.shape[1])
        else:
            assert time_range is not None
            indices = np.flatnonzero(
                (self._timestamps >= time_range.start_timestamp_ns)
                & (self._timestamps <= time_range.end_timestamp_ns)
            )
            if indices.size == 0:
                raise algorithm_error(INSUFFICIENT_WINDOW_DATA, "指定时间范围没有缓存数据", "snapshot_multichannel")
        start = int(indices[0])
        return SignalBlock(
            self._first_sequence_id + start,
            np.ascontiguousarray(self._timestamps[indices], dtype=np.int64),
            np.ascontiguousarray(self._values[:, indices], dtype=np.float32),
        )

    def snapshot_channel(self, channel_name: str, window_s: float, config_version: int) -> SignalBlock:
        if channel_name not in self._layout.channel_names:
            raise algorithm_error(INVALID_ARGUMENT, "频谱导联不存在", "snapshot_channel")
        block = self.snapshot_multichannel(window_s, None, config_version)
        index = self._layout.channel_names.index(channel_name)
        return SignalBlock(block.first_sequence_id, block.timestamps_ns, np.ascontiguousarray(block.values[index : index + 1]))

    def available_duration_s(self) -> float:
        return self._values.shape[1] / self._layout.sample_rate_hz

    def clear(self, config_version: int) -> None:
        self._values = np.empty((len(self._layout.channel_names), 0), dtype=np.float32)
        self._timestamps = np.empty((0,), dtype=np.int64)
        self._config_version = config_version

    def _check_version(self, config_version: int) -> None:
        if self._values.shape[1] == 0:
            raise algorithm_error(INSUFFICIENT_WINDOW_DATA, "滚动缓存为空", "RollingSignalBuffer.snapshot")
        if config_version != self._config_version:
            raise algorithm_error(INVALID_ARGUMENT, "查询配置版本与缓存版本不一致", "RollingSignalBuffer.snapshot")

