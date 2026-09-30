from __future__ import annotations

import json
import logging

from eeg_algorithm.internal.observability.context import get_logger, log_event
from eeg_algorithm.internal.observability.manager import LoggingManager
from eeg_algorithm.types import LogLevel, LoggingConfig


def test_async_file_and_ui_event(tmp_path) -> None:
    manager = LoggingManager()
    manager.configure(
        LoggingConfig(
            directory=str(tmp_path),
            min_level=LogLevel.INFO,
            ui_event_min_level=LogLevel.WARNING,
        )
    )
    logger = get_logger("eeg_algorithm.tests")
    log_event(logger, logging.INFO, "normal", code="NORMAL")
    log_event(logger, logging.WARNING, "warning", code="WARN", session_id=7, sequence_id=11)
    events = manager.drain(10)
    assert len(events) == 1
    assert events[0].code == "WARN"
    assert events[0].session_id == 7
    path = manager.status().active_log_file
    manager.shutdown()
    assert path is not None
    records = [json.loads(line) for line in open(path, encoding="utf-8")]
    assert [item["code"] for item in records] == ["NORMAL", "WARN"]


def test_disabled_logging_creates_no_file(tmp_path) -> None:
    manager = LoggingManager()
    manager.configure(LoggingConfig(enabled=False, directory=str(tmp_path)))
    assert manager.status().enabled is False
    manager.shutdown()
    assert list(tmp_path.iterdir()) == []

