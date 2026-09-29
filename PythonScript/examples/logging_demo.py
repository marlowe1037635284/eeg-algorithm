"""日志系统示例：配置异步日志、产生告警并轮询事件。

运行方式（在 ``algorithm`` 目录下）：

    $env:PYTHONPATH = "src"
    python examples/logging_demo.py
"""

from __future__ import annotations

import tempfile

from eeg_algorithm import api
from eeg_algorithm.types import LoggingConfig, LogLevel


def main() -> None:
    log_dir = tempfile.mkdtemp(prefix="eeg-log-demo-")
    api.configure_logging(
        LoggingConfig(
            enabled=True,
            directory=log_dir,
            min_level=LogLevel.INFO,
            ui_event_min_level=LogLevel.WARNING,
        )
    )

    alg = api.create_api()
    status = alg.get_logging_status()
    print(f"logging enabled: {status.enabled}")
    print(f"log file: {status.active_log_file}")

    # 直接拉取告警事件（本示例无业务调用产生告警，通常为空）。
    events = alg.drain_log_events(max_items=10)
    print(f"drained {len(events)} events")

    alg.close()
    status = alg.get_logging_status()
    print(f"logging enabled after close: {status.enabled}")
    print(f"dropped file records: {status.dropped_file_records}")


if __name__ == "__main__":
    main()
