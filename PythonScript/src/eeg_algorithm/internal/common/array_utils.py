from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

from eeg_algorithm.types import AbsoluteTimeRange, SignalBlock


def as_float32_c(values: NDArray[np.floating]) -> NDArray[np.float32]:
    return np.ascontiguousarray(values, dtype=np.float32)


def as_int64_c(values: NDArray[np.integer]) -> NDArray[np.int64]:
    return np.ascontiguousarray(values, dtype=np.int64)


def block_time_range(block: SignalBlock) -> AbsoluteTimeRange:
    return AbsoluteTimeRange(int(block.timestamps_ns[0]), int(block.timestamps_ns[-1]))


def copy_block(block: SignalBlock, values: NDArray[np.floating] | None = None) -> SignalBlock:
    return SignalBlock(
        first_sequence_id=block.first_sequence_id,
        timestamps_ns=as_int64_c(block.timestamps_ns.copy()),
        values=as_float32_c(block.values.copy() if values is None else values),
    )

