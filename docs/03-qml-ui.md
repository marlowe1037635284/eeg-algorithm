# 03 · QML 界面层

界面代码位于 `KSCEEGClient/qml/`，共约 50 个 `.qml` 文件，通过 CMake 的 QML 模块 `KSCEEGClient` 编译进资源。所有页面使用 **1920×1080 设计稿绝对坐标**，由 `DesignCanvas` 统一等比缩放。

## 1. 入口与路由

### 1.1 `Main.qml`

`ApplicationWindow`，固定 1920×1080、全屏显示，只负责三件事：**窗口、登录态、页面/弹窗路由**。

```
ApplicationWindow
├─ DesignCanvas
│   ├─ LoginPage                 loggedIn == false
│   └─ pageLoader                loggedIn == true，按 currentPage 切换
├─ dialogLoader                  当前弹窗（盖在页面之上）
└─ Toast                         轻提示
```

关键状态：

| 属性 | 作用 |
| --- | --- |
| `loggedIn` | 是否已登录 |
| `locked` | 无人值守超时后的锁屏样式（登录页只留输入框） |
| `currentUserName` / `currentUserRole` | 当前用户 |
| `currentPage` | `workbench` / `patient` / `history` / `user` / `settings` / `analysis` |
| `activeDialog` | 单值弹窗路由；同一时刻只显示一个弹窗 |
| `deviceDisconnectVisible` | 设备断线警示框，独立于 `activeDialog`，保证任何页面都能弹出 |
| `pending*` | 各类待确认操作的数据（患者、用户、标签、记录、事件） |
| `analysisRecordNo` | 进入分析页时回填的记录号 |

主要函数：

- `navigateTo(label)`：根据导航文案切换页面；离开分析页时自动回到历史记录。
- `openAnalysis(recordNo)` / `closeAnalysis()`：进入/退出「数据分析与后处理」。
- `openRecordPreview()` / `openRecordReport()`：打开回放/报告弹窗。
- `exportRecord()` / `exportRecordPdf()`：导出原始数据与 PDF（导出前按隐私开关脱敏）。
- `handleLogout()` / `handleIdleLockout()`：退出登录与空闲锁定。
- `showToast(message, kind)`：统一轻提示。
- `syncPrivacy()`：从 `app_settings.data_mask` 同步脱敏开关。

全局 `Connections`：

| 信号源 | 行为 |
| --- | --- |
| `Acq.collectingChanged` | 停止采集时调用 `AppDatabase.finishCollection()` 收尾记录 |
| `IdleGuard.idleTimedOut` | 锁定界面并回到登录页 |
| `Acq.deviceDisconnected` | 弹出设备断线警示框 |

页面之间不互相引用：子页面通过信号（`navRequested`、`logoutRequested`、`selectPatientRequested` 等）把意图交回 `Main`，由 `Main` 统一路由。

### 1.2 `DesignCanvas.qml`

- 以 `min(width / 1920, height / 1080)` 计算 `contentScale`。
- 内层 `Item` 使用设计稿尺寸并设置 `scale`，`transformOrigin: TopLeft`，居中裁剪。
- 页面直接按设计稿坐标书写，无需关心真实窗口尺寸。

### 1.3 `Design.qml`（单例）

设计变量集中定义，数值直接来自 Figma 规格：

- 画布 `1920×1080`，资源前缀 `qrc:/qt/qml/KSCEEGClient/assets/`。
- 主色 `primary #7092ab`、品牌橙 `brand #ff8d1a`、停止按钮 `stopButton #fea85d`、当前导联 `waveCurrent #d65a5d`。
- 面板底色/描边/分隔线均为半透明主色。
- 状态色：`good #23af6e`、`warning #fea85d`、`bad #d65a5d`、`poor #da8e20`、`offline #a3a3a3`。
- 提供 `impedanceColor(level)` 等辅助函数，把阻抗等级映射到四档颜色。

### 1.4 `Privacy.qml`（单例）

全局脱敏开关：

- `enabled` 由 `Main` 从 `app_settings.data_mask` 同步，系统设置页保存后立即生效。
- `masked(text)` 在开启且文本非空时返回 `***`。
- 只做**展示层与导出层**替换，不修改数据源，避免把 `***` 写回数据库。

## 2. 公共组件

| 文件 | 职责 |
| --- | --- |
| `components/AppShell.qml` | 除工作台外所有页面的外壳：左侧 92px 导航 + 顶栏 + 底部状态栏 + 内容卡片；内容槽原点 `(154,150)` |
| `components/AppNavRail.qml` | 全应用统一的图标导航条，信号 `navRequested(label)`；「用户管理」仅管理员可见 |
| `components/DialogFrame.qml` | 弹窗统一外框、标题、遮罩与关闭行为 |
| `components/Toast.qml` | 轻提示 |
| `components/UserMenu.qml` | 顶栏用户菜单（修改密码、退出登录） |
| `components/Pager.qml` | 分页器 |
| `components/Pager.qml` / `SearchField.qml` / `TableRowButton.qml` | 列表页通用控件 |
| `components/ChoiceField.qml` | 下拉/单选型参数控件 |
| `components/PanelDivider.qml` | 面板内分隔线 |
| `components/SoftBlob.qml` | 背景模糊装饰椭圆 |

`AppShell` 的属性：`pageTitle`、`currentNav`、`statusItems`、`userName`、`userRole`，默认插槽 `contentChildren`，信号 `navRequested`、`logoutRequested`、`changePasswordRequested`、`deviceInfoRequested`。

## 3. 页面

| 页面 | 职责 | 主要依赖 |
| --- | --- | --- |
| `pages/LoginPage.qml` | 登录/注册、记住密码、锁定态；登录后写入 `AppDatabase` 并进入工作台 | `AppDatabase`、`License`、`Privacy` |
| `pages/WorkbenchPage.qml` | 采集工作台：患者卡片、开始/停止采集、波形、电极阻抗、地形图、频谱、事件标注、设备状态 | `Acq`、五个 panel |
| `pages/HistoryPage.qml` | 历史记录列表、按患者筛选、回放/分析/导出/删除 | `AppDatabase`、`Recording` |
| `pages/PatientManagementPage.qml` | 患者增删改查、记录数量、按角色控制可见性 | `AppDatabase` |
| `pages/UserManagementPage.qml` | 用户开通、编辑、重置密码、启停用（仅管理员） | `AppDatabase`、审计日志 |
| `pages/SystemSettingsPage.qml` | 医院/科室信息、记录保存目录、脱敏开关、事件标签维护 | `AppDatabase`、`Privacy` |
| `pages/AnalysisPage.qml` | 「数据分析与后处理」整页：左侧参数面板 + 右侧六个标签页 | `Analysis`（`PostProcess`） |

### 3.1 工作台布局

`WorkbenchPage` 由五个独立面板组成，面板内部使用「相对面板左上角」的坐标：

| 面板 | 职责 |
| --- | --- |
| `panels/WaveformPanel.qml` | 16 导联实时波形、时间窗口、量程、灰度、通道显隐、当前导联高亮 |
| `panels/ElectrodePanel.qml` | 电极阻抗/接触质量四档配色、扫描按钮与图例 |
| `panels/TopographyPanel.qml` | 频带选择、地形图贴图、峰值电极与平均 RMS |
| `panels/SpectrumPanel.qml` | 当前导联 Welch 频谱、五个频段峰值 |
| `panels/EventPanel.qml` | 事件标注（手动标记/标签）、列表、删除与清空 |

### 3.2 分析页

`AnalysisPage` 自己不持有分析状态，参数与结果都在 C++ 的 `Analysis`（`PostProcess`）中。页面只做三件事：把记录喂进去、按当前标签摆放内容、把导出请求转出去。

| 文件 | 标签页 |
| --- | --- |
| `analysis/AnalysisControls.qml` | 左侧参数面板：滤波、重参考、降采样、基线、ASR、伪迹检测、质检、导出 |
| `analysis/WaveTab.qml` | 处理后的多导波形、事件对齐、通道选择 |
| `analysis/SpectrumTab.qml` | 频谱曲线与频带能量 |
| `analysis/ChannelTab.qml` | 16 通道统计表（只读） |
| `analysis/StatsTab.qml` | 统计指标、频带分布、相关性 |
| `analysis/TopographyTab.qml` | 六个频带地形图 |
| `analysis/ReportTab.qml` | 报告预览与 PDF 导出 |

## 4. 弹窗

| 弹窗 | 用途 |
| --- | --- |
| `dialogs/PrecheckDialog.qml` | 开始采集前的检查确认 |
| `dialogs/SelectPatientDialog.qml` | 选择/登记患者 |
| `dialogs/NewPatientDialog.qml` / `EditPatientDialog.qml` | 新建/编辑患者 |
| `dialogs/FilterDialog.qml` | 工作台滤波与后处理参数 |
| `dialogs/DeviceInfoDialog.qml` | 设备连接信息与端口选择 |
| `dialogs/DeviceDisconnectDialog.qml` | 采集中断线警示 |
| `dialogs/ElectrodeDetachDialog.qml` | 阻抗扫描后电极脱落提示 |
| `dialogs/RecordPreviewDialog.qml` | `.eegbin` 记录回放 |
| `dialogs/ReportDialog.qml` | 报告预览/导出 |
| `dialogs/UserDialog.qml` | 新建/编辑用户 |
| `dialogs/ResetPasswordDialog.qml` / `ChangePasswordDialog.qml` | 重置/修改密码 |
| `dialogs/NewTagDialog.qml` | 新建事件标签 |
| `dialogs/LicenseAlertDialog.qml` | 授权无效/过期提示 |
| `dialogs/ConfirmDialog.qml` | 通用二次确认（退出、删除记录、清空事件等） |

弹窗统一由 `Main.activeDialog` 单值路由；断线警示框例外，使用独立的 `deviceDisconnectVisible`。

## 5. 与 C++ 的绑定

| QML 标识 | C++ 类型 | 说明 |
| --- | --- | --- |
| `Acq` | `AcquisitionBridge` | 串口、采集、波形、滤波、地形图、频谱、事件、电极质量 |
| `Recording` | `RecordingPreview` | `.eegbin` 回放 |
| `Analysis` | `PostProcess` | 离线后处理全部参数与结果 |
| `License` | `LicenseManager` | 授权状态 |
| `IdleGuard` | `UnattendedGuard` | 空闲超时信号 |
| `AppDebugBuild` | 编译期布尔 | 是否为调试构建 |
| `AppDatabase` | `AppDatabase` | 在 `Main.qml` 中实例化，注入各页面 |
| `RecordReport` | `RecordReport` | 在 `Main.qml` 中实例化，用于 PDF 导出 |

图像通过 `QQuickImageProvider` 提供，QML 侧使用 `Image { source: "image://waveform/..." }` 形式；图像内容由 C++ `QPainter` 绘制，QML 只负责布局与缩放。

## 6. 界面约定

- **坐标**：页面文件使用设计稿绝对坐标；面板文件使用相对面板原点的坐标；放进 `AppShell` 内容槽的内容需减去 `(154,150)`。
- **状态刷新**：C++ 的 `Q_INVOKABLE` 没有变更通知，列表类数据通过 `revision` 属性显式触发重算。
- **脱敏**：所有展示患者姓名/病历号的位置必须经过 `Privacy.masked()`；导出路径在写文件前单独脱敏。
- **角色控制**：`userRole === "管理员"` 控制用户管理入口、医院信息编辑等权限；C++ 侧还会按 `created_by` 做数据归属校验。
- **字体**：`Alibaba PuHuiTi 2.0`，通过 `styleName`（55/65/85）区分字重，不能用 `weight`。
