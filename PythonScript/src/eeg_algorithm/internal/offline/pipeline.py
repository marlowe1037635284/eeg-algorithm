"""离线预处理流水线：按固定顺序执行已启用步骤并原子返回结果。

固定顺序为：带通 → 陷波 → 重参考 → ASR → 降采样 → 基线校正；
关闭的步骤直接跳过。
"""

from __future__ import annotations

import time

from eeg_algorithm.internal.observability import get_logger
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from eeg_algorithm.types.offline import PreprocessConfig, PreprocessedDataset

from eeg_algorithm.internal.offline.asr import asr_clean_offline
from eeg_algorithm.internal.offline.baseline import baseline_correct_offline
from eeg_algorithm.internal.offline.filtering import band_pass_filter, notch_filter
from eeg_algorithm.internal.offline.rereference import rereference_offline
from eeg_algorithm.internal.offline.resample import resample_offline

_log = get_logger("offline.pipeline")


def _time_range(signal: SignalBlock, sample_rate_hz: float) -> AbsoluteTimeRange:
    ts = signal.timestamps_ns
    if ts.size == 0:
        return AbsoluteTimeRange(0, 0)
    dt = int(1e9 / sample_rate_hz)
    return AbsoluteTimeRange(int(ts[0]), int(ts[-1]) + dt)


def run_preprocessing_pipeline(
    raw_signal: SignalBlock,
    layout: ChannelLayout,
    config: PreprocessConfig,
) -> PreprocessedDataset:
    """从原始数据开始，按固定顺序执行已启用的预处理步骤。"""
    signal = raw_signal
    current_layout = layout
    applied: list[str] = []

    _log.info(
        "离线预处理开始",
        extra={"operation": "run_preprocessing", "preprocess_version": config.preprocess_version},
    )

    def _run_step(name: str, fn, *args):
        nonlocal signal, current_layout
        start = time.perf_counter()
        result = fn(*args)
        elapsed_ms = (time.perf_counter() - start) * 1e3
        _log.info(
            "预处理步骤完成",
            extra={"operation": name, "preprocess_version": config.preprocess_version,
                   "duration_ms": elapsed_ms},
        )
        return result

    if config.band_pass.enabled:
        signal = _run_step(
            "band_pass", band_pass_filter, signal, current_layout.sample_rate_hz, config.band_pass
        )
        applied.append("band_pass")

    if config.notch.enabled:
        signal = _run_step(
            "notch", notch_filter, signal, current_layout.sample_rate_hz, config.notch
        )
        applied.append("notch")

    if config.reference.enabled:
        signal = _run_step(
            "reference", rereference_offline, signal, current_layout, config.reference
        )
        applied.append("reference")

    if config.asr.enabled:
        signal = _run_step("asr", asr_clean_offline, signal, current_layout, config.asr)
        applied.append("asr")

    if config.resample.enabled:
        signal, current_layout = _run_step(
            "resample", resample_offline, signal, current_layout, config.resample
        )
        applied.append("resample")

    if config.baseline.enabled:
        signal = _run_step("baseline", baseline_correct_offline, signal, config.baseline)
        applied.append("baseline")

    dataset = PreprocessedDataset(
        preprocess_version=config.preprocess_version,
        layout=current_layout,
        signal=signal,
        actual_time_range=_time_range(signal, current_layout.sample_rate_hz),
        applied_steps=tuple(applied),
    )

    _log.info(
        "离线预处理完成",
        extra={"operation": "run_preprocessing", "preprocess_version": config.preprocess_version,
               "applied_steps": list(applied)},
    )
    return dataset
