from itertools import count
from threading import Lock

_counter = count(1)
_lock = Lock()


def next_session_id() -> int:
    with _lock:
        return next(_counter)

