"""脑电地形图空间插值。

将电极坐标映射到二维网格并生成圆形头部掩膜。
首版采用径向基函数（RBF）插值，不依赖额外资源文件。
"""

from __future__ import annotations

import numpy as np


def interpolate_topography(
    electrode_values: np.ndarray,
    positions_xy: np.ndarray,
    grid_width: int = 64,
    grid_height: int = 64,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """对电极代表值做二维插值。

    参数：
        electrode_values: 形状 ``[C]`` 的电极代表值。
        positions_xy: 形状 ``[C, 2]`` 的电极二维坐标。
        grid_width / grid_height: 输出网格尺寸。

    返回：
        ``(grid_x, grid_y, grid_values, head_mask)``。
        ``grid_x`` 形状 ``[W]``，``grid_y`` 形状 ``[H]``，
        ``grid_values`` 形状 ``[H, W]``，``head_mask`` 形状 ``[H, W]``。
    """
    if positions_xy.shape[0] < 3:
        # 电极不足时无法插值，返回空网格。
        grid_values = np.zeros((grid_height, grid_width), dtype=np.float32)
        head_mask = np.zeros((grid_height, grid_width), dtype=np.bool_)
        grid_x = np.zeros(grid_width, dtype=np.float32)
        grid_y = np.zeros(grid_height, dtype=np.float32)
        return grid_x, grid_y, grid_values, head_mask

    try:
        from scipy.interpolate import RBFInterpolator
    except ImportError:  # pragma: no cover
        RBFInterpolator = None

    # 归一化坐标到 [-1, 1]，使插值半径稳定。
    scale = np.max(np.abs(positions_xy)) or 1.0
    pts = positions_xy / scale

    xs = np.linspace(-1.0, 1.0, grid_width)
    ys = np.linspace(-1.0, 1.0, grid_height)
    xx, yy = np.meshgrid(xs, ys)
    grid_pts = np.column_stack([xx.ravel(), yy.ravel()])

    if RBFInterpolator is not None:
        try:
            rbf = RBFInterpolator(
                pts, electrode_values.astype(np.float64), kernel="thin_plate_spline"
            )
            vals = rbf(grid_pts)
        except Exception:  # noqa: BLE001  电极坐标退化/近共线导致矩阵奇异时回退。
            vals = None
    else:  # pragma: no cover
        vals = None

    if vals is None:
        from scipy.interpolate import griddata

        try:
            vals = griddata(
                pts, electrode_values.astype(np.float64), grid_pts, method="linear", fill_value=0.0
            )
        except Exception:  # noqa: BLE001  共线电极导致三角化失败时回退。
            vals = None
        if vals is None or not np.isfinite(vals).all():
            vals = griddata(pts, electrode_values.astype(np.float64), grid_pts, method="nearest")

    grid_values = vals.reshape(grid_height, grid_width).astype(np.float32)

    # 圆形头部掩膜：半径略大于电极分布范围。
    radius = float(np.max(np.linalg.norm(pts, axis=1))) * 1.15
    dist = np.sqrt(xx ** 2 + yy ** 2)
    head_mask = (dist <= radius).astype(np.bool_)
    grid_values[~head_mask] = 0.0

    return xs.astype(np.float32), ys.astype(np.float32), grid_values, head_mask
