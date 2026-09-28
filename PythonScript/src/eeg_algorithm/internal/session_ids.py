"""全局会话 ID 生成器。

在线与离线会话共用同一个生成器，保证 ID 不重复。
"""

from __future__ import annotations

import itertools
import threading


class SessionIdGenerator:
    def __init__(self) -> None:
        self._counter = itertools.count(1)
        self._lock = threading.Lock()

    def next(self) -> int:
        with self._lock:
            return next(self._counter)


_generator = SessionIdGenerator()


def next_session_id() -> int:
    return _generator.next()
