# EEG Algorithm

面向 C++/pybind11 内嵌 CPython 的 EEG 在线与离线算法包。

公共入口只有：

- `eeg_algorithm.api`
- `eeg_algorithm.types`
- `eeg_algorithm.errors`

## 开发安装

```powershell
python -m pip install -e ".[dev]"
python -m pytest
```

需要启用 PyTorch 相位模型时安装：

```powershell
python -m pip install -e ".[dev,phase]"
```

## 日志

日志只有在调用 `configure_logging()` 后才会创建文件。算法线程仅向有界队列投递记录，后台线程负责写入轮转 JSON Lines 文件。C++ 通过 `EegAlgorithmApi.drain_log_events()` 拉取告警。

## ASR说明

当前代码提供可运行的参考统计和异常幅值抑制基线实现，并保留稳定的 `OnlineAsrProcessor`/`asr_clean_offline` 替换边界。用于科研或医疗结论前，应替换为经过验证的正式 ASR 实现并完成数据集验证。

