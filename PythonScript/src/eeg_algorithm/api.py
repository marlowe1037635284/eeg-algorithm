from __future__ import annotations

import logging
from threading import RLock

from eeg_algorithm.errors import INVALID_STATE, algorithm_error
from eeg_algorithm.internal.observability.context import get_logger, log_event
from eeg_algorithm.internal.observability.manager import (
    configure,
    drain_log_events,
    get_status,
    shutdown,
)
from eeg_algorithm.internal.offline.registry import OfflineSessionRegistry
from eeg_algorithm.internal.online.registry import OnlineSessionRegistry
from eeg_algorithm.types import (
    ChannelLayout,
    ConfigUpdateResult,
    GapInfo,
    LogEvent,
    LoggingConfig,
    LoggingStatus,
    OfflineQualityQuery,
    OfflineSessionStatus,
    OfflineSpectrumQuery,
    OfflineSpectrumResult,
    OfflineStatisticsQuery,
    OfflineStatisticsResult,
    OfflineTopographyQuery,
    OfflineTopographyResult,
    OnlineConfig,
    OnlineProcessingConfig,
    OnlineResult,
    PreprocessConfig,
    PreprocessedDataset,
    PreprocessResult,
    QualityReport,
    SampleFrame,
    SessionStatus,
    SignalBlock,
    SpectrumQuery,
    SpectrumResult,
    TopographyQuery,
    TopographyResult,
)
from eeg_algorithm.version import API_VERSION

_lock = RLock()
_api_instance: EegAlgorithmApi | None = None


class EegAlgorithmApi:
    """C++可调用的在线、离线及日志统一公共门面。"""

    def __init__(self) -> None:
        """初始化在线、离线会话注册表及日志。"""
        self._online = OnlineSessionRegistry()
        self._offline = OfflineSessionRegistry()
        self._closed = False
        self._logger = get_logger(__name__)
        log_event(self._logger, logging.INFO, "EEG算法API创建", code="API_CREATED", operation="create_api")

    def create_online_session(self, config: OnlineConfig) -> int:
        """创建在线会话，返回会话ID。"""
        self._ensure_open("create_online_session")
        return self._online.create(config)

    def set_asr_reference(self, session_id: int, reference: SignalBlock) -> None:
        """设置ASR参考信号。"""
        self._ensure_open("set_asr_reference")
        self._online.get(session_id).set_asr_reference(reference)

    def update_processing_config(
        self,
        session_id: int,
        config: OnlineProcessingConfig,
    ) -> ConfigUpdateResult:
        """更新在线处理配置。"""
        self._ensure_open("update_processing_config")
        return self._online.get(session_id).update_processing_config(config)

    def push_sample(self, session_id: int, frame: SampleFrame) -> OnlineResult:
        """推送单帧采样数据。"""
        self._ensure_open("push_sample")
        return self._online.get(session_id).push_sample(frame)

    def push_block(self, session_id: int, block: SignalBlock) -> OnlineResult:
        """推送信号数据块。"""
        self._ensure_open("push_block")
        return self._online.get(session_id).push_block(block)

    def notify_gap(self, session_id: int, gap: GapInfo) -> None:
        """通知数据断点信息。"""
        self._ensure_open("notify_gap")
        self._online.get(session_id).notify_gap(gap)

    def query_online_topography(
        self,
        session_id: int,
        query: TopographyQuery,
    ) -> TopographyResult:
        """查询在线地形图。"""
        self._ensure_open("query_online_topography")
        return self._online.get(session_id).query_topography(query)

    def query_online_spectrum(
        self,
        session_id: int,
        query: SpectrumQuery,
    ) -> SpectrumResult:
        """查询在线频谱。"""
        self._ensure_open("query_online_spectrum")
        return self._online.get(session_id).query_spectrum(query)

    def reset_online_session(self, session_id: int) -> None:
        """重置在线会话。"""
        self._ensure_open("reset_online_session")
        self._online.get(session_id).reset()

    def get_online_status(self, session_id: int) -> SessionStatus:
        """获取在线会话状态。"""
        self._ensure_open("get_online_status")
        return self._online.get(session_id).status()

    def close_online_session(self, session_id: int) -> None:
        """关闭在线会话。"""
        self._ensure_open("close_online_session")
        self._online.close(session_id)

    def create_offline_session(
        self,
        layout: ChannelLayout,
        raw_signal: SignalBlock,
    ) -> int:
        """创建离线会话，返回会话ID。"""
        self._ensure_open("create_offline_session")
        return self._offline.create(layout, raw_signal)

    def run_preprocessing(
        self,
        session_id: int,
        config: PreprocessConfig,
    ) -> PreprocessResult:
        """运行离线预处理。"""
        self._ensure_open("run_preprocessing")
        return self._offline.get(session_id).preprocess(config)

    def query_offline_spectrum(
        self,
        session_id: int,
        query: OfflineSpectrumQuery,
    ) -> OfflineSpectrumResult:
        """查询离线频谱。"""
        self._ensure_open("query_offline_spectrum")
        return self._offline.get(session_id).query_spectrum(query)

    def query_offline_topography(
        self,
        session_id: int,
        query: OfflineTopographyQuery,
    ) -> OfflineTopographyResult:
        """查询离线地形图。"""
        self._ensure_open("query_offline_topography")
        return self._offline.get(session_id).query_topography(query)

    def query_offline_statistics(
        self,
        session_id: int,
        query: OfflineStatisticsQuery,
    ) -> OfflineStatisticsResult:
        """查询离线多通道统计指标。"""
        self._ensure_open("query_offline_statistics")
        return self._offline.get(session_id).query_statistics(query)

    def query_offline_quality(
        self,
        session_id: int,
        query: OfflineQualityQuery,
    ) -> QualityReport:
        """在预处理后的选段数据上执行质检检测（只检测，不修改数据）。"""
        self._ensure_open("query_offline_quality")
        return self._offline.get(session_id).query_quality(query)

    def get_preprocessed_data(self, session_id: int) -> PreprocessedDataset:
        """获取预处理后的数据集。"""
        self._ensure_open("get_preprocessed_data")
        return self._offline.get(session_id).get_preprocessed_data()

    def get_offline_status(self, session_id: int) -> OfflineSessionStatus:
        """获取离线会话状态。"""
        self._ensure_open("get_offline_status")
        return self._offline.get(session_id).status()

    def close_offline_session(self, session_id: int) -> None:
        """关闭离线会话。"""
        self._ensure_open("close_offline_session")
        self._offline.close(session_id)

    def drain_log_events(self, max_items: int = 100) -> tuple[LogEvent, ...]:
        """排空并获取日志事件。"""
        self._ensure_open("drain_log_events")
        return drain_log_events(max_items)

    def get_logging_status(self) -> LoggingStatus:
        """获取日志状态。"""
        self._ensure_open("get_logging_status")
        return get_status()

    def close(self) -> None:
        """关闭API，释放所有会话资源。"""
        if self._closed:
            return
        self._online.close_all()
        self._offline.close_all()
        log_event(self._logger, logging.INFO, "EEG算法API关闭", code="API_CLOSED", operation="close")
        self._closed = True
        shutdown()

    def _ensure_open(self, operation: str) -> None:
        """校验API处于打开状态，否则抛出异常。"""
        if self._closed:
            raise algorithm_error(INVALID_STATE, "算法API已经关闭", operation)


def get_api_version() -> str:
    """获取API版本号。"""
    return API_VERSION


def configure_logging(config: LoggingConfig) -> None:
    """配置日志，须在create_api之前调用。"""
    with _lock:
        if _api_instance is not None:
            raise algorithm_error(INVALID_STATE, "必须在create_api之前配置日志", "configure_logging")
        configure(config)


def create_api() -> EegAlgorithmApi:
    """创建并返回单例的EegAlgorithmApi实例。"""
    global _api_instance
    with _lock:
        if _api_instance is None:
            _api_instance = EegAlgorithmApi()
        return _api_instance


__all__ = ["API_VERSION", "EegAlgorithmApi", "configure_logging", "create_api", "get_api_version"]
