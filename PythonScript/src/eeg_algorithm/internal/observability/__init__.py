"""异步日志与可观测性子包。"""

from eeg_algorithm.internal.observability.manager import (
    close_logging,
    configure_logging,
    drain_log_events,
    get_logger,
    get_logging_status,
    performance_summary,
    record_performance,
)
from eeg_algorithm.internal.observability.performance import PerformanceAggregator

__all__ = [
    "PerformanceAggregator",
    "close_logging",
    "configure_logging",
    "drain_log_events",
    "get_logger",
    "get_logging_status",
    "performance_summary",
    "record_performance",
]
