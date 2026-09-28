#ifndef SERIALPROTOCOL_H
#define SERIALPROTOCOL_H

#include <QByteArray>
#include <QVector>

#include <QtGlobal>

#include <cmath>

// EEG 采集设备的串口协议。帧格式与全部换算参数照搬 Python 参考实现
// （tms-eeg-client 的 data_thread.py 与 config.py），改协议时两边必须一起改。
//
// 帧结构（frame_size(channel_count) 字节）：
//   [0]        帧头 0xA0
//   [1]        帧号
//   [2..]      N 通道 × 3 字节，大端有符号 24 位 ADC 原始值
//   [末]       帧尾 0xC0
// 帧长 = 1 + 1 + N × 3 + 1，16 通道即 51 字节。
//
// 注意**没有校验和**：只有帧头与帧尾两道闸。所以配错波特率或通道数不会报错，
// 只会让波形变成噪声、丢字节计数一直涨 —— 排查时先看那个数字。
namespace serial_protocol
{

inline constexpr quint8 kStartByte = 0xA0;
inline constexpr quint8 kEndByte = 0xC0;

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
// 阻抗命令当前**没有接线**：协议里帧尾那 6 字节只解出 4 路阻抗、且不带电极名，
// 而界面是 16 行带导联名的列表，两边对不上（详见 parse_impedance_kohm 的说明）。
// 命令字与解析函数保留在这里，等确认了电极映射再接
inline constexpr char kCommandImpedance = 'U';

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
// 帧头对不上时**整段跳过**不含帧头的数据，而不是逐个 remove(0,1)：
// 波特率或通道数配错时每轮读入的几 KB 会被逐字节搬一遍，退化成 O(n²) 的 memmove。
// 帧头对但帧尾不对时只丢一个字节继续找 —— 真帧头可能就藏在后面几个字节里
inline bool take_frame(QByteArray *buffer, int frame_size, qint64 *dropped_bytes,
                       QByteArray *frame)
{
    if (buffer == nullptr || dropped_bytes == nullptr || frame == nullptr || frame_size <= 0)
    {
        return false;
    }

    while (buffer->size() >= frame_size)
    {
        if (static_cast<quint8>(buffer->at(0)) != kStartByte)
        {
            const qsizetype next = buffer->indexOf(static_cast<char>(kStartByte), 1);
            const qsizetype skip = (next < 0) ? buffer->size() : next;
            buffer->remove(0, skip);
            *dropped_bytes += skip;
            continue;
        }
        if (static_cast<quint8>(buffer->at(frame_size - 1)) != kEndByte)
        {
            buffer->remove(0, 1);
            ++(*dropped_bytes);
            continue;
        }

        *frame = buffer->left(frame_size);
        buffer->remove(0, frame_size);
        return true;
    }
    return false;
}

// 3 字节大端有符号 24 位 ADC 原始值 → 微伏
inline double bytes3_to_microvolt(quint8 b1, quint8 b2, quint8 b3)
{
    qint32 raw = (static_cast<qint32>(b1) << 16)
                 | (static_cast<qint32>(b2) << 8)
                 | static_cast<qint32>(b3);
    if ((raw & 0x00800000) != 0)
    {
        raw |= static_cast<qint32>(0xFF000000);   // 手工符号扩展
    }
    return raw * kMicroVoltPerCount;
}

// 协议把 4 路阻抗值放在帧的最后 6 字节。注意这 6 字节与最后两个通道的数据
// 字节是重叠的 —— 只有设备处于阻抗模式时它们才表示阻抗，解析才有意义。
// 返回 4 个值，单位 kΩ，分辨率 0.1。
//
// 当前**未被使用**（采集线程没有接阻抗命令）：界面上的阻抗列表是 16 行带
// 导联名的，而这里一次只给 4 个没有名字的值，且协议里没有任何字段说明
// 「这 4 路对应哪几个电极」。参考实现同样只显示了「阻抗1..阻抗4」四个标签。
// 等确认了设备的电极↔阻抗序号映射再接，否则只能编造一份对应关系
inline QVector<double> parse_impedance_kohm(const QByteArray &frame)
{
    QVector<double> values;
    if (frame.size() < 8)
    {
        return values;
    }

    const int base = frame.size() - 7;
    const auto byte_at = [&frame, base](int offset) {
        return static_cast<quint8>(frame.at(base + offset));
    };
    const quint8 b0 = byte_at(0);
    const quint8 b1 = byte_at(1);
    const quint8 b2 = byte_at(2);
    const quint8 b3 = byte_at(3);
    const quint8 b4 = byte_at(4);
    const quint8 b5 = byte_at(5);

    const int raw[4] = {
        (b0 << 4) | (b1 >> 4),              // 阻抗 1
        ((b1 & 0x0F) << 8) | b2,            // 阻抗 2
        (b3 << 4) | (b4 >> 4),              // 阻抗 3
        ((b4 & 0x0F) << 8) | b5,            // 阻抗 4
    };

    values.reserve(4);
    for (const int value : raw)
    {
        values.append(std::round(value * 0.1 * 10.0) / 10.0);
    }
    return values;
}

} // namespace serial_protocol

#endif // SERIALPROTOCOL_H
