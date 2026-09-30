from __future__ import annotations

import time

import numpy as np

from eeg_algorithm.internal.offline.pipeline import run_preprocessing_pipeline
from eeg_algorithm.types import (
    BandPassConfig,
    BaselineConfig,
    ChannelLayout,
    NotchConfig,
    OfflineAsrConfig,
    OfflineReferenceConfig,
    PreprocessConfig,
    ResampleConfig,
    SignalBlock,
)

layout = ChannelLayout(tuple(f"CH{i}" for i in range(32)), 1000.0)
values = np.random.default_rng(7).normal(size=(32, 60_000)).astype(np.float32)
timestamps = np.arange(60_000, dtype=np.int64) * 1_000_000
block = SignalBlock(0, timestamps, values)
config = PreprocessConfig(
    1,
    BandPassConfig(True, 0.5, 45.0),
    NotchConfig(True),
    OfflineReferenceConfig(False),
    OfflineAsrConfig(False),
    ResampleConfig(True, 250.0),
    BaselineConfig(False),
    False,
)
started = time.perf_counter()
result = run_preprocessing_pipeline(block, layout, config)
print(f"seconds={time.perf_counter() - started:.3f} output_shape={result.signal.values.shape}")

