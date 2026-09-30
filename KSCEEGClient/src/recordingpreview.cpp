#include "recordingpreview.h"

#include <QDateTime>
#include <QDebug>
#include <QPainter>
#include <QQuickImageProvider>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "eegbinformat.h"
#include "eegmontage.h"

namespace
{

quint32 read_u32_le(const uchar *data)
{
    return static_cast<quint32>(data[0])
           | (static_cast<quint32>(data[1]) << 8)
           | (static_cast<quint32>(data[2]) << 16)
           | (static_cast<quint32>(data[3]) << 24);
}

qint64 read_i64_le(const uchar *data)
{
    quint64 value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<quint64>(data[i]) << (8 * i);
    return static_cast<qint64>(value);
}

float read_f32_le(const uchar *data)
{
    const quint32 bits = read_u32_le(data);
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

} // namespace

RecordingPreview::RecordingPreview(QObject *parent)
    : QObject(parent)
{
}

RecordingPreview::~RecordingPreview()
{
    unload();
}

QStringList RecordingPreview::channel_names() const
{
    if (m_channels <= 0)
        return {};

    QStringList names;
    names.reserve(m_channels);
    for (int i = 0; i < m_channels; ++i)
        names.append(eeg_montage::channel_name(i));
    return names;
}

QStringList RecordingPreview::channel_colors()
{
    return {QStringLiteral("#0e9fbf"), QStringLiteral("#36a772"), QStringLiteral("#daa82a"),
            QStringLiteral("#e07a2e"), QStringLiteral("#d675a4"), QStringLiteral("#876ee3"),
            QStringLiteral("#299fbb"), QStringLiteral("#6baa40")};
}

bool RecordingPreview::open(const QString &path)
{
    unload();

    m_path = path;
    m_file.setFileName(path);

    // 失败时统一走 fail()：它把文件句柄与映射还回去。
    // 分散在五处 return false 的话，每条分支都要记得清理一遍，
    // 漏一条就是「弹窗关了这一屏，文件却还占着几十 MB 映射」
    const auto fail = [this](const QString &reason) {
        unload();
        m_error_text = reason;
        emit loadedChanged();
        return false;
    };

    if (path.trimmed().isEmpty() || !m_file.exists())
        return fail(tr("记录文件不存在"));

    if (!m_file.open(QIODevice::ReadOnly))
        return fail(tr("无法打开记录文件"));

    const qint64 size = m_file.size();
    if (size <= eegbin::kHeaderSize)
        return fail(tr("记录文件为空"));

    m_map = m_file.map(0, size);
    if (m_map == nullptr)
        return fail(tr("映射记录文件失败"));

    if (std::memcmp(m_map, eegbin::kMagic, sizeof(eegbin::kMagic)) != 0)
        return fail(tr("记录文件格式无法识别"));

    // 版本与头长都要校验。不校验的话，将来头长从 64 改成 128 时这里不会报错，
    // 而是按错误偏移解析出一张乱七八糟的波形图 —— 那种错最难查
    const quint32 version = read_u32_le(m_map + eegbin::kVersionOffset);
    const quint32 header_size = read_u32_le(m_map + eegbin::kHeaderSizeOffset);
    if (version != eegbin::kVersion || header_size != eegbin::kHeaderSize)
        return fail(tr("记录文件版本不支持"));

    m_channels = static_cast<int>(read_u32_le(m_map + eegbin::kChannelsOffset));
    m_sample_rate = static_cast<int>(read_u32_le(m_map + eegbin::kSampleRateOffset));
    const qint64 start_ms = read_i64_le(m_map + eegbin::kStartTimeOffset);

    if (m_channels <= 0 || m_sample_rate <= 0)
        return fail(tr("记录文件头不完整"));

    // 以文件实际长度为准算帧数，不信头里那个 frame_count：程序被强杀时
    // 那一栏根本来不及回填（写头时它是 0），而文件里的样本是真的
    const qint64 payload = size - eegbin::kHeaderSize;
    m_frames = payload / (static_cast<qint64>(m_channels) * eegbin::kBytesPerSample);
    if (m_frames <= 0)
        return fail(tr("记录文件里没有样本数据"));

    m_duration_seconds = static_cast<double>(m_frames) / m_sample_rate;
    m_start_time_text = start_ms > 0
                            ? QDateTime::fromMSecsSinceEpoch(start_ms)
                                  .toString(QStringLiteral("yyyy-M-d hh:mm:ss"))
                            : QString();

    m_loaded = true;
    m_error_text.clear();
    m_window_start = 0.0;
    // 默认窗口取 5 秒：再短看不出节律，再长 16 路会挤成一团
    m_window_seconds = std::min(5.0, std::max(0.5, m_duration_seconds));

    // **先画再报 loaded**：反过来的话 QML 会把 visible 置真、拿着旧 revision
    // 去取图，取到的是上一张占位图，波形区会先空白闪几帧
    render();
    emit loadedChanged();
    return true;
}

void RecordingPreview::close()
{
    unload();
    emit loadedChanged();
}

void RecordingPreview::unload()
{
    if (m_map != nullptr)
    {
        m_file.unmap(m_map);
        m_map = nullptr;
    }
    if (m_file.isOpen())
        m_file.close();

    m_loaded = false;
    m_channels = 0;
    m_sample_rate = 0;
    m_frames = 0;
    m_duration_seconds = 0.0;
    m_start_time_text.clear();

    {
        QMutexLocker locker(&m_mutex);
        m_image = QImage();
        ++m_revision;
    }
    emit imageChanged();
}

void RecordingPreview::set_view_size(int width, int height)
{
    if (width <= 0 || height <= 0)
        return;
    const QSize size(width, height);
    if (size == m_view_size)
        return;

    m_view_size = size;
    render();
}

void RecordingPreview::set_window_start(double seconds)
{
    // 起点允许贴到末尾：窗口后半段空着是正常的，但起点本身不能越界，
    // 否则会去读文件范围外的样本
    const double maximum = std::max(0.0, m_duration_seconds - 0.001);
    const double clamped = std::clamp(seconds, 0.0, maximum);
    if (qFuzzyCompare(clamped + 1.0, m_window_start + 1.0))
        return;

    m_window_start = clamped;
    emit viewChanged();
    render();
}

void RecordingPreview::set_window_seconds(double seconds)
{
    const double clamped = std::clamp(seconds, 0.1, 60.0);
    if (qFuzzyCompare(clamped + 1.0, m_window_seconds + 1.0))
        return;

    m_window_seconds = clamped;
    emit viewChanged();
    render();
}

void RecordingPreview::set_y_range_uv(int range_uv)
{
    if (range_uv == m_y_range_uv)
        return;

    m_y_range_uv = range_uv;
    emit viewChanged();
    render();
}

QImage RecordingPreview::render_window(double start_seconds, double seconds, int width,
                                       int height, int y_range_uv) const
{
    if (!m_loaded || m_map == nullptr || width < 2 || height < 2 || m_channels <= 0)
        return QImage();

    // 窗口内的样本下标范围。越界时夹到文件范围内：起点允许贴到末尾（窗口后半段
    // 空着是正常的），但不能去读文件范围外的样本
    const qint64 begin = static_cast<qint64>(start_seconds * m_sample_rate);
    const qint64 end = static_cast<qint64>((start_seconds + seconds) * m_sample_rate);
    const int first
        = static_cast<int>(std::clamp<qint64>(begin, 0, std::max<qint64>(0, m_frames - 1)));
    const int last = static_cast<int>(std::clamp<qint64>(end, first + 1, m_frames));
    const int frames = std::max(1, last - first);

    QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);

    const double lane_step = static_cast<double>(height) / m_channels;
    // 半格再收 14%：每路都按自己的峰值满格画的话，相邻泳道的波峰会贴在一起，
    // 16 路连成一片，反而看不出是哪一路
    const double half_lane = std::max(1.0, lane_step / 2.0 * 0.86);

    // 一列像素对应一段原始样本，取该段的 min/max 画成一条竖向包络。
    //
    // **不能按固定步长抽点**：当步长与信号周期成整数比（拍频）时，抽出的点会
    // 长期落在同相位，包络被"抽"成一条细线，波形上就出现斜向白带 —— 数据明明
    // 在，看着像断了。取每列 min/max 则保证任何一列的幅度范围都不会丢失。
    const int columns = std::min(width, frames);

    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing, false);

    QVector<double> col_min(columns);
    QVector<double> col_max(columns);
    QVector<QPointF> polyline;
    polyline.reserve(columns * 2);

    const QStringList colors = channel_colors();

    for (int ch = 0; ch < m_channels; ++ch)
    {
        const double center = lane_step * ch + lane_step / 2.0;

        // 先按列统计 min/max，并顺带求本窗口均值。
        //
        // **必须先去直流再定标**：电极的半电池电位在几百毫伏量级，而脑电只有
        // 几十微伏。按原始值取峰值的话，"峰值"就是那个直流偏置，整条曲线会被
        // 压成一条直线 —— 数据明明在，看上去像没采到。
        // 不去算整条记录的峰值也是同一个道理：安静的一段会被别处的尖峰摊平
        double sum = 0.0;
        int count = 0;
        for (int i = 0; i < columns; ++i)
        {
            const int b0 = first + static_cast<int>(static_cast<qint64>(i) * frames / columns);
            const int b1
                = first + static_cast<int>(static_cast<qint64>(i + 1) * frames / columns);
            double lo = 0.0;
            double hi = 0.0;
            for (int frame = b0; frame < b1; ++frame)
            {
                const uchar *cell = m_map + eegbin::kHeaderSize
                                    + (static_cast<qint64>(frame) * m_channels + ch) * 4;
                const double value = static_cast<double>(read_f32_le(cell));
                if (frame == b0)
                {
                    lo = value;
                    hi = value;
                }
                else
                {
                    lo = std::min(lo, value);
                    hi = std::max(hi, value);
                }
                sum += value;
                ++count;
            }
            col_min[i] = lo;
            col_max[i] = hi;
        }

        const double mean = count > 0 ? sum / count : 0.0;

        double peak = 0.0;
        for (int i = 0; i < columns; ++i)
        {
            peak = std::max(peak, std::abs(col_max[i] - mean));
            peak = std::max(peak, std::abs(col_min[i] - mean));
        }
        const double range = y_range_uv > 0 ? static_cast<double>(y_range_uv)
                                            : std::max(1.0, peak);

        polyline.clear();
        for (int i = 0; i < columns; ++i)
        {
            const double x = width * (static_cast<double>(i) + 0.5) / columns;
            const double y_hi
                = center - std::clamp((col_max[i] - mean) / range, -1.0, 1.0) * half_lane;
            const double y_lo
                = center - std::clamp((col_min[i] - mean) / range, -1.0, 1.0) * half_lane;
            // 奇偶列交替落笔，避免相邻列之间拉出长长的斜线，包络看起来才连贯
            if ((i & 1) == 0)
            {
                polyline.append(QPointF(x, y_hi));
                polyline.append(QPointF(x, y_lo));
            }
            else
            {
                polyline.append(QPointF(x, y_lo));
                polyline.append(QPointF(x, y_hi));
            }
        }

        if (polyline.size() < 2)
            continue;

        painter.setPen(QPen(QColor(colors.at(ch % colors.size())), 1.0));
        painter.drawPolyline(polyline.constData(), static_cast<int>(polyline.size()));
    }

    painter.end();
    return image;
}

QImage RecordingPreview::current_image() const
{
    QMutexLocker locker(&m_mutex);
    if (m_image.isNull())
    {
        // 还没有过一帧图（刚打开、尺寸还没报上来）时给一张 1×1 的透明图，
        // 而不是空 QImage —— 空图会让 Qt 打一行「Failed to get image from provider」，
        // 那是正常过程，不该在日志里刷成像是出错
        QImage placeholder(1, 1, QImage::Format_ARGB32_Premultiplied);
        placeholder.fill(Qt::transparent);
        return placeholder;
    }
    return m_image.copy();
}

void RecordingPreview::render()
{
    if (!m_loaded || m_map == nullptr || m_view_size.isEmpty())
        return;

    const QImage image = render_window(m_window_start, m_window_seconds, m_view_size.width(),
                                       m_view_size.height(), m_y_range_uv);
    if (image.isNull())
        return;

    {
        QMutexLocker locker(&m_mutex);
        m_image = image;
        ++m_revision;
    }
    // 通知在锁外发：订阅方一收到就会回来取图，那把锁正被这里拿着的话就是自己等自己
    emit imageChanged();
}

QQuickImageProvider *RecordingPreview::create_image_provider()
{
    return new RecordingImageProvider(this);
}

// ==================== image provider ====================

RecordingImageProvider::RecordingImageProvider(RecordingPreview *preview)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_preview(preview)
{
}

QImage RecordingImageProvider::requestImage(const QString &id, QSize *size,
                                            const QSize &requested_size)
{
    Q_UNUSED(id);
    Q_UNUSED(requested_size);

    const QImage image = m_preview != nullptr ? m_preview->current_image() : QImage();
    if (size != nullptr)
        *size = image.size();
    return image;
}
