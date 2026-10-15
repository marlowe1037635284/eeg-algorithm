#include "bridge/acquisitionbridge.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QFileInfo>
#include <QFontMetricsF>
#include <QMutexLocker>
#include <QPainter>
#include <QPolygonF>
#include <QThread>
#include <QSerialPortInfo>
#include <QtMath>

#include <cstring>
#include <functional>
#include <limits>

#include "common/eegmontage.h"
#include "algorithm/pythonengine.h"
#include "acquisition/serialprotocol.h"
#include "common/topographypalette.h"
#include "bridge/bridgeimageproviders.h"
#include "common/auditlog.h"

#include <algorithm>
#include <cmath>

namespace
{

// 显示缓冲的时长上限。按最长可选时窗（10 秒）留一倍余量
constexpr int kMaxWindowSeconds = 30;
// 单个通道最多存多少样本，兜住极端采样率下的内存
constexpr int kMaxSamplesPerChannel = 200000;

// 波形重绘周期（约 30 FPS）。与算法投递节拍一致
constexpr int kDisplayIntervalMs = 33;
// 地形图与频谱的刷新周期
constexpr int kTopographyIntervalMs = 1200;
constexpr int kSpectrumIntervalMs = 1200;

// 地形图出图的边长。网格只有 64×64，画到 256 已经足够，
// 再大只是白白多传几次纹理
constexpr int kTopographyImageSize = 256;

// 显示待处理队列的容量上限（块数）。按 33ms 一批、每批最多几块估，
// 64 块 ≈ 2 秒。满了就丢最旧的 —— 显示宁可跳一下也不能让队列无限增长。
// 注意生产（on_block_processed）与消费（pump_display）都在 GUI 线程，
// 队列只在算法投递追不上界面重绘时才会积压
constexpr int kDisplayPendingCapacity = 64;

// 落盘目录：程序执行目录下的 records 子目录
// 默认落在 exe 旁边，方便随程序一起拷贝/归档，不依赖 %LOCALAPPDATA%
QString default_record_directory()
{
    const QString base = QCoreApplication::applicationDirPath();
    return QDir::fromNativeSeparators(base) + QStringLiteral("/records");
}

// 患者子目录名：用病历号（P-0001 这类），**不用姓名**。
// 姓名带空格、生僻字，既不好找也不稳定；病历号才是稳定标识。
// 病历号允许手填，这里把 Windows 不允许出现在文件名里的字符换成下划线，
// 免得一个 '/' 或 ':' 就让建目录直接失败
QString patient_folder_name(const QString &patient_no)
{
    QString name = patient_no.trimmed();
    static const QString invalid = QStringLiteral("\\/:*?\"<>|");
    for (const QChar ch : invalid)
        name.replace(ch, QLatin1Char('_'));
    return name;
}

// 把地形图网格画成一张方形图。
//
// 头型掩膜之外画成**透明**：算法会把掩膜外的值置 0，而 0 在掩膜内也是合法功率，
// 只看数值分不出来。不透明的话热力图会是一个方块，盖掉设计稿的头型底图。
//
// 缩放按**掩膜圆的实际半径**来，而不是把整个网格铺满。
//
// 必须这么做：算法算出的头部半径是「最远电极距离 × 1.15」，而电极坐标是按最大
// 绝对值归一化的（见算法侧 topography_core.py）。本项目的蒙太奇算下来半径约
// 1.20，**大于网格半宽 1** —— 网格本身装不下这个头。
//
// 后果是掩膜被网格的四条边裁掉了：掩膜 = 半径 1.2 的圆 ∩ [-1,1]² 的方块
// = 一个**八边形**。照它原样画出来就是个方块，叠在设计稿的圆形底图上很显眼。
//
// 所以这里按「先定圆、再取样」来画：
//   · 圆外 → 透明（这才是「头外」）
//   · 圆内 → 采样网格；网格够不到的地方（圆周方向上超界的那一圈窄带）
//     按最近的边界点取值
// 半径直接从掩膜里量：掩膜是圆，网格里离中心最远的掩膜内点到中心的距离就是
// 半径（网格四角在半径之外，所以取最大值不会被边界截断）
QImage render_topography(const TopographyFrame &frame, int size)
{
    QImage image(size, size, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);

    if (frame.grid_width <= 0 || frame.grid_height <= 0 || frame.grid_values.isEmpty())
    {
        return image;
    }

    // 网格坐标 → 归一化坐标：网格边缘对应 ±1（与算法侧 np.linspace(-1,1,W) 一致）
    const int last_x = std::max(1, frame.grid_width - 1);
    const int last_y = std::max(1, frame.grid_height - 1);

    double radius = 1.0;
    if (frame.head_mask.size() == frame.grid_width * frame.grid_height)
    {
        bool found = false;
        for (int gy = 0; gy < frame.grid_height; ++gy)
        {
            const double ny = static_cast<double>(gy) / last_y * 2.0 - 1.0;
            for (int gx = 0; gx < frame.grid_width; ++gx)
            {
                if (!frame.head_mask.at(gy * frame.grid_width + gx))
                {
                    continue;
                }
                const double nx = static_cast<double>(gx) / last_x * 2.0 - 1.0;
                const double distance = std::sqrt(nx * nx + ny * ny);
                radius = found ? std::max(radius, distance) : distance;
                found = true;
            }
        }
        if (!found)
        {
            return image;   // 掩膜全空：插值还没产出有效结果
        }
    }

    const double scale_max = frame.scale_max > 0.0 ? frame.scale_max : 1.0;
    const double half = static_cast<double>(size - 1) / 2.0;

    for (int y = 0; y < size; ++y)
    {
        // 输出像素 → 归一化坐标（把 ±radius 铺到 ±half）
        const double ny = (static_cast<double>(y) - half) / half * radius;

        QRgb *line = reinterpret_cast<QRgb *>(image.scanLine(y));
        for (int x = 0; x < size; ++x)
        {
            const double nx = (static_cast<double>(x) - half) / half * radius;

            // 头外保持透明。判据是**圆的方程**而不是掩膜查表：
            // 掩膜只覆盖网格范围，而头圆在四个轴向超出网格，
            // 那些位置查不到掩膜，按圆判断才画得出完整的圆形头型
            if (nx * nx + ny * ny > radius * radius)
            {
                continue;
            }

            // 双线性采样：按相邻四格的权重混合，而不是四舍五入到最近一格。
            //
            // 网格是 64×64、图是 256×256，最近邻等于把每个格子摊成 4×4 的纯色方块，
            // 格子之间取值不连续 —— 看上去就是一圈圈硬邦邦的「分界线」。
            // 这里在相邻格之间线性过渡，边界自然就化开了
            const double fx = (nx + 1.0) / 2.0 * last_x;
            const double fy = (ny + 1.0) / 2.0 * last_y;
            const int x0 = std::clamp(static_cast<int>(std::floor(fx)), 0, frame.grid_width - 1);
            const int y0 = std::clamp(static_cast<int>(std::floor(fy)), 0, frame.grid_height - 1);
            const int x1 = std::min(x0 + 1, frame.grid_width - 1);
            const int y1 = std::min(y0 + 1, frame.grid_height - 1);
            const double tx = fx - x0;
            const double ty = fy - y0;

            // 掩膜外的格是 NaN，不参与混合，权重归一到剩下可用的格子上；
            // 四格全不可用就留透明（头外）
            double value_sum = 0.0;
            double weight_sum = 0.0;
            const auto accumulate = [&](int gx, int gy, double weight) {
                if (weight <= 0.0)
                    return;
                const int index = gy * frame.grid_width + gx;
                if (index < 0 || index >= frame.grid_values.size())
                    return;
                const float value = frame.grid_values.at(index);
                if (std::isnan(value))
                    return;
                value_sum += weight * value;
                weight_sum += weight;
            };
            accumulate(x0, y0, (1.0 - tx) * (1.0 - ty));
            accumulate(x1, y0, tx * (1.0 - ty));
            accumulate(x0, y1, (1.0 - tx) * ty);
            accumulate(x1, y1, tx * ty);

            if (weight_sum <= 0.0)
            {
                continue;
            }
            line[x] = topography_palette::color(value_sum / weight_sum / scale_max);
        }
    }
    return image;
}

// 频段名 → (preset, 低, 高)。写错的话算法会直接拒绝，界面上则表现为「点了没反应」
bool band_from_name(const QString &band, QString *preset, double *low_hz, double *high_hz)
{
    if (band == QLatin1String("full"))
    {
        *preset = QStringLiteral("full");
        *low_hz = 0.5;
        *high_hz = 45.0;
    }
    else if (band == QLatin1String("delta"))
    {
        *preset = QStringLiteral("delta");
        *low_hz = 0.5;
        *high_hz = 4.0;
    }
    else if (band == QLatin1String("theta"))
    {
        *preset = QStringLiteral("theta");
        *low_hz = 4.0;
        *high_hz = 8.0;
    }
    else if (band == QLatin1String("alpha"))
    {
        *preset = QStringLiteral("alpha");
        *low_hz = 8.0;
        *high_hz = 13.0;
    }
    else if (band == QLatin1String("beta"))
    {
        *preset = QStringLiteral("beta");
        *low_hz = 13.0;
        *high_hz = 30.0;
    }
    else if (band == QLatin1String("gamma"))
    {
        *preset = QStringLiteral("gamma");
        *low_hz = 30.0;
        *high_hz = 45.0;
    }
    else
    {
        return false;
    }
    return true;
}

} // namespace

QStringList AcquisitionBridge::topo_palette()
{
    return topography_palette::stops();
}

// ==================== 构造与析构 ====================

AcquisitionBridge::AcquisitionBridge(PythonEngine *engine, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
{
    qRegisterMetaType<SignalChunk>("SignalChunk");
    qRegisterMetaType<GapRange>("GapRange");

    reset_channels(m_channel_count);

    // ==================== 调试：逐级放开预处理 ====================
    // 排查实时显示问题：先只开带通（高通 + 低通）与陷波，重参考仍设为 off，
    // 便于确认「带通 + 陷波」这一段是否正常；ASR 默认即关（m_asr_enabled = false）
    // 恢复常态时：把 m_reference_method 改回 "common_average"
    m_processing.high_pass_enabled = true;
    m_processing.low_pass_enabled = true;
    m_processing.notch_enabled = true;
    m_reference_method = QStringLiteral("off");

    // 算法线程与采集线程的创建顺序不重要，但**析构顺序很重要**：
    // 两者都必须在解释器 finalize 之前停干净（见 main.cpp）
    //
    // 解释器没起来时**不能**启动算法线程：线程体第一件事就是取 GIL，
    // 而没有活解释器时那是致命错误。原来的写法会在这里把「Python 没接对、
    // 界面照常起来」变成「启动即崩」
    if (m_engine != nullptr && m_engine->is_running())
    {
        // ASR 参考要用原始数据拟合，数据源就是这个环形缓冲。
        // 它由采集线程写、算法线程读，自身带锁（见 RawRingBuffer）
        m_worker.set_raw_source(&m_raw_buffer);
        m_worker.start();
    }

    QObject::connect(&m_display_timer, &QTimer::timeout, this, &AcquisitionBridge::pump_display);
    m_display_timer.setInterval(kDisplayIntervalMs);
    m_display_timer.start();

    QObject::connect(&m_topo_timer, &QTimer::timeout, this, &AcquisitionBridge::tick_topography);
    m_topo_timer.setInterval(kTopographyIntervalMs);
    m_topo_timer.start();

    QObject::connect(&m_spectrum_timer, &QTimer::timeout, this, &AcquisitionBridge::tick_spectrum);
    m_spectrum_timer.setInterval(kSpectrumIntervalMs);
    m_spectrum_timer.start();

    QObject::connect(&m_demo_timer, &QTimer::timeout, this,
                     &AcquisitionBridge::tick_demo_source);
    m_demo_timer.setInterval(kDisplayIntervalMs);

    // 算法线程的信号一律队列投递（发信方在工作线程）
    QObject::connect(&m_worker, &PythonWorker::session_opened, this,
                     &AcquisitionBridge::on_session_opened, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::session_closed, this,
                     &AcquisitionBridge::on_session_closed, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::config_applied, this,
                     &AcquisitionBridge::on_config_applied, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::topography_ready, this,
                     &AcquisitionBridge::on_topography_ready, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::spectrum_ready, this,
                     &AcquisitionBridge::on_spectrum_ready, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::status_updated, this,
                     &AcquisitionBridge::on_status_updated, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::algorithm_failed, this,
                     &AcquisitionBridge::on_algorithm_failed, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::session_state_changed, this,
                     &AcquisitionBridge::on_session_state_changed, Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::notice, this, &AcquisitionBridge::on_notice,
                     Qt::QueuedConnection);
    QObject::connect(&m_worker, &PythonWorker::log_event, this, &AcquisitionBridge::on_log_event,
                     Qt::QueuedConnection);
    // 波形数据源：算法线程每处理完一块就投递过来，落在 GUI 线程
    QObject::connect(&m_worker, &PythonWorker::block_processed, this,
                     &AcquisitionBridge::on_block_processed, Qt::QueuedConnection);

    // 日志同时进控制台。只 emit 的话，在没有界面日志区的场合（自检、--demo、
    // 用户报问题时的复现）就什么都收不到，等于没有日志；而这一类问题
    //（数据到底有没有进来、会话有没有建起来）恰恰只能靠日志判断
    QObject::connect(this, &AcquisitionBridge::logMessage, this,
                     [](const QString &message) { qInfo().noquote() << "[acq]" << message; });

    refresh_ports();
    refresh_stats_text();
}

AcquisitionBridge::~AcquisitionBridge()
{
    // 顺序不能动：
    //   1) 先关串口并等采集线程退出 —— 否则它可能在本对象析构之后还调 deliver()
    //   2) 再停算法线程。它持有跨调用的 py::object，必须 wait() 回来
    //   3) 最后才轮得到解释器（由 main 负责）
    close_port();

    m_worker.request_stop();
    if (!m_worker.wait(15000))
    {
        // 超时说明某个 Python 调用卡住了。这里**不能** terminate()（会让解释器
        // 内部状态停在半路，随后 finalize 必崩），也不能放着不管 ——
        // 算法线程若还活着，它会继续读 m_raw_buffer，而成员马上要开始析构。
        // 把话说清楚：接下来要么是 QThread 基类的 qFatal 收场，要么是
        // 访问已析构的缓冲，两种都是明确的失败，不要再往上加一层掩盖
        qWarning() << "[acquisition] 算法线程未能在超时内退出，"
                      "退出过程可能不正常（多半是某个 Python 调用卡住）";
    }
}

// ==================== ChunkSink：运行在采集线程上 ====================

bool AcquisitionBridge::deliver(const SignalChunk &chunk)
{
    // 原始数据先留一份给 ASR：它要的是**未经任何处理**的数据。
    // 放在这里而不是等算法回传，是因为算法返回的是处理后的值，
    // 而参考矩阵必须用原始数据拟合
    const qint64 period_ns = 1000000000LL / std::max(1, m_sample_rate);
    m_raw_buffer.append(chunk.samples.constData(), chunk.samples_per_channel, chunk.channels,
                        chunk.first_timestamp_ns, period_ns);

    // 波形数据不在这里产生：块交给算法线程处理完，再由算法线程的 block_processed
    // 信号把结果投递回 GUI 线程（见 on_block_processed）。本函数只负责转交
    return m_worker.deliver(chunk);
}

bool AcquisitionBridge::deliver_gap(const GapRange &gap)
{
    return m_worker.deliver_gap(gap);
}

// ==================== 串口 ====================

void AcquisitionBridge::refresh_ports()
{
    QStringList ports;
    const QList<QSerialPortInfo> infos = QSerialPortInfo::availablePorts();
    for (const QSerialPortInfo &info : infos)
    {
        ports.append(info.portName());
    }
    if (ports != m_available_ports)
    {
        m_available_ports = ports;
        emit availablePortsChanged();
    }
}

bool AcquisitionBridge::collector_active() const
{
    // 判据必须是线程状态而不是指针是否为空：线程会因为拔线、掉电自己结束，
    // 那时 m_collector 非空却已不再消费命令队列
    return m_collector != nullptr && m_collector->isRunning();
}

bool AcquisitionBridge::open_port(const QString &port_name, int baud_rate, int sample_rate)
{
    if (port_name.trimmed().isEmpty())
    {
        set_error(tr("请先选择或输入串口名"));
        return false;
    }

    // 换参数就重开：先把上一份收干净，免得两个采集线程同时占着串口
    close_port();

    m_sample_rate = std::clamp(sample_rate, 1, 100000);

    SerialCollector::Config config;
    config.port_name = port_name.trimmed();
    config.baud_rate = std::clamp(baud_rate, 300, 4000000);
    // 串口上永远是设备的 16 路；界面上的 4/8/16 只是显示与算法的通道子集
    config.channel_count = serial_protocol::kChannelCount;
    config.sample_rate = m_sample_rate;

    m_raw_buffer.reset(config.channel_count, m_sample_rate, kMaxWindowSeconds * 6);
    reset_channels(m_channel_count);

    m_collector = new SerialCollector(this);
    m_collector->set_config(config);
    // 本对象就是数据块的消费者：deliver() 里再转交给算法线程，并在此把原始样本
    // 写进原始环形缓冲（供 ASR 拟合参考矩阵）。采集线程不再自己写一份 ——
    // 那样同一批样本会被采集线程与 deliver() 各写一次，ASR 参考数据翻倍、
    // 时间戳来回跳
    m_collector->set_sink(this);

    // 采集线程的信号一律队列投递（发信方在工作线程）
    QObject::connect(m_collector, &SerialCollector::port_opened, this,
                     &AcquisitionBridge::on_port_opened, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::port_open_failed, this,
                     &AcquisitionBridge::on_port_open_failed, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::port_closed, this,
                     &AcquisitionBridge::on_port_closed, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::device_lost, this,
                     &AcquisitionBridge::on_device_lost, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::stats_changed, this,
                     &AcquisitionBridge::on_stats_changed, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::status_message, this,
                     &AcquisitionBridge::on_status_message, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::failed, this, &AcquisitionBridge::on_failed,
                     Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::collecting_changed, this,
                     &AcquisitionBridge::on_collecting_changed, Qt::QueuedConnection);
    QObject::connect(m_collector, &SerialCollector::recording_changed, this,
                     &AcquisitionBridge::on_recording_changed, Qt::QueuedConnection);

    set_status(tr("正在打开 %1…").arg(config.port_name));
    m_collector->start();
    return true;
}

void AcquisitionBridge::close_port()
{
    if (m_collector == nullptr)
    {
        reset_port_flags();
        return;
    }

    m_collector->request_stop();
    if (!m_collector->wait(5000))
    {
        // 采集线程里没有跨调用的外部资源（串口与文件都是 run() 的栈上对象），
        // 所以这里敢强制终止 —— 丢一段录像好过整个程序退不出去。
        // 算法线程绝不能用这一招（它持有 Python 会话对象，杀掉后 finalize 必崩）。
        //
        // 注意这条路径**不只在退出时走**：用户换串口也会经过这里（open_port 会
        // 先 close_port）。被强杀的线程不会执行 QSerialPort 的析构，串口句柄
        // 会一直留到进程退出，Windows 下同一个口下次就打不开了。
        // 代价可以接受（超时本身已经是异常情况），但要知道它比「丢一段录像」更重
        qWarning() << "[acquisition] 采集线程未能在超时内退出，强制终止；"
                      "串口句柄可能要到进程退出才会释放";
        m_collector->terminate();
        m_collector->wait(1000);
    }

    // deleteLater 而不是直接 delete：现在可能还在处理本线程的队列信号，
    // 当场析构会让那些信号打到已释放的对象上
    m_collector->deleteLater();
    m_collector = nullptr;

    reset_port_flags();
}

// ==================== 采集 ====================

// 连接设备（供「开始采集」弹确认框**之前**调用）。
//
// 设计稿上**没有串口选择控件** —— 它的前提是「设备已连接」（顶栏那个
// 「Neurolink-6016 已连接」的胶囊）。所以这里按这个前提办事：自动打开枚举到的
// 那个口。参考实现的约定是取最后一个（真机通常枚举成编号最大的那个 COM 口）。
//
// 与 open_port 的差别在于「等结果」：open_port 只表示「已发起」，串口在采集线程里
// 异步打开，结果经队列信号回来。而确认框里的「连接」一栏就绑在 portOpen 上，
// 发起后立刻弹框会先显示成「未连接」—— 所以这里转一会儿事件循环，拿到确定的结果
//（打开成功或失败）再返回。等待有上限，不会把界面卡死
bool AcquisitionBridge::connect_device()
{
    // 演示模式下没有串口，直接算作已连接
    if (m_demo_enabled)
    {
        return true;
    }

    // 已经开着（可能是之前连的），直接报告当前状态
    if (collector_active())
    {
        return m_port_open;
    }

    refresh_ports();
    if (m_available_ports.isEmpty())
    {
        set_error(tr("没有找到可用的串口，请检查设备连接与驱动"));
        return false;
    }

    const QString port_name = m_available_ports.last();
    emit logMessage(tr("串口未打开，自动使用 %1").arg(port_name));
    // 先清掉上一轮的错误，好在等待时用它判断「失败已经回来了」
    clear_error();
    if (!open_port(port_name, 921600, m_sample_rate))
    {
        return false;
    }

    QElapsedTimer timer;
    timer.start();
    while (!m_port_open && m_error_text.isEmpty() && timer.elapsed() < 2000)
    {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(5);
    }
    // 收尾再转一次，把最后那个 portStateChanged 也送到 QML
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return m_port_open;
}

bool AcquisitionBridge::start_collection(const QString &directory, const QString &patient_no)
{
    // 演示模式下已经在灌数据了，不需要串口也不需要落盘
    if (m_demo_enabled)
    {
        return true;
    }

    // 串口在登录成功后就连上了，这里不再自动补连（连接已与采集解耦）：
    // 没连上就明确报错返回，不硬着头皮往下发采集指令
    if (!collector_active())
    {
        set_error(tr("请先连接设备"));
        return false;
    }

    // 算法会话：串口已经打开时也可以先建会话再采集，这样第一块数据就能被处理。
    // 会话建立是异步的，界面靠 sessionState 变化得知结果
    push_session_config();

    // 落盘：默认自动写文件，格式用二进制 —— 体积小、无格式化开销，
    // 而且文件头自带元信息，回放时不用另找参数
    SerialCollector::StartRequest request;
    request.format = SerialCollector::SaveFormat::Binary;
    request.channel_names = eeg_montage::channel_names();
    // 落盘采样率：与设备不同（整数倍）时采集线程会在写文件时升采样。
    // 只影响文件，采集/算法/显示仍按设备原始速率（见 set_record_sample_rate）
    request.save_sample_rate = m_record_sample_rate;

    // 目录不存在时由采集线程的 recording_start() 建出来（它本来就要处理
    // 落盘失败的各种情况，建目录属于同一件事），这里不重复
    QString folder = directory.trimmed().isEmpty() ? default_record_directory()
                                                   : directory.trimmed();
    // 按患者分目录：同一台机器上多位患者的记录各自成夹，便于整份归档/删除。
    // 夹名用病历号而不是姓名（见 patient_folder_name）
    const QString patient_dir = patient_folder_name(patient_no);
    if (!patient_dir.isEmpty())
        folder = QDir(folder).filePath(patient_dir);

    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    request.save_path = QDir(folder).filePath(stamp + QStringLiteral(".eegbin"));
    // 同一秒内重复开始会撞名，加后缀而不是覆盖 —— 覆盖会静默丢掉上一段
    for (int suffix = 1; QFileInfo::exists(request.save_path) && suffix < 1000; ++suffix)
    {
        request.save_path = QDir(folder).filePath(
            QStringLiteral("%1_%2.eegbin").arg(stamp).arg(suffix));
    }

    m_collect_timer.start();
    m_events.clear();
    emit eventsChanged();

    // 新一段采集从空图开始：不清显示缓冲的话，上一段的波形还留着，
    // 新样本接在后面写，画面看起来就像没重新开始
    clear_display();

    // 仅当设备此刻还停在阻抗上传模式（点过「阻抗扫描」，且那次扫描的 1.2 秒等待
    // 还没走完 / 结果还没读回）才补发 's'：只发 'b' 不足以让它切回常规脑电流。
    // 两条命令按入队顺序执行（见 SerialCollector::run 的命令批处理），线上顺序即 's' → 'b'
    //
    // 没扫描过就**不能**发 's'：设备会把它当成一次停止，紧跟着的 'b' 被冲掉，
    // 结果是点了「开始采集」却收不到任何数据帧、波形一片空白
    if (m_impedance_pending)
    {
        m_collector->post_impedance_stop();
        m_impedance_pending = false;
    }
    m_collector->post_start(request);
    audit_log::record(QStringLiteral("开始采集（患者：%1，落盘：%2）")
                          .arg(patient_no.trimmed().isEmpty() ? QStringLiteral("未指定")
                                                              : patient_no.trimmed(),
                               request.save_path));
    return true;
}

void AcquisitionBridge::stop_collection()
{
    if (m_demo_enabled)
    {
        stop_demo_source();
        return;
    }
    if (collector_active())
    {
        m_collector->post_stop();
        audit_log::record(QStringLiteral("停止采集"));
    }
    m_worker.post_close_session();
}

void AcquisitionBridge::reset_session()
{
    m_worker.post_reset();
}

// ==================== 演示数据源 ====================

void AcquisitionBridge::start_demo_source()
{
    if (m_demo_enabled)
    {
        return;
    }
    m_demo_enabled = true;

    m_sample_rate = 1000;
    reset_channels(m_channel_count);
    m_raw_buffer.reset(eeg_montage::kChannelCount, m_sample_rate, kMaxWindowSeconds * 6);

    // 走真实路径：先建会话，再灌数据
    push_session_config();

    m_collect_timer.start();
    m_events.clear();
    emit eventsChanged();

    // 同 start_collection()：新一段采集从空图开始
    clear_display();

    m_demo_sequence_id = 0;
    m_demo_timestamp_ns = 1000000000LL;   // 从 1 秒处起步，避开 0 这个哨兵值
    m_demo_timer.start();

    m_collecting = true;
    m_recording_path = tr("（演示数据源，不落盘）");
    emit demoSourceChanged();
    emit collectingChanged();
    emit logMessage(tr("已切到演示数据源：合成 10 Hz α 波 + 50 Hz 工频，"
                       "不接设备、不落盘"));
}

void AcquisitionBridge::stop_demo_source()
{
    if (!m_demo_enabled)
    {
        return;
    }
    m_demo_enabled = false;
    m_demo_timer.stop();
    m_collecting = false;
    m_recording_path.clear();
    m_worker.post_close_session();

    emit demoSourceChanged();
    emit collectingChanged();
    emit logMessage(tr("演示数据源已停止"));
}

void AcquisitionBridge::tick_demo_source()
{
    // 每拍 33 个样本（33ms @ 1000Hz），与真实采集的分块节拍一致
    constexpr int kFrames = 33;
    constexpr double kPi = 3.14159265358979323846;

    SignalChunk chunk;
    chunk.channels = eeg_montage::kChannelCount;
    chunk.samples_per_channel = kFrames;
    chunk.first_sequence_id = m_demo_sequence_id;
    chunk.first_timestamp_ns = m_demo_timestamp_ns;
    chunk.samples.resize(static_cast<qsizetype>(chunk.channels) * kFrames);

    for (int ch = 0; ch < chunk.channels; ++ch)
    {
        // 每通道幅度与相位都不同：相位铺满 0~π，重参考（默认全脑平均）之后
        // 才留得下残差。16 个通道喂同一条波形的话会被重参考减成 0
        const double amplitude = 12.0 + static_cast<double>(ch) * 1.5;
        const double phase = kPi * static_cast<double>(ch) / chunk.channels;
        for (int i = 0; i < kFrames; ++i)
        {
            const double t = static_cast<double>(m_demo_sequence_id + i) / 1000.0;
            chunk.samples[static_cast<qsizetype>(i) * chunk.channels + ch] =
                static_cast<float>(amplitude * std::sin(2.0 * kPi * 10.0 * t + phase)
                                   + 4.0 * std::sin(2.0 * kPi * 50.0 * t + phase)
                                   + 1.5 * std::sin(2.0 * kPi * 0.3 * t));
        }
    }

    m_demo_sequence_id += kFrames;
    m_demo_timestamp_ns += kFrames * 1000000;

    // 必须是 queue 投递而不是直接调：deliver() 在真实链路里跑在采集线程上，
    // 这里直接调会让「采集线程」变成 GUI 线程，掩盖掉跨线程的问题。
    // 用一个 0 延时的单次投递模拟那一次跨线程交接
    QMetaObject::invokeMethod(
        this,
        [this, chunk]() {
            if (!m_demo_enabled)
            {
                return;
            }
            const bool accepted = deliver(chunk);
            if (!accepted)
            {
                // 队列满（算法跟不上）：与真实链路一样记成数据缺口，
                // 不能悄悄丢 —— 下次 push_block 的序列号就接不上了
                GapRange gap;
                gap.first_missing_sequence_id = chunk.first_sequence_id;
                gap.last_missing_sequence_id =
                    chunk.first_sequence_id + chunk.samples_per_channel - 1;
                gap.start_timestamp_ns = chunk.first_timestamp_ns;
                gap.end_timestamp_ns = chunk.first_timestamp_ns;
                gap.reason = QStringLiteral("demo_backpressure");
                deliver_gap(gap);
            }
        },
        Qt::QueuedConnection);
}

void AcquisitionBridge::clear_error()
{
    if (m_error_text.isEmpty() && m_error_code.isEmpty())
    {
        return;
    }
    m_error_text.clear();
    m_error_code.clear();
    m_error_message.clear();
    m_can_reset = false;
    emit errorTextChanged();
    emit sessionStateChanged();
}

// ==================== 波形 ====================

void AcquisitionBridge::reset_channels(int channels)
{
    m_channel_count = std::clamp(channels, 1, eeg_montage::kChannelCount);

    const int wanted = std::clamp(m_sample_rate * kMaxWindowSeconds, 1, kMaxSamplesPerChannel);

    {
        // 容量、缓冲、写头三者必须在**同一把锁内**一起更新。
        //
        // 容量是采集线程 append_to_display() 用来算写指针的（head % capacity）：
        // 若在锁外先改容量、再进锁重建缓冲，中间那个窗口里采集线程会拿新容量
        // 去索引旧缓冲（那是按旧容量分配的），直接越界写。
        // 当前调用路径不会真的撞上（open_port 会先等采集线程退出），
        // 但这个不变式很脆，不该靠调用顺序来保证
        const QMutexLocker locker(&m_display_mutex);
        if (m_display_capacity != wanted || m_display_data.isEmpty())
        {
            // 只有容量真的变了（换采样率、重开串口）才重建。
            //
            // 切显示通道数**不重建**：原始数据流没有变，清空只会让画面白掉一截，
            // 而用户看到的「切档位后波形不对」里有一半就是这个
            m_display_capacity = wanted;
            m_display_data.assign(static_cast<qsizetype>(m_display_capacity)
                                      * eeg_montage::kChannelCount,
                                  0.0f);
            m_display_head = 0;
            m_display_filled = 0;
        }
    }

    // 显隐掩码只在通道数真的变了时重建，重叠部分原样保留
    if (m_channel_visible.size() != m_channel_count)
    {
        QVector<bool> rebuilt(m_channel_count, true);
        for (int i = 0; i < std::min(m_channel_visible.size(), rebuilt.size()); ++i)
        {
            rebuilt[i] = m_channel_visible.at(i);
        }
        m_channel_visible = rebuilt;
        emit channelVisibilityChanged();
    }

    emit channelCountChanged();

    // 同理：泳道条数变了要立刻重画，不然空图状态下切档位看不出任何变化
    m_rendered_generation = -1;
    render_wave();
}

// 把一块样本写进显示缓冲。**只在 GUI 线程上调用**（pump_display）。
//
// 喂进来的是显示侧 Python 滤波后的值；滤波不可用时是未滤波的原始采集值
//（pump_display 里兜底），保证「设备还在采」这件事在界面上始终看得见
void AcquisitionBridge::append_to_display(const SignalChunk &chunk)
{
    if (chunk.channels <= 0 || chunk.samples_per_channel <= 0 || chunk.samples.isEmpty())
    {
        return;
    }

    const QMutexLocker locker(&m_display_mutex);
    if (m_display_data.isEmpty() || chunk.channels != eeg_montage::kChannelCount)
    {
        // 通道数与缓冲约定不符：重建交给 GUI 线程的 reset_channels() 做，这里直接丢
        return;
    }

    for (int i = 0; i < chunk.samples_per_channel; ++i)
    {
        std::memcpy(m_display_data.data()
                        + static_cast<qsizetype>(m_display_head) * eeg_montage::kChannelCount,
                    chunk.samples.constData()
                        + static_cast<qsizetype>(i) * eeg_montage::kChannelCount,
                    static_cast<size_t>(eeg_montage::kChannelCount) * sizeof(float));
        m_display_head = (m_display_head + 1) % m_display_capacity;
        if (m_display_filled < m_display_capacity)
        {
            ++m_display_filled;
        }
    }
    // 记一次「有新数据了」。GUI 线程的定时器靠它决定要不要重绘
    m_display_generation.fetch_add(1, std::memory_order_relaxed);
}

// 算法线程投递回来的处理结果（队列连接，落在 GUI 线程）。
//
// 只把块压进显示待处理队列，不做别的：真正的写缓冲/重绘交给 m_display_timer
// 的 pump_display，把「算法出块」与「界面重绘」解耦，避免每来一块就画一次
void AcquisitionBridge::on_block_processed(const SignalChunk &chunk)
{
    if (chunk.channels <= 0 || chunk.samples_per_channel <= 0 || chunk.samples.isEmpty())
    {
        return;
    }

    // 生产与消费都在 GUI 线程，队列无需加锁。满了丢最旧的 ——
    // 显示宁可跳一下也不能让队列无限增长；丢块只影响画面连续性，不影响算法结果
    if (m_display_pending.size() >= kDisplayPendingCapacity)
    {
        m_display_pending.removeFirst();
    }
    m_display_pending.append(chunk);
}

// 消费算法线程的处理结果（GUI 线程定时回调，m_display_timer 驱动）。
//
// 算法线程只管把处理后的块 emit 出来，写缓冲与绘制放在这里做：
// 一次回调把攒下的块全部写进显示缓冲，最后统一重画
void AcquisitionBridge::pump_display()
{
    // 把攒下的块整体搬出来。队列生产/消费都在 GUI 线程，swap 后即可在锁外逐块处理
    QVector<SignalChunk> batch;
    batch.swap(m_display_pending);

    for (const SignalChunk &chunk : batch)
    {
        append_to_display(chunk);
    }

    if (!batch.isEmpty())
    {
        render_wave();
    }
}

void AcquisitionBridge::clear_display()
{
    // 清空还没处理的待处理块，避免上一段采集残留的样本在本段开头被补画出来
    m_display_pending.clear();

    {
        const QMutexLocker locker(&m_display_mutex);
        if (!m_display_data.isEmpty())
        {
            std::fill(m_display_data.begin(), m_display_data.end(), 0.0f);
        }
        m_display_head = 0;
        m_display_filled = 0;
    }

    // 强制下一次 render_wave() 重画：它平时靠「generation 变了」判断要不要画，
    // 而清空缓冲并没有新数据进来，不这样处理画面会一直停在上一段的波形上
    m_rendered_generation = -1;
    render_wave();
}

void AcquisitionBridge::render_wave()
{
    // 只在显示缓冲真的变了时才重画。
    //
    // 不能无条件每 33ms 画一次：串口没开、或采集已停时数据根本不进来，
    // 那样会白烧 CPU 让界面在空闲时也发热
    const qint64 generation = m_display_generation.load(std::memory_order_relaxed);
    if (generation == m_rendered_generation)
    {
        return;
    }
    m_rendered_generation = generation;

    // 锁内取窗口快照、锁外绘制。绘制要几毫秒，握着锁画会把采集线程挡在外面 ——
    // 而采集线程被挡住意味着串口缓冲积压，那正是要避免的事
    int samples_per_channel = 0;
    {
        const QMutexLocker locker(&m_display_mutex);
        const int wanted = std::min(m_display_filled,
                                   static_cast<int>(m_time_window * m_sample_rate));
        if (wanted > 0 && m_display_capacity > 0)
        {
            int start = (m_display_head - wanted) % m_display_capacity;
            if (start < 0)
            {
                start += m_display_capacity;
            }

            samples_per_channel = wanted;
            m_lane_window.resize(static_cast<qsizetype>(wanted) * eeg_montage::kChannelCount);
            for (int i = 0; i < wanted; ++i)
            {
                const int slot = (start + i) % m_display_capacity;
                std::memcpy(m_lane_window.data()
                                + static_cast<qsizetype>(i) * eeg_montage::kChannelCount,
                            m_display_data.constData()
                                + static_cast<qsizetype>(slot) * eeg_montage::kChannelCount,
                            static_cast<size_t>(eeg_montage::kChannelCount) * sizeof(float));
            }
        }
    }

    render_wave_image(m_lane_window, samples_per_channel);

    ++m_wave_revision;
    emit waveRevisionChanged();
}

void AcquisitionBridge::render_wave_image(const QVector<float> &window, int samples_per_channel)
{
    const QMutexLocker locker(&m_wave_mutex);
    if (m_wave_view_size.isEmpty() || m_wave_view_size.width() < 8 || m_wave_view_size.height() < 8)
    {
        return;
    }

    const int width = m_wave_view_size.width();
    const int height = m_wave_view_size.height();
    if (m_wave_image.size() != m_wave_view_size)
    {
        m_wave_image = QImage(m_wave_view_size, QImage::Format_ARGB32_Premultiplied);
    }
    // 背景保持透明：面板底色由 QML 那边的 Rectangle 提供，
    // 这里画死一个颜色的话，浅色主题下会和设计稿对不上
    if (m_wave_image.isNull())
    {
        return;
    }
    m_wave_image.fill(Qt::transparent);

    QPainter painter(&m_wave_image);

    const int lanes = std::max(1, m_channel_count);
    const double step = static_cast<double>(height) / lanes;
    const double half = std::max(2.0, step / 2.0 - 3.0);
    // 文字与线宽按高度等比缩放：图是按物理像素出的，高 DPI 下要跟着放大，
    // 否则线条只有半个像素、字小得看不清
    const double ui_scale = static_cast<double>(height) / 770.0;

    // ---- 每个通道一个独立泳道：外框 + 零线 ----
    // 抗锯齿关掉：1 像素的直线开了抗锯齿会糊成两像素的灰线
    painter.setRenderHint(QPainter::Antialiasing, false);
    for (int c = 0; c < lanes; ++c)
    {
        const double top = step * c;
        painter.setPen(QPen(QColor(0, 0, 0, 26), 1));
        painter.drawRect(QRectF(0.5, top + 0.5, width - 1.0, step - 1.0));

        // 零线：波形的基准，也是判断基线漂移的依据
        painter.setPen(QPen(QColor(0, 0, 0, 40), 1));
        const double center = top + step / 2.0;
        painter.drawLine(QPointF(0.0, center), QPointF(width, center));
    }

    // ---- 纵向时间网格。三条竖线落在时间轴 1/4、2/4、3/4 处，与底部刻度对齐 ----
    // 原来照抄设计稿的比例（186/470/743），而底部刻度是按等分生成的，
    // 网格线与刻度错开，光看线根本读不出是第几秒
    painter.setPen(QPen(QColor(0, 0, 0, 36), 1));
    static const double kGridColumns[] = {0.25, 0.5, 0.75};
    for (const double fraction : kGridColumns)
    {
        const double x = std::round(width * fraction) + 0.5;
        painter.drawLine(QPointF(x, 0.0), QPointF(x, static_cast<double>(height)));
    }

    // ---- 事件竖线 + 顶部标签 ----
    // 位置随窗口滑动：采集时刻 t 的事件，在当前窗口里离右端 (now - t) 秒，
    // 划出窗口就不画
    if (m_collect_timer.isValid() && !m_events.isEmpty())
    {
        const double now = static_cast<double>(m_collect_timer.elapsed()) / 1000.0;
        const double window_seconds = std::max(0.1, m_time_window);
        QFont label_font = painter.font();
        label_font.setPixelSize(std::max(8, static_cast<int>(std::round(12.0 * ui_scale))));

        for (const QVariant &entry : m_events)
        {
            const QVariantMap event = entry.toMap();
            const double age = now - event.value(QStringLiteral("offsetSeconds")).toDouble();
            if (age < 0.0 || age > window_seconds)
            {
                continue;
            }

            const double x = width * (1.0 - age / window_seconds);
            const QColor color(event.value(QStringLiteral("dotColor")).toString());
            const QString label = event.value(QStringLiteral("label")).toString();

            painter.setPen(QPen(color, 1));
            painter.drawLine(QPointF(std::round(x) + 0.5, 0.0),
                             QPointF(std::round(x) + 0.5, static_cast<double>(height)));

            painter.setFont(label_font);
            const QFontMetricsF metrics(label_font);
            const double chip_width = metrics.horizontalAdvance(label) + 12.0 * ui_scale;
            const double chip_height = metrics.height();
            const QRectF chip(x - chip_width / 2.0, 2.0 * ui_scale, chip_width, chip_height);

            painter.setRenderHint(QPainter::Antialiasing, true);
            painter.setPen(Qt::NoPen);
            painter.setBrush(color);
            painter.drawRoundedRect(chip, 4.0 * ui_scale, 4.0 * ui_scale);
            painter.setPen(Qt::white);
            painter.drawText(chip, Qt::AlignCenter, label);
            painter.setRenderHint(QPainter::Antialiasing, false);
        }
    }

    // ---- 波形 ----
    if (samples_per_channel <= 1 || window.isEmpty())
    {
        return;   // 还没数据：只留空泳道
    }

    // 折线开抗锯齿。实测它几乎不花时间（开 13.2ms / 关 13.4ms，Qt 光栅引擎
    // 的 AA 走的是同一套快速路径），而关掉的话斜线段会有肉眼可见的台阶 ——
    // 这条波形是给人看形状的，不值得为省不到 1% 换掉画质
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setPen(Qt::NoPen);

    // 数据只画在右侧：时窗是 2s 而只采到 0.5s 时，就只占右边 1/4 宽度，左边留空。
    // 不加这个限制的话，不足一屏的样本会被拉伸铺满整个时窗，看着像已经采满，
    // 底部刻度也就读不出真实时间了
    const int full_window_samples =
        std::max(1, static_cast<int>(m_time_window * m_sample_rate));
    const int data_x0 =
        samples_per_channel >= full_window_samples
            ? 0
            : std::max(0, width - static_cast<int>(static_cast<qint64>(width)
                                                    * samples_per_channel / full_window_samples));
    const int data_columns = width - data_x0;   // 数据实际占据的像素列数

    const QVector<int> indices = eeg_montage::display_channel_indices(m_channel_count);
    const QStringList colors = channel_colors();

    QVector<QPointF> points(width * 2);
    for (int c = 0; c < lanes && c < indices.size(); ++c)
    {
        if (!is_channel_visible(c))
        {
            continue;
        }

        const int source_channel = indices.at(c);
        const double top = step * c;
        const double center = top + step / 2.0;
        // 每个样本都钳在自己泳道内。真实 EEG 的运动伪迹轻松超过固定量程，
        // 不钳的话超量程部分会画到相邻几路的地盘上，看着就是几路叠成一团
        const double low_limit = top + 2.0;
        const double high_limit = top + step - 2.0;
        const double range = lane_range_uv(source_channel, window, samples_per_channel);
        const double scale = half / range;

        // 每列取该列的最小/最大值，两点连成一段 —— 点远多于像素列时
        // 才能保住肉眼要看的尖峰，否则正弦会被抽成锯齿
        // 显示用的去直流：减去本窗口内该通道的均值。
        //
        // 这不是「后处理」——它是示波器上的 AC 耦合：每帧现算，**没有跨帧状态**，
        // 所以不会像算法侧那个因果高通一样在启动时产生几秒的瞬变。
        //
        // 为什么必须有它：电极的半电池电位是几百 mV 量级，脑电只有几十 µV。
        // 不减掉直流，接得不好的那几路会顶到格子上沿连成一条平线（实测悬空电极
        // 在 533000 µV），整屏 16 路里只有接好的那一路看得出东西
        double offset = 0.0;
        if (m_dc_removal)
        {
            double sum = 0.0;
            for (int i = 0; i < samples_per_channel; ++i)
            {
                sum += window.at(static_cast<qsizetype>(i) * eeg_montage::kChannelCount
                                 + source_channel);
            }
            offset = sum / samples_per_channel;
        }

        // 一次分配、按下标写入。这份缓冲是成员而不是每帧新建：
        // 16 路 × 两千多个点，每帧重新分配一次是白白的开销
        const float *samples = window.constData();
        // 只遍历数据占据的那些列：左边留空的部分不画（画了会把波形拉满整屏）
        for (int x = data_x0; x < width; ++x)
        {
            const int local = x - data_x0;
            const int begin = static_cast<int>(
                static_cast<qint64>(local) * samples_per_channel / data_columns);
            const int end = std::max(
                begin + 1,
                static_cast<int>(static_cast<qint64>(local + 1) * samples_per_channel
                                 / data_columns));

            float minimum = std::numeric_limits<float>::max();
            float maximum = std::numeric_limits<float>::lowest();
            for (int i = begin; i < end && i < samples_per_channel; ++i)
            {
                const float value = samples[static_cast<qsizetype>(i) * eeg_montage::kChannelCount
                                            + source_channel];
                minimum = std::min(minimum, value);
                maximum = std::max(maximum, value);
            }
            minimum -= static_cast<float>(offset);
            maximum -= static_cast<float>(offset);
            if (minimum > maximum)
            {
                minimum = 0.0f;
                maximum = 0.0f;
            }

            points[x * 2] = QPointF(x, std::clamp(center - minimum * scale, low_limit, high_limit));
            points[x * 2 + 1] = QPointF(x, std::clamp(center - maximum * scale, low_limit, high_limit));
        }

        painter.setPen(QPen(QColor(colors.value(c)), 1.0 * ui_scale));
        painter.drawPolyline(points.constData() + data_x0 * 2,
                             static_cast<int>(points.size()) - data_x0 * 2);
    }
}

double AcquisitionBridge::lane_range_uv(int source_channel, const QVector<float> &window,
                                        int samples_per_channel) const
{
    if (m_y_range_uv > 0)
    {
        return m_y_range_uv;
    }
    if (samples_per_channel <= 0 || window.isEmpty())
    {
        return 100.0;
    }

    // 自动量程：取窗口内绝对值峰值，向上取到一个整齐档位。
    // 每个通道各自算，所以自动量程下通道之间不能直接比大小。
    //
    // 峰值的基准要和画图时一致：开了去直流就按去直流后的值算，否则直流偏置
    // （几百 ~ 几千 µV）会把量程顶到几千 µV，几十 µV 的脑电被压成一条平线
    double offset = 0.0;
    if (m_dc_removal)
    {
        double sum = 0.0;
        for (int i = 0; i < samples_per_channel; ++i)
        {
            sum += window.at(static_cast<qsizetype>(i) * eeg_montage::kChannelCount
                             + source_channel);
        }
        offset = sum / samples_per_channel;
    }

    float peak = 0.0f;
    for (int i = 0; i < samples_per_channel; ++i)
    {
        const double value = window.at(static_cast<qsizetype>(i) * eeg_montage::kChannelCount
                                       + source_channel)
                             - offset;
        peak = std::max(peak, static_cast<float>(std::fabs(value)));
    }

    static const double kSteps[] = {10.0, 25.0, 50.0, 100.0, 200.0, 500.0,
                                    1000.0, 2000.0, 5000.0, 10000.0};
    for (const double step : kSteps)
    {
        if (peak <= step)
        {
            return step;
        }
    }
    return 10000.0;
}

void AcquisitionBridge::set_wave_view_size(int width, int height)
{
    const QSize size(std::max(0, width), std::max(0, height));
    if (size == m_wave_view_size)
    {
        return;
    }
    {
        const QMutexLocker locker(&m_wave_mutex);
        m_wave_view_size = size;
    }

    // 尺寸一变就立刻重画一次。
    //
    // 不能等下一个数据节拍：刚进采集页、或采集还没开始时缓冲里没有数据，
    // 「显示缓冲变了才重画」那条路永远不触发 —— 结果是整片波形区一片空白，
    // 连泳道和网格都没有。空图也要把网格画出来，那是这一页的底
    m_rendered_generation = -1;
    render_wave();
}

QImage AcquisitionBridge::current_wave_image() const
{
    const QMutexLocker locker(&m_wave_mutex);
    if (m_wave_image.isNull())
    {
        // 还没画过。**不能返回空 QImage**：QML 的 Image 会打一条
        // "Failed to get image from provider"，而这是正常状态（刚启动、
        // 或显示区尺寸还没报上来）。给一张全透明图，界面上什么都不会画
        QImage placeholder(std::max(1, m_wave_view_size.width()),
                           std::max(1, m_wave_view_size.height()),
                           QImage::Format_ARGB32_Premultiplied);
        placeholder.fill(Qt::transparent);
        return placeholder;
    }
    return m_wave_image.copy();
}

QQuickImageProvider *AcquisitionBridge::create_wave_image_provider()
{
    return new WaveformImageProvider(this);
}

void AcquisitionBridge::set_channel_count(int count)
{
    const int clamped = std::clamp(count, 1, eeg_montage::kChannelCount);
    if (clamped == m_channel_count)
    {
        return;
    }
    // 只改显示，**不动算法会话**：算法侧始终拿全部 16 路（协议就只给 16 路），
    // 这个档位纯粹决定画几条泳道。
    //
    // 早先这里会重建会话，那是个 bug：重建会把滤波状态清零，而因果 0.5Hz 高通
    // 从零状态消掉重参考带进来的直流要四五秒 —— 每次切档位都会换来一段
    // 从十几万 µV 衰减下来的巨大瞬变，波形、地形图、频谱一起受影响
    reset_channels(clamped);

    // 频谱默认通道跟着档位走：切换档位后，原来选中的那一路可能已经不在显示
    // 集合里了，继续留着旧名字会让频谱画一条界面上看不到的通道。回到新档位的
    // 第一路（16 档下就是 Fp1）
    const QStringList names = channel_names();
    const QString first = names.isEmpty() ? QString() : names.first();
    if (!first.isEmpty() && first != m_spectrum_channel)
    {
        m_spectrum_channel = first;
        emit spectrumChannelChanged();
    }

    emit logMessage(tr("显示通道数改为 %1").arg(clamped));
}

void AcquisitionBridge::set_record_sample_rate(int rate)
{
    // 非正数归零（=与设备一致）；上限与设备采样率取同一范围，挡住离谱值
    const int clamped = rate > 0 ? std::clamp(rate, 1, 100000) : 0;
    if (clamped == m_record_sample_rate)
    {
        return;
    }
    m_record_sample_rate = clamped;
    emit recordSampleRateChanged();
}

// 与 SerialCollector 里决定要不要升采样的规则保持一致：只有落盘速率是设备
// 速率的**整数倍且更大**时才升采样，其余情况原样落盘（速率即设备速率）
int AcquisitionBridge::effective_record_sample_rate() const
{
    const int source = std::max(1, m_sample_rate);
    if (m_record_sample_rate <= source || m_record_sample_rate % source != 0)
    {
        return source;
    }
    return m_record_sample_rate;
}

bool AcquisitionBridge::is_channel_visible(int channel) const
{
    return channel >= 0 && channel < m_channel_visible.size() && m_channel_visible.at(channel);
}

void AcquisitionBridge::set_channel_visible(int channel, bool visible)
{
    if (channel < 0 || channel >= m_channel_visible.size()
        || m_channel_visible.at(channel) == visible)
    {
        return;
    }
    m_channel_visible[channel] = visible;
    emit channelVisibilityChanged();
}

void AcquisitionBridge::set_all_channels_visible(bool visible)
{
    bool changed = false;
    for (int i = 0; i < m_channel_visible.size(); ++i)
    {
        if (m_channel_visible.at(i) != visible)
        {
            m_channel_visible[i] = visible;
            changed = true;
        }
    }
    if (changed)
    {
        emit channelVisibilityChanged();
    }
}

void AcquisitionBridge::set_time_window(double seconds)
{
    const double clamped = std::clamp(seconds, 0.1, 10.0);
    if (qFuzzyCompare(clamped, m_time_window))
    {
        return;
    }
    m_time_window = clamped;
    emit timeWindowChanged();

    // 时窗变了波形也得跟着重画。
    //
    // render_wave() 只在「显示缓冲有新样本」时才画（见那里的注释）：采集停下、
    // 或者根本没接设备时它永远不会触发，于是点了时基界面纹丝不动。
    // 这里强制作废上一帧，立刻按新时窗画一次
    m_rendered_generation = -1;
    render_wave();
}

void AcquisitionBridge::set_y_range_uv(int range_uv)
{
    if (range_uv == m_y_range_uv)
    {
        return;
    }
    m_y_range_uv = range_uv;
    emit yRangeChanged();

    // 同 set_time_window()：量程变了必须立刻重画一次，否则采集不在跑的时候
    // 点幅值看不到任何反馈
    m_rendered_generation = -1;
    render_wave();
}

void AcquisitionBridge::set_dc_removal(bool enabled)
{
    if (enabled == m_dc_removal)
    {
        return;
    }
    m_dc_removal = enabled;
    // 下一帧就会按新设置重画，不用额外通知：波形每 33ms 重画一次，
    // 而 dcRemovalChanged 只用于让界面上的开关回读状态
    emit dcRemovalChanged();
}

void AcquisitionBridge::set_grayscale_wave(bool on)
{
    if (on == m_grayscale_wave)
    {
        return;
    }
    m_grayscale_wave = on;
    // 与 set_dc_removal 不同：这里换的是**颜色**而不是某帧数据，空闲（不采集）时
    // 没有新帧可等，所以必须强制立刻重画一帧。m_rendered_generation 置 -1 让
    // render_wave() 的「代次没变就跳过」判据失效（同 set_wave_view_size 的做法）
    m_rendered_generation = -1;
    render_wave();
    emit waveColorModeChanged();
}

QString AcquisitionBridge::default_record_dir() const
{
    // 面向界面显示：转成 Windows 风格的反斜杠。内部落盘用正斜杠（QDir 两者都认），
    // 但设置页里一条 d:/... 的路径看着不像本机目录，容易被当成没生效
    return QDir::toNativeSeparators(default_record_directory());
}

QString AcquisitionBridge::snapshot_dir()
{
    // 与 records 一样落在 exe 旁边：截图随程序一起拷贝/归档，不依赖 %LOCALAPPDATA%
    const QString base = QCoreApplication::applicationDirPath();
    const QString dir = QDir::fromNativeSeparators(base) + QStringLiteral("/snapshoot");
    if (!QDir().mkpath(dir))
        return QString();
    // 返回正斜杠路径，QML 直接拼 "/文件名" 即可，不必再管分隔符
    return dir;
}

QStringList AcquisitionBridge::channel_names() const
{
    QStringList names;
    const QVector<int> indices = eeg_montage::display_channel_indices(m_channel_count);
    for (const int index : indices)
    {
        names.append(eeg_montage::channel_name(index));
    }
    return names;
}

QStringList AcquisitionBridge::channel_colors() const
{
    // 配色表收在 eeg_montage 里（实时波形、回放预览、后处理三处同源），
    // 下标即通道序号，所以这里按**该路在蒙太奇里的序号**取色，而不是按屏幕上的
    // 第几条泳道 —— 否则切到 8 通道档时 F3 会被涂成 F7 的颜色。
    // 灰度档也遵循同样的「下标即通道序号」规则
    const QStringList palette =
        m_grayscale_wave ? eeg_montage::channel_gray_colors() : eeg_montage::channel_colors();
    QStringList colors;
    const QVector<int> indices = eeg_montage::display_channel_indices(m_channel_count);
    for (const int index : indices)
    {
        colors.append(palette.at(index % palette.size()));
    }
    return colors;
}

QVariantList AcquisitionBridge::channel_visible_mask() const
{
    QVariantList mask;
    mask.reserve(m_channel_visible.size());
    for (const bool visible : m_channel_visible)
    {
        mask.append(visible);
    }
    return mask;
}

// ==================== 滤波与后处理 ====================

void AcquisitionBridge::push_processing_config()
{
    ProcessingParams params = m_processing;
    // ASR 的开关不在 ProcessingParams 里单独存一份：它是界面意图，
    // 能不能真正打开由算法线程按「参考是否建好」决定（见 pythonworker.cpp）
    params.asr_enabled = m_asr_enabled;
    m_worker.post_processing_config(params);
}

void AcquisitionBridge::push_session_config()
{
    SessionConfig config;
    config.sample_rate_hz = m_sample_rate;
    // 滚动缓存必须不小于界面可选的最大查询窗口（时基最大 10 秒）。
    // 留一倍余量：缓存刚被清空时界面还能靠它更快恢复出图
    config.rolling_window_s = 20.0;
    config.reference_method = m_reference_method;
    config.processing = m_processing;
    config.processing.asr_enabled = m_asr_enabled;
    m_worker.post_session_config(config);
}

void AcquisitionBridge::set_high_pass_enabled(bool enabled)
{
    if (enabled == m_processing.high_pass_enabled)
    {
        return;
    }
    m_processing.high_pass_enabled = enabled;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_high_pass_low_hz(double hz)
{
    if (qFuzzyCompare(hz, m_processing.high_pass_low_hz))
    {
        return;
    }
    m_processing.high_pass_low_hz = hz;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_low_pass_enabled(bool enabled)
{
    if (enabled == m_processing.low_pass_enabled)
    {
        return;
    }
    m_processing.low_pass_enabled = enabled;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_low_pass_high_hz(double hz)
{
    if (qFuzzyCompare(hz, m_processing.low_pass_high_hz))
    {
        return;
    }
    m_processing.low_pass_high_hz = hz;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_notch_enabled(bool enabled)
{
    if (enabled == m_processing.notch_enabled)
    {
        return;
    }
    m_processing.notch_enabled = enabled;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_notch_low_hz(double hz)
{
    if (qFuzzyCompare(hz, m_processing.notch_low_hz))
    {
        return;
    }
    m_processing.notch_low_hz = hz;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_notch_high_hz(double hz)
{
    if (qFuzzyCompare(hz, m_processing.notch_high_hz))
    {
        return;
    }
    m_processing.notch_high_hz = hz;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_asr_enabled(bool enabled)
{
    if (enabled == m_asr_enabled)
    {
        return;
    }
    m_asr_enabled = enabled;
    emit processingChanged();
    push_processing_config();
}

void AcquisitionBridge::set_reference_method(const QString &method)
{
    if (method == m_reference_method)
    {
        return;
    }
    m_reference_method = method;
    emit processingChanged();

    // 重参考方式没法用 update_processing_config 改（接口的 OnlineProcessingConfig
    // 里没有它），只能重建会话。会话重建会让算法重新预热、滚动缓存清零 ——
    // 与改一次滤波参数的代价相同，所以对用户是可以预期的
    if (m_collecting)
    {
        push_session_config();
        emit logMessage(tr("重参考方式已改为 %1，正在重建在线会话").arg(method));
    }
}

// ==================== 查询 ====================

void AcquisitionBridge::set_topo_band(const QString &band)
{
    QString preset;
    double low_hz = 0.0;
    double high_hz = 0.0;
    if (!band_from_name(band, &preset, &low_hz, &high_hz))
    {
        // 认不出的名字直接忽略：界面写错时保持原样，总比发一个必然被拒的查询好
        return;
    }
    if (band == m_topo_band)
    {
        return;
    }
    m_topo_band = band;
    emit topoBandChanged();
    m_topo_status_text = tr("正在切换频段…");
    emit topoRevisionChanged();
    // 立刻查一次，不用等下一个 1.2 秒的节拍
    tick_topography();
}

void AcquisitionBridge::set_spectrum_channel(const QString &channel)
{
    if (channel.isEmpty() || channel == m_spectrum_channel)
    {
        return;
    }
    m_spectrum_channel = channel;
    emit spectrumChannelChanged();
    tick_spectrum();
}

void AcquisitionBridge::tick_topography()
{
    if (!m_collecting || m_session_state.isEmpty() || m_session_state == QLatin1String("error")
        || m_session_state == QLatin1String("closed"))
    {
        return;
    }

    constexpr double kWindowS = 2.0;
    // 先看滚动缓存够不够，不够就干脆不发查询。
    // 比发出去再 catch INSUFFICIENT_WINDOW_DATA 干净：省一次 Python 调用，
    // 也省掉「什么算正常异常」这种要靠文档维护的判断
    if (m_rolling_buffer_s < kWindowS) {
        m_topo_status_text = tr("数据累积中 %1 / %2 秒")
                                 .arg(m_rolling_buffer_s, 0, 'f', 1)
                                 .arg(kWindowS, 0, 'f', 0);
        emit topoRevisionChanged();
        return;
    }

    QString preset;
    double low_hz = 0.0;
    double high_hz = 0.0;
    if (!band_from_name(m_topo_band, &preset, &low_hz, &high_hz))
    {
        return;
    }

    TopographyRequest request;
    request.request_id = ++m_topo_request_id;
    request.band_preset = preset;
    request.band_low_hz = low_hz;
    request.band_high_hz = high_hz;
    request.window_s = kWindowS;
    request.grid_width = 64;
    request.grid_height = 64;
    m_worker.post_topography_request(request);
}

void AcquisitionBridge::tick_spectrum()
{
    if (!m_collecting || m_session_state.isEmpty() || m_session_state == QLatin1String("error")
        || m_session_state == QLatin1String("closed"))
    {
        return;
    }

    constexpr double kWindowS = 2.0;
    if (m_rolling_buffer_s < kWindowS)
    {
        m_spectrum_status_text = tr("数据累积中 %1 / %2 秒")
                                     .arg(m_rolling_buffer_s, 0, 'f', 1)
                                     .arg(kWindowS, 0, 'f', 0);
        emit spectrumRevisionChanged();
        return;
    }

    SpectrumRequest request;
    request.request_id = ++m_spectrum_request_id;
    request.channel_name = m_spectrum_channel;
    // 曲线要看到整个有意义的频段，所以查询用 0.5–30 Hz 而不是某个窄带
    request.band_preset = QStringLiteral("full_0_5_30");
    request.band_low_hz = 0.5;
    request.band_high_hz = 30.0;
    request.window_s = kWindowS;
    m_worker.post_spectrum_request(request);
}

// ==================== 算法线程的信号 ====================

void AcquisitionBridge::on_session_opened(int config_version)
{
    Q_UNUSED(config_version);
    m_session_state = QStringLiteral("warming_up");
    m_can_reset = false;
    m_warmup_text = tr("会话已建立，正在预热");
    m_rolling_buffer_s = 0.0;
    m_error_code.clear();
    m_error_message.clear();
    emit sessionStateChanged();
    emit logMessage(tr("在线算法会话已建立"));
}

void AcquisitionBridge::on_session_closed()
{
    m_session_state = QStringLiteral("closed");
    m_can_reset = false;
    m_warmup_text.clear();
    m_rolling_buffer_s = 0.0;
    emit sessionStateChanged();
}

void AcquisitionBridge::on_config_applied(const ConfigUpdateInfo &info)
{
    Q_UNUSED(info);
    // 配置一变，算法就把滚动缓存清空了。图上要立刻显示「重新累积」，
    // 否则用户会以为地形图卡住了
    m_rolling_buffer_s = 0.0;
    m_topo_status_text = tr("滤波参数已更新，数据重新累积中");
    m_spectrum_status_text = m_topo_status_text;
    emit topoRevisionChanged();
    emit spectrumRevisionChanged();
}

void AcquisitionBridge::on_topography_ready(const TopographyFrame &frame)
{
    // 过期结果直接丢：request_id 只增不减，收到更小的说明是上一轮的尾巴
    if (frame.request_id < m_topo_request_id)
    {
        return;
    }

    {
        const QMutexLocker locker(&m_topo_mutex);
        m_topo_image = render_topography(frame, kTopographyImageSize);
    }

    m_topo_scale_max = frame.scale_max;
    m_topo_status_text.clear();
    m_topo_stats = QStringList{
        frame.peak_electrode.isEmpty() ? QStringLiteral("—") : frame.peak_electrode,
        QString::number(frame.peak_power, 'f', 1),
        QString::number(frame.mean_power, 'f', 1),
        frame.frontal_occipital_ratio > 0.0
            ? QString::number(frame.frontal_occipital_ratio, 'f', 1)
            : QStringLiteral("—"),
    };

    ++m_topo_revision;
    emit topoRevisionChanged();
}

void AcquisitionBridge::on_spectrum_ready(const SpectrumFrame &frame)
{
    if (frame.request_id < m_spectrum_request_id || frame.psd.isEmpty())
    {
        return;
    }

    // 曲线归一化成 0~1，QML 只负责按画布高度缩放。
    //
    // PSD 的频点是 3.9 Hz 一档（算法侧 nperseg 固定 256，见接口文档），
    // 0.5–30 Hz 只有 7 个点，所以这条曲线天然是折线而不是平滑曲线 ——
    // 这是算法侧分辨率决定的，不是显示做得粗糙
    const float peak = *std::max_element(frame.psd.begin(), frame.psd.end());
    const double denominator = peak > 0.0f ? static_cast<double>(peak) : 1.0;

    QVariantList curve;
    curve.reserve(frame.psd.size());
    for (int i = 0; i < frame.psd.size(); ++i)
    {
        curve.append(static_cast<double>(frame.psd.at(i)) / denominator);
    }
    m_spectrum_curve = curve;

    // 五个频段各自的功率。频点太稀，各频段内的点数差异很大（α 只有 1 个点），
    // 所以这里显示的是「频段内 PSD 之和」，不除以点数 —— 除完会出现 0 或极大值
    struct BandRange
    {
        const char *letter;
        double low_hz;
        double high_hz;
    };
    static const BandRange bands[] = {
        {"δ", 0.5, 4.0}, {"θ", 4.0, 8.0}, {"α", 8.0, 13.0}, {"β", 13.0, 30.0},
        {"γ", 30.0, 45.0},
    };

    QStringList values;
    // 按两个数组里较短的那个遍历：copy_py_float_array 只校验一维与长度，
    // 不保证两者等长，而 QVector::at 越界在 Debug 下是断言崩溃
    const int point_count = std::min(frame.psd.size(), frame.frequencies_hz.size());
    for (const BandRange &band : bands)
    {
        double sum = 0.0;
        for (int i = 0; i < point_count; ++i)
        {
            const double frequency = frame.frequencies_hz.at(i);
            if (frequency >= band.low_hz && frequency <= band.high_hz)
            {
                sum += frame.psd.at(i);
            }
        }
        values.append(QStringLiteral("%1μV²").arg(sum, 0, 'f', 1));
    }
    m_spectrum_band_values = values;
    m_spectrum_status_text.clear();

    ++m_spectrum_revision;
    emit spectrumRevisionChanged();
}

void AcquisitionBridge::on_status_updated(const SessionStatusSnapshot &status)
{
    m_rolling_buffer_s = status.rolling_buffer_duration_s;
    m_processing_us = status.average_processing_time_us;
    m_session_state = status.state;
    m_can_reset = status.state == QLatin1String("error");
    if (status.warmup_remaining_samples > 0)
    {
        m_warmup_text = tr("预热中，剩余 %1 个采样点").arg(status.warmup_remaining_samples);
    }
    else
    {
        m_warmup_text.clear();
    }

    emit sessionStateChanged();
    refresh_stats_text();
}

void AcquisitionBridge::on_algorithm_failed(const AlgorithmErrorInfo &info)
{
    m_error_code = info.code;
    m_error_message = info.message;
    m_can_reset = true;

    // 单独记一条到界面日志区：错误消息是多行的 traceback 时，
    // 顶部的错误栏放不下
    emit logMessage(QStringLiteral("[算法 %1] %2 %3")
                        .arg(info.code, info.operation, info.message));
    emit sessionStateChanged();
    set_error(tr("算法调用失败（%1）：%2").arg(info.code, info.message));
}

void AcquisitionBridge::on_session_state_changed(const QString &state)
{
    m_session_state = state;
    m_can_reset = state == QLatin1String("error");
    emit sessionStateChanged();
}

void AcquisitionBridge::on_notice(const QString &message)
{
    emit logMessage(message);
}

void AcquisitionBridge::on_log_event(const AlgorithmLogEvent &event)
{
    emit logMessage(QStringLiteral("[%1 %2] %3").arg(event.level, event.code, event.message));
}

// ==================== 串口线程的信号 ====================

void AcquisitionBridge::on_port_opened(const QString &message)
{
    m_port_open = true;
    set_status(message);
    emit portStateChanged();
    emit logMessage(message);
}

void AcquisitionBridge::on_port_open_failed(const QString &message)
{
    m_port_open = false;
    emit portStateChanged();
    set_error(message);
}

void AcquisitionBridge::on_port_closed(const QString &message)
{
    reset_port_flags();
    set_status(message);
    emit logMessage(message);
}

void AcquisitionBridge::on_device_lost(const QString &message)
{
    // 只在采集进行中才提示。device_lost 排在 collecting_changed(false) 之前入队，
    // 所以此刻 m_collecting 仍是断开前的真实状态 —— 只有「采集中被拔线 / 掉电」
    // 会走到这里；单纯开着串口没采集时拔线不打扰用户（顶栏胶囊照样会变「未连接」）
    Q_UNUSED(message);
    if (m_collecting)
    {
        emit deviceDisconnected();
    }
}

void AcquisitionBridge::on_stats_changed(qint64 received, qint64 saved, qint64 dropped,
                                         qint64 frame_skips)
{
    m_received_frames = received;
    m_dropped_bytes = dropped;
    m_saved_frames_for_stats = saved;
    m_frame_number_skips = frame_skips;
    refresh_stats_text();
    emit statsChanged();
}

void AcquisitionBridge::on_status_message(const QString &message)
{
    set_status(message);
}

void AcquisitionBridge::on_failed(const QString &message)
{
    set_error(message);
}

void AcquisitionBridge::on_collecting_changed(bool collecting)
{
    if (collecting == m_collecting)
    {
        // 停止采集时即使状态没变也要通知 QML：start_collection 失败时
        // m_collecting 始终为 false，采集线程仍会发 collecting_changed(false)，
        // 如果不补发信号，QML 的 finishCollection 就永远不会被调用，
        // 历史记录里时长就一直是 00:00:00
        if (!collecting)
            emit collectingChanged();
        return;
    }
    m_collecting = collecting;
    emit collectingChanged();
}

void AcquisitionBridge::on_recording_changed(bool recording, const QString &file_path)
{
    // 只记文件路径，**不动 m_collecting** —— 采集状态由 collecting_changed 单独驱动。
    // 混在一起的话，落盘失败会让界面以为「没在采集」，从而关掉地形图与频谱的查询
    const bool was_recording = !m_recording_path.isEmpty();
    m_recording_path = recording ? file_path : QString();

    if (recording)
    {
        emit logMessage(tr("数据保存到 %1").arg(file_path));
    }
    else if (was_recording)
    {
        emit logMessage(tr("已停止写入文件"));
    }
    emit recordingPathChanged();
}

// ==================== 事件 ====================

void AcquisitionBridge::add_event(const QString &label, const QString &color)
{
    const qint64 elapsed_ms = m_collect_timer.isValid() ? m_collect_timer.elapsed() : 0;
    const qint64 total_seconds = elapsed_ms / 1000;

    QVariantMap event;
    event.insert(QStringLiteral("label"), label);
    // 事件时刻用「采集开始以来的偏移 + 当时的墙钟」。两者都要：
    // 偏移用来在波形上定位竖线，墙钟用来与外部记录对齐
    event.insert(QStringLiteral("offset"),
                 QStringLiteral("%1:%2")
                     .arg(total_seconds / 60, 2, 10, QLatin1Char('0'))
                     .arg(total_seconds % 60, 2, 10, QLatin1Char('0')));
    event.insert(QStringLiteral("wallClock"),
                 QDateTime::currentDateTime().toString(QStringLiteral("hh:mm:ss")));
    event.insert(QStringLiteral("offsetSeconds"), static_cast<double>(elapsed_ms) / 1000.0);
    event.insert(QStringLiteral("dotColor"),
                 color.isEmpty() ? QStringLiteral("#7c3aed") : color);

    m_events.append(event);
    emit eventsChanged();
}

QVariantList AcquisitionBridge::electrode_map() const
{
    QVariantList rows;
    const eeg_montage::Electrode *table = eeg_montage::electrodes();
    for (int i = 0; i < eeg_montage::kChannelCount; ++i)
    {
        QVariantMap row;
        row[QStringLiteral("name")] = QString::fromLatin1(table[i].name);
        row[QStringLiteral("x")] = table[i].x;
        row[QStringLiteral("y")] = table[i].y;
        rows.append(row);
    }
    return rows;
}

void AcquisitionBridge::begin_electrode_scan()
{
    // 按下「阻抗扫描」就立刻发 'Z'，让设备切到阻抗上传模式（只发 B0…D0 帧）。
    // 界面随后跑约 1.2 秒动画，等动画结束时由 scan_electrodes() 读回并停发 's'，
    // 这段时间足够设备连续上传多帧阻抗。
    // 串口在登录成功后就连上了，这里不再自动补连（连接已与采集解耦）；
    // 没连上（也含演示模式没有真实串口）就什么都不做，1.2 秒后由
    // scan_electrodes() 统一把「请先连接设备」交给界面
    if (!collector_active())
    {
        return;
    }
    m_collector->post_impedance_start();
    m_impedance_pending = true;
}

bool AcquisitionBridge::scan_electrodes()
{
    // 阻抗是设备实测的，必须先有采集线程才能发 'Z'/'s'
    if (!collector_active())
    {
        m_electrode_quality.clear();
        m_electrode_summary = tr("请先连接设备后再扫描阻抗");
        m_electrode_scan_valid = false;
        emit electrodeQualityChanged();
        return false;
    }

    // 读回采集线程缓存的最新一帧阻抗（内部加锁），随后立刻发 's' 让设备停止上传
    const QVector<double> kohm_values = m_collector->latest_impedance_kohm();
    m_collector->post_impedance_stop();
    m_impedance_pending = false;

    if (kohm_values.size() < eeg_montage::kChannelCount)
    {
        m_electrode_quality.clear();
        m_electrode_summary = tr("未收到阻抗数据，请确认设备已连接并支持阻抗扫描");
        m_electrode_scan_valid = false;
        emit electrodeQualityChanged();
        return false;
    }

    // 分档阈值（kΩ）。数值来自设备实测阻抗（B0…D0 帧每路一个 24 位值，
    // 单位欧姆，经 serial_protocol::kKohmPerOhm 换算）；< 0 表示该路未连接
    constexpr double kGoodBelow = 10.0;
    constexpr double kPoorBelow = 18.0;
    constexpr double kOffBelow = 30.0;
    constexpr double kMaxBar = 60.0;

    int good = 0;
    int fair = 0;
    int poor = 0;
    int off = 0;

    QVariantList rows;
    rows.reserve(eeg_montage::kChannelCount);

    for (int ch = 0; ch < eeg_montage::kChannelCount; ++ch)
    {
        const double kohm = kohm_values.at(ch);
        const bool disconnected = kohm < 0.0;

        QString level;
        if (disconnected || kohm >= kOffBelow)
        {
            level = QStringLiteral("脱落");
            ++off;
        }
        else if (kohm < kGoodBelow)
        {
            level = QStringLiteral("良好");
            ++good;
        }
        else if (kohm < kPoorBelow)
        {
            level = QStringLiteral("一般");
            ++fair;
        }
        else
        {
            level = QStringLiteral("不良");
            ++poor;
        }

        QVariantMap row;
        row[QStringLiteral("channel")] = ch;
        row[QStringLiteral("name")] = eeg_montage::channel_name(ch);
        row[QStringLiteral("level")] = level;
        // 进度条长度按阻抗占满量程的比例给；未连接画满条以直观地标出「脱落」
        row[QStringLiteral("ratio")] = disconnected ? 1.0
                                                    : std::clamp(kohm / kMaxBar, 0.05, 1.0);
        row[QStringLiteral("kohm")] = disconnected ? 0.0 : kohm;
        // 数值列显示设备实测阻抗（kΩ）；未连接显示「--」
        row[QStringLiteral("text")] = disconnected
                                          ? QStringLiteral("--")
                                          : QStringLiteral("%1kΩ").arg(kohm, 0, 'f', 1);
        rows.append(row);
    }

    m_electrode_quality = rows;
    m_electrode_scan_valid = true;
    m_electrode_summary = tr("良好 %1 · 一般 %2 · 不良 %3 · 脱落 %4")
                              .arg(good).arg(fair).arg(poor).arg(off);
    emit electrodeQualityChanged();
    return true;
}

bool AcquisitionBridge::set_event_label(int index, const QString &label, const QString &color)
{
    if (index < 0 || index >= m_events.size())
    {
        return false;
    }

    QVariantMap event = m_events.at(index).toMap();
    event.insert(QStringLiteral("label"), label);
    if (!color.isEmpty())
        event.insert(QStringLiteral("dotColor"), color);
    m_events[index] = event;

    emit eventsChanged();
    return true;
}

void AcquisitionBridge::remove_event(int index)
{
    if (index < 0 || index >= m_events.size())
    {
        return;
    }
    m_events.removeAt(index);
    emit eventsChanged();
}

void AcquisitionBridge::clear_events()
{
    if (m_events.isEmpty())
    {
        return;
    }
    m_events.clear();
    emit eventsChanged();
}

double AcquisitionBridge::elapsed_seconds() const
{
    if (!m_collect_timer.isValid())
    {
        return 0.0;
    }
    return static_cast<double>(m_collect_timer.elapsed()) / 1000.0;
}

double AcquisitionBridge::raw_buffer_seconds() const
{
    return m_raw_buffer.available_seconds();
}

int AcquisitionBridge::acquired_channel_count() const
{
    return eeg_montage::kChannelCount;
}

QVariantMap AcquisitionBridge::collection_summary() const
{
    QVariantMap summary;
    summary[QStringLiteral("durationSeconds")] =
        m_collect_timer.isValid() ? static_cast<int>(m_collect_timer.elapsed() / 1000) : 0;
    summary[QStringLiteral("eventCount")] = m_events.size();
    // 演示数据源不落盘，这里会是空串 —— 采集记录里那一列就留空
    summary[QStringLiteral("filePath")] = m_recording_path;
    return summary;
}

// ==================== 图像 provider ====================

QImage AcquisitionBridge::current_topo_image() const
{
    const QMutexLocker locker(&m_topo_mutex);
    if (m_topo_image.isNull())
    {
        // 还没出过图。**不能返回空 QImage**：那样 QML 的 Image 会打一条
        // "Failed to get image from provider" 的警告，而这是正常状态
        //（刚启动、或数据还在累积），不是错误。给一张全透明图，界面上
        // 什么都不会画，也不会污染日志
        QImage placeholder(kTopographyImageSize, kTopographyImageSize,
                           QImage::Format_ARGB32_Premultiplied);
        placeholder.fill(Qt::transparent);
        return placeholder;
    }
    return m_topo_image.copy();
}

QQuickImageProvider *AcquisitionBridge::create_topo_image_provider()
{
    return new TopoMapImageProvider(const_cast<AcquisitionBridge *>(this));
}

// ==================== 内部 ====================

void AcquisitionBridge::set_error(const QString &message)
{
    m_error_text = message;
    emit errorTextChanged();
    emit logMessage(message);
    qWarning().noquote() << "[acquisition]" << message;
}

void AcquisitionBridge::set_status(const QString &message)
{
    m_status_text = message;
    emit statusTextChanged();
}

void AcquisitionBridge::refresh_stats_text()
{
    m_stats_text = tr("已收 %1 帧 · 已存 %2 帧%3%4")
                       .arg(m_received_frames)
                       .arg(m_saved_frames_for_stats)
                       .arg(m_dropped_bytes > 0
                                ? tr(" · 丢弃 %1 字节").arg(m_dropped_bytes)
                                : QString())
                       // 设备帧号的跳变次数。与「丢弃字节数」一起看才能区分
                       // 「设备漏发」和「我们配错了波特率」—— 后者会让丢弃字节
                       // 持续增长而帧号照常连续。只在非 0 时显示，正常时是噪音
                       .arg(m_frame_number_skips > 0
                                ? tr(" · 设备跳帧 %1").arg(m_frame_number_skips)
                                : QString());

    m_processing_time_text = m_processing_us > 0.0
                                 ? tr("算法 %1 ms/块").arg(m_processing_us / 1000.0, 0, 'f', 2)
                                 : QString();

    emit statsChanged();
}

void AcquisitionBridge::reset_port_flags()
{
    const bool was_open = m_port_open;
    const bool was_collecting = m_collecting;

    m_port_open = false;
    m_collecting = false;
    // 阻抗扫描的「已发 'Z'、等 1.2 秒读回」状态也要一起清：串口都没了，那次扫描
    // 不可能有结果。留着它，下次「开始采集」会照发一个 's' 去停阻抗，而新连上的
    // 设备根本不在阻抗模式 —— 设备把 's' 当停止，紧跟着的 'b' 被冲掉，结果一块
    // 数据都收不到、波形一片空白（原因见 start_collection 里那段注释）
    m_impedance_pending = false;

    if (was_open)
    {
        emit portStateChanged();
    }
    if (was_collecting)
    {
        emit collectingChanged();
    }
}

// ==================== 桥接层端到端自检 ====================

namespace
{

int g_bridge_selfcheck_failures = 0;

void check_bridge(bool condition, const QString &what)
{
    if (condition)
    {
        qInfo().noquote() << "  [通过]" << what;
        return;
    }
    ++g_bridge_selfcheck_failures;
    qWarning().noquote() << "  [失败]" << what;
}

// 等条件成立，期间持续转事件循环 —— 桥接层的结果全靠队列信号从算法线程
// 投递过来，不转事件循环就永远收不到
bool wait_bridge(const std::function<bool()> &condition, int timeout_ms)
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

// 某一泳道里已绘制像素的纵向跨度（像素）。
//
// 直接验渲染结果而不是验中间数据：这样连「取窗口 → 抽稀 → 钳泳道 → 画线」
// 整条绘制路径一起覆盖到。平线或没数据时跨度接近 0，有真实波动时会明显张开。
//
// 采样列取中间一段，避开左右边框；纵向网格线也在这段之外
int lane_pixel_span(const QImage &image, int lane, int lanes)
{
    if (image.isNull() || lanes <= 0 || lane < 0 || lane >= lanes)
    {
        return 0;
    }
    const int top = image.height() * lane / lanes;
    const int bottom = image.height() * (lane + 1) / lanes;
    const int x0 = image.width() / 4;
    const int x1 = image.width() * 3 / 4;

    int min_y = image.height();
    int max_y = -1;
    for (int y = top; y < bottom; ++y)
    {
        const QRgb *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
        for (int x = x0; x < x1; ++x)
        {
            if (qAlpha(line[x]) > 0)
            {
                min_y = std::min(min_y, y);
                max_y = std::max(max_y, y);
                break;
            }
        }
    }
    return max_y < min_y ? 0 : max_y - min_y;
}

} // namespace

int run_bridge_selfcheck(PythonEngine &engine)
{
    install_console_message_handler();

    qInfo().noquote() << "== 桥接层端到端自检 ==";

    if (!engine.is_running())
    {
        qWarning().noquote() << "  解释器未启动，跳过";
        return 1;
    }

    {
        AcquisitionBridge bridge(&engine);

        // 报告显示区尺寸。不报的话渲染会直接早退（没有尺寸就不知道画多大），
        // 也正是界面第一次布局时会做的事
        bridge.set_wave_view_size(1037, 770);

        // 收集日志：ASR 这类「不报错但要能看出有没有生效」的状态全靠它
        QStringList message_log;
        QObject::connect(&bridge, &AcquisitionBridge::logMessage, &bridge,
                         [&message_log](const QString &message) { message_log.append(message); });

        // ---- 未连接时的错误路径 ----
        //
        // 串口在登录后独立连接，start_collection() 不再自动开串口：没连上就
        // 直接拒绝并给出错误。这里验证这条拒绝路径（不依赖本机有没有 COM 口，
        // 因为该路径根本不会去占用设备）
        bridge.refresh_ports();
        check_bridge(!bridge.start_collection(QString()),
                     QStringLiteral("未连接设备时开始采集被拒绝"));
        check_bridge(!bridge.error_text().isEmpty(),
                     QStringLiteral("拒绝时给出了可显示的错误：%1").arg(bridge.error_text()));
        bridge.clear_error();
        check_bridge(bridge.error_text().isEmpty(), QStringLiteral("错误可以被清掉"));

        // ---- 演示数据源 ----
        bridge.start_demo_source();
        check_bridge(bridge.demo_source() && bridge.collecting(),
                     QStringLiteral("演示数据源已启动"));

        const bool running =
            wait_bridge([&] { return bridge.session_state() == QLatin1String("running"); }, 20000);
        check_bridge(running, QStringLiteral("在线会话进入 running（实际 %1）")
                                  .arg(bridge.session_state()));

        // ---- 波形：数值必须真的有波动 ----
        const bool wave_drawn = wait_bridge(
            [&] { return lane_pixel_span(bridge.current_wave_image(), 0, 16) > 4; }, 20000);
        check_bridge(wave_drawn,
                     QStringLiteral("波形已画出且有真实波动（泳道内像素跨度 %1 px）")
                         .arg(lane_pixel_span(bridge.current_wave_image(), 0, 16)));

        // 通道档位：16 与 8 给出的通道名必须不同 —— 8 档挑的是
        // Fp1 Fp2 F3 F4 C3 C4 P3 P4，而不是前 8 路
        check_bridge(bridge.channel_names().size() == 16 && bridge.channel_names().first() == "Fp1",
                     QStringLiteral("16 档给出 16 个通道名（首个 %1）")
                         .arg(bridge.channel_names().value(0)));
        bridge.set_channel_count(8);
        check_bridge(bridge.channel_names().size() == 8 && bridge.channel_names().value(2) == "F3",
                     QStringLiteral("8 档跳过了 F7/T3，第三个是 F3（实际 %1）")
                         .arg(bridge.channel_names().value(2)));
        bridge.set_channel_count(16);
        check_bridge(bridge.channel_names().size() == 16, QStringLiteral("切回 16 档"));

        // 通道显隐：藏掉一个之后取掩码要能看出变化
        bridge.set_all_channels_visible(false);
        bridge.set_channel_visible(3, true);
        const QVariantList mask = bridge.channel_visible_mask();
        check_bridge(mask.size() == 16 && mask.value(3).toBool()
                         && !mask.value(4).toBool(),
                     QStringLiteral("通道显隐掩码按设置变化"));
        bridge.set_all_channels_visible(true);

        // ---- 地形图：等滚动缓存积够，图必须是一张有内容的方图 ----
        //
        // 判据用 topoScaleMax 而不是「图不为空」：没出图时 provider 返回的是一张
        // 透明占位图（那是为了防止 QML 报 "Failed to get image from provider"），
        // 尺寸同样是 256×256 —— 拿尺寸当判据会恒真，后面几条检查就会在真图
        // 到达之前跑，全部拿不到数据
        const bool topo_ready =
            wait_bridge([&] { return bridge.topo_scale_max() > 0.0; }, 30000);
        check_bridge(topo_ready, QStringLiteral("地形图已出图（%1×%2）")
                                     .arg(bridge.current_topo_image().width())
                                     .arg(bridge.current_topo_image().height()));

        // 四项统计必须算出来了，而不是一排短横
        const QStringList stats = bridge.topo_stats();
        check_bridge(stats.size() == 4 && stats.at(0) != QStringLiteral("—"),
                     QStringLiteral("地形图四项统计：%1").arg(stats.join(QStringLiteral(" / "))));
        check_bridge(bridge.topo_scale_max() > 0.0,
                     QStringLiteral("配色上限非零（%1 µV²/Hz）")
                         .arg(bridge.topo_scale_max(), 0, 'f', 3));

        // 图里必须有非透明像素 —— 掩膜用错时整张图会是空的
        const QImage topo_image = bridge.current_topo_image();
        int opaque_pixels = 0;
        for (int y = 0; y < topo_image.height(); y += 4)
        {
            for (int x = 0; x < topo_image.width(); x += 4)
            {
                if (qAlpha(topo_image.pixel(x, y)) > 0)
                {
                    ++opaque_pixels;
                }
            }
        }
        check_bridge(opaque_pixels > 100,
                     QStringLiteral("地形图有 %1 个采样点落在头型掩膜内").arg(opaque_pixels));

        // 头型必须是**圆的**。掩膜圆半径（约 1.20）大于网格半宽（1），
        // 铺图时若不按半径缩放，四角会一起被填上，画出来是个方块 ——
        // 叠在设计稿的圆形底图上会明显不对。四角透明 + 中心不透明就说明是圆的
        const int last = topo_image.width() - 1;
        const bool corners_transparent = qAlpha(topo_image.pixel(0, 0)) == 0
                                         && qAlpha(topo_image.pixel(last, 0)) == 0
                                         && qAlpha(topo_image.pixel(0, last)) == 0
                                         && qAlpha(topo_image.pixel(last, last)) == 0;
        const bool center_opaque = qAlpha(topo_image.pixel(last / 2, last / 2)) > 0;
        check_bridge(corners_transparent && center_opaque,
                     QStringLiteral("头型是圆形而不是方块（四角透明、中心不透明）"));

        // ---- 频谱 ----
        check_bridge(wait_bridge([&] { return !bridge.spectrum_curve().isEmpty(); }, 30000),
                     QStringLiteral("频谱曲线已生成（%1 个频点）")
                         .arg(bridge.spectrum_curve().size()));
        check_bridge(bridge.spectrum_band_values().size() == 5,
                     QStringLiteral("五个频段的数值：%1")
                         .arg(bridge.spectrum_band_values().join(QStringLiteral(" / "))));

        // ---- 滤波参数下发后仍有数据（不能把链路打断）----
        // 用 40 Hz 而不是默认的 45 Hz：默认值改到 45 之后写 45 会被 setter 的
        // qFuzzyCompare 提前返回，等于没改参数，这条检查就失去意义了
        bridge.set_low_pass_high_hz(40.0);
        check_bridge(
            wait_bridge(
                [&] { return lane_pixel_span(bridge.current_wave_image(), 0, 16) > 4; }, 20000),
            QStringLiteral("改滤波参数后波形仍在更新"));

        // ---- ASR 的数据来源必须真的接上 ----
        //
        // 这一条针对一个已经发生过的真实缺陷：算法线程持有的原始数据源指针
        // 从头到尾只被赋过 nullptr，导致整段自动拟合一进判断就被跳过 ——
        // 界面上勾选 ASR 会显示「需累计 60 秒」然后永远什么都不发生，
        // 既不报错也不生效。所以这里断言两件事：缓冲真的在进数据、
        // 勾上 ASR 之后确实有反馈
        const bool raw_buffer_grows =
            wait_bridge([&] { return bridge.raw_buffer_seconds() > 1.0; }, 20000);
        check_bridge(raw_buffer_grows,
                     QStringLiteral("原始数据缓冲在进数据（已攒 %1 秒，ASR 参考要用它）")
                         .arg(bridge.raw_buffer_seconds(), 0, 'f', 1));

        message_log.clear();
        bridge.set_asr_enabled(true);
        const bool asr_feedback =
            wait_bridge([&] {
                for (const QString &message : message_log) {
                    if (message.contains(QStringLiteral("ASR")))
                        return true;
                }
                return false;
            }, 15000);
        check_bridge(asr_feedback,
                     QStringLiteral("勾选 ASR 后有明确反馈（而不是静默不生效）"));
        bridge.set_asr_enabled(false);

        // ---- 事件 ----
        bridge.add_event(QStringLiteral("睁眼"));
        bridge.add_event(QStringLiteral("闭眼"));
        check_bridge(bridge.event_count() == 2,
                     QStringLiteral("手动标记落了 %1 条事件").arg(bridge.event_count()));
        const QVariantMap first_event = bridge.events().value(0).toMap();
        check_bridge(first_event.contains(QStringLiteral("offsetSeconds"))
                         && first_event.value(QStringLiteral("wallClock")).toString().length() == 8,
                     QStringLiteral("事件带采集偏移 %1 与墙钟 %2")
                         .arg(first_event.value(QStringLiteral("offset")).toString(),
                              first_event.value(QStringLiteral("wallClock")).toString()));
        bridge.clear_events();
        check_bridge(bridge.event_count() == 0, QStringLiteral("事件可以清空"));

        // ---- 停止 ----
        bridge.stop_demo_source();
        const bool stopped =
            wait_bridge([&] { return !bridge.collecting(); }, 10000);
        check_bridge(stopped, QStringLiteral("演示数据源已停止"));
    }

    // 走到这里 bridge 已析构：采集线程与算法线程都 wait() 回来了，
    // py::object 也全部释放 —— 这正是调用方随后关解释器的前提
    check_bridge(true, QStringLiteral("桥接层已析构，两个线程都已退出"));

    if (g_bridge_selfcheck_failures == 0)
    {
        qInfo().noquote() << "== 桥接层自检全部通过 ==";
        return 0;
    }
    qWarning().noquote()
        << QStringLiteral("== 桥接层自检失败 %1 项 ==").arg(g_bridge_selfcheck_failures);
    return 1;
}
