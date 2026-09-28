#ifndef EEGMONTAGE_H
#define EEGMONTAGE_H

#include <QString>
#include <QStringList>
#include <QVector>

// 采集设备的 16 导联蒙太奇。
//
// 串口上来的只有 CH1..CH16，没有电极名可对，所以「第几路是哪个电极」这件事
// 完全由这张表决定。它同时供三处使用：波形面板的通道名与配色、算法侧的
// ChannelLayout.positions（地形图插值要求至少 3 个电极带二维坐标）、
// 以及地形图的「峰值电极」显示。三处必须同源，各写一份迟早对不上。
//
// 坐标是**相对头半径的百分比**：x 向右为正，y 向下为正（鼻尖在 -y 方向）。
// 算法侧会先按最大绝对值归一化到 [-1,1] 再插值，所以这里的量纲是任意的，
// 只要是同一套比例即可。当前顺序是经典 16 导联（含 T3/T4/T5/T6），
// 它覆盖了枕区 O1/O2 —— 枕区 α 优势恰恰是这张地形图最该看的东西，
// 换成把 T5/T6/O1/O2 排到最后的顺序会让枕区缺位。
namespace eeg_montage
{

struct Electrode
{
    const char *name;
    double x;
    double y;
};

// 16 个电极，顺序即通道序号（下标 0 对应 CH1）。
inline constexpr int kChannelCount = 16;

inline const Electrode *electrodes()
{
    static const Electrode table[kChannelCount] = {
        {"Fp1", -58, -78}, {"Fp2", 58, -78}, {"F7", -88, -46}, {"F3", -42, -40},
        {"F4", 42, -40},   {"F8", 88, -46},  {"T3", -95, 0},   {"C3", -42, 0},
        {"C4", 42, 0},     {"T4", 95, 0},    {"T5", -88, 46},  {"P3", -42, 40},
        {"P4", 42, 40},    {"T6", 88, 46},   {"O1", -34, 78},  {"O2", 34, 78},
    };
    return table;
}

// 通道序号 → 电极名。越界时返回 CH<n> 形式的兜底名，绝不返回空串：
// 空串会让界面上出现一片没有标签的空白通道，比一个不好看但明确的名字更糟。
inline QString channel_name(int channel)
{
    if (channel < 0 || channel >= kChannelCount)
    {
        return QStringLiteral("CH%1").arg(channel + 1);
    }
    return QString::fromLatin1(electrodes()[channel].name);
}

inline QStringList channel_names()
{
    QStringList names;
    names.reserve(kChannelCount);
    for (int i = 0; i < kChannelCount; ++i)
    {
        names.append(channel_name(i));
    }
    return names;
}

// 通道档位（4/8/16）→ 显示哪几路。
//
// 设备永远是 16 路，档位只决定界面画几条泳道。**不能简单取前 N 路**：
// 取前 8 路会得到 Fp1 Fp2 F7 F3 F4 F8 T3 C3，而设计稿的 8 通道写的是
// Fp1 Fp2 F3 F4 C3 C4 P3 P4 —— 要挑出来才对得上。
// 4 档同理，取 Fp1 Fp2 C3 C4 四个有代表性的位置
inline QVector<int> display_channel_indices(int channel_count)
{
    switch (channel_count)
    {
    case 4:
        return {0, 1, 7, 8};                                    // Fp1 Fp2 C3 C4
    case 8:
        return {0, 1, 3, 4, 7, 8, 11, 12};                      // Fp1 Fp2 F3 F4 C3 C4 P3 P4
    default:
        break;
    }

    QVector<int> all;
    all.reserve(kChannelCount);
    for (int i = 0; i < kChannelCount; ++i)
    {
        all.append(i);
    }
    return all;
}

// 额区电极（用于「枕/额比」）。按名字判断而不是按下标 —— 下标会随蒙太奇顺序变，
// 名字不会。
inline bool is_frontal(const QString &name)
{
    return name == QLatin1String("Fp1") || name == QLatin1String("Fp2")
           || name == QLatin1String("F3") || name == QLatin1String("F4")
           || name == QLatin1String("F7") || name == QLatin1String("F8");
}

// 枕区电极（含后颞 T5/T6，参考实现也是这么分的）。
inline bool is_occipital(const QString &name)
{
    return name == QLatin1String("O1") || name == QLatin1String("O2")
           || name == QLatin1String("T5") || name == QLatin1String("T6")
           || name == QLatin1String("P3") || name == QLatin1String("P4");
}

} // namespace eeg_montage

#endif // EEGMONTAGE_H
