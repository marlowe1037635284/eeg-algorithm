# -*- coding: utf-8 -*-
"""
Created on Wed Oct  7 17:25:49 2026

@author: Lenovo
"""

import numpy as np


# =========================================================
# 1. 双侧乳突重参考
# =========================================================

def reference_mastoid(current_sample, m1_index, m2_index):

    # 双侧乳突平均
    ref = ( current_sample[m1_index] + current_sample[m2_index]) / 2.0

    # 所有通道减去参考
    output = current_sample - ref

    return output


# =========================================================
# 2. 全脑平均重参考
# =========================================================

def reference_average(current_sample):

    # 所有通道平均
    ref = np.mean(current_sample)

    # 所有通道减去平均参考
    output = current_sample - ref

    return output