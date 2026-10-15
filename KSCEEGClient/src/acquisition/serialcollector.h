#ifndef SERIALCOLLECTOR_H
#define SERIALCOLLECTOR_H

#include <QByteArray>
#include <QMutex>
#include <QString>
#include <QStringList>
#include <QThread>
#include <QVector>
#include <QtGlobal>

#include <atomic>

#include "common/eegtypes.h"

// 数据块的消费者。采集线程不关心谁在消费、也不关心有几个 ——
// 它只按返回值决定「这一块算不算送出去了」。
//
// 之所以不用信号槽：信号发射没有返回值，而队满时必须能显式告知采集线程
// 「我丢了 seq X..Y」。那条信息只有走返回值才拿得到，而它正是数据缺口
// 记账的依据（见 SerialCollector 里投递那一段）。
class ChunkSink
{
public:
    virtual ~ChunkSink() = default;

    // 送出一块样本。返回 false 表示这一块没有被接收（队列满），
    // 调用方负责把它记成数据缺口
    virtual bool deliver(const SignalChunk &chunk) = 0;

    // 声明一段缺口。必须与 deliver() 走同一条队列，否则声明会跑到
    // 它后面那块数据之后，算法侧看到的就是「先断后补」
    virtual bool deliver_gap(const GapRange &gap) = 0;
};

// 串口采集线程：打开串口、收字节、按协议切帧、解析成 µV、落盘，
// 并把样本块交给 ChunkSink。
//
// 为什么单独开线程：串口读取与文件写入都是外部 IO，放在 GUI 线程上，
// 一次驱动或磁盘抖动就会直接卡住界面。这里用 waitForReadyRead 阻塞等待数据
// （不是忙等），有数据立刻返回，所以命令队列的响应延迟也被压在一次等待之内。
//
// 线程约定沿用参考实现：线程内创建的 Qt 对象全部在 run() 里析构，保证
// 「创建线程 == 销毁线程」；跨线程只通过队列信号回传纯数据。
class SerialCollector : public QThread
{
    Q_OBJECT

public:
    // 落盘格式。Csv 便于人工查看，numpy/pandas 能直接读；
    // Binary 体积小、无格式化开销，文件头自带元信息（默认用这个）
    enum class SaveFormat
    {
        None = 0,
        Csv = 1,
        Binary = 2
    };

    struct Config
    {
        QString port_name;
        int baud_rate = 921600;
        int channel_count = 16;
        int sample_rate = 1000;
    };

    struct StartRequest
    {
        QString save_path;                    // 空表示不落盘
        SaveFormat format = SaveFormat::None;
        QStringList channel_names;            // 只用于 CSV 表头，可为空
        // 落盘采样率。设备固定以 Config::sample_rate 出帧，这里若设成它的**整数倍**
        //（如设备的 1000 设成 2000），写文件时按线性插值升采样，让记录文件以这个
        // 速率标注与存放。只影响写进文件的数据，采集/算法/显示都仍按设备原始速率。
        // 0 或缺省表示与设备一致（不重采样）
        int save_sample_rate = 0;
    };

    explicit SerialCollector(QObject *parent = nullptr);
    ~SerialCollector() override;

    // 以下三项都必须在 start() 之前调用；线程启动后只读，不再加锁
    void set_config(const Config &config);
    // 算法侧的数据块消费者。所有权不在采集线程，调用方必须保证它比线程活得久
    void set_sink(ChunkSink *sink);

    // 请求退出采集循环。线程会在下一轮循环（最多一次 waitForReadyRead 超时）后收尾
    void request_stop();

    // 下面两个由 GUI 线程调用，内部加锁投递，采集循环会取走执行
    void post_start(const StartRequest &request);
    void post_stop();

    // 阻抗扫描：开始/停止设备上传阻抗帧（发 'Z' / 's'）。
    // 停止时会顺带用 'b' 把常规数据流接回来（若当时正在采集）
    void post_impedance_start();
    void post_impedance_stop();

    // 最近一帧阻抗解析出的 16 路 kΩ（无效通道为 -1）。还没收到过任何阻抗帧时为空数组。
    // 线程安全：采集线程写、GUI 线程读，内部加锁
    QVector<double> latest_impedance_kohm() const;

    // 取 ASR 参考数据请直接用 RawRingBuffer::snapshot()：缓冲本身就是线程安全的，
    // 这里不再转发一层 —— 采集器会在每次换串口时被销毁重建，
    // 谁若拿了它的指针去取数据，中途换串口就会悬空

signals:
    void port_opened(const QString &message);
    void port_open_failed(const QString &message);
    // 采集线程结束、串口已经关掉。除了用户主动「关闭串口」之外，拔线/掉电
    // 也会走到这里，界面必须靠它把「已打开/采集中」复位，否则会卡在
    // 线程已死、界面还显示在采的状态里
    void port_closed(const QString &message);
    // frame_number_skips 是设备帧号的跳变次数。协议里没有校验和，帧号也不参与
    // 任何运算，所以它只当观察值：与 dropped_bytes 一起看，能区分「设备漏发」
    // 与「我们配错了波特率」。不据此丢帧，也不据此声明数据缺口 ——
    // 帧号语义未经确认，误判会白清一次算法的滤波状态
    void stats_changed(qint64 received_frames, qint64 saved_frames, qint64 dropped_bytes,
                       qint64 frame_number_skips);
    void status_message(const QString &message);
    void failed(const QString &message);
    // 「设备失去连接」：拔线 / 掉电 / 驱动把设备移除时才发。两条判据：
    //   1) 串口报 ResourceError（驱动明确说设备没了）
    //   2) 采集中连续 kDataStallTimeoutMs 收不到任何字节（串口还好、只是不再来数据 ——
    //      设备侧那条连接线被拔就属于这种，驱动不会报错）
    // 必须与 failed() 分开 —— failed 还会用于落盘失败、命令发送失败这些
    // 「采集仍在继续」的情形，界面不该为它们弹断连警示框
    void device_lost(const QString &message);
    // 「正在采集」。它**只**由 Start / Stop 命令决定，与落盘成败无关。
    //
    // 必须与 recording_changed 分开：落盘失败（目录只读、网络盘掉线）时采集是
    // 继续的，如果界面拿「落盘成功」当采集状态的代理，就会在数据照常进来的时候
    // 认为「没在采集」—— 地形图与频谱的定时查询会被一并关掉，而界面上显示的
    // 是「采集中」，两者对不上且极难排查
    void collecting_changed(bool collecting);
    // 「正在写文件」。file_path 为空表示这一段没有落盘
    void recording_changed(bool recording, const QString &file_path);

protected:
    void run() override;

private:
    enum class CommandKind
    {
        Start,
        Stop,
        Raw,
        ImpedanceStart,
        ImpedanceStop
    };

    struct Command
    {
        CommandKind kind = CommandKind::Raw;
        QByteArray payload;
        StartRequest request;
    };

    Config m_config;
    ChunkSink *m_sink = nullptr;

    mutable QMutex m_command_mutex;
    QVector<Command> m_commands;

    // 最近一帧阻抗（kΩ，16 路，无效为 -1）。采集线程写、GUI 线程读，用锁保护
    mutable QMutex m_impedance_mutex;
    QVector<double> m_latest_impedance;

    std::atomic<bool> m_stop_requested{false};
};

// 采集链路的自检：协议换算、帧长、切帧与重新同步。
//
// 为什么必须做：协议**没有校验和**，换算系数抄错一位、帧长算错一个字节，
// 都不会报任何错 —— 表现只是「波形幅度整体偏了」或「波形是噪声」，
// 而这种错在界面上看很难与「设备没接好」区分开。这里用合成字节流把
// 每一处换算钉死，接真机之前先保证这一段是对的。
//
// 返回 0 表示全部通过
int run_serial_selfcheck();

#endif // SERIALCOLLECTOR_H
