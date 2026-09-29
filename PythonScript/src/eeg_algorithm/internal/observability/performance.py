"""性能聚合：调用次数、平均耗时、P99、最大耗时。"""

from __future__ import annotations

import threading
from collections import defaultdict


class PerformanceAggregator:
    """按操作名聚合耗时统计，不在每个采样点写日志。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._stats: dict[str, dict] = defaultdict(
            lambda: {"count": 0, "total_us": 0.0, "max_us": 0.0, "samples": []}
        )

    def record(self, operation: str, duration_us: float) -> None:
        with self._lock:
            s = self._stats[operation]
            s["count"] += 1
            s["total_us"] += duration_us
            s["max_us"] = max(s["max_us"], duration_us)
            s["samples"].append(duration_us)

    def summarize(self) -> dict[str, dict[str, float | int]]:
        with self._lock:
            out: dict[str, dict[str, float | int]] = {}
            for op, s in self._stats.items():
                count = s["count"]
                out[op] = {
                    "count": count,
                    "avg_us": s["total_us"] / count if count else 0.0,
                    "p99_us": _percentile(s["samples"], 99.0),
                    "max_us": s["max_us"],
                }
            return out

    def clear(self) -> None:
        with self._lock:
            self._stats.clear()


def _percentile(sorted_or_not: list[float], p: float) -> float:
    if not sorted_or_not:
        return 0.0
    values = sorted(sorted_or_not)
    k = (len(values) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    frac = k - lo
    return values[lo] + (values[hi] - values[lo]) * frac
