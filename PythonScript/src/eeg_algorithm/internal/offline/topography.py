from __future__ import annotations

import numpy as np

from eeg_algorithm.types import (
    BandPreset,
    ChannelLayout,
    FrequencyBand,
    OfflineTopographyQuery,
    OfflineTopographyResult,
    SignalBlock,
)

from eeg_algorithm.internal.common.topography_core import band_rms_values, interpolate_topography

# 离线地形图固定计算的 6 个频段：全频段 + δ/θ/α/β/γ（名称、下界、上界，Hz）。
_BANDS: tuple[tuple[str, float, float], ...] = (
    ("full", 0.5, 30.0),
    ("delta", 0.5, 4.0),
    ("theta", 4.0, 8.0),
    ("alpha", 8.0, 13.0),
    ("beta", 13.0, 30.0),
    ("gamma", 30.0, 45.0),
)


def compute_offline_topography(
    multichannel_signal: SignalBlock,
    layout: ChannelLayout,
    query: OfflineTopographyQuery,
) -> OfflineTopographyResult:
    """一次返回全频段与 δ/θ/α/β/γ 共 6 张地形图。"""
    values = multichannel_signal.values
    sample_rate_hz = layout.sample_rate_hz
    nyquist = sample_rate_hz / 2.0
    grid_width = query.grid_width
    grid_height = query.grid_height

    grid_x = np.linspace(-1.0, 1.0, grid_width, dtype=np.float32)
    grid_y = np.linspace(-1.0, 1.0, grid_height, dtype=np.float32)

    band_names: list[str] = []
    electrode_rows: list[np.ndarray] = []
    grid_rows: list[np.ndarray] = []
    head_mask: np.ndarray | None = None

    for name, low, high in _BANDS:
        effective_high = min(high, nyquist * 0.99)
        band_names.append(name)
        if low >= effective_high:
            # 频段完全超出 Nyquist，返回 NaN 表示不可用
            electrode_rows.append(np.full(values.shape[0], np.nan, dtype=np.float32))
            grid_rows.append(np.full((grid_height, grid_width), np.nan, dtype=np.float32))
            continue
        band = FrequencyBand(BandPreset.CUSTOM, low, effective_high)
        electrode = band_rms_values(values, sample_rate_hz, band)
        _, _, grid, mask = interpolate_topography(electrode, layout, grid_width, grid_height)
        electrode_rows.append(electrode)
        grid_rows.append(grid)
        head_mask = mask

    if head_mask is None:
        xx, yy = np.meshgrid(grid_x, grid_y)
        head_mask = (xx * xx + yy * yy) <= 1.0

    return OfflineTopographyResult(
        request_id=query.request_id,
        preprocess_version=query.preprocess_version,
        selected_range=query.selected_range,
        band_names=tuple(band_names),
        grid_x=grid_x,
        grid_y=grid_y,
        grid_values=np.stack(grid_rows),
        head_mask=np.ascontiguousarray(head_mask, dtype=np.bool_),
        electrode_values=np.vstack(electrode_rows),
        electrode_names=layout.channel_names,
    )
