from __future__ import annotations

import logging
import time
from collections import defaultdict
from dataclasses import dataclass, field
from threading import Lock

import numpy as np

from .context import get_logger, log_event


@dataclass
class _Series:
    values_us: list[int] = field(default_factory=list)
    last_emit_s: float = field(default_factory=time.monotonic)


class PerformanceAggregator:
    def __init__(self, interval_s: float = 5.0) -> None:
        self._interval_s = interval_s
        self._lock = Lock()
        self._series: dict[str, _Series] = defaultdict(_Series)
        self._logger = get_logger(__name__)

    def record(self, operation: str, duration_us: int, *, session_id: int | None = None) -> None:
        now = time.monotonic()
        with self._lock:
            series = self._series[operation]
            series.values_us.append(duration_us)
            if now - series.last_emit_s < self._interval_s:
                return
            values = np.asarray(series.values_us, dtype=np.float64)
            series.values_us.clear()
            series.last_emit_s = now
        log_event(
            self._logger,
            logging.INFO,
            f"性能汇总: count={values.size}, avg_us={values.mean():.1f}, "
            f"p99_us={np.percentile(values, 99):.1f}, max_us={values.max():.1f}",
            code="PERFORMANCE_SUMMARY",
            operation=operation,
            session_id=session_id,
            duration_ms=float(values.mean() / 1000.0),
        )

