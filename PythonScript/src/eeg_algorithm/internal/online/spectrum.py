from __future__ import annotations

from eeg_algorithm.types import AbsoluteTimeRange, ChannelLayout, SignalBlock, SpectrumQuery, SpectrumResult

from eeg_algorithm.internal.common.spectrum_core import select_frequency_range, welch_psd ,band_peak_frequencies
from eeg_algorithm.internal.validation import validate_frequency_band


def compute_online_spectrum(
    rolling_signal: SignalBlock,
    layout: ChannelLayout,
    query: SpectrumQuery,
    config_version: int,
) -> SpectrumResult:
    validate_frequency_band(query.band, layout.sample_rate_hz, "compute_online_spectrum")
    frequencies, psd = welch_psd(rolling_signal.values[0], layout.sample_rate_hz)
    frequencies, psd = select_frequency_range(frequencies, psd, query.band.low_hz, query.band.high_hz)
    peak_frequencies_hz = band_peak_frequencies(frequencies, psd)
    return SpectrumResult(
        request_id=query.request_id,
        config_version=config_version,
        channel_name=query.channel_name,
        band=query.band,
        actual_time_range=AbsoluteTimeRange(int(rolling_signal.timestamps_ns[0]), int(rolling_signal.timestamps_ns[-1])),
        frequencies_hz=frequencies,
        psd=psd,
        peak_frequencies_hz=peak_frequencies_hz,
    )

