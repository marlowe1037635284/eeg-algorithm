from __future__ import annotations

import logging
from typing import Any


def get_logger(module_name: str) -> logging.Logger:
    if module_name.startswith("eeg_algorithm"):
        return logging.getLogger(module_name)
    return logging.getLogger(f"eeg_algorithm.{module_name}")


def log_event(
    logger: logging.Logger,
    level: int,
    message: str,
    *,
    code: str,
    operation: str | None = None,
    session_id: int | None = None,
    request_id: int | None = None,
    sequence_id: int | None = None,
    config_version: int | None = None,
    preprocess_version: int | None = None,
    duration_ms: float | None = None,
    exc_info: bool | BaseException | tuple[Any, Any, Any] | None = None,
) -> None:
    logger.log(
        level,
        message,
        extra={
            "code": code,
            "operation": operation,
            "session_id": session_id,
            "request_id": request_id,
            "sequence_id": sequence_id,
            "config_version": config_version,
            "preprocess_version": preprocess_version,
            "duration_ms": duration_ms,
        },
        exc_info=exc_info,
    )

