"""在线频谱：单导联 Welch PSD。"""

from __future__ import annotations

from eeg_algorithm.internal.common.spectrum_core import welch_psd
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from eeg_algorithm.types.online import SpectrumQuery, SpectrumResult


def _block_time_range(block: SignalBlock, fs: float) -> AbsoluteTimeRange:
    ts = block.timestamps_ns
    if ts.size == 0:
        return AbsoluteTimeRange(0, 0)
    dt = int(1e9 / fs)
    return AbsoluteTimeRange(int(ts[0]), int(ts[-1]) + dt)


class SpectrumAnalyzer:
    """接收单导联缓存快照并计算实时 Welch PSD。"""

    def compute(
        self,
        rolling_signal: SignalBlock,
        layout: ChannelLayout,
        query: SpectrumQuery,
        config_version: int,
    ) -> SpectrumResult:
        x = rolling_signal.values[0]
        freqs, psd = welch_psd(
            x,
            layout.sample_rate_hz,
            freq_range_hz=(query.band.low_hz, query.band.high_hz),
        )
        return SpectrumResult(
            request_id=query.request_id,
            config_version=config_version,
            channel_name=query.channel_name,
            band=query.band,
            actual_time_range=_block_time_range(rolling_signal, layout.sample_rate_hz),
            frequencies_hz=freqs,
            psd=psd,
        )
