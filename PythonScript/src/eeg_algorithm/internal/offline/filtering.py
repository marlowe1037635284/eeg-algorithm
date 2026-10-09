from __future__ import annotations

from eeg_algorithm.types import HighPassConfig, LowPassConfig, NotchConfig, SignalBlock

from eeg_algorithm.internal.common.array_utils import copy_block
from eeg_algorithm.internal.common.filter_design import (
    bandpass_sos,
    bandstop_sos,
    highpass_sos,
    lowpass_sos,
    zero_phase_filter,
)


def apply_high_low_filter(
    signal: SignalBlock,
    sample_rate_hz: float,
    high_pass: HighPassConfig,
    low_pass: LowPassConfig,
) -> tuple[SignalBlock, str | None]:
    """按高通/低通开关组合应用滤波。

    都开 → 带通；只开高通 → 高通；只开低通 → 低通；都关 → 透传。
    返回处理后的信号块以及对应步骤名（未滤波时步骤名为 None）。
    """
    hp_enabled = high_pass.enabled
    lp_enabled = low_pass.enabled
    if hp_enabled and lp_enabled:
        sos = bandpass_sos(high_pass.cutoff_hz, low_pass.cutoff_hz, sample_rate_hz)
        step = "band_pass"
    elif hp_enabled:
        sos = highpass_sos(high_pass.cutoff_hz, sample_rate_hz)
        step = "high_pass"
    elif lp_enabled:
        sos = lowpass_sos(low_pass.cutoff_hz, sample_rate_hz)
        step = "low_pass"
    else:
        return copy_block(signal), None
    return copy_block(signal, zero_phase_filter(signal.values, sos, "apply_high_low_filter")), step


def notch_filter(signal: SignalBlock, sample_rate_hz: float, config: NotchConfig) -> SignalBlock:
    if not config.enabled:
        return copy_block(signal)
    sos = bandstop_sos(config.stop_low_hz, config.stop_high_hz, sample_rate_hz)
    return copy_block(signal, zero_phase_filter(signal.values, sos, "notch_filter"))
