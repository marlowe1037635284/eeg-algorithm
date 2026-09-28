# EEG 在线与离线算法包

供 C++ 通过 pybind11 调用的 EEG 在线与离线算法包。本包只向 C++ 公开以下模块：

- `eeg_algorithm.api` — 唯一业务入口（`EegAlgorithmApi`）
- `eeg_algorithm.types` — 跨语言 DTO 与枚举
- `eeg_algorithm.errors` — 错误码与异常

其余在线状态、离线流水线、滤波、ASR、频谱、地形图与日志实现统一位于
`eeg_algorithm.internal`，C++ 不得直接导入。

## 目录结构

```text
algorithm/
├─ pyproject.toml
├─ README.md
├─ src/eeg_algorithm/
│  ├─ __init__.py
│  ├─ api.py                # 公共 API 门面
│  ├─ version.py            # API_VERSION = "1.3"
│  ├─ errors.py             # 错误码与 AlgorithmError
│  ├─ types/                # 公共 DTO 与枚举
│  └─ internal/             # 在线/离线/公共计算/日志实现
├─ models/                  # 相位模型资源清单
└─ examples/                # 在线/离线/日志示例
```

## 快速开始

```python
from eeg_algorithm import api

alg = api.create_api()
print(api.get_api_version())  # "1.3"
```

在线处理：

```python
sid = alg.create_online_session(online_config)
result = alg.push_block(sid, block)
topo = alg.query_online_topography(sid, topo_query)
alg.close_online_session(sid)
```

离线处理：

```python
sid = alg.create_offline_session(layout, raw_signal)
result = alg.run_preprocessing(sid, preprocess_config)
spec = alg.query_offline_spectrum(sid, spectrum_query)
alg.close_offline_session(sid)
```

日志：

```python
from eeg_algorithm.types import LoggingConfig, LogLevel

api.configure_logging(LoggingConfig(enabled=True, directory="./logs"))
alg = api.create_api()
events = alg.drain_log_events()  # C++ 周期拉取 WARNING+ 事件
alg.close()                      # 刷新并关闭日志线程
```

## 运行示例

在 `algorithm` 目录下：

```powershell
$env:PYTHONPATH = "src"
python examples/online_processing_demo.py
python examples/offline_processing_demo.py
python examples/logging_demo.py
```

## 依赖

- Python >= 3.10
- numpy >= 1.24
- scipy >= 1.10
- （可选）torch >= 2.0，用于相位解码模型
