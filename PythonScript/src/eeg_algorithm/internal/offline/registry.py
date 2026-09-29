"""离线会话注册表。"""

from __future__ import annotations

import threading

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.offline.session import OfflineSession
from eeg_algorithm.internal.session_ids import next_session_id
from eeg_algorithm.types.common import ChannelLayout, SignalBlock


class OfflineSessionRegistry:
    """管理离线会话 ID 与生命周期。"""

    def __init__(self) -> None:
        self._sessions: dict[int, OfflineSession] = {}
        self._lock = threading.Lock()

    def create(self, layout: ChannelLayout, raw_signal: SignalBlock) -> int:
        session = OfflineSession(layout, raw_signal)
        session_id = next_session_id()
        session._set_session_id(session_id)
        with self._lock:
            self._sessions[session_id] = session
        return session_id

    def get(self, session_id: int) -> OfflineSession:
        with self._lock:
            session = self._sessions.get(session_id)
        if session is None:
            raise error(
                ErrorCode.SESSION_NOT_FOUND,
                f"离线会话 {session_id} 不存在或已关闭",
                "get_offline_session",
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
