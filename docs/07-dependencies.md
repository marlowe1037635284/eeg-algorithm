# 07 · 依赖关系、调用时序与线程安全

本篇回答三个问题：项目依赖了什么、模块之间怎么依赖、关键路径上的调用顺序与线程约定是什么。

---

## 1. 运行时与构建期依赖总览

### 1.1 C++ 侧

| 依赖 | 版本 / 形态 | 用途 | 引入位置 |
| --- | --- | --- | --- |
| Qt 6 | 6.6.3，MSVC2019 x64 | GUI、QML、SQL、串口、线程池、网卡信息 | `find_package(Qt6 COMPONENTS Quick Sql SerialPort Concurrent Network)` |
| Qt6::Quick | 6.6.x | QML 引擎、`QQuickImageProvider`、`QQuickWindow` | `target_link_libraries` |
| Qt6::Sql | 6.6.x | SQLite 驱动，读写本地数据库 | 同上 |
| Qt6::SerialPort | 6.6.x | 921600 baud 串口采集 | 同上 |
| Qt6::Concurrent | 6.6.x | `QtConcurrent::run` 执行后处理重计算 | 同上 |
| Qt6::Network | 6.6.x | `QNetworkInterface` 读取网卡 MAC，用于授权绑定 | 同上 |
| CPython | 3.11 基础安装 | 嵌入式解释器，`python311.dll` 运行期需在 exe 旁 | `Python_ROOT_DIR` |
| pybind11 | 3.1.0，源码 `add_subdirectory` | `pybind11::embed`，C++ 调用 Python | `PYBIND11_SOURCE_DIR` |
| OpenSSL | 3.x，`OpenSSL::Crypto` | 授权文件 RSA PKCS#1 v1.5 + SHA-256 验签 | `OPENSSL_ROOT_DIR` |
| nlohmann/json | 3.12.0，纯头文件 | 还原授权待验签串，必须与签发侧序列化一致 | `NLOHMANN_JSON_INCLUDE_DIR` |

构建期另有 MSVC 工具链要求：C++17、`/utf-8`、`/Zm2000`（规避 QML 合并翻译单元导致的 C1060）。

### 1.2 Python 侧

来自 [pyproject.toml](file:///d:/myproject/eeg-algorithm/PythonScript/pyproject.toml)：

| 依赖 | 约束 | 必需性 | 用途 |
| --- | --- | --- | --- |
| Python | `>=3.11` | 必需 | 与嵌入解释器版本一致 |
| numpy | `>=1.26` | 必需 | 全部数值计算、帧数组 |
| scipy | `>=1.12` | 必需 | Butterworth/SOS 滤波、Welch、重采样、RBF 插值 |
| mne | `>=1.6` | 必需 | 离线 ASR 的依赖链（`asrpy` 需要） |
| asrpy | `>=0.0.8` | 必需 | 离线伪迹去除（ASR） |
| torch | `>=2.2` | 可选（`phase` extra） | 相位/深度学习相关可选能力 |
| pytest / pytest-cov | `>=8.0` / `>=5.0` | 可选（`dev` extra） | 测试与覆盖率 |

运行时实际 venv 中观测到的版本为 numpy 2.4.6、scipy 1.17.1、mne 1.13.2、asrpy 0.0.8。**版本上限未锁定**，升级 numpy/scipy 大版本时需要回归滤波与频谱数值。

### 1.3 依赖的三级解析

外部路径不写死在代码里，统一走「CMake CACHE 变量 → 编译期宏 → 运行时环境变量」：

| 路径 | CMake 变量 | 编译期宏 | 运行时覆盖 |
| --- | --- | --- | --- |
| Python 基础安装 | `Python_ROOT_DIR` | `PYTHON_ROOT_DIR` | 环境变量同名 |
| Python venv | `PYTHON_VENV_DIR` | `PYTHON_VENV_DIR` | 环境变量同名 |
| 算法包源码 | `EEG_ALGO_SRC_DIR` | `EEG_ALGO_SRC_DIR` | 环境变量同名 |
| 桥接脚本目录 | `EEG_BRIDGE_DIR` | `EEG_BRIDGE_DIR` | 环境变量同名 |

因此换机器或换打包目录时，优先改环境变量，不必重新编译。

---

## 2. 模块依赖矩阵

`src/` 分为 6 个模块，依赖方向整体自下而上：

| 模块 | 依赖 | 被谁依赖 | 职责 |
| --- | --- | --- | --- |
| `common/` | 无（仅 Qt 基础） | storage、acquisition、algorithm、bridge、analysis | 类型、电极蒙太奇、`.eegbin` 格式、配色、审计日志、授权、无人值守 |
| `storage/` | common | bridge（间接）、main | SQLite 六张表的读写门面 |
| `acquisition/` | common | algorithm、bridge | 串口协议、原始环形缓冲、采集线程 |
| `algorithm/` | common、acquisition | bridge、analysis | 嵌入式 Python 引擎、算法线程、离线调用层 |
| `bridge/` | common、acquisition、algorithm | QML | QML 属性门面、波形/地形图 ImageProvider |
| `analysis/` | common、algorithm、storage | QML | 回放、后处理页、A4 报告导出 |

```
QML  ──►  bridge/  ──►  algorithm/  ──►  acquisition/  ──►  common/
             │              │                  │
             └──────────────┴──────────────────┴──►  storage/
             │
             └──►  analysis/  ──►  algorithm/  ──►  common/
```

需要注意的两处例外：

1. `acquisition/*.cpp` 中残留了一个未被使用的 `algorithm` 头文件包含，形成 `acquisition → algorithm` 的反向引用。删除后整棵树即为严格单向。
2. `analysis/` 直接读 `storage/` 中的采集记录元数据，绕过 `bridge/`，属于同层横向依赖。

Python 包内部的依赖方向见 [04-python-algorithm.md](file:///d:/myproject/eeg-algorithm/docs/04-python-algorithm.md)：

```
api.py ──► internal/online/session.py ──► filter_chain / rereference / asr / rolling_buffer
       └─► internal/offline/session.py ──► filtering / artifact / resample / selection / quality / statistics
两者共享 internal/common/（spectrum_core、topography_core、types、errors、observability）
```

---

## 3. 关键调用时序

### 3.1 启动

```
main.cpp
  ├─ 单实例锁
  ├─ 解析命令行（--selfcheck / --demo）
  ├─ QApplication + QML 引擎
  ├─ LicenseManager 读取 license.lic → 验签 / MAC / 有效期
  ├─ AppDatabase 打开 SQLite，建表、写入内置 admin
  ├─ PythonEngine 启动（PyConfig.executable → venv python.exe）
  │    └─ sys.path 追加 EEG_ALGO_SRC_DIR、EEG_BRIDGE_DIR
  │    └─ import eeg_bridge，校验 API_VERSION
  ├─ PythonWorker 启动 QThread，进入事件循环
  ├─ 构造 AcquisitionBridge / RecordingPreview / PostProcess / RecordReport
  │    └─ 注册为 QML 上下文属性 Acq / Recording / Analysis / License / IdleGuard / AppDebugBuild
  ├─ image://waveform、image://topography 等 provider 注册
  └─ engine.load(Main.qml)
```

关键约束：`PythonEngine` 必须最后构造、最先析构；所有持有 Python 对象的 worker 必须先停。

### 3.2 在线采集

```
QML 开始采集
  → AcquisitionBridge::startCapture()
    → SerialCollector::start(Config)
      线程：read 串口 → 解帧（A0…C0 / B0…D0）
        → RawRingBuffer 写入原始样本
        → 组装 SignalChunk
        → PythonWorker 有界队列（容量 8）
          → 队列满则丢弃并记 GapRange，不阻塞采集
  PythonWorker（QThread）
    → eeg_bridge 调用 push_block
    → 在线流水线：滤波 → 重参考 → ASR → 相位（可选）→ 滚动缓存
    → 地形图 / 频谱按节流周期计算
    → 结果回传（QueuedConnection）到 GUI 线程
      → AcquisitionBridge 更新属性、发 dataChanged
      → QML 刷新；波形由 QQuickImageProvider 按需绘制
```

数据不拷贝的边界：`push_block` 热路径直接引用宿主内存，必须在同一作用域内完成使用或 memcpy 到 Python 自有数组。

### 3.3 离线后处理

```
QML 选择记录 → PostProcess::openRecord()
  → 读取 .eegbin 头与数据（按需分段）
  → QtConcurrent::run
    → OfflineAlgorithm → Python offline session
    → 高通/低通 → 陷波 → 重参考 → ASR → 伪迹检测 → 降采样 → 质检/修复
  → 结果写回（generation 校验，过期结果丢弃）
  → 各标签页读属性渲染：波形 / 频谱 / 通道 / 统计 / 地形图 / 报告
```

后处理的高频请求采用 latest-wins 单槽位：新请求覆盖旧请求，旧任务结果通过 generation 号判定过期后直接丢弃，避免界面追不上计算。

### 3.4 回放与报告

```
RecordPreview::open(recordNo) → 加载 .eegbin → set_view_size()
  → 分页读取环形窗口 → image provider 绘制
RecordReport::exportReport()
  → QPainter 绘制 A4 150 dpi（页边距 56，波形量程固定 100 µV）
  → 输出 PDF / 图片
  → AuditLog 记录导出事件
```

---

## 4. 线程模型与安全约定

| 线程 | 拥有者 | 职责 | 禁止事项 |
| --- | --- | --- | --- |
| GUI 线程 | Qt | QML、bridge 属性更新、图像绘制 | 不直接调用 Python 长任务 |
| 采集线程 | `SerialCollector`（QThread） | 串口读取、解帧、入队 | 不分配 Python 对象 |
| 算法线程 | `PythonWorker`（QThread） | 持 GIL、跑在线流水线 | 禁止 `terminate()`，只能置停止标志后 `wait()` |
| 线程池 | `QtConcurrent` | 离线后处理、报告生成 | 不与算法线程共享可变 Python 状态 |

约定：

1. **GIL 最小化**：只在进入 Python 的调用边界持 GIL，C++ 侧计算与图像绘制不持锁。
2. **跨线程通知**：一律 `Qt::QueuedConnection`，信号参数使用值类型（`SignalChunk`、`GapInfo`）。
3. **有界队列**：采集到算法之间容量 8，满即丢并记缺口，保证采集线程永不阻塞。
4. **缺口记账**：`GapRange` 表达绝对时间区间，下游据此断帧而不是拼接错误数据。
5. **latest-wins + generation**：UI 请求只保留最新一次；结果带 generation，过期即弃。
6. **锁外绘制**：图像 provider 先拷贝所需窗口数据，再在锁外绘制，避免长时间持锁。
7. **析构顺序**：停止采集 → 停止算法线程 → 关闭 PythonEngine → 关闭数据库。逆序会导致 GIL 已释放仍在析构 Python 对象。

---

## 5. 数据与配置的依赖链

| 数据 | 生产者 | 消费者 |
| --- | --- | --- |
| `.eegbin` 采集文件 | 采集线程 / 记录模块 | 回放、后处理、报告 |
| SQLite 业务库 | `AppDatabase` | 登录、患者、历史、设置、审计 |
| `client-config.json` | 部署方 | 无人值守阈值、授权路径等 |
| 审计日志 | `AuditLog` | 运维追溯 |
| Python JSONL 日志 | `observability` | 算法排障（由 PythonWorker 节流拉取） |
| `license.lic` | 签发侧 | `LicenseManager` 启动校验 |

格式细节与表结构见 [05-data-storage.md](file:///d:/myproject/eeg-algorithm/docs/05-data-storage.md)。

---

## 6. 升级依赖时的检查点

| 变更 | 必查项 |
| --- | --- |
| Python 3.11 → 更高 | `python311.dll` 名称、`PyConfig` 字段、pybind11 兼容性、venv `pyvenv.cfg` |
| numpy / scipy 大版本 | 滤波器系数与 Welch 数值回归、`np.float_` 等已移除别名 |
| mne / asrpy | ASR 拟合时长与参考段秒数（默认 60 s）、离线结果一致性 |
| Qt 6.6 → 更高 | QML 单例注册、`QQuickImageProvider` 接口、`qt_standard_project_setup` 最低版本 |
| OpenSSL 3.x | `libcrypto-3-x64.dll` 名称与部署位置、验签填充方式 |
| pybind11 | `pybind11::embed`、GIL 释放策略、`py::array` 生命周期语义 |

---

## 相关文档

- [README.md](file:///d:/myproject/eeg-algorithm/docs/README.md) —— 文档索引与快速开始
- [01-architecture.md](file:///d:/myproject/eeg-algorithm/docs/01-architecture.md) —— 整体架构与数据流
- [02-cpp-client.md](file:///d:/myproject/eeg-algorithm/docs/02-cpp-client.md) —— C++ 类与接口
- [04-python-algorithm.md](file:///d:/myproject/eeg-algorithm/docs/04-python-algorithm.md) —— Python 包与流水线
- [06-build-run.md](file:///d:/myproject/eeg-algorithm/docs/06-build-run.md) —— 构建、运行、打包
