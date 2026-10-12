#ifndef PYTHONTYPES_H
#define PYTHONTYPES_H

// Qt 类型 → Python 对象的转换helper。
//
// 本头文件**需要 pybind11**，只能被已经先包含过 pybind11 头的 .cpp 包含
// （目前是 pythonengine.cpp 与 pythonworker.cpp）。它不能出现在任何面向 QML 的
// 头文件里 —— 理由与 pybind11 头必须排在 Qt 头之前是同一条（见 pythonengine.cpp 顶部）。
//
// 为什么需要这层显式转换：pybind11 不认识 Qt 的容器类型。直接把 QStringList 传给
// pybind11 的调用运算符，得到的是运行期的
// "Unable to convert call argument '0' of type 'QList<QString>' to Python object"，
// 而不是编译错误 —— 所以必须逐项转成 std::string 再装进 py::list。
// QString 的 UTF-8 编码也在这里统一处理：Python 3 的 str 就是 UTF-8，
// 用 toStdString()（内部按 UTF-8 编码）才能保证中文错误消息不乱码。

#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>

#include <QString>
#include <QStringList>
#include <QVector>

#include <algorithm>

#include "common/eegmontage.h"
#include "common/eegtypes.h"

namespace py = pybind11;

namespace pytypes
{

inline std::string to_std_string(const QString &text)
{
    return text.toStdString();
}

inline QString to_qstring(const py::handle &value)
{
    return QString::fromStdString(py::str(value).cast<std::string>());
}

inline py::list to_py_list(const QStringList &items)
{
    py::list result;
    for (const QString &item : items)
    {
        result.append(item.toStdString());
    }
    return result;
}

// 电极表拍平成 [(name, x, y, z), ...]，供 ChannelLayout.positions 使用。
// z 一律给 0：地形图插值只用 x/y 两个分量，而设备也拿不到深度信息。
inline py::list to_py_positions()
{
    py::list positions;
    for (int i = 0; i < eeg_montage::kChannelCount; ++i)
    {
        const auto &electrode = eeg_montage::electrodes()[i];
        positions.append(py::make_tuple(std::string(electrode.name), electrode.x, electrode.y, 0.0));
    }
    return positions;
}

// 扁平滤波参数 → 适配层认的 dict。
// 键名必须与 eeg_bridge.PROCESSING_KEYS 完全一致；写错不会有编译错误，
// 只会在 update_processing_config 时抛 KeyError，所以启动自检要把这条路走一遍。
inline py::dict to_py_processing(const ProcessingParams &params, int config_version)
{
    py::dict result;
    result["config_version"] = config_version;

    result["high_pass_enabled"] = params.high_pass_enabled;
    result["high_pass_low_hz"] = params.high_pass_low_hz;
    result["high_pass_order"] = params.high_pass_order;

    result["low_pass_enabled"] = params.low_pass_enabled;
    result["low_pass_high_hz"] = params.low_pass_high_hz;
    result["low_pass_order"] = params.low_pass_order;

    result["notch_enabled"] = params.notch_enabled;
    result["notch_low_hz"] = params.notch_low_hz;
    result["notch_high_hz"] = params.notch_high_hz;
    result["notch_order"] = params.notch_order;

    result["asr_enabled"] = params.asr_enabled;
    return result;
}

// 帧优先交错的一块样本 → 算法要求的 [C,N] C 连续 float32 数组。
//
// 必须转置：采集侧、显示缓冲、落盘三处都用交错布局（按通道取样对界面更友好），
// 只有进出算法这一处需要 [C,N]。一块只有 channels × samples 个 float
// （16 通道 × 100 样本约 6 KB），转置的代价远小于让两边各用一套读法。
inline py::array_t<float> to_py_values(const SignalChunk &chunk)
{
    py::array_t<float> values({static_cast<py::ssize_t>(chunk.channels),
                               static_cast<py::ssize_t>(chunk.samples_per_channel)});
    float *destination = values.mutable_data();
    for (int ch = 0; ch < chunk.channels; ++ch)
    {
        for (int i = 0; i < chunk.samples_per_channel; ++i)
        {
            destination[static_cast<qsizetype>(ch) * chunk.samples_per_channel + i] =
                chunk.samples.at(static_cast<qsizetype>(i) * chunk.channels + ch);
        }
    }
    return values;
}

// 时间戳 [N]，int64 纳秒。块内按采样周期等距展开 ——
// 串口帧不携带时间戳，只能在块首钉一个基准值，块内按周期推。
inline py::array_t<qint64> to_py_timestamps(qint64 first_timestamp_ns, int samples,
                                            qint64 sample_period_ns)
{
    py::array_t<qint64> stamps(static_cast<py::ssize_t>(samples));
    qint64 *destination = stamps.mutable_data();
    for (int i = 0; i < samples; ++i)
    {
        destination[i] = first_timestamp_ns + static_cast<qint64>(i) * sample_period_ns;
    }
    return stamps;
}

// 从 Python 返回的 [C,N] 数组里取回交错布局的一块样本。
//
// forcecast + c_style 是保险：算法侧若换了 dtype 或改成 Fortran 序，这里会自动
// 拷一份，而不是让我们按错误的内存布局去读 —— 那种错误读出来的是「看起来像波形
// 但幅度离谱」的数据，比直接崩掉更难查。
inline bool copy_py_values_to_chunk(const py::handle &values_object, SignalChunk *chunk)
{
    if (chunk == nullptr || values_object.is_none())
    {
        return false;
    }

    const auto values =
        values_object.cast<py::array_t<float, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = values.request();
    if (info.ndim != 2 || info.shape[0] != chunk->channels
        || info.shape[1] != chunk->samples_per_channel)
    {
        return false;
    }

    const float *source = static_cast<const float *>(info.ptr);
    chunk->samples.resize(static_cast<qsizetype>(chunk->channels) * chunk->samples_per_channel);
    for (int ch = 0; ch < chunk->channels; ++ch)
    {
        for (int i = 0; i < chunk->samples_per_channel; ++i)
        {
            chunk->samples[static_cast<qsizetype>(i) * chunk->channels + ch] =
                source[static_cast<qsizetype>(ch) * chunk->samples_per_channel + i];
        }
    }
    return true;
}

// 一维 float32 数组 → QVector<float>。expected_size >= 0 时同时校验长度。
// 这类数组一律 forcecast：算法侧若换了 dtype，这里自动拷一份，
// 而不是让我们按错误的类型去读内存
inline bool copy_py_float_array(const py::handle &object, QVector<float> *out,
                                int expected_size = -1)
{
    if (out == nullptr || object.is_none())
    {
        return false;
    }

    const auto values = object.cast<py::array_t<float, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = values.request();
    if (info.ndim != 1 || (expected_size >= 0 && info.shape[0] != expected_size))
    {
        return false;
    }

    const float *source = static_cast<const float *>(info.ptr);
    out->resize(static_cast<qsizetype>(info.shape[0]));
    std::copy(source, source + info.shape[0], out->begin());
    return true;
}

// 一维 int64 数组 → QVector<qint64>
inline bool copy_py_int64_array(const py::handle &object, QVector<qint64> *out,
                                int expected_size = -1)
{
    if (out == nullptr || object.is_none())
    {
        return false;
    }

    const auto values = object.cast<py::array_t<qint64, py::array::c_style | py::array::forcecast>>();
    const py::buffer_info info = values.request();
    if (info.ndim != 1 || (expected_size >= 0 && info.shape[0] != expected_size))
    {
        return false;
    }

    const qint64 *source = static_cast<const qint64 *>(info.ptr);
    out->resize(static_cast<qsizetype>(info.shape[0]));
    std::copy(source, source + info.shape[0], out->begin());
    return true;
}

} // namespace pytypes

#endif // PYTHONTYPES_H
