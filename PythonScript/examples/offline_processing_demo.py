import numpy as np

from eeg_algorithm.api import create_api
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

layout = ChannelLayout(("C3", "C4"), 250.0)
values = np.zeros((2, 1000), dtype=np.float32)
timestamps = np.arange(1000, dtype=np.int64) * 4_000_000
api = create_api()
session_id = api.create_offline_session(layout, SignalBlock(0, timestamps, values))
config = PreprocessConfig(
    1,
    BandPassConfig(False, 1.0, 30.0),
    NotchConfig(False),
    OfflineReferenceConfig(False),
    OfflineAsrConfig(False),
    ResampleConfig(False, 250.0),
    BaselineConfig(False),
)
result = api.run_preprocessing(session_id, config)
print("processed samples:", result.sample_count)
print("applied steps:", result.applied_steps)
api.close()
