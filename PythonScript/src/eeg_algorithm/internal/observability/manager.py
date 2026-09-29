"""日志系统管理器（单例）。

职责：
- 初始化、重新配置和关闭日志系统。
- 管理文件日志队列和界面告警队列。
- 提供 ``drain_log_events()`` 和日志状态查询。
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import queue
import threading
import time
from pathlib import Path

from eeg_algorithm.internal.observability.formatter import JsonLinesFormatter
from eeg_algorithm.internal.observability.handlers import BoundedQueueHandler
from eeg_algorithm.internal.observability.performance import PerformanceAggregator
from eeg_algorithm.types.observability import (
    LogEvent,
    LoggingConfig,
    LoggingStatus,
    LogLevel,
)

_LEVEL_TO_INT: dict[LogLevel, int] = {
    LogLevel.DEBUG: logging.DEBUG,
    LogLevel.INFO: logging.INFO,
    LogLevel.WARNING: logging.WARNING,
    LogLevel.ERROR: logging.ERROR,
    LogLevel.CRITICAL: logging.CRITICAL,
}

_ROOT = "eeg_algorithm"


class _ObservabilityManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._config: LoggingConfig | None = None
        self._root_logger = logging.getLogger(_ROOT)
        self._root_logger.setLevel(logging.DEBUG)
        self._root_logger.addHandler(logging.NullHandler())

        self._queue_handler: BoundedQueueHandler | None = None
        self._file_handler: logging.Handler | None = None
        self._file_queue: "queue.Queue[logging.LogRecord] | None" = None
        self._ui_queue: "queue.Queue[LogEvent] | None" = None
        self._listener: logging.handlers.QueueListener | None = None

        self._dropped_file = 0
        self._dropped_ui = 0
        self._last_error: str | None = None
        self._active_file: str | None = None
        self._performance = PerformanceAggregator()

    # ---- 配置 ----
    def configure(self, config: LoggingConfig) -> None:
        with self._lock:
            self._shutdown_locked()
            self._config = config
            if not config.enabled:
                self._active_file = None
                return

            log_dir = Path(config.directory) if config.directory else Path.cwd() / "logs"
            try:
                log_dir.mkdir(parents=True, exist_ok=True)
                filename = (
                    f"eeg_algorithm-{time.strftime('%Y%m%d')}-{os.getpid()}.jsonl"
                )
                path = log_dir / filename
                self._active_file = str(path)

                self._file_queue = queue.Queue(maxsize=config.event_queue_capacity)
                self._ui_queue = queue.Queue(maxsize=config.event_queue_capacity)

                fh = logging.handlers.RotatingFileHandler(
                    path,
                    maxBytes=config.rotate_max_bytes,
                    backupCount=config.rotate_backup_count,
                    encoding="utf-8",
                )
                fh.setFormatter(JsonLinesFormatter())
                fh.setLevel(logging.DEBUG)
                self._file_handler = fh

                qh = BoundedQueueHandler(
                    self._file_queue,
                    self._ui_queue,
                    _LEVEL_TO_INT[config.ui_event_min_level],
                    self._on_file_drop,
                    self._on_ui_drop,
                )
                qh.setLevel(_LEVEL_TO_INT[config.min_level])
                self._queue_handler = qh
                self._root_logger.addHandler(qh)

                self._listener = logging.handlers.QueueListener(
                    self._file_queue, fh, respect_handler_level=True
                )
                self._listener.start()
            except Exception as exc:  # noqa: BLE001
                self._last_error = str(exc)
                self._shutdown_locked()

    # ---- 回调 ----
    def _on_file_drop(self) -> None:
        self._dropped_file += 1

    def _on_ui_drop(self) -> None:
        self._dropped_ui += 1

    # ---- 查询 ----
    def drain_log_events(self, max_items: int = 100) -> tuple[LogEvent, ...]:
        ui_queue = self._ui_queue
        if ui_queue is None:
            return ()
        events: list[LogEvent] = []
        while len(events) < max_items:
            try:
                events.append(ui_queue.get_nowait())
            except queue.Empty:
                break
        return tuple(events)

    def get_logging_status(self) -> LoggingStatus:
        with self._lock:
            enabled = (
                self._config is not None
                and self._config.enabled
                and self._listener is not None
            )
            return LoggingStatus(
                enabled=enabled,
                active_log_file=self._active_file,
                dropped_file_records=self._dropped_file,
                dropped_ui_events=self._dropped_ui,
                last_logging_error=self._last_error,
            )

    @property
    def performance(self) -> PerformanceAggregator:
        return self._performance

    # ---- 关闭 ----
    def close(self) -> None:
        with self._lock:
            self._shutdown_locked()
            self._active_file = None
            self._config = None

    def _shutdown_locked(self) -> None:
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
        if self._queue_handler is not None:
            self._root_logger.removeHandler(self._queue_handler)
            self._queue_handler = None
        if self._file_handler is not None:
            try:
                self._file_handler.close()
            except Exception:  # noqa: BLE001
                pass
            self._file_handler = None
        self._file_queue = None
        self._ui_queue = None


_manager = _ObservabilityManager()


def configure_logging(config: LoggingConfig) -> None:
    """配置异步日志系统。应在 ``create_api()`` 之前调用。"""
    _manager.configure(config)


def drain_log_events(max_items: int = 100) -> tuple[LogEvent, ...]:
    """供 C++ 周期性拉取告警事件。"""
    return _manager.drain_log_events(max_items)


def get_logging_status() -> LoggingStatus:
    return _manager.get_logging_status()


def close_logging() -> None:
    _manager.close()


def get_logger(name: str) -> logging.Logger:
    """获取 ``eeg_algorithm.<name>`` 命名空间下的 logger。"""
    return logging.getLogger(f"{_ROOT}.{name}")


def record_performance(operation: str, duration_us: float) -> None:
    """记录一次算法调用耗时。"""
    _manager.performance.record(operation, duration_us)


def performance_summary() -> dict:
    return _manager.performance.summarize()
