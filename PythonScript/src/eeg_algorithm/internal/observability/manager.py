from __future__ import annotations

import logging
import os
import queue
from datetime import datetime
from logging.handlers import QueueListener, RotatingFileHandler
from pathlib import Path
from threading import RLock

from eeg_algorithm.errors import INVALID_ARGUMENT, INVALID_STATE, algorithm_error
from eeg_algorithm.types import LogEvent, LogLevel, LoggingConfig, LoggingStatus

from .formatter import JsonLineFormatter
from .handlers import NonBlockingQueueHandler, UiEventHandler

_LEVELS = {
    LogLevel.DEBUG: logging.DEBUG,
    LogLevel.INFO: logging.INFO,
    LogLevel.WARNING: logging.WARNING,
    LogLevel.ERROR: logging.ERROR,
    LogLevel.CRITICAL: logging.CRITICAL,
}


class LoggingManager:
    def __init__(self) -> None:
        self._lock = RLock()
        self._enabled = False
        self._configured = False
        self._active_log_file: str | None = None
        self._dropped_file_records = 0
        self._dropped_ui_events = 0
        self._last_error: str | None = None
        self._file_queue: queue.Queue[logging.LogRecord] | None = None
        self._ui_queue: queue.Queue[logging.LogRecord] = queue.Queue(maxsize=1)
        self._listener: QueueListener | None = None
        self._file_handler: RotatingFileHandler | None = None
        self._queue_handler: NonBlockingQueueHandler | None = None
        self._ui_handler: UiEventHandler | None = None

    @property
    def configured(self) -> bool:
        with self._lock:
            return self._configured

    def configure(self, config: LoggingConfig) -> None:
        with self._lock:
            if self._configured:
                raise algorithm_error(INVALID_STATE, "日志系统已经配置", "configure_logging")
            self._validate(config)
            self._configured = True
            self._enabled = config.enabled
            self._ui_queue = queue.Queue(maxsize=config.event_queue_capacity)
            if not config.enabled:
                return

            try:
                directory = Path(config.directory).expanduser().resolve()
                directory.mkdir(parents=True, exist_ok=True)
                filename = f"eeg_algorithm-{datetime.now():%Y%m%d}-{os.getpid()}.jsonl"
                path = directory / filename
                file_queue: queue.Queue[logging.LogRecord] = queue.Queue(
                    maxsize=max(1024, config.event_queue_capacity * 4)
                )
                file_handler = RotatingFileHandler(
                    path,
                    maxBytes=config.rotate_max_bytes,
                    backupCount=config.rotate_backup_count,
                    encoding="utf-8",
                    delay=False,
                )
                file_handler.setLevel(_LEVELS[config.min_level])
                file_handler.setFormatter(JsonLineFormatter())
                queue_handler = NonBlockingQueueHandler(file_queue, self._increment_file_drop)
                queue_handler.setLevel(_LEVELS[config.min_level])
                ui_handler = UiEventHandler(
                    self._ui_queue,
                    self._increment_ui_drop,
                    _LEVELS[config.ui_event_min_level],
                )
                listener = QueueListener(file_queue, file_handler, respect_handler_level=True)

                package_logger = logging.getLogger("eeg_algorithm")
                package_logger.setLevel(min(_LEVELS[config.min_level], _LEVELS[config.ui_event_min_level]))
                package_logger.propagate = False
                package_logger.addHandler(queue_handler)
                package_logger.addHandler(ui_handler)
                listener.start()

                self._file_queue = file_queue
                self._file_handler = file_handler
                self._queue_handler = queue_handler
                self._ui_handler = ui_handler
                self._listener = listener
                self._active_log_file = str(path)
            except Exception as exc:
                self._last_error = str(exc)
                self._enabled = False
                self._configured = False
                raise algorithm_error(INVALID_ARGUMENT, f"日志初始化失败: {exc}", "configure_logging") from exc

    def drain(self, max_items: int = 100) -> tuple[LogEvent, ...]:
        if max_items <= 0:
            raise algorithm_error(INVALID_ARGUMENT, "max_items必须大于0", "drain_log_events")
        events: list[LogEvent] = []
        for _ in range(max_items):
            try:
                record = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            events.append(self._to_event(record))
        return tuple(events)

    def status(self) -> LoggingStatus:
        with self._lock:
            return LoggingStatus(
                enabled=self._enabled,
                active_log_file=self._active_log_file,
                dropped_file_records=self._dropped_file_records,
                dropped_ui_events=self._dropped_ui_events,
                last_logging_error=self._last_error,
            )

    def shutdown(self) -> None:
        with self._lock:
            package_logger = logging.getLogger("eeg_algorithm")
            if self._queue_handler is not None:
                package_logger.removeHandler(self._queue_handler)
            if self._ui_handler is not None:
                package_logger.removeHandler(self._ui_handler)
            if self._listener is not None:
                try:
                    self._listener.stop()
                except queue.Full:
                    if self._file_queue is not None:
                        try:
                            self._file_queue.get_nowait()
                        except queue.Empty:
                            pass
                    self._listener.stop()
                except Exception as exc:
                    self._last_error = str(exc)
            if self._file_handler is not None:
                self._file_handler.flush()
                self._file_handler.close()
            self._listener = None
            self._file_handler = None
            self._queue_handler = None
            self._ui_handler = None
            self._file_queue = None
            self._enabled = False

    def _validate(self, config: LoggingConfig) -> None:
        if config.enabled and not config.directory.strip():
            raise algorithm_error(INVALID_ARGUMENT, "启用日志时directory不能为空", "configure_logging")
        if config.rotate_max_bytes <= 0 or config.rotate_backup_count < 0:
            raise algorithm_error(INVALID_ARGUMENT, "日志轮转参数非法", "configure_logging")
        if config.event_queue_capacity <= 0 or config.performance_interval_s <= 0:
            raise algorithm_error(INVALID_ARGUMENT, "日志队列容量和性能周期必须大于0", "configure_logging")

    def _increment_file_drop(self) -> None:
        with self._lock:
            self._dropped_file_records += 1

    def _increment_ui_drop(self) -> None:
        with self._lock:
            self._dropped_ui_events += 1

    @staticmethod
    def _to_event(record: logging.LogRecord) -> LogEvent:
        return LogEvent(
            timestamp_utc_ns=int(record.created * 1_000_000_000),
            level=LogLevel(record.levelname),
            code=str(getattr(record, "code", "UNSPECIFIED")),
            message=record.getMessage(),
            operation=getattr(record, "operation", None),
            session_id=getattr(record, "session_id", None),
            request_id=getattr(record, "request_id", None),
            sequence_id=getattr(record, "sequence_id", None),
            duration_ms=getattr(record, "duration_ms", None),
        )


_manager = LoggingManager()


def configure(config: LoggingConfig) -> None:
    _manager.configure(config)


def drain_log_events(max_items: int = 100) -> tuple[LogEvent, ...]:
    return _manager.drain(max_items)


def get_status() -> LoggingStatus:
    return _manager.status()


def shutdown() -> None:
    _manager.shutdown()


def is_configured() -> bool:
    return _manager.configured

