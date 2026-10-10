#ifndef SERIALPROTOCOL_H
#define SERIALPROTOCOL_H

#include <QByteArray>
#include <QVector>

#include <QtGlobal>

#include <algorithm>
#include <cmath>

// EEG 采集设备的串口协议。帧格式与全部换算参数照搬 Python 参考实现
// （tms-eeg-client 的 data_thread.py 与 config.py），改协议时两边必须一起改。
//
// 协议里有**两种帧**，结构完全一样（都是 frame_size(channel_count) 字节），
// 只有首尾的魔术字节不同，用它们区分：
//
//   数据帧（常规采集）：
//     [0]        帧头 0xA0
//     [1]        帧号
//     [2..]      N 通道 × 3 字节，大端有符号 24 位 ADC 原始值
//     [末]       帧尾 0xC0
//
//   阻抗帧（收到 'Z' 命令后设备改为上传，'s' 停止）：
//     [0]        帧头 0xB0
//     [1]        帧号
//     [2..]      N 通道 × 3 字节，大端有符号 24 位，单位 Ω（<=0 表示该路未连接）
//     [末]       帧尾 0xD0
//
// 帧长 = 1 + 1 + N × 3 + 1，16 通道即 51 字节。
//
// 注意**没有校验和**：只有帧头与帧尾两道闸。所以配错波特率或通道数不会报错，
// 只会让波形变成噪声、丢字节计数一直涨 —— 排查时先看那个数字。
namespace serial_protocol
{

inline constexpr quint8 kStartByte = 0xA0;
inline constexpr quint8 kEndByte = 0xC0;

// 阻抗帧的首尾魔术字节
inline constexpr quint8 kImpedanceStartByte = 0xB0;
inline constexpr quint8 kImpedanceEndByte = 0xD0;

// ADS1299 前端参数 → uV 换算系数
inline constexpr double kVoltageRef = 4.5;                            // VREF，单位 V
inline constexpr double kPgaGain = 8.0;                               // 增益
inline constexpr int kAdcBits = 24;
inline constexpr int kAdcMaxValue = (1 << (kAdcBits - 1)) - 1;        // 8388607
// ≈ 0.0670552 µV/count；满量程 ±8388607 count → ±562500 µV
inline constexpr double kMicroVoltPerCount =
    kVoltageRef / kAdcMaxValue / kPgaGain * 1000000.0;

// 设备命令（单字节 ASCII）
inline constexpr char kCommandStart = 'b';
inline constexpr char kCommandStop = 's';
// 开始上传阻抗帧（设备收到后暂停常规数据帧，改为只发 B0…D0 阻抗帧）。
// 停止用通用的 kCommandStop('s')
inline constexpr char kCommandImpedanceStart = 'Z';

// 阻抗帧里每个通道的原始值单位是**欧姆**。换算成界面用的 kΩ 只改这一处。
//
// 之所以抽成常量：设备的阻抗单位口径还没最终定死（可能是 Ω，也可能是 0.1 kΩ），
// 真机对不上时只改这一个数字即可，不用去翻解析函数
inline constexpr double kKohmPerOhm = 0.001;

// 设备固定 16 通道。界面上的 4/8/16 档位是**显示与算法会话的通道子集**，
// 不改变串口上的帧结构 —— 采样、落盘、以及送进算法的那一份永远是 16 路。
//
// 参考实现里那份 {16: 51, 8: 33, 4: 21} 的帧长表与帧结构自相矛盾
// （按 1+1+N×3+1 应是 27 和 15），只有 16 通道被真正跑过，所以这里不提供 8/4
inline constexpr int kChannelCount = 16;
inline constexpr int kSampleRateHz = 1000;
inline constexpr int kDefaultBaudRate = 921600;

inline int frame_size(int channel_count)
{
    // 只认设备实际使用的那一档。参考实现的 config.py 里还有 8→33、4→21 两条，
    // 但那两个值与帧结构（1 + 1 + N×3 + 1 应为 27 和 15）自相矛盾，
    // 参考实现里也只有 16 通道被真正跑过。
    //
    // 这里**故意不给** 8/4：留着它们的话，谁把通道数改成 8，就会拿 33 去切真长
    // 27 的帧 —— 帧尾永远对不上，逐字节丢字节、波形全无，或者侥幸错位切出
    // 「两帧拼一帧」的假数据（幅度离谱但不报错），是全链路最难查的一种坏法。
    // 返回 0 让调用方直接拒绝，比默默错下去好
    return channel_count == 16 ? 51 : 0;
}

// 从缓冲区头部切出一个完整帧。成功返回 true 并把它从缓冲区里移除；
// 返回 false 表示还凑不够一个完整帧（字节留在缓冲区里等下一轮）。
//
// 放在协议头而不是采集线程里，是为了它**能被单独验证**：切帧是全链路里最容易
// 出错的一段（错位之后不会报错，只会让波形变成噪声），而它又是纯字节操作，
// 不依赖串口。放在这里，自检就能拿合成字节流直接喂它。
//
// 两种帧（数据/阻抗）帧长相同，靠帧头区分；尾巴必须与帧头配对（A0↔C0、B0↔D0）。
// 切出的是哪一种由可选出参 kind 带回（不需要时传 nullptr 即可）
enum class FrameKind
{
    Data,        // A0 … C0，常规脑电数据
    Impedance    // B0 … D0，阻抗
};

// 帧头对不上时**整段跳过**不含帧头的数据，而不是逐个 remove(0,1)：
// 波特率或通道数配错时每轮读入的几 KB 会被逐字节搬一遍，退化成 O(n²) 的 memmove。
// 帧头对但帧尾不对时只丢一个字节继续找 —— 真帧头可能就藏在后面几个字节里
inline bool take_frame(QByteArray *buffer, int frame_size, qint64 *dropped_bytes,
                       QByteArray *frame, FrameKind *kind = nullptr)
{
    if (buffer == nullptr || dropped_bytes == nullptr || frame == nullptr || frame_size <= 0)
    {
        return false;
    }

    while (buffer->size() >= frame_size)
    {
        const quint8 head = static_cast<quint8>(buffer->at(0));
        const bool is_data = (head == kStartByte);
        const bool is_impedance = (head == kImpedanceStartByte);
        if (!is_data && !is_impedance)
        {
            // 找下一个可能成为帧头的字节（两种帧头取更靠前的那个）。
            // indexOf 只认单个字节，所以两个都查一遍
            const qsizetype next_data = buffer->indexOf(static_cast<char>(kStartByte), 1);
            const qsizetype next_impedance =
                buffer->indexOf(static_cast<char>(kImpedanceStartByte), 1);
            qsizetype next = -1;
            if (next_data >= 0 && next_impedance >= 0)
            {
                next = std::min(next_data, next_impedance);
            }
            else
            {
                next = std::max(next_data, next_impedance);   // 有一个是 -1，取另一个
            }
            const qsizetype skip = (next < 0) ? buffer->size() : next;
            buffer->remove(0, skip);
            *dropped_bytes += skip;
            continue;
        }

        // 帧尾必须与帧头配对，否则这一字节处不是真帧
        const quint8 expected_end = is_impedance ? kImpedanceEndByte : kEndByte;
        if (static_cast<quint8>(buffer->at(frame_size - 1)) != expected_end)
        {
            buffer->remove(0, 1);
            ++(*dropped_bytes);
            continue;
        }

        *frame = buffer->left(frame_size);
        buffer->remove(0, frame_size);
        if (kind != nullptr)
        {
            *kind = is_impedance ? FrameKind::Impedance : FrameKind::Data;
        }
        return true;
    }
    return false;
}

// 3 字节大端有符号 24 位整数 → qint32（手工符号扩展）
inline qint32 bytes3_to_int(quint8 b1, quint8 b2, quint8 b3)
{
    qint32 raw = (static_cast<qint32>(b1) << 16)
                 | (static_cast<qint32>(b2) << 8)
                 | static_cast<qint32>(b3);
    if ((raw & 0x00800000) != 0)
    {
        raw |= static_cast<qint32>(0xFF000000);   // 手工符号扩展
    }
    return raw;
}

// 3 字节大端有符号 24 位 ADC 原始值 → 微伏
inline double bytes3_to_microvolt(quint8 b1, quint8 b2, quint8 b3)
{
    return bytes3_to_int(b1, b2, b3) * kMicroVoltPerCount;
}

// 解析一帧阻抗（B0 … D0）里的 16 路阻抗，返回各路的 kΩ 值。
//
// 每路 3 字节大端有符号 24 位，设备给的原始值单位是**欧姆**，换算成 kΩ 由
// kKohmPerOhm 一处决定。原始值 <= 0（未连接的通道会发 0xFFFFFF = -1）记作
// -1.0，由调用方判成「脱落」。
//
// 返回值恒为 kChannelCount 项；帧长不对时返回空数组
inline QVector<double> parse_impedance_kohm(const QByteArray &frame)
{
    QVector<double> values;
    if (frame.size() < frame_size(kChannelCount))
    {
        return values;
    }

    values.reserve(kChannelCount);
    for (int ch = 0; ch < kChannelCount; ++ch)
    {
        const int index = 2 + ch * 3;
        const qint32 raw = bytes3_to_int(static_cast<quint8>(frame.at(index)),
                                         static_cast<quint8>(frame.at(index + 1)),
                                         static_cast<quint8>(frame.at(index + 2)));
        values.append(raw > 0 ? raw * kKohmPerOhm : -1.0);
    }
    return values;
}

} // namespace serial_protocol

#endif // SERIALPROTOCOL_H
