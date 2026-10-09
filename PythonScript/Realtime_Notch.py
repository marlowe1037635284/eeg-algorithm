# -*- coding: utf-8 -*-
"""
Created on Mon Sep 28 16:23:23 2026

@author: DELL
"""

# -*- coding: utf-8 -*-

import numpy as np
from scipy.signal import iirnotch


# =========================================================
# Notch 参数
# =========================================================

fs = 1000

# 工频
notch_freq = 50

# 品质因数
Q = 30


# =========================================================
# 生成 Notch 权重
# =========================================================

def Notch_weights(fs, notch_freq, Q):

    b, a = iirnotch(
        w0=notch_freq,
        Q=Q,
        fs=fs
    )

    return b, a


b, a = Notch_weights(
    fs,
    notch_freq,
    Q
)

# 提前反转权重，buffer 始终保持旧 → 新
b_reverse = b[::-1]
a_reverse = a[1:][::-1]


# =========================================================
# Notch buffer
# =========================================================

x_buffer = None
y_buffer = None


# =========================================================
# 根据实际通道数初始化
# =========================================================

def Notch_init(channels):

    global x_buffer, y_buffer

    # 行 = 通道
    # 列 = 历史输入
    x_buffer = np.zeros(
        (channels, len(b))
    )

    # 行 = 通道
    # 列 = 历史输出
    y_buffer = np.zeros(
        (channels, len(a) - 1)
    )


# =========================================================
# 一个时间点，多通道 Notch
# =========================================================

def realtime_Notch(current_sample):

    global x_buffer, y_buffer

    channels = len(current_sample)

    filtered_sample = np.zeros(channels)


    # =====================================================
    # 当前时间点逐通道处理
    # =====================================================

    for ch in range(channels):

        # 当前通道当前 EEG
        x = current_sample[ch]


        # -------------------------------------------------
        # 更新输入 buffer
        # -------------------------------------------------

        x_buffer[ch, :-1] = x_buffer[ch, 1:]
        x_buffer[ch, -1] = x


        # -------------------------------------------------
        # b × 当前/历史输入
        # -------------------------------------------------

        input_part = np.sum(
            b_reverse * x_buffer[ch]
        )


        # -------------------------------------------------
        # a × 历史输出
        # -------------------------------------------------

        feedback_part = np.sum(
            a_reverse * y_buffer[ch]
        )


        # -------------------------------------------------
        # 当前 Notch 输出
        # -------------------------------------------------

        y = (input_part - feedback_part) / a[0]


        filtered_sample[ch] = y


        # -------------------------------------------------
        # 更新输出 buffer
        # -------------------------------------------------

        y_buffer[ch, :-1] = y_buffer[ch, 1:]
        y_buffer[ch, -1] = y


    return filtered_sample


# =========================================================
# C++ 调用接口
# =========================================================

def process_notch(interleaved, channels):

    global x_buffer, y_buffer

    channels = int(channels)

    samples = np.asarray(
        interleaved,
        dtype=np.float64
    )


    # =====================================================
    # 基本检查
    # =====================================================

    if channels <= 0:
        return interleaved

    if samples.size < channels:
        return interleaved


    # =====================================================
    # 第一次运行 / 通道数变化
    # 才初始化 buffer
    # =====================================================

    if (
        x_buffer is None
        or x_buffer.shape[0] != channels
    ):

        Notch_init(channels)


    # =====================================================
    # 自动判断本次 C++ 传了几个时间点
    # =====================================================

    frames = samples.size // channels


    # =====================================================
    # 一维交错数据
    # →
    # 时间 × 通道
    # =====================================================

    data = samples[
        :frames * channels
    ].reshape(
        frames,
        channels
    )


    output = np.zeros_like(data)


    # =====================================================
    # 时间循环
    # =====================================================

    for t in range(frames):

        current_sample = data[t, :]

        output[t, :] = realtime_Notch(
            current_sample
        )


    # =====================================================
    # 转回 C++ 的一维交错格式
    # =====================================================

    return output.reshape(-1).astype(
        np.float32,
        copy=False
    )