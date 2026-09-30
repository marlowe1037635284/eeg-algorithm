from __future__ import annotations

from eeg_algorithm.types import ChannelLayout, OfflineTopographyQuery, OfflineTopographyResult, SignalBlock

from eeg_algorithm.internal.common.topography_core import band_rms_values, interpolate_topography
from eeg_algorithm.internal.validation import validate_frequency_band


def compute_offline_topography(
    multichannel_signal: SignalBlock,
    layout: ChannelLayout,
    query: OfflineTopographyQuery,
) -> OfflineTopographyResult:
    validate_frequency_band(query.frequency_band, layout.sample_rate_hz, "compute_offline_topography")
    electrode_values = band_rms_values(multichannel_signal.values, layout.sample_rate_hz, query.frequency_band)
    grid_x, grid_y, grid_values, head_mask = interpolate_topography(
        electrode_values, layout, query.grid_width, query.grid_height
    )
    return OfflineTopographyResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        frequency_band=query.frequency_band,
        selected_range=query.selected_range,
        grid_x=grid_x,
        grid_y=grid_y,
        grid_values=grid_values,
        head_mask=head_mask,
        electrode_values=electrode_values,
        electrode_names=layout.channel_names,
    )

