# -*- coding: utf-8 -*-
"""
Created on Tue Sep 22 17:30:37 2026

@author: DELL
"""

import mne
import matplotlib.pyplot as plt
#直接指定文件路径
file_path = r'E:\Matlab\24YXY.vhdr'
raw = mne.io.read_raw_brainvision(file_path, preload=True)

# # 单通道
# fig = raw.plot(picks=['F3'], duration=5.0, scalings='auto')
# 全通道
fig = raw.plot(n_channels=len(raw.ch_names), duration=5.0, scalings='auto')

111