#ifndef PYTHONWORKER_H
#define PYTHONWORKER_H

#include <QMutex>
#include <QQueue>
#include <QThread>
#include <QWaitCondition>

#include <atomic>

#include "eegtypes.h"
#include "serialcollector.h"

// 只用于下面的自检签名。前置声明而不是包含 pythonengine.h：
// 本头文件会被面向 QML 的头文件包含，少一层包含扩散就少一处编译顺序的坑
class PythonEngine;

// 算法线程：持有在线会话，串行处理数据块、配置更新与查询。
//
// 为什么独立成线程（而参考实现是把滤波同步调在 GUI 线程里）：
// 本项目走的是完整在线流水线（高通/低通 → 陷波 → 重参考 → ASR → 写滚动缓存），
// 每秒 30 次、每次几毫秒，还要与地形图/频谱查询串行；再加地形图的空间插值
// 一次可能几十毫秒。放在 GUI 线程上就是每 1.2 秒卡一下界面。
//
// 本头文件**不含任何 pybind11 头**：它会被面向 QML 的头文件包含，而 pybind11
// 必须排在所有 Qt 头之前才能编译的原因见 pythonengine.cpp 顶部。
// 所有 py::object 都关在 pythonworker.cpp 的 PythonSession 里（只在 .cpp 可见）。
//
// 线程安全的约定（每条都有明确的失败现象）：
//   · 只有本线程碰 Python 对象，所以**不需要**用 QMutex 保护它们 ——
//     GIL 与 QMutex 是两套独立锁，嵌套顺序无法全局约定，是死锁的经典配方。
//     串行化靠「单线程事件循环」本身，不靠锁。
//   · GIL 只在单次 Python 调用前后持有，**绝不跨越 emit**：队列投递可能阻塞，
//     持着 GIL 等待会把 GUI 线程的下一次 Python 调用饿死。
//   · 绝对不调用 terminate()：本线程持有跨调用的 Python 会话对象，
//     在任意点杀掉它会让解释器内部状态停在半路，随后 finalize 必崩。
//     退出只能靠 request_stop() + wait()。**超时的结局是明确的失败**：
//     本类析构里的 wait() 放弃之后，基类 ~QThread 会以
//     qFatal("Destroyed while thread is still running") 终止进程 ——
//     这是刻意选的兜底，不是「等它自己好」。
class PythonWorker : public QThread, public ChunkSink
{
    Q_OBJECT

public:
    // 数据块队列容量。8 块 ≈ 264 ms 的余量，够吸收一次地形图插值带来的停顿
    static constexpr int kBlockQueueCapacity = 8;
    // 没数据时的循环节拍：也要靠它定期拉日志与刷新会话状态，
    // 否则串口一停，算法的告警就再也不更新了
    static constexpr int kIdleTickMs = 50;
    // 拉取算法侧告警事件的周期（接口建议 200~500 ms）
    static constexpr int kLogDrainIntervalMs = 300;
    // 刷新会话状态的周期。界面靠 rolling_buffer_duration_s 决定查询发不发
    static constexpr int kStatusIntervalMs = 500;
    // ASR 参考需要的最短原始数据时长（接口规定 60~180 秒）
    static constexpr int kAsrReferenceSeconds = 60;
    // ASR 参考拟合失败后的重试间隔。拟合要摘 60 秒原始数据（约 3.8 MB）再转置，
    // 不能每块都试 —— 那是每秒 30 次、每次百万次浮点搬运，且全程持着 GIL
    static constexpr int kAsrRefitRetryMs = 2000;

    explicit PythonWorker(QObject *parent = nullptr);
    ~PythonWorker() override;

    // ASR 参考的数据来源。必须在 start() 之前设置，且指向的对象要比本线程活得久。
    //
    // 直接收 RawRingBuffer 而不是 SerialCollector：缓冲自身就是「带锁 + const」
    // 的线程安全接口，没有理由再绕一层。而且采集器在每次换串口时都会被销毁重建
    //（见 AcquisitionBridge::close_port），拿它的指针必然悬空；
    // 环形缓冲是桥接层的常驻成员，生命周期覆盖本线程
    void set_raw_source(const RawRingBuffer *raw_buffer);

    // ---- 采集线程调用（实现 ChunkSink）----
    bool deliver(const SignalChunk &chunk) override;
    bool deliver_gap(const GapRange &gap) override;

    // ---- GUI 线程调用 ----
    // 建会话。参数变化幅度超过 update_processing_config 能表达的范围时
    // （目前只有重参考方式）也用这个来重建会话
    void post_session_config(const SessionConfig &config);
    void post_close_session();
    void post_processing_config(const ProcessingParams &params);
    void post_topography_request(const TopographyRequest &request);
    void post_spectrum_request(const SpectrumRequest &request);
    // 会话进了 ERROR 之后的唯一恢复入口
    void post_reset();
    void request_stop();

signals:
    // 算法处理后的样本块（交错布局，单位 µV）
    void block_processed(const SignalChunk &chunk);
    void session_opened(int config_version);
    void session_closed();
    void config_applied(const ConfigUpdateInfo &info);
    void topography_ready(const TopographyFrame &frame);
    void spectrum_ready(const SpectrumFrame &frame);
    void status_updated(const SessionStatusSnapshot &status);
    // 非故障的提示（例如「ASR 需要先累计 60 秒数据」）。与 algorithm_failed
    // 分开：这类消息不该把界面切到异常态，也不该让用户以为采集坏了
    void notice(const QString &message);
    // 一次调用失败。会话是否因此坏掉要看随后到达的 session_state_changed
    void algorithm_failed(const AlgorithmErrorInfo &info);
    void session_state_changed(const QString &state);
    void log_event(const AlgorithmLogEvent &event);

protected:
    void run() override;

private:
    struct QueueItem
    {
        enum class Kind
        {
            Block,
            Gap
        };
        Kind kind = Kind::Block;
        SignalChunk chunk;
        GapRange gap;
    };

    // 「最新值赢」的请求槽。
    //
    // 不用信号槽投递这类请求：用户拖一次滑块会连投十几个配置更新，队列连接会
    // 老老实实排十几次，而用户想要的只是最后一次。覆盖式语义既省掉那些无用的
    // Python 调用，也避开了「连投十次触发十次滚动缓存清空」这种荒唐的结果。
    struct PendingRequests
    {
        bool session_config_pending = false;
        SessionConfig session_config;
        bool close_session_pending = false;

        bool processing_config_pending = false;
        ProcessingParams processing_config;

        bool topography_pending = false;
        TopographyRequest topography;

        bool spectrum_pending = false;
        SpectrumRequest spectrum;

        // reset 是**一次性事件**，不能被后来的查询覆盖掉，所以与上面几个分开
        bool reset_pending = false;
    };

    // 采集线程投递。队列满时返回 false，由调用方记成数据缺口
    bool enqueue(QueueItem item);

    const RawRingBuffer *m_raw_source = nullptr;

    mutable QMutex m_queue_mutex;
    QWaitCondition m_queue_wakeup;
    QQueue<QueueItem> m_queue;

    mutable QMutex m_request_mutex;
    PendingRequests m_pending;

    std::atomic<bool> m_stop_requested{false};
};

// 算法线程的集成自检：不接设备、不启界面，用合成数据把
// 「建会话 → 推数据块 → 查询地形图 → 喂一块错数据 → 继续推」整条路走一遍。
//
// 为什么必须有它：C++ 与算法之间是靠字符串键名和位置参数连起来的，没有编译期
// 检查；参数拼错、字段名对不上、GIL 用错，都只会在运行时表现为「结果一直不来」
// 或「界面卡住」，而那时已经在真机上、正在采数据了。
//
// engine 必须已经 start() 过：一个进程只能起一次解释器，所有自检共用同一个
// （原因见 pythonengine.h 里 run_python_selfcheck 的说明）。
// 返回 0 表示全部通过
int run_worker_selfcheck(PythonEngine &engine);

#endif // PYTHONWORKER_H
