"""离线频谱：对选定的单导联数据计算 Welch PSD。"""

from __future__ import annotations

from eeg_algorithm.internal.common.spectrum_core import welch_psd
from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.offline import OfflineSpectrumQuery, OfflineSpectrumResult


def compute_offline_spectrum(
    channel_signal: SignalBlock,
    layout: ChannelLayout,
    query: OfflineSpectrumQuery,
) -> OfflineSpectrumResult:
    """接收 ``select_channel_segment()`` 返回的 ``[1, K]`` 数据，计算单边 PSD。"""
    x = channel_signal.values[0]
    freqs, psd = welch_psd(
        x,
        layout.sample_rate_hz,
        freq_range_hz=query.frequency_range_hz,
    )
    return OfflineSpectrumResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        channel_name=query.channel_name,
        selected_range=query.selected_range,
        frequencies_hz=freqs,
        psd=psd,
    )
