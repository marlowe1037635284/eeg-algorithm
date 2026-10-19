# EEG-KSC Code Wiki

面向 16 导联 EEG 设备的桌面采集与分析系统。客户端为 **Qt 6 + QML（C++17）**，算法为 **Python 包**，二者通过**进程内嵌入式 CPython（pybind11）**直接调用，不启动独立 Python 进程，也不使用 socket/IPC。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](01-architecture.md) | 整体架构、进程/线程模型、数据流、模块依赖与关键设计 |
| [02-cpp-client.md](02-cpp-client.md) | C++ 客户端 6 个模块的职责、关键类与函数说明 |
| [03-qml-ui.md](03-qml-ui.md) | QML 界面层：入口、路由、页面、面板、弹窗、组件 |
| [04-python-algorithm.md](04-python-algorithm.md) | `eeg_algorithm` 包：公共 API、类型、错误码、在线/离线流水线、日志 |
| [05-data-storage.md](05-data-storage.md) | SQLite 数据库、`.eegbin` 格式、配置文件、日志、审计与授权 |
| [06-build-run.md](06-build-run.md) | 环境依赖、构建、运行、自检、测试、打包与故障排查 |
| [07-dependencies.md](07-dependencies.md) | 依赖清单、模块依赖矩阵、关键调用时序与线程安全约定 |

## 项目一览

| 项 | 说明 |
| --- | --- |
| 顶层目录 | `KSCEEGClient/`（C++/Qt 客户端）、`PythonScript/`（`eeg_algorithm` 算法包） |
| 采集设备 | 16 导联 EEG，串口 921600 baud，1000 Hz 采样，ADS1299 24-bit ADC |
| 客户端框架 | Qt 6.6.3（Quick / Sql / SerialPort / Concurrent / Network），MSVC2019 x64 |
| 算法运行时 | 嵌入式 CPython 3.11，pybind11 3.1.0，numpy / scipy（可选 torch） |
| 数据存储 | 本地 SQLite（账号/患者/记录/标签/事件）、`.eegbin` 波形文件 |
| 交付形态 | Windows x64 免安装目录（自带 Qt 运行库、Python、venv、算法包） |

## 快速开始

开发机构建（VS2019 x64 开发者命令行）：

```bat
cmake -S KSCEEGClient -B KSCEEGClient/build/release -G "NMake Makefiles" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH="D:/Qt/6.6.3/msvc2019_64" ^
    -DKSCEEG_CONSOLE=ON
cmake --build KSCEEGClient/build/release --parallel 1
```

运行：

```bat
KSCEEGClient\build\release\appKSCEEGClient.exe            :: 正常界面
KSCEEGClient\build\release\appKSCEEGClient.exe --selfcheck :: 接口自检
KSCEEGClient\build\release\appKSCEEGClient.exe --demo      :: 无设备演示数据
```

算法包独立开发：

```powershell
cd PythonScript
python -m pip install -e ".[dev]"
python -m pytest
```

详细步骤见 [06-build-run.md](06-build-run.md)。

## 源码地图

```
eeg-algorithm/
├── KSCEEGClient/
│   ├── src/
│   │   ├── main.cpp              # 组装入口：单实例、自检、授权、Python、QML
│   │   ├── common/               # 跨线程类型、电极蒙太奇、文件格式、授权、审计、空闲退出
│   │   ├── storage/              # SQLite 门面 AppDatabase
│   │   ├── acquisition/          # 串口协议、原始环形缓冲、采集线程
│   │   ├── algorithm/            # PythonEngine / PythonWorker / 离线算法调用
│   │   ├── bridge/               # AcquisitionBridge（QML 门面）与图像 provider
│   │   └── analysis/             # 记录回放、后处理页、PDF 报告
│   ├── qml/                      # 界面（页面/面板/弹窗/组件/设计单例）
│   ├── python/eeg_bridge.py      # 宿主适配层（C++ ↔ 算法包）
│   ├── client-config.json        # 运行期配置
│   ├── public_key.pem            # 授权验签公钥
│   └── CMakeLists.txt
└── PythonScript/
    ├── src/eeg_algorithm/        # 算法包（api / types / errors / internal）
    ├── tests/                    # 契约、集成、性能、单元测试
    ├── benchmarks/               # 性能基准
    ├── examples/                 # Python 与 C++ 调用示例
    └── pyproject.toml
```

## 阅读建议

- 想了解「数据从串口到界面」：先读 [01-architecture.md](01-architecture.md)，再读 [02-cpp-client.md](02-cpp-client.md) 的 acquisition / algorithm / bridge 三节。
- 想改算法：读 [04-python-algorithm.md](04-python-algorithm.md)；宿主侧适配逻辑集中在 `KSCEEGClient/python/eeg_bridge.py`。
- 想改界面：读 [03-qml-ui.md](03-qml-ui.md)；界面状态多由 C++ 上下文属性（`Acq` / `Analysis` / `Recording`）提供。
- 想打包交付：读 [05-data-storage.md](05-data-storage.md) 与 [06-build-run.md](06-build-run.md)。
