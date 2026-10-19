# 01 · 整体架构

## 1. 系统定位

EEG-KSC 是一套单进程 Windows 桌面应用，完成：

```
16 导联设备 → 串口实时采集 → 在线算法（滤波/重参考/ASR/频谱/地形图）
            → 波形与指标展示 → 记录落盘 → 历史回放 → 离线后处理 → A4 报告
```

核心架构决策：

1. **单进程 + 嵌入式 CPython**：算法以 Python 包形式运行在客户端进程内，由 `pybind11` 的 `scoped_interpreter` 管理生命周期；C++ 与 Python 之间直接传 numpy 数组/字典，无序列化与 IPC 开销。
2. **线程隔离**：串口采集、算法处理、界面渲染分属不同线程，通过有界队列和 `Qt::QueuedConnection` 解耦。
3. **界面与绘制分离**：波形、地形图、频谱、回放图全部由 C++ 用 `QPainter` 绘制成 `QImage`，经 `QQuickImageProvider` 交给 QML `Image` 显示，避免 QML Canvas 的性能问题。
4. **算法状态唯一持有者**：在线会话对象只存在于算法线程；界面通过请求槽（latest-wins）获取地形图/频谱快照。

## 2. 部署与运行时组成

```
┌──────────────────────────────────────────────────────────────────┐
│ appKSCEEGClient.exe（单进程）                                     │
│                                                                  │
│  GUI 线程                                                         │
│  ├─ QQmlApplicationEngine / QML 页面与弹窗                        │
│  ├─ AcquisitionBridge（QML 上下文属性 Acq）                       │
│  ├─ RecordingPreview（Recording）/ PostProcess（Analysis）        │
│  ├─ AppDatabase（SQLite）/ RecordReport（PDF）                    │
│  └─ QQuickImageProvider（波形/地形图/后处理/回放）                 │
│                                                                  │
│  SerialCollector（QThread）                                       │
│  ├─ QSerialPort 收字节 → 协议切帧 → 24-bit 转 µV                  │
│  ├─ 写 .eegbin / CSV                                             │
│  └─ ChunkSink::deliver() → AcquisitionBridge                      │
│                                                                  │
│  PythonWorker（QThread）                                          │
│  ├─ 有界队列（容量 8）接收 SignalChunk / GapRange                  │
│  ├─ 调用 eeg_bridge.py → eeg_algorithm.api                       │
│  └─ 回传处理块、地形图、频谱、状态、日志                           │
│                                                                  │
│  嵌入式 CPython 3.11（PythonEngine，主线程启动/关闭）              │
│  └─ eeg_bridge.py（宿主适配层）→ eeg_algorithm（算法包）           │
└──────────────────────────────────────────────────────────────────┘
```

| 组件 | 线程 | 职责 |
| --- | --- | --- |
| `SerialCollector` | 独立 `QThread` | 串口 I/O、协议解析、单位换算、记录落盘、缺口记账 |
| `PythonWorker` | 独立 `QThread` | 持有在线 Python 会话，串行处理数据块/配置/查询 |
| `AcquisitionBridge` | GUI 线程 | QML 门面、原始缓存写入、显示队列、图像请求 |
| `PostProcess` | GUI + `QtConcurrent` | 离线后处理任务调度、结果缓存、图表生成 |
| `PythonEngine` | 主线程 | 解释器启动、`sys.path` 配置、API 版本校验、关闭 |

## 3. 数据流

### 3.1 在线采集链路

```
设备字节流
  │  QSerialPort (921600 baud)
  ▼
SerialCollector::run()
  │  1) 按帧头 0xA0/0xC0（数据）或 0xB0/0xD0（阻抗）切帧
  │  2) CRC-16/MODBUS 校验（可配置）
  │  3) 3 字节补码 → µV（VREF 4.5V / gain 8）
  │  4) 组装 SignalChunk（帧优先交错，单位 µV）
  ├─► 记录文件（.eegbin / CSV）
  └─► ChunkSink::deliver(chunk)  ── Qt::QueuedConnection ──►
        AcquisitionBridge（GUI 线程）
          ├─► RawRingBuffer.append()       // 供 ASR 拟合的原始数据
          └─► PythonWorker::deliver()      // 有界队列，满则记缺口
                │
                ▼
        PythonWorker::run()（算法线程，持 GIL 调用）
          push_block → OnlineSession:
            OnlineFilterChain → ReReferencer → OnlineAsrProcessor
            → PhaseDecoder（可选）→ RollingSignalBuffer
          │
          ├─ block_processed(处理块) ──► AcquisitionBridge 显示队列 → 波形图
          ├─ status_updated / log_event / algorithm_failed
          └─ topography_ready / spectrum_ready ──► 面板贴图
```

关键机制：

- **缺口记账（GapRange）**：采集停止、队列满、显示队列丢弃、算法块序列号不连续时都不会静默丢数据，而是记录 `[start_ns, end_ns]` 并传给 Python；在线会话收到缺口后重置流状态并进入 `WARMING_UP`。
- **latest-wins 请求槽**：地形图/频谱请求只保留最新一条；算法线程处理完当前请求后再取最新值，避免查询堆积。
- **GIL 边界最小化**：`PythonWorker` 中只有「构造入参 → 调用桥接函数 → 抽取结果」位于 `py::gil_scoped_acquire` 作用域内，`emit` 信号都在 GIL 之外执行。

### 3.2 离线后处理链路

```
.eegbin（memory map）
  ▼
RecordingPreview（读取头 + 帧数据，供回放/报告）
  ▼
PostProcess::schedule_recompute()（参数变化防抖）
  ▼
QtConcurrent 后台任务
  ▼
offlinealgorithm::run()
  ▼
Embedded Python:
  eeg_bridge.run_preprocessing()
    → OfflineSession.preprocess()
      → run_preprocessing_pipeline():
          高通/低通 → 陷波 → 重参考 → ASR → 伪迹检测
          → 降采样 → 质检/线性插值修复
  ▼
查询：频谱 / 地形图 / 统计 / 质检 / 预处理数据
  ▼
PostProcess::on_recompute_finished() → 波形/频谱/地形图图像 + 表格模型
```

`PostProcess` 使用 **Fingerprint + generation** 双保险：

- Fingerprint 覆盖全部重算参数与原始数据指针；仅窗口、标尺、事件、当前导联变化时复用上一轮 `processed` 数据，只重绘图像。
- generation 递增用于丢弃过期的后台结果，避免旧任务覆盖新结果。

## 4. 模块划分与依赖

`KSCEEGClient/src/` 分为 6 个模块，`main.cpp` 只做组装：

| 模块 | 主要文件 | 职责 | 依赖 |
| --- | --- | --- | --- |
| `common/` | `eegtypes.h`、`eegmontage.h`、`eegbinformat.h`、`topographypalette.h`、`licensemanager.*`、`auditlog.*`、`unattendedguard.*` | 跨线程数据结构、电极坐标、文件格式、配色、授权、审计、空闲退出 | Qt Core/Gui/Network、OpenSSL、nlohmann/json |
| `storage/` | `appdatabase.*` | SQLite 门面（账号/患者/记录/标签/事件/偏好） | Qt Sql |
| `acquisition/` | `serialprotocol.h`、`rawringbuffer.*`、`serialcollector.*` | 协议解析、原始缓存、串口线程 | `common` |
| `algorithm/` | `pythonengine.*`、`pythonworker.*`、`pythontypes.h`、`offlinealgorithm.*` | 解释器生命周期、算法线程、离线调用 | `common`、`acquisition`、pybind11 |
| `bridge/` | `acquisitionbridge.*`、`bridgeimageproviders.*` | QML 门面、显示队列、图像 provider | `common`、`acquisition`、`algorithm` |
| `analysis/` | `postprocess.*`、`recordingpreview.*`、`recordreport.*` | 回放、后处理、PDF 报告 | `common`、`algorithm` |

依赖方向总体自下而上：`common → acquisition → algorithm → bridge/analysis`。

存在两处刻意的反向依赖：

- `algorithm/pythonworker.h` 继承 `acquisition/serialcollector.h` 中的 `ChunkSink` 抽象接口；
- `acquisition/serialcollector.cpp` 的串口自检调用 `algorithm/pythonengine.h` 的自由函数 `install_console_message_handler()`。

```
                ┌──────────────┐
                │    main.cpp  │
                └──────┬───────┘
       ┌───────────────┼────────────────┐
       ▼               ▼                ▼
 ┌───────────┐   ┌────────────┐   ┌──────────────┐
 │  bridge   │   │  analysis  │   │   storage    │
 └─────┬─────┘   └─────┬──────┘   └──────────────┘
       │               │
       ▼               ▼
 ┌───────────┐   ┌────────────┐
 │ algorithm │◄──┤ acquisition│
 └─────┬─────┘   └─────┬──────┘
       │               │
       └───────┬───────┘
               ▼
         ┌───────────┐
         │  common   │
         └───────────┘
```

## 5. 对象生命周期与退出顺序

`main.cpp` 中通过**内层作用域**保证析构顺序：

```
QGuiApplication
  └─ UnattendedGuard（空闲自动退出）
  └─ LicenseManager.verify()
  └─ PythonEngine.start()
      └─ [内层作用域]
           AcquisitionBridge   → 析构时 close_port + worker.stop/wait
           RecordingPreview
           PostProcess
           QQmlApplicationEngine
      └─ PythonEngine.shutdown()
```

要点：

- `PythonEngine` 必须在所有会调用 Python 的对象析构之后才关闭解释器。
- `PythonWorker` 析构时 `request_stop()` + `wait(10000)`，**不能调用 `terminate()`**：线程可能正持有跨调用的 Python 会话对象，强杀会造成解释器状态损坏。
- `AcquisitionBridge` 的成员声明顺序保证 `m_raw_buffer` 先于 `m_worker` 构造、后于其析构；`m_worker` 持有指向 `m_raw_buffer` 的指针。

## 6. 错误处理与可观测性

| 层级 | 机制 |
| --- | --- |
| 串口 | `port_open_failed` / `port_closed` / `device_lost` / `failed`；任何退出路径都必须发出打开失败或关闭信号 |
| 算法 C++ 侧 | `algorithm_failed(code, message, operation)`；算法线程主循环外层 `catch`，防止异常穿出 `QThread::run()` 触发 `std::terminate` |
| Python 侧 | `AlgorithmError` 携带结构化 `AlgorithmErrorInfo(code, message, operation, session_id, sequence_id, details)` |
| 界面 | 设备断线弹窗、算法错误提示、Toast / 状态栏 |
| 运行日志 | Qt `qInfo/qWarning` + Python JSON Lines 轮转日志；UI 通过 `drain_log_events()` 拉取告警 |
| 审计 | `%LOCALAPPDATA%\EEG-KSC\logs\audit.log`，记录登录、账号管理、采集与导出等关键操作 |

## 7. 配置解析顺序

| 配置 | 优先序 |
| --- | --- |
| SQLite 数据库 | 源码目录（开发期）→ exe 同级（打包后） |
| `client-config.json` | **exe 同级 → 源码目录**（与数据库相反，便于现场调参） |
| Python 目录 | 同名环境变量 → exe 同级同名目录 → 编译期默认值 |
| 授权文件 | exe 同级 `license.lic` + `public_key.pem` |

详见 [05-data-storage.md](05-data-storage.md) 与 [06-build-run.md](06-build-run.md)。
