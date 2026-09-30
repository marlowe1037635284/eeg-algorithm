from __future__ import annotations

from eeg_algorithm.types import BandPassConfig, NotchConfig, SignalBlock

from eeg_algorithm.internal.common.array_utils import copy_block
from eeg_algorithm.internal.common.filter_design import bandpass_sos, bandstop_sos, zero_phase_filter


def band_pass_filter(signal: SignalBlock, sample_rate_hz: float, config: BandPassConfig) -> SignalBlock:
    if not config.enabled:
        return copy_block(signal)
    sos = bandpass_sos(config.low_cut_hz, config.high_cut_hz, sample_rate_hz)
    return copy_block(signal, zero_phase_filter(signal.values, sos, "band_pass_filter"))


def notch_filter(signal: SignalBlock, sample_rate_hz: float, config: NotchConfig) -> SignalBlock:
    if not config.enabled:
        return copy_block(signal)
    sos = bandstop_sos(config.stop_low_hz, config.stop_high_hz, sample_rate_hz)
    return copy_block(signal, zero_phase_filter(signal.values, sos, "notch_filter"))

