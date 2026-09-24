"""统一错误码与异常。

日志不能替代错误码或异常返回。``AlgorithmError`` 是接口错误的正式表达。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping


class ErrorCode:
    """接口文档约定的错误码。"""

    INVALID_ARGUMENT = "INVALID_ARGUMENT"
    SHAPE_MISMATCH = "SHAPE_MISMATCH"
    CHANNEL_LAYOUT_MISMATCH = "CHANNEL_LAYOUT_MISMATCH"
    INVALID_SAMPLE_RATE = "INVALID_SAMPLE_RATE"
    TIME_SEQUENCE_DISCONTINUITY = "TIME_SEQUENCE_DISCONTINUITY"
    FREQUENCY_OUT_OF_RANGE = "FREQUENCY_OUT_OF_RANGE"
    INSUFFICIENT_WINDOW_DATA = "INSUFFICIENT_WINDOW_DATA"
    TIME_RANGE_OUT_OF_RANGE = "TIME_RANGE_OUT_OF_RANGE"
    PREPROCESSED_DATA_NOT_READY = "PREPROCESSED_DATA_NOT_READY"
    STALE_DATA_VERSION = "STALE_DATA_VERSION"
    NOT_INITIALIZED = "NOT_INITIALIZED"
    SESSION_NOT_FOUND = "SESSION_NOT_FOUND"
    INVALID_STATE = "INVALID_STATE"
    MODEL_LOAD_FAILED = "MODEL_LOAD_FAILED"
    ASR_REFERENCE_REQUIRED = "ASR_REFERENCE_REQUIRED"
    PROCESSING_TIMEOUT = "PROCESSING_TIMEOUT"
    ALGORITHM_RUNTIME_ERROR = "ALGORITHM_RUNTIME_ERROR"
    INTERNAL_ERROR = "INTERNAL_ERROR"


@dataclass(frozen=True)
class AlgorithmErrorInfo:
    """错误信息 DTO，跨语言传递。"""

    code: str
    message: str
    operation: str
    session_id: int | None = None
    sequence_id: int | None = None
    details: Mapping[str, object] = field(default_factory=dict)


class AlgorithmError(RuntimeError):
    """接口错误异常。

    携带结构化的 :class:`AlgorithmErrorInfo`，供 C++ 侧读取错误码与上下文。
    """

    def __init__(self, info: AlgorithmErrorInfo) -> None:
        super().__init__(info.message)
        self._info = info

    @property
    def info(self) -> AlgorithmErrorInfo:
        return self._info


def error(
    code: str,
    message: str,
    operation: str,
    session_id: int | None = None,
    sequence_id: int | None = None,
    details: Mapping[str, object] | None = None,
) -> AlgorithmError:
    """构造 :class:`AlgorithmError` 的便捷函数。"""
    return AlgorithmError(
        AlgorithmErrorInfo(
            code=code,
            message=message,
            operation=operation,
            session_id=session_id,
            sequence_id=sequence_id,
            details=dict(details) if details else {},
        )
    )
