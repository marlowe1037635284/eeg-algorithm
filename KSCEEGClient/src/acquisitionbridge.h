#ifndef ACQUISITIONBRIDGE_H
#define ACQUISITIONBRIDGE_H

#include <QElapsedTimer>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QVector>

#include <atomic>

#include "eegtypes.h"
#include "pythonworker.h"
#include "rawringbuffer.h"
#include "serialcollector.h"

class QQuickImageProvider;
class PythonEngine;

// 采集工作台对 QML 暴露的唯一门面（在 main.cpp 里用 setContextProperty 注入成 Acq）。
//
// 线程约定：本对象常驻 GUI 线程。它同时是 ChunkSink，所以 deliver() 是在**采集线程**
// 上调用的 —— 那里只做两件不碰界面的事：把原始样本写进原始环形缓冲（供 ASR 用）、
// 追加到显示缓冲（加锁），然后把块转交给算法线程。所有 Q_PROPERTY 与信号都只在
// GUI 线程上产生。
//
// 数据通路（见 plan 的架构图）：
//   采集线程 ──deliver()──▶ 本对象 ──┬──▶ PythonWorker（有界队列，不可丢）
//                                   └──▶ 显示缓冲（可丢，覆盖式）
//   算法线程 ──block_processed──▶ 本对象把处理后的样本写进显示缓冲
//   算法线程 ──topography_ready / spectrum_ready / status_updated──▶ 本对象 → QML
class AcquisitionBridge : public QObject, public ChunkSink
{
    Q_OBJECT

    // ---- 串口与采集 ----
    Q_PROPERTY(QStringList availablePorts READ available_ports NOTIFY availablePortsChanged)
    Q_PROPERTY(bool portOpen READ port_open NOTIFY portStateChanged)
    Q_PROPERTY(bool collecting READ collecting NOTIFY collectingChanged)
    Q_PROPERTY(QString statusText READ status_text NOTIFY statusTextChanged)
    Q_PROPERTY(QString errorText READ error_text NOTIFY errorTextChanged)
    Q_PROPERTY(QString statsText READ stats_text NOTIFY statsChanged)
    Q_PROPERTY(qint64 receivedFrames READ received_frames NOTIFY statsChanged)
    Q_PROPERTY(qint64 droppedBytes READ dropped_bytes NOTIFY statsChanged)
    Q_PROPERTY(QString recordingPath READ recording_path NOTIFY collectingChanged)

    // ---- 波形 ----
    // 界面上的 4/8/16 档位。它只影响**显示与算法会话的通道子集**，
    // 串口上永远是 16 路（协议决定，见 serialprotocol.h）
    Q_PROPERTY(int channelCount READ channel_count WRITE set_channel_count
                   NOTIFY channelCountChanged)
    Q_PROPERTY(QStringList channelNames READ channel_names NOTIFY channelCountChanged)
    Q_PROPERTY(QStringList channelColors READ channel_colors CONSTANT)
    Q_PROPERTY(QVariantList channelVisibleMask READ channel_visible_mask
                   NOTIFY channelVisibilityChanged)
    // 每画好一帧就自增，QML 靠它变化触发 Canvas 重绘
    Q_PROPERTY(int waveRevision READ wave_revision NOTIFY waveRevisionChanged)
    Q_PROPERTY(double timeWindow READ time_window WRITE set_time_window
                   NOTIFY timeWindowChanged)
    // 每路纵轴半量程（µV），0 表示按窗口内峰值自动
    Q_PROPERTY(int yRangeUV READ y_range_uv WRITE set_y_range_uv NOTIFY yRangeChanged)

    // ---- 滤波与后处理（弹窗绑这些属性）----
    Q_PROPERTY(bool highPassEnabled READ high_pass_enabled WRITE set_high_pass_enabled
                   NOTIFY processingChanged)
    Q_PROPERTY(double highPassLowHz READ high_pass_low_hz WRITE set_high_pass_low_hz
                   NOTIFY processingChanged)
    Q_PROPERTY(bool lowPassEnabled READ low_pass_enabled WRITE set_low_pass_enabled
                   NOTIFY processingChanged)
    Q_PROPERTY(double lowPassHighHz READ low_pass_high_hz WRITE set_low_pass_high_hz
                   NOTIFY processingChanged)
    Q_PROPERTY(bool notchEnabled READ notch_enabled WRITE set_notch_enabled
                   NOTIFY processingChanged)
    Q_PROPERTY(double notchLowHz READ notch_low_hz WRITE set_notch_low_hz
                   NOTIFY processingChanged)
    Q_PROPERTY(double notchHighHz READ notch_high_hz WRITE set_notch_high_hz
                   NOTIFY processingChanged)
    Q_PROPERTY(bool asrEnabled READ asr_enabled WRITE set_asr_enabled
                   NOTIFY processingChanged)
    Q_PROPERTY(QString referenceMethod READ reference_method WRITE set_reference_method
                   NOTIFY processingChanged)

    // ---- 算法会话状态 ----
    Q_PROPERTY(QString sessionState READ session_state NOTIFY sessionStateChanged)
    Q_PROPERTY(QString errorCode READ error_code NOTIFY sessionStateChanged)
    Q_PROPERTY(QString errorMessage READ error_message NOTIFY sessionStateChanged)
    Q_PROPERTY(bool canReset READ can_reset NOTIFY sessionStateChanged)
    Q_PROPERTY(QString warmupText READ warmup_text NOTIFY sessionStateChanged)
    Q_PROPERTY(QString processingTimeText READ processing_time_text NOTIFY statsChanged)

    // ---- 脑电地形图 ----
    Q_PROPERTY(int topoRevision READ topo_revision NOTIFY topoRevisionChanged)
    Q_PROPERTY(QString topoBand READ topo_band WRITE set_topo_band NOTIFY topoBandChanged)
    // 固定四项：[峰值电极, 峰值功率, 全脑均值, 枕/额比]，在算法线程里格式化好
    Q_PROPERTY(QStringList topoStats READ topo_stats NOTIFY topoRevisionChanged)
    // 本帧配色上限（µV²/Hz）。图按每帧峰值归一化配色，色标右端必须跟着走
    Q_PROPERTY(double topoScaleMax READ topo_scale_max NOTIFY topoRevisionChanged)
    Q_PROPERTY(QString topoStatusText READ topo_status_text NOTIFY topoRevisionChanged)
    // 与画图用的是同一份色标。做成 CONSTANT：一张常量表，暴露出去是为了让
    // QML 的色标条与 C++ 画的图用同一份数据，两边各抄一份迟早对不上
    Q_PROPERTY(QStringList topoPalette READ topo_palette CONSTANT)

    // ---- 频谱 ----
    Q_PROPERTY(int spectrumRevision READ spectrum_revision NOTIFY spectrumRevisionChanged)
    Q_PROPERTY(QString spectrumChannel READ spectrum_channel WRITE set_spectrum_channel
                   NOTIFY spectrumChannelChanged)
    // PSD 曲线，已归一化成 0~1 的高度（从大到小排列的画布坐标由 QML 处理）
    Q_PROPERTY(QVariantList spectrumCurve READ spectrum_curve NOTIFY spectrumRevisionChanged)
    // 五个频段（δ/θ/α/β/γ）的功率，固定五项，单位 µV²
    Q_PROPERTY(QStringList spectrumBandValues READ spectrum_band_values
                   NOTIFY spectrumRevisionChanged)
    Q_PROPERTY(QString spectrumStatusText READ spectrum_status_text
                   NOTIFY spectrumRevisionChanged)

    // ---- 事件 ----
    Q_PROPERTY(QVariantList events READ events NOTIFY eventsChanged)
    Q_PROPERTY(int eventCount READ event_count NOTIFY eventsChanged)

public:
    explicit AcquisitionBridge(PythonEngine *engine, QObject *parent = nullptr);
    ~AcquisitionBridge() override;

    // ---- ChunkSink：由采集线程调用 ----
    bool deliver(const SignalChunk &chunk) override;
    bool deliver_gap(const GapRange &gap) override;

    // ---- QML 调用 ----
    Q_INVOKABLE void refresh_ports();
    Q_INVOKABLE bool open_port(const QString &port_name, int baud_rate, int sample_rate);
    Q_INVOKABLE void close_port();
    // 开始采集：开串口（若未开）、建算法会话、开始落盘
    Q_INVOKABLE bool start_collection(const QString &directory);
    Q_INVOKABLE void stop_collection();
    Q_INVOKABLE void reset_session();
    Q_INVOKABLE void clear_error();

    // 演示数据源：不接设备，直接在进程内合成 16 通道样本，按真实采集的节拍
    // 走**同一条** deliver() 通路灌进去。
    //
    // 存在的理由：算法链路与界面渲染在没有硬件时完全无法验证，而它们恰恰是
    // 最容易出问题、又最难凭空看出来的部分（波形画不出来还是没数据，从界面上
    // 分不清）。走同一条通路也意味着它验证的是真实路径，不是一条并行的假分支
    Q_INVOKABLE void start_demo_source();
    Q_INVOKABLE void stop_demo_source();
    Q_PROPERTY(bool demoSource READ demo_source NOTIFY demoSourceChanged)

    Q_INVOKABLE bool is_channel_visible(int channel) const;
    Q_INVOKABLE void set_channel_visible(int channel, bool visible);
    Q_INVOKABLE void set_all_channels_visible(bool visible);

    // 某通道在显示窗口内、按像素列抽稀后的样本（µV）。
    // 返回 2*columns 个值：每列依次给出该列的最小值与最大值，
    // Canvas 顺次连线就得到包络正确的折线（点远多于像素列时不会把峰削掉）
    Q_INVOKABLE QVariantList lane_samples(int channel, int columns) const;
    // 该通道当前的纵轴半量程（µV），QML 用它把 µV 换算成像素
    Q_INVOKABLE double lane_range_uv(int channel) const;
    // 采样率，状态栏与「数据点」显示用
    Q_INVOKABLE int sample_rate() const { return m_sample_rate; }
    // 事件：手动标记，时间取自采集计时与墙钟
    Q_INVOKABLE void add_event(const QString &label);
    Q_INVOKABLE void remove_event(int index);
    Q_INVOKABLE void clear_events();
    // 本次采集已经过去多少秒。波形面板用它把事件定位到当前显示窗口里的横向位置
    Q_INVOKABLE double elapsed_seconds() const;
    // 原始数据缓冲里已经攒了多少秒。ASR 需要先攒够 60 秒才能建参考，
    // 界面可以拿它显示进度；自检也靠它确认这条通路真的在进数据
    Q_INVOKABLE double raw_buffer_seconds() const;

    // 提供地形图图像的 provider，所有权交给调用方
    QQuickImageProvider *create_topo_image_provider();
    QImage current_topo_image() const;

    // ---- 属性读取 ----
    QStringList available_ports() const { return m_available_ports; }
    bool port_open() const { return m_port_open; }
    bool collecting() const { return m_collecting; }
    QString status_text() const { return m_status_text; }
    QString error_text() const { return m_error_text; }
    QString stats_text() const { return m_stats_text; }
    qint64 received_frames() const { return m_received_frames; }
    qint64 dropped_bytes() const { return m_dropped_bytes; }
    QString recording_path() const { return m_recording_path; }

    int channel_count() const { return m_channel_count; }
    QStringList channel_names() const;
    QStringList channel_colors() const;
    QVariantList channel_visible_mask() const;
    int wave_revision() const { return m_wave_revision; }
    double time_window() const { return m_time_window; }
    int y_range_uv() const { return m_y_range_uv; }

    bool high_pass_enabled() const { return m_processing.high_pass_enabled; }
    double high_pass_low_hz() const { return m_processing.high_pass_low_hz; }
    bool low_pass_enabled() const { return m_processing.low_pass_enabled; }
    double low_pass_high_hz() const { return m_processing.low_pass_high_hz; }
    bool notch_enabled() const { return m_processing.notch_enabled; }
    double notch_low_hz() const { return m_processing.notch_low_hz; }
    double notch_high_hz() const { return m_processing.notch_high_hz; }
    bool asr_enabled() const { return m_asr_enabled; }
    QString reference_method() const { return m_reference_method; }

    QString session_state() const { return m_session_state; }
    QString error_code() const { return m_error_code; }
    QString error_message() const { return m_error_message; }
    bool can_reset() const { return m_can_reset; }
    QString warmup_text() const { return m_warmup_text; }
    QString processing_time_text() const { return m_processing_time_text; }

    int topo_revision() const { return m_topo_revision; }
    QString topo_band() const { return m_topo_band; }
    QStringList topo_stats() const { return m_topo_stats; }
    double topo_scale_max() const { return m_topo_scale_max; }
    QString topo_status_text() const { return m_topo_status_text; }
    static QStringList topo_palette();

    int spectrum_revision() const { return m_spectrum_revision; }
    QString spectrum_channel() const { return m_spectrum_channel; }
    QVariantList spectrum_curve() const { return m_spectrum_curve; }
    QStringList spectrum_band_values() const { return m_spectrum_band_values; }
    QString spectrum_status_text() const { return m_spectrum_status_text; }

    QVariantList events() const { return m_events; }
    int event_count() const { return m_events.size(); }

    bool demo_source() const { return m_demo_enabled; }

public slots:
    void set_channel_count(int count);
    void set_time_window(double seconds);
    void set_y_range_uv(int range_uv);
    void set_high_pass_enabled(bool enabled);
    void set_high_pass_low_hz(double hz);
    void set_low_pass_enabled(bool enabled);
    void set_low_pass_high_hz(double hz);
    void set_notch_enabled(bool enabled);
    void set_notch_low_hz(double hz);
    void set_notch_high_hz(double hz);
    void set_asr_enabled(bool enabled);
    void set_reference_method(const QString &method);
    void set_topo_band(const QString &band);
    void set_spectrum_channel(const QString &channel);

signals:
    void availablePortsChanged();
    void portStateChanged();
    void collectingChanged();
    void statusTextChanged();
    void errorTextChanged();
    void statsChanged();
    void channelCountChanged();
    void channelVisibilityChanged();
    void waveRevisionChanged();
    void timeWindowChanged();
    void yRangeChanged();
    void processingChanged();
    void sessionStateChanged();
    void topoRevisionChanged();
    void topoBandChanged();
    void spectrumRevisionChanged();
    void spectrumChannelChanged();
    void eventsChanged();
    void demoSourceChanged();
    // 给界面的日志区
    void logMessage(const QString &message);

private:
    void on_port_opened(const QString &message);
    void on_port_open_failed(const QString &message);
    void on_port_closed(const QString &message);
    void on_stats_changed(qint64 received, qint64 saved, qint64 dropped, qint64 frame_skips);
    void on_status_message(const QString &message);
    void on_failed(const QString &message);
    void on_collecting_changed(bool collecting);
    void on_recording_changed(bool recording, const QString &file_path);
    void on_block_processed(const SignalChunk &chunk);
    void on_session_opened(int config_version);
    void on_session_closed();
    void on_config_applied(const ConfigUpdateInfo &info);
    void on_topography_ready(const TopographyFrame &frame);
    void on_spectrum_ready(const SpectrumFrame &frame);
    void on_status_updated(const SessionStatusSnapshot &status);
    void on_algorithm_failed(const AlgorithmErrorInfo &info);
    void on_session_state_changed(const QString &state);
    void on_notice(const QString &message);
    void on_log_event(const AlgorithmLogEvent &event);

    void set_error(const QString &message);
    void set_status(const QString &message);
    void reset_port_flags();
    void refresh_stats_text();
    bool collector_active() const;

    // 按当前通道数重建显示缓冲，并把显隐掩码重置为「全部可见」
    void reset_channels(int channels);
    // 往显示缓冲追加一块样本。**可能在采集线程上被调用**，内部加锁
    void append_to_display(const SignalChunk &chunk);
    // 由 m_display_timer 驱动：取显示缓冲的最新状态并重绘
    void render_wave();
    // 把当前滤波参数与会话参数下发给算法线程
    void push_processing_config();
    void push_session_config();
    // 定时查询地形图与频谱。缓存没积够就不发，界面显示「数据累积中」
    void tick_topography();
    void tick_spectrum();

    PythonEngine *m_engine = nullptr;

    SerialCollector *m_collector = nullptr;
    // **顺序要紧**：m_raw_buffer 必须声明在 m_worker 之前。
    // 局部/成员按声明逆序析构，worker 里持有指向这个缓冲的指针，
    // 反过来声明的话缓冲会先被销毁，而那时算法线程可能还在读它。
    // 同时 ~AcquisitionBridge 里必须等 worker 真的退出（wait 的返回值要检查）
    RawRingBuffer m_raw_buffer;
    PythonWorker m_worker;

    int m_sample_rate = 1000;
    int m_channel_count = 16;
    QVector<bool> m_channel_visible;

    // 显示缓冲：环形，帧优先交错。喂进去的是**算法处理后**的数据；
    // 算法不可用时回退成原始数据，保证「设备还在采」这件事在界面上始终看得见
    QVector<float> m_display_data;
    int m_display_capacity = 0;
    int m_display_head = 0;
    int m_display_filled = 0;
    // 「显示缓冲变过几次」。采集线程自增、GUI 线程读，所以用原子量。
    // 用它把「有没有新数据」和「该不该重绘」分开：没有新数据就不重绘
    std::atomic<qint64> m_display_generation{0};
    qint64 m_rendered_generation = -1;
    mutable QMutex m_display_mutex;
    int m_wave_revision = 0;
    double m_time_window = 2.0;
    int m_y_range_uv = 100;

    QTimer m_display_timer;
    QTimer m_topo_timer;
    QTimer m_spectrum_timer;

    // 演示数据源
    QTimer m_demo_timer;
    bool m_demo_enabled = false;
    qint64 m_demo_sequence_id = 0;
    qint64 m_demo_timestamp_ns = 0;
    void tick_demo_source();

    // 采集线程读、GUI 线程写，所以用原子量而不是普通成员：
    // 普通 bool 在这里是实打实的数据竞争
    std::atomic<bool> m_use_raw_fallback{true};

    // 地形图。image provider 的调用线程由 Qt 决定，加锁并返回深拷贝
    QImage m_topo_image;
    mutable QMutex m_topo_mutex;
    int m_topo_revision = 0;
    QString m_topo_band = QStringLiteral("alpha");
    QStringList m_topo_stats;
    double m_topo_scale_max = 0.0;
    QString m_topo_status_text;
    int m_topo_request_id = 0;

    // 频谱
    QVariantList m_spectrum_curve;
    QStringList m_spectrum_band_values;
    QString m_spectrum_status_text;
    QString m_spectrum_channel = QStringLiteral("C3");
    int m_spectrum_revision = 0;
    int m_spectrum_request_id = 0;

    // 会话
    QString m_session_state;
    QString m_error_code;
    QString m_error_message;
    bool m_can_reset = false;
    QString m_warmup_text;
    QString m_processing_time_text;
    double m_rolling_buffer_s = 0.0;

    // 滤波与后处理参数（界面回读用；真正的下发以 ProcessingParams 为准）
    ProcessingParams m_processing;
    bool m_asr_enabled = false;
    QString m_reference_method = QStringLiteral("common_average");

    // 事件
    QVariantList m_events;
    QElapsedTimer m_collect_timer;

    QStringList m_available_ports;
    bool m_port_open = false;
    bool m_collecting = false;
    QString m_status_text;
    QString m_error_text;
    QString m_stats_text;
    QString m_recording_path;
    qint64 m_received_frames = 0;
    qint64 m_dropped_bytes = 0;
    qint64 m_saved_frames_for_stats = 0;
    // 设备帧号的跳变次数。与 dropped_bytes 一起看能区分「设备漏发」与
    // 「我们配错了波特率」—— 后者会让 dropped_bytes 持续增长而帧号照常连续
    qint64 m_frame_number_skips = 0;
    double m_processing_us = 0.0;
};

// 桥接层的端到端自检：起演示数据源，验证「数据 → 算法 → 显示缓冲 → 波形 /
// 地形图 / 频谱」整条链路真的通了，以及停止、错误提示这些路径的行为。
//
// 为什么必须做：这条链路上任何一处断掉，在界面上表现都一样 ——「波形不动」。
// 分不清是没数据、会话没建成、还是绘制读错了缓冲。自检把每一段的产物
// （非空且非常量的波形数组、非空的地形图、非空的 PSD 曲线）分别验一遍。
//
// engine 必须是已经 start() 过的实例（一个进程只能起一次解释器，见 pythonengine.h）。
// 返回 0 表示全部通过
int run_bridge_selfcheck(PythonEngine &engine);

#endif // ACQUISITIONBRIDGE_H
