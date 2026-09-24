"""公共 API：C++ 通过 pybind11 调用的唯一业务入口。

对外提供 :func:`get_api_version` 与 :func:`create_api`，以及
:class:`EegAlgorithmApi` 门面。具体实现统一委托给 ``internal.facade``。
"""

from __future__ import annotations

from eeg_algorithm.internal.facade import Facade
from eeg_algorithm.internal.observability import (
    configure_logging as _configure_logging,
    drain_log_events as _drain_log_events,
    get_logging_status as _get_logging_status,
)
from eeg_algorithm.types.common import ChannelLayout, GapInfo, SampleFrame, SignalBlock
from eeg_algorithm.types.observability import LogEvent, LoggingConfig, LoggingStatus
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
from eeg_algorithm.version import API_VERSION


class EegAlgorithmApi:
    """C++ 调用算法功能的唯一业务入口。"""

    def __init__(self) -> None:
        self._facade = Facade()

    # ---- 在线 ----
    def create_online_session(self, config: OnlineConfig) -> int:
        return self._facade.create_online_session(config)

    def set_asr_reference(self, session_id: int, reference: SignalBlock) -> None:
        self._facade.set_asr_reference(session_id, reference)

    def update_processing_config(
        self, session_id: int, config: OnlineProcessingConfig
    ) -> ConfigUpdateResult:
        return self._facade.update_processing_config(session_id, config)

    def push_sample(self, session_id: int, frame: SampleFrame) -> OnlineResult:
        return self._facade.push_sample(session_id, frame)

    def push_block(self, session_id: int, block: SignalBlock) -> OnlineResult:
        return self._facade.push_block(session_id, block)

    def notify_gap(self, session_id: int, gap: GapInfo) -> None:
        self._facade.notify_gap(session_id, gap)

    def query_online_topography(self, session_id: int, query: TopographyQuery) -> TopographyResult:
        return self._facade.query_online_topography(session_id, query)

    def query_online_spectrum(self, session_id: int, query: SpectrumQuery) -> SpectrumResult:
        return self._facade.query_online_spectrum(session_id, query)

    def reset_online_session(self, session_id: int) -> None:
        self._facade.reset_online_session(session_id)

    def get_online_status(self, session_id: int) -> SessionStatus:
        return self._facade.get_online_status(session_id)

    def close_online_session(self, session_id: int) -> None:
        self._facade.close_online_session(session_id)

    # ---- 离线 ----
    def create_offline_session(self, layout: ChannelLayout, raw_signal: SignalBlock) -> int:
        return self._facade.create_offline_session(layout, raw_signal)

    def run_preprocessing(self, session_id: int, config: PreprocessConfig) -> PreprocessResult:
        return self._facade.run_preprocessing(session_id, config)

    def query_offline_spectrum(
        self, session_id: int, query: OfflineSpectrumQuery
    ) -> OfflineSpectrumResult:
        return self._facade.query_offline_spectrum(session_id, query)

    def query_offline_topography(
        self, session_id: int, query: OfflineTopographyQuery
    ) -> OfflineTopographyResult:
        return self._facade.query_offline_topography(session_id, query)

    def get_preprocessed_data(self, session_id: int) -> PreprocessedDataset:
        return self._facade.get_preprocessed_data(session_id)

    def get_offline_status(self, session_id: int) -> OfflineSessionStatus:
        return self._facade.get_offline_status(session_id)

    def close_offline_session(self, session_id: int) -> None:
        self._facade.close_offline_session(session_id)

    # ---- 日志 ----
    def drain_log_events(self, max_items: int = 100) -> tuple[LogEvent, ...]:
        return _drain_log_events(max_items)

    def get_logging_status(self) -> LoggingStatus:
        return _get_logging_status()

    # ---- 生命周期 ----
    def close(self) -> None:
        self._facade.close()


_api_instance: EegAlgorithmApi | None = None


def get_api_version() -> str:
    """返回在线与离线统一接口版本。"""
    return API_VERSION


def create_api() -> EegAlgorithmApi:
    """创建进程内唯一的 API 门面；重复调用返回同一对象。"""
    global _api_instance
    if _api_instance is None:
        _api_instance = EegAlgorithmApi()
    return _api_instance


def configure_logging(config: LoggingConfig) -> None:
    """配置异步日志系统。应在 ``create_api()`` 之前调用。"""
    _configure_logging(config)


__all__ = [
    "API_VERSION",
    "EegAlgorithmApi",
    "configure_logging",
    "create_api",
    "get_api_version",
]
