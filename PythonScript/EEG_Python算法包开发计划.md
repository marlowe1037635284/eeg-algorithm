# EEG Python算法包开发计划（含日志系统）

## 1. 文档目的

本文档用于指导 EEG Python 算法包的工程建设，覆盖：

- C++ 可调用的 Python 公共接口。
- 在线算法模块与离线算法模块。
- DTO、异常、模型资源及测试目录。
- 异步日志、日志轮转、性能统计与 C++ 告警轮询机制。

本阶段只建设 Python 算法包，不包含 C++ 采集、Qt 界面、pybind11 桥接代码和桌面安装包。

## 2. 总体方案

Python 算法包只向 C++ 公开以下模块：

- `eeg_algorithm.api`
- `eeg_algorithm.types`
- `eeg_algorithm.errors`

其余在线状态、离线流水线、滤波、ASR、频谱、地形图和日志实现统一放入 `eeg_algorithm.internal`，C++ 不得直接导入内部模块。

日志系统采用以下方式：

- Python 使用后台线程异步写入轮转 JSON Lines 日志文件。
- Python 保存 `WARNING` 及以上级别的告警事件队列。
- C++ 每隔 `200～500 ms` 主动拉取告警事件并转发到桌面界面。
- Python 不从日志线程直接回调 C++，避免 GIL、线程生命周期和界面重入问题。
- 实时算法线程只负责非阻塞地投递日志，不得同步写盘或调用 `flush()`。

## 3. 推荐项目目录

```text
EEG项目/
├─ EEG在线与离线算法模块接口文档.md
├─ EEG_Python算法包开发计划.md
│
└─ algorithm/
   ├─ pyproject.toml
   ├─ README.md
   │
   ├─ src/
   │  └─ eeg_algorithm/
   │     ├─ __init__.py
   │     ├─ api.py
   │     ├─ version.py
   │     ├─ errors.py
   │     │
   │     ├─ types/
   │     │  ├─ __init__.py
   │     │  ├─ enums.py
   │     │  ├─ common.py
   │     │  ├─ online.py
   │     │  ├─ offline.py
   │     │  └─ observability.py
   │     │
   │     ├─ internal/
   │     │  ├─ __init__.py
   │     │  ├─ facade.py
   │     │  ├─ session_ids.py
   │     │  ├─ validation.py
   │     │  │
   │     │  ├─ online/
   │     │  │  ├─ __init__.py
   │     │  │  ├─ registry.py
   │     │  │  ├─ session.py
   │     │  │  ├─ filter_chain.py
   │     │  │  ├─ rereference.py
   │     │  │  ├─ asr.py
   │     │  │  ├─ phase_decoder.py
   │     │  │  ├─ rolling_buffer.py
   │     │  │  ├─ topography.py
   │     │  │  └─ spectrum.py
   │     │  │
   │     │  ├─ offline/
   │     │  │  ├─ __init__.py
   │     │  │  ├─ registry.py
   │     │  │  ├─ session.py
   │     │  │  ├─ pipeline.py
   │     │  │  ├─ filtering.py
   │     │  │  ├─ rereference.py
   │     │  │  ├─ asr.py
   │     │  │  ├─ artifact.py
   │     │  │  ├─ resample.py
   │     │  │  ├─ quality.py
   │     │  │  ├─ selection.py
   │     │  │  ├─ topography.py
   │     │  │  ├─ spectrum.py
   │     │  │  └─ statistics.py
   │     │  │
   │     │  ├─ common/
   │     │  │  ├─ __init__.py
   │     │  │  ├─ filter_design.py
   │     │  │  ├─ spectrum_core.py
   │     │  │  ├─ topography_core.py
   │     │  │  └─ array_utils.py
   │     │  │
   │     │  └─ observability/
   │     │     ├─ __init__.py
   │     │     ├─ manager.py
   │     │     ├─ handlers.py
   │     │     ├─ formatter.py
   │     │     ├─ context.py
   │     │     └─ performance.py
   │     │
   │     └─ resources/
   │        └─ electrode_layouts/
   │
   ├─ models/
   │  ├─ README.md
   │  └─ manifest.json
   │
   ├─ tests/
   │  ├─ unit/
   │  │  ├─ types/
   │  │  ├─ online/
   │  │  ├─ offline/
   │  │  └─ observability/
   │  ├─ contract/
   │  ├─ integration/
   │  ├─ performance/
   │  └─ fixtures/
   │
   ├─ examples/
   │  ├─ online_processing_demo.py
   │  ├─ offline_processing_demo.py
   │  └─ logging_demo.py
   │
   └─ benchmarks/
      ├─ benchmark_push_sample.py
      ├─ benchmark_push_block.py
      └─ benchmark_offline_pipeline.py
```

## 4. 公共接口模块

### 4.1 `api.py`

职责：

- 提供 `get_api_version()` 和 `create_api()`。
- 对外提供 `EegAlgorithmApi`。
- 作为 C++ 调用算法功能的唯一业务入口。
- 将具体实现委托给 `internal.facade`，保证公共模块简洁稳定。

### 4.2 `version.py`

- 保存接口版本，如 `API_VERSION = "1.3"`。
- Python 包版本与跨语言接口版本分别管理。

### 4.3 `errors.py`

- 定义 `AlgorithmErrorInfo` 和 `AlgorithmError`。
- 统一管理接口文档中约定的错误码。
- 日志不能替代错误码或异常返回。

### 4.4 `types/`

- `enums.py`：重参考方式、频段、质量标记、会话状态等枚举。
- `common.py`：`ElectrodePosition`、`ChannelLayout`、`SampleFrame`、`SignalBlock`、时间范围和数据缺口。
- `online.py`：在线配置、查询、结果和状态 DTO。
- `offline.py`：离线预处理配置、查询、数据集、结果和状态 DTO。
- `observability.py`：日志配置、日志事件和日志状态 DTO。

所有跨语言 DTO 使用不可变 `dataclass`。DTO 只负责数据表达和基础约束，不包含具体算法流程。

## 5. 在线算法模块

- `registry.py`：管理在线会话 ID 和生命周期。
- `session.py`：校验输入、编排在线流水线、检查序列连续性并保证状态原子提交。
- `filter_chain.py`：因果 SOS 高通、低通和陷波，保存跨调用滤波状态。
- `rereference.py`：OFF、双侧乳突及全脑平均重参考。
- `asr.py`：保存参考数据、参考矩阵及在线业务窗口状态。
- `phase_decoder.py`：加载 PyTorch 模型并保存历史窗口或隐藏状态。
- `rolling_buffer.py`：保存预处理后的多通道数据，是实时地形图和实时频谱的唯一数据来源。
- `topography.py`：接收多通道缓存快照并计算实时地形图。
- `spectrum.py`：接收单导联缓存快照并计算实时 Welch PSD。

## 6. 离线算法模块

- `registry.py`：管理离线会话。
- `session.py`：保存不可变原始数据和当前有效预处理版本。
- `pipeline.py`：按照固定顺序执行已启用的预处理步骤，并原子替换成功结果。
- `filtering.py`：高通/低通组合、陷波和零相位滤波。
- `rereference.py`：离线重参考。
- `asr.py`：离线 ASR 去伪迹。
- `artifact.py`：离线伪迹检测（跳变伪迹 + 高频能量伪迹），只检测不修改信号。
- `resample.py`：离线降采样并同步更新时间信息。
- `quality.py`：离线质检与修复（空值与弱信号、幅度范围外值、低相关性导联，每个小项独立开关 + 线性插值修复）。
- `selection.py`：按照绝对时间范围从当前预处理数据中选段。
- `spectrum.py`：对选定的单导联数据计算频谱。
- `topography.py`：对选定的多通道数据一次计算全频段与 δ/θ/α/β/γ 共 6 张脑电地形图。
- `statistics.py`：对选定的多通道数据逐通道计算统计指标（均值、标准差、RMS、峰峰值、最大值、最小值、零交叉率、偏度、峰度、优势频带），并计算通道相关性矩阵与 δ/θ/α/β/γ 频带能量。

离线后处理不得绕过当前 `PreprocessedDataset` 直接读取原始数据。

## 7. 类与函数的划分

具有状态、生命周期或缓存的组件使用类：

- `EegAlgorithmApi`
- `OnlineSession`、`OfflineSession`
- 在线和离线 Session Registry
- `OnlineFilterChain`
- `OnlineAsrProcessor`
- `PhaseDecoder`
- `RollingSignalBuffer`

无历史状态的算法优先使用函数：

- 离线滤波、降采样和质检与修复。
- 离线选段。
- Welch PSD 计算。
- 地形图频段代表值和空间插值。
- 无状态重参考。

地形图不必仅为了算法名称定义 `TopographyAnalyzer` 类。首版使用计算函数；只有需要缓存电极插值矩阵时，才增加私有 `TopographyKernel` 类。频谱模块同理。

## 8. 模块依赖规则

```text
eeg_algorithm.api
    ↓
internal.facade
    ↓
在线/离线 Registry
    ↓
OnlineSession / OfflineSession
    ↓
具体算法模块
    ↓
internal.common

types 和 errors 不依赖任何算法模块
```

- C++ 不得导入 `eeg_algorithm.internal`。
- 在线与离线模块不能直接互相调用。
- 在线与离线可以复用 `internal.common` 的纯计算函数。
- Python 算法包不负责设备采集、界面刷新、文件持久化和 C++ 线程调度。

## 9. 日志公共 DTO 与接口

在 `types/observability.py` 中定义：

```python
class LogLevel(Enum):
    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    CRITICAL = "CRITICAL"


@dataclass(frozen=True)
class LoggingConfig:
    enabled: bool = True
    directory: str = ""
    min_level: LogLevel = LogLevel.INFO
    rotate_max_bytes: int = 20 * 1024 * 1024
    rotate_backup_count: int = 10
    ui_event_min_level: LogLevel = LogLevel.WARNING
    event_queue_capacity: int = 1000
    performance_interval_s: float = 5.0


@dataclass(frozen=True)
class LogEvent:
    timestamp_utc_ns: int
    level: LogLevel
    code: str
    message: str
    operation: str | None = None
    session_id: int | None = None
    request_id: int | None = None
    sequence_id: int | None = None
    duration_ms: float | None = None


@dataclass(frozen=True)
class LoggingStatus:
    enabled: bool
    active_log_file: str | None
    dropped_file_records: int
    dropped_ui_events: int
    last_logging_error: str | None
```

公共接口增加：

```python
def configure_logging(config: LoggingConfig) -> None:
    ...


class EegAlgorithmApi:
    def drain_log_events(
        self,
        max_items: int = 100,
    ) -> tuple[LogEvent, ...]:
        ...

    def get_logging_status(self) -> LoggingStatus:
        ...
```

调用顺序：

```text
C++ 初始化 CPython
    → configure_logging()
    → create_api()
    → 创建在线/离线会话
    → C++ 每 200～500 ms 调用 drain_log_events()
    → 将 WARNING/ERROR 转发到 Qt 主线程
    → api.close() 刷新剩余日志并关闭日志线程
```

`configure_logging()` 应当在 `create_api()` 前调用。没有配置日志时，模块只安装 `NullHandler`，不得自行创建目录或文件。

## 10. 算法过程中的日志写在哪里

算法代码只负责产生日志记录，不直接打开或写入日志文件。

```text
在线/离线算法模块
    → logger.info()/warning()/error()
    → internal/observability/handlers.py
    → 有界非阻塞日志队列
    → 后台 QueueListener
    → RotatingFileHandler
    → LoggingConfig.directory/*.jsonl
```

### 10.1 日志调用位置

- `internal/facade.py`
  - 公共接口调用失败和未分类异常。
  - 在接口边界统一记录一次异常，避免重复日志。
- `internal/online/session.py`
  - 在线会话创建、配置变化、数据缺口、状态重置和关闭。
- `internal/online/asr.py`
  - ASR 参考拟合、重新拟合、参考缺失和处理异常。
- `internal/online/phase_decoder.py`
  - 模型加载、推理设备、推理失败和关闭。
- `internal/offline/session.py`
  - 离线会话创建、预处理版本更新、过期查询和关闭。
- `internal/offline/pipeline.py`
  - 预处理开始、各步骤耗时、完成和失败。
- `internal/observability/performance.py`
  - 聚合并周期性输出在线、离线性能统计。

底层数值函数遇到问题应抛出约定异常，由 `OnlineSession`、`OfflineSession` 或 `facade` 边界补齐上下文后统一记录，避免一个异常被多个层级重复写入。

### 10.2 日志最终保存位置

日志目录由 C++ 通过 `LoggingConfig.directory` 传入，Python 不硬编码用户目录。

正式产品建议使用：

```text
C:\Users\<用户名>\AppData\Local\<产品名>\logs\
└─ eeg_algorithm-20260924-12345.jsonl
```

开发阶段可以使用：

```text
E:\AgentProgram\EEG项目\.run\logs\
```

`.run/` 应加入 `.gitignore`，避免运行日志进入版本库。

## 11. 日志内部模块职责

### 11.1 `manager.py`

- 初始化、重新配置和关闭日志系统。
- 管理文件日志队列和界面告警队列。
- 提供 `drain_log_events()` 和日志状态查询。

### 11.2 `handlers.py`

- 基于 `QueueHandler` 和 `QueueListener` 异步写盘。
- 使用有界队列和非阻塞入队。
- 队列满时丢弃当前日志并累计计数，不阻塞实时算法。
- 文件处理器自身异常不得传播到算法处理路径。

### 11.3 `formatter.py`

- 每行输出一条 JSON 记录。
- 统一时间、日志级别、事件码、操作名称和会话上下文。

### 11.4 `context.py`

- 为日志添加 `session_id`、`request_id`、`sequence_id`、配置版本和预处理版本。
- 使用显式上下文或 `LoggerAdapter`，不使用无约束的业务全局变量。

### 11.5 `performance.py`

- 聚合调用次数、平均耗时、P99 和最大耗时。
- 按配置周期写入性能汇总，不在每个采样点写一条 `INFO` 日志。

## 12. 日志事件范围

### 12.1 生命周期事件

- Python 算法模块初始化和关闭。
- 在线、离线会话创建与关闭。
- 模型加载成功、设备类型和模型版本。
- ASR 参考数据设置或重新拟合。
- 在线配置更新及生效序列号。
- 离线预处理开始、结束和版本更新。

### 12.2 异常与质量事件

- 数据缺口、乱序和重复序列号。
- 滚动窗口数据不足。
- ASR 参考缺失或失效。
- 预处理失败和旧数据版本查询。
- 模型加载及推理失败。
- 日志队列溢出。
- 算法处理超时。

### 12.3 性能事件

- `push_sample()`、`push_block()` 的聚合耗时。
- 地形图和频谱计算耗时。
- 离线各预处理步骤耗时。
- 会话累计处理点数及错误次数。

## 13. 日志格式

日志使用 JSON Lines，每行一条独立 JSON：

```json
{
  "timestamp": "2026-09-24T10:15:31.125Z",
  "level": "WARNING",
  "logger": "eeg_algorithm.internal.online.session",
  "code": "TIME_SEQUENCE_DISCONTINUITY",
  "message": "检测到在线数据缺口，流式状态已重置",
  "operation": "push_block",
  "session_id": 12,
  "sequence_id": 10528,
  "config_version": 3,
  "thread": "AlgorithmWorker"
}
```

日志文件命名：

```text
eeg_algorithm-日期-进程ID.jsonl
eeg_algorithm-日期-进程ID.jsonl.1
eeg_algorithm-日期-进程ID.jsonl.2
```

默认单文件上限为 `20 MB`，保留 `10` 个历史文件。

## 14. 实时性与安全约束

- 禁止在 `push_sample()` 中同步写文件或调用 `flush()`。
- 默认不为每个采样点记录 `DEBUG` 日志。
- 高频性能数据先在内存聚合，再每 `5 s` 输出一次汇总。
- 日志失败不得改变滤波、ASR、模型、滚动缓存或会话状态。
- `AlgorithmError` 是接口错误的正式表达，日志不能替代异常和错误码。
- 不记录原始 EEG 数组、受试者信息、模型权重或完整 ASR 参考数据。
- 数据信息只记录形状、dtype、采样率、通道数和时间范围。
- 日志告警队列溢出时允许丢弃，但必须累计 `dropped_ui_events`。
- 文件日志队列溢出时允许丢弃，但必须累计 `dropped_file_records`。

## 15. 开发顺序

1. 创建 `algorithm/` 工程骨架及 `pyproject.toml`。
2. 实现公共枚举、DTO、错误类型和 API 版本。
3. 实现异步日志管理器、轮转文件、JSON 格式化和告警轮询。
4. 实现在线 Session、滤波链、滚动缓存及查询数据流。
5. 实现 ASR 与相位模型接口，并接入在线 Session。
6. 实现离线 Session、预处理流水线、选段和后处理。
7. 补充公共接口契约测试、集成测试和性能基准。
8. 使用 C++/pybind11 调用方执行跨语言联调。

## 16. 测试与验收

### 16.1 公共接口与算法

- 公共接口名称、签名和 DTO 字段与接口文档一致。
- `push_block(N)` 与连续调用 `N` 次 `push_sample()` 的结果在数值容差内等价。
- 在线滤波、ASR、相位和滚动缓存状态能够跨调用保存。
- 配置更新、数据缺口和 `reset` 正确重置受影响状态。
- 地形图只读取多通道滚动缓存，频谱只读取指定导联缓存。
- 离线预处理开关、执行顺序、选段和版本号正确。
- 离线预处理失败时保留上一份有效结果。
- 非法形状、通道、频率、时间范围和 NaN/Inf 返回约定错误。

### 16.2 日志系统

- 未调用 `configure_logging()` 时不创建目录或文件。
- 算法工作线程不执行同步文件写入。
- 文件达到上限后能够正确轮转。
- 日志队列满时不阻塞在线算法，并正确累计丢弃数。
- C++ 轮询得到的告警事件只返回一次且保持顺序。
- 只有达到 `ui_event_min_level` 的事件进入界面告警队列。
- `session_id`、`sequence_id`、请求 ID 和操作名称关联正确。
- 日志处理器异常不污染算法状态。
- `api.close()` 刷新剩余日志并停止后台监听线程。
- 日志内容不包含原始 EEG 数据和受试者敏感信息。

## 17. 假设与默认值

- Python 负责异步落盘，C++ 通过轮询接收告警事件。
- C++ 负责把告警事件转发到 Qt 主线程，Python 不直接操作界面。
- 日志使用 Python 标准库 `logging`，首版不引入第三方日志框架。
- 正式环境默认日志级别为 `INFO`，开发环境可以启用 `DEBUG`。
- Python 运行依赖由 `pyproject.toml` 统一声明。
- 模型路径通过 `PhaseModelConfig` 传入，大型模型文件不直接放入 Python 源码包。
- 测试数据使用合成或匿名 EEG 数据，不提交真实受试者数据。
- `QtPythonImageDemo` 保持为独立原型，不作为正式算法包依赖。
