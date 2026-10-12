# EEG-KSC 脑电采集与分析系统

一套面向 16 导联 EEG 设备的桌面软件：串口实时采集 → 在线算法（滤波 / 重参考 / ASR / 频谱 / 地形图）→
历史回放与离线后处理 → A4 报告导出。

客户端为 **Qt 6 + QML**，算法为 **Python 包**，两者通过**进程内嵌入式 CPython（pybind11）**打通 ——
不需要另起 Python 进程，也不走 socket/IPC。

## 仓库结构

| 目录 | 说明 |
| --- | --- |
| `KSCEEGClient/` | C++ / Qt 桌面客户端（含 QML 界面、串口采集、嵌入式 Python 门面） |
| `PythonScript/` | `eeg_algorithm` 算法包（在线 / 离线接口），另见 [PythonScript/README.md](PythonScript/README.md) |

## 客户端模块划分（`KSCEEGClient/src/`）

源码按职责分为 6 个模块，`main.cpp` 留在 `src/` 根，只负责把各门面组装起来。

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `common/` | 跨模块共用的地基：跨线程数据结构、电极蒙太奇、`.eegbin` 文件格式、地形图配色、无人值守自动退出、审计日志 | — |
| `storage/` | 本地 SQLite（账号 / 偏好 / 患者 / 标签 / 采集记录） | — |
| `acquisition/` | 串口采集链路：协议解析、原始环形缓冲、采集线程 | `common` |
| `algorithm/` | 嵌入式 Python 解释器门面、算法线程、离线算法调用层 | `common` `acquisition` |
| `bridge/` | QML 门面（`AcquisitionBridge`）与波形 / 地形图图像 provider | `common` `acquisition` `algorithm` |
| `analysis/` | 历史记录回放、「数据分析与后处理」页、A4 报告导出 | `common` `algorithm` |

依赖方向尽量自下而上（`common` → `acquisition` → `algorithm` → `bridge` / `analysis`）。
`acquisition` 与 `algorithm` 之间存在双向引用，且都是真实依赖：

- `algorithm/pythonworker.h` 继承 `acquisition/serialcollector.h` 里的 `ChunkSink` 抽象接口；
- `acquisition/serialcollector.cpp` 的串口自检（`run_serial_selfcheck`）调用了
  `algorithm/pythonengine.h` 声明的自由函数 `install_console_message_handler()`
  （把自检输出直接写 stdout，绕开 Qt 默认只写到「正在附加」终端的行为）。

> 模块名用 `storage` 而非 `data`，因为仓库根 `.gitignore` 有一条 `data/` 规则会让该目录被 git 忽略。

## 运行时组成

| 组件 | 作用 |
| --- | --- |
| `QML`（`qml/`） | 界面。实时波形 / 地形图由 C++ 用 `QPainter` 画好后经 `QQuickImageProvider` 交给 `Image` 贴图，不走 QML Canvas |
| 串口线程（`SerialCollector`） | 收字节、按协议切帧、解析成 µV、落盘 `.eegbin` |
| 算法线程（`PythonWorker`） | 持有在线会话，串行处理数据块 / 配置更新 / 查询 |
| 嵌入式 CPython | 由 `PythonEngine` 管理生命周期（pimpl，pybind11 只出现在 `.cpp`） |

## 依赖环境

| 依赖 | 本机路径（CMake 默认值，可覆盖） |
| --- | --- |
| Qt 6.6.3（msvc2019_64） | `D:/Qt/6.6.3/msvc2019_64` |
| Visual Studio 2019（MSVC 14.29） | `C:\Program Files (x86)\Microsoft Visual Studio\2019\Community` |
| CMake ≥ 3.16 | 需在 PATH |
| Python 3.11 **基础安装** | `C:/Program Files/Python311` |
| pybind11 3.1.0（源码方式引入） | `D:/work/learn/pybind11/pybind11-3.1.0` |
| 算法 venv（numpy / scipy） | `PythonScript/venv` |
| 算法包源码 | `PythonScript/src` |

上述路径都是 CMake 的 `CACHE` 变量，换机器时用 `-D<变量>=...` 覆盖即可，无需改代码：

`Python_ROOT_DIR`、`PYTHON_VENV_DIR`、`EEG_ALGO_SRC_DIR`、`EEG_BRIDGE_DIR`、`PYBIND11_SOURCE_DIR`。

## 构建（开发机）

必须在 **VS2019 x64 开发环境**里执行（`cl` 之外还需要 `INCLUDE` / `LIB` 等变量）。
命令行方式先加载 `vcvars64.bat`，或直接用 Visual Studio 开发者命令提示符。

```bat
:: 1) 配置（NMake Makefiles 生成器）
cmake -S KSCEEGClient -B KSCEEGClient/build/release -G "NMake Makefiles" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH="D:/Qt/6.6.3/msvc2019_64" ^
    -DKSCEEG_CONSOLE=ON

:: 2) 构建
cmake --build KSCEEGClient/build/release --parallel 1
```

注意事项：

- **`--parallel 1` 不要去掉**：QML 缓存生成会把所有 QML 合并进一个巨大的翻译单元，并行编译会让 MSVC
  报 `C1060`（编译器堆空间不足）。CMakeLists 里的 `/Zm2000` 只能缓解，不能并行。
- `KSCEEG_CONSOLE=ON` 时构建为控制台程序，能看到 Python 侧日志与自检输出；默认 `OFF`（窗口程序）。
- 源码必须按 UTF-8 编译（CMakeLists 已加 `/utf-8`），否则频段的 δ θ α β γ 等字符会静默错乱。

现成的辅助脚本（位于被 git 忽略的 `KSCEEGClient/build/`）：

| 脚本 | 用途 |
| --- | --- |
| `build/selfcheck.cmd` | Debug + 控制台构建；加 `--run` 顺带跑自检 |
| `build/relbuild.cmd` | Release + 控制台构建；加 `--run` 顺带跑自检 |
| `build/rebuild.cmd` | 复用 Qt Creator 的 Debug 构建目录做增量编译 |
| `build/configure-nmake-debug.cmd` / `build-nmake-debug.cmd` | 手工配置 / 构建 `build/nmake-debug` |

### 改完代码后启动/退出崩溃：陈旧增量构建

**症状**：Debug 构建下改完代码（尤其是改了某个类的成员，或改动了头文件）后，程序能启动、界面也正常，
但**退出时**弹出：

```
Run-Time Check Failure #2 - Stack around the variable 'bridge' was corrupted.
```

也可能表现为其它内存错乱 / 随机崩溃，或行为与改动的代码对不上。

**根因**：Qt Creator 的构建目录 `build/Desktop_Qt_6_6_3_MSVC2019_64bit_Debug` 由 **CMake 4.3 + `NMake Makefiles JOM`**
生成，其头文件依赖跟踪已失效 —— `CMakeFiles/appKSCEEGClient.dir/src/main.cpp.obj.d` 是 0 字节，
`compiler_depend.make` 里 `main.cpp` 的依赖项**只列源文件、不列任何头文件**。于是当
[acquisitionbridge.h](KSCEEGClient/src/bridge/acquisitionbridge.h) 新增成员 `int m_record_sample_rate`
（`sizeof(AcquisitionBridge)` 由 `0x670` 变 `0x678`）后，`main.cpp` **没有被重编**，最终链接出
「旧布局的 `main.o` + 新布局的 `acquisitionbridge.o`」混合的 exe。构造函数按新布局多写的 8 字节正好覆盖了
`main` 栈帧中 `bridge` 变量之后的保护字节 —— MSVC `/RTC1`（含 `/RTCs`）会在函数返回时用
`_RTC_CheckStackVars` 逐一校验局部变量的保护字节，于是 `main` 返回时报出该错。

**判定**：凡是「改了类定义 / 头文件后出现行为异常、崩溃、内存错乱」，先怀疑此因。快速自查：比对
`build/Desktop_Qt_6_6_3_MSVC2019_64bit_Debug/CMakeFiles/appKSCEEGClient.dir/src/main.cpp.obj`
与所改头文件的时间戳，若 obj 更早，即为未重编：

```powershell
Get-Item "KSCEEGClient\build\Desktop_Qt_6_6_3_MSVC2019_64bit_Debug\CMakeFiles\appKSCEEGClient.dir\src\main.cpp.obj",
         "KSCEEGClient\src\bridge\acquisitionbridge.h" | Select LastWriteTime,Name
```

**处理**：对该目录执行「**清理 + 重新构建**」，或直接删除 `build/Desktop_Qt_6_6_3_MSVC2019_64bit_Debug`
后让 Qt Creator 重新配置。注意：**只跑 `cmake --build`（增量）不足以强制重编 `main.cpp`**，`build/rebuild.cmd`
只做增量构建，不能解决本问题。

## 运行参数

| 参数 | 作用 |
| --- | --- |
| `--selfcheck` | 不启界面，跑接口自检（串口协议换算 + C++ 与算法包之间的接口），退出码即失败项数 |
| `--demo` | 切换到进程内合成的演示数据源，无设备时也能跑通整条链路 |

自检示例：`KSCEEGClient\build\selfcheck\appKSCEEGClient.exe --selfcheck`

## 打包（可移植分发）

目标：整个目录拷到另一台 Windows x64 机器即可运行，目标机**无需安装** Qt / Python。

```bat
build\package.cmd            :: 构建（Release，窗口程序）并组装
build\package.cmd --no-build :: 复用已构建好的 exe，只重新组装
build\package.cmd --zip      :: 额外生成 dist\EEG-KSC-portable.zip
```

组装产物在 `KSCEEGClient/build/dist/EEG-KSC/`，共 6 步：

1. 拷贝 exe、`python311.dll`、设计字体（`assets/fonts`）、数据库模板 `eeg-ksc.db`、运行期配置 `client-config.json`；
2. `windeployqt` 收集 Qt 运行期（DLL、平台插件、QML 模块）；
3. 拷贝 Python 3.11 基础安装到 `python\`；
4. 拷贝 `PythonScript/venv` 到 `venv\`；
5. 拷贝算法包 `PythonScript/src` 到 `app\`；
6. 拷贝宿主适配层 `KSCEEGClient/python` 到 `bridge\`。

最终目录布局：

```
dist/EEG-KSC/
├── appKSCEEGClient.exe     python311.dll     Qt6*.dll     platforms/  qml/ ...
├── assets/fonts/           # 设计字体
├── python/                 # Python 3.11 基础安装
├── venv/                   # numpy / scipy
├── app/                    # eeg_algorithm 算法包
├── bridge/                 # eeg_bridge.py 适配层
└── eeg-ksc.db              # SQLite 表结构模板（含预置 admin）
└── client-config.json      # 运行期配置（无人值守自动退出分钟数等）
```

运行期 Python 路径由 [pythonengine.cpp](KSCEEGClient/src/algorithm/pythonengine.cpp) 的 `resolve_dir`
按三级顺序解析：**同名环境变量 → exe 同级同名目录 → 编译期默认值**。开发机构建目录旁边没有
`python\`/`venv\`/`app\`/`bridge\`，自然落到编译期默认值，与打包目录互不干扰。

> 打包脚本会校验 `KSCEEGClient/eeg-ksc.db` 是否存在。该文件被 `.gitignore` 忽略；
> 客户端首次运行会在源码目录自动建表并预置 `admin`，把它作为模板使用即可。

## 运行期数据位置

- **账号 / 患者 / 记录库**：开发运行时为 `KSCEEGClient/eeg-ksc.db`（编译期宏 `KSCEEG_SOURCE_DIR`），
  打包后为 exe 同级 `eeg-ksc.db`。
- **采集记录波形**：`.eegbin`（64 字节头 + float32 帧优先交错样本），与 UI 同源的读取逻辑在
  `analysis/recordingpreview.cpp`。
- **运行期配置**：`client-config.json`。解析顺序与数据库模板相反，**exe 同级优先**，其次源码目录
  （开发期从 `build/` 跑时用），便于现场改配置而不动源码。字段 `unattended_auto_exit_minutes`
  为无人值守自动退出的空闲阈值（分钟，默认 60）：连续该时长没有任何鼠标 / 键盘操作即退出程序，
  设为 `0` 关闭该功能。改动后需重启程序生效。
- **日志与本地数据**：`QStandardPaths::AppLocalDataLocation`，应用名为 `EEG-KSC`。
- **审计日志**：`%LOCALAPPDATA%\EEG-KSC\logs\audit.log`（UTF-8 纯文本，每行一条）。
  每条固定四字段 `用户ID | 日期 | 时间 | 事件`，事件置于末列便于前 3 列稳定解析；首行为表头。
  覆盖三类事件：①用户登录 / 退出及登录失败、账号创建 / 修改 / 重置密码 / 启停用；
  ②账号管理操作；③核心功能（开始 / 停止采集、打开记录后处理、各类数据与报告导出）。
  「用户ID」取登录账号 `username`（登录失败时账号可能尚未建立、拿不到 `U-0001` 形式的 uid，
  而失败尝试同样需要留痕）。实现见 [auditlog.h](KSCEEGClient/src/common/auditlog.h) /
  [auditlog.cpp](KSCEEGClient/src/common/auditlog.cpp)，经 `QMutex` 保护，可任意线程调用。

## 已知问题与修复记录

代码审查中确认的问题及处置（按影响排序）：

1. **原始环形缓冲被采集线程与 GUI 线程各写一次** → 已修复。ASR 参考样本只由
   `AcquisitionBridge`（唯一 `ChunkSink`）写入，`SerialCollector` 侧的那次重复写已移除；
2. **算法线程主循环缺少兜底 `catch`** → 已修复。[pythonworker.cpp](KSCEEGClient/src/algorithm/pythonworker.cpp)
   主循环补了 `catch (const std::exception &)`：`py::cast_error` 等非 `py::error_already_set`
   的异常不再穿出 `QThread::run()` 触发 `std::terminate`；
3. **后处理 pending 补跑在 `generation` 不匹配时被提前 `return` 跳过** → 未能复现（按现有
   调用路径不会走到），本轮未改动；
4. **断线重连后 `m_impedance_pending` 未复位** → 已修复。`reset_port_flags()` 一并清零该标志。

中低优先级项的处置：

- **`removePatient` 只删库行、不删磁盘 `.eegbin`** → 已修复：删行前先查出该患者名下所有
  `file_path`，删库后逐个 `QFile::remove`（删不掉只记日志，与 `removeSession` 同口径）；
- **单条记录的读 / 改 / 删 / 导出缺少患者归属校验** → 已修复：新增
  `patientBelongsToCurrentUser()` / `sessionBelongsToCurrentUser()`，`updatePatient`、
  `removePatient`、`session`、`removeSession`、`exportSession` 均按与列表查询一致的
  可见性规则（管理员放行，其余角色限 `created_by`）拦截越权；
- **`port.write()` 返回值未检查** → 已修复：[serialcollector.cpp](KSCEEGClient/src/acquisition/serialcollector.cpp)
  中 7 处写串口的调用均检查返回值，失败时 `emit failed(...)`；
- **口令明文存储** → 未修复（保持现状，改动涉及既有账号数据的迁移）；
- 其余（`RawRingBuffer` 锁外读 `m_channels`、EDF 字段非 ASCII 丢字、`copy_*` 返回值）
  为技术性 / 标准限制或已有兜底，暂不处理。

