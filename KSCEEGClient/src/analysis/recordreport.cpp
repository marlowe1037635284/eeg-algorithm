#include "analysis/recordreport.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetricsF>
#include <QPageSize>
#include <QPainter>
#include <QPdfWriter>
#include <QRectF>
#include <QStringList>
#include <QUrl>

#include <algorithm>
#include <cmath>

#include "common/eegmontage.h"
#include "analysis/recordingpreview.h"
#include "common/auditlog.h"

namespace
{

// 报告一律按 150 dpi 出图：再低波形糊成一团，再高文件大得没意义。
// A4 在这个分辨率下约 1240×1754 像素
constexpr int kDpi = 150;
constexpr qreal kMargin = 56.0;

// 报告波形用固定量程（与工作台、预览弹窗的默认标尺一致），不按峰值自动 ——
// 一份「回顾整段记录」的报告要能横向比较各段幅值，自动量程会把安静的段放得跟
// 剧烈段一样大，看上去全都一样
constexpr int kYRangeUV = 100;

const QColor kInk(0x21, 0x21, 0x21);
const QColor kSub(0x63, 0x63, 0x63);
const QColor kMuted(0xa3, 0xa3, 0xa3);
const QColor kPrimary(0x70, 0x92, 0xab);
const QColor kCard(0xf5, 0xf6, 0xf8);
const QColor kRule(0xe4, 0xe7, 0xea);
const QColor kPlotFill(0xfb, 0xfb, 0xfc);

// 与 Design.qml 同一套字体：普惠体四个字重在 Qt 里合并成一个家族，
// 只能靠 styleName 选，用 weight 是选不出来的（见 Design.qml 与 main.cpp）
const QString kFamily = QStringLiteral("Alibaba PuHuiTi 2.0");
const QString kStyleRegular = QStringLiteral("55 Regular");
const QString kStyleMedium = QStringLiteral("65 Medium");
const QString kStyleBold = QStringLiteral("85 Bold");

QFont report_font(const QString &style, qreal point_size)
{
    QFont font(kFamily);
    font.setStyleName(style);
    font.setPointSizeF(point_size);
    return font;
}

// 与预览弹窗的 formatClock 同一套写法：不足一小时只写 mm:ss
QString format_clock(double seconds)
{
    const int total = static_cast<int>(seconds + 0.5);
    const int h = total / 3600;
    const int m = (total / 60) % 60;
    const int s = total % 60;
    if (h > 0)
        return QStringLiteral("%1:%2:%3")
            .arg(h)
            .arg(m, 2, 10, QLatin1Char('0'))
            .arg(s, 2, 10, QLatin1Char('0'));
    return QStringLiteral("%1:%2")
        .arg(m, 2, 10, QLatin1Char('0'))
        .arg(s, 2, 10, QLatin1Char('0'));
}

} // namespace

RecordReport::RecordReport(QObject *parent)
    : QObject(parent)
{
}

QVariantMap RecordReport::exportPdf(const QVariantMap &session, const QVariantList &events,
                                    const QString &directory) const
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;
    result[QStringLiteral("path")] = QString();

    if (session.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("记录不存在");
        return result;
    }

    // QML 侧 StandardPaths.writableLocation 给的是 file:/// 形式的 URL（QML 的 url
    // 类型，本身没有 toLocalFile），直接拿去构造 QDir 会判定为不存在的目录，
    // 所以先按 URL 解成本地路径再用
    QString target_path = directory;
    if (target_path.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive))
        target_path = QUrl(target_path).toLocalFile();

    const QDir target_dir(target_path);
    if (target_path.isEmpty() || !target_dir.exists())
    {
        result[QStringLiteral("message")] = QStringLiteral("导出目录不可用");
        return result;
    }

    const QString no = session.value(QStringLiteral("no")).toString();
    const QString patient_no = session.value(QStringLiteral("patientNo")).toString();
    const QString stem = QStringLiteral("%1_%2").arg(no, patient_no);
    const QString target = target_dir.filePath(stem + QStringLiteral("_采集报告.pdf"));

    // 目标已存在时先删掉：反复导出覆盖上一次才是预期行为，
    // 报「文件已存在」只会让人以为导出坏了（与 AppDatabase::exportSession 一致）
    if (QFile::exists(target) && !QFile::remove(target))
    {
        result[QStringLiteral("message")]
            = QStringLiteral("目标文件被占用，无法覆盖：%1").arg(target);
        return result;
    }

    QPdfWriter writer(target);
    writer.setPageSize(QPageSize(QPageSize::A4));
    // 页边距交给排版自己算：用默认边距的话坐标系原点会跟着挪，
    // 「贴边留 56」这类固定偏移就全得再减一遍
    writer.setPageMargins(QMarginsF(0, 0, 0, 0));
    writer.setResolution(kDpi);
    writer.setTitle(QStringLiteral("%1 采集记录报告").arg(no));

    QPainter painter;
    if (!painter.begin(&writer))
    {
        result[QStringLiteral("message")] = QStringLiteral("写入 PDF 失败");
        return result;
    }

    const int page_w = painter.device()->width();
    const int page_h = painter.device()->height();
    const qreal content_w = page_w - 2 * kMargin;
    // 正文底部的位置，留给页脚
    const qreal body_bottom = page_h - kMargin - 26.0;
    int page = 1;

    const auto draw_footer = [&](int page_no) {
        painter.setFont(report_font(kStyleRegular, 9));
        painter.setPen(kMuted);
        painter.drawText(QRectF(kMargin, page_h - kMargin + 4, content_w * 0.6, 18),
                         Qt::AlignLeft | Qt::AlignVCenter,
                         QStringLiteral("生成时间 %1").arg(QDateTime::currentDateTime()
                                                              .toString(QStringLiteral(
                                                                  "yyyy-M-d hh:mm"))));
        painter.drawText(QRectF(kMargin + content_w * 0.4, page_h - kMargin + 4, content_w * 0.6, 18),
                         Qt::AlignRight | Qt::AlignVCenter,
                         QStringLiteral("第 %1 页").arg(page_no));
    };

    // ---------- 标题 ----------
    qreal y = kMargin;
    painter.setFont(report_font(kStyleBold, 20));
    painter.setPen(kInk);
    painter.drawText(QRectF(kMargin, y, content_w * 0.65, 44),
                     Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("采集记录报告"));
    painter.setFont(report_font(kStyleRegular, 11));
    painter.setPen(kSub);
    painter.drawText(QRectF(kMargin + content_w * 0.35, y, content_w * 0.65, 44),
                     Qt::AlignRight | Qt::AlignVCenter, no);

    y += 44;
    painter.setPen(QPen(kPrimary, 2.0));
    painter.drawLine(QPointF(kMargin, y + 10), QPointF(kMargin + content_w, y + 10));
    y += 10;

    // ---------- 信息卡（3 列 × 3 行） ----------
    const qreal card_x = kMargin;
    const qreal card_y = y + 26;
    const qreal row_h = 62.0;
    const qreal card_h = row_h * 3 + 32;
    painter.setPen(Qt::NoPen);
    painter.setBrush(kCard);
    painter.drawRoundedRect(QRectF(card_x, card_y, content_w, card_h), 8, 8);

    const QString gender_age
        = session.value(QStringLiteral("age")).toInt() > 0
              ? QStringLiteral("%1 · %2 岁")
                    .arg(session.value(QStringLiteral("gender")).toString())
                    .arg(session.value(QStringLiteral("age")).toInt())
              : session.value(QStringLiteral("gender")).toString();
    const QString patient_no_dept
        = session.value(QStringLiteral("dept")).toString().isEmpty()
              ? patient_no
              : QStringLiteral("%1 · %2").arg(patient_no,
                                              session.value(QStringLiteral("dept")).toString());
    const QString channels_rate
        = QStringLiteral("%1 通道 · %2 Hz")
              .arg(session.value(QStringLiteral("channels")).toInt())
              .arg(session.value(QStringLiteral("rate")).toInt());

    struct Field
    {
        QString label;
        QString value;
    };
    const Field fields[9] = {
        {QStringLiteral("患者"), session.value(QStringLiteral("patient")).toString()},
        {QStringLiteral("性别 / 年龄"), gender_age},
        {QStringLiteral("病历号 / 科室"), patient_no_dept},
        {QStringLiteral("采集时间"), session.value(QStringLiteral("time")).toString()},
        {QStringLiteral("记录时长"), session.value(QStringLiteral("duration")).toString()},
        {QStringLiteral("通道 / 采样率"), channels_rate},
        {QStringLiteral("事件标注"),
         QStringLiteral("%1 条").arg(events.size())},
        {QStringLiteral("显示量程"), QStringLiteral("%1 μV / 全程").arg(kYRangeUV)},
        {QStringLiteral("电极贴合"), session.value(QStringLiteral("quality")).toString()},
    };

    const qreal cell_w = content_w / 3.0;
    for (int i = 0; i < 9; ++i)
    {
        const qreal cx = card_x + (i % 3) * cell_w + 24;
        const qreal cy = card_y + 16 + (i / 3) * row_h;
        const qreal cw = cell_w - 24 - 12;
        painter.setFont(report_font(kStyleRegular, 9));
        painter.setPen(kMuted);
        painter.drawText(QRectF(cx, cy, cw, 18), Qt::AlignLeft | Qt::AlignVCenter, fields[i].label);
        painter.setFont(report_font(kStyleMedium, 12));
        painter.setPen(kInk);
        painter.drawText(QRectF(cx, cy + 22, cw, 26), Qt::AlignLeft | Qt::AlignVCenter,
                         fields[i].value);
    }

    // 小标题 + 右侧附注 + 一条细线。波形段与事件段共用这一套
    const auto draw_section = [&](qreal section_y, const QString &title, const QString &right) {
        painter.setFont(report_font(kStyleBold, 13));
        painter.setPen(kInk);
        painter.drawText(QRectF(kMargin, section_y, content_w * 0.5, 26),
                         Qt::AlignLeft | Qt::AlignVCenter, title);
        if (!right.isEmpty())
        {
            painter.setFont(report_font(kStyleRegular, 10));
            painter.setPen(kMuted);
            painter.drawText(QRectF(kMargin + content_w * 0.5, section_y, content_w * 0.5, 26),
                             Qt::AlignRight | Qt::AlignVCenter, right);
        }
        painter.setPen(QPen(kRule, 1.0));
        painter.drawLine(QPointF(kMargin, section_y + 30), QPointF(kMargin + content_w, section_y + 30));
    };

    // ---------- 全程波形 ----------
    const double duration = session.value(QStringLiteral("durationSeconds")).toDouble();
    const qreal wave_section_y = card_y + card_h + 34;
    draw_section(wave_section_y, QStringLiteral("全程波形"),
                 QStringLiteral("0:00 – %1 · %2 μV").arg(format_clock(duration)).arg(kYRangeUV));

    const qreal label_w = 48.0;
    const qreal plot_x = kMargin + label_w + 10;
    const qreal plot_w = content_w - label_w - 10;
    // 与预览弹窗的轨迹区同一比例（802×429），出图不会变形
    const qreal plot_h = std::round(plot_w * 429.0 / 802.0);
    const qreal plot_y = wave_section_y + 30 + 18;

    // 波形图由 RecordingPreview 画，与界面上那块是从同一段代码出来的
    RecordingPreview preview;
    QImage wave;
    const QString file_path = session.value(QStringLiteral("filePath")).toString();
    if (!file_path.isEmpty() && QFile::exists(file_path) && preview.open(file_path))
        wave = preview.render_window(0.0, preview.duration_seconds(), static_cast<int>(plot_w),
                                     static_cast<int>(plot_h), kYRangeUV);

    painter.setPen(QPen(kRule, 1.0));
    painter.setBrush(kPlotFill);
    painter.drawRect(QRectF(plot_x, plot_y, plot_w, plot_h));

    const int channels = preview.loaded() ? preview.channel_count()
                                          : session.value(QStringLiteral("channels")).toInt();
    const qreal lane_step = channels > 0 ? plot_h / channels : plot_h;

    if (!wave.isNull())
    {
        // 泳道分隔线画在波形下面，避免盖住曲线
        painter.setPen(QPen(QColor(0xee, 0xf0, 0xf3), 1.0));
        for (int i = 1; i < channels; ++i)
            painter.drawLine(QPointF(plot_x, plot_y + lane_step * i),
                             QPointF(plot_x + plot_w, plot_y + lane_step * i));

        painter.drawImage(QPointF(plot_x, plot_y), wave);

        painter.setFont(report_font(kStyleRegular, 8));
        painter.setPen(kSub);
        for (int i = 0; i < channels; ++i)
        {
            const qreal cy = plot_y + lane_step * i + lane_step / 2.0;
            painter.drawText(QRectF(kMargin, cy - 9, label_w, 18),
                             Qt::AlignRight | Qt::AlignVCenter,
                             eeg_montage::channel_name(i));
        }
    }
    else
    {
        painter.setFont(report_font(kStyleRegular, 11));
        painter.setPen(kMuted);
        painter.drawText(QRectF(plot_x, plot_y, plot_w, plot_h), Qt::AlignCenter,
                         QStringLiteral("原始数据文件缺失，无法渲染波形"));
    }

    // 时间刻度：首末与三等分，末刻度往里收，别越出轨迹区
    painter.setFont(report_font(kStyleRegular, 9));
    for (int i = 0; i <= 4; ++i)
    {
        const qreal tx = plot_x + plot_w * i / 4.0;
        painter.setPen(QPen(kRule, 1.0));
        painter.drawLine(QPointF(tx, plot_y + plot_h), QPointF(tx, plot_y + plot_h + 6));

        const QString label = format_clock(duration * i / 4.0);
        const qreal tw = QFontMetricsF(painter.font()).horizontalAdvance(label);
        const qreal lx = std::clamp(tx - tw / 2.0, plot_x, plot_x + plot_w - tw);
        painter.setPen(kMuted);
        painter.drawText(QRectF(lx, plot_y + plot_h + 8, tw + 2, 18),
                         Qt::AlignLeft | Qt::AlignVCenter, label);
    }

    // ---------- 事件标注 ----------
    y = plot_y + plot_h + 34;
    draw_section(y, QStringLiteral("事件标注（%1）").arg(events.size()), QString());
    y += 30 + 16;

    const qreal event_x1 = kMargin;
    const qreal event_w1 = content_w * 0.16;
    const qreal event_x2 = kMargin + event_w1 + 16;
    const qreal event_w2 = content_w * 0.30;
    const qreal event_x3 = kMargin + event_w1 + event_w2 + 32;
    const qreal event_w3 = content_w - event_w1 - event_w2 - 32;
    const qreal event_row_h = 30.0;

    const auto draw_event_header = [&]() {
        painter.setFont(report_font(kStyleMedium, 10));
        painter.setPen(kSub);
        const qreal ty = y + 6;
        painter.drawText(QRectF(event_x1, ty, event_w1, 18),
                         Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("时刻"));
        painter.drawText(QRectF(event_x2, ty, event_w2, 18),
                         Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("采集时刻"));
        painter.drawText(QRectF(event_x3, ty, event_w3, 18),
                         Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("事件标签"));
        painter.setPen(QPen(kRule, 1.0));
        painter.drawLine(QPointF(kMargin, y + event_row_h), QPointF(kMargin + content_w, y + event_row_h));
        y += event_row_h;
    };

    if (events.isEmpty())
    {
        painter.setFont(report_font(kStyleRegular, 11));
        painter.setPen(kMuted);
        painter.drawText(QRectF(kMargin, y, content_w, 26),
                         Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("该记录没有事件标注"));
        y += 26;
    }
    else
    {
        draw_event_header();
        for (int i = 0; i < events.size(); ++i)
        {
            // 一行放不下就翻页，并把表头重画一遍，续页上看不出这是第几列
            if (y + event_row_h > body_bottom)
            {
                draw_footer(page);
                writer.newPage();
                ++page;
                y = kMargin;
                draw_event_header();
            }

            const QVariantMap event = events.at(i).toMap();
            const QColor dot(event.value(QStringLiteral("color")).toString());

            if (i % 2 == 0)
            {
                painter.setPen(Qt::NoPen);
                painter.setBrush(kCard);
                painter.drawRect(QRectF(kMargin, y, content_w, event_row_h));
            }

            const qreal ty = y + 6;
            painter.setFont(report_font(kStyleRegular, 10));
            painter.setPen(kSub);
            painter.drawText(QRectF(event_x1, ty, event_w1, 18), Qt::AlignLeft | Qt::AlignVCenter,
                             format_clock(event.value(QStringLiteral("offsetSeconds")).toDouble()));
            painter.drawText(QRectF(event_x2, ty, event_w2, 18), Qt::AlignLeft | Qt::AlignVCenter,
                             event.value(QStringLiteral("wallClock")).toString());

            painter.setPen(Qt::NoPen);
            painter.setBrush(dot.isValid() ? dot : kPrimary);
            painter.drawEllipse(QPointF(event_x3 + 5, y + event_row_h / 2.0), 4.5, 4.5);
            painter.setFont(report_font(kStyleMedium, 10));
            painter.setPen(kInk);
            painter.drawText(QRectF(event_x3 + 18, ty, event_w3 - 18, 18),
                             Qt::AlignLeft | Qt::AlignVCenter,
                             event.value(QStringLiteral("label")).toString());

            painter.setPen(QPen(kRule, 1.0));
            painter.drawLine(QPointF(kMargin, y + event_row_h),
                             QPointF(kMargin + content_w, y + event_row_h));
            y += event_row_h;
        }
    }

    draw_footer(page);
    painter.end();

    // end() 之后才看得到最终字节数。写不出来的情况（磁盘满、目标被占用）
    // QPdfWriter 不会抛异常，只会留下一个空的/半截文件 —— 那种文件提示「导出成功」
    // 比直接报错更糟
    if (!QFile::exists(target) || QFileInfo(target).size() == 0)
    {
        result[QStringLiteral("message")] = QStringLiteral("写入 PDF 失败：%1").arg(target);
        return result;
    }

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("path")] = target;
    result[QStringLiteral("message")] = QStringLiteral("已导出报告：%1").arg(target);
    audit_log::record(QStringLiteral("导出采集报告 PDF：%1 → %2").arg(no, target));
    return result;
}
