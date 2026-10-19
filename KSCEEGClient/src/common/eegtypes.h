#ifndef EEGTYPES_H
#define EEGTYPES_H

#include <QMetaType>
#include <QString>
#include <QStringList>
#include <QVector>
#include <QtGlobal>

#include <limits>

// 跨线程传递的纯数据结构。这个头文件**不含任何 pybind11 头**，也不需要前置声明 ——
// 所有 py::object 都只活在 pythonengine.cpp / pythonworker.cpp 的翻译单元里。
// 原因见 pythonengine.cpp 顶部的包含顺序说明（pybind11 必须先于 Qt 头）。

// 一块连续的 EEG 样本。
//
// 数据布局：**帧优先交错**，访问式 ``samples[i * channels + ch]``，单位 µV。
// 采集线程、显示环形缓冲、.eegbin 落盘三处用的是同一套布局，跨这三处不必转置；
// 只有进出 Python 时才需要转成算法要求的 [C,N]（见 pythonworker.cpp）。
//
// 原始数据与算法处理后的数据共用这一个结构：两者的字段完全一致，区别只在来源，
// 分成两个结构只会让「原始/处理后」这条主线多一层无谓的类型转换。
struct SignalChunk
{
    int channels = 0;
    int samples_per_channel = 0;
    // 本块首个样本的序列号。C++ 自己编，只在成功解析出样本时推进；
    // 算法的 push_block 要求它严格等于上次 last+1，中间补洞要用 gap 声明。
    qint64 first_sequence_id = 0;
    // 本块首个样本的时间戳（ns）。由单调时钟加一个墙钟基准偏移生成，
    // 不用 QDateTime —— 系统时间被 NTP 回拨会产生重复/倒序时间戳，
    // 算法侧会抛 TIME_SEQUENCE_DISCONTINUITY，那种错「偶尔出现、无法复现」。
    qint64 first_timestamp_ns = 0;
    QVector<float> samples;
};
Q_DECLARE_METATYPE(SignalChunk)

// 一段数据缺口。采集线程因为算法队列满而主动丢块时会记一条，
// 算法线程在处理后续数据前先把它声明出去 —— 否则算法只会看到「序列号断裂」，
// 真正的原因（我们主动丢了）反而被淹没。
struct GapRange
{
    qint64 first_missing_sequence_id = 0;
    qint64 last_missing_sequence_id = 0;
    qint64 start_timestamp_ns = 0;
    qint64 end_timestamp_ns = 0;
    QString reason;
};
Q_DECLARE_METATYPE(GapRange)

// 算法侧抛出的结构化错误（对应 Python 的 AlgorithmErrorInfo）。
// 接口文档约定「日志不能替代错误码」，所以 code 是分级的唯一依据。
struct AlgorithmErrorInfo
{
    QString code;        // 错误码，取不到时为空
    QString message;
    QString operation;
    qint64 session_id = -1;
    qint64 sequence_id = -1;

    bool is_valid() const { return !code.isEmpty(); }
};
Q_DECLARE_METATYPE(AlgorithmErrorInfo)

// 在线滤波与陷波参数。对应 Python 的 OnlineProcessingConfig，
// 但压成了扁平结构 —— 五层嵌套的 dataclass 不适合在 C++ 侧持有。
//
// config_version 不在这里自增：它的唯一持有者是 PythonWorker 线程，
// 且只在 update_processing_config 成功返回后才 +1（见 pythonworker.cpp）。
struct ProcessingParams
{
    bool high_pass_enabled = true;
    double high_pass_low_hz = 0.5;
    int high_pass_order = 4;

    bool low_pass_enabled = true;
    double low_pass_high_hz = 45.0;
    int low_pass_order = 4;

    bool notch_enabled = true;
    double notch_low_hz = 48.0;
    double notch_high_hz = 52.0;
    int notch_order = 4;

    bool asr_enabled = false;
};
Q_DECLARE_METATYPE(ProcessingParams)

// update_processing_config 的结果投影。
struct ConfigUpdateInfo
{
    int config_version = 0;
    qint64 effective_sequence_id = 0;
    bool rolling_buffer_cleared = false;
    // 为真表示前置滤波变了、ASR 输入分布跟着变，而算法无法自动重新拟合，
    // 必须由 C++ 重新调 set_asr_reference()。没有 180 秒原始缓冲就做不到这件事。
    bool asr_refit_required = false;
    bool warmup_required = false;
};
Q_DECLARE_METATYPE(ConfigUpdateInfo)

// 一帧脑电地形图。grid_values 的形状是 [grid_height, grid_width]，
// 行优先、单位 µV²/Hz；头部掩膜以外的值算法已经置 0，这里不必再带掩膜。
//
// 面板上那四项统计（峰值电极/峰值功率/全脑均值/枕额比）在算法线程里算好一起带回来：
// 界面只负责贴，不再自己从数组里挑极值 —— 一份统计两处实现，迟早对不上
struct TopographyFrame
{
    int request_id = 0;
    int config_version = 0;
    int grid_width = 0;
    int grid_height = 0;
    QVector<float> grid_values;
    // 头部掩膜 [H,W]。必须带回来：算法会把掩膜外的值置 0，而 0 在掩膜内也是
    // 合法功率值，只看数值分不出「头外」和「头内的零功率」。画图时靠它把
    // 头外做成透明，否则热力图会是一个方块而不是圆的
    QVector<bool> head_mask;
    QVector<float> electrode_values;   // [C]，与 electrode_names 一一对应
    QStringList electrode_names;

    QString peak_electrode;
    double peak_power = 0.0;           // µV²/Hz
    double mean_power = 0.0;           // µV²/Hz，全脑平均
    double frontal_occipital_ratio = 0.0;
    // 配色上限（µV²/Hz）。实时侧固定为 50（见 kTopographyScaleMax），
    // 图与色标条共用它归一化，超过上限的值在色标顶端饱和
    double scale_max = 0.0;
};
Q_DECLARE_METATYPE(TopographyFrame)

// 建在线会话所需的全部参数。与 ProcessingParams 分开，是因为这两者的
// 可变性不同：ProcessingParams 可以在会话运行中改（update_processing_config），
// 而下面这些只有建会话时能定，改了必须重建会话（接口的 OnlineConfig 才带它们）
struct SessionConfig
{
    // 通道名与电极坐标一律取自 eeg_montage，不在这里传：
    // 两处各存一份名字，改了一处忘了另一处，地形图上就会出现对不上的电极
    double sample_rate_hz = 1000.0;
    // 滚动缓存时长，必须不小于界面可选的最大地形图/频谱窗口
    double rolling_window_s = 10.0;

    // 重参考方式（"off" / "bilateral_mastoids" / "common_average"）
    QString reference_method = QStringLiteral("common_average");
    QStringList mastoid_channels;

    double asr_cutoff = 20.0;
    double asr_window_s = 1.0;
    double asr_overlap_ratio = 0.5;
    double asr_reference_duration_s = 120.0;

    ProcessingParams processing;
};
Q_DECLARE_METATYPE(SessionConfig)

// 地形图查询请求。request_id 由界面侧递增，用来丢弃过期结果
struct TopographyRequest
{
    int request_id = 0;
    QString band_preset = QStringLiteral("alpha");
    double band_low_hz = 8.0;
    double band_high_hz = 13.0;
    double window_s = 2.0;
    int grid_width = 64;
    int grid_height = 64;
};
Q_DECLARE_METATYPE(TopographyRequest)

// 频谱查询请求
struct SpectrumRequest
{
    int request_id = 0;
    QString channel_name;
    QString band_preset = QStringLiteral("full_0_5_45");
    double band_low_hz = 0.5;
    double band_high_hz = 45.0;
    double window_s = 2.0;
};
Q_DECLARE_METATYPE(SpectrumRequest)

// 一条单导联 PSD 曲线。
struct SpectrumFrame
{
    int request_id = 0;
    int config_version = 0;
    QString channel_name;
    QVector<float> frequencies_hz;
    QVector<float> psd;
    // 算法接口给出的五个频段峰值 PSD，顺序 δ θ α β γ。
    // 频段内没有频点时为 NaN，界面显示「—」。
    double delta_peak_psd = std::numeric_limits<double>::quiet_NaN();
    double theta_peak_psd = std::numeric_limits<double>::quiet_NaN();
    double alpha_peak_psd = std::numeric_limits<double>::quiet_NaN();
    double beta_peak_psd = std::numeric_limits<double>::quiet_NaN();
    double gamma_peak_psd = std::numeric_limits<double>::quiet_NaN();
};
Q_DECLARE_METATYPE(SpectrumFrame)

// 会话状态的精简投影。界面只关心这几个：
// rolling_buffer_duration_s 决定地形图/频谱查询能不能发，
// state 是判断「会话是不是真的坏了」的权威依据。
struct SessionStatusSnapshot
{
    QString state;                            // created/warming_up/running/degraded/error/closed
    int config_version = 0;
    qint64 last_processed_sequence_id = -1;
    double rolling_buffer_duration_s = 0.0;
    int gap_count = 0;
    int warmup_remaining_samples = 0;
    double average_processing_time_us = 0.0;
};
Q_DECLARE_METATYPE(SessionStatusSnapshot)

// Python 侧日志系统里 WARNING 及以上的事件，由算法线程周期拉取后转到界面。
struct AlgorithmLogEvent
{
    qint64 timestamp_utc_ns = 0;
    QString level;
    QString code;
    QString message;
    QString operation;
};
Q_DECLARE_METATYPE(AlgorithmLogEvent)

#endif // EEGTYPES_H
