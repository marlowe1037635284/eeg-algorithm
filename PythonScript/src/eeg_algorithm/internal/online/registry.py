"""在线会话注册表。"""

from __future__ import annotations

import threading

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.online.session import OnlineSession
from eeg_algorithm.internal.session_ids import next_session_id
from eeg_algorithm.types.online import OnlineConfig


class OnlineSessionRegistry:
    """管理在线会话 ID 与生命周期。"""

    def __init__(self) -> None:
        self._sessions: dict[int, OnlineSession] = {}
        self._lock = threading.Lock()

    def create(self, config: OnlineConfig) -> int:
        session = OnlineSession(config)
        session_id = next_session_id()
        session._set_session_id(session_id)
        with self._lock:
            self._sessions[session_id] = session
        return session_id

    def get(self, session_id: int) -> OnlineSession:
        with self._lock:
            session = self._sessions.get(session_id)
        if session is None:
            raise error(
                ErrorCode.SESSION_NOT_FOUND,
                f"在线会话 {session_id} 不存在或已关闭",
                "get_online_session",
            )
        return session

    def close(self, session_id: int) -> None:
        with self._lock:
            session = self._sessions.pop(session_id, None)
        if session is not None:
            session.close()

    def close_all(self) -> None:
        with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            session.close()
