#include "acquisition/rawringbuffer.h"

#include <QMutexLocker>

#include <algorithm>
#include <cstring>

void RawRingBuffer::reset(int channel_count, int sample_rate, int capacity_seconds)
{
    const QMutexLocker locker(&m_mutex);

    m_channels = std::max(1, channel_count);
    m_sample_rate = std::max(1, sample_rate);
    m_capacity = std::max(1, m_sample_rate * std::max(1, capacity_seconds));

    m_data.assign(static_cast<qsizetype>(m_capacity) * m_channels, 0.0f);
    m_timestamps.assign(m_capacity, 0);
    m_head = 0;
    m_filled = 0;
    m_next_sequence_id = 0;
}

void RawRingBuffer::append(const float *values, int frames, int channel_count,
                           qint64 first_timestamp_ns, qint64 period_ns)
{
    // channel_count 是调用方那块数据的通道数，必须与缓冲自身的一致：
    // 下面按 m_channels 做步长取值，若两者不同就是按错的步长越界读。
    // 生产者目前只有 16 通道的采集线程与演示源，所以这是把不变量显式化，
    // 而不是在修一个已发生的错误
    if (values == nullptr || frames <= 0 || m_channels <= 0 || channel_count != m_channels)
    {
        return;
    }

    const QMutexLocker locker(&m_mutex);
    if (m_data.isEmpty())
    {
        // 还没 reset() 过：没有容量可写，直接丢弃而不是就地扩容 ——
        // 就地扩容会在这个线程上做一次可能几十毫秒的分配，而调用方是采集线程
        return;
    }

    for (int i = 0; i < frames; ++i)
    {
        std::memcpy(m_data.data() + static_cast<qsizetype>(m_head) * m_channels,
                    values + static_cast<qsizetype>(i) * m_channels,
                    static_cast<size_t>(m_channels) * sizeof(float));
        m_timestamps[m_head] = first_timestamp_ns + static_cast<qint64>(i) * period_ns;
        m_head = (m_head + 1) % m_capacity;
        if (m_filled < m_capacity)
        {
            ++m_filled;
        }
    }
    m_next_sequence_id += frames;
}

bool RawRingBuffer::snapshot(int max_seconds, SignalChunk *chunk) const
{
    if (chunk == nullptr)
    {
        return false;
    }

    const QMutexLocker locker(&m_mutex);

    const int wanted = std::min(m_filled, std::max(0, max_seconds) * m_sample_rate);
    if (wanted <= 0 || m_channels <= 0)
    {
        return false;
    }

    // 起点算法与显示缓冲一致：从写头往回数 wanted 个槽
    int start = (m_head - wanted) % m_capacity;
    if (start < 0)
    {
        start += m_capacity;
    }

    chunk->channels = m_channels;
    chunk->samples_per_channel = wanted;
    chunk->samples.resize(static_cast<qsizetype>(wanted) * m_channels);
    chunk->first_timestamp_ns = m_timestamps.at(start);
    // 序列号是「相对于环形缓冲起点」的连续编号：算法侧只要求它自洽，
    // 不要求它与实时流的编号一致 —— ASR 参考是一次独立的数据段
    chunk->first_sequence_id = m_next_sequence_id - wanted;

    for (int i = 0; i < wanted; ++i)
    {
        const int slot = (start + i) % m_capacity;
        std::memcpy(chunk->samples.data() + static_cast<qsizetype>(i) * m_channels,
                    m_data.constData() + static_cast<qsizetype>(slot) * m_channels,
                    static_cast<size_t>(m_channels) * sizeof(float));
    }
    return true;
}

double RawRingBuffer::available_seconds() const
{
    const QMutexLocker locker(&m_mutex);
    return m_sample_rate > 0 ? static_cast<double>(m_filled) / m_sample_rate : 0.0;
}

int RawRingBuffer::channel_count() const
{
    const QMutexLocker locker(&m_mutex);
    return m_channels;
}
