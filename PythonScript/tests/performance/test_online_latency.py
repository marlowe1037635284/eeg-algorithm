from __future__ import annotations

import time

import numpy as np
import pytest

from eeg_algorithm.api import EegAlgorithmApi
from eeg_algorithm.types import (
    AsrConfig,
    ChannelLayout,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    ReferenceConfig,
    SampleFrame,
    ToggleFilterConfig,
)


@pytest.mark.performance
def test_1000_hz_python_point_throughput() -> None:
    layout = ChannelLayout(tuple(f"CH{i}" for i in range(32)), 1000.0)
    disabled = ToggleFilterConfig(False)
    config = OnlineConfig(
        layout,
        OnlineProcessingConfig(1, disabled, disabled, disabled, False),
        ReferenceConfig(),
        AsrConfig(),
        PhaseModelConfig(False, "", ()),
        rolling_window_s=2.0,
        return_processed_signal=False,
    )
    api = EegAlgorithmApi()
    session_id = api.create_online_session(config)
    values = np.zeros(32, dtype=np.float32)
    count = 2000
    started = time.perf_counter_ns()
    for index in range(count):
        api.push_sample(session_id, SampleFrame(index, index * 1_000_000, values))
    average_us = (time.perf_counter_ns() - started) / 1000.0 / count
    api.close()
    assert average_us < 1000.0, f"Python逐点平均耗时{average_us:.1f}us，超过1000us吞吐目标"
