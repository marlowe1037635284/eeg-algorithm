# 02 · C++ 客户端

C++ 客户端位于 `KSCEEGClient/src/`，目标名 `appKSCEEGClient`，按职责分为 6 个模块。`main.cpp` 只负责组装，不含业务逻辑。

## 1. 入口：`main.cpp`

启动流程：

1. 创建 `QGuiApplication`，设置应用名 `EEG-KSC`。
2. **单实例**：`QLockFile` 加锁；若已有实例，通过 `QLocalServer` 发送激活消息并退出。
3. **自检分支**：`--selfcheck` 时安装控制台消息处理器，只启动一次 `PythonEngine`，依次执行：
   - `run_serial_selfcheck()`：串口帧长、CRC、24-bit 换算、阻抗换算；
   - `run_python_selfcheck()`：解释器、依赖导入、API 版本；
   - `run_worker_selfcheck()`：算法线程与在线会话；
   - `run_bridge_selfcheck()`：桥接层完整链路。
   返回码为失败项数。
4. 创建 `UnattendedGuard`（空闲自动退出事件过滤器）。
5. `load_design_fonts()`：加载 `assets/fonts` 下的普惠体，按 styleName 区分字重。
6. `LicenseManager::verify()`：验签 `license.lic`。
7. `PythonEngine::start()`：启动嵌入式解释器。
8. **内层作用域**内创建：
   - `AcquisitionBridge`（QML 属性 `Acq`）
   - `RecordingPreview`（`Recording`）
   - `PostProcess`（`Analysis`）
   - `QQmlApplicationEngine`，注册图像 provider 与上下文属性 `Acq / Recording / Analysis / License / IdleGuard / AppDebugBuild`
   - `engine.loadFromModule("KSCEEGClient", "Main")`
   - `--demo` 时通过单次定时器调用演示数据源
9. `app.exec()`；作用域结束后 `PythonEngine::shutdown()`。

> 作用域是刻意设计的：`AcquisitionBridge` 析构时需要停止算法线程并等待其退出，而算法线程仍可能调用 Python；解释器必须最后关闭。

## 2. `common/`：公共地基

### 2.1 跨线程数据结构 `eegtypes.h`

| 类型 | 说明 |
| --- | --- |
| `SignalChunk` | 一块多通道样本。**帧优先交错**：`samples[frame * channels + channel]`，单位 µV；含首帧时间戳、序列号、采样率、通道数 |
| `GapRange` | 数据缺口 `[start_timestamp_ns, end_timestamp_ns]` |
| `AlgorithmErrorInfo` | 错误码、消息、操作名、会话/序列号、详情 |
| `ProcessingParams` | 在线处理参数（高通/低通/陷波/ASR/重参考/配置版本） |
| `ConfigUpdateInfo` | 配置更新请求与结果 |
| `TopographyFrame` / `TopographyRequest` | 地形图结果与查询 |
| `SpectrumFrame` / `SpectrumRequest` | 频谱结果与查询 |
| `SessionConfig` / `SessionStatusSnapshot` | 会话配置与状态快照 |
| `AlgorithmLogEvent` | Python 侧日志事件 |

全部通过 `Q_DECLARE_METATYPE` 注册，可跨线程排队传递。

### 2.2 电极蒙太奇 `eegmontage.h`

- `kChannelCount = 16`。
- 固定 16 电极表（Fp1/Fp2/F3/F4/C3/C4/P3/P4/O1/O2/F7/F8/T7/T8/Fz/Cz）及归一化头面坐标。
- 函数：`electrodes()`、`channel_name(i)`、`channel_names()`、`index_of(name)`、`channel_colors()`、`channel_gray_colors()`、`display_channel_indices(4/8/16)`、`is_frontal()`、`is_occipital()`。
- 通道颜色同时供波形、地形图、质检和报告使用。

### 2.3 记录文件格式 `eegbinformat.h`

- 魔数 `EEGBIN01`，版本 `1`，固定 64 字节头。
- 头内保存通道数、采样率、起始时间、帧数等；数据区为 `float32`，帧优先交错。
- 读取端以**文件实际长度**计算帧数，不信任头部 `frame_count`（防止记录中断导致头尾不一致）。

### 2.4 地形图配色 `topographypalette.h`

- 7 个停靠点从深蓝 `#173778` 到深红 `#cd2d2d`，插值成 256 项 LUT。
- `color(double normalized)` 返回颜色；实时地形图与离线后处理共用同一色标。

### 2.5 授权 `licensemanager.*`

`LicenseManager : QObject`，QML 属性 `checked / valid / message`。

- `verify()`：读取 exe 同级 `license.lic` 与 `public_key.pem`。
- 使用 nlohmann/json 解析；取 `license["data"].dump()` 作为原始待验签串。
- SHA-256 + RSA PKCS#1 v1.5 验签（OpenSSL `EVP_PKEY_verify`）。
- MAC 绑定：将本机网卡 MAC 的冒号替换为横线后与授权字段比对。
- 有效期字段 `expire_date`，格式 `%Y-%m-%dT%H:%M:%S`。
- **fail-closed**：任何缺失/解析失败/验签失败都视为无效，并写入审计日志。

### 2.6 审计日志 `auditlog.*`

- 命名空间 `audit_log`，函数：`set_current_user()`、`clear_current_user()`、`current_user()`、`record()`、`record_as()`、`log_file_path()`。
- 输出 `%LOCALAPPDATA%\EEG-KSC\logs\audit.log`，UTF-8 纯文本，每行 `用户ID | 日期 | 时间 | 事件`，首行表头。
- `QMutex` 保护，可任意线程调用。

### 2.7 无人值守 `unattendedguard.*`

- `client_config_path()`：**exe 同级优先**，其次源码目录（与数据库优先级相反）。
- `unattended_auto_exit_minutes(fallback)`：读取 `client-config.json`，默认 60 分钟；`0` 表示关闭。
- `UnattendedGuard`：安装为应用级事件过滤器，只把键盘、鼠标、滚轮、触摸、手写笔视为用户输入；`QTimer` 超时后发出 `idleTimedOut()`，由 QML 锁定界面。

## 3. `acquisition/`：串口采集

### 3.1 协议 `serialprotocol.h`

| 常量/函数 | 说明 |
| --- | --- |
| `0xA0` / `0xC0` | 数据帧头 / 帧尾 |
| `0xB0` / `0xD0` | 阻抗帧头 / 帧尾 |
| `frame_size(channel_count, with_crc)` | 当前仅支持 16 通道：无 CRC 51 字节，含 CRC 53 字节 |
| `crc16_modbus()` | CRC-16/MODBUS |
| `take_frame(...)` | 从字节缓冲中查找并切出完整帧，返回 `FrameKind{Data, Impedance}` |
| `bytes3_to_int()` / `bytes3_to_microvolt()` | ADS1299 24-bit 补码转 µV |
| `parse_impedance_kohm()` | 阻抗原始值转 kΩ |

换算基准：VREF 4.5 V、gain 8、24 bit，约 `0.0670552 µV/count`。命令字：`'b'` 开始采集、`'s'` 停止采集、`'Z'` 阻抗扫描。

### 3.2 原始环形缓冲 `rawringbuffer.*`

- `reset(channel_count, sample_rate, capacity_seconds)`。
- `append(chunk)`、`snapshot(max_seconds, SignalChunk*)`、`available_seconds()`。
- `QMutex` 保护；容量约为显示窗口上限的 6 倍（约 3 分钟），用于 ASR 参考样本拟合。
- **只由 `AcquisitionBridge` 写入**（唯一 `ChunkSink`），避免采集线程与 GUI 线程重复写。

### 3.3 采集线程 `serialcollector.*`

`class SerialCollector : public QThread`。

```cpp
class ChunkSink {
    virtual bool deliver(const SignalChunk &chunk) = 0;
    virtual bool deliver_gap(const GapRange &gap) = 0;
};
```

**配置与请求**

| 类型 | 字段 |
| --- | --- |
| `Config` | `port_name`、`baud_rate`(921600)、`channel_count`(16)、`sample_rate`(1000)、`crc_enabled` |
| `StartRequest` | `save_path`（空表示不落盘）、`save_format`（None/Csv/Binary）、`save_sample_rate`（0 表示与设备一致） |

**对外方法**：`set_config()`、`set_sink()`、`request_stop()`、`post_start()`、`post_stop()`、`post_impedance_start()`、`post_impedance_stop()`、`latest_impedance_kohm()`。

**信号**：`port_opened`、`port_open_failed`、`port_closed`、`stats_changed`、`status_message`、`failed`、`device_lost`、`collecting_changed`、`recording_changed`。

**run() 主循环**

1. 打开串口，初始化墙钟基准与单调时钟基准。
2. 依次执行 GUI 投递的命令（Start / Stop / Raw / ImpedanceStart / ImpedanceStop）。
3. 读取字节、切帧、解析、按需落盘。
4. 按节拍交付 `ChunkSink` 并刷新统计。

**生命周期细节**

- Start：重置运行状态 → 开始记录 → 写 `'b'` → `collecting_changed(true)`。
- Stop：写 `'s'` → 交付剩余尾块 → 声明缺口 → 结束记录 → 刷新统计 → `collecting_changed(false)`。
- 阻抗停止：先写 `'s'`；若此前正在采集，再补发 `'b'` 恢复。
- 投递失败不静默丢弃，而是 `merge_into_gap()` 累积为缺口。
- 通过 `port.error() == QSerialPort::ResourceError` 检测拔线并发出 `device_lost`。
- 任何退出路径都必须发出 `port_open_failed` 或 `port_closed`，避免界面停在「连接中」。
- 所有 `port.write()` 均检查返回值，失败时 `emit failed(...)`。

自由函数：`run_serial_selfcheck()`、`serial_crc_enabled(fallback=false)`。

## 4. `algorithm/`：嵌入式 Python

### 4.1 `PythonEngine`（pimpl）

头文件不暴露 pybind11，所有 Python 头只出现在 `.cpp`。

| 方法 | 说明 |
| --- | --- |
| `start()` | 构造 `PyConfig`、启动解释器、配置 `sys.path`、导入 `eeg_bridge` 并校验 API 版本，随后释放 GIL |
| `shutdown()` | 持 GIL 调 `eeg_bridge.close_api()`，再依次销毁 `gil_scoped_release` 与解释器 |
| `is_running()` / `api_version()` | 状态查询 |
| `project_dir()` / `bridge_dir()` / `venv_dir()` | 路径查询 |
| `install_console_message_handler()` | 自检输出直达 stdout |
| `run_python_selfcheck()` | 解释器与依赖自检 |

**路径三级解析** `resolve_dir(env, portable_name, fallback)`：

1. 同名环境变量；
2. exe 同级同名目录（`python/`、`venv/`、`app/`、`bridge/`）；
3. 编译期默认值（`PYTHON_ROOT_DIR` 等）。

**解释器配置**

- `config.parse_argv = 0`、`user_site_directory = 0`。
- `home` 指向 Python 基础安装。
- `executable` 指向 `venv/Scripts/python.exe`，并要求 `pyvenv.cfg` 存在。
- 将 `bridge` 与 `app` 目录插入 `sys.path` 头部。
- 启动日志打印 Python 版本、`executable`、`prefix`、`base_prefix`，并尝试导入 numpy / scipy / eeg_algorithm / eeg_bridge。

**GIL 约定**：`start()` 成功后立即释放 GIL；`PythonWorker` 每次调用 Python 时用 `py::gil_scoped_acquire` 获取，作用域尽量小。

### 4.2 类型转换 `pythontypes.h`

命名空间 `pytypes`：

- `to_std_string` / `to_qstring`
- `to_py_list` / `to_py_positions`
- `to_py_processing`（处理参数 → dict）
- `to_py_values`（C++ 帧优先交错 → Python `[C, N]`）
- `to_py_timestamps`
- `copy_py_values_to_chunk` / `copy_py_float_array` / `copy_py_int64_array`

> 热路径上 Python 返回的 numpy 数组是**视图**，必须在本作用域内完成 memcpy，不能保存裸指针。

### 4.3 算法线程 `PythonWorker`

常量：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `kBlockQueueCapacity` | 8 | 数据块队列容量 |
| `kIdleTickMs` | 50 | 空闲轮询周期 |
| `kLogDrainIntervalMs` | 300 | 日志拉取周期 |
| `kStatusIntervalMs` | 500 | 状态上报周期 |
| `kAsrReferenceSeconds` | 60 | ASR 参考最少时长 |
| `kAsrRefitRetryMs` | 2000 | ASR 拟合重试间隔 |

**run() 结构**

```
session = new PythonSession
py::gil_scoped_acquire → import eeg_bridge → open_api()
若失败：emit algorithm_failed("NOT_INITIALIZED") 并返回

while (!stop):
  try:
    取数据（等待最多 50ms）→ 处理 Gap / Block
    → 应用配置更新
    → 处理地形图/频谱查询
    → 按节拍拉日志、发状态
  catch (...):
    上报算法错误，保持线程存活
```

**数据块处理**

- 序列号不连续时先补 `notify_gap()`，`gap_end = 下一块首时间戳 - 1`。
- GIL 只包住「构造入参 → `push_block` → 抽干结果」。
- 失败时查询 `online_status` 获取权威状态；若为 `error`，清空队列并发 `session_state_changed`。

**配置更新**

- 通过 `config_version` 严格递增。
- 当 ASR 参考尚未就绪时，先以 `asr=false` 生效并记录 `asr_deferred`；成功后推进版本，失败不推进。

**信号**

`block_processed`、`session_opened`、`session_closed`、`config_applied`、`topography_ready`、`spectrum_ready`、`status_updated`、`notice`、`algorithm_failed`、`session_state_changed`、`log_event`。

**析构**：`request_stop()` + `wait(10000)`，禁止 `terminate()`。

### 4.4 离线算法调用 `offlinealgorithm.*`

命名空间 `offlinealgorithm`：

```cpp
struct Input  { QString record_no; QByteArray raw; int channel_count; ... };
struct Output { ... };
struct Spectrum { ... };
struct Segment { ... };
bool available();
Output run(const Input &input);
```

- `run()` 获取 GIL、创建离线会话、执行预处理、查询所需的频谱/地形图/统计/质检、关闭会话，全部在一次调用内完成。
- 适配层函数负责把 `AlgorithmError` 转成 C++ 可读的错误信息。
- 构造的配置字典必须与 `eeg_bridge._parse_preprocess_config` 的扁平键完全一致（陷波中心 ±2 Hz、`reference_index` 0 表示双侧乳突等）。

## 5. `bridge/`：QML 门面

### 5.1 `AcquisitionBridge`

QML 上下文属性名 `Acq`，所有 `Q_PROPERTY` 与信号都在 GUI 线程产生。

**属性分组**

| 分组 | 代表属性 |
| --- | --- |
| 串口 | `availablePorts`、`portOpen`、`collecting`、`statusText`、`errorText`、`statsText`、`receivedFrames`、`droppedBytes` |
| 记录 | `recordingPath`、`defaultRecordDir`、`recordSampleRate` |
| 波形 | `channelCount`、`channelNames`、`channelColors`、`grayscaleWave`、`channelVisibleMask`、`waveRevision`、`timeWindow`、`yRangeUV`、`dcRemoval` |
| 滤波 | `highPassEnabled/lowPassEnabled/notchEnabled/asrEnabled` 及各自频率/区间 |
| 会话 | `sessionState`、`errorCode`、`errorMessage`、`canReset`、`warmupText`、`processingTimeText` |
| 地形图 | `topoRevision`、`topoBand`、`topoStats`、`topoScaleMax`、`topoStatusText`、`topoPalette` |
| 频谱 | `spectrumRevision`、`spectrumChannel`、`spectrumCurve`、`spectrumBandValues`、`spectrumStatusText` |
| 事件 | `events`、`eventCount` |
| 电极质量 | `electrodeQuality`、`electrodeSummary`、`electrodeScanValid`、`electrodeMap` |
| 演示源 | `demoSource` |

**主要 Q_INVOKABLE**

- 连接：`refresh_ports()`、`open_port(port, baud, sample_rate)`、`close_port()`、`connect_device()`
- 采集：`start_collection(directory, patient_no)`、`stop_collection()`、`reset_session()`、`clear_error()`
- 记录：`snapshot_dir()`、`collection_summary()`、`elapsed_seconds()`
- 演示：`start_demo_source()`、`stop_demo_source()`
- 显示：`is_channel_visible()`、`set_channel_visible()`、`set_all_channels_visible()`、`set_wave_view_size()`、`clear_display()`
- 电极：`begin_electrode_scan()`、`scan_electrodes()`
- 事件：`add_event()`、`set_event_label()`、`remove_event()`、`clear_events()`

**内部数据流**

- 构造时若解释器已运行：`m_worker.set_raw_source(&m_raw_buffer)` 并启动算法线程；连接算法线程全部信号（`Qt::QueuedConnection`）。
- 启动显示、地形图、频谱、演示四类定时器。
- `deliver(chunk)`：先写 `RawRingBuffer`（按采样率计算帧周期），再 `m_worker.deliver(chunk)`；失败交给 `deliver_gap()`。
- `open_port()`：固定 16 通道，读取 `serial_crc_enabled`，重置原始缓存，创建并启动 `SerialCollector`。
- `on_block_processed()`：压入 `m_display_pending`，满则丢最旧。
- `pump_display()`：批量 swap 取出 → `append_to_display()` → `render_wave()`。
- `render_wave()`：`generation` 未变化则跳过；锁内取快照，锁外绘制。

**析构顺序**：`close_port()` → `m_worker.request_stop()` + `wait(15000)` → 解释器由 `main` 关闭。

### 5.2 图像 provider

`WaveformImageProvider`、`TopoMapImageProvider` 持有**非拥有**的 `AcquisitionBridge` 指针，向 QML 提供波形与地形图 `QImage`。后处理与回放另有各自的 provider。

## 6. `analysis/`：回放、后处理与报告

### 6.1 `RecordingPreview`（QML 名 `Recording`）

- `open(path)`：`QFile` + memory map 读取 `.eegbin`。
- 校验魔数、版本、头长度；读取通道数、采样率、起始时间。
- 以文件实际长度计算帧数，忽略头部 `frame_count`。
- 任何失败统一走 `unload()`，保证状态一致。
- 属性：`loaded`、`errorText`、`channelCount`、`sampleRate`、`durationSeconds`、`startTimeText`、`channelNames`、`windowStart`、`windowSeconds`、`yRangeUV`、`revision`。
- `render_window()` 供 PDF 报告复用。
- `RecordingImageProvider` 输出回放波形图。

### 6.2 `PostProcess`（QML 名 `Analysis`）

负责「数据分析与后处理」页的全部状态与计算。

**静态计算入口**

- `compute()`：完整离线流水线；
- `compute_wave()` / `compute_spectrum()` / `compute_topography()`：由已处理的 `processed` 数据出图。

**调度机制**

- 参数变化 → `schedule_recompute()` 防抖 → `QtConcurrent::run(run_recompute)`；
- `generation` 递增，`on_recompute_finished()` 丢弃过期结果；
- `Fingerprint` 覆盖所有重算参数与原始数据指针；仅窗口/标尺/事件/当前导联变化时复用 `processed`。

**计算内容**

1. 构造 `offlinealgorithm::Input`（基线、质检参数、降采样 divisor、`resample_target_hz`）。
2. 调用 `offlinealgorithm::run()`。
3. 完整性守卫（通道数与地形图 `6 × C`）。
4. 生成处理链文案（高通/低通/陷波/ASR/降采样/线性插值修复）。
5. 保存 `processed`（帧优先交错 float）供导出。
6. 构造频谱、通道统计、频带能量、频带分布、相关性图、质检计数与伪迹段。
7. 依次生成波形/频谱/地形图图像。

**主要属性**：加载状态、记录信息、滤波参数、重参考、降采样、基线、ASR、伪迹检测、质检开关与阈值、修复方式、导出格式/类型/范围、选段时间、当前通道、窗口、事件选择、通道名/颜色、频带定义、`channelStats`、`bandDistribution`、`channelBands`、`topoStats`、`reportSections`、`statusGroups`、`laneHeight`(78)、`waveRangeUV`、频谱坐标范围、`busy`、`revision`。

**Q_INVOKABLE**：`open(record_no, file_path, ...)`、`close()`、`set_view_size()`、`export_data()`、`export_stats_csv()`、`export_report_txt()`。

### 6.3 `RecordReport`

`QML_ELEMENT`，按需实例化。`exportPdf(session, events, directory)`：

- A4、150 dpi（约 1240×1754），页边距 56。
- 固定 100 µV 量程，保证不同记录段可横向比较。
- 包含记录信息、事件、波形、统计与地形图。
- 字体与 `Design.qml` 一致（Alibaba PuHuiTi 2.0，按 styleName 选择字重）。

## 7. `storage/`：`AppDatabase`

`QML_ELEMENT`，属性 `databasePath`，方法全部为 `Q_INVOKABLE`。

| 分组 | 方法 |
| --- | --- |
| 登录 | `authenticateOrRegister(phone, password)`、`lastLogin()`、`saveLoginRecord()`、`setCurrentUser()` |
| 患者 | `patients()`、`addPatient()`、`updatePatient()`、`removePatient()` |
| 记录 | `recordCollection()`、`finishCollection()`、`sessions(patient_no)`、`session(record_no)`、`sessionEvents()`、`removeSession()`、`exportSession()` |
| 偏好 | `setting(key, fallback)`、`setSetting()`、`recordDirectory()` |
| 标签 | `tags()`、`addTag()`、`updateTag()`、`removeTag()` |
| 用户 | `users()`、`addUser()`、`updateUser()`、`resetPassword()`、`changePassword()`、`canChangeOwnPassword()`、`setUserStatus()`、`currentAccount()` |

数据表结构见 [05-data-storage.md](05-data-storage.md)。内置超级管理员 `admin` 写死在代码中（`kBuiltinAdminUser`），不在 `users` 表内。
