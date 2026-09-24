"""日志处理器：有界非阻塞队列 + UI 告警队列。"""

from __future__ import annotations

import logging
import queue
from typing import Callable

from eeg_algorithm.types.observability import LogEvent, LogLevel

_LEVEL_TO_ENUM: dict[int, LogLevel] = {
    logging.DEBUG: LogLevel.DEBUG,
    logging.INFO: LogLevel.INFO,
    logging.WARNING: LogLevel.WARNING,
    logging.ERROR: LogLevel.ERROR,
    logging.CRITICAL: LogLevel.CRITICAL,
}


def record_to_log_event(record: logging.LogRecord) -> LogEvent:
    """把 logging record 转成跨语言的 :class:`LogEvent`。"""
    return LogEvent(
        timestamp_utc_ns=int(record.created * 1_000_000_000),
        level=_LEVEL_TO_ENUM.get(record.levelno, LogLevel.INFO),
        code=getattr(record, "code", ""),
        message=record.getMessage(),
        operation=getattr(record, "operation", None),
        session_id=getattr(record, "session_id", None),
        request_id=getattr(record, "request_id", None),
        sequence_id=getattr(record, "sequence_id", None),
        duration_ms=getattr(record, "duration_ms", None),
    )


class BoundedQueueHandler(logging.Handler):
    """非阻塞投递日志到文件队列；``WARNING`` 及以上额外投递到 UI 告警队列。

    队列满时丢弃当前记录并回调计数，不阻塞实时算法线程。
    """

    def __init__(
        self,
        file_queue: "queue.Queue[logging.LogRecord]",
        ui_queue: "queue.Queue[LogEvent]",
        ui_min_level: int,
        on_file_drop: Callable[[], None],
        on_ui_drop: Callable[[], None],
    ) -> None:
        super().__init__()
        self._file_queue = file_queue
        self._ui_queue = ui_queue
        self._ui_min_level = ui_min_level
        self._on_file_drop = on_file_drop
        self._on_ui_drop = on_ui_drop

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self._file_queue.put_nowait(record)
        except queue.Full:
            self._on_file_drop()

        if record.levelno >= self._ui_min_level:
            try:
                self._ui_queue.put_nowait(record_to_log_event(record))
            except queue.Full:
                self._on_ui_drop()
