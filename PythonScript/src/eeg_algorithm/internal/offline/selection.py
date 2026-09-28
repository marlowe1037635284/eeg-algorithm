"""离线选段：按绝对时间范围从预处理数据中截取。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.validation import validate_channel_name, validate_time_range
from eeg_algorithm.types.common import AbsoluteTimeRange, SignalBlock
from eeg_algorithm.types.offline import PreprocessedDataset


def _indices(signal: SignalBlock, selected_range: AbsoluteTimeRange) -> np.ndarray:
    ts = signal.timestamps_ns
    idx = np.where(
        (ts >= selected_range.start_timestamp_ns) & (ts < selected_range.end_timestamp_ns)
    )[0]
    if idx.size == 0:
        raise error(
            ErrorCode.TIME_RANGE_OUT_OF_RANGE,
            "选段范围内没有样本",
            "select_segment",
        )
    return idx


def _slice(signal: SignalBlock, idx: np.ndarray) -> SignalBlock:
    values = np.ascontiguousarray(signal.values[:, idx], dtype=np.float32)
    stamps = np.ascontiguousarray(signal.timestamps_ns[idx], dtype=np.int64)
    return SignalBlock(
        first_sequence_id=signal.first_sequence_id + int(idx[0]),
        timestamps_ns=stamps,
        values=values,
    )


def select_multichannel_segment(
    dataset: PreprocessedDataset,
    selected_range: AbsoluteTimeRange,
) -> SignalBlock:
    """按时间戳从预处理数据中截取多通道选段，返回 ``[C, K]``。"""
    validate_time_range(selected_range, dataset.actual_time_range, "select_multichannel_segment")
    idx = _indices(dataset.signal, selected_range)
    return _slice(dataset.signal, idx)


def select_channel_segment(
    dataset: PreprocessedDataset,
    channel_name: str,
    selected_range: AbsoluteTimeRange,
) -> SignalBlock:
    """按时间戳从预处理数据中截取单导联选段，返回 ``[1, K]``。"""
    validate_channel_name(dataset.layout, channel_name, "select_channel_segment")
    validate_time_range(selected_range, dataset.actual_time_range, "select_channel_segment")
    idx = _indices(dataset.signal, selected_range)
    base = _slice(dataset.signal, idx)
    channel_index = dataset.layout.channel_names.index(channel_name)
    return SignalBlock(
        first_sequence_id=base.first_sequence_id,
        timestamps_ns=base.timestamps_ns,
        values=base.values[channel_index: channel_index + 1],
    )
