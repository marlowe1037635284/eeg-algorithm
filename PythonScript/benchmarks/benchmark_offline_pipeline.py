from __future__ import annotations

import time

import numpy as np

from eeg_algorithm.internal.offline.pipeline import run_preprocessing_pipeline
from eeg_algorithm.types import (
    ArtifactDetectionConfig,
    ChannelLayout,
    HighPassConfig,
    LowPassConfig,
    NotchConfig,
    OfflineAsrConfig,
    OfflineReferenceConfig,
    PreprocessConfig,
    QualityControlConfig,
    ResampleConfig,
    SignalBlock,
)

layout = ChannelLayout(tuple(f"CH{i}" for i in range(32)), 1000.0)
values = np.random.default_rng(7).normal(size=(32, 60_000)).astype(np.float32)
timestamps = np.arange(60_000, dtype=np.int64) * 1_000_000
block = SignalBlock(0, timestamps, values)
config = PreprocessConfig(
    preprocess_version=1,
    high_pass=HighPassConfig(True, 0.5),
    low_pass=LowPassConfig(True, 45.0),
    notch=NotchConfig(True),
    reference=OfflineReferenceConfig(False),
    asr=OfflineAsrConfig(False),
    artifact=ArtifactDetectionConfig(False),
    resample=ResampleConfig(True, 250.0),
    quality_control=QualityControlConfig(
        null_weak_enabled=False, amplitude_outlier_enabled=False, low_correlation_enabled=False
    ),
)
started = time.perf_counter()
result, _, _ = run_preprocessing_pipeline(block, layout, config)
print(f"seconds={time.perf_counter() - started:.3f} output_shape={result.signal.values.shape}")
