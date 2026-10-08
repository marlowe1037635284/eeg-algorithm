# -*- coding: utf-8 -*-
"""
Created on Wed Oct  7 16:21:21 2026

@author: Lenovo
"""


import numpy as np


def spectrum(data):

    # =====================================================
    # 1. FFT
    # =====================================================

    fft_result = np.fft.rfft(data)


    # =====================================================
    # 2. 功率
    # =====================================================

    power = np.abs(fft_result) ** 2


    # =====================================================
    # 3. 取 0.1 ~ 45 Hz
    #
    # 10秒数据：
    # 每个FFT点 = 0.1 Hz
    # =====================================================

    power = power[1:451]

    # =====================================================
    # 4. 每5个点求平均
    #
    # 0.1~0.5  → 0.25 Hz
    # 0.6~1.0  → 0.75 Hz
    # ...
    #
    # 最终90个数
    # =====================================================

    power = power.reshape(-1, 5)

    mean_power = np.mean(power, axis=1)


    # =====================================================
    # 5. 各频段峰值
    # 直接从90个数里面找最大值
    # =====================================================

    delta_peak = np.max(mean_power[1:8])      # 0.5~4 Hz

    theta_peak = np.max(mean_power[8:16])     # 4~8 Hz

    alpha_peak = np.max(mean_power[16:24])    # 8~12 Hz

    beta_peak = np.max(mean_power[26:60])     # 13~30 Hz

    gamma_peak = np.max(mean_power[60:90])    # 30~45 Hz


    return (
        mean_power,
        delta_peak,
        theta_peak,
        alpha_peak,
        beta_peak,
        gamma_peak
    )