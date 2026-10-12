#include "acquisition/serialcollector.h"

#include "common/eegbinformat.h"
#include "algorithm/pythonengine.h"
#include "acquisition/serialprotocol.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QMutexLocker>
#include <QSerialPort>
#include <QVector>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{

// 单帧最多支持的通道数。固定长度的栈数组（parse_frames 里的 values）
// 依赖这个上限，改动时要一起看
constexpr int kMaxChannels = 16;

// 等待采集线程退出的上限。收尾只涉及一次 flush 与关闭串口，远小于此值
constexpr int kStopTimeoutMs = 5000;

// 一次 waitForReadyRead 的阻塞上限。既决定命令的响应粒度，也决定拔线检测的粒度
constexpr int kPollTimeoutMs = 20;

// 向算法投递样本块的周期（约 30 FPS）。
// 与显示刷新同一个节拍：再快也只是让算法多做几次小块的固定开销
constexpr int kChunkIntervalMs = 33;

// 状态栏刷新周期
constexpr int kStatsIntervalMs = 500;

// 单块样本的时长上限。下游若因为别的原因卡住，这里兜住内存：最多退回
// 「每秒一块」，不会让队列里堆起几百个巨大的样本块
constexpr int kMaxChunkSeconds = 1;

// 落盘缓冲攒到该字节数才真正 write()，避免每帧一次系统调用
constexpr qint64 kFileFlushBytes = 256 * 1024;

// ==================== 二进制格式 ====================
// 头部字段、magic、头长等常量在 eegbinformat.h 里，**与回放端共用同一份**
//（recordingpreview.cpp 读的就是它）。以前这里和那边各写一遍、靠注释约定
//「必须逐字对应」，格式一改就会静默解析出乱码波形。
// 之所以自己拼字节而不走 QDataStream：格式固定且只有这几行，拼出来一眼能看懂
constexpr qint64 kBinaryFrameCountOffset = eegbin::kFrameCountOffset;

void append_u32_le(QByteArray &out, quint32 value)
{
    out.append(static_cast<char>(value & 0xFF));
    out.append(static_cast<char>((value >> 8) & 0xFF));
    out.append(static_cast<char>((value >> 16) & 0xFF));
    out.append(static_cast<char>((value >> 24) & 0xFF));
}

void append_i64_le(QByteArray &out, qint64 value)
{
    const quint64 bits = static_cast<quint64>(value);
    for (int shift = 0; shift < 64; shift += 8)
    {
        out.append(static_cast<char>((bits >> shift) & 0xFF));
    }
}

// 落盘状态。QFile 只在采集线程的 run() 里创建与销毁，见类注释
struct Recorder
{
    QFile file;
    // 收尾时要靠它决定「是不是二进制格式、要不要回填帧数」，
    // 所以 recording_stop() 会把它复位成 None，而不是留给下一次录音
    SerialCollector::SaveFormat format = SerialCollector::SaveFormat::None;
    QByteArray buffer;      // 已攒下、还没 write() 的字节，攒到 kFileFlushBytes 才落盘
    qint64 frames = 0;      // 已写入文件的帧数
    QString path;
    // 还在正常落盘。磁盘满、盘掉线时置 false，此后 recording_write_frame()
    // 直接返回、不再尝试写 —— 每帧重试一次只会把采集循环拖慢
    bool active = false;

    // ---- 升采样（落盘采样率是设备采样率的整数倍时用，如 1000 → 2000）----
    // 设备固定按设备速率出帧，这里在写文件时按线性插值补点，让文件以目标速率
    // 标注与存放。只影响写进文件的数据，采集/算法/显示仍走设备原始速率
    int channels = 0;          // 每帧通道数，插值要逐通道算
    int ratio = 1;             // 输出帧数 / 输入帧数；<=1 表示原样落盘
    bool has_prev = false;     // 已经攒下上一帧、可以插值了
    QVector<float> prev;       // 上一帧样本（插值区间的左端点）
    QVector<float> scratch;    // 插值输出帧的临时缓冲，避免每帧重新分配
    // 已喂进来的输入帧数。状态栏「已存 N 帧」用它，才与「已收 N 帧」可比 ——
    // 升采样后写进文件的帧数是它的 ratio 倍，拿文件帧数去显示会像丢/多了数据
    qint64 source_frames = 0;
};

// 一次采集过程的全部可变状态。在 run() 里建**一份**，从打开串口一直用到关闭。
//
// 之所以要有个结构体，是因为下面几个辅助函数（parse_frames、take_chunk、
// recording_*）都是自由函数：它们改不了 SerialCollector 的成员，也 emit 不了信号，
// 只能通过这个结构体把结果交回采集循环。所以这里有些字段并不是「状态」，
// 而是**跨函数的延迟信号** —— 见 save_failed 的说明
struct RunState
{
    // 串口是字节流，一次 readAll() 拿到的可能是半帧、一帧半、或者好几帧，
    // 所以先攒在这里，再由 parse_frames 按帧长切
    QByteArray rx_buffer;

    // 已解析成 µV、但还没交出去的样本。帧优先交错，与 SignalChunk::samples 同一布局。
    // 攒到 kChunkIntervalMs（约 30 FPS）或满一秒才整块 take_chunk() 走
    QVector<float> chunk_samples;
    int chunk_frames = 0;
    qint64 chunk_first_sequence_id = 0;
    qint64 chunk_first_timestamp_ns = 0;

    // 本段采集的两个计数器，Start 时清零，随 stats_changed 报到状态栏。
    // received_frames 只在 collecting 为真时递增，所以它是「本次采集处理了多少帧」
    qint64 received_frames = 0;
    // 因对不上帧头/帧尾而丢掉的字节数。它是波特率或通道数配错的唯一线索：
    // 配错时不会报错，只会让这个数字一直涨、波形变成噪声。正常应恒为 0
    qint64 dropped_bytes = 0;
    // 设备帧号的跳变次数。只当观察值（见 stats_changed 的说明），不据此丢帧
    qint64 frame_number_skips = 0;
    int last_frame_number = -1;

    // 「设备被要求持续发数据」—— 即处在 Start 与 Stop 命令之间。
    //
    // 注意它**不等于**「正在收帧」：不采集的时候帧照样会进来（Stop 之后设备
    // 未必立刻停发，会有一段尾巴）。所以 parse_frames 里那道 collecting 闸
    // 是必需的：没有它，尾巴上的帧会被当成脑电数据混进波形
    bool collecting = false;

    // 序列号。算法要求 push_block 的 first_sequence_id 严格等于上次 last+1，
    // 所以这里**每个被接受的帧推进 1**，与设备帧号无关（帧号语义未经确认）。
    // Start 时归零：在线会话是在那时建的
    qint64 next_sequence_id = 0;

    // 时间戳的推进规则见 parse_frames 里的说明：不直接跟随墙钟，
    // 而是取 max(墙钟, 上一帧 + 采样周期)，保证严格递增
    qint64 last_timestamp_ns = 0;

    // 单调时钟与墙钟的组合。
    //
    // 时间戳必须用单调时钟推：直接取 QDateTime 的话，系统时间被 NTP 回拨时
    // 会产生重复/倒序的时间戳，算法侧会抛 TIME_SEQUENCE_DISCONTINUITY，
    // 现象是「偶尔在某个时刻报错」，既不复现也无法定位。
    // 加墙钟基准偏移是为了让时间戳仍然对应真实的日历时间，便于与事件、
    // 外部设备记录对齐
    qint64 wall_clock_base_ns = 0;
    QElapsedTimer monotonic_clock;

    // 落盘失败的延迟信号。parse_frames 是自由函数、emit 不了信号，
    // 所以它只把失败记在这里；等回到 run() 的循环里再 emit。
    // 消费完立刻清掉，避免同一个错误每轮循环都弹一次
    bool save_failed = false;
    QString save_error;

    // 最近解析到的一帧阻抗（kΩ，16 路，无效为 -1）。
    // parse_frames 交不出去（它 emit 不了信号、也碰不到成员），所以先放这里，
    // 由 run() 在每轮末尾搬到线程安全的 m_latest_impedance。
    // impedance_updated 是「这一轮解析到过新阻抗帧」的一次性标记
    QVector<double> impedance_kohm;
    bool impedance_updated = false;

    Recorder recorder;
};

// 一次采集里，Start 命令负责把「上一轮的残留」清干净。单列出来是因为
// 哪些字段该清、哪些不该清并不直观：
//   - rx_buffer 要清：里面可能留着上一轮没切完的半截帧，接着解析会拼出假帧
//   - 计数器要清：它们是「本段采集」的统计量
//   - next_sequence_id 要清：在线会话是新建的，序列号必须从 0 重新开始
//   - last_frame_number 要清：设备重新开始发时帧号会从头上数
//   - monotonic_clock **不清**：它是进程级的，跨段保持单调才有意义
//   - recorder 不清：交给 recording_start()，它会先调 recording_stop() 收尾
void reset_for_new_run(RunState &state)
{
    state.chunk_samples.clear();
    state.chunk_frames = 0;
    state.chunk_first_sequence_id = 0;
    state.chunk_first_timestamp_ns = 0;
    state.received_frames = 0;
    state.dropped_bytes = 0;
    state.frame_number_skips = 0;
    state.last_frame_number = -1;
    state.next_sequence_id = 0;
    state.rx_buffer.clear();
}

// ==================== 落盘 ====================
//
// 生命周期由三个函数串起来，都在采集线程里跑：
//   recording_start()       开文件、写文件头
//   recording_write_frame() 每解析出一帧调一次，只是往 buffer 里追加
//   recording_stop()        收尾：flush、回填帧数、关文件
//
// 失败是「单向」的：一旦写不进去就把 recorder.active 置 false，之后
// recording_write_frame 直接返回 true（当作没这回事），采集本身不受影响。
// 落盘失败该不该中断采集的答案是不该 —— 串口上的数据仍有显示与处理价值
//
// write_raw_frame 的前向声明：recording_stop()（升采样补尾帧）在它定义之前就会用到
void write_raw_frame(Recorder &recorder, const float *values, int channel_count);

void recording_flush(Recorder &recorder)
{
    if (recorder.buffer.isEmpty())
    {
        return;
    }
    // 写不进去（磁盘满、盘掉线）就停掉落盘并留下原因。不在这里重试：
    // 每帧重试一次只会把采集循环拖慢
    if (!recorder.file.isOpen()
        || recorder.file.write(recorder.buffer) != recorder.buffer.size())
    {
        recorder.active = false;
    }
    recorder.buffer.clear();
}

// 收尾：flush、回填帧数、关文件。以「文件是否还开着」为准，可重复调用。
// 返回给界面看的摘要（没落盘则为空）
QString recording_stop(Recorder &recorder)
{
    if (!recorder.file.isOpen())
    {
        recorder.active = false;
        recorder.format = SerialCollector::SaveFormat::None;
        recorder.buffer.clear();
        return QString();
    }

    // 升采样：最后一帧没有「下一帧」可插值，到这里按保持（重复）把它的 ratio 个
    // 输出点补满。少了这一步，输出会比输入少一整块、文件尾部缺一小段
    if (recorder.active && recorder.ratio > 1 && recorder.has_prev)
    {
        for (int j = 0; j < recorder.ratio && recorder.active; ++j)
        {
            write_raw_frame(recorder, recorder.prev.constData(), recorder.channels);
        }
    }

    recording_flush(recorder);
    const qint64 frames = recorder.frames;

    // 二进制格式的帧数写在文件头里，收尾时回填，文件才自描述。
    // 写入中途失败过（active 已置 false）就别再回填了，文件本来就不完整
    if (recorder.format == SerialCollector::SaveFormat::Binary && recorder.active
        && recorder.file.seek(kBinaryFrameCountOffset))
    {
        QByteArray tail;
        append_i64_le(tail, frames);
        recorder.file.write(tail);
    }

    const QString path = recorder.path;
    recorder.file.close();
    recorder.active = false;
    recorder.buffer.clear();
    recorder.format = SerialCollector::SaveFormat::None;

    return SerialCollector::tr("已保存 %1 帧到 %2").arg(frames).arg(path);
}

// 打开目标文件并写文件头。save_path 为空或格式为 None 表示不落盘 —— 这不算失败。
// 失败时把原因写进 error 并返回 false
bool recording_start(Recorder &recorder, const SerialCollector::StartRequest &request,
                     int channel_count, int sample_rate, QString *error)
{
    // 保险：上一轮没关干净时先收尾
    recording_stop(recorder);

    // 先回到「原样落盘」的中性状态，避免上一轮的升采样状态残留到这一段
    recorder.ratio = 1;
    recorder.has_prev = false;
    recorder.source_frames = 0;

    if (request.save_path.isEmpty() || request.format == SerialCollector::SaveFormat::None)
    {
        return true;
    }

    // 落盘采样率（见 Recorder 里升采样的说明）：目标必须是设备速率的整数倍
    // 才做升采样，否则一律原样落盘。effective_rate 是文件里该写的采样率
    const int source_rate = std::max(1, sample_rate);
    const int target_rate = request.save_sample_rate > 0 ? request.save_sample_rate : source_rate;
    recorder.ratio = (target_rate > source_rate && target_rate % source_rate == 0)
                         ? target_rate / source_rate
                         : 1;
    const int effective_rate = recorder.ratio > 1 ? target_rate : source_rate;

    recorder.channels = channel_count;
    recorder.prev = QVector<float>(channel_count, 0.0f);
    recorder.scratch.resize(channel_count);

    const QFileInfo info(request.save_path);
    if (!QDir().mkpath(info.absolutePath()))
    {
        *error = SerialCollector::tr("无法创建目录: %1").arg(info.absolutePath());
        return false;
    }

    recorder.file.setFileName(request.save_path);
    if (!recorder.file.open(QIODevice::WriteOnly | QIODevice::Truncate))
    {
        *error = SerialCollector::tr("无法写入 %1：%2")
                     .arg(request.save_path, recorder.file.errorString());
        return false;
    }

    if (request.format == SerialCollector::SaveFormat::Csv)
    {
        QStringList names = request.channel_names;
        while (names.size() < channel_count)
        {
            names.append(QStringLiteral("CH%1").arg(names.size() + 1));
        }
        names = names.mid(0, channel_count);

        // 头部统一用 # 注释，numpy.loadtxt(comments='#') / pandas read_csv(comment='#')
        // 都能直接读，同时人也能看懂
        QByteArray header;
        header += "# EEG 采集记录（单位 uV）\n";
        header += "# 起始时间: "
                  + QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8() + "\n";
        header += "# 采样率: " + QByteArray::number(effective_rate) + " Hz\n";
        header += "# 通道数: " + QByteArray::number(channel_count) + "\n";
        header += "# 通道名: " + names.join(',').toUtf8() + "\n";
        header += names.join(',').toUtf8() + "\n";
        recorder.buffer += header;
    }
    else
    {
        QByteArray header;
        header.append(eegbin::kMagic, int(sizeof(eegbin::kMagic)));
        append_u32_le(header, eegbin::kVersion);
        append_u32_le(header, static_cast<quint32>(channel_count));
        append_u32_le(header, static_cast<quint32>(effective_rate));
        append_u32_le(header, eegbin::kHeaderSize);
        append_i64_le(header, QDateTime::currentMSecsSinceEpoch());
        append_i64_le(header, 0);                          // frame_count，收尾回填
        while (header.size() < static_cast<int>(eegbin::kHeaderSize))
        {
            header.append('\0');
        }
        recorder.buffer += header;
    }

    recorder.format = request.format;
    recorder.frames = 0;
    recorder.path = request.save_path;
    recorder.active = true;
    return true;
}

// 按落盘格式把一帧追加进缓冲。采样率换算（升采样）由调用方在调用它之前完成 ——
// 这一层只负责「一帧怎么落到文件里」，格式分支与攒批/落盘都在这里
void write_raw_frame(Recorder &recorder, const float *values, int channel_count)
{
    if (recorder.format == SerialCollector::SaveFormat::Csv)
    {
        QByteArray line;
        line.reserve(channel_count * 12);
        for (int ch = 0; ch < channel_count; ++ch)
        {
            if (ch > 0)
            {
                line.append(',');
            }
            line.append(QByteArray::number(static_cast<double>(values[ch]), 'f', 6));
        }
        line.append('\n');
        recorder.buffer.append(line);
    }
    else
    {
        // 按内存布局直接落盘：x86-64 是小端，与文件头声明的格式一致
        recorder.buffer.append(reinterpret_cast<const char *>(values),
                               channel_count * static_cast<int>(sizeof(float)));
    }

    ++recorder.frames;
    if (recorder.buffer.size() >= kFileFlushBytes)
    {
        recording_flush(recorder);
    }
}

// 写一帧。返回 false 表示落盘失败（此时 recorder.active 已被置 false，
// 原因留在 recorder.file 的 errorString 里）
//
// 落盘采样率是设备速率的整数倍时在这里做线性插值升采样：设备每送来一帧，
// 就补出 ratio 个输出点。插值要用到「上一帧 → 当前帧」这一段，所以第一帧先攒着，
// 等第二帧到了再一起发；最后一帧的尾块由 recording_stop() 收尾时补上
bool recording_write_frame(Recorder &recorder, const float *values, int channel_count)
{
    if (!recorder.active)
    {
        return true;
    }

    ++recorder.source_frames;

    // 原样落盘：设备速率与落盘速率一致，一帧进一帧出
    if (recorder.ratio <= 1)
    {
        write_raw_frame(recorder, values, channel_count);
        return recorder.active;
    }

    if (!recorder.has_prev)
    {
        std::memcpy(recorder.prev.data(), values,
                    static_cast<size_t>(channel_count) * sizeof(float));
        recorder.has_prev = true;
        return true;
    }

    // 在这一段 [上一帧, 当前帧] 上均匀取 ratio 个点：t=0 就是上一帧，
    // t 越接近 1 越靠近当前帧
    for (int j = 0; j < recorder.ratio && recorder.active; ++j)
    {
        const float t = static_cast<float>(j) / static_cast<float>(recorder.ratio);
        for (int ch = 0; ch < channel_count; ++ch)
        {
            recorder.scratch[ch] = recorder.prev[ch] * (1.0f - t) + values[ch] * t;
        }
        write_raw_frame(recorder, recorder.scratch.constData(), channel_count);
    }
    std::memcpy(recorder.prev.data(), values,
                static_cast<size_t>(channel_count) * sizeof(float));
    return recorder.active;
}

// 切帧并解析。帧头对不上就丢一个字节继续找：设备上电、串口刚打开时缓冲里
// 常有半截帧，逐字节收敛比整体丢弃重来稳
void parse_frames(RunState &state, int frame_size, int channel_count, int sample_rate)
{
    const qint64 sample_period_ns = 1000000000LL / std::max(1, sample_rate);

    QByteArray frame;
    serial_protocol::FrameKind kind = serial_protocol::FrameKind::Data;
    while (serial_protocol::take_frame(&state.rx_buffer, frame_size, &state.dropped_bytes,
                                       &frame, &kind))
    {
        // 阻抗帧（B0…D0）不是脑电数据：解析出 16 路阻抗存下来，就直接跳过 ——
        // 它既不进样本块（否则会当成 µV 混进波形），也不落盘。
        // 放在 collecting 闸之前，是因为扫描时常在采集之中，此时 collecting 为真
        if (kind == serial_protocol::FrameKind::Impedance)
        {
            const QVector<double> values = serial_protocol::parse_impedance_kohm(frame);
            if (!values.isEmpty())
            {
                state.impedance_kohm = values;
                state.impedance_updated = true;
            }
            continue;
        }

        // 帧号只当观察值。协议里没有校验和，帧号既不参与任何运算、语义也未经确认
        // （是否回绕、是否在掉电后归零都不知道），所以不据此丢帧、也不据此声明
        // 数据缺口 —— 误判一次就要白清一次算法的滤波状态与滚动缓存
        const int frame_number = static_cast<quint8>(frame.at(1));
        if (state.collecting && state.last_frame_number >= 0
            && frame_number != (state.last_frame_number + 1) % 256)
        {
            ++state.frame_number_skips;
        }
        state.last_frame_number = frame_number;

        // 固定长度的栈数组：channel_count 已在 run() 开头按 kMaxChannels 校验过，
        // 走到这里必然不超过它。这个不变量跨了函数，改动 run() 的校验时要一起看
        float values[kMaxChannels];
        for (int ch = 0; ch < channel_count; ++ch)
        {
            const int index = 2 + ch * 3;
            values[ch] = static_cast<float>(serial_protocol::bytes3_to_microvolt(
                static_cast<quint8>(frame.at(index)),
                static_cast<quint8>(frame.at(index + 1)),
                static_cast<quint8>(frame.at(index + 2))));
        }

        // 不采集时的帧不是脑电数据（Stop 之后设备还没停发的那一段尾巴），挡在波形之外
        if (!state.collecting)
        {
            continue;
        }

        // 时间戳：取 max(墙钟, 上一帧 + 采样周期)。
        //
        // 不能直接用墙钟：块与块之间解析的先后顺序不保证，后一个块的锚点可能
        // 早于前一个块按周期推出来的末尾，时间戳就退回去了，算法侧会判成
        // 时间序列断裂。也不能只按周期累加：那样会随设备实际速率缓慢漂离墙钟，
        // 跑半小时就差出一秒。取两者的较大值，既单调、又贴着真实时间
        const qint64 now_ns = state.wall_clock_base_ns + state.monotonic_clock.nsecsElapsed();
        const qint64 timestamp_ns =
            state.last_timestamp_ns > 0
                ? std::max(now_ns, state.last_timestamp_ns + sample_period_ns)
                : now_ns;
        state.last_timestamp_ns = timestamp_ns;

        if (state.chunk_frames == 0)
        {
            state.chunk_first_sequence_id = state.next_sequence_id;
            state.chunk_first_timestamp_ns = timestamp_ns;
        }

        const qsizetype offset = state.chunk_samples.size();
        state.chunk_samples.resize(offset + channel_count);
        std::memcpy(state.chunk_samples.data() + offset, values,
                    static_cast<size_t>(channel_count) * sizeof(float));
        ++state.chunk_frames;
        ++state.received_frames;
        ++state.next_sequence_id;

        // ASR 参考用的原始样本不在这里存：那会让同一批数据被采集线程与
        // ChunkSink::deliver() 各写一份，翻倍且时间戳来回跳。写入统一在
        // AcquisitionBridge::deliver() 里做（演示模式也走那条路）
        if (!recording_write_frame(state.recorder, values, channel_count))
        {
            state.save_failed = true;
            state.save_error = SerialCollector::tr("写入文件失败，已停止保存：%1")
                                   .arg(state.recorder.file.errorString());
        }
    }
}

// 把攒下的样本整块取走。用 swap 而不是拷贝：一秒的数据有几十 KB，没必要复制一遍
//
// 注意顺序：samples_per_channel 与两个标量要在 swap **之前**取，
// swap 之后 state.chunk_frames 就该归零了；而 chunk->samples 交给调用方之后
// 就不能再写 —— 采集线程下一轮会往 state.chunk_samples（已换空的）里继续攒
void take_chunk(RunState &state, int channel_count, SignalChunk *chunk)
{
    chunk->channels = channel_count;
    chunk->samples_per_channel = state.chunk_frames;
    chunk->first_sequence_id = state.chunk_first_sequence_id;
    chunk->first_timestamp_ns = state.chunk_first_timestamp_ns;
    chunk->samples.swap(state.chunk_samples);
    state.chunk_frames = 0;
    state.chunk_samples.clear();
}

// 把一块被丢弃的样本并进待声明的缺口。
// 投递失败时要靠它把缺口报全，否则算法只会看到「序列号断裂」，而真正的原因
// （我们主动丢了）被淹没。
//
// already_open 由调用方显式给出，而不是靠比较首尾号猜「这条缺口是不是空的」：
// GapRange 的默认构造是全零，而首个被丢的块完全可能从序列号 0 开始，
// 用 last < first 判断会把它误当成一条已经开着的缺口，首号就永远补不上了
void merge_into_gap(GapRange &gap, const SignalChunk &chunk, int sample_rate,
                    bool already_open)
{
    const qint64 period_ns = 1000000000LL / std::max(1, sample_rate);
    if (!already_open)
    {
        gap.first_missing_sequence_id = chunk.first_sequence_id;
        gap.start_timestamp_ns = chunk.first_timestamp_ns;
    }
    gap.last_missing_sequence_id = chunk.first_sequence_id + chunk.samples_per_channel - 1;
    gap.end_timestamp_ns = chunk.first_timestamp_ns
                           + static_cast<qint64>(chunk.samples_per_channel - 1) * period_ns;
    gap.reason = QStringLiteral("collector_backpressure");
}

} // namespace

SerialCollector::SerialCollector(QObject *parent)
    : QThread(parent)
{
}

SerialCollector::~SerialCollector()
{
    // 必须保证线程停下来再析构：QThread 在运行中被销毁会走
    // qFatal("Destroyed while thread is still running")，那是直接终止进程，
    // 不是「兜底告警」。超时说明收尾卡住了（例如保存目录是个掉线的网络盘），
    // 此时强制终止 —— 丢一段录像好过整个程序崩掉。
    //
    // 这里敢用 terminate() 是因为采集线程没有跨调用的外部资源：
    // 串口与文件都是 run() 的栈上对象，被杀掉只会漏一次 close()。
    // 算法线程**绝不能**这么干（见 pythonworker.cpp 的说明）
    request_stop();
    if (!wait(kStopTimeoutMs))
    {
        qWarning() << "[serialcollector] 采集线程未能在超时内退出，强制终止";
        terminate();
        wait(1000);
    }
}

void SerialCollector::set_config(const Config &config)
{
    m_config = config;
}

void SerialCollector::set_sink(ChunkSink *sink)
{
    m_sink = sink;
}

void SerialCollector::request_stop()
{
    m_stop_requested.store(true, std::memory_order_relaxed);
}

void SerialCollector::post_start(const StartRequest &request)
{
    Command command;
    command.kind = CommandKind::Start;
    command.request = request;

    const QMutexLocker locker(&m_command_mutex);
    m_commands.append(command);
}

void SerialCollector::post_stop()
{
    Command command;
    command.kind = CommandKind::Stop;

    const QMutexLocker locker(&m_command_mutex);
    m_commands.append(command);
}

void SerialCollector::post_impedance_start()
{
    Command command;
    command.kind = CommandKind::ImpedanceStart;

    const QMutexLocker locker(&m_command_mutex);
    m_commands.append(command);
}

void SerialCollector::post_impedance_stop()
{
    Command command;
    command.kind = CommandKind::ImpedanceStop;

    const QMutexLocker locker(&m_command_mutex);
    m_commands.append(command);
}

QVector<double> SerialCollector::latest_impedance_kohm() const
{
    const QMutexLocker locker(&m_impedance_mutex);
    return m_latest_impedance;
}

// 采集线程主体：开串口 → 循环（执行命令 / 收字节 / 切帧解析 / 按节拍投递）
// → 收尾关串口。整条命脉都在这一个函数里。
//
// 一条必须守住的约定：**任何一条退出路径都得给界面一个交代** —— 要么
// port_open_failed()，要么 port_closed()。界面靠这两个信号复位「已打开/采集中」
// 两个标志，少发一个，界面就会永远卡在「正在打开…」上，按钮再也点不动。
// 所以这里不能有中途 return 的旁路（除了开头参数校验那两处，它们都在
// 打开串口之前），循环只能 break，让控制流落到下面的收尾段
void SerialCollector::run()
{
    const int channel_count = m_config.channel_count;
    const int frame_size = serial_protocol::frame_size(channel_count);
    if (frame_size <= 0 || channel_count > kMaxChannels)
    {
        emit port_open_failed(tr("不支持的通道数: %1").arg(channel_count));
        return;
    }

    QSerialPort port;
    port.setPortName(m_config.port_name);
    port.setBaudRate(m_config.baud_rate);
    port.setDataBits(QSerialPort::Data8);
    port.setParity(QSerialPort::NoParity);
    port.setStopBits(QSerialPort::OneStop);
    port.setFlowControl(QSerialPort::NoFlowControl);

    if (!port.open(QIODevice::ReadWrite))
    {
        emit port_open_failed(
            tr("打开串口 %1 失败：%2").arg(m_config.port_name, port.errorString()));
        return;
    }
    // 丢掉打开瞬间残留在驱动缓冲里的半截数据，免得开头解析出一串假帧
    port.clear(QSerialPort::AllDirections);
    emit port_opened(tr("串口 %1 已打开（%2 baud，%3 通道）")
                         .arg(m_config.port_name)
                         .arg(m_config.baud_rate)
                         .arg(channel_count));

    RunState state;
    state.wall_clock_base_ns = QDateTime::currentMSecsSinceEpoch() * 1000000LL;
    state.monotonic_clock.start();

    // 单块样本的帧数上限。下游若因为别的原因卡住不消化，靠它兜住内存：
    // 攒满就强制发一块，每秒最多一块，不会让队列里堆起几百个巨大的样本块
    const int chunk_frame_limit = std::max(1, m_config.sample_rate * kMaxChunkSeconds);

    // 投递失败时累计的缺口。见下面投递那一段：队列满**不能静默丢弃**
    GapRange pending_gap;
    bool gap_pending = false;

    QElapsedTimer chunk_timer;
    QElapsedTimer stats_timer;
    chunk_timer.start();
    stats_timer.start();

    // ==================== 采集主循环 ====================
    //
    // 一轮做四件事，顺序不能换：
    //   1) 先执行 GUI 投递过来的命令。Start/Stop 必须先落地再解析这一轮收到的
    //      字节：反过来会漏掉开头的数据（Start 晚一拍，这一轮解析出的帧因为
    //      collecting 还是假而被丢弃）或多收一段尾巴（Stop 晚一拍）
    //   2) 等数据。waitForReadyRead 是阻塞等待而不是忙等，超时上限
    //      kPollTimeoutMs 同时也是拔线检测与命令响应的粒度
    //   3) 切帧、解析、落盘
    //   4) 按节拍把攒好的数据交给 sink，并刷新状态栏
    while (!m_stop_requested.load(std::memory_order_relaxed))
    {
        // ---- 1) 执行 GUI 线程投递过来的命令 ----
        QVector<Command> commands;
        {
            const QMutexLocker locker(&m_command_mutex);
            commands.swap(m_commands);
        }
        for (const Command &command : commands)
        {
            switch (command.kind)
            {
            case CommandKind::Start:
            {
                reset_for_new_run(state);
                // 上一段的缺口不该跟着新会话：算法那边是全新会话，没有断口
                gap_pending = false;
                pending_gap = GapRange();

                QString error;
                if (recording_start(state.recorder, command.request, channel_count,
                                    m_config.sample_rate, &error))
                {
                    if (state.recorder.active)
                    {
                        emit recording_changed(true, state.recorder.path);
                    }
                }
                else
                {
                    // 落盘失败不阻止采集：先采着，用户改好路径再重开。
                    // 话得说全，否则用户看到「采集中」会以为数据存下来了
                    emit failed(error + tr("（采集继续，但这一段不会保存）"));
                }

                state.collecting = true;
                if (port.write(QByteArray(1, serial_protocol::kCommandStart)) < 0)
                {
                    emit failed(tr("发送开始命令失败：%1").arg(port.errorString()));
                }
                // 与落盘成败无关：数据在采，界面就该显示在采
                emit collecting_changed(true);
                emit status_message(tr("已发送开始采集命令"));
                break;
            }
            case CommandKind::Stop:
            {
                if (state.collecting)
                {
                    if (port.write(QByteArray(1, serial_protocol::kCommandStop)) < 0)
                    {
                        emit failed(tr("发送停止命令失败：%1").arg(port.errorString()));
                    }
                    state.collecting = false;
                }
                if (state.chunk_frames > 0)
                {
                    // 不足一块的尾巴也要交出去，否则停止时波形会缺一小段
                    SignalChunk chunk;
                    take_chunk(state, channel_count, &chunk);
                    if (m_sink != nullptr && !m_sink->deliver(chunk))
                    {
                        merge_into_gap(pending_gap, chunk, m_config.sample_rate, gap_pending);
                        gap_pending = true;
                    }
                }
                // 停下来了，缺口到此为止，尽快声明掉让算法知道数据断了
                if (gap_pending && m_sink != nullptr && m_sink->deliver_gap(pending_gap))
                {
                    gap_pending = false;
                }

                // 状态栏「已存 N 帧」用输入帧数：升采样后文件里的帧数是它的 ratio 倍，
                // 拿文件帧数去显示会让人以为存进去的数据多了一倍
                const qint64 saved_frames = state.recorder.source_frames;
                const QString summary = recording_stop(state.recorder);
                if (!summary.isEmpty())
                {
                    emit status_message(summary);
                }
                emit collecting_changed(false);
                emit recording_changed(false, QString());
                emit stats_changed(state.received_frames, saved_frames, state.dropped_bytes,
                                   state.frame_number_skips);
                emit status_message(tr("已发送停止采集命令"));
                break;
            }
            case CommandKind::Raw:
            {
                if (port.write(command.payload) < 0)
                {
                    emit failed(tr("发送原始命令失败：%1").arg(port.errorString()));
                }
                break;
            }
            case CommandKind::ImpedanceStart:
            {
                // 清掉上一次扫描的残留：这次若没收到新帧，界面应报「未收到阻抗数据」，
                // 而不是拿到上一次的旧值
                {
                    const QMutexLocker locker(&m_impedance_mutex);
                    m_latest_impedance.clear();
                }
                if (port.write(QByteArray(1, serial_protocol::kCommandImpedanceStart)) < 0)
                {
                    emit failed(tr("发送阻抗扫描命令失败：%1").arg(port.errorString()));
                }
                break;
            }
            case CommandKind::ImpedanceStop:
            {
                // 's' 让设备停发（通常连常规数据帧一起停）。若当时正在采集，
                // 立刻补发 'b' 把常规数据流接回来，否则界面会一直收不到脑电数据
                if (port.write(QByteArray(1, serial_protocol::kCommandStop)) < 0)
                {
                    emit failed(tr("发送阻抗停止命令失败：%1").arg(port.errorString()));
                }
                if (state.collecting)
                {
                    if (port.write(QByteArray(1, serial_protocol::kCommandStart)) < 0)
                    {
                        emit failed(tr("恢复采集的命令发送失败：%1").arg(port.errorString()));
                    }
                }
                break;
            }
            }
        }

        // ---- 2) 收数据 ----
        // waitForReadyRead 返回 false 绝大多数情况只是「这段时间没数据」，属正常，
        // 所以不能拿它当出错处理。只有 error() 变成 ResourceError 才意味着
        // 串口真的没了（拔线、设备掉电、驱动把设备移除），那时再等没有意义
        if (port.waitForReadyRead(kPollTimeoutMs))
        {
            state.rx_buffer.append(port.readAll());
        }
        else if (port.error() == QSerialPort::ResourceError)
        {
            emit failed(tr("串口异常断开：%1").arg(port.errorString()));
            break;
        }

        // ---- 3) 切帧、解析、落盘 ----
        parse_frames(state, frame_size, channel_count, m_config.sample_rate);

        // 解析到新阻抗帧就搬到线程安全的快照里，供 GUI 线程读取
        if (state.impedance_updated)
        {
            state.impedance_updated = false;
            const QMutexLocker locker(&m_impedance_mutex);
            m_latest_impedance = state.impedance_kohm;
        }

        if (state.save_failed)
        {
            state.save_failed = false;
            emit failed(state.save_error);
            // 只报「不再写文件」，**不**发 collecting_changed(false)：
            // 采集本身继续，串口上的数据仍然有显示、算法与地形图的价值。
            // 这里若把采集状态一起关掉，界面会在数据照常流动的同时
            // 停止查询地形图与频谱
            emit recording_changed(false, QString());
        }

        // ---- 4) 按节拍交给下游 ----
        if (chunk_timer.elapsed() >= kChunkIntervalMs
            || state.chunk_frames >= chunk_frame_limit)
        {
            if (state.chunk_frames > 0 && m_sink != nullptr)
            {
                SignalChunk chunk;
                take_chunk(state, channel_count, &chunk);

                // 队列满**不能静默丢弃**：下一次 push_block 的 first_sequence_id
                // 一旦接不上，算法只会看到「序列号断裂」并打 WARNING（还附带
                // 一次滤波状态与滚动缓存的清空），而真正的原因（我们主动丢了）
                // 反而被淹没。正确做法是把丢掉的范围显式声明成缺口，
                // 并让序列号跳过它 —— 这样 notify_gap 与 seq 编号说的是同一件事。
                //
                // 缺口的声明必须排在它后面那块数据**之前**（两者走同一条队列）
                bool accounted = false;
                if (gap_pending && m_sink->deliver_gap(pending_gap))
                {
                    // 补上之前欠的那条声明，腾出队列空间
                    gap_pending = false;
                }
                if (!gap_pending && m_sink->deliver(chunk))
                {
                    accounted = true;
                }
                if (!accounted)
                {
                    // 没送出去（队列仍满，或刚腾出来又被这一块塞满）：并进缺口，下一轮再试
                    merge_into_gap(pending_gap, chunk, m_config.sample_rate, gap_pending);
                    gap_pending = true;
                }
            }
            else if (state.chunk_frames > 0 && m_sink == nullptr)
            {
                // 没有消费者（还没接算法线程）：直接丢，别让内存无限涨
                state.chunk_samples.clear();
                state.chunk_frames = 0;
            }

            chunk_timer.restart();
        }

        if (stats_timer.elapsed() >= kStatsIntervalMs)
        {
            emit stats_changed(state.received_frames, state.recorder.frames,
                               state.dropped_bytes, state.frame_number_skips);
            stats_timer.restart();
        }
    }

    // ---- 收尾：先让设备停，再把文件与串口关干净 ----
    //
    // 顺序有两层讲究：
    //   - 先停设备再关串口。设备收到 's' 才会停止上发，否则它会一直发到断电，
    //     下一轮打开串口时开头就是一堆上一轮的残留字节
    //   - waitForBytesWritten 不能省。这里是采集线程，线程里没有事件循环，
    //     不能指望「控制权回到事件循环时数据自然发出去」；不显式等一次，
    //     关串口可能抢在这一个字节真正发出去之前
    if (state.collecting)
    {
        if (port.write(QByteArray(1, serial_protocol::kCommandStop)) < 0)
        {
            emit failed(tr("收尾时发送停止命令失败：%1").arg(port.errorString()));
        }
        port.waitForBytesWritten(kPollTimeoutMs);
        state.collecting = false;
    }
    if (state.chunk_frames > 0 && m_sink != nullptr)
    {
        SignalChunk chunk;
        take_chunk(state, channel_count, &chunk);
        if (!m_sink->deliver(chunk))
        {
            merge_into_gap(pending_gap, chunk, m_config.sample_rate, gap_pending);
            gap_pending = true;
        }
    }
    if (gap_pending && m_sink != nullptr)
    {
        // 尽力声明。失败也不再等：采集线程正在退出，算法侧随后会收到会话关闭
        m_sink->deliver_gap(pending_gap);
    }
    emit stats_changed(state.received_frames, state.recorder.frames, state.dropped_bytes,
                       state.frame_number_skips);

    const QString summary = recording_stop(state.recorder);
    if (!summary.isEmpty())
    {
        emit status_message(summary);
    }
    // 无论因为什么退出（用户关闭、拔线掉电），都要让界面知道采集已经停了，
    // 否则它会一直显示「已打开/采集中」，按钮状态再也回不来
    emit collecting_changed(false);
    emit recording_changed(false, QString());
    emit port_closed(tr("串口 %1 已关闭").arg(m_config.port_name));

    // QSerialPort::flush() 是「把内部写缓冲尽量推给串口」，不是丢弃缓冲
    // （与 C 的 fflush 同名但语义不同，别搞反）。这里补一次是兜底：
    // 上面若有哪次 port.write() 还没发干净，赶在 close() 之前送出去。
    // 必须在 close() 之前调 —— 串口关掉后 flush 会直接返回 false 并置 NotOpenError
    port.flush();
    port.close();
}

// ==================== 采集链路自检 ====================

namespace
{

int g_serial_selfcheck_failures = 0;

void check_serial(bool condition, const QString &what)
{
    if (condition)
    {
        qInfo().noquote() << "  [通过]" << what;
        return;
    }
    ++g_serial_selfcheck_failures;
    qWarning().noquote() << "  [失败]" << what;
}

// 按协议拼一帧。raw_values 是每个通道的 24 位原始 ADC 值（有符号）
QByteArray make_test_frame(quint8 frame_number, const QVector<qint32> &raw_values)
{
    QByteArray frame;
    frame.append(static_cast<char>(serial_protocol::kStartByte));
    frame.append(static_cast<char>(frame_number));
    for (const qint32 raw : raw_values)
    {
        frame.append(static_cast<char>((raw >> 16) & 0xFF));
        frame.append(static_cast<char>((raw >> 8) & 0xFF));
        frame.append(static_cast<char>(raw & 0xFF));
    }
    frame.append(static_cast<char>(serial_protocol::kEndByte));
    return frame;
}

bool nearly(double a, double b, double tolerance = 1e-6)
{
    return std::fabs(a - b) <= tolerance;
}

} // namespace

int run_serial_selfcheck()
{
    install_console_message_handler();

    qInfo().noquote() << "== 串口协议自检 ==";

    // ---- 帧长 ----
    const int frame_size = serial_protocol::frame_size(serial_protocol::kChannelCount);
    check_serial(frame_size == 51,
                 QStringLiteral("16 通道帧长 = 1 + 1 + 16×3 + 1 = 51（实际 %1）").arg(frame_size));

    // ---- 换算系数 ----
    // ADS1299：4.5 V 参考、增益 8、24 位（满量程 2^23-1）
    const double expected_uv_per_count = 4.5 / 8388607.0 / 8.0 * 1000000.0;
    check_serial(nearly(serial_protocol::kMicroVoltPerCount, expected_uv_per_count, 1e-12),
                 QStringLiteral("µV/count = %1（期望 %2）")
                     .arg(serial_protocol::kMicroVoltPerCount, 0, 'f', 12)
                     .arg(expected_uv_per_count, 0, 'f', 12));

    // 正满量程、负满量程、-1（最小负步进）
    const double full_scale = serial_protocol::bytes3_to_microvolt(0x7F, 0xFF, 0xFF);
    check_serial(nearly(full_scale, 562500.0, 0.5),
                 QStringLiteral("正满量程 = +562500 µV（实际 %1）").arg(full_scale, 0, 'f', 3));

    const double negative_one = serial_protocol::bytes3_to_microvolt(0xFF, 0xFF, 0xFF);
    check_serial(nearly(negative_one, -serial_protocol::kMicroVoltPerCount, 1e-9),
                 QStringLiteral("全 0xFF 解出 -1 count（实际 %1 µV）").arg(negative_one, 0, 'f', 9));

    // 符号位在 bit23：0x80 0x00 0x00 应是最大负数，不是 +8388608
    const double min_value = serial_protocol::bytes3_to_microvolt(0x80, 0x00, 0x00);
    check_serial(nearly(min_value, -8388608.0 * serial_protocol::kMicroVoltPerCount, 1e-6),
                 QStringLiteral("0x800000 解出 -8388608 count（实际 %1 µV）").arg(min_value, 0, 'f', 3));

    // ---- 切帧：干净的一帧 ----
    {
        QVector<qint32> raw;
        raw.fill(0, serial_protocol::kChannelCount);
        raw[0] = 1000;
        raw[15] = -1000;
        QByteArray buffer = make_test_frame(7, raw);
        QByteArray frame;
        qint64 dropped = 0;
        const bool taken = serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame);
        check_serial(taken && buffer.isEmpty() && dropped == 0,
                     QStringLiteral("干净的一帧被完整取出，缓冲区清空"));
        check_serial(frame.size() == frame_size
                         && static_cast<quint8>(frame.at(1)) == 7
                         && nearly(serial_protocol::bytes3_to_microvolt(
                                       static_cast<quint8>(frame.at(2)),
                                       static_cast<quint8>(frame.at(3)),
                                       static_cast<quint8>(frame.at(4))),
                                   1000.0 * serial_protocol::kMicroVoltPerCount, 1e-9),
                     QStringLiteral("帧号与 CH1 的值解析正确"));
    }

    // ---- 切帧：前面有垃圾字节 ----
    {
        QVector<qint32> raw;
        raw.fill(0, serial_protocol::kChannelCount);
        QByteArray buffer = QByteArray::fromHex("11223344") + make_test_frame(1, raw);
        QByteArray frame;
        qint64 dropped = 0;
        const bool taken = serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame);
        check_serial(taken && buffer.isEmpty() && dropped == 4,
                     QStringLiteral("前置垃圾被跳过并计入 dropped_bytes（实际 %1）").arg(dropped));
    }

    // ---- 切帧：帧尾错位，要能重新同步 ----
    {
        QVector<qint32> raw;
        raw.fill(0, serial_protocol::kChannelCount);
        QByteArray good = make_test_frame(1, raw);
        // 造一个「帧头对但帧尾不对」的帧：把最后一字节改掉，
        // 后面再接一帧完好的 —— 切帧必须丢掉错的那一帧并找回后一帧
        QByteArray broken = good;
        broken[broken.size() - 1] = static_cast<char>(0x00);
        QByteArray buffer = broken + good;

        QByteArray frame;
        qint64 dropped = 0;
        const bool taken = serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame);
        check_serial(taken && dropped > 0,
                     QStringLiteral("帧尾错位时重新同步成功（丢弃 %1 字节）").arg(dropped));
        // 找回来的必须是后面那一帧完好的
        check_serial(frame == good, QStringLiteral("重新同步后取到的是完好的那一帧"));
    }

    // ---- 切帧：半个帧要留在缓冲区里 ----
    {
        QVector<qint32> raw;
        raw.fill(0, serial_protocol::kChannelCount);
        QByteArray whole = make_test_frame(1, raw);
        QByteArray buffer = whole.left(frame_size - 10);
        const QByteArray before = buffer;
        QByteArray frame;
        qint64 dropped = 0;
        const bool taken = serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame);
        check_serial(!taken && buffer == before && dropped == 0,
                     QStringLiteral("半个帧不被消费，原样留在缓冲区里"));

        // 剩下那 10 个字节到了之后应当立刻能切出来
        buffer.append(whole.right(10));
        const bool taken_now = serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame);
        check_serial(taken_now && buffer.isEmpty() && frame == whole,
                     QStringLiteral("补足后立刻切出完整的一帧"));
    }

    // ---- 阻抗帧：切帧要认 B0…D0，数据帧仍认 A0…C0 ----
    {
        // 数据帧（A0…C0）要被认成 FrameKind::Data，别被阻抗帧的引入带偏
        QVector<qint32> raw;
        raw.fill(0, serial_protocol::kChannelCount);
        QByteArray buffer = make_test_frame(1, raw);
        QByteArray frame;
        serial_protocol::FrameKind kind = serial_protocol::FrameKind::Impedance;
        qint64 dropped = 0;
        const bool taken =
            serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame, &kind);
        check_serial(taken && kind == serial_protocol::FrameKind::Data,
                     QStringLiteral("A0…C0 仍被识别为数据帧"));
    }

    {
        // 真实样例帧：B0 起始、D0 结尾，16 路阻抗（单位 Ω，0xFFFFFF = -1 未连接）
        const QByteArray impedance = QByteArray::fromHex(
            "B007001450000C4E0030700022C40055F000125C003B6000189C0010040016A800238C000CE4006978FFFFFF001C20002A30D0");
        check_serial(impedance.size() == frame_size,
                     QStringLiteral("阻抗帧长 = %1（实际 %2）")
                         .arg(frame_size).arg(impedance.size()));

        QByteArray buffer = impedance;
        QByteArray frame;
        serial_protocol::FrameKind kind = serial_protocol::FrameKind::Data;
        qint64 dropped = 0;
        const bool taken =
            serial_protocol::take_frame(&buffer, frame_size, &dropped, &frame, &kind);
        check_serial(taken && buffer.isEmpty() && frame == impedance && dropped == 0
                         && kind == serial_protocol::FrameKind::Impedance,
                     QStringLiteral("B0…D0 被识别为阻抗帧并完整取出"));

        // 手算：每路 3 字节大端有符号 24 位 Ω ÷ 1000 → kΩ；0xFFFFFF → -1（未连接）
        const QVector<double> expected{5.2,  3.15, 12.4, 8.9, 22.0, 4.7,  15.2, 6.3,
                                       4.1,  5.8,  9.1,  3.3, 27.0, -1.0, 7.2,  10.8};
        const QVector<double> kohm = serial_protocol::parse_impedance_kohm(frame);
        bool all_ok = (kohm.size() == expected.size());
        if (all_ok)
        {
            for (int i = 0; i < kohm.size(); ++i)
            {
                if (!nearly(kohm.at(i), expected.at(i), 1e-9))
                {
                    all_ok = false;
                    break;
                }
            }
        }
        check_serial(all_ok, QStringLiteral("样例阻抗帧解析出 16 路 kΩ 值与手算一致"));
    }

    if (g_serial_selfcheck_failures == 0)
    {
        qInfo().noquote() << "== 串口协议自检全部通过 ==";
        return 0;
    }
    qWarning().noquote()
        << QStringLiteral("== 串口协议自检失败 %1 项 ==").arg(g_serial_selfcheck_failures);
    return 1;
}
