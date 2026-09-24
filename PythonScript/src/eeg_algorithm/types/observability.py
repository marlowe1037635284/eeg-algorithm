"""可观测性 DTO：日志配置、日志事件与日志状态。"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class LogLevel(Enum):
    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    CRITICAL = "CRITICAL"


@dataclass(frozen=True)
class LoggingConfig:
    enabled: bool = True
    directory: str = ""
    min_level: LogLevel = LogLevel.INFO
    rotate_max_bytes: int = 20 * 1024 * 1024
    rotate_backup_count: int = 10
    ui_event_min_level: LogLevel = LogLevel.WARNING
    event_queue_capacity: int = 1000
    performance_interval_s: float = 5.0


@dataclass(frozen=True)
class LogEvent:
    timestamp_utc_ns: int
    level: LogLevel
    code: str
    message: str
    operation: str | None = None
    session_id: int | None = None
    request_id: int | None = None
    sequence_id: int | None = None
    duration_ms: float | None = None


@dataclass(frozen=True)
class LoggingStatus:
    enabled: bool
    active_log_file: str | None
    dropped_file_records: int
    dropped_ui_events: int
    last_logging_error: str | None
