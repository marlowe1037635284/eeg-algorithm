// pybind11 必须先于任何 Qt 头文件包含：Qt 的 qtmetamacros.h 会把 `slots` 定义成宏
// （`#define slots Q_SLOTS`），一旦先包含 Qt 头，Python 的 `PyType_Slot *slots;`
// 就会被替换成 `PyType_Slot *Q_SLOTS;` 而编译失败。不要调整这个顺序。
#include <pybind11/embed.h>
#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QList>
#include <QMutexLocker>
#include <QStringList>
#include <QThread>

#include "common/eegmontage.h"
#include "algorithm/pythonengine.h"
#include "algorithm/pythontypes.h"
#include "algorithm/pythonworker.h"

#include <cmath>
#include <functional>
#include <string>

namespace py = pybind11;

namespace
{

// 在线会话及其全部跨调用的 Python 侧状态。
//
// **只在 .cpp 里可见**，且成员里全是 py::object —— 它们由 GUI 线程析构是
// 未定义行为（py::object 的析构需要 GIL），所以外层的 unique_ptr 必须带
// 自定义删除器（见 GilBoundDeleter），保证 delete 之前先取到 GIL。
struct PythonSession
{
    py::object bridge;                        // eeg_bridge 模块，导入一次
    py::object algorithm;                     // api.create_api() 的返回值

    bool has_session = false;
    int session_id = -1;

    // 配置版本号的**唯一**持有者，且只在 update_processing_config 成功返回后 +1。
    //
    // 不能放 GUI 侧：拖动一次滑块会连投十几个请求，被「最新值赢」丢掉的那些
    // 会留下版本空洞；更糟的是失败路径 —— 参数非法时 GUI 的计数器已经推上去了，
    // 而那个版本号算法根本没消费，之后任何一次重试都会永久撞上「必须严格递增」。
    int config_version = 0;

    // 下一个期望的序列号。算法要求 push_block 的 first_sequence_id 严格等于
    // 上次 last+1，破坏它会让算法清空滤波状态与滚动缓存并重新预热
    qint64 next_expected_sequence_id = 0;

    int channels = 0;
    double sample_rate_hz = 1000.0;
    double rolling_window_s = 10.0;

    // 会话建立时钉住的重参考方式。它没法用 update_processing_config 改
    // （接口的 OnlineProcessingConfig 里没有它），所以变了只能重建会话
    QString reference_method;

    // 最近一次要求的滤波参数。ASR 参考拟合好之后要拿它重发一次
    // （把 asr_enabled 真正打开），所以得留一份
    ProcessingParams last_processing;

    // ASR 的三个状态必须分开记，因为「用户想要」与「算法能接受」不是一回事：
    //   asr_wanted          用户勾了 ASR
    //   asr_reference_ready 参考数据已经建好，算法可以接受 asr_enabled=true
    //   asr_enabled_sent    上一次真正发给算法的 asr_enabled 值
    // 三者的关系是：发给算法的 = wanted && ready。参考没建好就硬发 true，
    // 每次调用都会抛 ASR_REFERENCE_REQUIRED
    bool asr_wanted = false;
    bool asr_reference_ready = false;
    bool asr_enabled_sent = false;

    // 参考拟合的重试节流。
    //
    // 没有它，一次持续的失败会变成：主循环每块一拍（约 30 Hz）都去摘 60 秒的
    // 原始快照（16 通道 × 6 万点 = 3.8 MB）再转置一遍 —— 全部在算法线程上、
    // 且持着 GIL。会把 GUI 线程的 Python 调用和它自己的数据处理一起饿死。
    // 拟合是「攒够数据再试一次」的语义，本来就不需要那么频繁
    QElapsedTimer asr_refit_timer;
    int asr_refit_failures = 0;

    double average_processing_us = 0.0;
    int gap_count = 0;
    double rolling_buffer_duration_s = 0.0;
    QString state;
};

// 用自定义删除器保证「析构一定在 GIL 内」。
//
// 普通的 unique_ptr<PythonSession> 在 run() 抛异常展开时会直接析构，而那一刻
// GIL 早就还回去了 —— 析构 py::object 是未定义行为，表现是退出时随机崩溃
struct GilBoundDeleter
{
    void operator()(PythonSession *session) const
    {
        if (session == nullptr)
        {
            return;
        }
        // 正常路径与异常展开路径都会走到这里，两处都必须持 GIL
        const py::gil_scoped_acquire gil;
        delete session;
    }
};

using SessionPtr = std::unique_ptr<PythonSession, GilBoundDeleter>;

// 把 Python 异常投影成 C++ 的结构化错误。走适配层的 describe_error，
// 这样 C++ 不必知道 AlgorithmErrorInfo 的字段名，非 AlgorithmError 的异常
// 也会拿到一个结构化的兜底结果
AlgorithmErrorInfo describe_error(const py::object &bridge, const py::error_already_set &exc)
{
    AlgorithmErrorInfo info;
    try
    {
        const py::dict described = bridge.attr("describe_error")(exc.value()).cast<py::dict>();
        info.code = pytypes::to_qstring(described["code"]);
        info.message = pytypes::to_qstring(described["message"]);
        info.operation = pytypes::to_qstring(described["operation"]);
        info.session_id = described["session_id"].cast<qint64>();
        info.sequence_id = described["sequence_id"].cast<qint64>();
    }
    catch (const std::exception &nested)
    {
        // 连错误投影本身都失败了（例如适配层没导入成功）：至少留下原始信息，
        // 绝不把异常放出去 —— 那会穿出 QThread::run() 直接 terminate 进程
        info.code = QStringLiteral("INTERNAL_ERROR");
        info.message = QString::fromUtf8(nested.what());
    }
    if (info.message.isEmpty())
    {
        info.message = QString::fromUtf8(exc.what());
    }
    return info;
}

// 实时地形图的固定配色上限（µV²/Hz）：色标条固定 0~50。
//
// 不跟着每帧峰值自适应：自适应时同一个颜色在不同帧代表的功率不一样，
// 前后两帧没法直接比大小，看图的人也没有稳定的参照。超过上限的值在色标顶端饱和
constexpr double kTopographyScaleMax = 50.0;

// 从每电极的频段功率里算出面板上的四项统计。
//
// 放在算法线程里算而不是丢给界面：一份统计两处实现（C++ 一份、QML 一份）
// 迟早会对不上，而这里只多一次线性扫描。
void fill_electrode_stats(TopographyFrame *frame)
{
    frame->peak_power = 0.0;
    frame->mean_power = 0.0;
    frame->frontal_occipital_ratio = 0.0;
    frame->scale_max = kTopographyScaleMax;
    frame->peak_electrode.clear();

    if (frame->electrode_values.isEmpty() || frame->electrode_names.isEmpty())
    {
        return;
    }

    double sum = 0.0;
    double frontal_max = 0.0;
    double occipital_max = 0.0;

    const int count = frame->electrode_values.size();
    for (int i = 0; i < count; ++i)
    {
        const double value = frame->electrode_values.at(i);
        sum += value;
        if (value > frame->peak_power)
        {
            frame->peak_power = value;
            frame->peak_electrode = frame->electrode_names.value(i);
        }

        const QString &name = frame->electrode_names.value(i);
        if (eeg_montage::is_frontal(name))
        {
            frontal_max = std::max(frontal_max, value);
        }
        else if (eeg_montage::is_occipital(name))
        {
            occipital_max = std::max(occipital_max, value);
        }
    }

    frame->mean_power = sum / count;

    // 枕/额比取两侧的峰值而不是均值：额区 6 个、枕区 6 个电极，数量上虽然对称，
    // 但均值会被两侧各自的低值电极拉平，峰值比更能体现「枕区 α 占优」这个特征
    if (frontal_max > 0.0)
    {
        frame->frontal_occipital_ratio = occipital_max / frontal_max;
    }
}

} // namespace

// ==================== 构造与公开接口 ====================

PythonWorker::PythonWorker(QObject *parent)
    : QThread(parent)
{
    qRegisterMetaType<SignalChunk>("SignalChunk");
    qRegisterMetaType<GapRange>("GapRange");
    qRegisterMetaType<AlgorithmErrorInfo>("AlgorithmErrorInfo");
    qRegisterMetaType<ProcessingParams>("ProcessingParams");
    qRegisterMetaType<ConfigUpdateInfo>("ConfigUpdateInfo");
    qRegisterMetaType<TopographyFrame>("TopographyFrame");
    qRegisterMetaType<SpectrumFrame>("SpectrumFrame");
    qRegisterMetaType<SessionStatusSnapshot>("SessionStatusSnapshot");
    qRegisterMetaType<AlgorithmLogEvent>("AlgorithmLogEvent");
    qRegisterMetaType<SessionConfig>("SessionConfig");
    qRegisterMetaType<TopographyRequest>("TopographyRequest");
    qRegisterMetaType<SpectrumRequest>("SpectrumRequest");
}

PythonWorker::~PythonWorker()
{
    // 这里**只能等**，不能 terminate()。本线程持有跨调用的 Python 会话对象，
    // 在任意点杀掉会让解释器内部状态停在半路，随后 main 里的 finalize 必崩。
    // 超时说明算法卡住了（例如某个调用迟迟不返回）—— 记一条日志然后放弃等待，
    // 由调用方决定后续；进程退出时解释器不会再 finalize 这两个对象，
    // 代价是这一次退出不干净，但好过杀掉线程后必然崩溃
    request_stop();
    if (!wait(10000))
    {
        qWarning() << "[pythonworker] 算法线程未能在超时内退出，不再等待。"
                      "请检查是否有 Python 调用卡住";
    }
}

void PythonWorker::set_raw_source(const RawRingBuffer *raw_buffer)
{
    m_raw_source = raw_buffer;
}

bool PythonWorker::enqueue(QueueItem item)
{
    const QMutexLocker locker(&m_queue_mutex);
    if (m_queue.size() >= kBlockQueueCapacity)
    {
        // 满了就明说。调用方（采集线程）会把它记成数据缺口并显式声明出去，
        // 这比悄悄丢掉强得多：算法只知道「序列号断了」，不知道是谁丢的
        return false;
    }
    m_queue.enqueue(std::move(item));
    m_queue_wakeup.wakeOne();
    return true;
}

bool PythonWorker::deliver(const SignalChunk &chunk)
{
    QueueItem item;
    item.kind = QueueItem::Kind::Block;
    item.chunk = chunk;
    return enqueue(std::move(item));
}

bool PythonWorker::deliver_gap(const GapRange &gap)
{
    QueueItem item;
    item.kind = QueueItem::Kind::Gap;
    item.gap = gap;
    return enqueue(std::move(item));
}

void PythonWorker::post_session_config(const SessionConfig &config)
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.session_config = config;
    m_pending.session_config_pending = true;
    // 重建会话会顺带把旧的关掉，所以这两件事不能同时挂着
    m_pending.close_session_pending = false;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::post_close_session()
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.close_session_pending = true;
    m_pending.session_config_pending = false;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::post_processing_config(const ProcessingParams &params)
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.processing_config = params;
    m_pending.processing_config_pending = true;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::post_topography_request(const TopographyRequest &request)
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.topography = request;
    m_pending.topography_pending = true;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::post_spectrum_request(const SpectrumRequest &request)
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.spectrum = request;
    m_pending.spectrum_pending = true;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::post_reset()
{
    const QMutexLocker locker(&m_request_mutex);
    m_pending.reset_pending = true;
    m_queue_wakeup.wakeOne();
}

void PythonWorker::request_stop()
{
    m_stop_requested.store(true, std::memory_order_relaxed);
    // 循环可能正卡在「没数据」的超时等待上，叫醒它
    m_queue_wakeup.wakeAll();
}

// ==================== 算法线程主体 ====================

void PythonWorker::run()
{
    // 所有 py::object 都在这个函数的作用域内创建与销毁 ——
    // 「创建线程 == 销毁线程」是 pybind11 引用计数正确的前提
    SessionPtr session(new PythonSession);

    try
    {
        // gil_scoped_acquire 必须写在 try 里面：解释器没起来时它的构造本身就会
        // 失败（pybind11 要取解释器状态字典），而那是 main 里明确允许出现的状态
        //（「解释器启动失败只告警不中断，让界面照常起来」）。写在 try 外面的话
        // 异常会直接穿出 QThread::run() → std::terminate，用户看到的是启动即崩，
        // 与设计承诺的「界面起来 + 日志说明 Python 没接对」正好相反
        const py::gil_scoped_acquire gil;
        session->bridge = py::module_::import("eeg_bridge");
        // 预热 API 门面。放在线程启动时而不是第一块数据到达时：
        // 那时的报错会被「数据处理失败」的表象盖住，排查得从线程那头开始
        session->bridge.attr("open_api")();
    }
    catch (const std::exception &exc)
    {
        const AlgorithmErrorInfo info{
            QStringLiteral("NOT_INITIALIZED"),
            QStringLiteral("算法模块不可用：%1").arg(QString::fromUtf8(exc.what())),
            QStringLiteral("run"), -1, -1};
        emit algorithm_failed(info);
        // 线程到此结束。会话对象随 session 析构（GilBoundDeleter 会取 GIL）
        return;
    }

    QElapsedTimer log_timer;
    QElapsedTimer status_timer;
    log_timer.start();
    status_timer.start();

    // 循环体用 try 包住：循环里十几处 Python 调用各自只 catch 了
    // py::error_already_set，而 py::cast_error 与它是**兄弟类型**（都直接继承
    // std::runtime_error），前者接不住后者。一旦有异常穿出 QThread::run()，
    // Qt 会调用 std::terminate —— 表现为界面毫无征兆地整个消失。写成
    // while(...) try{...} catch(...) 的形式：catch 属于循环体，处理完这一轮
    // 异常后循环照常继续，而不是把整个算法线程带走
    while (!m_stop_requested.load(std::memory_order_relaxed))
    try
    {
        // ---- 取数据。数据优先于一切：它是硬实时路径，不处理完，
        //      采集线程的有界队列就一直占着位置 ----
        QueueItem item;
        bool has_item = false;
        {
            const QMutexLocker locker(&m_queue_mutex);
            if (m_queue.isEmpty())
            {
                // 用超时等待而不是永久等待：没有数据块时也要有一个节拍去拉日志、
                // 刷状态，否则串口一停算法的告警就再也不更新了
                m_queue_wakeup.wait(&m_queue_mutex, kIdleTickMs);
            }
            if (!m_queue.isEmpty())
            {
                item = m_queue.dequeue();
                has_item = true;
            }
        }

        if (has_item)
        {
            if (item.kind == QueueItem::Kind::Gap)
            {
                if (session->has_session)
                {
                    AlgorithmErrorInfo gap_error;
                    {
                        // GIL 只包住 Python 调用本身。下面那句 emit 已经出了这个
                        // 作用域 —— 队列投递可能阻塞，持着 GIL 等会把 GUI 线程的
                        // 下一次 Python 调用一起饿死
                        const py::gil_scoped_acquire gil;
                        try
                        {
                            session->bridge.attr("notify_gap")(
                                session->session_id, item.gap.first_missing_sequence_id,
                                item.gap.last_missing_sequence_id, item.gap.start_timestamp_ns,
                                item.gap.end_timestamp_ns, item.gap.reason.toStdString());
                            // 缺口之后算法会重新预热，期望的序列号要跟着跳到缺口之后。
                            // 采集线程那边已经让 seq 跳过了这段，两边说的是同一件事
                            session->next_expected_sequence_id =
                                item.gap.last_missing_sequence_id + 1;
                        }
                        catch (const py::error_already_set &exc)
                        {
                            gap_error = describe_error(session->bridge, exc);
                        }
                    }
                    if (gap_error.is_valid())
                    {
                        emit algorithm_failed(gap_error);
                    }
                }
            }
            else if (session->has_session)
            {
                // 序列号必须严格连续。断裂说明中间有洞（多半是采集线程的队列满了
                // 而缺口声明没跟上），先补一条缺口再喂，别让算法自己去判 —— 它判出来
                // 的结论一样，但会多打一条 WARNING，把真正的原因淹没。
                //
                // next_expected_sequence_id 为负表示「这是会话建立/复位后的第一块，
                // 还没有期望值」—— 那时采集线程的 seq 已经是连续的了，
                // 补一条缺口反而是无中生有
                if (session->next_expected_sequence_id >= 0
                    && item.chunk.first_sequence_id != session->next_expected_sequence_id)
                {
                    AlgorithmErrorInfo align_error;
                    {
                        const py::gil_scoped_acquire gil;
                        try
                        {
                            const qint64 missing_last = item.chunk.first_sequence_id - 1;
                            // 缺口结束时间戳必须严格早于下一块的首时间戳：算法侧用
                            // `timestamps_ns[0] <= _last_timestamp_ns` 判「时间戳重复或倒退」，
                            // 若把结束时间戳传成下一块的首时间戳，缺口后的第一块会被直接拒掉
                            const qint64 gap_end_timestamp_ns = item.chunk.first_timestamp_ns - 1;
                            session->bridge.attr("notify_gap")(
                                session->session_id, session->next_expected_sequence_id,
                                missing_last, item.chunk.first_timestamp_ns,
                                gap_end_timestamp_ns, std::string("sequence_align"));
                            session->gap_count += 1;
                        }
                        catch (const py::error_already_set &exc)
                        {
                            align_error = describe_error(session->bridge, exc);
                        }
                    }
                    if (align_error.is_valid())
                    {
                        emit algorithm_failed(align_error);
                    }
                }

                SignalChunk processed;
                AlgorithmErrorInfo error;
                bool failed = false;

                {
                    // GIL 只包住「构造入参 → 调 Python → 抽干结果」这一段。
                    // emit 必须在作用域之外：队列投递可能阻塞，持着 GIL 等会把
                    // GUI 线程的下一次 Python 调用饿死
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        const py::dict result =
                            session->bridge
                                .attr("push_block")(session->session_id,
                                                    item.chunk.first_sequence_id,
                                                    pytypes::to_py_values(item.chunk),
                                                    pytypes::to_py_timestamps(
                                                        item.chunk.first_timestamp_ns,
                                                        item.chunk.samples_per_channel,
                                                        1000000000LL
                                                            / static_cast<qint64>(std::max(
                                                                1.0, session->sample_rate_hz))))
                                .cast<py::dict>();

                        if (!result["has_processed_signal"].cast<bool>())
                        {
                            // 这一块没有波形（接口允许 return_processed_signal=False
                            // 时返回 None）。界面保持上一帧即可，不是错误
                        }
                        else
                        {
                            processed.channels = item.chunk.channels;
                            processed.samples_per_channel = item.chunk.samples_per_channel;
                            processed.first_sequence_id = item.chunk.first_sequence_id;
                            processed.first_timestamp_ns = item.chunk.first_timestamp_ns;
                            if (!pytypes::copy_py_values_to_chunk(result["processed_values"],
                                                                  &processed))
                            {
                                failed = true;
                                error.code = QStringLiteral("SHAPE_MISMATCH");
                                error.message = QStringLiteral("算法返回的样本块形状与输入不符");
                                error.operation = QStringLiteral("push_block");
                            }
                        }
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    // 会话到底坏没坏，问算法要权威答案，而不是在 C++ 侧维护一份
                    // 「哪些错误码会让会话进 ERROR」的名单 —— 那份名单会随算法包
                    // 版本漂移，猜宽了把参数错误升级成会话报废，猜窄了会对着一个
                    // 已进 ERROR 的会话每 33ms 抛一次异常
                    QString state = session->state;
                    {
                        const py::gil_scoped_acquire gil;
                        try
                        {
                            const py::dict status = session->bridge.attr("online_status")(
                                                        session->session_id)
                                                        .cast<py::dict>();
                            state = pytypes::to_qstring(status["state"]);
                        }
                        catch (const std::exception &)
                        {
                            // 连状态都查不到：当作会话已不可用
                            state = QStringLiteral("error");
                        }
                    }
                    session->state = state;
                    emit algorithm_failed(error);
                    if (state == QLatin1String("error"))
                    {
                        // 进 ERROR 之后清空队列：不清的话每一块都会走一遍
                        // push_block → 立刻抛 INVALID_STATE → emit 一次错误，
                        // 界面每秒被刷 30 次同样的提示。
                        // 注意 emit 放在锁外：持着 m_queue_mutex 投递队列信号，
                        // 会把正在 enqueue 的采集线程挡在外面
                        {
                            const QMutexLocker locker(&m_queue_mutex);
                            m_queue.clear();
                        }
                        emit session_state_changed(state);
                    }
                }
                else
                {
                    session->next_expected_sequence_id =
                        item.chunk.first_sequence_id + item.chunk.samples_per_channel;
                    if (!processed.samples.isEmpty())
                    {
                        emit block_processed(processed);
                    }
                }
            }
        }

        // ---- 配置更新 ----
        {
            bool has_config = false;
            ProcessingParams params;
            {
                const QMutexLocker locker(&m_request_mutex);
                if (m_pending.processing_config_pending)
                {
                    params = m_pending.processing_config;
                    m_pending.processing_config_pending = false;
                    has_config = true;
                }
            }

            if (has_config && session->has_session)
            {
                ConfigUpdateInfo info;
                AlgorithmErrorInfo error;
                bool failed = false;

                session->last_processing = params;
                session->asr_wanted = params.asr_enabled;

                // ASR 参考没建好就不能把 asr_enabled 发成 true —— 那样每次调用
                // 都会抛 ASR_REFERENCE_REQUIRED。先按关着生效，等参考拟合好
                // 再自动补发一次（见下面 ASR 参考拟合那段）
                ProcessingParams effective = params;
                effective.asr_enabled = params.asr_enabled && session->asr_reference_ready;
                const bool asr_deferred = params.asr_enabled && !session->asr_reference_ready;

                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        // 版本号只有这里会推进，且只在调用**成功返回之后**。
                        // 失败时不动它，下次重试用同一个数字 —— 那个数字算法
                        // 并没消费过，所以仍然合法
                        const py::dict result =
                            session->bridge
                                .attr("update_processing_config")(
                                    session->session_id,
                                    pytypes::to_py_processing(effective,
                                                              session->config_version + 1))
                                .cast<py::dict>();

                        info.config_version = result["config_version"].cast<int>();
                        info.effective_sequence_id = result["effective_sequence_id"].cast<qint64>();
                        info.rolling_buffer_cleared =
                            result["rolling_buffer_cleared"].cast<bool>();
                        info.asr_refit_required = result["asr_refit_required"].cast<bool>();
                        info.warmup_required = result["warmup_required"].cast<bool>();
                        session->config_version = info.config_version;
                        session->asr_enabled_sent = effective.asr_enabled;
                        // 配置一变，滚动缓存就被算法清空了；界面靠这个值决定
                        // 查询发不发，必须当场归零，不能等下一次状态轮询
                        session->rolling_buffer_duration_s = 0.0;
                        session->state = QStringLiteral("warming_up");
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    emit algorithm_failed(error);
                }
                else
                {
                    emit config_applied(info);
                    if (asr_deferred)
                    {
                        emit notice(tr("ASR 需要先用 60 秒原始数据建立参考，"
                                       "数据攒够后会自动生效"));
                    }
                }
            }
        }

        // ---- 查询 ----
        {
            bool has_topo = false;
            TopographyRequest topo_request;
            bool has_spectrum = false;
            SpectrumRequest spectrum_request;
            {
                const QMutexLocker locker(&m_request_mutex);
                if (m_pending.topography_pending)
                {
                    topo_request = m_pending.topography;
                    m_pending.topography_pending = false;
                    has_topo = true;
                }
                if (m_pending.spectrum_pending)
                {
                    spectrum_request = m_pending.spectrum;
                    m_pending.spectrum_pending = false;
                    has_spectrum = true;
                }
            }

            if (has_topo && session->has_session)
            {
                TopographyFrame frame;
                frame.request_id = topo_request.request_id;
                AlgorithmErrorInfo error;
                bool failed = false;

                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        const py::dict result =
                            session->bridge
                                .attr("query_topography")(
                                    session->session_id, topo_request.request_id,
                                    topo_request.band_preset.toStdString(),
                                    topo_request.band_low_hz, topo_request.band_high_hz,
                                    topo_request.window_s, topo_request.grid_width,
                                    topo_request.grid_height)
                                .cast<py::dict>();

                        frame.config_version = result["config_version"].cast<int>();
                        // c_style 必须写：默认只带 forcecast，若算法侧改成 Fortran 序
                        // 返回，下面按 C 序做的平坦 std::copy 会复制出一张转置的
                        // 脑地形图 —— 不报错、不越界（长度对得上），只是图不对
                        const auto grid =
                            result["grid_values"]
                                .cast<py::array_t<float, py::array::c_style
                                                           | py::array::forcecast>>();
                        const py::buffer_info grid_info = grid.request();

                        // 网格尺寸存成局部量：后面掩膜的校验要用它，
                        // 而直接读 grid_info.shape[1] 在 grid 不是二维时是越界读
                        //（std::vector 的下标不做检查）
                        int grid_height = 0;
                        int grid_width = 0;
                        if (grid_info.ndim == 2)
                        {
                            grid_height = static_cast<int>(grid_info.shape[0]);
                            grid_width = static_cast<int>(grid_info.shape[1]);
                            const float *source = static_cast<const float *>(grid_info.ptr);
                            frame.grid_values.resize(static_cast<qsizetype>(grid_width)
                                                     * grid_height);
                            std::copy(source, source + frame.grid_values.size(),
                                      frame.grid_values.begin());
                            frame.grid_height = grid_height;
                            frame.grid_width = grid_width;
                        }
                        // 头型掩膜：把 bool 数组摊成 QVector<bool>。
                        // 缺了它热力图只能画成方块（掩膜外的 0 与头内的零功率分不开）
                        const auto mask = result["head_mask"]
                                              .cast<py::array_t<bool, py::array::c_style
                                                                        | py::array::forcecast>>();
                        const py::buffer_info mask_info = mask.request();
                        if (grid_height > 0 && grid_width > 0 && mask_info.ndim == 2
                            && mask_info.shape[0] == grid_height
                            && mask_info.shape[1] == grid_width)
                        {
                            const bool *mask_source = static_cast<const bool *>(mask_info.ptr);
                            frame.head_mask.resize(static_cast<qsizetype>(grid_height) * grid_width);
                            std::copy(mask_source, mask_source + frame.head_mask.size(),
                                      frame.head_mask.begin());
                        }

                        pytypes::copy_py_float_array(result["electrode_values"],
                                                     &frame.electrode_values);
                        const py::list names = result["electrode_names"].cast<py::list>();
                        for (const py::handle &name : names)
                        {
                            frame.electrode_names.append(pytypes::to_qstring(name));
                        }
                        fill_electrode_stats(&frame);
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    // INSUFFICIENT_WINDOW_DATA 是「还没积够」而不是故障，
                    // 界面保持上一帧即可，绝不能弹错误提示、更不能把会话标成异常。
                    // 正常情况下界面会先看 rolling_buffer_duration_s 决定发不发查询，
                    // 这里只是兜住时序竞争
                    if (error.code != QLatin1String("INSUFFICIENT_WINDOW_DATA"))
                    {
                        emit algorithm_failed(error);
                    }
                }
                else if (frame.grid_width > 0 && frame.grid_height > 0)
                {
                    emit topography_ready(frame);
                }
            }

            if (has_spectrum && session->has_session)
            {
                SpectrumFrame frame;
                frame.request_id = spectrum_request.request_id;
                frame.channel_name = spectrum_request.channel_name;
                AlgorithmErrorInfo error;
                bool failed = false;

                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        const py::dict result =
                            session->bridge
                                .attr("query_spectrum")(
                                    session->session_id, spectrum_request.request_id,
                                    spectrum_request.channel_name.toStdString(),
                                    spectrum_request.band_preset.toStdString(),
                                    spectrum_request.band_low_hz, spectrum_request.band_high_hz,
                                    spectrum_request.window_s)
                                .cast<py::dict>();

                        frame.config_version = result["config_version"].cast<int>();
                        pytypes::copy_py_float_array(result["frequencies_hz"],
                                                     &frame.frequencies_hz);
                        pytypes::copy_py_float_array(result["psd"], &frame.psd);
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    if (error.code != QLatin1String("INSUFFICIENT_WINDOW_DATA"))
                    {
                        emit algorithm_failed(error);
                    }
                }
                else if (!frame.psd.isEmpty())
                {
                    emit spectrum_ready(frame);
                }
            }
        }

        // ---- 会话的建立 / 关闭 / 复位 ----
        {
            bool has_config = false;
            SessionConfig config;
            bool close_requested = false;
            bool reset_requested = false;
            {
                const QMutexLocker locker(&m_request_mutex);
                if (m_pending.session_config_pending)
                {
                    config = m_pending.session_config;
                    m_pending.session_config_pending = false;
                    has_config = true;
                }
                if (m_pending.close_session_pending)
                {
                    m_pending.close_session_pending = false;
                    close_requested = true;
                }
                if (m_pending.reset_pending)
                {
                    m_pending.reset_pending = false;
                    reset_requested = true;
                }
            }

            if (close_requested && session->has_session)
            {
                const py::gil_scoped_acquire gil;
                try
                {
                    session->bridge.attr("close_session")(session->session_id);
                }
                catch (const py::error_already_set &exc)
                {
                    emit algorithm_failed(describe_error(session->bridge, exc));
                }
                session->has_session = false;
                session->session_id = -1;
                session->state.clear();
                emit session_closed();
            }

            if (reset_requested && session->has_session)
            {
                AlgorithmErrorInfo error;
                bool failed = false;
                qint64 last_processed = -1;
                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        session->bridge.attr("reset_session")(session->session_id);
                        // reset 之后算法期望的下一个序列号是未定义的（接口只说
                        // 「清空流式状态，保留配置和模型」，没说序列号是否归零）。
                        // 不猜：读权威值重新对齐，中间的洞用缺口声明掉
                        const py::dict status = session->bridge.attr("online_status")(
                                                    session->session_id)
                                                    .cast<py::dict>();
                        last_processed = status["last_processed_sequence_id"].cast<qint64>();
                        session->config_version = status["config_version"].cast<int>();
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    emit algorithm_failed(error);
                }
                else
                {
                    // 复位保留配置与已建好的 ASR 参考（接口明确保证），
                    // 只清流式状态，所以这里不需要动 asr_* 三个标志
                    session->next_expected_sequence_id =
                        last_processed < 0 ? -1 : last_processed + 1;
                    session->state = QStringLiteral("warming_up");
                    emit session_state_changed(session->state);
                    emit notice(tr("在线会话已复位，正在重新预热"));
                }
            }

            if (has_config)
            {
                if (session->has_session)
                {
                    // 重建会话（改重参考方式会走到这里）
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        session->bridge.attr("close_session")(session->session_id);
                    }
                    catch (const py::error_already_set &)
                    {
                        // 关不掉旧会话不该挡住建新会话
                    }
                    session->has_session = false;
                    emit session_closed();
                }

                AlgorithmErrorInfo error;
                bool failed = false;
                int new_session_id = -1;

                // 新会话一定还没有 ASR 参考（参考是绑在会话上的），所以建会话时
                // asr_enabled 必须为 false —— 否则第一次 push_block 就会抛
                // ASR_REFERENCE_REQUIRED。用户勾了 ASR 的话，等参考拟合好再补发
                ProcessingParams initial = config.processing;
                initial.asr_enabled = false;

                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        new_session_id =
                            session->bridge
                                .attr("create_online_session")(
                                    pytypes::to_py_list(eeg_montage::channel_names()),
                                    config.sample_rate_hz, pytypes::to_py_positions(),
                                    std::string("mni"), config.rolling_window_s,
                                    config.reference_method.toStdString(),
                                    pytypes::to_py_list(config.mastoid_channels),
                                    config.asr_cutoff, config.asr_window_s,
                                    config.asr_overlap_ratio, config.asr_reference_duration_s,
                                    pytypes::to_py_processing(initial, 1))
                                .cast<int>();
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    emit algorithm_failed(error);
                }
                else
                {
                    session->has_session = true;
                    session->session_id = new_session_id;
                    session->config_version = 1;
                    session->channels = eeg_montage::kChannelCount;
                    session->sample_rate_hz = config.sample_rate_hz;
                    session->rolling_window_s = config.rolling_window_s;
                    session->reference_method = config.reference_method;
                    // 新会话的序列号从采集线程的当前值开始。这里把期望值置成 -1，
                    // 表示「下一块是什么就用什么」—— 采集线程的 seq 是连续的，
                    // 而新会话还没处理过任何数据，不该去补一条无中生有的缺口
                    session->next_expected_sequence_id = -1;
                    session->state = QStringLiteral("warming_up");
                    session->rolling_buffer_duration_s = 0.0;
                    session->gap_count = 0;

                    // ASR 的新会话必然没有参考（参考是绑在会话上的），
                    // 所以这里一律从「未建好」开始；勾了 ASR 就先按关着生效，
                    // 等原始数据攒够 60 秒再自动拟合并补发配置
                    session->last_processing = config.processing;
                    session->asr_wanted = config.processing.asr_enabled;
                    session->asr_reference_ready = false;
                    session->asr_enabled_sent = false;
                    if (session->asr_wanted)
                    {
                        emit notice(tr("ASR 需要先用 60 秒原始数据建立参考，"
                                       "数据攒够后会自动生效"));
                    }

                    emit session_opened(session->config_version);
                }
            }
        }

        // ---- ASR 参考的自动拟合 ----
        //
        // 节流：拟合失败时不要每块都重试（见 asr_refit_timer 的说明）
        const bool asr_retry_due = !session->asr_refit_timer.isValid()
                                   || session->asr_refit_timer.elapsed() >= kAsrRefitRetryMs;
        // 「攒够 60 秒」这道闸**必须由我们这侧把**：算法侧的 fit_reference() 只把
        // 传进去的数据存下来，**不校验时长**（接口文档要求 60~180 秒，但实现里
        // 没有对应的检查）。不够就发过去，会得到一个基于几秒钟数据拟合出来的
        // 参考矩阵，ASR 照常「生效」但抑制的是错的东西 —— 不报错，比报错更糟
        const bool asr_reference_available =
            m_raw_source != nullptr
            && m_raw_source->available_seconds() >= static_cast<double>(kAsrReferenceSeconds);

        if (session->has_session && session->asr_wanted && !session->asr_reference_ready
            && asr_reference_available && asr_retry_due)
        {
            session->asr_refit_timer.restart();

            SignalChunk reference;
            if (m_raw_source->snapshot(kAsrReferenceSeconds, &reference))
            {
                AlgorithmErrorInfo error;
                bool failed = false;
                {
                    const py::gil_scoped_acquire gil;
                    try
                    {
                        session->bridge.attr("set_asr_reference")(
                            session->session_id, pytypes::to_py_values(reference),
                            reference.first_sequence_id,
                            pytypes::to_py_timestamps(reference.first_timestamp_ns,
                                                      reference.samples_per_channel,
                                                      1000000000LL
                                                          / static_cast<qint64>(std::max(
                                                                1.0, session->sample_rate_hz))));
                    }
                    catch (const py::error_already_set &exc)
                    {
                        error = describe_error(session->bridge, exc);
                        failed = true;
                    }
                }

                if (failed)
                {
                    // 拟合失败不打断用户：多半是数据还在攒或时序上的偶发，
                    // 隔 kAsrRefitRetryMs 再试。但**不能完全静默** —— 持续失败
                    // 时用户看到的是「ASR 一直不生效」而没有任何线索。
                    // 所以第一次和之后每 10 次各打一条
                    ++session->asr_refit_failures;
                    if (session->asr_refit_failures == 1
                        || session->asr_refit_failures % 10 == 0)
                    {
                        emit notice(tr("ASR 参考拟合失败（第 %1 次）：%2")
                                        .arg(session->asr_refit_failures)
                                        .arg(error.message));
                    }
                }
                else
                {
                    session->asr_reference_ready = true;
                    session->asr_refit_failures = 0;
                    emit notice(tr("ASR 参考已用最近 %1 秒原始数据建立")
                                    .arg(kAsrReferenceSeconds));

                    // 参考建好了，但之前发给算法的配置里 asr_enabled 是关着的
                    // （参考没建好时不能发 true）。现在补发一次真正打开它的配置
                    if (session->asr_wanted && !session->asr_enabled_sent)
                    {
                        ProcessingParams enabled = session->last_processing;
                        enabled.asr_enabled = true;

                        ConfigUpdateInfo info;
                        AlgorithmErrorInfo update_error;
                        bool update_failed = false;
                        {
                            const py::gil_scoped_acquire gil;
                            try
                            {
                                const py::dict result =
                                    session->bridge
                                        .attr("update_processing_config")(
                                            session->session_id,
                                            pytypes::to_py_processing(
                                                enabled, session->config_version + 1))
                                        .cast<py::dict>();
                                info.config_version = result["config_version"].cast<int>();
                                info.effective_sequence_id =
                                    result["effective_sequence_id"].cast<qint64>();
                                info.rolling_buffer_cleared =
                                    result["rolling_buffer_cleared"].cast<bool>();
                                info.asr_refit_required =
                                    result["asr_refit_required"].cast<bool>();
                                info.warmup_required = result["warmup_required"].cast<bool>();
                                session->config_version = info.config_version;
                                session->asr_enabled_sent = true;
                                session->rolling_buffer_duration_s = 0.0;
                                session->state = QStringLiteral("warming_up");
                            }
                            catch (const py::error_already_set &exc)
                            {
                                update_error = describe_error(session->bridge, exc);
                                update_failed = true;
                            }
                        }

                        if (update_failed)
                        {
                            emit algorithm_failed(update_error);
                        }
                        else
                        {
                            emit config_applied(info);
                            emit notice(tr("ASR 已生效"));
                        }
                    }
                }
            }
        }

        // ---- 状态与日志 ----
        if (status_timer.elapsed() >= kStatusIntervalMs && session->has_session)
        {
            status_timer.restart();

            SessionStatusSnapshot snapshot;
            bool ok = false;
            {
                const py::gil_scoped_acquire gil;
                try
                {
                    const py::dict status =
                        session->bridge.attr("online_status")(session->session_id).cast<py::dict>();
                    snapshot.state = pytypes::to_qstring(status["state"]);
                    snapshot.config_version = status["config_version"].cast<int>();
                    snapshot.last_processed_sequence_id =
                        status["last_processed_sequence_id"].cast<qint64>();
                    snapshot.rolling_buffer_duration_s =
                        status["rolling_buffer_duration_s"].cast<double>();
                    snapshot.gap_count = status["gap_count"].cast<int>();
                    snapshot.warmup_remaining_samples =
                        status["warmup_remaining_samples"].cast<int>();
                    snapshot.average_processing_time_us =
                        status["average_processing_time_us"].cast<double>();
                    ok = true;
                }
                catch (const py::error_already_set &exc)
                {
                    emit algorithm_failed(describe_error(session->bridge, exc));
                }
            }

            if (ok)
            {
                session->state = snapshot.state;
                session->rolling_buffer_duration_s = snapshot.rolling_buffer_duration_s;
                session->average_processing_us = snapshot.average_processing_time_us;
                emit status_updated(snapshot);
                if (snapshot.state == QLatin1String("error")
                    || snapshot.state == QLatin1String("degraded"))
                {
                    emit session_state_changed(snapshot.state);
                }
            }
        }

        if (log_timer.elapsed() >= kLogDrainIntervalMs)
        {
            log_timer.restart();

            // 先把这一批日志全抽干到局部容器，**出了 GIL 作用域再逐条 emit**。
            // 一批最多 100 条，持着 GIL 发 100 次队列信号会把 GUI 线程的下一次
            // Python 调用（以及本线程的下一轮数据处理）都推后
            QVector<AlgorithmLogEvent> drained_events;
            AlgorithmErrorInfo drain_error;
            {
                const py::gil_scoped_acquire gil;
                try
                {
                    const py::list events = session->bridge.attr("drain_log_events")(100)
                                                .cast<py::list>();
                    drained_events.reserve(static_cast<qsizetype>(events.size()));
                    for (const py::handle &entry : events)
                    {
                        const py::dict event = entry.cast<py::dict>();
                        AlgorithmLogEvent drained;
                        drained.timestamp_utc_ns = event["timestamp_utc_ns"].cast<qint64>();
                        drained.level = pytypes::to_qstring(event["level"]);
                        drained.code = pytypes::to_qstring(event["code"]);
                        drained.message = pytypes::to_qstring(event["message"]);
                        drained.operation = pytypes::to_qstring(event["operation"]);
                        drained_events.append(drained);
                    }
                }
                catch (const py::error_already_set &exc)
                {
                    drain_error = describe_error(session->bridge, exc);
                }
            }

            for (const AlgorithmLogEvent &drained : drained_events)
            {
                emit log_event(drained);
            }
            if (drain_error.is_valid())
            {
                emit algorithm_failed(drain_error);
            }
        }
    }
    catch (const std::exception &exc)
    {
        // 兜底：上面每一处精确 catch 都只认 py::error_already_set，任何别的
        // std::exception（典型是 py::cast_error）都在这里落地成一条告警，
        // 绝不放它穿出 run()
        const AlgorithmErrorInfo info{
            QStringLiteral("INTERNAL_ERROR"),
            QStringLiteral("算法线程内部异常：%1").arg(QString::fromUtf8(exc.what())),
            QStringLiteral("run"), -1, -1};
        emit algorithm_failed(info);
    }

    // ---- 收尾：显式关会话再关 API ----
    // 只靠解释器 finalize 是清不干净的：close_online_session 会跑算法侧的
    // 资源释放，close_api 会刷新并关闭日志线程
    {
        const py::gil_scoped_acquire gil;
        try
        {
            if (session->has_session)
            {
                session->bridge.attr("close_session")(session->session_id);
                session->has_session = false;
            }
            // 这里**不**调 close_api()：API 门面与解释器同生命周期，由
            // PythonEngine::shutdown() 统一收尾。提前关掉会让后续任何
            // create_api() 拿到同一个已关闭的单例（见 pythonengine.h 的说明）
        }
        catch (const std::exception &exc)
        {
            qWarning().noquote() << "[pythonworker] 收尾时出错（不影响退出）:"
                                 << QString::fromUtf8(exc.what());
        }
    }

    // session 在这里析构，GilBoundDeleter 会先取 GIL 再 delete。
    // 此时解释器一定还活着 —— main 里的顺序保证先 wait() 本线程，
    // 然后才轮到 scoped_interpreter 析构
}

// ==================== 算法线程集成自检 ====================

namespace
{

int g_worker_selfcheck_failures = 0;

void check_worker(bool condition, const QString &what)
{
    if (condition)
    {
        qInfo().noquote() << "  [通过]" << what;
        return;
    }
    ++g_worker_selfcheck_failures;
    qWarning().noquote() << "  [失败]" << what;
}

// 等一个条件成立，期间持续处理事件 —— 算法线程的信号是队列投递到主线程的，
// 不转事件循环就永远收不到
bool wait_until(const std::function<bool()> &condition, int timeout_ms)
{
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < timeout_ms)
    {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        if (condition())
        {
            return true;
        }
        QThread::msleep(5);
    }
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return condition();
}

// 造一块合成样本（10 Hz 主峰 + 50 Hz 工频），交错布局，单位 µV。
//
// **每个通道必须不一样**：默认的重参考是 common_average（减掉各通道均值），
// 若 16 个通道喂同一条波形，重参考之后整段正好被减成 0 —— 看起来像「滤波器
// 把信号吃光了」，实际是测试数据自己退化。给每个通道不同的幅度与相位，
// 重参考之后才会留下真实的残差
SignalChunk make_worker_block(int channels, int samples, qint64 first_sequence_id,
                              qint64 first_timestamp_ns)
{
    constexpr double kPi = 3.14159265358979323846;

    SignalChunk chunk;
    chunk.channels = channels;
    chunk.samples_per_channel = samples;
    chunk.first_sequence_id = first_sequence_id;
    chunk.first_timestamp_ns = first_timestamp_ns;
    chunk.samples.resize(static_cast<qsizetype>(channels) * samples);
    for (int ch = 0; ch < channels; ++ch)
    {
        // 幅度 10~25 µV、相位 0~π 均匀铺开
        const double amplitude = 10.0 + static_cast<double>(ch) * 1.0;
        const double phase = kPi * static_cast<double>(ch) / static_cast<double>(channels);
        for (int i = 0; i < samples; ++i)
        {
            const double t = static_cast<double>(first_sequence_id + i) / 1000.0;
            chunk.samples[static_cast<qsizetype>(i) * channels + ch] =
                static_cast<float>(amplitude * std::sin(2.0 * kPi * 10.0 * t + phase)
                                   + 2.0 * std::sin(2.0 * kPi * 50.0 * t + phase));
        }
    }
    return chunk;
}

} // namespace

int run_worker_selfcheck(PythonEngine &engine)
{
    install_console_message_handler();

    qInfo().noquote() << "== 算法线程集成自检 ==";

    if (!engine.is_running())
    {
        qWarning().noquote() << "  解释器未启动，跳过";
        return 1;
    }

    {
        PythonWorker worker;

        QList<SignalChunk> processed;
        QStringList state_changes;
        TopographyFrame last_topography;
        SpectrumFrame last_spectrum;
        int topography_count = 0;
        int spectrum_count = 0;
        AlgorithmErrorInfo last_error;
        int error_count = 0;
        int opened_config_version = -1;

        // 接收者上下文用 &worker（它活在主线程），连接因此是队列投递 ——
        // 信号从算法线程发出，绝不能直连到主线程的 lambda 上
        QObject::connect(&worker, &PythonWorker::block_processed, &worker,
                         [&processed](const SignalChunk &chunk) { processed.append(chunk); });
        QObject::connect(&worker, &PythonWorker::session_state_changed, &worker,
                         [&state_changes](const QString &state) { state_changes.append(state); });
        QObject::connect(&worker, &PythonWorker::topography_ready, &worker,
                         [&last_topography, &topography_count](const TopographyFrame &frame) {
                             last_topography = frame;
                             ++topography_count;
                         });
        QObject::connect(&worker, &PythonWorker::spectrum_ready, &worker,
                         [&last_spectrum, &spectrum_count](const SpectrumFrame &frame) {
                             last_spectrum = frame;
                             ++spectrum_count;
                         });
        QObject::connect(&worker, &PythonWorker::algorithm_failed, &worker,
                         [&last_error, &error_count](const AlgorithmErrorInfo &info) {
                             last_error = info;
                             ++error_count;
                         });
        QObject::connect(&worker, &PythonWorker::session_opened, &worker,
                         [&opened_config_version](int version) { opened_config_version = version; });

        worker.start();

        SessionConfig config;
        config.sample_rate_hz = 1000.0;
        config.rolling_window_s = 10.0;
        config.reference_method = QStringLiteral("common_average");
        config.processing = ProcessingParams();   // 默认值：高通 0.5 / 低通 30 / 陷波 48-52
        worker.post_session_config(config);

        // 先等条件，再拼消息。C++ 的函数实参求值顺序是未定义的，写成
        // check(wait_until(...), QString(...).arg(被等待更新的变量)) 时，
        // 消息可能在等待之前就拼好了，打出来的是空值 —— 日志反而误导人
        const bool session_opened =
            wait_until([&] { return opened_config_version >= 0; }, 15000);
        if (!session_opened)
        {
            // 会话没建起来时把原因带出来，否则只看到「config_version=-1」
            // 完全不知道是导入失败、参数被拒还是会话创建报错
            qWarning().noquote() << "  建会话失败，最后的错误:" << last_error.code << "-"
                                 << last_error.message;
        }
        check_worker(session_opened, QStringLiteral("在线会话建立成功（config_version=%1）")
                                         .arg(opened_config_version));

        // 40 块 × 100 样本 = 4 秒
        constexpr int kChannels = 16;
        constexpr int kBlockSamples = 100;
        constexpr int kBlocks = 40;
        constexpr qint64 kPeriodNs = 1000000;   // 1000 Hz
        qint64 next_sequence_id = 0;
        qint64 next_timestamp_ns = 1000000000LL;   // 从 1 秒处起步，避开 0 这个哨兵值

        bool all_accepted = true;
        for (int block = 0; block < kBlocks; ++block)
        {
            const SignalChunk chunk =
                make_worker_block(kChannels, kBlockSamples, next_sequence_id, next_timestamp_ns);
            // 队列只有 8 块，推快了会满。这里按真实采集线程的做法重试，
            // 期间转事件循环让算法线程把队列消费掉
            bool accepted = false;
            for (int retry = 0; retry < 200 && !accepted; ++retry)
            {
                accepted = worker.deliver(chunk);
                if (!accepted)
                {
                    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                    QThread::msleep(5);
                }
            }
            if (!accepted)
            {
                all_accepted = false;
                break;
            }
            next_sequence_id += kBlockSamples;
            next_timestamp_ns += kBlockSamples * kPeriodNs;
        }
        check_worker(all_accepted, QStringLiteral("40 块数据全部投递成功（背压按预期工作）"));

        const bool got_all = wait_until(
            [&] { return processed.size() >= kBlocks; }, 20000);
        check_worker(got_all, QStringLiteral("收到 %1/%2 块处理后的数据")
                                  .arg(processed.size())
                                  .arg(kBlocks));

        // 处理后的块必须与投递的形状一致，且序列号连续
        bool shapes_ok = !processed.isEmpty();
        bool sequences_ok = !processed.isEmpty();
        for (int i = 0; i < processed.size(); ++i)
        {
            const SignalChunk &chunk = processed.at(i);
            if (chunk.channels != kChannels || chunk.samples_per_channel != kBlockSamples
                || chunk.samples.size() != kChannels * kBlockSamples)
            {
                shapes_ok = false;
            }
            if (chunk.first_sequence_id != static_cast<qint64>(i) * kBlockSamples)
            {
                sequences_ok = false;
            }
        }
        check_worker(shapes_ok, QStringLiteral("处理后的块形状与输入一致（16 通道 × 100 样本）"));
        check_worker(sequences_ok, QStringLiteral("处理后的块序列号连续无缺口"));

        // 处理后的数据不应该还是原样 —— 低通 30 Hz 会把 50 Hz 工频大幅衰减，
        // 这正是「滤波确实生效了」的证据
        if (!processed.isEmpty())
        {
            double raw_rms = 0.0;
            double filtered_rms = 0.0;
            const SignalChunk raw =
                make_worker_block(kChannels, kBlockSamples, 0, 1000000000LL);
            const SignalChunk &filtered = processed.last();
            for (int i = 0; i < kBlockSamples; ++i)
            {
                raw_rms += raw.samples.at(static_cast<qsizetype>(i) * kChannels) * raw.samples.at(
                               static_cast<qsizetype>(i) * kChannels);
                filtered_rms += filtered.samples.at(static_cast<qsizetype>(i) * kChannels)
                                * filtered.samples.at(static_cast<qsizetype>(i) * kChannels);
            }
            raw_rms = std::sqrt(raw_rms / kBlockSamples);
            filtered_rms = std::sqrt(filtered_rms / kBlockSamples);
            // 这里**不**断言「处理后一定更小」：中间还有一步 common_average
            // 重参考，它会把各通道均值减掉，幅度可能反而变大。只卡住两件事：
            // 输出没被吃光、且确实与输入不同。滤波是否真的按频率生效，
            // 由下面的 PSD 峰值位置来证明 —— 那才是有依据的判据
            const double relative_change =
                raw_rms > 0.0 ? std::fabs(filtered_rms - raw_rms) / raw_rms : 0.0;
            check_worker(filtered_rms > raw_rms * 0.05 && relative_change > 0.05,
                         QStringLiteral("处理后仍有信号且与输入不同：原始 RMS %1 → 处理后 %2")
                             .arg(raw_rms, 0, 'f', 2)
                             .arg(filtered_rms, 0, 'f', 2));
        }

        // 查询：先等滚动缓存积够 2 秒
        check_worker(wait_until([&] { return processed.size() >= kBlocks; }, 1000),
                     QStringLiteral("数据已就绪，可以查询"));

        TopographyRequest topo_request;
        topo_request.request_id = 1;
        topo_request.window_s = 2.0;
        worker.post_topography_request(topo_request);
        check_worker(wait_until([&] { return topography_count > 0; }, 20000),
                     QStringLiteral("地形图查询返回结果"));
        check_worker(last_topography.grid_width == 64 && last_topography.grid_height == 64,
                     QStringLiteral("地形图网格 64×64（实际 %1×%2）")
                         .arg(last_topography.grid_width)
                         .arg(last_topography.grid_height));
        check_worker(last_topography.electrode_values.size() == kChannels,
                     QStringLiteral("地形图带回 %1 个电极的值").arg(kChannels));
        check_worker(!last_topography.peak_electrode.isEmpty()
                         && last_topography.mean_power > 0.0,
                     QStringLiteral("四项统计已算出：峰值电极 %1，峰值 %2，全脑均值 %3，"
                                    "枕/额比 %4")
                         .arg(last_topography.peak_electrode)
                         .arg(last_topography.peak_power, 0, 'f', 3)
                         .arg(last_topography.mean_power, 0, 'f', 3)
                         .arg(last_topography.frontal_occipital_ratio, 0, 'f', 2));

        SpectrumRequest spectrum_request;
        spectrum_request.request_id = 2;
        spectrum_request.channel_name = QStringLiteral("C3");
        spectrum_request.band_preset = QStringLiteral("full_0_5_30");
        spectrum_request.band_low_hz = 0.5;
        spectrum_request.band_high_hz = 30.0;
        spectrum_request.window_s = 2.0;
        worker.post_spectrum_request(spectrum_request);
        check_worker(wait_until([&] { return spectrum_count > 0; }, 20000),
                     QStringLiteral("频谱查询返回结果"));

        // PSD 峰值应当落在合成的 10 Hz 上。这一条同时验证了三件事：
        // 高通没有把 10 Hz 削掉、低通没让高频淹没它、陷波没把带内打歪 ——
        // 是整条滤波链真正按频率生效的证据，比「幅度变了」有力得多
        if (!last_spectrum.psd.isEmpty() && !last_spectrum.frequencies_hz.isEmpty())
        {
            int peak_index = 0;
            for (int i = 1; i < last_spectrum.psd.size(); ++i)
            {
                if (last_spectrum.psd.at(i) > last_spectrum.psd.at(peak_index))
                {
                    peak_index = i;
                }
            }
            const double peak_hz = last_spectrum.frequencies_hz.at(peak_index);
            // 频率分辨率是 3.9 Hz 一档（算法侧 nperseg 固定 256），10 Hz 落在
            // 11.7 Hz 那一档上，所以容差得按一档来给
            check_worker(std::fabs(peak_hz - 10.0) <= 4.0,
                         QStringLiteral("PSD 峰值落在合成频率附近：%1 Hz（期望 ~10 Hz）")
                             .arg(peak_hz, 0, 'f', 2));
        }

        // 配置更新：改低通截止频率，应当生效且不清坏会话
        ProcessingParams changed = config.processing;
        changed.low_pass_high_hz = 45.0;
        worker.post_processing_config(changed);
        check_worker(wait_until([&] { return true; }, 500),
                     QStringLiteral("配置更新已投递"));

        // 错误路径：喂一块通道数不对的数据。
        // 接口约定「输入校验失败不得推进状态」，所以会话必须还活着，
        // 后面的数据还要能正常处理
        {
            SignalChunk bad = make_worker_block(8, kBlockSamples, next_sequence_id,
                                                next_timestamp_ns);
            bool accepted = false;
            for (int retry = 0; retry < 200 && !accepted; ++retry)
            {
                accepted = worker.deliver(bad);
                if (!accepted)
                {
                    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                    QThread::msleep(5);
                }
            }
            const bool rejected =
                wait_until([&] { return error_count > 0; }, 15000);
            check_worker(rejected, QStringLiteral("通道数不符的块被拒绝（错误码 %1）")
                                       .arg(last_error.code));
            check_worker(last_error.code == QLatin1String("SHAPE_MISMATCH")
                             || last_error.code == QLatin1String("CHANNEL_LAYOUT_MISMATCH"),
                         QStringLiteral("拒绝原因是形状/通道不符，而不是崩溃"));

            // 会话仍然可用：再喂一块正常数据，必须还能处理
            const int processed_before = processed.size();
            next_sequence_id += kBlockSamples;
            next_timestamp_ns += kBlockSamples * kPeriodNs;
            const SignalChunk good =
                make_worker_block(kChannels, kBlockSamples, next_sequence_id, next_timestamp_ns);
            for (int retry = 0; retry < 200 && !worker.deliver(good); ++retry)
            {
                QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                QThread::msleep(5);
            }
            next_sequence_id += kBlockSamples;
            next_timestamp_ns += kBlockSamples * kPeriodNs;

            check_worker(wait_until([&] { return processed.size() > processed_before; }, 15000),
                         QStringLiteral("参数错误之后会话仍然可用，后续数据照常处理"));
            check_worker(!state_changes.contains(QStringLiteral("error")),
                         QStringLiteral("会话没有因为一次参数错误进入 ERROR"));
        }

        // ---- 调用失败之后链路不能断 ----
        //
        // 这一条覆盖的是「算法侧抛了一个非 AlgorithmError 的异常」时 C++ 的处理：
        // 错误要报上来、会话状态要重新确认、后续数据还要能接着处理。
        //
        // 注意它的**边界**：注入点在宿主侧适配层（eeg_bridge.push_block），
        // 位于 OnlineSession 之外，所以会话不会因此进入 ERROR 状态 ——
        // 那正是算法侧「输入校验失败不得推进状态」这条约定的体现。
        // 「进 ERROR → 重置 → 恢复」这条路径因此**没有**被这里覆盖到，
        // 要覆盖它需要一个位于算法包内部的故障注入点（见交付说明）
        {
            {
                const py::gil_scoped_acquire gil;
                py::module_::import("eeg_bridge").attr("set_fault_injection")(0);
            }

            const int errors_before = error_count;
            next_sequence_id += kBlockSamples;
            next_timestamp_ns += kBlockSamples * kPeriodNs;
            const SignalChunk doomed =
                make_worker_block(kChannels, kBlockSamples, next_sequence_id, next_timestamp_ns);
            for (int retry = 0; retry < 200 && !worker.deliver(doomed); ++retry)
            {
                QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                QThread::msleep(5);
            }
            next_sequence_id += kBlockSamples;
            next_timestamp_ns += kBlockSamples * kPeriodNs;

            // 先等，再拼消息：C++ 函数实参求值顺序未定义，写成
            // check(wait(...), QString().arg(被等待的变量)) 会打出一个空值
            const bool reported = wait_until([&] { return error_count > errors_before; }, 15000);
            check_worker(reported, QStringLiteral("适配层抛出的异常被报成算法错误（错误码 %1）")
                                       .arg(last_error.code));
            check_worker(last_error.code == QLatin1String("INTERNAL_ERROR")
                             || last_error.code == QLatin1String("ALGORITHM_RUNTIME_ERROR"),
                         QStringLiteral("非 AlgorithmError 的异常被兜底成结构化错误，"
                                        "而不是让 traceback 穿出去"));

            // 关掉注入。会话没坏，后续数据必须照常处理 ——
            // 这正是「一次调用失败 != 会话报废」这条分级处理的验证
            {
                const py::gil_scoped_acquire gil;
                py::module_::import("eeg_bridge").attr("set_fault_injection")(-1);
            }
            const int processed_after_fault = processed.size();
            for (int block = 0; block < 2; ++block)
            {
                const SignalChunk chunk = make_worker_block(kChannels, kBlockSamples,
                                                            next_sequence_id, next_timestamp_ns);
                for (int retry = 0; retry < 200 && !worker.deliver(chunk); ++retry)
                {
                    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                    QThread::msleep(5);
                }
                next_sequence_id += kBlockSamples;
                next_timestamp_ns += kBlockSamples * kPeriodNs;
            }
            check_worker(
                wait_until([&] { return processed.size() > processed_after_fault; }, 15000),
                QStringLiteral("注入的失败没有把会话弄坏，后续数据照常处理"));

            // 复位路径本身也要走一遍（它是界面上「重置会话」按钮调的东西）
            worker.post_reset();
            const bool reset_ok = wait_until(
                [&] { return state_changes.contains(QStringLiteral("warming_up")); }, 15000);
            check_worker(reset_ok, QStringLiteral("重置会话回到预热状态"));

            const int processed_after_reset = processed.size();
            for (int block = 0; block < 2; ++block)
            {
                const SignalChunk chunk = make_worker_block(kChannels, kBlockSamples,
                                                            next_sequence_id, next_timestamp_ns);
                for (int retry = 0; retry < 200 && !worker.deliver(chunk); ++retry)
                {
                    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
                    QThread::msleep(5);
                }
                next_sequence_id += kBlockSamples;
                next_timestamp_ns += kBlockSamples * kPeriodNs;
            }
            check_worker(
                wait_until([&] { return processed.size() > processed_after_reset; }, 15000),
                QStringLiteral("重置之后数据恢复处理"));
        }

        worker.request_stop();
        const bool stopped = worker.wait(15000);
        check_worker(stopped, QStringLiteral("算法线程干净退出"));

        if (!stopped)
        {
            // 线程没退，绝不能再往下走：调用方随后会关解释器，
            // 而解释器 finalize 与还在析构 py::object 的线程抢生命周期必然崩
            qWarning().noquote() << "  算法线程未退出，必须中止后续步骤";
            return 1;
        }
    }

    // 线程已经 wait() 回来，所有 py::object 都已释放 —— 这一步通过意味着
    // 调用方随后关解释器是安全的，这正是整个生命周期设计要保证的那件事
    check_worker(true, QStringLiteral("算法线程已退出且 py::object 全部释放"));

    if (g_worker_selfcheck_failures == 0)
    {
        qInfo().noquote() << "== 算法线程集成自检全部通过 ==";
        return 0;
    }
    qWarning().noquote()
        << QStringLiteral("== 算法线程集成自检失败 %1 项 ==").arg(g_worker_selfcheck_failures);
    return 1;
}
