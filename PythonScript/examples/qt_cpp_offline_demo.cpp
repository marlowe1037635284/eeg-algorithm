// ============================================================================
// Qt C++ 端调用 eeg_algorithm 离线接口示例
// ============================================================================
// 说明：
//   - 离线会话用于整段信号的一次性处理：先 create_offline_session 送入原始信号，
//     再 run_preprocessing 预处理，之后可多次查询频谱/地形图（指定时间段）。
//   - 与在线接口的差异：查询必须携带 preprocess_version（防止查询到过期数据）；
//     时间段用绝对时间戳 AbsoluteTimeRange（纳秒），而非"最近 N 秒"。
//   - C++ 只调用公共模块 eeg_algorithm.api / types / errors，不得导入 internal。
//
// 依赖：pybind11、Python 3.11+、Qt5/Qt6（示例仅用到 QVector 容器）。
// 编译（示意，路径按本机环境调整；MSVC）：
//   cl /std:c++17 /EHsc qt_cpp_offline_demo.cpp ^
//      /I<python include> /I<pybind11 include> /I<Qt include> ^
//      <python lib>.lib Qt6Core.lib
// 运行前需保证 eeg_algorithm 可导入：已 pip install -e . 或将 src 加入 sys.path。
// ============================================================================

#include <pybind11/embed.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>

#include <QVector>

#include <cmath>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace py = pybind11;

// 采样参数
constexpr double kSampleRateHz = 250.0;
constexpr int kChannelCount = 4;
constexpr int kTotalSamples = 2500;          // 10 秒
constexpr int64_t kNsPerSample = 4'000'000;  // 250Hz -> 4ms

// 模拟 4 通道、10 秒的 EEG 信号（10Hz alpha 波，[C, N] 行主序）
static QVector<float> makeSimulatedSignal() {
    QVector<float> buf(kChannelCount * kTotalSamples);
    constexpr double kPi = 3.141592653589793;
    for (int c = 0; c < kChannelCount; ++c) {
        for (int n = 0; n < kTotalSamples; ++n) {
            double t = double(n) / kSampleRateHz;
            buf[c * kTotalSamples + n] = float(20.0 * std::sin(2.0 * kPi * 10.0 * t + c * 0.4));
        }
    }
    return buf;
}

int main(int argc, char** argv) {
    try {
        // 1. 初始化嵌入式 Python 解释器（进程内仅允许一次）
        py::scoped_interpreter guard{};

        // 2. 确保 eeg_algorithm 可导入（已 pip install -e . 可省略）
        py::module_::import("sys").attr("path").attr("append")("<你的 src 目录绝对路径>");

        // 3. 导入公共模块
        py::module_ api_mod = py::module_::import("eeg_algorithm.api");
        py::module_ types_mod = py::module_::import("eeg_algorithm.types");

        // 4. 创建 API 门面
        py::object api = api_mod.attr("create_api")();

        // 5. 构造含电极坐标的布局（离线地形图查询必需 positions）
        py::object e1 = types_mod.attr("ElectrodePosition")("F3", -0.5, 0.6, 0.6, "unit_sphere");
        py::object e2 = types_mod.attr("ElectrodePosition")("F4", 0.5, 0.6, 0.6, "unit_sphere");
        py::object e3 = types_mod.attr("ElectrodePosition")("P3", -0.5, -0.6, 0.6, "unit_sphere");
        py::object e4 = types_mod.attr("ElectrodePosition")("P4", 0.5, -0.6, 0.6, "unit_sphere");
        py::tuple channel_names = py::make_tuple("F3", "F4", "P3", "P4");
        py::tuple positions = py::make_tuple(e1, e2, e3, e4);
        py::object layout = types_mod.attr("ChannelLayout")(channel_names, kSampleRateHz, positions);

        // 6. 构造原始信号块（零拷贝；离线会话内部会复制保存，调用返回后内存可复用）
        QVector<float> buf = makeSimulatedSignal();
        std::vector<py::ssize_t> value_shape = {kChannelCount, kTotalSamples};
        py::array_t<float> values(value_shape, buf.data());

        std::vector<int64_t> ts(kTotalSamples);
        for (int n = 0; n < kTotalSamples; ++n) ts[n] = n * kNsPerSample;
        std::vector<py::ssize_t> ts_shape = {kTotalSamples};
        py::array_t<int64_t> timestamps(ts_shape, ts.data());

        py::object raw_signal = types_mod.attr("SignalBlock")(0, timestamps, values);

        // 7. 创建离线会话
        int session_id = api.attr("create_offline_session")(layout, raw_signal).cast<int>();
        std::cout << "离线会话已创建: " << session_id << std::endl;

        // 8. 构造预处理配置并运行（高通/低通独立开关，组合为带通）
        py::object high_pass = types_mod.attr("HighPassConfig")(true, 1.0);        // 高通 1Hz
        py::object low_pass = types_mod.attr("LowPassConfig")(true, 30.0);         // 低通 30Hz
        py::object notch = types_mod.attr("NotchConfig")(true);                    // 陷波 48-52Hz
        py::object ref_method = types_mod.attr("ReferenceMethod").attr("COMMON_AVERAGE");
        py::object reference = types_mod.attr("OfflineReferenceConfig")(true, ref_method);  // 平均参考
        py::object asr = types_mod.attr("OfflineAsrConfig")(false);                // 关闭 ASR
        // 伪迹检测配置：enabled=true，跳变/高频参数使用默认 jump_ratio=5.0, high_freq_hz=30.0, high_freq_ratio=0.5
        py::object artifact = types_mod.attr("ArtifactDetectionConfig")(true);      // 开启伪迹检测
        py::object resample = types_mod.attr("ResampleConfig")(false, 250.0);      // 不降采样
        // 质检配置：空值+弱信号/幅度外值/低相关三个检测开关=true；修复=true；
        //           其余检测/修复参数（eeg_range、三口径阈值、邻居表等）使用默认值
        py::object quality = types_mod.attr("QualityControlConfig")(
            py::arg("null_weak_enabled") = true,
            py::arg("amplitude_outlier_enabled") = true,
            py::arg("low_correlation_enabled") = true,
            py::arg("repair_enabled") = true);
        py::object config = types_mod.attr("PreprocessConfig")(
            1, high_pass, low_pass, notch, reference, asr, artifact, resample, quality);

        py::object result = api.attr("run_preprocessing")(session_id, config);
        int version = result.attr("preprocess_version").cast<int>();
        int sample_count = result.attr("sample_count").cast<int>();
        py::tuple steps = result.attr("applied_steps").cast<py::tuple>();
        std::cout << "预处理样本数: " << sample_count << std::endl;
        std::cout << "已应用步骤: " << py::str(steps).cast<std::string>() << std::endl;

        // 8.1 读取伪迹检测报告（异常段列表 + 逐样本掩码，用于界面标注）
        py::object artifact_report = result.attr("artifact_report");
        py::tuple artifact_segments = artifact_report.attr("segments").cast<py::tuple>();
        std::cout << "伪迹异常段数量: " << py::len(artifact_segments) << std::endl;

        // 8.2 读取质检报告（异常段列表 + 逐样本掩码，用于界面标注）
        py::object quality_report = result.attr("quality_report");
        py::tuple segments = quality_report.attr("segments").cast<py::tuple>();
        bool repaired = quality_report.attr("repaired").cast<bool>();
        std::cout << "质检异常段数量: " << py::len(segments) << "  是否已修复: " << (repaired ? "是" : "否") << std::endl;

        // 9. 查询离线频谱（F3 导联，2-4 秒，4-20Hz）
        py::object selected = types_mod.attr("AbsoluteTimeRange")(
            int64_t(2'000'000'000), int64_t(4'000'000'000));
        py::object freq_range = py::make_tuple(4.0, 20.0);
        py::object spec_query = types_mod.attr("OfflineSpectrumQuery")(
            1, version, "F3", selected, freq_range);
        py::object spectrum = api.attr("query_offline_spectrum")(session_id, spec_query);
        int freq_count = spectrum.attr("frequencies_hz").attr("size").cast<int>();
        std::cout << "离线频谱频点数: " << freq_count << std::endl;

        // 10. 查询离线地形图（一次返回全频段 + δ/θ/α/β/γ 共 6 张，64x64 网格）
        py::object topo_query = types_mod.attr("OfflineTopographyQuery")(
            2, version, selected);
        py::object topo = api.attr("query_offline_topography")(session_id, topo_query);
        auto grid = topo.attr("grid_values").cast<py::array_t<float>>();
        py::tuple topo_bands = topo.attr("band_names").cast<py::tuple>();
        std::cout << "离线地形图频段: " << py::str(topo_bands).cast<std::string>() << std::endl;
        std::cout << "离线地形图网格: " << grid.shape(0) << "x" << grid.shape(1)
                  << "x" << grid.shape(2) << " (6 张)" << std::endl;

        // 11. 查询离线多通道统计指标（与频谱/地形图同级别的统计页面）
        py::object stats_query = types_mod.attr("OfflineStatisticsQuery")(
            3, version, selected);
        py::object stats = api.attr("query_offline_statistics")(session_id, stats_query);
        auto stats_mean = stats.attr("mean").cast<py::array_t<float>>();
        py::tuple dominant = stats.attr("dominant_band").cast<py::tuple>();
        auto corr = stats.attr("correlation_matrix").cast<py::array_t<float>>();
        auto band_energies = stats.attr("band_energies").cast<py::array_t<float>>();
        py::tuple band_names = stats.attr("band_names").cast<py::tuple>();
        std::cout << "统计通道数: " << stats_mean.shape(0) << std::endl;
        std::cout << "统计优势频带: " << py::str(dominant).cast<std::string>() << std::endl;
        std::cout << "通道相关性矩阵: " << corr.shape(0) << "x" << corr.shape(1) << std::endl;
        std::cout << "频带能量: " << band_energies.shape(0) << "x" << band_energies.shape(1) << std::endl;
        std::cout << "频带名称: " << py::str(band_names).cast<std::string>() << std::endl;

        // 12. 查询离线质检（在预处理后选段数据上独立检测，只检测不修改数据）
        py::object qc = types_mod.attr("QualityControlConfig")();
        py::object quality_query = types_mod.attr("OfflineQualityQuery")(
            4, version, selected, qc);
        py::object quality = api.attr("query_offline_quality")(session_id, quality_query);
        py::tuple segments = quality.attr("segments").cast<py::tuple>();
        std::cout << "质检异常段数量: " << segments.size() << std::endl;

        // 13. 查看离线会话状态
        py::object status = api.attr("get_offline_status")(session_id);
        std::string state = status.attr("state").attr("value").cast<std::string>();
        std::cout << "离线状态: " << state << std::endl;

        // 14. 关闭（释放全部会话与资源）
        api.attr("close")();
        std::cout << "已关闭 API" << std::endl;
    } catch (const py::error_already_set& e) {
        std::cerr << "Python 调用失败: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
