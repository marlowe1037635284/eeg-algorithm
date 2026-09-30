from __future__ import annotations

from threading import RLock

from eeg_algorithm.errors import SESSION_NOT_FOUND, algorithm_error
from eeg_algorithm.types import OnlineConfig

from eeg_algorithm.internal.session_ids import next_session_id

from .session import OnlineSession


class OnlineSessionRegistry:
    def __init__(self) -> None:
        self._sessions: dict[int, OnlineSession] = {}
        self._lock = RLock()

    def create(self, config: OnlineConfig) -> int:
        with self._lock:
            session_id = next_session_id()
            self._sessions[session_id] = OnlineSession(session_id, config)
            return session_id

    def get(self, session_id: int) -> OnlineSession:
        with self._lock:
            try:
                return self._sessions[session_id]
            except KeyError as exc:
                raise algorithm_error(SESSION_NOT_FOUND, "在线会话不存在", "OnlineSessionRegistry.get", session_id=session_id) from exc

    def close(self, session_id: int) -> None:
        with self._lock:
            session = self.get(session_id)
            session.close()
            del self._sessions[session_id]

    def close_all(self) -> None:
        with self._lock:
            for session in tuple(self._sessions.values()):
                session.close()
            self._sessions.clear()

