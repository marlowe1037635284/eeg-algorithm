# -*- coding: utf-8 -*-
"""
Created on Tue Sep 22 11:11:24 2026

@author: DELL

实时 EEG 滤波模块。三类滤波各自独立、可单独开关、可自由级联：

  ① FIR   —— 线性相位 FIR（带通/低通），零相位失真，延迟 = (numtaps-1)/(2*fs)
  ② IIR   —— butter 带通，去直流/低频漂移，低延迟但相位非线性
  ③ Notch —— 50/60Hz 工频陷波（iirnotch），只影响工频附近，对信号频段无影响

三者通过 process_frame() 组合成 C++ 侧（pybind11）调用的唯一入口。
"""

import time
from datetime import datetime

import numpy as np
from scipy.signal import firwin, butter, iirnotch, lfilter, lfilter_zi

fs = 1000


# =====================================================================
# ① FIR —— 线性相位滤波（零相位失真）
# =====================================================================
# 参数
fir_cutoff = [0.5, 70]     # 带通截止（Hz）
fir_numtaps = 16           # 抽头数（= 滤波器长度；群延迟 = (fir_numtaps-1)/(2*fs)）
                           # 注意：16 抽头做不出 0.5Hz 低端截止（归一化截止 0.001，
                           # 过渡带宽约 125Hz），直流/低频偏移滤不掉。

# 系数
def design_fir(cutoff, numtaps):
    b = firwin(numtaps=numtaps, cutoff=cutoff, fs=fs, pass_zero=False)
    return b


fir_b = design_fir(fir_cutoff, fir_numtaps)

# 状态：每通道各存一份历史（taps-1, channels）
_fir_history = None


def reset_fir(channels):
    """按通道数重建 FIR 历史。换通道数或重新开始采集时调用。"""
    global _fir_history
    _fir_history = np.zeros((fir_b.size - 1, int(channels)))


# ---- 逐点版（单通道，演示/自测用）----
# [未使用] 以下 _buffer 与 realtime_FIR 是历史遗留的逐点 FIR 演示，
# 模块内无任何调用，正式链路走 process_frame_fir，可安全删除。
_buffer = np.zeros(fir_b.size)


def realtime_FIR(current_sample):
    """[未使用] 逐点 FIR 滤波。只适用于单通道；多通道请用 process_frame_fir。"""
    _buffer[:-1] = _buffer[1:]
    _buffer[-1] = current_sample
    return np.sum(_buffer * fir_b)


# ---- 整批版（C++ 侧按显示节拍调用，约 30 次/秒）----
def process_frame_fir(interleaved, channels):
    """整批 FIR 滤波。

    interleaved 为按帧交错的一维序列：[帧0的ch0..chN-1, 帧1的ch0..chN-1, ...]。
    与 realtime_FIR 数学等价（同样的 fir_b、同样的滑动窗口），区别只是
    每通道各存历史、一次算一批。fir_b 对称，正反卷积一致。
    """
    global _fir_history

    channels = int(channels)
    samples = np.asarray(interleaved, dtype=np.float64)
    if channels <= 0 or samples.size < channels:
        return interleaved
    if _fir_history is None or _fir_history.shape[1] != channels:
        reset_fir(channels)

    frames = samples.size // channels
    x = samples[:frames * channels].reshape(frames, channels)

    # 把历史接到前面，再按抽头逐次平移累加——等价于逐通道做 conv(x, fir_b, 'valid')
    extended = np.vstack([_fir_history, x])
    y = np.zeros_like(x)
    for k in range(fir_b.size):
        y += fir_b[k] * extended[k:k + frames, :]

    _fir_history = extended[-(fir_b.size - 1):, :].copy()
    return y.reshape(-1).astype(np.float32, copy=False)


# =====================================================================
# ② IIR —— butter 带通（去直流/低频漂移，低延迟）
# =====================================================================
# 参数（与 tms-eeg-client/eeg_processing.py 一一对应）
iir_bp_cutoff = [0.5, 30]   # 带通截止（Hz）；[0, 0] 表示直通
iir_bp_order = 2            # butter 阶数（2 阶即 4 极点）

# 系数
def design_iir():
    """设计带通。直通时 a 只有 [1.0]，调用方跳过 lfilter。"""
    if iir_bp_cutoff[0] == 0 and iir_bp_cutoff[1] == 0:
        return np.array([1.0]), np.array([1.0])
    return butter(iir_bp_order, iir_bp_cutoff, btype='bandpass', fs=fs)


iir_bp_b, iir_bp_a = design_iir()

# 状态：带通每通道一份 (阶数, channels)
_iir_zi = None


def reset_iir(channels):
    """清空 IIR 状态，等下一批样本到达后再预热。"""
    global _iir_zi
    _iir_zi = None


def process_frame_iir(interleaved, channels):
    """整批 IIR 带通（不含陷波），移植自 eeg_processing.py 的
    process_sample() / process_block()，逐通道独立状态。

    scipy 的 lfilter 支持沿 axis=0 批量、zi 按 (阶数, 通道数) 给，
    所以一级滤波只需一次调用，不用逐通道循环。
    """
    global _iir_zi

    channels = int(channels)
    samples = np.asarray(interleaved, dtype=np.float64)
    if channels <= 0 or samples.size < channels:
        return interleaved
    if _iir_zi is not None and _iir_zi.shape[1] != channels:
        reset_iir(channels)

    frames = samples.size // channels
    x = samples[:frames * channels].reshape(frames, channels)

    # 预热：拿本批首个样本给每通道各设一份稳态初值，消除启动瞬态
    if _iir_zi is None:
        _iir_zi = _zi_seed(iir_bp_b, iir_bp_a, x[0])

    # 直通时跳过 lfilter（与 eeg_processing 的 len(a) > 1 判断一致）
    if len(iir_bp_a) > 1:
        v, _iir_zi = lfilter(iir_bp_b, iir_bp_a, x, axis=0, zi=_iir_zi)
    else:
        v = x

    return v.reshape(-1).astype(np.float32, copy=False)


# =====================================================================
# ③ Notch —— 工频陷波（只影响 50/60Hz 附近，对信号频段无影响）
# =====================================================================
# 参数
notch_freq = "50"    # "50" / "60" / "none"
notch_q = 25         # 品质因数（eeg_processing 从 config.json 的 notch_q 读，那边是 25）

# 系数
def design_notch():
    """设计陷波。"none" 时 a 只有 [1.0]，调用方跳过 lfilter。"""
    if notch_freq == "50":
        return iirnotch(50.0, notch_q, fs=fs)
    if notch_freq == "60":
        return iirnotch(60.0, notch_q, fs=fs)
    return np.array([1.0]), np.array([1.0])


notch_b, notch_a = design_notch()

# 状态：陷波每通道一份 (阶数, channels)
_notch_zi = None


def reset_notch(channels):
    """清空陷波状态，等下一批样本到达后再预热。"""
    global _notch_zi
    _notch_zi = None


def process_frame_notch(interleaved, channels):
    """整批陷波。只影响工频附近，与带通/低通级联使用。"""
    global _notch_zi

    # 直通：不改信号直接返回
    if len(notch_a) <= 1:
        return interleaved

    channels = int(channels)
    samples = np.asarray(interleaved, dtype=np.float64)
    if channels <= 0 or samples.size < channels:
        return interleaved
    if _notch_zi is not None and _notch_zi.shape[1] != channels:
        reset_notch(channels)

    frames = samples.size // channels
    x = samples[:frames * channels].reshape(frames, channels)

    if _notch_zi is None:
        _notch_zi = _zi_seed(notch_b, notch_a, x[0])

    v, _notch_zi = lfilter(notch_b, notch_a, x, axis=0, zi=_notch_zi)
    return v.reshape(-1).astype(np.float32, copy=False)


# =====================================================================
# 公共工具与组合
# =====================================================================
def _zi_seed(b, a, first_samples):
    """把状态预热到「输入恒为 first_samples」的稳态，消除启动瞬态。
    与 eeg_processing 的 _warmup_channel 等价。直通滤波器返回 None。"""
    if len(a) <= 1:
        return None
    seed = np.asarray(first_samples, dtype=np.float64)[None, :]
    return lfilter_zi(b, a)[:, None] * seed


def reset_state(channels):
    """[对外接口] 按通道数统一重建三类滤波状态。换通道数或重新开始采集时由外部调用。

    注意：模块内 process_frame 不调用它——各 process 函数会自行按通道数重建状态。
    """
    reset_fir(channels)
    reset_iir(channels)
    reset_notch(channels)


# ---- 开关 ----
use_iir = True     # True: 主滤波用 IIR 带通；False: 用 FIR
use_notch = True   # 是否级联 50/60Hz 陷波


# ---- 计时统计（ms 精度）----
# 用 time.perf_counter() 打点：单调时钟、微秒级精度，适合测量耗时；
# 同时用 datetime 记录 wall-clock 时间戳（ms 精度），便于打印真实接收/完成时刻。
_timing = {
    "count": 0,        # 累计处理帧数
    "channels": 0,     # 最近一帧的通道数
    "n_samples": 0,    # 最近一帧的采样点数（= 样本总数 / 通道数）
    "last_ms": 0.0,    # 最近一帧耗时（ms）
    "total_ms": 0.0,   # 累计耗时（ms）
    "max_ms": 0.0,     # 单帧最大耗时（ms）
    "start_ts": 0.0,   # 最近一帧：接收到数据的 perf_counter 时间戳（秒）
    "end_ts": 0.0,     # 最近一帧：处理完成的 perf_counter 时间戳（秒）
    "start_time": "",  # 最近一帧：接收到数据的 wall-clock 时间戳（HH:MM:SS.mmm）
    "end_time": "",    # 最近一帧：处理完成的 wall-clock 时间戳（HH:MM:SS.mmm）
}
log_timing = True      # 是否打印每帧的时间戳与耗时


def _tick(channels, n_samples):
    """打点：记录「接收到数据」的时间戳、通道数与采样点数。"""
    _timing["channels"] = int(channels)
    _timing["n_samples"] = int(n_samples)
    _timing["start_ts"] = time.perf_counter()
    _timing["start_time"] = datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _tock():
    """打点：记录「数据处理完成」的时间戳，累计耗时并打印（ms）。"""
    end = time.perf_counter()
    _timing["end_ts"] = end
    _timing["end_time"] = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    dt_ms = (end - _timing["start_ts"]) * 1000.0
    _timing["count"] += 1
    _timing["last_ms"] = dt_ms
    _timing["total_ms"] += dt_ms
    if dt_ms > _timing["max_ms"]:
        _timing["max_ms"] = dt_ms
    if log_timing:
        print("[timing] ch=%d 采样点=%d 帧=%d  接收=%s 完成=%s  耗时=%.3f ms"
              % (_timing["channels"], _timing["n_samples"], _timing["count"],
                 _timing["start_time"], _timing["end_time"], dt_ms))
    return dt_ms


def get_timing():
    """[对外接口] 返回计时统计：count / channels / n_samples / last_ms / avg_ms / max_ms / 时间戳。

    模块内不调用，供 C++ 侧或测试读取。
    """
    t = dict(_timing)
    t["avg_ms"] = t["total_ms"] / t["count"] if t["count"] else 0.0
    return t


def process_frame(interleaved, channels):
    """C++ 侧的唯一入口：主滤波（FIR 或 IIR，二选一）-> 陷波。

    参数：
        interleaved：按帧交错的一维序列
            [采样点0的ch0..chN-1, 采样点1的ch0..chN-1, ...]
            采样点数 = len(interleaved) // channels（可 1 个或多个）。
        channels   ：通道数。

    返回：
        与输入同长度的一维数组（float32），包含所有采样点的滤波结果
        [滤波后采样点0的ch0..chN-1, 滤波后采样点1的ch0..chN-1, ...]。

    三部分独立开关：改 use_iir 切换 FIR/IIR，改 use_notch 决定是否陷波。
    内部用 _tick/_tock 打点，统计并打印「接收到数据 -> 处理完成」的耗时（ms）。
    """
    channels = int(channels)
    n_samples = len(interleaved) // channels if channels > 0 else 0
    _tick(channels, n_samples)
    if use_iir:
        out = process_frame_iir(interleaved, channels)
    else:
        out = process_frame_fir(interleaved, channels)

    if use_notch:
        out = process_frame_notch(out, channels)
    _tock()
    return out
