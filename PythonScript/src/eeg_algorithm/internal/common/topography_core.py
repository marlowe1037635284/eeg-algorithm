from __future__ import annotations

import numpy as np
from numpy.typing import NDArray
from scipy import interpolate

from eeg_algorithm.errors import CHANNEL_LAYOUT_MISMATCH, INVALID_ARGUMENT, algorithm_error
from eeg_algorithm.types import ChannelLayout, FrequencyBand

from .filter_design import bandpass_sos, zero_phase_filter


def band_rms_values(
    values: NDArray[np.float32],
    sample_rate_hz: float,
    band: FrequencyBand,
) -> NDArray[np.float32]:
    sos = bandpass_sos(band.low_hz, band.high_hz, sample_rate_hz)
    filtered = zero_phase_filter(values, sos, "topography_band_filter")
    return np.ascontiguousarray(np.sqrt(np.mean(np.square(filtered, dtype=np.float64), axis=1)), dtype=np.float32)


def interpolate_topography(
    electrode_values: NDArray[np.float32],
    layout: ChannelLayout,
    grid_width: int,
    grid_height: int,
) -> tuple[NDArray[np.float32], NDArray[np.float32], NDArray[np.float32], NDArray[np.bool_]]:
    if grid_width < 8 or grid_height < 8:
        raise algorithm_error(INVALID_ARGUMENT, "地形图网格尺寸至少为8x8", "interpolate_topography")
    positions = {position.channel_name: position for position in layout.positions}
    if len(positions) != len(layout.channel_names):
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "地形图要求所有通道具有电极坐标", "interpolate_topography")
    xy = np.asarray([(positions[name].x, positions[name].y) for name in layout.channel_names], dtype=np.float64)
    if xy.shape[0] < 3:
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "地形图至少需要3个电极坐标", "interpolate_topography")
    center = xy.mean(axis=0)
    xy = xy - center
    radius = float(np.max(np.linalg.norm(xy, axis=1)))
    if radius <= 0:
        raise algorithm_error(CHANNEL_LAYOUT_MISMATCH, "电极坐标不能全部重合", "interpolate_topography")
    xy /= radius
    grid_x = np.linspace(-1.0, 1.0, grid_width, dtype=np.float32)
    grid_y = np.linspace(-1.0, 1.0, grid_height, dtype=np.float32)
    xx, yy = np.meshgrid(grid_x, grid_y)
    # 用薄板样条（thin plate spline）RBF 做**全局**插值。
    #
    # 之前用 griddata(cubic) 再拿 nearest 补 NaN，会在头内留下硬分界线：
    #   · griddata 的三次插值只在电极**凸包内**有定义，凸包外一律 NaN；
    #   · 而 16 导联的凸包（最外是 Fp1/Fp2、F7/F8、T3/T4）比头圆小一圈，
    #     头圆里最外面那圈全落在凸包外 —— 全靠 nearest 补出来的**分片常值**；
    #   · 分片常值在以电极划分的 Voronoi 边界上直接跳变，
    #     于是头缘、尤其是鼻尖附近出现一条条笔直的色带分界线。
    # RBF 是定义在**整个平面**上的光滑函数，凸包外会自然外推，
    # 头内不再有跳变，且基本不过冲（实测极值仍在电极值范围内）。
    query = np.column_stack([xx.ravel(), yy.ravel()])
    rbf = interpolate.RBFInterpolator(xy, electrode_values, kernel="thin_plate_spline")
    grid = rbf(query).reshape(grid_height, grid_width)
    mask = (xx * xx + yy * yy) <= 1.0
    grid = np.where(mask, grid, np.nan)
    return (
        grid_x,
        grid_y,
        np.ascontiguousarray(grid, dtype=np.float32),
        np.ascontiguousarray(mask, dtype=np.bool_),
    )

