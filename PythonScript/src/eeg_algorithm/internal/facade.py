"""公共门面：将 ``EegAlgorithmApi`` 的调用委托给在线/离线注册表。"""

from __future__ import annotations

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.observability import close_logging, get_logger
from eeg_algorithm.internal.offline.registry import OfflineSessionRegistry
from eeg_algorithm.internal.online.registry import OnlineSessionRegistry
from eeg_algorithm.types.common import ChannelLayout, GapInfo, SampleFrame, SignalBlock
from eeg_algorithm.types.offline import (
    OfflineSessionStatus,
    OfflineSpectrumQuery,
    OfflineSpectrumResult,
    OfflineTopographyQuery,
    OfflineTopographyResult,
    PreprocessConfig,
    PreprocessedDataset,
    PreprocessResult,
)
from eeg_algorithm.types.online import (
    ConfigUpdateResult,
    OnlineConfig,
    OnlineProcessingConfig,
    OnlineResult,
    SessionStatus,
    SpectrumQuery,
    SpectrumResult,
    TopographyQuery,
    TopographyResult,
)

_log = get_logger("facade")


class Facade:
    """进程内唯一的业务门面，持有在线与离线两个注册表。"""

    def __init__(self) -> None:
        self._online = OnlineSessionRegistry()
        self._offline = OfflineSessionRegistry()
        self._closed = False

    # ---- 在线 ----
    def create_online_session(self, config: OnlineConfig) -> int:
        self._ensure_open()
        return self._online.create(config)

    def set_asr_reference(self, session_id: int, reference: SignalBlock) -> None:
        self._ensure_open()
        self._online.get(session_id).set_asr_reference(reference)

    def update_processing_config(
        self, session_id: int, config: OnlineProcessingConfig
    ) -> ConfigUpdateResult:
        self._ensure_open()
        return self._online.get(session_id).update_processing_config(config)

    def push_sample(self, session_id: int, frame: SampleFrame) -> OnlineResult:
        self._ensure_open()
        return self._online.get(session_id).push_sample(frame)

    def push_block(self, session_id: int, block: SignalBlock) -> OnlineResult:
        self._ensure_open()
        return self._online.get(session_id).push_block(block)

    def notify_gap(self, session_id: int, gap: GapInfo) -> None:
        self._ensure_open()
        self._online.get(session_id).notify_gap(gap)

    def query_online_topography(self, session_id: int, query: TopographyQuery) -> TopographyResult:
        self._ensure_open()
        return self._online.get(session_id).query_topography(query)

    def query_online_spectrum(self, session_id: int, query: SpectrumQuery) -> SpectrumResult:
        self._ensure_open()
        return self._online.get(session_id).query_spectrum(query)

    def reset_online_session(self, session_id: int) -> None:
        self._ensure_open()
        self._online.get(session_id).reset()

    def get_online_status(self, session_id: int) -> SessionStatus:
        self._ensure_open()
        return self._online.get(session_id).status()

    def close_online_session(self, session_id: int) -> None:
        self._online.close(session_id)

    # ---- 离线 ----
    def create_offline_session(self, layout: ChannelLayout, raw_signal: SignalBlock) -> int:
        self._ensure_open()
        return self._offline.create(layout, raw_signal)

    def run_preprocessing(self, session_id: int, config: PreprocessConfig) -> PreprocessResult:
        self._ensure_open()
        return self._offline.get(session_id).preprocess(config)

    def query_offline_spectrum(
        self, session_id: int, query: OfflineSpectrumQuery
    ) -> OfflineSpectrumResult:
        self._ensure_open()
        return self._offline.get(session_id).query_spectrum(query)

    def query_offline_topography(
        self, session_id: int, query: OfflineTopographyQuery
    ) -> OfflineTopographyResult:
        self._ensure_open()
        return self._offline.get(session_id).query_topography(query)

    def get_preprocessed_data(self, session_id: int) -> PreprocessedDataset:
        self._ensure_open()
        return self._offline.get(session_id).get_preprocessed_data()

    def get_offline_status(self, session_id: int) -> OfflineSessionStatus:
        self._ensure_open()
        return self._offline.get(session_id).status()

    def close_offline_session(self, session_id: int) -> None:
        self._offline.close(session_id)

    # ---- 生命周期 ----
    def close(self) -> None:
        if self._closed:
            return
        self._online.close_all()
        self._offline.close_all()
        self._closed = True
        close_logging()

    def _ensure_open(self) -> None:
        if self._closed:
            raise error(ErrorCode.INVALID_STATE, "API 已关闭", "api")
