from dataclasses import FrozenInstanceError

import pytest

from eeg_algorithm.api import EegAlgorithmApi, create_api, get_api_version
from eeg_algorithm.types import LogLevel, LoggingConfig


def test_api_version_and_singleton() -> None:
    assert get_api_version() == "1.3"
    assert create_api() is create_api()


def test_api_class_is_public_and_surface_is_complete() -> None:
    assert EegAlgorithmApi.__module__ == "eeg_algorithm.api"
    expected_methods = {
        "create_online_session",
        "set_asr_reference",
        "update_processing_config",
        "push_sample",
        "push_block",
        "notify_gap",
        "query_online_topography",
        "query_online_spectrum",
        "reset_online_session",
        "get_online_status",
        "close_online_session",
        "create_offline_session",
        "run_preprocessing",
        "query_offline_spectrum",
        "query_offline_topography",
        "get_preprocessed_data",
        "get_offline_status",
        "close_offline_session",
        "drain_log_events",
        "get_logging_status",
        "close",
    }
    assert expected_methods <= set(dir(EegAlgorithmApi))


def test_dto_is_frozen() -> None:
    config = LoggingConfig(enabled=False)
    with pytest.raises(FrozenInstanceError):
        config.min_level = LogLevel.DEBUG  # type: ignore[misc]
