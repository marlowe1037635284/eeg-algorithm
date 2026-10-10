#ifndef OFFLINEALGORITHM_H
#define OFFLINEALGORITHM_H

// C++ 侧的后处理算法调用层。
//
// 「数据分析与后处理」页（postprocess.cpp）原先自己实现了一整套预处理与统计
// （滤波 / 重参考 / ASR / 降采样 / Welch / 相关性 / 地形图插值 …）。现在算法统一
// 收到 Python 侧的 ``eeg_algorithm`` 离线接口里，这一层负责把 C++ 的参数翻译成
// 适配层（``eeg_bridge``）认识的扁平 dict，跑完一次离线会话后再把结果搬回 C++ 的
// 普通容器（QVector），供 PostProcess 复用它原有的出图/报告代码组装 Result。
//
// 为什么单独一个翻译单元：pybind11 的头必须排在 Qt 头之前（Qt 的 qtmetamacros.h
// 会把 ``slots`` 定义成宏，先包含 Qt 再包含 pybind11 会编译失败），而 postprocess.h
// 面向 QML、必须保持对 pybind11 无感。所以把「包含 pybind11」这件事全部关在本层
// 的 .cpp 里，头文件只暴露纯 Qt 结构 —— 谁都能包含它，谁都不必碰 pybind11。
//
// 本头文件**不含 pybind11**，也不含任何 Python.h。

#include <QString>
#include <QStringList>
#include <QVector>

namespace offlinealgorithm
{

// 单导联频谱。与 C++ 原来的 Psd 结构同形，方便 postprocess 侧直接喂给它自己的
// band_mean_psd / band_power / render_spectrum_image。
struct Spectrum
{
    QVector<double> frequencies;   // Hz
    QVector<double> values;        // PSD
};

// 质检 / 伪差片段。sample 索引基于**整段**预处理信号（不是选段），
// 由 PostProcess 按选段裁剪后再用于报告。
struct Segment
{
    QString channel_name;
    QString type;
    int start_sample = 0;
    int end_sample = 0;   // 开区间（= 末样本下标 + 1）
};

// 一次后处理分析的全部输入。字段直接对应 PostProcess 的 Job 参数。
struct Input
{
    QVector<float> samples;   // 整段原始信号，帧优先交错（帧 i 的 ch 在 i*channels+ch）
    int channels = 0;
    int frames = 0;
    int sample_rate = 0;      // 原始采样率（Hz）
    int preprocess_version = 1;

    bool high_pass_enabled = true;
    double high_pass_hz = 0.1;
    bool low_pass_enabled = true;
    double low_pass_hz = 49.0;
    bool notch_enabled = true;
    double notch_hz = 50.0;

    int reference_index = 2;        // 0 双侧乳突 / 1 平均参考 / 2 不重参考
    bool asr_enabled = false;
    double asr_cutoff = 20.0;
    bool artifact_detection_enabled = false;

    bool resample_enabled = false;
    double resample_target_hz = 0.0;

    // 基线校正由本层在送数据前完成：按通道扣掉整段均值。
    bool baseline_enabled = false;

    double segment_start = 0.0;     // 选段起点（秒，相对预处理后信号）
    double segment_seconds = 10.0;  // 选段时长（秒）

    bool qc_signal_enabled = true;      // 弱信号
    bool qc_range_enabled = true;       // 幅值离群
    bool qc_correlation_enabled = true; // 低相关
    bool qc_repair_enabled = false;
    double qc_amplitude_ratio = 0.1;
    double qc_correlation = 0.1;
    double qc_weak_signal_threshold_uv = 1.0;
};

// 一次后处理分析的全部输出。除名称外都已是 Qt 容器，PostProcess 直接拿来用。
struct Output
{
    bool ok = false;
    QString error;

    double sample_rate = 0.0;         // 预处理后采样率
    int channels = 0;
    int sample_count = 0;             // 预处理后整段样本数
    int analysis_first = 0;           // 选段在整段中的起点
    int analysis_count = 0;           // 选段样本数

    QStringList applied_steps;        // Python 侧执行过的步骤名（仅参考）
    QStringList warnings;

    QVector<QVector<double>> processed;        // [C][N] 逐通道整段
    QVector<qint64> processed_timestamps_ns;   // [N]
    bool repaired = false;

    QVector<Spectrum> spectra;                 // [C]

    QVector<double> mean;                      // 以下各 [C]
    QVector<double> std_dev;
    QVector<double> rms;
    QVector<double> peak_to_peak;
    QVector<double> minimum;
    QVector<double> maximum;
    QVector<double> zero_cross;
    QVector<double> skewness;
    QVector<double> kurtosis;
    QStringList dominant_band;                 // [C]，取值为频段 key 或 "none"

    QVector<QVector<double>> correlation;      // [C][C]
    QVector<QVector<double>> band_energies;    // [C][5]
    QStringList band_names;                    // 5：delta/theta/alpha/beta/gamma

    QStringList topo_band_names;               // 6：full/delta/theta/alpha/beta/gamma
    QVector<QVector<double>> topo_electrode;   // [6][C]，各频段电极 RMS

    QVector<Segment> quality_segments;         // 整段 sample 索引
    QVector<Segment> artifact_segments;        // 整段 sample 索引
};

// Python 解释器是否已就绪。PostProcess 用它决定是走离线算法还是直接报错。
bool available();

// 跑一次完整的离线分析。内部自行取 GIL、建会话、预处理、查询、关会话。
// 任何失败（解释器未启动、会话异常、算法报错）都以 ok=false + error 返回，
// 不抛异常 —— 调用方在 QtConcurrent 的工作线程里，异常穿出线程会 terminate。
Output run(const Input &input);

} // namespace offlinealgorithm

#endif // OFFLINEALGORITHM_H
