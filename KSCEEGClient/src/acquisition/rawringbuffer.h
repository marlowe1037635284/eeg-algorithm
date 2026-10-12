#ifndef RAWRINGBUFFER_H
#define RAWRINGBUFFER_H

#include <QMutex>
#include <QVector>

#include "common/eegtypes.h"

// 原始样本的环形缓冲，供 ASR 参考拟合取数。
//
// 为什么需要它：接口规定 ASR 开启前必须先用 60~180 秒原始数据调
// set_asr_reference()，而 C++ 侧除此之外没有任何地方会保留整段原始数据
// （显示缓冲只留 30 秒，且喂进去的是**处理过**的数据）。没有这份缓冲，
// 用户每改一次前置滤波就得手动重采三分钟。
//
// 为什么由采集线程写、别的线程读：采集线程是唯一看到每一帧的地方，
// 让数据绕一圈回到 GUI 再存进去，中间任何一次「界面跟不上就丢块」
// 都会在参考数据里留个洞，而 ASR 拟合对洞很敏感。直接在这里存，
// 路径最短，也不受显示节奏影响。
//
// 锁的粒度：写一次是 channel_count 个 float（16 通道 64 字节），
// 读一次最多 180 秒（约 11 MB）。读很少发生（只在用户开启 ASR 时），
// 所以用一把普通的互斥量就够，不必上读写锁。
class RawRingBuffer
{
public:
    RawRingBuffer() = default;

    // 按新的通道数重建。容量按秒数算：180 秒 × 1000 Hz × 16 通道 × 4 字节 ≈ 11.5 MB
    void reset(int channel_count, int sample_rate, int capacity_seconds);

    // 追加若干帧（交错布局 values[i * channel_count + ch]，单位 µV）。
    // channel_count 必须与 reset() 时的一致，否则整块丢弃（步长对不上会越界读）。
    // 时间戳逐个给出：块内按采样周期等距展开，块与块之间可能有真实的空洞
    void append(const float *values, int frames, int channel_count, qint64 first_timestamp_ns,
                qint64 period_ns);

    // 取最近 max_seconds 秒（不足则取全部）。返回的 chunk 是交错布局、
    // 可直接交给 pytypes::to_py_values()。数据为空时返回 false
    bool snapshot(int max_seconds, SignalChunk *chunk) const;

    double available_seconds() const;
    int channel_count() const;

private:
    mutable QMutex m_mutex;
    QVector<float> m_data;            // 环形，交错，容量 = m_capacity * m_channels
    QVector<qint64> m_timestamps;     // 环形，每个样本槽一个时间戳（长度 = m_capacity）
    int m_channels = 0;
    int m_sample_rate = 1;
    int m_capacity = 0;               // 每个通道能存多少个样本
    int m_head = 0;                   // 下一个写入的样本槽
    int m_filled = 0;                 // 已填入的样本数（封顶 m_capacity）
    qint64 m_next_sequence_id = 0;    // 下一个写入样本的序列号，用于快照时对齐
};

#endif // RAWRINGBUFFER_H
