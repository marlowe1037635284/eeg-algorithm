from __future__ import annotations

import logging
import time

from eeg_algorithm.types import (
    AbsoluteTimeRange,
    ArtifactReport,
    ChannelLayout,
    PreprocessConfig,
    PreprocessedDataset,
    QualityReport,
    SignalBlock,
)

from eeg_algorithm.internal.common.array_utils import copy_block
from eeg_algorithm.internal.observability.context import get_logger, log_event

from .artifact import detect_artifacts_offline
from .asr import asr_clean_offline
from .filtering import apply_high_low_filter, notch_filter
from .quality import run_quality_control
from .rereference import rereference_offline
from .resample import resample_offline

_logger = get_logger(__name__)


def run_preprocessing_pipeline(
    raw_signal: SignalBlock,
    layout: ChannelLayout,
    config: PreprocessConfig,
    *,
    session_id: int | None = None,
) -> tuple[PreprocessedDataset, QualityReport | None, ArtifactReport | None]:
    started = time.perf_counter_ns()
    current = copy_block(raw_signal)
    current_layout = layout
    steps: list[str] = []
    quality_report: QualityReport | None = None
    artifact_report: ArtifactReport | None = None
    log_event(
        _logger,
        logging.INFO,
        "离线预处理开始",
        code="OFFLINE_PREPROCESSING_STARTED",
        operation="run_preprocessing",
        session_id=session_id,
        preprocess_version=config.preprocess_version,
    )
    try:
        current, filter_step = apply_high_low_filter(
            current, current_layout.sample_rate_hz, config.high_pass, config.low_pass
        )
        if filter_step is not None:
            steps.append(filter_step)
        if config.notch.enabled:
            current = notch_filter(current, current_layout.sample_rate_hz, config.notch)
            steps.append("notch")
        if config.reference.enabled:
            current = rereference_offline(current, current_layout, config.reference)
            steps.append("rereference")
        if config.asr.enabled:
            current = asr_clean_offline(current, current_layout, config.asr)
            steps.append("asr")
        if config.artifact.enabled:
            artifact_report = detect_artifacts_offline(current, current_layout, config.artifact)
            steps.append("artifact")
        if config.resample.enabled:
            current, current_layout = resample_offline(current, current_layout, config.resample)
            steps.append("resample")
        current, quality_report = run_quality_control(current, current_layout, config.quality_control)
        if quality_report.repaired:
            steps.append("repair")
    except Exception:
        log_event(
            _logger,
            logging.ERROR,
            "离线预处理失败",
            code="OFFLINE_PREPROCESSING_FAILED",
            operation="run_preprocessing",
            session_id=session_id,
            preprocess_version=config.preprocess_version,
            exc_info=True,
        )
        raise
    duration_ms = (time.perf_counter_ns() - started) / 1_000_000.0
    log_event(
        _logger,
        logging.INFO,
        "离线预处理完成",
        code="OFFLINE_PREPROCESSING_COMPLETED",
        operation="run_preprocessing",
        session_id=session_id,
        preprocess_version=config.preprocess_version,
        duration_ms=duration_ms,
    )
    dataset = PreprocessedDataset(
        preprocess_version=config.preprocess_version,
        layout=current_layout,
        signal=current,
        actual_time_range=AbsoluteTimeRange(int(current.timestamps_ns[0]), int(current.timestamps_ns[-1])),
        applied_steps=tuple(steps),
    )
    return dataset, quality_report, artifact_report
