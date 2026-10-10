// 后处理算法的 C++ 调用层实现。
//
// pybind11 头必须排在任何 Qt 头之前（见 offlinealgorithm.h 顶部说明），因此这里的
// include 顺序是：pybind11 → 本层的头（其内部才包含 Qt）→ 其余 Qt / 项目头。
#include <pybind11/embed.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>

#include "offlinealgorithm.h"

#include "eegmontage.h"
#include "pythontypes.h"

#include <algorithm>
#include <cmath>

namespace py = pybind11;

namespace
{

// ==================== 错误投影 ====================

// 走适配层的 describe_error，C++ 不必知道 AlgorithmErrorInfo 的字段名。
// bridge 可能压根没导入成功（null），那时退回异常的原始文本。
QString describe_error(const py::object &bridge, const py::error_already_set &exc)
{
    if (bridge && !bridge.is_none())
    {
        try
        {
            const py::dict info = bridge.attr("describe_error")(exc.value()).cast<py::dict>();
            const QString message = pytypes::to_qstring(info["message"]);
            if (!message.isEmpty())
            {
                return message;
            }
        }
        catch (const std::exception &)
        {
            // 连投影都失败，落到下面的原始文本
        }
    }
    return QString::fromUtf8(exc.what());
}

// ==================== Python 数组 → Qt 容器 ====================

// [C,N] float32 → QVector<QVector<double>>。expected_frames < 0 时不校验列数。
bool copy_channel_matrix(const py::object &object, int channels, int expected_frames,
                         QVector<QVector<double>> *out)
{
    if (out == nullptr || object.is_none())
    {
        return false;
    }
    const auto array =
        object.cast<py::array_t<float, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = array.request();
    if (info.ndim != 2 || static_cast<int>(info.shape[0]) != channels)
    {
        return false;
    }
    const int frames = static_cast<int>(info.shape[1]);
    if (expected_frames >= 0 && frames != expected_frames)
    {
        return false;
    }
    const float *source = static_cast<const float *>(info.ptr);
    out->resize(channels);
    for (int ch = 0; ch < channels; ++ch)
    {
        QVector<double> &row = (*out)[ch];
        row.resize(frames);
        const float *line = source + static_cast<qsizetype>(ch) * frames;
        for (int i = 0; i < frames; ++i)
        {
            row[i] = static_cast<double>(line[i]);
        }
    }
    return true;
}

// [rows,cols] float32 → QVector<QVector<double>>。expected_cols < 0 时不校验。
bool copy_matrix(const py::object &object, int rows, int expected_cols,
                 QVector<QVector<double>> *out)
{
    if (out == nullptr || object.is_none())
    {
        return false;
    }
    const auto array =
        object.cast<py::array_t<float, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = array.request();
    if (info.ndim != 2 || static_cast<int>(info.shape[0]) != rows)
    {
        return false;
    }
    const int cols = static_cast<int>(info.shape[1]);
    if (expected_cols >= 0 && cols != expected_cols)
    {
        return false;
    }
    const float *source = static_cast<const float *>(info.ptr);
    out->resize(rows);
    for (int r = 0; r < rows; ++r)
    {
        QVector<double> &row = (*out)[r];
        row.resize(cols);
        const float *line = source + static_cast<qsizetype>(r) * cols;
        for (int i = 0; i < cols; ++i)
        {
            row[i] = static_cast<double>(line[i]);
        }
    }
    return true;
}

// [N] float32 → QVector<double>
bool copy_vector(const py::object &object, QVector<double> *out)
{
    if (out == nullptr || object.is_none())
    {
        return false;
    }
    const auto array =
        object.cast<py::array_t<float, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = array.request();
    if (info.ndim != 1)
    {
        return false;
    }
    const float *source = static_cast<const float *>(info.ptr);
    out->resize(static_cast<qsizetype>(info.shape[0]));
    for (qsizetype i = 0; i < info.shape[0]; ++i)
    {
        (*out)[i] = static_cast<double>(source[i]);
    }
    return true;
}

QStringList to_string_list(const py::object &object)
{
    QStringList result;
    if (object.is_none())
    {
        return result;
    }
    for (const py::handle item : object)
    {
        result.append(pytypes::to_qstring(item));
    }
    return result;
}

QVector<offlinealgorithm::Segment> to_segments(const py::object &object)
{
    QVector<offlinealgorithm::Segment> result;
    if (object.is_none())
    {
        return result;
    }
    for (const py::handle item : object)
    {
        const py::dict segment = item.cast<py::dict>();
        offlinealgorithm::Segment out;
        out.channel_name = pytypes::to_qstring(segment["channel_name"]);
        out.type = pytypes::to_qstring(segment["artifact_type"]);
        out.start_sample = segment["start_sample"].cast<int>();
        out.end_sample = segment["end_sample"].cast<int>();
        result.append(out);
    }
    return result;
}

// ==================== Qt 输入 → Python 参数 ====================

// 扁平配置 dict。键名必须与 eeg_bridge._parse_preprocess_config 完全一致 ——
// 少一个键不会编译报错，只在运行期以 KeyError 冒出来，所以这里逐键对齐。
py::dict make_config(const offlinealgorithm::Input &input)
{
    py::dict config;
    config["preprocess_version"] = input.preprocess_version;

    config["high_pass_enabled"] = input.high_pass_enabled;
    config["high_pass_cutoff_hz"] = input.high_pass_hz;
    config["low_pass_enabled"] = input.low_pass_enabled;
    config["low_pass_cutoff_hz"] = input.low_pass_hz;

    // C++ 只给一个陷波中心频率，算法要的是一个阻带区间：以中心 ±2Hz。
    config["notch_enabled"] = input.notch_enabled;
    config["notch_stop_low_hz"] = input.notch_hz - 2.0;
    config["notch_stop_high_hz"] = input.notch_hz + 2.0;

    config["reference_enabled"] = input.reference_index != 2;
    switch (input.reference_index)
    {
    case 0:
    {
        config["reference_method"] = "bilateral_mastoids";
        py::list mastoids;
        mastoids.append("T3");
        mastoids.append("T4");
        config["mastoid_channels"] = mastoids;
        break;
    }
    case 1:
        config["reference_method"] = "common_average";
        break;
    default:
        config["reference_method"] = "off";
        break;
    }

    config["asr_enabled"] = input.asr_enabled;
    config["asr_cutoff"] = input.asr_cutoff;

    // C++ 的伪差检测只有一个开关，其余参数沿用算法默认值。
    config["artifact_enabled"] = input.artifact_detection_enabled;
    config["artifact_jump_ratio"] = 5.0;
    config["artifact_high_freq_hz"] = 30.0;
    config["artifact_high_freq_ratio"] = 0.5;

    config["resample_enabled"] = input.resample_enabled;
    config["resample_target_rate_hz"] = input.resample_target_hz;

    config["qc_null_weak_enabled"] = input.qc_signal_enabled;
    config["qc_amplitude_outlier_enabled"] = input.qc_range_enabled;
    config["qc_low_correlation_enabled"] = input.qc_correlation_enabled;
    config["qc_repair_enabled"] = input.qc_repair_enabled;
    config["qc_amplitude_ratio"] = input.qc_amplitude_ratio;
    config["qc_correlation_threshold"] = input.qc_correlation;
    config["qc_weak_signal_threshold_uv"] = input.qc_weak_signal_threshold_uv;

    config["return_processed_signal"] = true;
    return config;
}

// 帧优先交错的一块样本 → [C,N] float32。baseline_enabled 时逐通道扣掉整段均值。
py::array_t<float> make_values(const offlinealgorithm::Input &input)
{
    const int channels = input.channels;
    const int frames = input.frames;

    QVector<double> channel_mean;
    if (input.baseline_enabled)
    {
        channel_mean.resize(channels);
        for (int ch = 0; ch < channels; ++ch)
        {
            double sum = 0.0;
            for (int i = 0; i < frames; ++i)
            {
                sum += input.samples.at(static_cast<qsizetype>(i) * channels + ch);
            }
            channel_mean[ch] = sum / frames;
        }
    }

    py::array_t<float> values({static_cast<py::ssize_t>(channels),
                               static_cast<py::ssize_t>(frames)});
    float *destination = values.mutable_data();
    for (int ch = 0; ch < channels; ++ch)
    {
        float *line = destination + static_cast<qsizetype>(ch) * frames;
        const double base = input.baseline_enabled ? channel_mean.at(ch) : 0.0;
        for (int i = 0; i < frames; ++i)
        {
            line[i] = static_cast<float>(
                static_cast<double>(input.samples.at(static_cast<qsizetype>(i) * channels + ch))
                - base);
        }
    }
    return values;
}

// 块内按采样周期等距展开的绝对时间戳 [N]（int64 纳秒），首个样本钉在 0。
py::array_t<qint64> make_timestamps(int frames, int sample_rate)
{
    const qint64 period_ns =
        static_cast<qint64>(std::llround(1.0e9 / static_cast<double>(sample_rate)));
    py::array_t<qint64> stamps(static_cast<py::ssize_t>(frames));
    qint64 *destination = stamps.mutable_data();
    for (int i = 0; i < frames; ++i)
    {
        destination[i] = static_cast<qint64>(i) * period_ns;
    }
    return stamps;
}

// 会话 RAII：无论正常还是异常展开，都保证关掉离线会话、释放 Python 侧内存。
// 析构器在 run() 的 GIL 作用域内执行（先于 gil 对象析构）。
struct SessionGuard
{
    py::object bridge;
    int session_id = -1;

    ~SessionGuard()
    {
        if (session_id >= 0 && bridge)
        {
            try
            {
                bridge.attr("close_offline_session")(session_id);
            }
            catch (...)
            {
                // 关会话失败不该盖住真正的错误，吞掉即可
            }
        }
    }
};

// ==================== 主体 ====================

void run_body(const py::object &bridge, const offlinealgorithm::Input &input,
              offlinealgorithm::Output *output)
{
    const int channels = input.channels;

    const int session_id = bridge.attr("create_offline_session")(
        pytypes::to_py_list(eeg_montage::channel_names()),
        static_cast<double>(input.sample_rate),
        pytypes::to_py_positions(),
        std::string("percent"),
        static_cast<qint64>(0),
        make_timestamps(input.frames, input.sample_rate),
        make_values(input)).cast<int>();

    SessionGuard guard{bridge, session_id};

    const py::dict pre =
        bridge.attr("run_preprocessing")(session_id, make_config(input)).cast<py::dict>();

    QVector<QVector<double>> processed;
    if (!copy_channel_matrix(pre["processed_values"], channels, -1, &processed)
        || processed.isEmpty())
    {
        output->error = QStringLiteral("算法返回的预处理信号格式不正确");
        return;
    }
    const int frames_out = processed.first().size();
    if (frames_out < 16)
    {
        output->error = QStringLiteral("预处理后的数据太短，无法分析");
        return;
    }

    QVector<qint64> stamps;
    if (!pytypes::copy_py_int64_array(pre["processed_timestamps_ns"], &stamps, frames_out))
    {
        output->error = QStringLiteral("算法返回的时间戳格式不正确");
        return;
    }

    const double rate_out = pre["sample_rate_hz"].cast<double>();

    // 选段：与 PostProcess 原先的切片口径一致，按预处理后采样率换算。
    int first = static_cast<int>(std::llround(input.segment_start * rate_out));
    first = std::clamp(first, 0, std::max(0, frames_out - 16));
    int count = static_cast<int>(std::llround(input.segment_seconds * rate_out));
    count = std::clamp(count, 16, frames_out - first);

    // 查询用闭区间：取选段首末样本的绝对时间戳。
    const qint64 start_ns = stamps.at(first);
    const qint64 end_ns = stamps.at(first + count - 1);

    // ---- 统计 ----
    const py::dict stats =
        bridge.attr("query_offline_statistics")(session_id, 0, input.preprocess_version,
                                                start_ns, end_ns).cast<py::dict>();
    copy_vector(stats["mean"], &output->mean);
    copy_vector(stats["std"], &output->std_dev);
    copy_vector(stats["rms"], &output->rms);
    copy_vector(stats["peak_to_peak"], &output->peak_to_peak);
    copy_vector(stats["min_value"], &output->minimum);
    copy_vector(stats["max_value"], &output->maximum);
    copy_vector(stats["zero_crossing_rate"], &output->zero_cross);
    copy_vector(stats["skewness"], &output->skewness);
    copy_vector(stats["kurtosis"], &output->kurtosis);
    output->dominant_band = to_string_list(stats["dominant_band"]);
    output->band_names = to_string_list(stats["band_names"]);
    copy_matrix(stats["correlation_matrix"], channels, channels, &output->correlation);
    copy_matrix(stats["band_energies"], channels, 5, &output->band_energies);

    // ---- 地形图：只要各频段的电极值，网格插值交给 PostProcess 原有的 C++ 实现，
    //      所以用一个最小网格（Python 要求 >= 8）把被丢弃的网格开销压到最低。----
    const py::dict topo =
        bridge.attr("query_offline_topography")(session_id, 0, input.preprocess_version,
                                                start_ns, end_ns, 8, 8).cast<py::dict>();
    output->topo_band_names = to_string_list(topo["band_names"]);
    copy_matrix(topo["electrode_values"], 6, channels, &output->topo_electrode);

    // ---- 逐通道频谱 ----
    const QStringList names = eeg_montage::channel_names();
    output->spectra.resize(channels);
    for (int ch = 0; ch < channels; ++ch)
    {
        const py::dict spectrum = bridge.attr("query_offline_spectrum")(
            session_id, ch, input.preprocess_version, names.at(ch).toStdString(), start_ns,
            end_ns, py::none()).cast<py::dict>();
        offlinealgorithm::Spectrum line;
        copy_vector(spectrum["frequencies_hz"], &line.frequencies);
        copy_vector(spectrum["psd"], &line.values);
        output->spectra[ch] = line;
    }

    // ---- 质检 / 伪差（整段 sample 索引，PostProcess 按选段裁剪）----
    const py::object quality = pre["quality"];
    if (!quality.is_none())
    {
        const py::dict report = quality.cast<py::dict>();
        output->repaired = report["repaired"].cast<bool>();
        output->quality_segments = to_segments(report["segments"]);
    }
    const py::object artifact = pre["artifact"];
    if (!artifact.is_none())
    {
        output->artifact_segments = to_segments(artifact.cast<py::dict>()["segments"]);
    }

    output->applied_steps = to_string_list(pre["applied_steps"]);
    output->warnings = to_string_list(pre["warnings"]);
    output->sample_rate = rate_out;
    output->channels = channels;
    output->sample_count = frames_out;
    output->analysis_first = first;
    output->analysis_count = count;
    output->processed = processed;
    output->processed_timestamps_ns = stamps;
    output->ok = true;
}

} // namespace

namespace offlinealgorithm
{

bool available()
{
    return Py_IsInitialized() != 0;
}

Output run(const Input &input)
{
    Output output;

    if (input.channels <= 0 || input.frames <= 1 || input.sample_rate <= 0
        || input.samples.size() < static_cast<qsizetype>(input.channels) * input.frames)
    {
        output.error = QStringLiteral("这条记录没有可分析的数据");
        return output;
    }

    // Py_IsInitialized 不需要 GIL，可在取 GIL 之前判 —— 解释器没起来时
    // gil_scoped_acquire 的构造本身就会失败（见 pythonworker.cpp 的说明）。
    if (!Py_IsInitialized())
    {
        output.error = QStringLiteral("Python 算法模块未就绪，无法进行后处理分析");
        return output;
    }

    try
    {
        // GIL 只包住「构造入参 → 调 Python → 抽干结果」这一整段。返回的 numpy 数组
        // 不拷贝，必须在 GIL 作用域内 memcpy 拷走（见 run_body 的各个 copy_* 调用）。
        const py::gil_scoped_acquire gil;
        py::object bridge;
        try
        {
            bridge = py::module_::import("eeg_bridge");
            // 幂等预热：pythonengine.start() 未必调过 open_api，这里保底建门面。
            bridge.attr("open_api")();
            run_body(bridge, input, &output);
        }
        catch (const py::error_already_set &exc)
        {
            output.ok = false;
            output.error = describe_error(bridge, exc);
        }
    }
    catch (const std::exception &exc)
    {
        // 走到这里多半是 GIL 获取失败（解释器已关闭）等非 Python 异常
        output.ok = false;
        output.error = QString::fromUtf8(exc.what());
    }
    return output;
}

} // namespace offlinealgorithm
