#ifndef RECORDINGPREVIEW_H
#define RECORDINGPREVIEW_H

#include <QFile>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QVector>

// 历史采集记录的波形回放（「采集记录预览」弹窗里那块波形）。
//
// 记录文件是 .eegbin：64 字节文件头 + float32 帧优先交错的样本，
// 格式见 serialcollector.cpp 的「二进制格式」一节。只有这几行，照着读即可，
// 不必为此引进 BDF/EDF 那一整套库。
//
// 为什么绘制放在 C++ 而不是 QML 的 Canvas：与实时波形同一个原因（见
// bridgeimageproviders.h）—— 一竖屏 16 路 × 上千个点全走 JS 侧的光栅化，
// 每帧要上百毫秒，界面会卡成幻灯片。
//
// 为什么单独一个类而不是塞进 AcquisitionBridge：它读的是磁盘上的文件，
// 与串口、算法会话、采集线程没有任何关系。混进那个类只会让它继续膨胀，
// 而「打开一条历史记录」与「正在采集」本来就是互不相干的两件事
class RecordingPreview : public QObject
{
    Q_OBJECT

    // 是否已经成功打开一个文件。界面据此决定画面板还是空态
    Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
    // 打不开的原因（文件不存在、格式不对、空文件），显示在波形区的空态里
    Q_PROPERTY(QString errorText READ error_text NOTIFY loadedChanged)
    Q_PROPERTY(int channelCount READ channel_count NOTIFY loadedChanged)
    Q_PROPERTY(int sampleRate READ sample_rate NOTIFY loadedChanged)
    Q_PROPERTY(double durationSeconds READ duration_seconds NOTIFY loadedChanged)
    // 记录起始时刻（文件头里那个 UTC 毫秒），格式化成界面上的写法
    Q_PROPERTY(QString startTimeText READ start_time_text NOTIFY loadedChanged)
    Q_PROPERTY(QStringList channelNames READ channel_names NOTIFY loadedChanged)
    Q_PROPERTY(QStringList channelColors READ channel_colors CONSTANT)

    // 当前显示的时间窗口。回放就是按固定步长推进 windowStart
    Q_PROPERTY(double windowStart READ window_start WRITE set_window_start
                   NOTIFY viewChanged)
    Q_PROPERTY(double windowSeconds READ window_seconds WRITE set_window_seconds
                   NOTIFY viewChanged)
    // 幅值标尺（µV）：0 表示按窗口内峰值自动
    Q_PROPERTY(int yRangeUV READ y_range_uv WRITE set_y_range_uv NOTIFY viewChanged)
    // 每画好一帧自增，QML 靠它变化触发 Image 换 URL（否则 Image 会按 URL 缓存，
    // 图永远停在第一帧）。
    // **必须挂在 imageChanged 上而不是 viewChanged 上**：windowStart 变化时
    // 是先发 viewChanged 再重画，若 revision 也挂在这条信号上，QML 会在图还没
    // 重画出来时就去取，取到的永远是上一帧
    Q_PROPERTY(int revision READ revision NOTIFY imageChanged)

public:
    explicit RecordingPreview(QObject *parent = nullptr);
    ~RecordingPreview() override;

    // 打开一个记录文件。成功返回 true；失败时 errorText 给出原因
    Q_INVOKABLE bool open(const QString &path);
    Q_INVOKABLE void close();

    // 波形绘制区的像素尺寸，由 QML 在尺寸变化时报上来
    Q_INVOKABLE void set_view_size(int width, int height);

    bool loaded() const { return m_loaded; }
    QString error_text() const { return m_error_text; }
    int channel_count() const { return m_channels; }
    int sample_rate() const { return m_sample_rate; }
    double duration_seconds() const { return m_duration_seconds; }
    QString start_time_text() const { return m_start_time_text; }
    QStringList channel_names() const;
    static QStringList channel_colors();

    double window_start() const { return m_window_start; }
    double window_seconds() const { return m_window_seconds; }
    int y_range_uv() const { return m_y_range_uv; }
    int revision() const { return m_revision; }

    // 当前这一帧的图。Qt 不保证 image provider 的调用线程，所以加锁并交出深拷贝
    QImage current_image() const;
    QQuickImageProvider *create_image_provider();

public slots:
    void set_window_start(double seconds);
    void set_window_seconds(double seconds);
    void set_y_range_uv(int range_uv);

signals:
    void loadedChanged();
    void viewChanged();
    // 换了一帧图（revision 跟着自增）
    void imageChanged();

private:
    void unload();
    // 按当前窗口重画一帧。锁内取数据、锁外绘制
    void render();
    // 窗口内某通道的样本下标范围。越界时自动夹到文件范围内
    void frame_range(int *first, int *last) const;

    QFile m_file;
    // 文件映射，只读。整段映射而不是边读边解析：一条 10 分钟的记录约 38 MB，
    // 映射省掉一次全量读入，而且随机访问窗口内任意位置都是常数时间
    uchar *m_map = nullptr;

    bool m_loaded = false;
    QString m_error_text;
    QString m_path;
    int m_channels = 0;
    int m_sample_rate = 0;
    qint64 m_frames = 0;
    double m_duration_seconds = 0.0;
    QString m_start_time_text;

    QSize m_view_size;
    double m_window_start = 0.0;
    double m_window_seconds = 5.0;
    // 0 表示自动量程
    int m_y_range_uv = 0;
    int m_revision = 0;

    QImage m_image;
    mutable QMutex m_mutex;
};

// 把 RecordingPreview 画好的图交给 QML 的 Image 元素。
// URL 里的 revision 只用来制造新 URL，id 本身不用
class RecordingImageProvider : public QQuickImageProvider
{
public:
    explicit RecordingImageProvider(RecordingPreview *preview);

    QImage requestImage(const QString &id, QSize *size, const QSize &requested_size) override;

private:
    // 非拥有：preview 由 main.cpp 持有，且声明在 QML 引擎之前，析构顺序有保证
    RecordingPreview *m_preview = nullptr;
};

#endif // RECORDINGPREVIEW_H
