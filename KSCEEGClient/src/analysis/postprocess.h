#ifndef POSTPROCESS_H
#define POSTPROCESS_H

#include <QFutureWatcher>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include <memory>

// 「数据分析与后处理」页的全部计算与出图。
//
// ==================== 为什么offline 处理放在 C++ ====================
// 算法包里**有**一套离线模块（eeg_algorithm.internal.offline，接口文档第 8.12~8.14 节），
// 本可以走嵌入式 Python。这里没有走，原因是这条通路在本机跑不起来：
// 本工作副本的 PythonScript 树比 eeg_bridge.py 旧（eeg_bridge 已经从
// eeg_algorithm.errors 里 import ErrorCode / error，而这棵树里两者都不存在），
// 于是解释器起得来、算法模块导入却直接抛 ImportError。基于它做后处理页面，
// 打开就是一片「算法模块不可用」。
//
// 因此离线流水线按接口文档里那套**固定顺序**在本类里实现：
//   高通 → 低通 → 陷波 → 重参考 → ASR → 降采样 → 基线校正
// 与 eeg_algorithm.internal.offline.pipeline.run_preprocessing_pipeline 逐段对应，
// 数值口径尽量取齐（Butterworth 4 阶、零相位、Welch 512 点 / 50% 重叠 / 密度谱）。
// 将来 Python 通路可用时，把 compute_pipeline() 换成一次跨语言调用即可 ——
// 外面这层（参数、切片、统计、出图、导出）不必动。
//
// ==================== 为什么要算在别的线程 ====================
// 一条十分钟的记录是 15 万个采样点 × 16 路。滤波、Welch、相关性加起来在
// Release 下约几十毫秒，Debug 下要几百毫秒 —— 放在 GUI 线程上就是「拖一下
// 高通截止频率，界面卡半秒」。所以重算走 QtConcurrent，算完回到 GUI 线程出图。
//
// 参数变化很密集（拖滑块、连点下拉），所以两头都做了取舍：
//   · 重算前先防抖（kRecomputeDelayMs），连着改只算最后一次；
//   · 每次重算带一个 generation，回来时过期的结果直接丢掉。
class PostProcess : public QObject
{
    Q_OBJECT

    // ---------- 记录 ----------
    Q_PROPERTY(bool loaded READ loaded NOTIFY recordChanged)
    Q_PROPERTY(QString errorText READ error_text NOTIFY recordChanged)
    Q_PROPERTY(QString recordNo READ record_no NOTIFY recordChanged)
    Q_PROPERTY(QString subtitle READ subtitle NOTIFY recordChanged)
    Q_PROPERTY(double durationSeconds READ duration_seconds NOTIFY recordChanged)
    Q_PROPERTY(int sampleRate READ sample_rate NOTIFY recordChanged)
    Q_PROPERTY(int channelCount READ channel_count NOTIFY recordChanged)
    // 基本信息面板那几行：{ label, value }
    Q_PROPERTY(QVariantList recordInfo READ record_info NOTIFY recordChanged)
    // 记录里的事件标注，时间轴上要画
    Q_PROPERTY(QVariantList events READ events NOTIFY recordChanged)

    // ---------- 预处理参数 ----------
    Q_PROPERTY(bool highPassEnabled READ high_pass_enabled WRITE set_high_pass_enabled
                   NOTIFY paramsChanged)
    Q_PROPERTY(double highPassHz READ high_pass_hz WRITE set_high_pass_hz NOTIFY paramsChanged)
    Q_PROPERTY(bool lowPassEnabled READ low_pass_enabled WRITE set_low_pass_enabled
                   NOTIFY paramsChanged)
    Q_PROPERTY(double lowPassHz READ low_pass_hz WRITE set_low_pass_hz NOTIFY paramsChanged)
    Q_PROPERTY(bool notchEnabled READ notch_enabled WRITE set_notch_enabled NOTIFY paramsChanged)
    Q_PROPERTY(double notchHz READ notch_hz WRITE set_notch_hz NOTIFY paramsChanged)
    // 重参考 / 降采样都用「选项下标」，与下拉框一一对应。取值表见 referenceChoices /
    // downsampleChoices —— 降采样那几个数是**按记录实际采样率算的**，
    // 不能照设计稿写死 1000Hz（设计稿那张图是 256Hz 的记录，写了也没意义）
    Q_PROPERTY(int referenceIndex READ reference_index WRITE set_reference_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(int downsampleIndex READ downsample_index WRITE set_downsample_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(bool baselineEnabled READ baseline_enabled WRITE set_baseline_enabled
                   NOTIFY paramsChanged)
    Q_PROPERTY(bool asrEnabled READ asr_enabled WRITE set_asr_enabled NOTIFY paramsChanged)
    Q_PROPERTY(int asrCutoff READ asr_cutoff WRITE set_asr_cutoff NOTIFY paramsChanged)

    // 伪迹检测：是否统计「超出 ±300 μV 的样本」并给出偽差结论。
    // 报告页的「伪差检测」一节与底栏的「无伪差 / 有伪差」都由它决定
    Q_PROPERTY(bool artifactDetectionEnabled READ artifact_detection_enabled
                   WRITE set_artifact_detection_enabled NOTIFY paramsChanged)

    // 窗口和缩放里的「幅度」。0 表示**自动**（沿用原来按窗口内峰值定的标尺），
    // 由用户拖过滑块之后才是一个固定的 ±μV 值。位移 / 窗口长度复用下面的
    // windowStartSeconds / windowSeconds —— 它们本来就被时间轴拖着改，同一份状态
    Q_PROPERTY(double waveAmplitudeUV READ wave_amplitude_uv WRITE set_wave_amplitude_uv
                   NOTIFY paramsChanged)

    // 质检与修复。三个检测项的阈值都可调，改完报告与底栏的数字一起变
    Q_PROPERTY(bool qcSignalEnabled READ qc_signal_enabled WRITE set_qc_signal_enabled
                   NOTIFY paramsChanged)
    Q_PROPERTY(bool qcRangeEnabled READ qc_range_enabled WRITE set_qc_range_enabled
                   NOTIFY paramsChanged)
    Q_PROPERTY(bool qcCorrelationEnabled READ qc_correlation_enabled
                   WRITE set_qc_correlation_enabled NOTIFY paramsChanged)
    Q_PROPERTY(double qcAmplitudeRatio READ qc_amplitude_ratio WRITE set_qc_amplitude_ratio
                   NOTIFY paramsChanged)
    Q_PROPERTY(double qcCorrelation READ qc_correlation WRITE set_qc_correlation
                   NOTIFY paramsChanged)
    Q_PROPERTY(int qcRepairIndex READ qc_repair_index WRITE set_qc_repair_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(QStringList qcRepairChoices READ qc_repair_choices NOTIFY recordChanged)

    // 脑电数据导出：格式 / 类型 / 范围 三个下拉，决定「导出数据」按钮写出的内容
    Q_PROPERTY(int exportFormatIndex READ export_format_index WRITE set_export_format_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(int exportTypeIndex READ export_type_index WRITE set_export_type_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(int exportRangeIndex READ export_range_index WRITE set_export_range_index
                   NOTIFY paramsChanged)
    Q_PROPERTY(QStringList exportFormatChoices READ export_format_choices NOTIFY recordChanged)
    Q_PROPERTY(QStringList exportTypeChoices READ export_type_choices NOTIFY recordChanged)
    Q_PROPERTY(QStringList exportRangeChoices READ export_range_choices NOTIFY recordChanged)

    Q_PROPERTY(QStringList referenceChoices READ reference_choices NOTIFY recordChanged)
    Q_PROPERTY(QStringList downsampleChoices READ downsample_choices NOTIFY recordChanged)

    // ---------- 分析片段 ----------
    // 统计 / 频谱 / 相关性 / 地形图都基于这一段，与设计稿报告页那句
    //「统计 / 频谱 / 通道分析均基于所选片段」一致
    Q_PROPERTY(int segmentIndex READ segment_index WRITE set_segment_index NOTIFY paramsChanged)
    Q_PROPERTY(QStringList segmentChoices READ segment_choices NOTIFY recordChanged)
    Q_PROPERTY(double beforeSeconds READ before_seconds WRITE set_before_seconds
                   NOTIFY paramsChanged)
    Q_PROPERTY(double afterSeconds READ after_seconds WRITE set_after_seconds
                   NOTIFY paramsChanged)

    // ---------- 波形窗口 ----------
    Q_PROPERTY(int currentChannel READ current_channel WRITE set_current_channel
                   NOTIFY viewChanged)
    Q_PROPERTY(double windowStartSeconds READ window_start_seconds WRITE set_window_start_seconds
                   NOTIFY viewChanged)
    Q_PROPERTY(double windowSeconds READ window_seconds WRITE set_window_seconds
                   NOTIFY viewChanged)
    // 当前选中的事件标注（events 里的下标，-1 = 没选）。波形上那根事件竖线与顶端的
    // 圆点选中后换成高亮色，弹窗里对应那一行也点亮 —— 两边共用这一份状态
    Q_PROPERTY(int selectedEvent READ selected_event WRITE set_selected_event
                   NOTIFY viewChanged)
    Q_PROPERTY(QStringList channelNames READ channel_names CONSTANT)
    Q_PROPERTY(QStringList channelColors READ channel_colors CONSTANT)

    // ---------- 频段 ----------
    Q_PROPERTY(QStringList bandKeys READ band_keys CONSTANT)
    Q_PROPERTY(QStringList bandNames READ band_names CONSTANT)
    Q_PROPERTY(QStringList bandColors READ band_colors CONSTANT)
    // 每项 { key, letter, low, high }。频谱图按边界算各色带正中的位置写 δ θ α β γ
    Q_PROPERTY(QVariantList bandRanges READ band_ranges CONSTANT)

    // ---------- 状态与结果 ----------
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString statusText READ status_text NOTIFY resultChanged)
    // 每画好一轮图自增，QML 靠它变化触发 Image 换 URL（否则按 URL 缓存，图不会变）
    Q_PROPERTY(int revision READ revision NOTIFY resultChanged)

    // 通道表（「通道」页）。每项：
    //   { name, color, mean, std, rms, peak, min, max, zeroCross, skewness, kurtosis, band }
    Q_PROPERTY(QVariantList channelStats READ channel_stats NOTIFY resultChanged)
    // 五个频段的整段平均值（「统计」页的大柱图与报告页的频带占比）
    //   { key, label, color, mean, ratio }
    Q_PROPERTY(QVariantList bandDistribution READ band_distribution NOTIFY resultChanged)
    // 每通道的频带占比（「统计」页的小柱图），按通道顺序：
    //   { name, color, ratio: [δ,θ,α,β,γ] }
    Q_PROPERTY(QVariantList channelBands READ channel_bands NOTIFY resultChanged)
    // 地形图每格的统计（峰值电极 / 峰值功率 …），顺序同 bandKeys
    Q_PROPERTY(QVariantList topoStats READ topo_stats NOTIFY resultChanged)
    // 报告页的分节内容：{ title, rows: [{label, value, kind}], chips: [...] , note }
    Q_PROPERTY(QVariantList reportSections READ report_sections NOTIFY resultChanged)
    // 底栏状态条：分组的分段文本。每组是若干段 { text, kind }，kind = "label" |
    // "value"。分组只为排版上的间距（设计稿 info.png 里组间 20、组内紧贴），
    // 上色交给 QML 按 kind 做 —— 标签走正文色、值走主色
    Q_PROPERTY(QVariantList statusGroups READ status_groups NOTIFY resultChanged)
    // 有效片段（秒），报告页与底栏都要显示
    Q_PROPERTY(double segmentStartSeconds READ segment_start_seconds NOTIFY resultChanged)
    Q_PROPERTY(double segmentSeconds READ segment_seconds NOTIFY resultChanged)
    // 地形图色标上限（µV²/Hz），六张图共用一根色标条
    Q_PROPERTY(double topoScaleMax READ topo_scale_max NOTIFY resultChanged)

    // 波形泳道高度。**C++ 与 QML 共用这一个数**：图是按它一段段画的，
    // 通道名与泳道分隔线由 QML 按同一个步长摆 —— 两处各写一个数就会错行
    Q_PROPERTY(int laneHeight READ lane_height CONSTANT)
    // 波形每一格的幅值（µV）。图上按它画，右侧的 +N/0/−N 标注也按它写
    Q_PROPERTY(double waveRangeUV READ wave_range_uv NOTIFY resultChanged)
    // 频谱坐标轴范围。C++ 按它画曲线与频带底色，QML 按同一组数写刻度字
    Q_PROPERTY(double spectrumFMin READ spectrum_f_min NOTIFY resultChanged)
    Q_PROPERTY(double spectrumFMax READ spectrum_f_max NOTIFY resultChanged)
    Q_PROPERTY(double spectrumDbMin READ spectrum_db_min NOTIFY resultChanged)
    Q_PROPERTY(double spectrumDbMax READ spectrum_db_max NOTIFY resultChanged)

public:
    explicit PostProcess(QObject *parent = nullptr);
    ~PostProcess() override;

    // 打开一条记录。record_no 是界面上的编号（R-0001），file_path 是落盘的 .eegbin；
    // info 是库里那条记录的字段（患者、时间、电极贴合…），页面顶栏与基本信息面板要用。
    // 返回是否打开成功；失败原因在 errorText 里
    Q_INVOKABLE bool open(const QString &record_no, const QString &file_path,
                          const QVariantMap &info);
    Q_INVOKABLE void close();

    // 波形与频谱绘制区的像素尺寸，由 QML 在尺寸变化时报上来。
    // pixel_ratio 是绘制区的**物理像素倍率**（高 DPI 下 > 1）：波形按它把图出得
    // 更大、贴回来时正好 1:1，1 像素宽的折线才不会在放大时糊掉或起台阶
    Q_INVOKABLE void set_view_size(int width, int height, double pixel_ratio = 1.0);

    // ---------- 导出 ----------
    // 三个导出都返回 { success, message, path }。目录由调用方给（与历史记录页
    // 的导出同一套：默认「文档」目录，不在 C++ 侧猜路径）
    Q_INVOKABLE QVariantMap export_data(const QString &directory);
    Q_INVOKABLE QVariantMap export_stats_csv(const QString &directory);
    Q_INVOKABLE QVariantMap export_report_txt(const QString &directory);

    bool loaded() const { return m_loaded; }
    QString error_text() const { return m_error_text; }
    QString record_no() const { return m_record_no; }
    QString subtitle() const { return m_subtitle; }
    double duration_seconds() const { return m_duration_seconds; }
    int sample_rate() const { return m_sample_rate; }
    int channel_count() const { return m_channels; }
    QVariantList record_info() const { return m_record_info; }
    QVariantList events() const { return m_events; }

    bool high_pass_enabled() const { return m_params.high_pass_enabled; }
    double high_pass_hz() const { return m_params.high_pass_hz; }
    bool low_pass_enabled() const { return m_params.low_pass_enabled; }
    double low_pass_hz() const { return m_params.low_pass_hz; }
    bool notch_enabled() const { return m_params.notch_enabled; }
    double notch_hz() const { return m_params.notch_hz; }
    int reference_index() const { return m_params.reference_index; }
    int downsample_index() const { return m_params.downsample_index; }
    bool baseline_enabled() const { return m_params.baseline_enabled; }
    bool asr_enabled() const { return m_params.asr_enabled; }
    int asr_cutoff() const { return m_params.asr_cutoff; }

    bool artifact_detection_enabled() const { return m_params.artifact_detection_enabled; }
    double wave_amplitude_uv() const { return m_params.wave_amplitude_uv; }
    bool qc_signal_enabled() const { return m_params.qc_signal_enabled; }
    bool qc_range_enabled() const { return m_params.qc_range_enabled; }
    bool qc_correlation_enabled() const { return m_params.qc_correlation_enabled; }
    double qc_amplitude_ratio() const { return m_params.qc_amplitude_ratio; }
    double qc_correlation() const { return m_params.qc_correlation; }
    int qc_repair_index() const { return m_params.qc_repair_index; }
    int export_format_index() const { return m_params.export_format_index; }
    int export_type_index() const { return m_params.export_type_index; }
    int export_range_index() const { return m_params.export_range_index; }

    int segment_index() const { return m_params.segment_index; }
    double before_seconds() const { return m_params.before_seconds; }
    double after_seconds() const { return m_params.after_seconds; }

    QStringList reference_choices() const;
    QStringList downsample_choices() const;
    QStringList segment_choices() const;
    QStringList qc_repair_choices() const;
    QStringList export_format_choices() const;
    QStringList export_type_choices() const;
    QStringList export_range_choices() const;

    int current_channel() const { return m_current_channel; }
    double window_start_seconds() const { return m_window_start; }
    double window_seconds() const { return m_window_seconds; }
    int selected_event() const { return m_selected_event; }
    QStringList channel_names() const;
    QStringList channel_colors() const;

    static QStringList band_keys();
    static QStringList band_names();
    static QStringList band_colors();
    static QVariantList band_ranges();

    bool busy() const { return m_busy; }
    QString status_text() const { return m_status_text; }
    int revision() const;

    QVariantList channel_stats() const;
    QVariantList band_distribution() const;
    QVariantList channel_bands() const;
    QVariantList topo_stats() const;
    QVariantList report_sections() const;
    QVariantList status_groups() const;
    double segment_start_seconds() const { return m_segment_start; }
    double segment_seconds() const { return m_segment_seconds; }
    double topo_scale_max() const { return m_topo_scale_max; }
    static int lane_height() { return kLaneHeight; }
    double wave_range_uv() const { return m_result.wave_range_uv; }
    double spectrum_f_min() const { return m_result.spectrum_f_min; }
    double spectrum_f_max() const { return m_result.spectrum_f_max; }
    double spectrum_db_min() const { return m_result.spectrum_db_min; }
    double spectrum_db_max() const { return m_result.spectrum_db_max; }

    // 把某一轮的图交给 QML 的 Image。id 形如 "<kind>/<revision>" 或
    // "topo/<band>/<revision>"，revision 只用来制造新 URL，本身不参与取图
    QImage image_for(const QString &id) const;
    QQuickImageProvider *create_image_provider();

public slots:
    void set_high_pass_enabled(bool value);
    void set_high_pass_hz(double value);
    void set_low_pass_enabled(bool value);
    void set_low_pass_hz(double value);
    void set_notch_enabled(bool value);
    void set_notch_hz(double value);
    void set_reference_index(int value);
    void set_downsample_index(int value);
    void set_baseline_enabled(bool value);
    void set_asr_enabled(bool value);
    void set_asr_cutoff(int value);
    void set_artifact_detection_enabled(bool value);
    void set_wave_amplitude_uv(double value);
    void set_qc_signal_enabled(bool value);
    void set_qc_range_enabled(bool value);
    void set_qc_correlation_enabled(bool value);
    void set_qc_amplitude_ratio(double value);
    void set_qc_correlation(double value);
    void set_qc_repair_index(int value);
    void set_export_format_index(int value);
    void set_export_type_index(int value);
    void set_export_range_index(int value);
    void set_segment_index(int value);
    void set_before_seconds(double value);
    void set_after_seconds(double value);
    void set_current_channel(int value);
    void set_window_start_seconds(double value);
    void set_window_seconds(double value);
    void set_selected_event(int value);

signals:
    void recordChanged();
    void paramsChanged();
    void viewChanged();
    void busyChanged();
    void resultChanged();

private:
    struct Result;

    // 「重流水线」那部分输入的指纹。拖动时间轴只影响波形图、频谱图与六张地形图，
    // 整条重流水线（滤波 / 重参考 / 降采样 / 相关性 / 统计 / 频带占比）与窗口无关。
    // 把它们的输入摘成一个可比对的指纹：指纹没变就说明可以整份复用上一轮结果，
    // 只重画波形、频谱与地形图 —— 拖动的延迟从「整条流水线」降到「出图」。窗口（位移/
    // 长度）、当前导联幅度、幅度标尺、绘制区尺寸、事件都不算在内，因为它们只进那几张图。
    struct Fingerprint
    {
        bool high_pass_enabled = true;
        double high_pass_hz = 0.0;
        bool low_pass_enabled = true;
        double low_pass_hz = 0.0;
        bool notch_enabled = true;
        double notch_hz = 0.0;
        int reference_index = 2;
        int downsample_index = 0;
        bool baseline_enabled = false;
        bool asr_enabled = false;
        int asr_cutoff = 0;
        bool artifact_detection_enabled = false;
        bool qc_signal_enabled = true;
        bool qc_range_enabled = true;
        bool qc_correlation_enabled = true;
        double qc_amplitude_ratio = 0.0;
        double qc_correlation = 0.0;
        int qc_repair_index = 0;
        double segment_start = 0.0;
        double segment_seconds = 0.0;
        // 当前导联会进频谱、报告、底栏，所以必须算在指纹里：换导联就走整条流水线
        int current_channel = 0;
        // 原始数据身份：换记录必然换指纹
        const void *raw = nullptr;

        bool operator==(const Fingerprint &other) const
        {
            return high_pass_enabled == other.high_pass_enabled
                && high_pass_hz == other.high_pass_hz
                && low_pass_enabled == other.low_pass_enabled
                && low_pass_hz == other.low_pass_hz
                && notch_enabled == other.notch_enabled
                && notch_hz == other.notch_hz
                && reference_index == other.reference_index
                && downsample_index == other.downsample_index
                && baseline_enabled == other.baseline_enabled
                && asr_enabled == other.asr_enabled
                && asr_cutoff == other.asr_cutoff
                && artifact_detection_enabled == other.artifact_detection_enabled
                && qc_signal_enabled == other.qc_signal_enabled
                && qc_range_enabled == other.qc_range_enabled
                && qc_correlation_enabled == other.qc_correlation_enabled
                && qc_amplitude_ratio == other.qc_amplitude_ratio
                && qc_correlation == other.qc_correlation
                && qc_repair_index == other.qc_repair_index
                && segment_start == other.segment_start
                && segment_seconds == other.segment_seconds
                && current_channel == other.current_channel
                && raw == other.raw;
        }
    };

    // 一遍后处理要用的全部输入。在 GUI 线程上拷一份快照交给工作线程，
    // 工作线程从此不碰本对象的可变状态（只读缓存的那份原始数据）
    struct Job
    {
        int generation = 0;
        bool high_pass_enabled = true;
        double high_pass_hz = 0.1;
        bool low_pass_enabled = true;
        double low_pass_hz = 49.0;
        bool notch_enabled = true;
        double notch_hz = 50.0;
        // 默认不重参考。本蒙太奇没有 A1/A2，「双侧乳突」只能退化成减 0.5*(T3+T4)，
        // 而 T3/T4 往往是全场噪声最大的两路 —— 减它们等于把噪声灌进每一条通道，
        // 波形变成满屏一致的梳状、量程被顶到 ±500。默认关掉，让用户按记录自己决定
        int reference_index = 2;
        int downsample_index = 0;
        bool baseline_enabled = false;
        bool asr_enabled = false;
        int asr_cutoff = 40;
        // 伪迹检测开关与「窗口和缩放」里的幅度（0 = 自动），以及质检三个阈值与修复方式
        bool artifact_detection_enabled = false;
        double wave_amplitude_uv = 0.0;
        bool qc_signal_enabled = true;
        bool qc_range_enabled = true;
        bool qc_correlation_enabled = true;
        double qc_amplitude_ratio = 0.1;
        double qc_correlation = 0.1;
        int qc_repair_index = 0;
        // 片段**在 GUI 线程上就解析成秒**再交给工作线程：片段是按事件时刻算的，
        // 而事件在库里（页面手上的 m_events）。工作线程只认「从第几秒到第几秒」，
        // 不必知道「哪条事件、前后各留多久」
        double segment_start = 0.0;
        double segment_seconds = 10.0;
        int current_channel = 0;
        double window_start = 0.0;
        double window_seconds = 5.0;
        // 波形绘制区（不含左边的通道名列）像素尺寸
        int wave_width = 1200;
        int wave_height = 600;
        // 波形的物理像素倍率：图按 wave_width × (通道数 × 泳道高) 再乘上它出，
        // 贴回逻辑尺寸时正好 1:1（见 set_view_size 注释）
        double wave_scale = 1.0;
        // 频谱绘制区像素尺寸
        int spectrum_width = 1200;
        int spectrum_height = 600;
        // 事件标注（时刻 / 标签 / 颜色）。随任务一起拷进来，工作线程便不必
        // 反过来问 GUI 线程要数据 —— 那种反向依赖是死锁的经典配方
        QVariantList events;
        // 当前选中的事件下标（-1 = 没选）。波形上那根竖线与顶端圆点据此换成高亮色
        int selected_event = -1;
        // 基本信息那五行。报告页的「记录信息」一节直接用它，不再从 info 重新拼一遍
        QVariantList record_info;
        // 上一轮的结果快照。窗口类改动命中指纹时，compute 直接复用它、只重画波形、
        // 频谱与地形图，不再重跑整条流水线。与 raw 同寿命（shared_ptr 保证在工作线程
        // 用完前不析构）
        std::shared_ptr<const Result> previous;
    };

    // 工作线程产出的全部结果。**只含 POD 与 QImage**：QImage 是隐式共享的
    // 值类型，跨线程传递安全
    struct Result
    {
        int generation = 0;
        bool ok = false;
        QString error;

        int sample_rate = 0;
        int channels = 0;
        double segment_start = 0.0;
        double segment_seconds = 0.0;

        QStringList processing_chain;
        QVariantList channel_stats;
        QVariantList band_distribution;
        QVariantList channel_bands;
        QVariantList topo_stats;
        QVariantList report_sections;
        QVariantList status_groups;
        double topo_scale_max = 0.0;

        double wave_range_uv = 100.0;
        double spectrum_f_min = 0.5;
        double spectrum_f_max = 45.0;
        double spectrum_db_min = -90.0;
        double spectrum_db_max = 10.0;

        // 只画**用 QML 画不划算**的那几张：波形（16 路 × 上千个点，JS 侧光栅化
        // 一帧上百毫秒）、频谱曲线、相关性矩阵（16×16 个小格）、六张地形图。
        // 柱状图（频段大柱、每通道小柱）留给 QML 用 Rectangle 画 —— 十几个矩形
        // 而已，比在 C++ 里摆位置再贴一张图更省事，也随界面缩放不发虚
        QImage wave_image;
        QImage spectrum_image;
        QImage correlation_image;
        // 六个频段各一张，顺序同 bandKeys()
        QVector<QImage> topo_images;

        // 预处理后的整段数据（帧优先交错，单位 µV），「导出数据」用它。
        // 一轮十分钟的记录约 10 MB —— 为了导出再算一遍要几百毫秒，
        // 留着这份副本比每次重算划算
        QVector<float> processed;
        int processed_channels = 0;
        double processed_rate = 0.0;

        // 这一轮窗口无关输入的指纹。下一轮拖动时间轴时与它比对：相等就直接复用
        // 本结果的中间产物（processed / 统计 / 相关性…），只重画波形、频谱与地形图
        Fingerprint fingerprint;
    };

    // 原始数据：打开记录时读一次，之后所有重算只读它。
    // 用 QVector<float> 而不是每次重读文件 —— 拖一次滑块重读 30MB 没有意义
    struct RawData
    {
        QVector<float> samples;   // 帧优先交错，与 .eegbin 里一致
        int channels = 0;
        int frames = 0;
        int sample_rate = 0;
        qint64 start_utc_ms = 0;
    };

    // 在工作线程上跑。**只读 m_raw（shared_ptr 保证活着）**，不碰任何其它成员
    static Result compute(std::shared_ptr<const RawData> raw, Job job);

    // 波形图那张的出图（自动标尺 + 渲染）。窗口、当前导联、幅度标尺、事件都只
    // 影响它，所以命中指纹的增量重算也只调它，不碰整条流水线
    static void compute_wave(Result &result, const QVector<QVector<double>> &data,
                             double sample_rate, const Job &job);

    // 频谱图那张的出图（按当前窗口做 Welch + 渲染）。与波形图一样只依赖窗口与
    // 当前导联，所以命中指纹的增量重算也要调它 —— 拖动时间轴时频谱随之变化
    static void compute_spectrum(Result &result, const QVector<QVector<double>> &data,
                                 double sample_rate, const Job &job);

    // 六张地形图的出图（按当前窗口逐通道做 Welch + 取各频段平均功率谱密度 + 渲染）。
    // 与频谱图同一扇窗、同一份 Welch，所以命中指纹的增量重算也要调它 ——
    // 拖动时间轴时六张地形图随之变化
    static void compute_topography(Result &result, const QVector<QVector<double>> &data,
                                   double sample_rate, const Job &job);

    // 基本信息面板那五行，从 open() 收到的 info 拼出来
    void build_record_info();

    void schedule_recompute();
    void run_recompute();
    void on_recompute_finished();
    void invalidate();

    // 泳道高度。78 ≈ 设计稿里六条泳道铺满绘制区的高度，16 路时靠滚动看
    static constexpr int kLaneHeight = 78;

    std::shared_ptr<const RawData> m_raw;
    mutable QMutex m_mutex;

    bool m_loaded = false;
    QString m_error_text;
    QString m_record_no;
    QString m_subtitle;
    QString m_file_path;
    double m_duration_seconds = 0.0;
    int m_sample_rate = 0;
    int m_channels = 0;
    QVariantList m_record_info;
    QVariantList m_events;
    QVariantMap m_info;

    struct Params
    {
        bool high_pass_enabled = true;
        double high_pass_hz = 0.1;
        bool low_pass_enabled = true;
        double low_pass_hz = 49.0;
        bool notch_enabled = true;
        double notch_hz = 50.0;
        int reference_index = 2;   // 见 Job 里的说明：默认不重参考
        int downsample_index = 0;
        bool baseline_enabled = false;
        bool asr_enabled = false;
        int asr_cutoff = 40;
        bool artifact_detection_enabled = false;
        double wave_amplitude_uv = 0.0;   // 0 = 自动
        bool qc_signal_enabled = true;
        bool qc_range_enabled = true;
        bool qc_correlation_enabled = true;
        double qc_amplitude_ratio = 0.1;
        double qc_correlation = 0.1;
        int qc_repair_index = 0;          // 0=off, 1=限幅修复
        int export_format_index = 0;      // 0=EDF, 1=CSV
        int export_type_index = 0;        // 0=预处理数据, 1=原始数据
        int export_range_index = 0;       // 0=全记录, 1=当前片段
        // 默认「前 10 秒」。设计稿报告页写的就是「片段范围 0.0 - 10.0 s」，
        // 而且一条记录只要超过十秒，前 10 秒一定存在 —— 默认值就该是必然可用的那个
        int segment_index = 1;
        double before_seconds = -0.2;
        double after_seconds = 0.8;
    };
    Params m_params;

    int m_current_channel = 0;
    double m_window_start = 0.0;
    double m_window_seconds = 5.0;
    // 当前选中的事件标注（events 里的下标，-1 = 没选）
    int m_selected_event = -1;
    QSize m_view_size;
    // 绘制区的物理像素倍率（见 set_view_size）。只对波形生效：波形的泳道高由
    // C++ 内部决定（lane_height），不像频谱那样拿 QML 报来的高度，得靠这个倍率
    // 才能跟着高 DPI 一起放大
    double m_view_pixel_ratio = 1.0;
    // 最近一轮结果对应的片段（秒）与色标上限。单独存一份是为了让
    //「参数刚改、结果还没回来」的那一小段时间里界面拿到的仍是上一轮的值，
    // 而不是 0 —— 显示 0 会让报告页闪一下「片段 0.0-0.0 s」
    double m_segment_start = 0.0;
    double m_segment_seconds = 0.0;
    double m_topo_scale_max = 0.0;

    bool m_busy = false;
    QString m_status_text;
    int m_generation = 0;
    int m_applied_generation = 0;
    Result m_result;
    // 最近一次真正落到界面上的结果。拖动时间轴时把它交给工作线程做增量重算的底子
    std::shared_ptr<const Result> m_previous;
    // 计算期间又来了改动：等这一轮一结束就立刻补跑最新参数，而不是再等一拍
    bool m_pending_recompute = false;
    QFutureWatcher<Result> m_watcher;
    class QTimer *m_debounce = nullptr;
};

// 把 PostProcess 画好的图交给 QML 的 Image 元素。
// 非拥有：PostProcess 由 main.cpp 持有，且声明在 QML 引擎之前，析构顺序有保证
class PostProcessImageProvider : public QQuickImageProvider
{
public:
    explicit PostProcessImageProvider(PostProcess *analysis);

    QImage requestImage(const QString &id, QSize *size, const QSize &requested_size) override;

private:
    PostProcess *m_analysis = nullptr;
};

#endif // POSTPROCESS_H
