#ifndef TOPOGRAPHYPALETTE_H
#define TOPOGRAPHYPALETTE_H

#include <QColor>
#include <QRgb>
#include <QStringList>
#include <QVector>

#include <algorithm>

// 地形图配色。**共用一份**：实时地形图（acquisitionbridge.cpp）与后处理地形图
//（postprocess.cpp）都从这里取色，QML 的色标条也读同一份（Acq.topoPalette）。
//
// 抽出来是因为色标是「按图读值」的唯一依据：两处各抄一份色值，改了一处忘了另一处，
// 色标和热力图就对不上了 —— 那种偏差没有任何报错，只是读数悄悄偏了。
namespace topography_palette
{

// 七个等距停靠点：深蓝 → 蓝 → 青 → 绿 → 黄 → 橙 → 红
inline const QStringList &stops()
{
    static const QStringList palette = {
        QStringLiteral("#173778"), QStringLiteral("#1b6ca8"), QStringLiteral("#2fb4a8"),
        QStringLiteral("#7ec850"), QStringLiteral("#f2d024"), QStringLiteral("#f28c28"),
        QStringLiteral("#cd2d2d"),
    };
    return palette;
}

// 把 7 个停靠点插值展开成 256 项查表，只建一次。
//
// 为什么不在逐像素时现算：一帧 256×256 就是 6.5 万次调用、每次两次
// QColor(QString)（要从十六进制字符串解析颜色），合计十余万次字符串解析
inline const QVector<QRgb> &lut()
{
    static const QVector<QRgb> table = []() {
        const QStringList &palette = stops();
        const int last = palette.size() - 1;

        QVector<QRgb> result(256);
        for (int i = 0; i < result.size(); ++i)
        {
            const double scaled = static_cast<double>(i) / 255.0 * last;
            const int low = std::min(static_cast<int>(scaled), last - 1);
            const double fraction = scaled - low;

            const QColor low_color(palette.at(low));
            const QColor high_color(palette.at(low + 1));
            result[i] = qRgb(
                static_cast<int>(low_color.red()
                                 + (high_color.red() - low_color.red()) * fraction),
                static_cast<int>(low_color.green()
                                 + (high_color.green() - low_color.green()) * fraction),
                static_cast<int>(low_color.blue()
                                 + (high_color.blue() - low_color.blue()) * fraction));
        }
        return result;
    }();
    return table;
}

// 0~1 的归一化值 → 颜色
inline QRgb color(double normalized)
{
    const int index = static_cast<int>(std::clamp(normalized, 0.0, 1.0) * 255.0 + 0.5);
    return lut().at(std::clamp(index, 0, 255));
}

} // namespace topography_palette

#endif // TOPOGRAPHYPALETTE_H
