from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping

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
    code: str
    message: str
    operation: str
    session_id: int | None = None
    sequence_id: int | None = None
    details: Mapping[str, object] = field(default_factory=dict)


class AlgorithmError(RuntimeError):
    def __init__(self, info: AlgorithmErrorInfo) -> None:
        super().__init__(f"{info.code}: {info.message}")
        self._info = info

    @property
    def info(self) -> AlgorithmErrorInfo:
        return self._info


def algorithm_error(
    code: str,
    message: str,
    operation: str,
    *,
    session_id: int | None = None,
    sequence_id: int | None = None,
    **details: object,
) -> AlgorithmError:
    return AlgorithmError(
        AlgorithmErrorInfo(code, message, operation, session_id, sequence_id, details)
    )

