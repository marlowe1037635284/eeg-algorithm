# 04 · Python 算法包 `eeg_algorithm`

源码位于 `PythonScript/src/eeg_algorithm/`，采用 `src` 布局，包名 `eeg-algorithm`，要求 Python ≥ 3.11。公共入口只有三个：

```python
from eeg_algorithm import api
from eeg_algorithm import types
from eeg_algorithm import errors
```

`internal/` 下的实现不承诺稳定，宿主不应直接导入。

## 1. 包结构

```
eeg_algorithm/
├── __init__.py
├── version.py                 # API_VERSION = "1.3"，__version__ = "0.1.0"
├── api.py                     # EegAlgorithmApi 门面 + create_api()
├── errors.py                  # 错误码、AlgorithmErrorInfo、AlgorithmError
├── types/
│   ├── common.py              # ChannelLayout / SignalBlock / SampleFrame / GapInfo ...
│   ├── enums.py               # ReferenceMethod / BandPreset / QualityFlag / SessionState ...
│   ├── online.py              # 在线配置与查询/结果类型
│   ├── offline.py             # 离线配置、查询、报告、数据集类型
│   └── observability.py       # LogEvent / LoggingStatus
└── internal/
    ├── common/                # filter_design、spectrum_core、topography_core、array_utils
    ├── online/                # session、filter_chain、rereference、asr、phase_decoder、
    │                          # rolling_buffer、spectrum、topography、registry
    ├── offline/               # session、pipeline、filtering、rereference、asr、artifact、
    │                          # resample、quality、selection、spectrum、topography、
    │                          # statistics、registry
    ├── observability/         # manager、handlers、formatter、context、performance
    ├── validation.py          # 频带/参数校验
    └── session_ids.py         # 会话 ID 分配
```

## 2. 公共 API

`api.py` 提供单例门面 `EegAlgorithmApi`，通过 `create_api()` 获取。

### 2.1 在线会话

| 方法 | 说明 |
| --- | --- |
| `create_online_session(config: OnlineConfig) -> int` | 创建会话，返回 `session_id` |
| `set_asr_reference(session_id, reference: SignalBlock)` | 设置 ASR 参考数据（要求 60–180 秒） |
| `update_processing_config(session_id, config) -> ConfigUpdateResult` | 更新处理参数，版本必须严格递增 |
| `push_sample(session_id, frame: SampleFrame) -> OnlineResult` | 单样本处理（调试/低吞吐） |
| `push_block(session_id, block: SignalBlock) -> OnlineResult` | 数据块处理（主路径） |
| `notify_gap(session_id, gap: GapInfo)` | 通知数据缺口，重置流状态并进入预热 |
| `query_online_topography(session_id, query) -> TopographyResult` | 查询地形图 |
| `query_online_spectrum(session_id, query) -> SpectrumResult` | 查询频谱 |
| `reset_online_session(session_id)` | 重置会话 |
| `get_online_status(session_id) -> SessionStatus` | 会话状态快照 |
| `close_online_session(session_id)` | 关闭会话 |

### 2.2 离线会话

| 方法 | 说明 |
| --- | --- |
| `create_offline_session(layout, raw_signal) -> int` | 用原始数据创建离线会话 |
| `run_preprocessing(session_id, config: PreprocessConfig) -> PreprocessResult` | 执行完整预处理 |
| `query_offline_spectrum(session_id, query)` | 频谱查询 |
| `query_offline_topography(session_id, query)` | 地形图查询 |
| `query_offline_statistics(session_id, query)` | 统计查询 |
| `query_offline_quality(session_id, query)` | 质检报告（带缓存） |
| `get_preprocessed_data(session_id) -> PreprocessedDataset` | 取预处理后数据 |
| `get_offline_status(session_id) -> OfflineSessionStatus` | 会话状态 |
| `close_offline_session(session_id)` | 关闭会话 |

离线查询必须携带与当前预处理结果一致的 `preprocess_version`，否则抛出 `STALE_DATA_VERSION`。

### 2.3 全局

| 方法 | 说明 |
| --- | --- |
| `drain_log_events(max_items=100) -> tuple[LogEvent, ...]` | 拉取 UI 告警日志 |
| `get_logging_status() -> LoggingStatus` | 日志队列状态 |
| `close()` | 关闭全部门面与日志 |

`configure_logging()` 必须在 `create_api()` 之前调用；`_ensure_open()` 在门面关闭后抛 `INVALID_STATE`。

## 3. 错误模型 `errors.py`

错误码常量：

```
INVALID_ARGUMENT            SHAPE_MISMATCH
CHANNEL_LAYOUT_MISMATCH     INVALID_SAMPLE_RATE
TIME_SEQUENCE_DISCONTINUITY FREQUENCY_OUT_OF_RANGE
INSUFFICIENT_WINDOW_DATA    TIME_RANGE_OUT_OF_RANGE
PREPROCESSED_DATA_NOT_READY STALE_DATA_VERSION
NOT_INITIALIZED             SESSION_NOT_FOUND
INVALID_STATE               MODEL_LOAD_FAILED
ASR_REFERENCE_REQUIRED      PROCESSING_TIMEOUT
ALGORITHM_RUNTIME_ERROR     INTERNAL_ERROR
```

```python
AlgorithmErrorInfo(code, message, operation, session_id, sequence_id, details)
class AlgorithmError(RuntimeError):
    info: AlgorithmErrorInfo
def algorithm_error(code, message, operation, ...) -> AlgorithmError
```

C++ 侧通过 `eeg_bridge.describe_error()` 与 pybind11 异常转换读取这些字段，最终映射到 `AlgorithmErrorInfo`。

## 4. 数据类型

### 4.1 通用 `types/common.py`

| 类型 | 字段 |
| --- | --- |
| `ElectrodePosition` | `channel_name, x, y, z, coordinate_system` |
| `ChannelLayout` | `channel_names, sample_rate_hz, positions, unit="uV"` |
| `SampleFrame` | `sequence_id, timestamp_ns, values` |
| `SignalBlock` | `first_sequence_id, timestamps_ns, values`（`values` 形状 `[C, N]`） |
| `AbsoluteTimeRange` | `start_timestamp_ns, end_timestamp_ns` |
| `GapInfo` | `first_missing_sequence_id, last_missing_sequence_id, start/end_timestamp_ns, reason` |

### 4.2 在线 `types/online.py`

配置：

- `ToggleFilterConfig`（开关、阶数、截止频率）
- `OnlineProcessingConfig`（高通/低通/陷波/ASR/重参考）
- `ReferenceConfig`（方法、乳突通道）
- `AsrConfig`（cutoff 等）
- `PhaseModelConfig`（可选相位模型）
- `OnlineConfig`（布局、处理参数、缓存时长）

查询/结果：

- `FrequencyBand(low_hz, high_hz, name)`
- `TopographyQuery` / `TopographyResult`（网格、头掩码、电极值、峰值电极、峰值/平均 RMS）
- `SpectrumQuery` / `SpectrumResult`（频率、PSD、五频段峰值）
- `PhaseValue` / `PhaseResult`
- `OnlineResult`（处理后块、状态、耗时）
- `ConfigUpdateResult`
- `SessionStatus`（状态、配置版本、预热进度、错误信息）

### 4.3 离线 `types/offline.py`

配置：

- `HighPassConfig` / `LowPassConfig` / `NotchConfig`
- `OfflineReferenceConfig`
- `OfflineAsrConfig`
- `ArtifactDetectionConfig`（跳变比例、高频阈值/比例）
- `ResampleConfig`（目标采样率）
- `QualityControlConfig`（信号/范围/相关性开关与阈值、修复方式）
- `PreprocessConfig`（上述组合）

结果：

- `ArtifactSegment` / `ArtifactReport`（段列表 + 逐样本掩码）
- `QualityReport`（四类异常：`null_value`、`weak_signal`、`amplitude_outlier`、`low_correlation`）
- `PreprocessedDataset`（信号、布局、处理步骤）
- `PreprocessResult`（版本、数据集、质检、伪迹）
- `OfflineSpectrumQuery/Result`、`OfflineTopographyQuery/Result`、`OfflineStatisticsQuery/Result`、`OfflineQualityQuery`
- `OfflineSessionStatus`

## 5. 在线流水线

`internal/online/session.py` 的 `OnlineSession` 依次持有：

```
OnlineFilterChain → ReReferencer → OnlineAsrProcessor → PhaseDecoder → RollingSignalBuffer
```

**push_block 顺序**

1. 连续性校验：`first_sequence_id` 必须等于期望值，时间戳必须连续；否则 `TIME_SEQUENCE_DISCONTINUITY`。
2. 滤波器链（`sosfilt`，保留 `zi` 状态）。
3. 重参考（关闭 / 共平均 / 双侧乳突）。
4. ASR（参考未就绪时按 `asr=false` 处理）。
5. 相位解码（可选，torch 模型）。
6. 写入滚动缓存（固定容量、禁止混合配置版本）。

**配置更新**

- `config_version` 严格递增，否则 `INVALID_ARGUMENT`。
- 滤波参数变化时 ASR 需要重新拟合。
- 通道布局（采样率/通道数/顺序）不可在会话内改变。

**缺口处理**：`notify_gap()` 重置滤波器、重参考、ASR 与相位状态，会话进入 `WARMING_UP`，直到缓存重新填满。

**查询**

- `query_topography`：对查询窗口按频带做带通 + 零相位滤波，计算各电极 RMS，再做薄板样条 RBF 插值到网格，头外置 NaN。
- `query_spectrum`：对指定通道做 Welch PSD（默认 2 秒段、50% 重叠），截取频带并计算五个频段峰值。

## 6. 离线流水线

`internal/offline/pipeline.py` 的 `run_preprocessing_pipeline()` **固定顺序**：

```
高通/低通（带通）
  → 陷波
  → 重参考
  → ASR
  → 伪迹检测
  → 降采样
  → 质检 / 修复
```

返回 `(dataset, quality_report, artifact_report)`；若启用修复，处理步骤追加 `"repair"`。

各步骤：

| 模块 | 说明 |
| --- | --- |
| `filtering.py` | 高通/低通组合成带通；陷波为带阻；统一使用零相位 SOS 滤波 |
| `rereference.py` | 关闭 / 共平均 / 双侧乳突 |
| `asr.py` | 离线 ASR 幅值抑制 |
| `artifact.py` | 跳变伪迹与高频能量伪迹检测；只标注不修改信号 |
| `resample.py` | `resample_poly` 多相重采样，按目标采样率重建时间戳 |
| `quality.py` | 16/8/4 电极分级、固定邻居表、四类异常检测、线性插值修复 |
| `selection.py` | 按绝对时间范围选段；单通道选段 |
| `spectrum.py` | 离线频谱 |
| `topography.py` | 离线六频带地形图 |
| `statistics.py` | 均值、标准差、RMS、峰峰值、最值、过零率、偏度、峰度、相关系数矩阵、频带能量、优势频带 |
| `session.py` | 保存原始副本；预处理版本严格递增，失败回滚；查询校验版本 |

**版本语义**

- `preprocess()` 成功才推进 `preprocess_version`；
- 失败时保留上一版本数据；
- 所有查询必须匹配当前版本，否则 `STALE_DATA_VERSION`；
- `get_preprocessed_data()` 在未就绪时抛 `PREPROCESSED_DATA_NOT_READY`。

## 7. 公共算法组件

### 7.1 `internal/common/filter_design.py`

- `highpass_sos` / `lowpass_sos` / `bandpass_sos` / `bandstop_sos`：设计二阶节（SOS）。
- `zero_phase_filter`：`sosfiltfilt` 零相位滤波，离线路径使用。

### 7.2 `internal/common/spectrum_core.py`

- `welch_psd(values, sample_rate_hz)`：至少 4 个采样点；`nperseg = min(N, max(4, 2 秒))`，50% 重叠，`detrend="constant"`。
- `select_frequency_range()`：按频率区间裁剪。
- `band_peak_frequencies()`：δ(0.5–4)、θ(4–8)、α(8–13)、β(13–30)、γ(30–45) 的峰值频率，区间左闭右开。

### 7.3 `internal/common/topography_core.py`

- `band_rms_values()`：按频带滤波后逐通道 RMS。
- `summarize_electrode_values()`：峰值电极、最大 RMS、平均 RMS。
- `interpolate_topography()`：电极坐标中心化并归一化到单位圆，使用 **薄板样条 RBF** 全局插值；网格至少 8×8；头外置 NaN。
  > 早期使用 `griddata(cubic)` + `nearest` 补洞，会在电极凸包外产生分片常值与硬分界线；RBF 在整个平面光滑外推，消除该问题。

### 7.4 `internal/online/*`

| 模块 | 说明 |
| --- | --- |
| `filter_chain.py` | 在线 SOS 滤波，逐块保留 `zi`；v1 强制四阶 |
| `rereference.py` | 共平均/双侧乳突重参考 |
| `asr.py` | 在线 ASR 参考统计与幅值抑制（基线实现，保留替换边界） |
| `phase_decoder.py` | 可选相位模型（torch） |
| `rolling_buffer.py` | 固定容量滚动缓存，禁止混合配置版本，支持按窗口或绝对时间取快照 |
| `spectrum.py` / `topography.py` | 在线查询实现 |
| `registry.py` | 会话注册表 |

### 7.5 `internal/validation.py`

- `validate_frequency_band()`：检查频带上下界、采样率约束（如上限不超过 Nyquist）。

## 8. 日志与可观测性

`internal/observability/manager.py` 的 `LoggingManager` 为单例：

- `configure()`：创建 `RotatingFileHandler` + `JsonLineFormatter` + `NonBlockingQueueHandler` + `UiEventHandler` + `QueueListener`。
- 日志文件：`eeg_algorithm-YYYYMMDD-pid.jsonl`。
- 算法线程只向有界队列投递，后台监听线程负责写盘，避免阻塞热路径。
- `drain(max_items)`：C++ 拉取 UI 告警。
- `status()`：队列积压、丢弃计数等。
- `shutdown()`：停止监听并刷新。

`context.py` 提供 `get_logger(__name__)`；`performance.py` 提供耗时统计辅助。

## 9. 宿主适配层 `KSCEEGClient/python/eeg_bridge.py`

该文件是 C++ 与算法包之间唯一的适配层，只导入 `eeg_algorithm.api`、`types`、`errors`。

**常量**

- `SUPPORTED_API_MAJOR = 1`
- `PROCESSING_KEYS`
- `DEFAULT_PROCESSING`：高通 0.5 Hz / 4 阶，低通 45 Hz / 4 阶，陷波 48–52 Hz / 4 阶，ASR 关闭。

**版本与初始化**

- `api_version()`
- `ensure_api_compatible()`：主版本不匹配时报错。
- `open_api()` / `_get_api()`
- `processing_defaults()`

**参数解析与校验**

- `_parse_processing(config, config_version)`：把扁平字典转为 `OnlineProcessingConfig`。
- `_validate_processing()`：四阶固定、频率范围、通带非空、陷波区间合法。
- `_parse_reference_method()` / `_parse_band_preset()`
- `_parse_preprocess_config()`：离线扁平配置。

**在线接口**

`create_online_session`、`update_processing_config`、`set_asr_reference`、`push_block`、`notify_gap`、`query_topography`、`query_spectrum`、`online_status`、`reset_session`、`close_session`。

> `push_block` 是热路径：返回扁平 `dict`；`processed_values` 直接返回 numpy 数组本身，不拷贝。C++ 必须在当前作用域内完成 memcpy，不能保存引用。

**离线接口**

`create_offline_session`、`run_preprocessing`、`query_offline_*`、`get_preprocessed_data`、`offline_status`、`close_offline_session`。

**其他**

- `drain_log_events()`、`close_api()`、`describe_error()`。
- `set_fault_injection()`：仅供自检使用。

## 10. 测试、基准与示例

| 目录 | 内容 |
| --- | --- |
| `tests/contract/test_public_api.py` | 公共 API 契约（签名、类型、错误码） |
| `tests/integration/test_online_pipeline.py` | 在线链路集成 |
| `tests/integration/test_offline_pipeline.py` | 离线链路集成 |
| `tests/performance/test_online_latency.py` | 在线延迟约束 |
| `tests/unit/observability/test_logging.py` | 日志行为 |
| `benchmarks/benchmark_push_block.py` | 块处理吞吐 |
| `benchmarks/benchmark_push_sample.py` | 单样本吞吐 |
| `benchmarks/benchmark_offline_pipeline.py` | 离线流水线耗时 |
| `examples/*.py` / `examples/*.cpp` | Python 与 C++ 调用示例 |

运行：

```powershell
cd PythonScript
python -m pip install -e ".[dev]"
python -m pytest
```

## 11. 依赖

| 依赖 | 版本 | 用途 |
| --- | --- | --- |
| numpy | ≥1.26 | 数组运算 |
| scipy | ≥1.12 | 滤波、Welch、重采样、插值、统计 |
| mne | ≥1.6 | 电极/数据辅助（可选路径） |
| asrpy | ≥0.0.8 | ASR 参考实现 |
| torch | ≥2.2（可选 `phase`） | 相位模型 |
| pytest | dev | 测试 |

> README 明确说明：当前 ASR 为可运行的基线实现，保留 `OnlineAsrProcessor` / `asr_clean_offline` 替换边界；用于科研或医疗结论前需替换为经验证的正式实现并完成数据集验证。
