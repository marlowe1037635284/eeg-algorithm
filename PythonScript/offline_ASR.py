# -*- coding: utf-8 -*-
"""
Created on Thu Oct  8 11:24:05 2026

@author: DELL
"""

import mne
from asrpy import ASR

# 1. 读取 EEG
file_path = r"E:\MDD\H_S1_EC_lrf.fif"
raw = mne.io.read_raw_fif(file_path, preload=True)

# 2. 初始化 ASR
asr = ASR(
    sfreq=raw.info["sfreq"],
    cutoff=20
)

# 3. 拟合 ASR
asr.fit(raw)

# 4. ASR 去伪迹
raw_asr = asr.transform(raw)

# 5. 保存新的 Raw 对象
raw_asr.save(
    r"E:\MDD\H_S1_EC_ASR_raw.fif",
    overwrite=True
)