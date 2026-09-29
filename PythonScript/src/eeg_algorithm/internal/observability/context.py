"""日志上下文绑定，使用显式 LoggerAdapter，不使用业务全局变量。"""

from __future__ import annotations

import logging
from typing import Any


class SessionLoggerAdapter(logging.LoggerAdapter):
    """把 ``session_id``、``request_id``、``sequence_id`` 等上下文注入日志。"""

    def process(self, msg: Any, kwargs: dict) -> tuple[Any, dict]:
        extra = kwargs.setdefault("extra", {})
        extra.update(self.extra)
        return msg, kwargs


def bind(
    logger: logging.Logger,
    *,
    session_id: int | None = None,
    request_id: int | None = None,
    sequence_id: int | None = None,
    config_version: int | None = None,
    preprocess_version: int | None = None,
) -> SessionLoggerAdapter:
    """返回绑定了会话上下文的 LoggerAdapter。"""
    extra: dict[str, Any] = {}
    if session_id is not None:
        extra["session_id"] = session_id
    if request_id is not None:
        extra["request_id"] = request_id
    if sequence_id is not None:
        extra["sequence_id"] = sequence_id
    if config_version is not None:
        extra["config_version"] = config_version
    if preprocess_version is not None:
        extra["preprocess_version"] = preprocess_version
    return SessionLoggerAdapter(logger, extra)
