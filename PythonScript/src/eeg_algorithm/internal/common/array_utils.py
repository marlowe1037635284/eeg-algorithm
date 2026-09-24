"""数组工具：C-contiguous 转换与 NaN/Inf 校验。"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import error
from eeg_algorithm.errors import ErrorCode


def as_contiguous_float32(a: np.ndarray) -> np.ndarray:
    """转换为 C-contiguous ``float32``，若已是目标类型则零拷贝返回。"""
    arr = np.asarray(a, dtype=np.float32)
    if not arr.flags.c_contiguous:
        arr = np.ascontiguousarray(arr)
    return arr


def as_contiguous_int64(a: np.ndarray) -> np.ndarray:
    """转换为 C-contiguous ``int64``。"""
    arr = np.asarray(a, dtype=np.int64)
    if not arr.flags.c_contiguous:
        arr = np.ascontiguousarray(arr)
    return arr


def check_no_nan_inf(a: np.ndarray, operation: str) -> None:
    """输入数组不允许包含 NaN 或 Inf。"""
    if not np.isfinite(a).all():
        raise error(ErrorCode.INVALID_ARGUMENT, "输入数据包含 NaN 或 Inf", operation)


def check_shape(a: np.ndarray, expected: tuple[int, ...] | None, operation: str) -> None:
    """校验形状（``expected=None`` 表示仅要求非空）。"""
    if a.ndim == 0:
        raise error(ErrorCode.SHAPE_MISMATCH, "输入数组为空标量", operation)
    if expected is not None and tuple(a.shape) != tuple(expected):
        raise error(
            ErrorCode.SHAPE_MISMATCH,
            f"数组形状 {tuple(a.shape)} 与期望 {tuple(expected)} 不符",
            operation,
        )
