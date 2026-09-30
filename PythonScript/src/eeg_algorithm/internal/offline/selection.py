from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import CHANNEL_LAYOUT_MISMATCH, TIME_RANGE_OUT_OF_RANGE, algorithm_error
from eeg_algorithm.types import AbsoluteTimeRange, PreprocessedDataset, SignalBlock


def select_multichannel_segment(
    dataset: PreprocessedDataset,
    selected_range: AbsoluteTimeRange,
) -> SignalBlock:
    timestamps = dataset.signal.timestamps_ns
    mask = (timestamps >= selected_range.start_timestamp_ns) & (timestamps <= selected_range.end_timestamp_ns)
    indices = np.flatnonzero(mask)
    if indices.size == 0:
        raise algorithm_error(TIME_RANGE_OUT_OF_RANGE, "所选时间段不在预处理数据内", "select_multichannel_segment")
    start = int(indices[0])
    return SignalBlock(
        dataset.signal.first_sequence_id + start,
        np.ascontiguousarray(timestamps[indices], dtype=np.int64),
        np.ascontiguousarray(dataset.signal.values[:, indices], dtype=np.float32),
    )


def select_channel_segment(
    dataset: PreprocessedDataset,
    channel_name: str,
    selected_range: AbsoluteTimeRange,
) -> SignalBlock:
    if channel_name not in dataset.layout.channel_names:
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "所选导联不存在", "select_channel_segment")
    block = select_multichannel_segment(dataset, selected_range)
    index = dataset.layout.channel_names.index(channel_name)
    return SignalBlock(block.first_sequence_id, block.timestamps_ns, np.ascontiguousarray(block.values[index : index + 1]))

