# 06 · 构建、运行与打包

## 1. 环境要求

| 依赖 | 版本/路径（本机默认值） | 说明 |
| --- | --- | --- |
| Windows | x64 | 仅支持 Windows |
| Visual Studio | 2019（MSVC 14.29） | 必须在 x64 开发者环境编译 |
| Qt | 6.6.3 `msvc2019_64` | 默认 `D:/Qt/6.6.3/msvc2019_64` |
| CMake | ≥ 3.16 | 需在 `PATH` |
| Python | 3.11 基础安装 | 默认 `C:/Program Files/Python311` |
| pybind11 | 3.1.0 源码 | 默认 `D:/work/learn/pybind11/pybind11-3.1.0` |
| 算法 venv | `PythonScript/venv` | 含 numpy / scipy |
| 算法包源码 | `PythonScript/src` | 即 `eeg_algorithm` |

所有路径都是 CMake `CACHE` 变量，换机器时用 `-D<变量>=...` 覆盖，无需改代码：

| 变量 | 含义 |
| --- | --- |
| `Python_ROOT_DIR` | Python 基础安装根目录 |
| `PYTHON_VENV_DIR` | 算法 venv 目录 |
| `EEG_ALGO_SRC_DIR` | `eeg_algorithm` 源码目录 |
| `EEG_BRIDGE_DIR` | `eeg_bridge.py` 所在目录 |
| `PYBIND11_SOURCE_DIR` | pybind11 源码目录 |

## 2. 构建

必须在 **VS2019 x64 开发者命令提示符**中执行（需要 `INCLUDE` / `LIB` 等环境变量），或先加载 `vcvars64.bat`。

```bat
:: 配置（NMake Makefiles）
cmake -S KSCEEGClient -B KSCEEGClient/build/release -G "NMake Makefiles" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH="D:/Qt/6.6.3/msvc2019_64" ^
    -DKSCEEG_CONSOLE=ON

:: 构建
cmake --build KSCEEGClient/build/release --parallel 1
```

### 2.1 关键构建选项

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `KSCEEG_CONSOLE` | `OFF` | `ON` 时构建控制台程序，可看到 Python 日志与自检输出 |
| `CMAKE_BUILD_TYPE` | — | `Debug` / `Release` |
| `CMAKE_PREFIX_PATH` | — | 指向 Qt 6.6.3 msvc2019_64 |

### 2.2 编译细节

- Qt 组件：`Quick`、`Sql`、`SerialPort`、`Concurrent`、`Network`。
- OpenSSL `Crypto`、`pybind11::embed`。
- MSVC 选项：`/Zm2000`（缓解 QML 翻译单元过大导致的 C1060）、`/utf-8`（防止 δ θ α β γ 等字符静默错乱）。
- 编译期宏：`KSCEEG_SOURCE_DIR`、`PYTHON_ROOT_DIR`、`PYTHON_VENV_DIR`、`EEG_ALGO_SRC_DIR`、`EEG_BRIDGE_DIR`、`KSCEEG_DEBUG_BUILD`。
- QML 模块 URI：`KSCEEGClient`；`Design.qml`、`Privacy.qml` 注册为 singleton。
- POST_BUILD 拷贝：设计字体、`python311.dll`、`libcrypto-3-x64.dll`。

### 2.3 辅助脚本

以下脚本位于被 git 忽略的 `KSCEEGClient/build/`：

| 脚本 | 用途 |
| --- | --- |
| `build/selfcheck.cmd` | Debug + 控制台构建；`--run` 顺带跑自检 |
| `build/relbuild.cmd` | Release + 控制台构建；`--run` 顺带跑自检 |
| `build/rebuild.cmd` | 复用 Qt Creator Debug 构建目录做增量编译 |
| `build/configure-nmake-debug.cmd` | 配置 `build/nmake-debug` |
| `build/build-nmake-debug.cmd` | 构建 `build/nmake-debug` |
| `build/package.cmd` | 打包可移植目录 |
| `build/clean-db.py` | 打包时生成清空数据后的数据库副本 |

## 3. 运行

```bat
:: 正常启动（全屏界面）
appKSCEEGClient.exe

:: 接口自检：不启界面，退出码为失败项数
appKSCEEGClient.exe --selfcheck

:: 演示模式：进程内合成数据，无设备也能跑通整条链路
appKSCEEGClient.exe --demo
```

### 3.1 自检覆盖范围

| 自检 | 内容 |
| --- | --- |
| `run_serial_selfcheck()` | 帧长、CRC-16/MODBUS、24-bit 补码转 µV、阻抗换算 |
| `run_python_selfcheck()` | 解释器、venv、numpy/scipy/eeg_algorithm/eeg_bridge 导入、API 主版本 |
| `run_worker_selfcheck()` | 算法线程启动、在线会话、配置更新、缺口通知 |
| `run_bridge_selfcheck()` | 桥接层完整链路 |

### 3.2 启动依赖

- 授权：exe 同级 `license.lic` + `public_key.pem`；验证失败会提示并可能限制功能。
- 数据库：首次运行自动建表；开发期在源码目录，打包后在 exe 同级。
- Python：按「环境变量 → exe 同级目录 → 编译期默认值」解析。

## 4. 算法包开发

```powershell
cd PythonScript
python -m pip install -e ".[dev]"
python -m pytest
```

启用可选相位模型：

```powershell
python -m pip install -e ".[dev,phase]"
```

测试布局：

- `tests/contract/`：公共 API 契约；
- `tests/integration/`：在线/离线流水线；
- `tests/performance/`：在线延迟；
- `tests/unit/`：日志等单元测试。

基准：

```powershell
python benchmarks/benchmark_push_block.py
python benchmarks/benchmark_push_sample.py
python benchmarks/benchmark_offline_pipeline.py
```

## 5. 打包（可移植分发）

目标：整个目录拷到另一台 Windows x64 机器即可运行，目标机**无需安装** Qt / Python。

```bat
build\package.cmd            :: 构建（Release，窗口程序）并组装
build\package.cmd --no-build :: 复用已构建 exe，只重新组装
build\package.cmd --zip      :: 额外生成 dist\EEG-KSC-portable.zip
```

产物：`KSCEEGClient/build/dist/EEG-KSC/`。

### 5.1 组装步骤

0. 由开发库 `eeg-ksc.db` 生成清空后的副本（各表数据删除、自增计数归零），源库保持不变；脚本 `build/clean-db.py`。
1. 拷贝 exe、`python311.dll`、设计字体、数据库模板、`client-config.json`。
2. `windeployqt` 收集 Qt DLL、平台插件、QML 模块。
3. 拷贝 Python 3.11 基础安装到 `python\`。
4. 拷贝 `PythonScript/venv` 到 `venv\`。
5. 拷贝 `PythonScript/src` 到 `app\`。
6. 拷贝 `KSCEEGClient/python` 到 `bridge\`。

### 5.2 最终目录

```
dist/EEG-KSC/
├── appKSCEEGClient.exe
├── python311.dll
├── Qt6*.dll
├── platforms/  qml/ ...
├── assets/fonts/
├── python/                 # Python 3.11 基础安装
├── venv/                   # numpy / scipy
├── app/                    # eeg_algorithm
├── bridge/                 # eeg_bridge.py
├── eeg-ksc.db              # 清空后的表结构模板
└── client-config.json
```

> 打包脚本要求 `KSCEEGClient/eeg-ksc.db` 存在；该文件被 `.gitignore` 忽略。客户端首次运行会自动建表，可作为模板。模板中的账号表不含内置 `admin`。

## 6. 故障排查

### 6.1 并行编译报 C1060

**现象**：MSVC 报 `C1060: compiler is out of heap space`。

**原因**：QML 缓存生成会把所有 QML 合并进一个巨大的翻译单元。

**处理**：保留 `--parallel 1`；`/Zm2000` 只能缓解，不能并行。

### 6.2 改头文件后启动/退出崩溃

**现象**：改完类定义（尤其新增成员）后程序能启动、界面正常，但退出时报：

```
Run-Time Check Failure #2 - Stack around the variable 'bridge' was corrupted.
```

**根因**：Qt Creator 的构建目录由 CMake 4.3 + `NMake Makefiles JOM` 生成，头文件依赖跟踪失效（`.obj.d` 为 0 字节，`compiler_depend.make` 不列头文件）。`main.cpp` 未重编，链接出「旧布局 `main.o` + 新布局 `acquisitionbridge.o`」的混合 exe；构造函数多写的字节覆盖了 `main` 栈帧保护字节。

**判定**：比较 `main.cpp.obj` 与所改头文件的时间戳：

```powershell
Get-Item "KSCEEGClient\build\Desktop_Qt_6_6_3_MSVC2019_64bit_Debug\CMakeFiles\appKSCEEGClient.dir\src\main.cpp.obj",
         "KSCEEGClient\src\bridge\acquisitionbridge.h" | Select LastWriteTime,Name
```

**处理**：清理并重新构建该目录，或删除构建目录后重新配置。仅跑增量 `cmake --build` 不足以强制重编 `main.cpp`；`build/rebuild.cmd` 也只做增量。

### 6.3 中文/希腊字母乱码

源码必须以 UTF-8 编译。CMakeLists 已加 `/utf-8`，不要移除。

### 6.4 Python 导入失败

检查：

1. `python311.dll` 是否在 exe 同级；
2. `venv/pyvenv.cfg` 是否存在；
3. `app/` 与 `bridge/` 是否在 exe 同级（或设置对应环境变量）；
4. 用 `--selfcheck` 查看具体失败项。

### 6.5 无设备时验证链路

使用 `--demo`，演示数据源在进程内合成，覆盖采集、算法、显示、落盘全链路。

## 7. 构建产物与运行期目录对照

| 场景 | 数据库 | Python | 配置 |
| --- | --- | --- | --- |
| 开发机直接运行 `build/.../exe` | 源码目录 `eeg-ksc.db` | 编译期默认路径 | exe 同级优先，其次源码目录 |
| 打包目录运行 | exe 同级 `eeg-ksc.db` | exe 同级 `python/`、`venv/`、`app/`、`bridge/` | exe 同级 `client-config.json` |
| 设置环境变量 | 不受影响 | 环境变量优先 | 不受影响 |
