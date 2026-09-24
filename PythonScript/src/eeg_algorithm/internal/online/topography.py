"""在线脑电地形图。"""

from __future__ import annotations

import numpy as np
from scipy.signal import filtfilt, sosfilt

from eeg_algorithm.errors import ErrorCode, error
from eeg_algorithm.internal.common.filter_design import bandpass_ba, bandpass_sos
from eeg_algorithm.internal.common.topography_core import interpolate_topography
from eeg_algorithm.types.common import AbsoluteTimeRange, ChannelLayout, SignalBlock
from eeg_algorithm.types.online import TopographyQuery, TopographyResult


def _block_time_range(block: SignalBlock, fs: float) -> AbsoluteTimeRange:
    ts = block.timestamps_ns
    if ts.size == 0:
        return AbsoluteTimeRange(0, 0)
    dt = int(1e9 / fs)
    return AbsoluteTimeRange(int(ts[0]), int(ts[-1]) + dt)


class TopographyAnalyzer:
    """接收多通道缓存快照并计算实时地形图。"""

    def compute(
        self,
        rolling_signal: SignalBlock,
        layout: ChannelLayout,
        query: TopographyQuery,
        config_version: int,
    ) -> TopographyResult:
        if len(layout.positions) < 3:
            raise error(
                ErrorCode.INVALID_ARGUMENT,
                "电极坐标不足，无法生成地形图",
                "query_topography",
            )

        pos_map = {p.channel_name: p for p in layout.positions}
        xy = np.array(
            [[pos_map[n].x, pos_map[n].y] for n in layout.channel_names],
            dtype=np.float64,
        )

        filtered = self._band_filter(
            rolling_signal.values,
            layout.sample_rate_hz,
            query.band.low_hz,
            query.band.high_hz,
        )
        reps = np.sqrt(np.mean(filtered ** 2, axis=1)).astype(np.float32)

        grid_x, grid_y, grid_values, head_mask = interpolate_topography(
            reps, xy, query.grid_width, query.grid_height
        )

        return TopographyResult(
            request_id=query.request_id,
            config_version=config_version,
            band=query.band,
            actual_time_range=_block_time_range(rolling_signal, layout.sample_rate_hz),
            grid_x=grid_x,
            grid_y=grid_y,
            grid_values=grid_values,
            head_mask=head_mask,
            electrode_values=reps,
            electrode_names=tuple(layout.channel_names),
        )

    def _band_filter(
        self,
        values: np.ndarray,
        fs: float,
        low_hz: float,
        high_hz: float,
    ) -> np.ndarray:
        if values.shape[1] < 8:
            return values.astype(np.float64)
        try:
            b, a = bandpass_ba(low_hz, high_hz, fs)
            return filtfilt(b, a, values, axis=1)
        except ValueError:
            sos = bandpass_sos(low_hz, high_hz, fs)
            return sosfilt(sos, values, axis=1)
