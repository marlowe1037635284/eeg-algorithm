from __future__ import annotations

from eeg_algorithm.api import EegAlgorithmApi
from eeg_algorithm.types import (
    AbsoluteTimeRange,
    ArtifactDetectionConfig,
    HighPassConfig,
    LowPassConfig,
    NotchConfig,
    OfflineAsrConfig,
    OfflineReferenceConfig,
    OfflineSpectrumQuery,
    OfflineTopographyQuery,
    PreprocessConfig,
    ResampleConfig,
)


def test_offline_preprocess_and_spectrum(layout, signal_block) -> None:
    api = EegAlgorithmApi()
    session_id = api.create_offline_session(layout, signal_block)
    config = PreprocessConfig(
        preprocess_version=1,
        high_pass=HighPassConfig(True, 1.0),
        low_pass=LowPassConfig(True, 30.0),
        notch=NotchConfig(False),
        reference=OfflineReferenceConfig(False),
        asr=OfflineAsrConfig(False),
        artifact=ArtifactDetectionConfig(False),
        resample=ResampleConfig(True, 50.0),
    )
    result = api.run_preprocessing(session_id, config)
    assert result.sample_count == 500
    assert result.applied_steps == ("band_pass", "resample")
    query = OfflineSpectrumQuery(
        request_id=4,
        preprocess_version=1,
        channel_name="F3",
        selected_range=AbsoluteTimeRange(2_000_000_000, 6_000_000_000),
        frequency_range_hz=(1.0, 20.0),
    )
    spectrum = api.query_offline_spectrum(session_id, query)
    assert spectrum.request_id == 4
    assert spectrum.psd.size > 0
    topography = api.query_offline_topography(
        session_id,
        OfflineTopographyQuery(
            request_id=5,
            preprocess_version=1,
            selected_range=AbsoluteTimeRange(2_000_000_000, 6_000_000_000),
            grid_width=24,
            grid_height=24,
        ),
    )
    assert topography.band_names == ("full", "delta", "theta", "alpha", "beta", "gamma")
    assert topography.grid_values.shape == (6, 24, 24)
    assert topography.electrode_values.shape == (6, 4)
    api.close()
