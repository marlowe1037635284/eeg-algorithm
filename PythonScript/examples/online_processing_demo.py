import numpy as np

from eeg_algorithm.api import create_api
from eeg_algorithm.types import (
    AsrConfig,
    ChannelLayout,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    ReferenceConfig,
    SignalBlock,
    ToggleFilterConfig,
)

layout = ChannelLayout(("C3", "C4"), 250.0)
disabled = ToggleFilterConfig(False)
config = OnlineConfig(
    layout,
    OnlineProcessingConfig(1, disabled, disabled, disabled, False),
    ReferenceConfig(),
    AsrConfig(),
    PhaseModelConfig(False, "", ()),
    rolling_window_s=5.0,
)
api = create_api()
session_id = api.create_online_session(config)
values = np.zeros((2, 25), dtype=np.float32)
timestamps = np.arange(25, dtype=np.int64) * 4_000_000
result = api.push_block(session_id, SignalBlock(0, timestamps, values))
print("processed shape:", result.processed_signal.values.shape)
print("status:", api.get_online_status(session_id))
api.close()
