from __future__ import annotations

from eeg_algorithm.types import AbsoluteTimeRange, ChannelLayout, SignalBlock, SpectrumQuery, SpectrumResult

from eeg_algorithm.internal.common.spectrum_core import select_frequency_range, welch_psd ,band_peak_psd
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
    delta_peak_psd, theta_peak_psd, alpha_peak_psd, beta_peak_psd, gamma_peak_psd = (
        band_peak_psd(frequencies, psd)
    )
    return SpectrumResult(
        request_id=query.request_id,
        config_version=config_version,
        channel_name=query.channel_name,
        band=query.band,
        actual_time_range=AbsoluteTimeRange(int(rolling_signal.timestamps_ns[0]), int(rolling_signal.timestamps_ns[-1])),
        frequencies_hz=frequencies,
        psd=psd,
        delta_peak_psd=delta_peak_psd,
        theta_peak_psd=theta_peak_psd,
        alpha_peak_psd=alpha_peak_psd,
        beta_peak_psd=beta_peak_psd,
        gamma_peak_psd=gamma_peak_psd,
    )

