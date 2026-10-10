from __future__ import annotations

import numpy as np

from eeg_algorithm.errors import (
    ALGORITHM_RUNTIME_ERROR,
    ASR_REFERENCE_REQUIRED,
    INVALID_ARGUMENT,
    algorithm_error,
)
from eeg_algorithm.types import ChannelLayout, OfflineAsrConfig, SignalBlock
from eeg_algorithm.internal.common.array_utils import copy_block


def asr_clean_offline(
    signal: SignalBlock,
    layout: ChannelLayout,
    config: OfflineAsrConfig,
) -> SignalBlock:
    """使用asrpy执行离线ASR校准与伪迹重建。"""
    operation = "asr_clean_offline"

    if not config.enabled:
        return copy_block(signal)

    if not np.isfinite(config.cutoff) or config.cutoff <= 0:
        raise algorithm_error(
            INVALID_ARGUMENT, "ASR cutoff必须为有限正数", operation
        )

    # 选择参考数据。
    reference = signal.values
    if config.reference_range is not None:
        mask = (
            (signal.timestamps_ns >= config.reference_range.start_timestamp_ns)
            & (signal.timestamps_ns <= config.reference_range.end_timestamp_ns)
        )
        reference = signal.values[:, mask]

    if reference.shape[1] < max(4, int(round(layout.sample_rate_hz))):
        raise algorithm_error(
            ASR_REFERENCE_REQUIRED, "ASR参考数据为空或过短", operation
        )

    # 保留框架的窗口和重叠参数。
    options = dict(sfreq=layout.sample_rate_hz, cutoff=config.cutoff)
    transform_options = {}

    if config.window_s is not None:
        if (
            not np.isfinite(config.window_s)
            or config.window_s <= 0
            or config.window_s * layout.sample_rate_hz < 2
        ):
            raise algorithm_error(
                INVALID_ARGUMENT, "ASR窗口必须为正且至少包含2个采样点", operation
            )
        options["win_len"] = config.window_s
        transform_options = dict(
            lookahead=config.window_s / 2,
            stepsize=min(32, int(config.window_s * layout.sample_rate_hz)),
        )

    if config.overlap_ratio is not None:
        if not 0 <= config.overlap_ratio < 1:
            raise algorithm_error(
                INVALID_ARGUMENT, "ASR重叠比例必须位于[0, 1)", operation
            )
        options["win_overlap"] = config.overlap_ratio

    # MNE使用V，处理结束后转换回原单位。
    scales = {"uV": 1e-6, "µV": 1e-6, "μV": 1e-6, "mV": 1e-3, "V": 1.0}
    if layout.unit not in scales:
        raise algorithm_error(
            INVALID_ARGUMENT, "ASR不支持此电压单位", operation
        )
    scale = scales[layout.unit]

    try:
        import mne
        from asrpy import ASR

        info = mne.create_info(
            list(layout.channel_names), layout.sample_rate_hz, "eeg"
        )

        def make_raw(values):
            return mne.io.RawArray(
                np.asarray(values, dtype=np.float64) * scale,
                info,
                verbose=False,
            )

        asr = ASR(**options)
        asr.fit(make_raw(reference))
        cleaned = asr.transform(
            make_raw(signal.values), **transform_options
        ).get_data() / scale

        cleaned = np.ascontiguousarray(cleaned, dtype=np.float32)
        if cleaned.shape != signal.values.shape or not np.isfinite(cleaned).all():
            raise ValueError("ASR输出形状不匹配或包含非有限值")

    except Exception as exc:
        raise algorithm_error(
            ALGORITHM_RUNTIME_ERROR,
            f"离线ASR校准或重建失败：{exc}",
            operation,
        ) from exc

    return copy_block(signal, cleaned)

