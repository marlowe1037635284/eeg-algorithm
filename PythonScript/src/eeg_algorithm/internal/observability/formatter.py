"""JSON Lines 日志格式化。"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone


class JsonLinesFormatter(logging.Formatter):
    """每行输出一条 JSON 记录。"""

    def format(self, record: logging.LogRecord) -> str:
        ts = datetime.fromtimestamp(record.created, tz=timezone.utc)
        timestamp = ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{record.msecs:03.0f}Z"
        payload = {
            "timestamp": timestamp,
            "level": record.levelname,
            "logger": record.name,
            "code": getattr(record, "code", ""),
            "message": record.getMessage(),
            "operation": getattr(record, "operation", None),
            "session_id": getattr(record, "session_id", None),
            "request_id": getattr(record, "request_id", None),
            "sequence_id": getattr(record, "sequence_id", None),
            "config_version": getattr(record, "config_version", None),
            "preprocess_version": getattr(record, "preprocess_version", None),
            "duration_ms": getattr(record, "duration_ms", None),
            "thread": record.threadName,
        }
        return json.dumps(payload, ensure_ascii=False)
