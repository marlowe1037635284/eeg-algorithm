from __future__ import annotations

import logging
import queue
from collections.abc import Callable
from logging.handlers import QueueHandler


class NonBlockingQueueHandler(QueueHandler):
    def __init__(self, target_queue: queue.Queue[logging.LogRecord], on_drop: Callable[[], None]) -> None:
        super().__init__(target_queue)
        self._on_drop = on_drop

    def enqueue(self, record: logging.LogRecord) -> None:
        try:
            self.queue.put_nowait(record)
        except queue.Full:
            self._on_drop()

    def handleError(self, record: logging.LogRecord) -> None:  # noqa: N802
        self._on_drop()


class UiEventHandler(logging.Handler):
    def __init__(
        self,
        target_queue: queue.Queue[logging.LogRecord],
        on_drop: Callable[[], None],
        level: int,
    ) -> None:
        super().__init__(level)
        self._queue = target_queue
        self._on_drop = on_drop

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self._queue.put_nowait(record)
        except queue.Full:
            self._on_drop()

