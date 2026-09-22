# -*- coding: utf-8 -*-
"""pybindwithqt 演示模块。

由 Qt/C++ 侧通过 pybind11 嵌入的解释器 import 调用。整个模块**不注册任何 C++ 回调**，
保持单向依赖：Qt -> Python。因此「耗时任务上报进度」不是靠 Python 反向调用 C++，
而是把任务拆成可增量调用的粒度（见 mandelbrot_row），由 C++ 侧在后台线程里循环调用。

四档由浅入深：
  ① greet / add            —— 基础类型往返，验证链路是否打通
  ② statistics             —— 容器转换，C++ QVariantList <-> Python list / dict
  ③ mandelbrot_row         —— 逐行耗时计算，供 C++ 后台线程分块调用
  ④ point_cloud_stats      —— numpy 大块数据，ndarray 走缓冲协议双向传递

另有 environment_info()，用来在界面上证明解释器确实挂到了 venv 上。

本文件可以脱离 Qt 单独运行自测：venv/Scripts/python.exe pydemo.py
"""

import math
import sys

# ③ 的视口固定，保证逐行拼接出来的图像整体一致
_MANDEL_X_MIN = -2.5
_MANDEL_X_MAX = 1.0
_MANDEL_Y_MIN = -1.25
_MANDEL_Y_MAX = 1.25


# ==================== ① 基础类型 ====================


def greet(name: str) -> str:
    """最基础的字符串往返。"""
    return "你好，%s！来自 Python %d.%d" % (
        name,
        sys.version_info.major,
        sys.version_info.minor,
    )


def add(a: float, b: float) -> float:
    """数值往返。pybind11 会按 double 转换。"""
    return a + b


def environment_info() -> dict:
    """自检：返回解释器与依赖的关键路径。

    嵌入式解释器被配置成以 venv 身份运行，所以正常情况下应该是：
      prefix         = venv 目录
      base_prefix    = 基础安装目录（解释器本体与标准库在那里，链接期链接的也是它）
      site_packages 里有且只有 venv 那一份 —— 系统安装与用户级的 site-packages
                     都不可见，这正是「只用 venv，不用系统环境」的判据
    """
    info = {
        "version": sys.version.split()[0],
        "prefix": sys.prefix,
        "base_prefix": sys.base_prefix,
        "module_file": __file__,
        "site_packages": [
            path
            for path in sys.path
            if path.replace("\\", "/").rstrip("/").endswith("site-packages")
        ],
    }
    try:
        import numpy

        info["numpy"] = numpy.__version__
        info["numpy_file"] = numpy.__file__
    except ImportError as exc:
        info["numpy"] = "未安装: %s" % exc
        info["numpy_file"] = "-"
    return info


# ==================== ② 容器转换 ====================


def statistics(values) -> dict:
    """统计一组数，返回 dict。

    C++ 侧的 QVariantList 会被 pybind11 转成 Python list 传进来。
    空输入不抛异常而是返回 count=0，让 C++ 侧少一层错误分支。
    """
    count = len(values)
    if count == 0:
        return {
            "count": 0,
            "mean": 0.0,
            "min": 0.0,
            "max": 0.0,
            "std": 0.0,
            "range": 0.0,
        }

    mean = sum(values) / count
    variance = sum((value - mean) ** 2 for value in values) / count
    return {
        "count": count,
        "mean": mean,
        "min": min(values),
        "max": max(values),
        "std": math.sqrt(variance),
        "range": max(values) - min(values),
    }


# ==================== ③ 逐行耗时计算 ====================


def mandelbrot_row(y: int, width: int, height: int, max_iter: int) -> list:
    """只计算第 y 行的 Mandelbrot 迭代次数，返回长度 width 的 list[int]。

    刻意按「行」而不是整幅图暴露：C++ 侧在后台线程里逐行调用，每行之间 emit 进度信号，
    从而在单向依赖下也能上报进度并响应取消。
    """
    if width <= 0 or height <= 0 or max_iter <= 0:
        raise ValueError("width/height/max_iter 必须为正数")
    if y < 0 or y >= height:
        raise ValueError("y=%d 超出 [0, %d)" % (y, height))

    ci = _MANDEL_Y_MIN + (_MANDEL_Y_MAX - _MANDEL_Y_MIN) * y / max(height - 1, 1)
    row = []
    for x in range(width):
        cr = _MANDEL_X_MIN + (_MANDEL_X_MAX - _MANDEL_X_MIN) * x / max(width - 1, 1)
        zr = 0.0
        zi = 0.0
        iteration = 0
        # 转义半径 2 的平方；乘 2 的写法比 hypot 快得多，这是内层热点
        while zr * zr + zi * zi <= 4.0 and iteration < max_iter:
            zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
            iteration += 1
        row.append(iteration)
    return row


# ==================== ④ numpy 大块数据 ====================


def point_cloud_stats(points) -> dict:
    """统计点集：输入 (N, 3) 的 float32 数组，返回形心与各点到形心的距离。

    返回的 distances 是 ndarray，C++ 侧用 py::array_t 走缓冲协议零拷贝读回，
    不产生逐元素转换开销 —— 这是大块数据该走的路径。
    """
    import numpy as np

    array = np.asarray(points, dtype=np.float32)
    if array.ndim != 2 or array.shape[1] != 3:
        raise ValueError("points 形状必须是 (N, 3)，收到 %s" % (array.shape,))
    if array.shape[0] == 0:
        raise ValueError("points 不能为空")

    centroid = array.mean(axis=0)
    distances = np.linalg.norm(array - centroid, axis=1).astype(np.float32)
    return {
        "count": int(array.shape[0]),
        "centroid": [float(value) for value in centroid],
        "distances": distances,
        "min_distance": float(distances.min()),
        "max_distance": float(distances.max()),
        "mean_distance": float(distances.mean()),
    }


# ==================== 脱离 Qt 的自测 ====================


def _self_test() -> int:
    """按四档顺序跑一遍，用于脱离 Qt 单独验证 Python 侧。返回进程退出码。"""
    failures = []

    def check(label, fn):
        try:
            print("[ok  ] %-18s %s" % (label, fn()))
        except Exception as exc:  # noqa: BLE001 - 自测要把任何异常都报出来
            failures.append(label)
            print("[fail] %-18s %r" % (label, exc))

    info = environment_info()
    print("[env ] Python %s" % info["version"])
    print("[env ] prefix      = %s" % info["prefix"])
    print("[env ] base_prefix = %s" % info["base_prefix"])
    print("[env ] site-packages:")
    for path in info["site_packages"]:
        print("[env ]   %s" % path)
    print("[env ] numpy       = %s" % info["numpy"])

    check("greet", lambda: greet("Qt"))
    check("add", lambda: add(1.5, 2.25))
    check("statistics", lambda: statistics([1.0, 2.0, 3.0, 4.0]))
    check("mandelbrot_row", lambda: "第 0 行前 8 列 = %s" % mandelbrot_row(0, 64, 48, 100)[:8])

    # numpy 是第 ④ 档的硬依赖，缺了就是失败，不按「跳过」处理 ——
    # 否则自测会打印 [skip] 却返回非零，两种语义自相矛盾
    if "未安装" in str(info["numpy"]):
        failures.append("numpy")
        print("[fail] point_cloud_stats   （numpy 未安装，第 ④ 档无法运行）")
    else:
        import numpy as np

        rng = np.random.default_rng(42)
        cloud = rng.normal(size=(1000, 3)).astype(np.float32)
        check("point_cloud_stats", lambda: point_cloud_stats(cloud))

    if failures:
        print("\n失败: %s" % ", ".join(failures))
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(_self_test())
