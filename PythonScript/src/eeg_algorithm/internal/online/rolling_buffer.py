"""滚动信号缓存：实时地形图与频谱的唯一数据来源。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, SignalBlock


class RollingSignalBuffer:
    """保存处理后的多通道数据，不允许混合不同配置版本的数据。"""

    def __init__(self, layout: ChannelLayout, capacity_s: float) -> None:
        self._fs = layout.sample_rate_hz
        self._channel_names = layout.channel_names
        self._channel_count = len(layout.channel_names)
        self._capacity = max(1, int(capacity_s * self._fs))
        self._data = np.zeros((self._channel_count, 0), dtype=np.float32)
        self._timestamps = np.zeros((0,), dtype=np.int64)
        self._config_version: int | None = None

    def append(self, signal: SignalBlock, config_version: int) -> None:
        if self._config_version != config_version:
            self.clear(config_version)
        values = np.ascontiguousarray(signal.values, dtype=np.float32)
        stamps = np.ascontiguousarray(signal.timestamps_ns, dtype=np.int64)
        self._data = np.concatenate([self._data, values], axis=1)
        self._timestamps = np.concatenate([self._timestamps, stamps])
        if self._data.shape[1] > self._capacity:
            self._data = self._data[:, -self._capacity:]
            self._timestamps = self._timestamps[-self._capacity:]

    def snapshot_multichannel(
        self,
        window_s: float | None,
        time_range: AbsoluteTimeRange | None,
        config_version: int,
    ) -> SignalBlock:
        if self._config_version != config_version:
            raise error(
                ErrorCode.INSUFFICIENT_WINDOW_DATA,
                "缓存配置版本不匹配",
                "snapshot_multichannel",
            )
        if time_range is not None:
            idx = self._indices_for_range(time_range)
        elif window_s is not None:
            idx = self._indices_for_window(window_s)
        else:
            raise error(
                ErrorCode.INVALID_ARGUMENT,
                "window_s 与 time_range 必须且只能提供一个",
                "snapshot_multichannel",
            )
        if idx.shape[0] == 0:
            raise error(
                ErrorCode.INSUFFICIENT_WINDOW_DATA,
                "滚动缓存尚未积满查询需要的时间窗",
                "snapshot_multichannel",
            )
        return self._make_block(idx)

    def snapshot_channel(
        self,
        channel_name: str,
        window_s: float,
        config_version: int,
    ) -> SignalBlock:
        if self._config_version != config_version:
            raise error(
                ErrorCode.INSUFFICIENT_WINDOW_DATA,
                "缓存配置版本不匹配",
                "snapshot_channel",
            )
        # channel_name 不在此处校验，由调用方传入当前导联。
        idx = self._indices_for_window(window_s)
        if idx.shape[0] == 0:
            raise error(
                ErrorCode.INSUFFICIENT_WINDOW_DATA,
                "滚动缓存尚未积满查询需要的时间窗",
                "snapshot_channel",
            )
        block = self._make_block(idx)
        channel_idx = self._find_channel(channel_name)
        return SignalBlock(
            first_sequence_id=block.first_sequence_id,
            timestamps_ns=block.timestamps_ns,
            values=block.values[channel_idx: channel_idx + 1],
        )

    def available_duration_s(self) -> float:
        return self._data.shape[1] / self._fs

    def clear(self, config_version: int) -> None:
        self._data = np.zeros((self._channel_count, 0), dtype=np.float32)
        self._timestamps = np.zeros((0,), dtype=np.int64)
        self._config_version = config_version

    # ---- 内部 ----
    def _indices_for_window(self, window_s: float) -> np.ndarray:
        n = int(window_s * self._fs)
        return np.arange(max(0, self._data.shape[1] - n), self._data.shape[1])

    def _indices_for_range(self, time_range: AbsoluteTimeRange) -> np.ndarray:
        return np.where(
            (self._timestamps >= time_range.start_timestamp_ns)
            & (self._timestamps < time_range.end_timestamp_ns)
        )[0]

    def _make_block(self, idx: np.ndarray) -> SignalBlock:
        values = np.ascontiguousarray(self._data[:, idx])
        stamps = np.ascontiguousarray(self._timestamps[idx])
        return SignalBlock(
            first_sequence_id=0,
            timestamps_ns=stamps,
            values=values,
        )

    def _find_channel(self, channel_name: str) -> int:
        return self._channel_names.index(channel_name)
