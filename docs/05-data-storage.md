# 05 · 数据、存储与配置

## 1. 数据落点总览

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| SQLite 数据库 | 开发期：`KSCEEGClient/eeg-ksc.db`；打包后：exe 同级 `eeg-ksc.db` | 账号、偏好、患者、标签、采集记录、事件 |
| 采集波形 | 由「记录保存目录」决定，默认在系统记录目录下 | `.eegbin` 私有二进制 |
| 运行期配置 | **exe 同级优先**，其次源码目录 `client-config.json` | 无人值守阈值、串口 CRC 开关 |
| Python 日志 | exe 同级 `logs/` 下的 `eeg_algorithm-YYYYMMDD-pid.jsonl` | JSON Lines，轮转 |
| 审计日志 | `%LOCALAPPDATA%\EEG-KSC\logs\audit.log` | UTF-8 纯文本，每行一条 |
| 授权 | exe 同级 `license.lic` + `public_key.pem` | RSA 验签 + MAC 绑定 |
| 本地应用数据 | `QStandardPaths::AppLocalDataLocation`（应用名 `EEG-KSC`） | Qt 运行期数据 |

数据库路径的优先序与配置文件**相反**：

- 数据库：源码目录 → exe 同级（开发期使用源码目录里的库，打包后使用 exe 同级）；
- `client-config.json`：exe 同级 → 源码目录（现场调阈值不应回源码目录改）。

## 2. SQLite 数据库

由 `storage/appdatabase.cpp` 管理。`createTables()` 建表，`ensure_column()` 对旧库做兼容性补列（例如 `recording_sessions` 的 6 个新增列、`users` 的 3 个新增列、`patients.created_by`）。

### 2.1 表结构

| 表 | 字段 | 说明 |
| --- | --- | --- |
| `users` | `id`、`username`（UNIQUE）、`password`、`display_name`、`role`、`created_at` | 账号表；口令当前为明文存储（已知问题，未迁移） |
| `app_settings` | `setting_key`（PK）、`setting_value` | 键值型偏好：医院/科室、记录目录、脱敏开关等 |
| `patients` | `patient_no`（PK）、`name`、`gender`、`age`、`department`、`diagnosis`、`note`、`created_by`、`created_at` | 患者信息 |
| `recording_sessions` | `id`、`patient_no`、`started_at`、`duration_s`、`channel_count`、`sample_rate`、`event_count`、`electrode_quality`、`file_path` | 采集记录；含索引 `idx_sessions_patient` |
| `tags` | `id`、`name`、`code`、`color`、`created_at` | 事件标签 |
| `session_events` | `id`、`session_id`、`offset_s`、`wall_clock`、`label`、`color` | 记录内事件；含索引 `idx_session_events` |

### 2.2 内置管理员

超级管理员 `admin` 写死在代码中（`kBuiltinAdminUser`），**不写入 `users` 表**，因此不会出现在用户列表里。首次登录使用它，其余账号在「用户管理」页开通。

### 2.3 权限与归属

- 患者与记录按 `created_by` 做归属校验；管理员放行。
- `updatePatient()`、`removePatient()`、`session()`、`removeSession()`、`exportSession()` 均调用 `patientBelongsToCurrentUser()` / `sessionBelongsToCurrentUser()` 拦截越权。
- 删除患者时，先查出其名下所有 `file_path`，删库后逐个 `QFile::remove()`；删除失败只记日志（与删除单条记录同口径）。

### 2.4 记录生命周期

1. 开始采集：`recordCollection(patient_no, channel_count, ...)` 插入 `recording_sessions`，返回记录号。
2. 采集过程中：事件写入 `session_events`（相对偏移 + 墙钟时间）。
3. 停止采集：`finishCollection(patient_no, duration_seconds, ...)` 回填时长、事件数、电极质量、文件路径。

## 3. `.eegbin` 波形格式

定义见 `common/eegbinformat.h`：

| 项 | 值 |
| --- | --- |
| 魔数 | `EEGBIN01` |
| 版本 | `1` |
| 头长度 | 64 字节 |
| 样本类型 | `float32`（4 字节/样本） |
| 排列 | **帧优先交错**：`samples[frame * channels + channel]` |
| 单位 | µV |

头部保存通道数、采样率、起始时间、帧数等元数据。读取时（`RecordingPreview`）会校验魔数、版本、头长度，并**以文件实际长度计算帧数**，不信任头部 `frame_count`——记录异常中断时头部计数可能不可靠。

写入端支持：

- `SaveFormat::Binary`：`.eegbin`；
- `SaveFormat::Csv`：文本导出；
- `SaveFormat::None`：不落盘。

落盘采样率可通过 `recordSampleRate` 单独设置，`0` 表示与设备一致（不重采样）。

## 4. `client-config.json`

```json
{
  "_comment": "...unattended_auto_exit_minutes ... serial_crc_enabled ...",
  "unattended_auto_exit_minutes": 60,
  "serial_crc_enabled": false
}
```

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `unattended_auto_exit_minutes` | 60 | 连续无鼠标/键盘操作多少分钟后自动退出；`0` 关闭；改动需重启 |
| `serial_crc_enabled` | false | 串口帧是否校验 CRC-16/MODBUS |

解析失败或文件不存在时使用默认值并打印警告。配置只在启动时读取。

## 5. 日志

### 5.1 审计日志

实现：`common/auditlog.*`。

- 路径：`%LOCALAPPDATA%\EEG-KSC\logs\audit.log`。
- 格式：`用户ID | 日期 | 时间 | 事件`，首行表头；事件放末列，便于前 3 列稳定解析。
- 「用户ID」使用登录账号 `username`（登录失败时可能拿不到 `U-0001` 形式的 uid，但失败尝试同样需要留痕）。
- `QMutex` 保护，可任意线程调用。

覆盖事件：

1. 用户登录/退出、登录失败、账号创建/修改/重置密码/启停用；
2. 账号管理操作；
3. 核心功能：开始/停止采集、打开记录后处理、各类数据与报告导出。

### 5.2 Python 日志

实现：`internal/observability/`。

- 文件名：`eeg_algorithm-YYYYMMDD-pid.jsonl`，目录为 exe 同级 `logs/`。
- JSON Lines，按日期轮转。
- 算法线程只向有界队列投递；后台 `QueueListener` 写盘。
- C++ 通过 `drain_log_events()` 拉取 UI 告警，通过 `get_logging_status()` 查看积压与丢弃。

### 5.3 Qt 日志

`PythonWorker` 等位置同时把算法日志输出到 Qt 的 `qInfo/qWarning`；`KSCEEG_CONSOLE=ON` 构建下可直接在控制台观察。

## 6. 授权文件

- 文件：exe 同级 `license.lic`、`public_key.pem`。
- 解析：nlohmann/json；待验签串为 `license["data"].dump()`。
- 算法：SHA-256 摘要 + RSA PKCS#1 v1.5（OpenSSL `EVP_PKEY_verify`）。
- MAC 绑定：本机网卡 MAC 冒号替换为横线后比对。
- 有效期：`expire_date`，格式 `%Y-%m-%dT%H:%M:%S`。
- **fail-closed**：文件缺失、JSON 解析失败、签名不匹配、MAC 不匹配、过期均判为无效，并写审计日志。
- 界面：`License` 上下文属性 + `LicenseAlertDialog` 提示。

## 7. 导出物

| 导出 | 入口 | 内容 |
| --- | --- | --- |
| 原始记录 | `AppDatabase.exportSession()` | `.eegbin` 原始数据文件名 + 摘要 CSV |
| 分析数据 | `Analysis.export_data()` | 预处理后的多通道数据 |
| 统计 CSV | `Analysis.export_stats_csv()` | 各通道统计指标 |
| 文本报告 | `Analysis.export_report_txt()` | 记录信息、参数、统计摘要 |
| PDF 报告 | `RecordReport.exportPdf()` | A4、150 dpi，记录信息、事件、波形、统计、地形图 |

导出前按 `Privacy.enabled` 对患者姓名/病历号脱敏。界面脱敏只影响展示，**导出物在写文件那一刻单独脱敏**，因为文件离开程序后不再受开关约束。

## 8. 隐私与脱敏

`Privacy.qml` 是全局单例：

- 开关存入 `app_settings.data_mask`，由 `Main.syncPrivacy()` 同步。
- 展示层统一调用 `Privacy.masked(text)`。
- 不修改数据源：`patients()` 返回的 `no` / `name` 仍被界面用作过滤键、动作参数和编辑初值，数据层打码会把 `***` 写回数据库。

## 9. 已知数据层问题

来自根 README 的审查记录：

| 问题 | 状态 |
| --- | --- |
| 口令明文存储 | 未修复（涉及既有账号数据迁移） |
| `removePatient` 只删库行不删 `.eegbin` | 已修复：删库后逐个删除文件 |
| 单条记录读/改/删/导出缺少归属校验 | 已修复：统一按 `created_by` 校验 |
| `RawRingBuffer` 在锁外读取 `m_channels` | 暂不处理（已有兜底） |
| `copy_*` 返回值未检查 | 暂不处理（已有兜底） |
