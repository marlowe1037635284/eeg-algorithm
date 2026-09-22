# -*- coding: utf-8 -*-
"""
Created on Tue Sep 22 11:11:24 2026

@author: DELL
"""
##16阶 带通1-30 采样率1000hz 滤波器权重

import numpy as np
from scipy.signal import firwin


# =========================
# FIR 参数
# =========================

fs = 1000
cutoff = [0.5, 70]
order = 16

# =========================
# 生成 FIR 权重
# =========================

def FIR_weights(fs, cutoff, order):

    b = firwin(numtaps=order,cutoff=cutoff,fs=fs,pass_zero=False)

    return b

# 生成权重
b = FIR_weights(fs, cutoff, order)

# =========================
# 16通道 buffer
# =========================

buffer = np.zeros(len(b))


def realtime_FIR(current_sample):

    # 所有历史数据左移一位
    buffer[:-1] = buffer[1:]

    # 最新采样点放在最后
    buffer[-1] = current_sample

    # 逐点乘权重，然后求和
    filtered_sample = np.sum(buffer * b)

    return filtered_sample


# ==================== 多通道批量接口 ====================
# realtime_FIR 用的是模块级全局 buffer，16 路共用一份，逐路调用会互相污染；
# 而且 1000Hz x 16 路 = 每秒 16 万次调用，开销扛不住。
# 下面这套按「一整批样本一起算」工作，每通道各存自己的状态，
# C++ 侧按显示节拍调用（约 30 次/秒）。原 realtime_FIR 保持不动。

from scipy.signal import butter, iirnotch, lfilter, lfilter_zi

# ---- 用哪一套滤波器 ----
# True ：IIR，移植自 tms-eeg-client/eeg_processing.py（带通 -> 陷波）
# False：用上面的 FIR 权重
#
# 当前用 FIR（下面的 IIR 只是备选，两套都保留着，改这个开关即可切换）。
# 备注：0.5Hz 这个低端截止 16 抽头 FIR 做不出来——归一化截止是 0.001，
# 而 16 抽头能分辨的过渡带宽约 0.25（125Hz），实测那组系数直流增益仍是 1.04，
# 低频没被滤掉。真要滤掉直流得用 IIR 或上千抽头的 FIR。
use_iir = True

# ---- IIR 参数（与 eeg_processing.py 一一对应）----
iir_bp_cutoff = [0.5, 30]   # 带通截止（Hz），设成 [0, 0] 表示直通
iir_bp_order = 2            # butter 阶数（2 阶即 4 极点）
iir_notch = "50"            # "50" / "60" / "none"
iir_notch_q = 25            # 品质因数（eeg_processing 从 config.json 的 notch_q 读，那边是 25）


def _make_iir():
    """设计带通与陷波。直通时 a 只有 [1.0]，调用方要跳过 lfilter——
    与 eeg_processing 里 len(a) > 1 的判断一致。"""
    if iir_bp_cutoff[0] == 0 and iir_bp_cutoff[1] == 0:
        bp_b, bp_a = np.array([1.0]), np.array([1.0])
    else:
        bp_b, bp_a = butter(iir_bp_order, iir_bp_cutoff, btype='bandpass', fs=fs)

    if iir_notch == "50":
        nt_b, nt_a = iirnotch(50.0, iir_notch_q, fs=fs)
    elif iir_notch == "60":
        nt_b, nt_a = iirnotch(60.0, iir_notch_q, fs=fs)
    else:
        nt_b, nt_a = np.array([1.0]), np.array([1.0])
    return bp_b, bp_a, nt_b, nt_a


iir_bp_b, iir_bp_a, iir_nt_b, iir_nt_a = _make_iir()

# ---- 每通道状态 ----
_channels = 0
_history = None    # FIR：(taps-1, channels)
_zi_bp = None      # IIR 带通：(阶数, channels)
_zi_nt = None      # IIR 陷波：(阶数, channels)


def _zi_seed(b, a, first_samples):
    """把状态预热到「输入恒为 first_samples」的稳态，消除启动瞬态。
    与 eeg_processing 的 _warmup_channel 等价。直通滤波器返回 None。"""
    if len(a) <= 1:
        return None
    seed = np.asarray(first_samples, dtype=np.float64)[None, :]
    return lfilter_zi(b, a)[:, None] * seed


def reset_state(channels):
    """按通道数重建滤波状态。换通道数或重新开始采集时调用。"""
    global _channels, _history, _zi_bp, _zi_nt
    _channels = int(channels)
    _history = np.zeros((b.size - 1, _channels))
    _zi_bp = None      # 等第一批样本到了再预热——预热要用首样本做种子
    _zi_nt = None


def process_frame_fir(interleaved, channels):
    """整批 FIR 滤波。

    interleaved 按帧交错的一维序列：[帧0的ch0..chN-1, 帧1的ch0..chN-1, ...]。
    返回同长度的一维数组。

    与 realtime_FIR 数学上等价（同样的 b、同样的滑动窗口），区别只是
    每通道各存历史、且一次算一批。b 是对称的，正反卷积一致。
    """
    global _history

    channels = int(channels)
    samples = np.asarray(interleaved, dtype=np.float64)
    if channels <= 0 or samples.size < channels:
        return interleaved
    if _channels != channels:
        reset_state(channels)

    frames = samples.size // channels
    x = samples[:frames * channels].reshape(frames, channels)

    # 把历史接到前面，再按抽头逐次平移累加——等价于逐通道做 conv(x, b, 'valid')
    extended = np.vstack([_history, x])
    y = np.zeros_like(x)
    for k in range(b.size):
        y += b[k] * extended[k:k + frames, :]

    _history = extended[-(b.size - 1):, :].copy()
    return y.reshape(-1).astype(np.float32, copy=False)


def process_frame_iir(interleaved, channels):
    """整批 IIR 滤波：带通 -> 陷波，移植自 eeg_processing.py 的
    process_sample() / process_block()，逐通道独立状态。

    与那边等价，区别只是这里一次处理 (帧数 x 通道数) 的整批：
    scipy 的 lfilter 支持沿 axis=0 批量、zi 按 (阶数, 通道数) 给，
    所以一级滤波只要一次调用，不用逐通道循环。
    """
    global _zi_bp, _zi_nt

    channels = int(channels)
    samples = np.asarray(interleaved, dtype=np.float64)
    if channels <= 0 or samples.size < channels:
        return interleaved
    if _channels != channels:
        reset_state(channels)

    frames = samples.size // channels
    x = samples[:frames * channels].reshape(frames, channels)

    # 预热：拿本批首个样本给每通道各设一份稳态初值（对应 _warmup_channel）
    if _zi_bp is None:
        _zi_bp = _zi_seed(iir_bp_b, iir_bp_a, x[0])
    if _zi_nt is None:
        _zi_nt = _zi_seed(iir_nt_b, iir_nt_a, x[0])

    # 1. 带通（直通时跳过 lfilter，与 eeg_processing 的写法一致）
    if len(iir_bp_a) > 1:
        v, _zi_bp = lfilter(iir_bp_b, iir_bp_a, x, axis=0, zi=_zi_bp)
    else:
        v = x

    # 2. 陷波
    if len(iir_nt_a) > 1:
        v, _zi_nt = lfilter(iir_nt_b, iir_nt_a, v, axis=0, zi=_zi_nt)

    return v.reshape(-1).astype(np.float32, copy=False)


def process_frame(interleaved, channels):
    """C++ 侧的唯一入口，按 use_iir 分发。改 use_iir 即可切换两套滤波器。"""
    if use_iir:
        return process_frame_iir(interleaved, channels)
    return process_frame_fir(interleaved, channels)
