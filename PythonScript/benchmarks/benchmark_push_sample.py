from __future__ import annotations

import time

import numpy as np

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

layout = ChannelLayout(tuple(f"CH{i}" for i in range(32)), 1000.0)
disabled = ToggleFilterConfig(False)
config = OnlineConfig(
    layout,
    OnlineProcessingConfig(1, disabled, disabled, disabled, False),
    ReferenceConfig(),
    AsrConfig(),
    PhaseModelConfig(False, "", ()),
    5.0,
    False,
)
api = EegAlgorithmApi()
session_id = api.create_online_session(config)
values = np.zeros(32, dtype=np.float32)
started = time.perf_counter_ns()
for index in range(10_000):
    api.push_sample(session_id, SampleFrame(index, index * 1_000_000, values))
elapsed_us = (time.perf_counter_ns() - started) / 1000
print(f"calls=10000 average_us={elapsed_us / 10000:.2f}")
api.close()
