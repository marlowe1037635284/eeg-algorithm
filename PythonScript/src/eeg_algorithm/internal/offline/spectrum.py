from __future__ import annotations

from eeg_algorithm.errors import FREQUENCY_OUT_OF_RANGE, algorithm_error
from eeg_algorithm.types import ChannelLayout, OfflineSpectrumQuery, OfflineSpectrumResult, SignalBlock

from eeg_algorithm.internal.common.spectrum_core import select_frequency_range, welch_psd


def compute_offline_spectrum(
    channel_signal: SignalBlock,
    layout: ChannelLayout,
    query: OfflineSpectrumQuery,
) -> OfflineSpectrumResult:
    frequencies, psd = welch_psd(channel_signal.values[0], layout.sample_rate_hz)
    if query.frequency_range_hz is not None:
        low, high = query.frequency_range_hz
        if not 0 <= low < high <= layout.sample_rate_hz / 2:
            raise algorithm_error(FREQUENCY_OUT_OF_RANGE, "离线频谱范围非法", "compute_offline_spectrum")
        frequencies, psd = select_frequency_range(frequencies, psd, low, high)
    return OfflineSpectrumResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        channel_name=query.channel_name,
        selected_range=query.selected_range,
        frequencies_hz=frequencies,
        psd=psd,
    )

