from __future__ import annotations

from eeg_algorithm.types import AbsoluteTimeRange, ChannelLayout, SignalBlock, TopographyQuery, TopographyResult

from eeg_algorithm.internal.common.topography_core import band_rms_values, interpolate_topography
from eeg_algorithm.internal.validation import validate_frequency_band


def compute_online_topography(
    rolling_signal: SignalBlock,
    layout: ChannelLayout,
    query: TopographyQuery,
    config_version: int,
) -> TopographyResult:
    validate_frequency_band(query.band, layout.sample_rate_hz, "compute_online_topography")
    electrode_values = band_rms_values(rolling_signal.values, layout.sample_rate_hz, query.band)
    grid_x, grid_y, grid_values, head_mask = interpolate_topography(
        electrode_values, layout, query.grid_width, query.grid_height
    )
    return TopographyResult(
        request_id=query.request_id,
        config_version=config_version,
        band=query.band,
        actual_time_range=AbsoluteTimeRange(int(rolling_signal.timestamps_ns[0]), int(rolling_signal.timestamps_ns[-1])),
        grid_x=grid_x,
        grid_y=grid_y,
        grid_values=grid_values,
        head_mask=head_mask,
        electrode_values=electrode_values,
        electrode_names=layout.channel_names,
    )

