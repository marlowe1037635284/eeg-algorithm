// ============================================================================
// Qt C++ 端调用 eeg_algorithm 在线接口示例
// ============================================================================
// 说明：
//   - eeg_algorithm 是面向 C++/pybind11 内嵌 CPython 的 EEG 算法包。
//   - C++ 只调用公共模块 eeg_algorithm.api / types / errors，不得导入 internal。
//   - 本示例演示完整流程：初始化嵌入解释器 → 校验版本 → create_api →
//     构造配置 DTO → 创建在线会话 → push_block 零拷贝推送数据 →
//     查询频谱/地形图 → 关闭。
//
// 依赖：pybind11、Python 3.11+、Qt5/Qt6（示例仅用到 QVector 容器）。
// 编译（示意，路径按本机环境调整；MSVC）：
//   cl /std:c++17 /EHsc qt_cpp_api_demo.cpp ^
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
constexpr int kBlockSamples = 250;            // 每块 1 秒
constexpr int64_t kNsPerSample = 4'000'000;   // 250Hz -> 4ms

// 用 QVector 存放模拟采集数据（[C, N] 行主序，10Hz alpha + 20Hz beta）
static QVector<float> makeSimulatedBlock(double startTimeS) {
    QVector<float> buf(kChannelCount * kBlockSamples);
    constexpr double kPi = 3.141592653589793;
    for (int c = 0; c < kChannelCount; ++c) {
        for (int n = 0; n < kBlockSamples; ++n) {
            double t = startTimeS + double(n) / kSampleRateHz;
            double v = std::sin(2.0 * kPi * 10.0 * t + c * 0.3)
                     + 0.5 * std::sin(2.0 * kPi * 20.0 * t);
            buf[c * kBlockSamples + n] = float(v);
        }
    }
    return buf;
}

int main(int argc, char** argv) {
    try {
        // 1. 初始化嵌入式 Python 解释器（进程内仅允许一次，须早于所有 py:: 调用）
        py::scoped_interpreter guard{};

        // 2. 确保 eeg_algorithm 可导入：将 src 目录加入 sys.path
        //    （若已执行 pip install -e . 安装为可编辑包，可省略此行）
        py::module_::import("sys").attr("path").attr("append")("<你的 src 目录绝对路径>");

        // 3. 导入公共模块
        py::module_ api_mod = py::module_::import("eeg_algorithm.api");
        py::module_ types_mod = py::module_::import("eeg_algorithm.types");

        // 4. 创建 API 前校验主版本号
        std::string version = api_mod.attr("get_api_version")().cast<std::string>();
        if (version.rfind("1.", 0) != 0) {
            std::cerr << "不支持的 API 版本: " << version << std::endl;
            return 1;
        }
        std::cout << "API 版本: " << version << std::endl;

        // 5. 创建进程内唯一 API 门面（重复调用返回同一对象）
        py::object api = api_mod.attr("create_api")();

        // 6. 构造配置 DTO（字段与 Python dataclass 一一对应）
        py::object toggle_off = types_mod.attr("ToggleFilterConfig")(false);           // 滤波全关
        py::object processing = types_mod.attr("OnlineProcessingConfig")(
            1, toggle_off, toggle_off, toggle_off, false);                             // version=1, ASR 关
        py::object reference = types_mod.attr("ReferenceConfig")();                    // 重参考 OFF
        py::object asr = types_mod.attr("AsrConfig")();                                // ASR 默认参数
        py::object phase = types_mod.attr("PhaseModelConfig")(false, "", py::tuple()); // 相位关

        py::tuple channel_names = py::make_tuple("F3", "F4", "P3", "P4");
        py::object layout = types_mod.attr("ChannelLayout")(channel_names, kSampleRateHz);
        py::object config = types_mod.attr("OnlineConfig")(
            layout, processing, reference, asr, phase, 5.0);                           // rolling_window_s=5.0

        // 7. 创建在线会话
        int session_id = api.attr("create_online_session")(config).cast<int>();
        std::cout << "在线会话已创建: " << session_id << std::endl;

        // 8. 分块 push_block（模拟流式采集 10 块，共 10 秒）
        int next_seq = 0;
        for (int block = 0; block < 10; ++block) {
            QVector<float> buf = makeSimulatedBlock(block * 1.0);

            // 零拷贝构造 numpy 数组（[C, N] 与 [N]）；内存须在本次调用返回前保持有效
            std::vector<py::ssize_t> value_shape = {kChannelCount, kBlockSamples};
            py::array_t<float> values(value_shape, buf.data());

            std::vector<int64_t> ts(kBlockSamples);
            for (int n = 0; n < kBlockSamples; ++n) {
                ts[n] = int64_t(block) * kBlockSamples * kNsPerSample + n * kNsPerSample;
            }
            std::vector<py::ssize_t> ts_shape = {kBlockSamples};
            py::array_t<int64_t> timestamps(ts_shape, ts.data());

            py::object signal_block = types_mod.attr("SignalBlock")(next_seq, timestamps, values);
            py::object result = api.attr("push_block")(session_id, signal_block);

            int64_t last_seq = result.attr("last_sequence_id").cast<int64_t>();
            next_seq += kBlockSamples;
            std::cout << "[block " << block << "] seq .." << last_seq << std::endl;
        }

        // 9. 查询 alpha 频段频谱（单导联）
        py::object alpha = types_mod.attr("BandPreset").attr("ALPHA");
        py::object band = types_mod.attr("FrequencyBand")(alpha, 8.0, 13.0);
        py::object spectrum_query = types_mod.attr("SpectrumQuery")(1, "F3", band, 2.0);
        py::object spectrum = api.attr("query_online_spectrum")(session_id, spectrum_query);
        int freq_count = spectrum.attr("frequencies_hz").attr("size").cast<int>();
        std::cout << "频谱频点数量: " << freq_count << std::endl;

        // 10. 查询 alpha 频段地形图（多通道，64x64 网格）
        py::object topo_query = types_mod.attr("TopographyQuery")(
            2, band, py::arg("window_s") = 2.0);
        py::object topo = api.attr("query_online_topography")(session_id, topo_query);
        auto grid = topo.attr("grid_values").cast<py::array_t<float>>();
        std::cout << "地形图网格形状: " << grid.shape(0) << "x" << grid.shape(1) << std::endl;

        // 11. 关闭（释放全部会话与资源；关闭后除重复 close 外调用均抛 INVALID_STATE）
        api.attr("close")();
        std::cout << "已关闭 API" << std::endl;
    } catch (const py::error_already_set& e) {
        std::cerr << "Python 调用失败: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
