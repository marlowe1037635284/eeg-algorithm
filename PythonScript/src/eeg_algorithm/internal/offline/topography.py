"""离线脑电地形图：频段滤波、电极代表值与空间插值。"""

from __future__ import annotations

import numpy as np
from scipy.signal import filtfilt, sosfilt

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.common.filter_design import bandpass_ba, bandpass_sos
from eeg_algorithm.internal.common.topography_core import interpolate_topography
from eeg_algorithm.types.common import ChannelLayout, SignalBlock
from eeg_algorithm.types.offline import OfflineTopographyQuery, OfflineTopographyResult


def _band_filter(values: np.ndarray, fs: float, low_hz: float, high_hz: float) -> np.ndarray:
    if values.shape[1] < 8:
        return values.astype(np.float64)
    try:
        b, a = bandpass_ba(low_hz, high_hz, fs)
        return filtfilt(b, a, values, axis=1)
    except ValueError:
        sos = bandpass_sos(low_hz, high_hz, fs)
        return sosfilt(sos, values, axis=1)


def compute_offline_topography(
    multichannel_signal: SignalBlock,
    layout: ChannelLayout,
    query: OfflineTopographyQuery,
) -> OfflineTopographyResult:
    """接收 ``select_multichannel_segment()`` 返回的 ``[C, K]`` 数据，生成地形图。"""
    if len(layout.positions) < 3:
        raise error(
            ErrorCode.INVALID_ARGUMENT,
            "电极坐标不足，无法生成地形图",
            "compute_offline_topography",
        )

    pos_map = {p.channel_name: p for p in layout.positions}
    xy = np.array(
        [[pos_map[n].x, pos_map[n].y] for n in layout.channel_names],
        dtype=np.float64,
    )

    filtered = _band_filter(
        multichannel_signal.values,
        layout.sample_rate_hz,
        query.frequency_band.low_hz,
        query.frequency_band.high_hz,
    )
    reps = np.sqrt(np.mean(filtered ** 2, axis=1)).astype(np.float32)

    grid_x, grid_y, grid_values, head_mask = interpolate_topography(
        reps, xy, query.grid_width, query.grid_height
    )

    return OfflineTopographyResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        frequency_band=query.frequency_band,
        selected_range=query.selected_range,
        grid_x=grid_x,
        grid_y=grid_y,
        grid_values=grid_values,
        head_mask=head_mask,
        electrode_values=reps,
        electrode_names=tuple(layout.channel_names),
    )
