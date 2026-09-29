# -*- coding: utf-8 -*-
"""
Created on Tue Sep 29 14:22:31 2026

@author: DELL
"""

import numpy as np
from scipy.signal import butter


# =========================================================
# 1. IIR 基本参数
# =========================================================

fs = 1000
cutoff = [0.5, 45]
order = 4


# =========================================================
# 2. 计算 IIR 系数
# =========================================================

def IIR_weights(fs, cutoff, order):

    b, a = butter(N=order,Wn=cutoff,btype='bandpass',fs=fs)

    return b, a

b, a = IIR_weights(fs,cutoff,order)

# =========================================================
# 3. IIR 历史 buffer
#
# None 表示：
# 当前还没有根据实际通道数建立 buffer
# =========================================================

x_buffer = None
y_buffer = None

# =========================================================
# 4. 根据实际通道数建立 IIR buffer
# =========================================================

def IIR_init(channels):

    global x_buffer, y_buffer

    # -----------------------------------------------------
    # 输入历史
    #
    # 行 = 电极/通道
    # 列 = 该电极的历史输入点
    # -----------------------------------------------------

    x_buffer = np.zeros((channels, len(b)), dtype=np.float32)

    # -----------------------------------------------------
    # 输出历史
    #
    # 行 = 电极/通道
    # 列 = 该电极的历史输出点
    # -----------------------------------------------------

    y_buffer = np.zeros((channels, len(a) - 1),dtype=np.float32)

# =========================================================
# 5. 实时 IIR
# current_sample：
# 当前一个时间点的所有电极
# =========================================================

def realtime_IIR(current_sample):

    global x_buffer, y_buffer

    channels = len(current_sample)

    # 保存当前这一帧所有电极的滤波结果
    filtered_sample = np.zeros(channels,dtype=np.float32)

    # -----------------------------------------------------
    # 每个电极独立进行 IIR
    # -----------------------------------------------------

    for ch in range(channels):

        # 当前电极、当前时间点的原始 EEG
        x = current_sample[ch]

        # =================================================
        # 更新这个电极自己的输入历史
        # =================================================

        x_buffer[ch, :-1] = x_buffer[ch, 1:]
        x_buffer[ch, -1] = x

        # =================================================
        # IIR 前馈部分
        #
        # b0*x[n] + b1*x[n-1] + ...
        # =================================================

        input_part = np.sum(b * x_buffer[ch, ::-1])

        # =================================================
        # IIR 反馈部分
        #
        # a1*y[n-1] + a2*y[n-2] + ...
        # =================================================

        feedback_part = np.sum(a[1:] * y_buffer[ch, ::-1])

        # =================================================
        # IIR 差分方程
        # =================================================

        y = (input_part - feedback_part) / a[0]

        # 当前电极滤波结果
        filtered_sample[ch] = y

        # =================================================
        # 更新这个电极自己的输出历史
        # =================================================

        y_buffer[ch, :-1] = y_buffer[ch, 1:]
        y_buffer[ch, -1] = y

    return filtered_sample


# =========================================================
# 6. IIR 接口函数
#
# 这个函数负责适配公司 C++ 传进来的 interleaved 格式
#
# 输入：
# 一维 interleaved
#
# 内部：
# 一维 -> frames × channels
#      -> realtime_IIR
#      -> frames × channels
#
# 输出：
# 一维 float32
# =========================================================

def process_frame_iir(interleaved, channels):

    global x_buffer, y_buffer

    # -----------------------------------------------------
    # C++传进来的通道数统一转成Python int
    # -----------------------------------------------------

    channels = int(channels)

    # -----------------------------------------------------
    # C++的一维数据转成NumPy数组
    #
    # 内部IIR计算使用float64
    # -----------------------------------------------------

    samples = np.asarray(
        interleaved,
        dtype=np.float64
    )

    # -----------------------------------------------------
    # 无有效通道时直接返回
    # -----------------------------------------------------

    if channels <= 0:return np.asarray(interleaved,dtype=np.float32)

    # -----------------------------------------------------
    # 数据不足一个完整frame
    # -----------------------------------------------------

    if samples.size < channels:
        return np.asarray(interleaved,dtype=np.float32)

    # =====================================================
    # 检查 IIR buffer
    #
    # 第一次：
    # x_buffer = None
    # -> 初始化
    #
    # 如果原来16导，现在变8导：
    # x_buffer.shape[0] != channels
    # -> 按新的通道数重新初始化
    # =====================================================

    if (
        x_buffer is None
        or y_buffer is None
        or x_buffer.shape[0] != channels
    ):
        IIR_init(channels)

    # =====================================================
    # 计算C++这一次传来了多少个时间点/frame
    # =====================================================

    frames = samples.size // channels

    # =====================================================
    # C++一维数据拆成二维
    #
    # shape:
    #
    # (frames, channels)
    #
    # 行 = 时间点
    # 列 = 电极
    # =====================================================

    data = samples[:frames * channels].reshape(frames,channels)

    # -----------------------------------------------------
    # 建立二维输出
    # -----------------------------------------------------

    output = np.zeros_like(data)

    # =====================================================
    # 一帧一帧处理
    # =====================================================

    for t in range(frames):

        # 当前这个时间点所有电极
        current_sample = data[t, :]

        # 每个电极进行IIR
        filtered_sample = realtime_IIR(current_sample)

        # 保存当前frame结果
        output[t, :] = filtered_sample

    # =====================================================
    # Python内部二维
    #
    #     ↓
    #
    # 重新组合成C++需要的一维
    #
    #     ↓
    #
    # 最终统一成float32
    # =====================================================

    return output.reshape(-1).astype(np.float32,copy=False)

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
    
    out = process_frame_iir(interleaved, channels)
   

    
    return out
