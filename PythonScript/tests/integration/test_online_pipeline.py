from __future__ import annotations

import numpy as np
import pytest

from eeg_algorithm.errors import AlgorithmError, TIME_SEQUENCE_DISCONTINUITY
from eeg_algorithm.api import EegAlgorithmApi
from eeg_algorithm.types import (
    AsrConfig,
    BandPreset,
    FrequencyBand,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    ReferenceConfig,
    SampleFrame,
    SpectrumQuery,
    ToggleFilterConfig,
)


def _config(layout) -> OnlineConfig:
    disabled = ToggleFilterConfig(False)
    processing = OnlineProcessingConfig(1, disabled, disabled, disabled, False)
    return OnlineConfig(
        layout=layout,
        processing=processing,
        reference=ReferenceConfig(),
        asr=AsrConfig(),
        phase=PhaseModelConfig(False, "", ()),
        rolling_window_s=5.0,
    )


def _filtered_config(layout) -> OnlineConfig:
    processing = OnlineProcessingConfig(
        1,
        ToggleFilterConfig(True, low_hz=1.0),
        ToggleFilterConfig(True, high_hz=30.0),
        ToggleFilterConfig(False),
        False,
    )
    return OnlineConfig(
        layout=layout,
        processing=processing,
        reference=ReferenceConfig(),
        asr=AsrConfig(),
        phase=PhaseModelConfig(False, "", ()),
        rolling_window_s=5.0,
    )


def test_block_and_sample_are_equivalent(layout, signal_block) -> None:
    api = EegAlgorithmApi()
    block_session = api.create_online_session(_config(layout))
    point_session = api.create_online_session(_config(layout))
    source = type(signal_block)(
        signal_block.first_sequence_id,
        signal_block.timestamps_ns[:200].copy(),
        signal_block.values[:, :200].copy(),
    )
    block_result = api.push_block(block_session, source)
    point_values = []
    for index in range(source.values.shape[1]):
        result = api.push_sample(
            point_session,
            SampleFrame(index, int(source.timestamps_ns[index]), source.values[:, index].copy()),
        )
        point_values.append(result.processed_signal.values[:, 0])
    np.testing.assert_allclose(block_result.processed_signal.values, np.stack(point_values, axis=1), atol=1e-6)

    spectrum = api.query_online_spectrum(
        block_session,
        SpectrumQuery(10, "F3", FrequencyBand(BandPreset.ALPHA, 8.0, 13.0), 1.0),
    )
    assert spectrum.request_id == 10
    assert spectrum.frequencies_hz.size > 0
    api.close()


def test_causal_filter_block_and_sample_are_equivalent(layout, signal_block) -> None:
    api = EegAlgorithmApi()
    block_session = api.create_online_session(_filtered_config(layout))
    point_session = api.create_online_session(_filtered_config(layout))
    source = type(signal_block)(0, signal_block.timestamps_ns[:250].copy(), signal_block.values[:, :250].copy())
    expected = api.push_block(block_session, source).processed_signal.values
    actual = []
    for index in range(source.values.shape[1]):
        result = api.push_sample(
            point_session,
            SampleFrame(index, int(source.timestamps_ns[index]), source.values[:, index].copy()),
        )
        actual.append(result.processed_signal.values[:, 0])
    np.testing.assert_allclose(expected, np.stack(actual, axis=1), atol=1e-6)
    api.close()


def test_invalid_sequence_does_not_advance_status(layout, signal_block) -> None:
    api = EegAlgorithmApi()
    session_id = api.create_online_session(_config(layout))
    first = type(signal_block)(0, signal_block.timestamps_ns[:10].copy(), signal_block.values[:, :10].copy())
    api.push_block(session_id, first)
    before = api.get_online_status(session_id)
    invalid = type(signal_block)(20, signal_block.timestamps_ns[20:30].copy(), signal_block.values[:, 20:30].copy())
    with pytest.raises(AlgorithmError) as caught:
        api.push_block(session_id, invalid)
    assert caught.value.info.code == TIME_SEQUENCE_DISCONTINUITY
    after = api.get_online_status(session_id)
    assert after.last_processed_sequence_id == before.last_processed_sequence_id == 9
    api.close()
