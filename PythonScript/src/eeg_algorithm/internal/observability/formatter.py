from __future__ import annotations

import json
import logging
from datetime import datetime, timezone


class JsonLineFormatter(logging.Formatter):
    _OPTIONAL_FIELDS = (
        "code",
        "operation",
        "session_id",
        "request_id",
        "sequence_id",
        "config_version",
        "preprocess_version",
        "duration_ms",
    )

    def format(self, record: logging.LogRecord) -> str:
        timestamp = datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds")
        payload: dict[str, object] = {
            "timestamp": timestamp.replace("+00:00", "Z"),
            "timestamp_utc_ns": int(record.created * 1_000_000_000),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "thread": record.threadName,
            "process_id": record.process,
        }
        for name in self._OPTIONAL_FIELDS:
            value = getattr(record, name, None)
            if value is not None:
                payload[name] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str)

