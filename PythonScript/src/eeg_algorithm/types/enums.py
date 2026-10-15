from enum import Enum


class ReferenceMethod(Enum):
    OFF = "off"
    BILATERAL_MASTOIDS = "bilateral_mastoids"
    COMMON_AVERAGE = "common_average"


class BandPreset(Enum):
    DELTA = "delta"
    THETA = "theta"
    ALPHA = "alpha"
    BETA = "beta"
    GAMMA = "gamma"
    FULL_0_5_30 = "full_0_5_30"
    FULL_0_5_45 = "full_0_5_45"
    CUSTOM = "custom"


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

