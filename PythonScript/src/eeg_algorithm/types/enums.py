"""跨语言枚举定义。"""

from __future__ import annotations

from enum import Enum


class ReferenceMethod(Enum):
    OFF = "off"
    BILATERAL_MASTOIDS = "bilateral_mastoids"
    COMMON_AVERAGE = "common_average"


class BandPreset(Enum):
    DELTA = "delta"                  # 0.5–4 Hz
    THETA = "theta"                  # 4–8 Hz
    ALPHA = "alpha"                  # 8–13 Hz
    BETA = "beta"                    # 13–30 Hz
    GAMMA = "gamma"                  # 30–45 Hz
    FULL_0_5_30 = "full_0_5_30"      # 0.5–30 Hz
    CUSTOM = "custom"


# 频段预设标准范围（单位 Hz）。
BAND_PRESET_RANGES: dict[BandPreset, tuple[float, float]] = {
    BandPreset.DELTA: (0.5, 4.0),
    BandPreset.THETA: (4.0, 8.0),
    BandPreset.ALPHA: (8.0, 13.0),
    BandPreset.BETA: (13.0, 30.0),
    BandPreset.GAMMA: (30.0, 45.0),
    BandPreset.FULL_0_5_30: (0.5, 30.0),
}


class QualityFlag(Enum):
    OK = "ok"
    WARMING_UP = "warming_up"
    DATA_GAP = "data_gap"
    ARTIFACT = "artifact"
    MODEL_INVALID = "model_invalid"
    TIMEOUT = "timeout"


class SessionState(Enum):
    CREATED = "created"
    WARMING_UP = "warming_up"
    RUNNING = "running"
    DEGRADED = "degraded"
    ERROR = "error"
    CLOSED = "closed"


class OfflineSessionState(Enum):
    RAW_READY = "raw_ready"
    PREPROCESSING = "preprocessing"
    PREPROCESSED = "preprocessed"
    ERROR = "error"
    CLOSED = "closed"
