# -*- coding: utf-8 -*-
"""
Created on Wed Oct  7 18:15:56 2026

@author: Lenovo
"""

import numpy as np
from scipy.signal import butter


# =========================================================
# 1. IIR 参数
# =========================================================

fs = 1000
cutoff = [0.5, 45]
order = 4


# =========================================================
# 2. 生成 IIR 权重
# =========================================================

def IIR_weights(fs, cutoff, order):

    b, a = butter(
        N=order,
        Wn=cutoff,
        btype='bandpass',
        fs=fs
    )

    return b, a


b, a = IIR_weights(
    fs,
    cutoff,
    order
)


# =========================================================
# 3. 提前反转权重
#
# buffer 始终保持：
# 旧 ------------------------> 新
#
# 所以权重改成：
# 旧 ------------------------> 新
# =========================================================

b_reverse = b[::-1]

# a0 不参与历史 y 的乘法
# 所以先去掉 a0，再反转
a_reverse = a[1:][::-1]


# =========================================================
# 4. IIR buffer
# =========================================================

x_buffer = None
y_buffer = None


def IIR_init(channels):

    global x_buffer, y_buffer

    # 输入历史：旧 → 新
    x_buffer = np.zeros(
        (channels, len(b))
    )

    # 输出历史：旧 → 新
    y_buffer = np.zeros(
        (channels, len(a) - 1)
    )


# =========================================================
# 5. 实时 IIR
# 一个时间点，所有通道
# =========================================================

def realtime_IIR(current_sample):

    global x_buffer, y_buffer

    channels = len(current_sample)

    filtered_sample = np.zeros(channels)


    for ch in range(channels):

        # 当前原始 EEG
        x = current_sample[ch]


        # -------------------------------------------------
        # 更新输入历史
        #
        # 左边最老
        # 右边最新
        # -------------------------------------------------

        x_buffer[ch, :-1] = x_buffer[ch, 1:]
        x_buffer[ch, -1] = x


        # -------------------------------------------------
        # b × x
        #
        # 不翻转数据
        # 使用已经翻转好的 b 权重
        # -------------------------------------------------

        input_part = np.sum(
            b_reverse * x_buffer[ch]
        )


        # -------------------------------------------------
        # a × 历史 y
        #
        # 同样不翻转数据
        # -------------------------------------------------

        feedback_part = np.sum(
            a_reverse * y_buffer[ch]
        )


        # -------------------------------------------------
        # 当前输出
        # -------------------------------------------------

        y = (
            input_part
            -
            feedback_part
        ) / a[0]


        filtered_sample[ch] = y


        # -------------------------------------------------
        # 保存当前 y
        #
        # 仍然保持：旧 → 新
        # -------------------------------------------------

        y_buffer[ch, :-1] = y_buffer[ch, 1:]
        y_buffer[ch, -1] = y


    return filtered_sample