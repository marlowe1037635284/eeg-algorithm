#include "postprocess.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetrics>
#include <QPainter>
#include <QPainterPath>
#include <QSaveFile>
#include <QTextStream>
#include <QTimer>
#include <QtConcurrent/QtConcurrentRun>
#include <QtMath>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

#include "eegbinformat.h"
#include "eegmontage.h"
#include "topographypalette.h"

namespace
{

// ==================== 字节读取 ====================
// .eegbin 是小端裸格式，用 QDataStream 反而要配 setByteOrder 且对 float32
// 没有直接支持；这里按偏移手工取，与 recordingpreview.cpp 同一套

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

// ==================== 频段定义 ====================
//
// 五档边界与算法侧 band_from_name（acquisitionbridge.cpp）以及地形图面板的
// 频段选择块完全一致。三处各写一套边界的话，界面上选 α、图却按 8-12 Hz 算，
// 是没有任何报错的那类错

struct BandDef
{
    const char *key;
    const char *letter;
    const char *name;
    double low_hz;
    double high_hz;
    const char *color;
};

const BandDef kBands[5] = {
    {"delta", "δ", "Delta", 0.5, 4.0, "#1f4e79"},
    {"theta", "θ", "Theta", 4.0, 8.0, "#4a90c2"},
    {"alpha", "α", "Alpha", 8.0, 13.0, "#7ec850"},
    {"beta", "β", "Beta", 13.0, 30.0, "#f2a03d"},
    {"gamma", "γ", "Gamma", 30.0, 45.0, "#f2d024"},
};

constexpr int kBandCount = 5;
// 「全频段」那张地形图的范围。上界取 45 Hz（γ 的上界），不再往上：
// 49 Hz 低通之后 45 以上基本只剩噪声
constexpr double kFullBandLowHz = 0.5;
constexpr double kFullBandHighHz = 45.0;

// 地形图网格。与接口文档里 OfflineTopographyQuery 的默认值一致
constexpr int kTopoGrid = 64;
// 地形图出图边长（像素）。贴到界面上会缩，取大一点免得放大发虚
constexpr int kTopoImageSize = 256;

// 一次 Welch 最多平均多少段。上限不是精度需要，是耗时需要（见 welch_psd）
constexpr int kMaxPsdSegments = 64;

// ==================== 双二阶与滤波器设计 ====================

struct Biquad
{
    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a1 = 0.0;
    double a2 = 0.0;
};

// 4 阶 Butterworth 的两个二阶节对应的 Q 值（极点对）。N=4 时就是这两个数，
// 与 scipy.signal.butter(order=4, output='sos') 给出的一致
constexpr double kButterQ[2] = {1.306562964876377, 0.541196100146197};

// 双线性变换（预畸变已含在 tan() 里）下的二阶节。
// 低通与高通共用 a1/a2，只有分子不同 —— 这正是 Butterworth 归一化原型
// 经双线性变换后的标准结果
void butter_section(double k, double q, bool high_pass, Biquad *out)
{
    const double norm = 1.0 / (1.0 + k / q + k * k);
    out->a1 = 2.0 * (k * k - 1.0) * norm;
    out->a2 = (1.0 - k / q + k * k) * norm;
    if (high_pass)
    {
        out->b0 = norm;
        out->b1 = -2.0 * norm;
        out->b2 = norm;
    }
    else
    {
        out->b0 = k * k * norm;
        out->b1 = 2.0 * out->b0;
        out->b2 = out->b0;
    }
}

QVector<Biquad> butter_sos(double cutoff_hz, double sample_rate, bool high_pass)
{
    const double k = std::tan(M_PI * cutoff_hz / sample_rate);
    QVector<Biquad> sos;
    sos.reserve(2);
    for (const double q : kButterQ)
    {
        Biquad section;
        butter_section(k, q, high_pass, &section);
        sos.append(section);
    }
    return sos;
}

// 陷波：RBJ 双二阶，带宽由 Q 定（Q 越大越窄）。
//
// 取 Q=12.5，即 50 Hz 处 4 Hz 带宽（48~52 Hz）—— 与在线滤波那套
// notch_low_hz=48 / notch_high_hz=52 是同一个口径。窄到 2.5 Hz 的话，
// 工频稍微漂一点（实测有 49.8 Hz 的）就落在陷波带外，谱上照样留一根峰
Biquad notch_biquad(double center_hz, double sample_rate, double q)
{
    const double w0 = 2.0 * M_PI * center_hz / sample_rate;
    const double alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;

    Biquad section;
    section.b0 = 1.0 / a0;
    section.b1 = -2.0 * std::cos(w0) / a0;
    section.b2 = 1.0 / a0;
    section.a1 = -2.0 * std::cos(w0) / a0;
    section.a2 = (1.0 - alpha) / a0;
    return section;
}

// 直接 II 型转置，逐节串起来作用于**整个**缓冲区。
// 每一节的状态在整段上连续（不是每块清零）—— 清零会让块边界出现台阶
void filter_forward(QVector<double> &x, const QVector<Biquad> &sos)
{
    for (const Biquad &section : sos)
    {
        double z1 = 0.0;
        double z2 = 0.0;
        for (double &value : x)
        {
            const double input = value;
            const double output = section.b0 * input + z1;
            z1 = section.b1 * input - section.a1 * output + z2;
            z2 = section.b2 * input - section.a2 * output;
            value = output;
        }
    }
}

// 零相位滤波（正向 + 反向正向），与 Python 侧 scipy.signal.sosfiltfilt 同理。
//
// 边界按**奇对称延拓**补一段再接回来。这不是可选项：本项目默认的高通是 0.1 Hz，
// 时间常数几秒，不延拓的话滤波器从零状态启动，头十几秒会拖出一条缓慢漂移的
// 基线 —— 而默认分析片段恰好就是开头那 10 秒，等于把最脏的一段留给用户
void zero_phase_filter(QVector<double> &x, const QVector<Biquad> &sos, double sample_rate)
{
    const int n = x.size();
    if (n < 4)
        return;

    // 3 秒延拓（或数据长度的一半，取小）。比 scipy 的默认 3×阶数 保守得多，
    // 正是为了啃下 0.1 Hz 那条长尾巴
    const int pad = std::min(n / 2, std::max(8, static_cast<int>(std::lround(3.0 * sample_rate))));
    const int total = n + 2 * pad;

    QVector<double> buffer(total);
    // 奇数延拓：左端 = 2*x[0] - x[pad..1]，右端同理。这样接缝处值连续、
    // 一阶差分也连续，滤波器的启动瞬变被推到接缝以外
    for (int i = 0; i < pad; ++i)
        buffer[i] = 2.0 * x.first() - x[pad - i];
    std::copy(x.begin(), x.end(), buffer.begin() + pad);
    for (int i = 0; i < pad; ++i)
        buffer[pad + n + i] = 2.0 * x.last() - x[n - 2 - i];

    filter_forward(buffer, sos);
    std::reverse(buffer.begin(), buffer.end());
    filter_forward(buffer, sos);
    std::reverse(buffer.begin(), buffer.end());

    std::copy(buffer.begin() + pad, buffer.begin() + pad + n, x.begin());
}

// ==================== Welch 功率谱 ====================

// 原地基 2 FFT。点数固定为 2 的幂（512/1024），没必要引 FFTW 那种依赖
void fft_in_place(QVector<double> &re, QVector<double> &im)
{
    const int n = re.size();
    if (n < 2)
        return;

    // 位反转置换
    for (int i = 1, j = 0; i < n; ++i)
    {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j)
        {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }

    for (int len = 2; len <= n; len <<= 1)
    {
        const double angle = -2.0 * M_PI / len;
        const double w_re = std::cos(angle);
        const double w_im = std::sin(angle);
        for (int i = 0; i < n; i += len)
        {
            double cur_re = 1.0;
            double cur_im = 0.0;
            for (int k = 0; k < len / 2; ++k)
            {
                const int a = i + k;
                const int b = a + len / 2;
                const double t_re = re[b] * cur_re - im[b] * cur_im;
                const double t_im = re[b] * cur_im + im[b] * cur_re;
                re[b] = re[a] - t_re;
                im[b] = im[a] - t_im;
                re[a] += t_re;
                im[a] += t_im;

                const double next_re = cur_re * w_re - cur_im * w_im;
                cur_im = cur_re * w_im + cur_im * w_re;
                cur_re = next_re;
            }
        }
    }
}

struct Psd
{
    QVector<double> frequencies;
    QVector<double> values;   // µV²/Hz
};

// Welch 平均周期图。口径取齐算法侧 spectrum_core.welch_psd：
// nperseg = min(N, round(fs*2))、50% 重叠、逐段去均值、Hann 窗、密度谱
Psd welch_psd(const double *signal, int n, double sample_rate)
{
    Psd result;
    if (n < 4 || sample_rate <= 0.0)
        return result;

    // 段长取「2 秒」再**向下取到 2 的幂**。
    //
    // 这一步不是可有可无的优化：下面的 FFT 是基 2 的，位反转置换只在点数为
    // 2 的幂时成立。1000 Hz 的记录算出来是 2000 点，位反转会把下标推到
    // 数组之外（Debug 下直接断言崩掉，Release 下是越界写）。256 Hz 的记录
    // 恰好得到 512，所以这个坑只在千赫兹采样率上现形
    int nperseg = std::min(n, std::max(4, static_cast<int>(std::lround(sample_rate * 2.0))));
    int power_of_two = 1;
    while (power_of_two * 2 <= nperseg)
        power_of_two *= 2;
    nperseg = std::max(4, power_of_two);

    const int step = std::max(1, nperseg / 2);
    const int bins = nperseg / 2 + 1;

    QVector<double> window(nperseg);
    double window_energy = 0.0;
    for (int i = 0; i < nperseg; ++i)
    {
        window[i] = 0.5 - 0.5 * std::cos(2.0 * M_PI * i / (nperseg - 1));
        window_energy += window[i] * window[i];
    }
    if (window_energy <= 0.0)
        return result;

    QVector<double> accumulated(bins, 0.0);
    int segments = 0;

    // 最多平均 kMaxSegments 段，超了就**等间隔抽样**。
    // 一条十分钟、1 kHz 的记录整段做 Welch 是近两万次 1024 点 FFT，
    // 而功率谱的方差按段数收敛得很快：60 段与 500 段在图上已经看不出差别，
    // 代价却差一个数量级。抽样的步长按「可用段数 / 上限」取，整段铺开不偏头
    const int available = (n - nperseg) / step + 1;
    const int stride = available > kMaxPsdSegments
                           ? (available + kMaxPsdSegments - 1) / kMaxPsdSegments : 1;

    for (int index = 0; index < available; index += stride)
    {
        const int start = index * step;
        double mean = 0.0;
        for (int i = 0; i < nperseg; ++i)
            mean += signal[start + i];
        mean /= nperseg;

        QVector<double> re(nperseg, 0.0);
        QVector<double> im(nperseg, 0.0);
        for (int i = 0; i < nperseg; ++i)
            re[i] = (signal[start + i] - mean) * window[i];

        fft_in_place(re, im);

        for (int k = 0; k < bins; ++k)
            accumulated[k] += re[k] * re[k] + im[k] * im[k];
        ++segments;
    }

    if (segments == 0)
        return result;

    result.frequencies.resize(bins);
    result.values.resize(bins);
    for (int k = 0; k < bins; ++k)
    {
        const bool edge = (k == 0) || (k == bins - 1);
        const double one_sided = edge ? 1.0 : 2.0;
        result.frequencies[k] = sample_rate * k / nperseg;
        result.values[k] = one_sided * (accumulated[k] / segments)
                           / (sample_rate * window_energy);
    }
    return result;
}

// 频段平均功率谱密度（µV²/Hz）。用**均值**而不是积分：设计稿色标写的就是
// µV²/Hz，均值与色标是同一个量纲，报告里的占比则用积分算（见 band_power）
double band_mean_psd(const Psd &psd, double low_hz, double high_hz)
{
    double sum = 0.0;
    int count = 0;
    for (int i = 0; i < psd.frequencies.size(); ++i)
    {
        const double f = psd.frequencies.at(i);
        if (f >= low_hz && f <= high_hz)
        {
            sum += psd.values.at(i);
            ++count;
        }
    }
    return count > 0 ? sum / count : 0.0;
}

// 频段绝对功率（µV²）：对功率谱密度积分
double band_power(const Psd &psd, double low_hz, double high_hz)
{
    double total = 0.0;
    for (int i = 1; i < psd.frequencies.size(); ++i)
    {
        const double f0 = psd.frequencies.at(i - 1);
        const double f1 = psd.frequencies.at(i);
        const double mid = 0.5 * (f0 + f1);
        if (mid < low_hz || mid > high_hz)
            continue;
        total += 0.5 * (psd.values.at(i - 1) + psd.values.at(i)) * (f1 - f0);
    }
    return total;
}

// ==================== 逐通道统计 ====================

struct ChannelStat
{
    double mean = 0.0;
    double std_dev = 0.0;
    double rms = 0.0;
    double peak = 0.0;
    double minimum = 0.0;
    double maximum = 0.0;
    double zero_cross = 0.0;   // 每秒
    double skewness = 0.0;
    double kurtosis = 0.0;
};

ChannelStat compute_stat(const double *signal, int n, double sample_rate)
{
    ChannelStat stat;
    if (n <= 1 || sample_rate <= 0.0)
        return stat;

    double sum = 0.0;
    for (int i = 0; i < n; ++i)
        sum += signal[i];
    stat.mean = sum / n;

    double m2 = 0.0;
    double m3 = 0.0;
    double m4 = 0.0;
    double square = 0.0;
    double lowest = std::numeric_limits<double>::max();
    double highest = std::numeric_limits<double>::lowest();
    double peak = 0.0;
    int crossings = 0;
    for (int i = 0; i < n; ++i)
    {
        const double centred = signal[i] - stat.mean;
        const double square_value = centred * centred;
        m2 += square_value;
        m3 += square_value * centred;
        m4 += square_value * square_value;
        square += signal[i] * signal[i];
        lowest = std::min(lowest, signal[i]);
        highest = std::max(highest, signal[i]);
        peak = std::max(peak, std::abs(signal[i]));
        if (i > 0 && ((signal[i - 1] < 0.0) != (signal[i] < 0.0)))
            ++crossings;
    }

    m2 /= n;
    m3 /= n;
    m4 /= n;
    const double variance = std::max(m2, 0.0);
    const double deviation = std::sqrt(variance);

    stat.std_dev = deviation;
    stat.rms = std::sqrt(square / n);
    stat.peak = peak;
    stat.minimum = lowest;
    stat.maximum = highest;
    stat.zero_cross = crossings / (static_cast<double>(n) / sample_rate);
    // 标准差为 0 时偏度/峰度没有定义，直接给 0 —— 返回 nan 会在界面上显示成 "nan"
    stat.skewness = deviation > 1e-12 ? m3 / (variance * deviation) : 0.0;
    stat.kurtosis = deviation > 1e-12 ? m4 / (variance * variance) - 3.0 : 0.0;
    return stat;
}

// ==================== 地形图 ====================

// 电极坐标：与算法侧一样先减去质心、再按最大半径归一化到 [-1,1]。
// 不归一化的话，蒙太奇坐标（百分比）与网格坐标（±1）差了 80 多倍，
// 插值出来的图会是一整片同色
void normalize_positions(QVector<QPointF> *xy)
{
    if (xy->isEmpty())
        return;

    QPointF centre;
    for (const QPointF &point : *xy)
        centre += point;
    centre /= xy->size();

    double radius = 0.0;
    for (QPointF &point : *xy)
    {
        point -= centre;
        radius = std::max(radius, std::hypot(point.x(), point.y()));
    }
    if (radius <= 0.0)
        return;
    for (QPointF &point : *xy)
        point /= radius;
}

// 反距离加权插值（Shepard，2 次幂）。
//
// 算法侧用的是 scipy 的三次样条（griddata(method='cubic')），本页取反距离加权：
// 三次样条在电极稀疏处会外插出上下冲，十六个电极的蒙太奇上偶有刺眼的假极值；
// 反距离加权是加权平均，天然被电极值域夹住，不会出现「比最大电极还红」的点
void interpolate_topography(const QVector<QPointF> &xy, const QVector<double> &values,
                            int grid, QVector<float> *grid_values)
{
    grid_values->resize(grid * grid);

    const auto sample = [&](double nx, double ny) {
        double weight_sum = 0.0;
        double value_sum = 0.0;
        double nearest = 0.0;
        double nearest_distance = std::numeric_limits<double>::max();
        for (int i = 0; i < xy.size(); ++i)
        {
            const double dx = nx - xy.at(i).x();
            const double dy = ny - xy.at(i).y();
            const double distance_squared = dx * dx + dy * dy;
            if (distance_squared < nearest_distance)
            {
                nearest_distance = distance_squared;
                nearest = values.at(i);
            }
            // 落到电极上时权重会发散，用一个下限兜住（归一化坐标下 1e-6 已足够小）
            const double weight = 1.0 / std::max(distance_squared, 1e-6);
            weight_sum += weight;
            value_sum += weight * values.at(i);
        }
        return weight_sum > 0.0 ? value_sum / weight_sum : nearest;
    };

    for (int gy = 0; gy < grid; ++gy)
    {
        const double ny = static_cast<double>(gy) / (grid - 1) * 2.0 - 1.0;
        for (int gx = 0; gx < grid; ++gx)
        {
            const double nx = static_cast<double>(gx) / (grid - 1) * 2.0 - 1.0;
            (*grid_values)[gy * grid + gx] = static_cast<float>(sample(nx, ny));
        }
    }
}

// 网格 → 一张方形图。掩膜（单位圆）之外画**透明**：不透明的话热力图会是一个
// 方块，盖掉 QML 那边叠的头型底图
QImage render_topography_image(const QVector<float> &grid_values, int grid, double scale_max)
{
    QImage image(kTopoImageSize, kTopoImageSize, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    if (grid <= 1 || grid_values.size() < grid * grid)
        return image;

    const double safe_max = scale_max > 0.0 ? scale_max : 1.0;
    const double half = (kTopoImageSize - 1) / 2.0;

    for (int y = 0; y < kTopoImageSize; ++y)
    {
        const double ny = (y - half) / half;
        QRgb *line = reinterpret_cast<QRgb *>(image.scanLine(y));
        for (int x = 0; x < kTopoImageSize; ++x)
        {
            const double nx = (x - half) / half;
            if (nx * nx + ny * ny > 1.0)
                continue;   // 头外

            const int gy = std::clamp(
                static_cast<int>(std::lround((ny + 1.0) / 2.0 * (grid - 1))), 0, grid - 1);
            const int gx = std::clamp(
                static_cast<int>(std::lround((nx + 1.0) / 2.0 * (grid - 1))), 0, grid - 1);
            line[x] = topography_palette::color(grid_values.at(gy * grid + gx) / safe_max);
        }
    }
    return image;
}

// 色标上限取一个「好看」的整数档：图按它归一化配色，QML 色标条右端显示同一个数，
// 显示 37.4 这种原值既不好读，也没必要精确到小数点后
double nice_scale_max(double value)
{
    if (!(value > 0.0))
        return 1.0;
    const double exponent = std::pow(10.0, std::floor(std::log10(value)));
    const double normalized = value / exponent;
    double step = 10.0;
    if (normalized <= 1.0)
        step = 1.0;
    else if (normalized <= 2.0)
        step = 2.0;
    else if (normalized <= 5.0)
        step = 5.0;
    return step * exponent;
}

} // namespace

// ==================== 出图 ====================

namespace
{

// 波形图。宽度是**绘制区**宽度（不含左边的通道名列），高度 = 通道数 × 泳道高，
// 所以整张图比视口高，由 QML 那边滚动着看 —— 这样滚动不必重算一遍分析
QImage render_wave_image(const QVector<QVector<double>> &data, double sample_rate,
                         double window_start, double window_seconds, int current_channel,
                         double range_uv, int width, const QVariantList &events)
{
    const int channels = data.size();
    const int height = channels * PostProcess::lane_height();
    QImage image(std::max(2, width), std::max(2, height), QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    if (channels <= 0 || width < 2)
        return image;

    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing, true);

    const double first_sample = std::floor(window_start * sample_rate);
    const double last_sample = first_sample + window_seconds * sample_rate;
    const double span = std::max(1.0, last_sample - first_sample);

    // 泳道居中线
    painter.setPen(QPen(QColor(0, 0, 0, 26), 1.0));
    for (int i = 0; i < channels; ++i)
    {
        const double centre = i * PostProcess::lane_height() + PostProcess::lane_height() / 2.0;
        painter.drawLine(QPointF(0.0, centre), QPointF(width, centre));
    }

    // 事件竖线（画在波形之下）。与预览弹窗同一套：划出窗口的事件跟着消失，
    // 不钉在窗口边上
    for (const QVariant &item : events)
    {
        const QVariantMap event = item.toMap();
        const double offset = event.value(QStringLiteral("offsetSeconds")).toDouble();
        if (offset < window_start || offset > window_start + window_seconds)
            continue;
        const double x = (offset - window_start) / window_seconds * width;
        QColor color(event.value(QStringLiteral("color")).toString());
        if (!color.isValid())
            color = QColor(QStringLiteral("#7c3aed"));
        color.setAlpha(150);
        QPen pen(color, 1.0, Qt::DashLine);
        painter.setPen(pen);
        painter.drawLine(QPointF(x, 0.0), QPointF(x, height));
    }

    painter.setRenderHint(QPainter::Antialiasing, false);

    const double half_lane = PostProcess::lane_height() * 0.5;
    const double scale = half_lane / std::max(1.0, range_uv);

    for (int channel = 0; channel < channels; ++channel)
    {
        const QVector<double> &row = data.at(channel);
        if (row.isEmpty())
            continue;

        const double centre = channel * PostProcess::lane_height() + half_lane;
        const bool active = channel == current_channel;
        // 当前导联用它的配色，其余压成灰 —— 设计稿图例写的就是「当前通道 / 其余通道」
        QColor color = active ? QColor(eeg_montage::channel_colors().value(channel))
                              : QColor(150, 158, 168);

        QPolygonF polyline;
        polyline.reserve(std::max(2, width) * 2);
        const int samples = static_cast<int>(row.size());
        for (int x = 0; x < width; ++x)
        {
            const int from = static_cast<int>(first_sample + span * x / width);
            const int to = static_cast<int>(first_sample + span * (x + 1) / width);
            if (from >= samples)
                break;

            // 一个像素列对应多个采样点时取这一列的最小/最大，画成一条竖线 ——
            // 只取一个点的话，高频成分会被抽稀成一堆假峰
            double lowest = row.at(std::clamp(from, 0, samples - 1));
            double highest = lowest;
            const int stop = std::min(std::max(to, from + 1), samples);
            for (int i = std::max(0, from); i < stop; ++i)
            {
                lowest = std::min(lowest, row.at(i));
                highest = std::max(highest, row.at(i));
            }

            const double y_low = centre - std::clamp(lowest * scale, -half_lane, half_lane);
            const double y_high = centre - std::clamp(highest * scale, -half_lane, half_lane);
            polyline.append(QPointF(x, y_low));
            polyline.append(QPointF(x, y_high));
        }

        painter.setPen(QPen(color, active ? 1.4 : 1.0));
        painter.drawPolyline(polyline);
    }

    // 事件顶端的小圆点
    painter.setRenderHint(QPainter::Antialiasing, true);
    for (const QVariant &item : events)
    {
        const QVariantMap event = item.toMap();
        const double offset = event.value(QStringLiteral("offsetSeconds")).toDouble();
        if (offset < window_start || offset > window_start + window_seconds)
            continue;
        const double x = (offset - window_start) / window_seconds * width;
        QColor color(event.value(QStringLiteral("color")).toString());
        if (!color.isValid())
            color = QColor(QStringLiteral("#7c3aed"));
        painter.setPen(Qt::NoPen);
        painter.setBrush(color);
        painter.drawEllipse(QPointF(x, 5.0), 4.0, 4.0);
    }

    return image;
}

// 频谱图。背景按 δ/θ/α/β/γ 铺一层浅色带 —— 有底色才能一眼看出曲线在哪一段，
// 也才和设计稿一致
QImage render_spectrum_image(const Psd &psd, double f_min, double f_max,
                             double db_min, double db_max, int width, int height)
{
    QImage image(std::max(2, width), std::max(2, height), QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    if (width < 4 || height < 4 || psd.frequencies.size() < 2)
        return image;

    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing, true);

    const double f_span = std::max(1e-6, f_max - f_min);
    const double db_span = std::max(1e-6, db_max - db_min);

    const auto to_x = [&](double hz) { return (hz - f_min) / f_span * width; };
    const auto to_y = [&](double db) { return (db_max - db) / db_span * height; };

    // 频带底色。δ 与 θ 偏冷、β 与 γ 偏暖，与统计页那根图例是同一套颜色
    for (int i = 0; i < kBandCount; ++i)
    {
        const double low = std::max(kBands[i].low_hz, f_min);
        const double high = std::min(kBands[i].high_hz, f_max);
        if (high <= low)
            continue;
        QColor tint(kBands[i].color);
        tint.setAlpha(38);
        painter.fillRect(QRectF(to_x(low), 0.0, to_x(high) - to_x(low), height), tint);
    }

    // 曲线。dB 下限以下夹到边界上（画到图外会变成一条穿出画布的斜线）
    QPolygonF curve;
    for (int i = 0; i < psd.frequencies.size(); ++i)
    {
        const double hz = psd.frequencies.at(i);
        if (hz < f_min || hz > f_max)
            continue;
        const double value = psd.values.at(i);
        const double db = value > 0.0 ? 10.0 * std::log10(value) : db_min;
        curve.append(QPointF(to_x(hz), std::clamp(to_y(db), 0.0, static_cast<double>(height))));
    }

    if (curve.size() >= 2)
    {
        painter.setPen(QPen(QColor(0x70, 0x92, 0xab), 1.6));
        painter.drawPolyline(curve);
    }

    return image;
}

// 通道相关性矩阵。正相关偏红、负相关偏绿（与设计稿一致），
// 复用地形图那套「白底 → 饱和色」的插值思路，只是换成发散色标
QImage render_correlation_image(const QVector<QVector<double>> &matrix, int size)
{
    const int count = matrix.size();
    QImage image(std::max(2, size), std::max(2, size), QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    if (count <= 0)
        return image;

    const double cell = static_cast<double>(size) / count;
    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing, false);

    const QColor base(0xf0, 0xf0, 0xf0);
    const QColor positive(0xd0, 0x51, 0x5c);
    const QColor negative(0x4a, 0x9d, 0x7f);

    for (int row = 0; row < count; ++row)
    {
        const int y0 = static_cast<int>(std::lround(row * cell));
        const int y1 = static_cast<int>(std::lround((row + 1) * cell));
        for (int column = 0; column < count; ++column)
        {
            const int x0 = static_cast<int>(std::lround(column * cell));
            const int x1 = static_cast<int>(std::lround((column + 1) * cell));

            const double value = std::clamp(matrix.at(row).at(column), -1.0, 1.0);
            const QColor target = value >= 0.0 ? positive : negative;
            const double weight = std::abs(value);
            const QColor color(
                static_cast<int>(base.red() + (target.red() - base.red()) * weight),
                static_cast<int>(base.green() + (target.green() - base.green()) * weight),
                static_cast<int>(base.blue() + (target.blue() - base.blue()) * weight));

            painter.fillRect(QRect(x0, y0, x1 - x0, y1 - y0), color);
        }
    }
    return image;
}

} // namespace

// ==================== PostProcess ====================

PostProcess::PostProcess(QObject *parent)
    : QObject(parent)
{
    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(180);
    QObject::connect(m_debounce, &QTimer::timeout, this, &PostProcess::run_recompute);

    QObject::connect(&m_watcher, &QFutureWatcher<Result>::finished,
                     this, &PostProcess::on_recompute_finished);

    m_view_size = QSize(1200, 600);
}

PostProcess::~PostProcess()
{
    // 工作线程可能还在跑。它只读 m_raw（shared_ptr），本对象析构后它仍安全 ——
    // 但 m_watcher 的回调会打到已析构的 this 上，所以必须等它回来。
    // waitForFinished 阻塞 GUI 线程最多一次分析的时间（Release 下几十毫秒）
    m_watcher.waitForFinished();
}

// ---------- 记录 ----------

bool PostProcess::open(const QString &record_no, const QString &file_path,
                       const QVariantMap &info)
{
    close();

    m_record_no = record_no;
    m_info = info;
    m_file_path = file_path;

    auto raw = std::make_shared<RawData>();

    QFile file(file_path);
    if (file_path.trimmed().isEmpty() || !file.exists())
    {
        m_error_text = tr("这条记录没有落盘的原始数据文件");
        emit recordChanged();
        return false;
    }
    if (!file.open(QIODevice::ReadOnly))
    {
        m_error_text = tr("无法打开记录文件：%1").arg(file.errorString());
        emit recordChanged();
        return false;
    }

    const qint64 size = file.size();
    if (size <= eegbin::kHeaderSize)
    {
        m_error_text = tr("记录文件为空");
        emit recordChanged();
        return false;
    }

    const QByteArray blob = file.readAll();
    file.close();
    const uchar *map = reinterpret_cast<const uchar *>(blob.constData());

    if (std::memcmp(map, eegbin::kMagic, sizeof(eegbin::kMagic)) != 0
        || read_u32_le(map + eegbin::kVersionOffset) != eegbin::kVersion
        || read_u32_le(map + eegbin::kHeaderSizeOffset) != eegbin::kHeaderSize)
    {
        m_error_text = tr("记录文件格式无法识别");
        emit recordChanged();
        return false;
    }

    raw->channels = static_cast<int>(read_u32_le(map + eegbin::kChannelsOffset));
    raw->sample_rate = static_cast<int>(read_u32_le(map + eegbin::kSampleRateOffset));
    raw->start_utc_ms = read_i64_le(map + eegbin::kStartTimeOffset);

    if (raw->channels <= 0 || raw->sample_rate <= 0)
    {
        m_error_text = tr("记录文件头不完整");
        emit recordChanged();
        return false;
    }

    // 帧数按**文件实际长度**算，不信头里那个 frame_count：程序被强杀时
    // 那一栏来不及回填（写头时是 0），而文件里的样本是真的。
    // 与 recordingpreview.cpp 同一口径
    const qint64 payload = size - eegbin::kHeaderSize;
    const qint64 frames = payload / (static_cast<qint64>(raw->channels)
                                     * eegbin::kBytesPerSample);
    if (frames <= 0)
    {
        m_error_text = tr("记录文件里没有样本数据");
        emit recordChanged();
        return false;
    }
    raw->frames = static_cast<int>(frames);
    raw->samples.resize(raw->frames * raw->channels);

    const uchar *samples = map + eegbin::kHeaderSize;
    for (int i = 0; i < raw->samples.size(); ++i)
        raw->samples[i] = read_f32_le(samples + static_cast<qint64>(i) * eegbin::kBytesPerSample);

    m_raw = raw;
    m_channels = raw->channels;
    m_sample_rate = raw->sample_rate;
    m_duration_seconds = static_cast<double>(raw->frames) / raw->sample_rate;
    m_loaded = true;
    m_error_text.clear();

    // 默认窗口 5 秒（与预览弹窗一致），记录更短时取整段
    m_window_seconds = std::min(5.0, std::max(0.5, m_duration_seconds));
    m_window_start = 0.0;
    m_current_channel = 0;

    // 事件随 info 一起进来（页面从库里取好）。**不在这里查库**：本类不持有
    // AppDatabase，也不该知道记录是怎么存的 —— 它只管把一段数据算成一屏图
    m_events = info.value(QStringLiteral("events")).toList();

    // 顶栏副标题：「历史记录R-0001·黎明(P-0001)·16通道@256Hz」，
    // 缺患者名或病历号的那几段自动省掉，不会留下孤零零的括号
    const QString patient = info.value(QStringLiteral("patient")).toString();
    const QString patient_no = info.value(QStringLiteral("patientNo")).toString();
    QString who = patient;
    if (!patient_no.isEmpty())
        who = patient.isEmpty() ? QStringLiteral("(%1)").arg(patient_no)
                                : QStringLiteral("%1(%2)").arg(patient, patient_no);
    m_subtitle = who.isEmpty()
                     ? tr("历史记录 %1·%2通道@%3Hz").arg(record_no).arg(m_channels).arg(m_sample_rate)
                     : tr("历史记录 %1·%2·%3通道@%4Hz")
                           .arg(record_no, who)
                           .arg(m_channels)
                           .arg(m_sample_rate);

    build_record_info();
    emit recordChanged();
    schedule_recompute();
    return true;
}

void PostProcess::close()
{
    m_watcher.waitForFinished();
    m_raw.reset();
    m_loaded = false;
    m_error_text.clear();
    m_record_no.clear();
    m_subtitle.clear();
    m_file_path.clear();
    m_duration_seconds = 0.0;
    m_sample_rate = 0;
    m_channels = 0;
    m_record_info.clear();
    m_events.clear();
    m_info.clear();
    {
        // 与 on_recompute_finished 同一个理由：结果里有 QImage / 容器，
        // 而 image provider 可能在另一个线程上正读着它
        const QMutexLocker locker(&m_mutex);
        m_result = Result();
    }
    ++m_generation;
    emit recordChanged();
    emit resultChanged();
}

void PostProcess::build_record_info()
{
    // 基本信息面板那五行。设计稿里的值是示意，这里全部换成库里那条记录的真实值；
    // 取不到的项显示「—」，不编一个像样的假数
    const auto text = [this](const char *key, const QString &fallback) {
        const QString value = m_info.value(QString::fromLatin1(key)).toString();
        return value.isEmpty() ? fallback : value;
    };

    const QString duration = [this]() {
        const int total = static_cast<int>(std::lround(m_duration_seconds));
        return QStringLiteral("%1:%2:%3")
            .arg(total / 3600, 2, 10, QLatin1Char('0'))
            .arg((total % 3600) / 60, 2, 10, QLatin1Char('0'))
            .arg(total % 60, 2, 10, QLatin1Char('0'));
    }();

    m_record_info = QVariantList{
        QVariantMap{{QStringLiteral("label"), tr("记录 / 患者")},
                    {QStringLiteral("value"),
                     QStringLiteral("%1 · %2").arg(m_record_no, text("patient", QStringLiteral("—")))}},
        QVariantMap{{QStringLiteral("label"), tr("采集时间")}, {QStringLiteral("value"), text("time", QStringLiteral("—"))}},
        QVariantMap{{QStringLiteral("label"), tr("时长 / 通道")},
                    {QStringLiteral("value"),
                     QStringLiteral("%1 · %2 ch").arg(duration).arg(m_channels)}},
        QVariantMap{{QStringLiteral("label"), tr("采样率 / 幅值")},
                    {QStringLiteral("value"),
                     QStringLiteral("%1 Hz · 100 μV").arg(m_sample_rate)}},
        QVariantMap{{QStringLiteral("label"), tr("电极贴合 / 事件")},
                    {QStringLiteral("value"),
                     QStringLiteral("%1 · %2 个")
                         .arg(text("quality", QStringLiteral("—")),
                              text("eventCount", QStringLiteral("0")))}},
    };
}

QStringList PostProcess::reference_choices() const
{
    return {tr("双侧乳突"), tr("平均参考"), tr("不重参考")};
}

QStringList PostProcess::downsample_choices() const
{
    // 按记录**实际采样率**给出整数分频档：能整除才做得到「先抗混叠低通、
    // 再每 M 个取一个」，非整数比要重采样，对后处理没有价值只有风险。
    // 设计稿那张图写死「1000Hz」，而它是 256Hz 的记录 —— 照抄只会给一个
    // 点了就报错的选项
    QStringList choices{tr("原始")};
    if (m_sample_rate <= 0)
        return choices;

    for (int divisor = 2; divisor <= 16; divisor <<= 1)
    {
        if (m_sample_rate % divisor != 0)
            continue;
        const int target = m_sample_rate / divisor;
        if (target < 32)
            break;
        choices.append(QStringLiteral("%1 Hz").arg(target));
    }
    return choices;
}

QStringList PostProcess::segment_choices() const
{
    // 前两项固定，其后是记录里真实出现过的**事件标签**。设计稿写死
    //「睁眼/闭眼/手动标记」，而一条记录里到底标了什么只有库里知道
    QStringList choices{tr("整段记录"), tr("前 10 秒"), tr("前 30 秒")};

    QStringList labels;
    for (const QVariant &item : m_events)
    {
        const QString label = item.toMap().value(QStringLiteral("label")).toString();
        if (!label.isEmpty() && !labels.contains(label))
            labels.append(label);
    }
    choices.append(labels);
    return choices;
}

QStringList PostProcess::channel_names() const
{
    return eeg_montage::channel_names();
}

QStringList PostProcess::channel_colors() const
{
    return eeg_montage::channel_colors();
}

QStringList PostProcess::band_keys()
{
    QStringList keys;
    for (const BandDef &band : kBands)
        keys.append(QString::fromLatin1(band.key));
    return keys;
}

QStringList PostProcess::band_names()
{
    QStringList names;
    for (const BandDef &band : kBands)
        // letter 是希腊字母（δ θ α β γ），**必须 fromUtf8**：源文件里的这几个字节
        // 是 UTF-8 编码的两字节序列，按 Latin-1 解会把它们变成两个西欧字符，
        // 界面上出现的就不是 δ 而是一个没人认识的符号，且不报任何错
        names.append(QString::fromUtf8(band.letter) + QLatin1Char(' ')
                     + QString::fromLatin1(band.name));
    return names;
}

QStringList PostProcess::band_colors()
{
    QStringList colors;
    for (const BandDef &band : kBands)
        colors.append(QString::fromLatin1(band.color));
    return colors;
}

// ---------- 参数 ----------

void PostProcess::invalidate()
{
    emit paramsChanged();
    schedule_recompute();
}

void PostProcess::set_band_pass_enabled(bool value)
{
    if (m_params.band_pass_enabled == value)
        return;
    m_params.band_pass_enabled = value;
    invalidate();
}

void PostProcess::set_high_pass_hz(double value)
{
    // 上限压在低通之下，下限即「直流」。放任非法值进去的话，滤波器设计那一步
    // 会算出一个发散的双二阶，输出整段 nan —— 界面上只表现为「波形没了」
    const double clamped = std::clamp(value, 0.01, std::max(0.02, m_params.low_pass_hz - 0.5));
    if (qFuzzyCompare(m_params.high_pass_hz, clamped))
        return;
    m_params.high_pass_hz = clamped;
    invalidate();
}

void PostProcess::set_low_pass_hz(double value)
{
    const double nyquist = m_sample_rate > 0 ? m_sample_rate / 2.0 : 128.0;
    const double clamped = std::clamp(value, m_params.high_pass_hz + 0.5, nyquist - 1.0);
    if (qFuzzyCompare(m_params.low_pass_hz, clamped))
        return;
    m_params.low_pass_hz = clamped;
    invalidate();
}

void PostProcess::set_notch_enabled(bool value)
{
    if (m_params.notch_enabled == value)
        return;
    m_params.notch_enabled = value;
    invalidate();
}

void PostProcess::set_notch_hz(double value)
{
    const double nyquist = m_sample_rate > 0 ? m_sample_rate / 2.0 : 128.0;
    const double clamped = std::clamp(value, 1.0, nyquist - 1.0);
    if (qFuzzyCompare(m_params.notch_hz, clamped))
        return;
    m_params.notch_hz = clamped;
    invalidate();
}

void PostProcess::set_reference_index(int value)
{
    // 选项表返回的是 QStringList，size() 是 qsizetype；clamp 两边必须同类型
    const int last = static_cast<int>(reference_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.reference_index == clamped)
        return;
    m_params.reference_index = clamped;
    invalidate();
}

void PostProcess::set_downsample_index(int value)
{
    const int last = static_cast<int>(downsample_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.downsample_index == clamped)
        return;
    m_params.downsample_index = clamped;
    invalidate();
}

void PostProcess::set_baseline_enabled(bool value)
{
    if (m_params.baseline_enabled == value)
        return;
    m_params.baseline_enabled = value;
    invalidate();
}

void PostProcess::set_asr_enabled(bool value)
{
    if (m_params.asr_enabled == value)
        return;
    m_params.asr_enabled = value;
    invalidate();
}

void PostProcess::set_asr_cutoff(int value)
{
    const int clamped = std::clamp(value, 5, 100);
    if (m_params.asr_cutoff == clamped)
        return;
    m_params.asr_cutoff = clamped;
    invalidate();
}

void PostProcess::set_segment_index(int value)
{
    const int last = static_cast<int>(segment_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.segment_index == clamped)
        return;
    m_params.segment_index = clamped;
    invalidate();
}

void PostProcess::set_before_seconds(double value)
{
    const double clamped = std::clamp(value, -30.0, 0.0);
    if (qFuzzyCompare(m_params.before_seconds, clamped))
        return;
    m_params.before_seconds = clamped;
    invalidate();
}

void PostProcess::set_after_seconds(double value)
{
    const double clamped = std::clamp(value, 0.0, 60.0);
    if (qFuzzyCompare(m_params.after_seconds, clamped))
        return;
    m_params.after_seconds = clamped;
    invalidate();
}

// ---------- 视图 ----------

void PostProcess::set_current_channel(int value)
{
    const int clamped = std::clamp(value, 0, std::max(0, m_channels - 1));
    if (m_current_channel == clamped)
        return;
    m_current_channel = clamped;
    emit viewChanged();
    schedule_recompute();
}

void PostProcess::set_window_start_seconds(double value)
{
    const double maximum = std::max(0.0, m_duration_seconds - m_window_seconds);
    const double clamped = std::clamp(value, 0.0, maximum);
    if (qFuzzyCompare(m_window_start, clamped))
        return;
    m_window_start = clamped;
    emit viewChanged();
    schedule_recompute();
}

void PostProcess::set_window_seconds(double value)
{
    const double clamped = std::clamp(value, 0.5, std::max(0.5, m_duration_seconds));
    if (qFuzzyCompare(m_window_seconds, clamped))
        return;
    m_window_seconds = clamped;
    if (m_window_start > m_duration_seconds - clamped)
    {
        m_window_start = std::max(0.0, m_duration_seconds - clamped);
        emit viewChanged();
    }
    emit viewChanged();
    schedule_recompute();
}

void PostProcess::set_view_size(int width, int height)
{
    if (width <= 0 || height <= 0)
        return;
    const QSize size(width, height);
    if (size == m_view_size)
        return;
    m_view_size = size;
    schedule_recompute();
}

// ---------- 重算调度 ----------

void PostProcess::schedule_recompute()
{
    if (!m_loaded)
        return;
    // 防抖：拖滑块会连投十几个改动，只算最后一次
    m_debounce->start();
}

void PostProcess::run_recompute()
{
    if (!m_loaded || !m_raw)
        return;

    if (m_watcher.isRunning())
    {
        // 上一轮还没回来。再等一拍 —— 不等的话任务会排队堆起来，
        // 而每一轮都是几百毫秒的全量计算
        m_debounce->start();
        return;
    }

    Job job;
    job.generation = ++m_generation;
    job.band_pass_enabled = m_params.band_pass_enabled;
    job.high_pass_hz = m_params.high_pass_hz;
    job.low_pass_hz = m_params.low_pass_hz;
    job.notch_enabled = m_params.notch_enabled;
    job.notch_hz = m_params.notch_hz;
    job.reference_index = m_params.reference_index;
    job.downsample_index = m_params.downsample_index;
    job.baseline_enabled = m_params.baseline_enabled;
    job.asr_enabled = m_params.asr_enabled;
    job.asr_cutoff = m_params.asr_cutoff;
    job.current_channel = m_current_channel;
    job.window_start = m_window_start;
    job.window_seconds = m_window_seconds;

    // 片段在这里（GUI 线程）就解析成秒：按事件算片段要用到事件时刻，
    // 而事件在库侧，工作线程手上没有
    double start = 0.0;
    double seconds = m_duration_seconds;
    const int index = m_params.segment_index;
    if (index == 1)
        seconds = std::min(10.0, m_duration_seconds);
    else if (index == 2)
        seconds = std::min(30.0, m_duration_seconds);
    else if (index >= 3)
    {
        const QStringList choices = segment_choices();
        const QString label = index < choices.size() ? choices.at(index) : QString();
        for (const QVariant &item : m_events)
        {
            const QVariantMap event = item.toMap();
            if (event.value(QStringLiteral("label")).toString() != label)
                continue;
            const double offset = event.value(QStringLiteral("offsetSeconds")).toDouble();
            start = std::max(0.0, offset + m_params.before_seconds);
            seconds = std::max(0.5, m_params.after_seconds - m_params.before_seconds);
            break;
        }
    }
    if (start + seconds > m_duration_seconds)
        seconds = std::max(0.5, m_duration_seconds - start);
    job.segment_start = start;
    job.segment_seconds = seconds;

    // 波形绘制区宽度：视口宽度减掉左边的通道名列（56）
    job.wave_width = std::max(64, m_view_size.width() - 56);
    job.wave_height = m_view_size.height();
    job.spectrum_width = std::max(64, m_view_size.width());
    job.spectrum_height = std::max(64, m_view_size.height());
    job.events = m_events;
    job.record_info = m_record_info;

    m_busy = true;
    emit busyChanged();
    m_status_text = tr("正在计算…");
    emit resultChanged();

    const std::shared_ptr<const RawData> raw = m_raw;
    m_watcher.setFuture(QtConcurrent::run(&PostProcess::compute, raw, job));
}

void PostProcess::on_recompute_finished()
{
    const Result result = m_watcher.result();
    // 过期的结果直接丢：参数又变了，这一轮算出来的已经不是用户要看的
    if (result.generation < m_applied_generation)
        return;

    m_applied_generation = result.generation;
    {
        // 必须加锁：这一份结果里有 QImage / QVector / QVariantList，
        // 而 QQuickImageProvider::requestImage 可能在**另一个线程**上读它
        //（image_for 也是用这把锁）。整体赋值不是原子的，不加锁就是
        //「读到一个半新半旧的 QImage」—— Debug 下偶发断言，Release 下偶发花屏
        const QMutexLocker locker(&m_mutex);
        m_result = result;
    }
    m_busy = false;

    // 采样率可能被降采样改过，界面上的「片段」读数要用改过之后的
    m_segment_start = result.segment_start;
    m_segment_seconds = result.segment_seconds;
    m_topo_scale_max = result.topo_scale_max;

    m_status_text = result.ok ? QString() : result.error;
    emit busyChanged();
    emit resultChanged();
}

int PostProcess::revision() const
{
    // 图用 result 里的 generation 当版本号：它只在**出新结果**时变，
    // 不会因为参数改动（图还没重画）就让 QML 去取一张旧图
    return m_result.generation;
}

// ==================== 一轮分析 ====================
//
// 这个函数在**工作线程**上跑：只读 raw（shared_ptr 保证它在算完之前不会被释放），
// 其余输入全在 job 里，输出全在返回值里。它不碰本对象的任何成员 ——
// 那正是能安全地丢给 QtConcurrent 的前提
PostProcess::Result PostProcess::compute(std::shared_ptr<const RawData> raw, Job job)
{
    Result result;
    result.generation = job.generation;

    if (!raw || raw->channels <= 0 || raw->frames <= 1)
    {
        result.error = tr("这条记录没有可分析的数据");
        return result;
    }

    const int channels = raw->channels;
    const int source_rate = raw->sample_rate;
    const int source_frames = raw->frames;

    // ---------- 1. 交错样本 → 逐通道 double ----------
    // 后面每一步都是逐通道的整段运算，先转置一次，比每步都去乘一次索引便宜
    QVector<QVector<double>> data(channels);
    for (int channel = 0; channel < channels; ++channel)
    {
        QVector<double> &row = data[channel];
        row.resize(source_frames);
        for (int i = 0; i < source_frames; ++i)
            row[i] = raw->samples.at(i * channels + channel);
    }

    double sample_rate = source_rate;
    QStringList chain;

    // ---------- 2. 带通 + 陷波 ----------
    // 合成**一条**级联（高通两节 → 低通两节 → 陷波一节）只做一次零相位滤波。
    // 分成三次各做一遍前向-反向数值上等价，代价是三倍的边界延拓与内存搬运
    {
        // 滤波之前先扣掉每路的直流分量。
        //
        // 这一步不是可有可无的：本机落盘的记录带着数万到数十万 µV 的直流偏置
        //（放大器的零点，与脑电无关）。0.1 Hz 高通要从这个台阶上「爬」回零，
        // 而它的时间常数是秒级的 —— 整段分析片段都会被这条爬升曲线占满，真实的
        // 脑电被压成一条直线。扣直流**正是高通本来要做的事**，提前做只是让滤波器
        // 不必从饱和状态启动。带通关掉时不扣：那时用户要的就是原始波形
        if (job.band_pass_enabled)
        {
            for (QVector<double> &row : data)
            {
                double sum = 0.0;
                for (const double value : row)
                    sum += value;
                const double mean = sum / row.size();
                for (double &value : row)
                    value -= mean;
            }
        }

        QVector<Biquad> sos;
        if (job.band_pass_enabled)
        {
            const double low_pass = std::min(job.low_pass_hz, sample_rate / 2.0 - 1.0);
            sos += butter_sos(job.high_pass_hz, sample_rate, true);
            sos += butter_sos(low_pass, sample_rate, false);
            chain.prepend(tr("去直流"));
            chain.append(tr("高通 %1 Hz").arg(job.high_pass_hz, 0, 'g', 4));
            chain.append(tr("低通 %1 Hz").arg(job.low_pass_hz, 0, 'g', 4));
        }
        if (job.notch_enabled)
        {
            sos.append(notch_biquad(std::min(job.notch_hz, sample_rate / 2.0 - 1.0), sample_rate, 12.5));
            chain.append(tr("陷波 %1 Hz").arg(job.notch_hz, 0, 'g', 4));
        }
        if (!sos.isEmpty())
        {
            for (QVector<double> &row : data)
                zero_phase_filter(row, sos, sample_rate);
        }
    }

    // ---------- 3. 重参考 ----------
    // 减参考不改变「哪一段是哪一段」，时间轴完全不动
    if (job.reference_index == 0 || job.reference_index == 1)
    {
        QVector<double> reference(source_frames, 0.0);
        if (job.reference_index == 0)
        {
            // 双侧乳突。本蒙太奇里没有 A1/A2，最接近乳突的一对是 T3/T4（左右中颞）。
            // 界面上写「双侧乳突」是设计稿的说法，代码里按名字取下标，蒙太奇顺序
            // 变了也不会悄悄指到别的电极上
            const int left = eeg_montage::index_of(QStringLiteral("T3"));
            const int right = eeg_montage::index_of(QStringLiteral("T4"));
            if (left >= 0 && right >= 0 && left < channels && right < channels)
            {
                for (int i = 0; i < source_frames; ++i)
                    reference[i] = 0.5 * (data.at(left).at(i) + data.at(right).at(i));
            }
        }
        else
        {
            for (int channel = 0; channel < channels; ++channel)
            {
                const QVector<double> &row = data.at(channel);
                for (int i = 0; i < source_frames; ++i)
                    reference[i] += row.at(i);
            }
            for (int i = 0; i < source_frames; ++i)
                reference[i] /= channels;
        }

        for (int channel = 0; channel < channels; ++channel)
        {
            QVector<double> &row = data[channel];
            for (int i = 0; i < source_frames; ++i)
                row[i] -= reference.at(i);
        }
    }

    // ---------- 4. ASR 去伪迹 ----------
    // 与算法包离线模块当前的行为一致：按「均值 ± cutoff × 标准差」整段限幅。
    // 算法包把那一步标成可替换的边界，这里保持同样语义 —— 哪天换成真 ASR，两边一起换
    if (job.asr_enabled && job.asr_cutoff > 0)
    {
        for (QVector<double> &row : data)
        {
            double sum = 0.0;
            for (const double value : row)
                sum += value;
            const double mean = sum / row.size();

            double variance = 0.0;
            for (const double value : row)
                variance += (value - mean) * (value - mean);
            const double limit = job.asr_cutoff * std::sqrt(variance / row.size());
            if (limit <= 0.0)
                continue;
            for (double &value : row)
                value = std::clamp(value, mean - limit, mean + limit);
        }
        chain.append(tr("ASR 限幅 ×%1").arg(job.asr_cutoff));
    }

    // ---------- 5. 降采样 ----------
    // 先按目标采样率的一半做抗混叠低通，再每 M 个取一个。跳过抗混叠的话高频会
    // 折叠到低频上，δ/θ 段凭空多出一堆功率，而且看不出是假的
    int divisor = 1;
    if (job.downsample_index > 0 && source_rate > 0)
    {
        // 档位下标 → 分频比，规则与 downsample_choices() 完全一致
        int seen = 0;
        for (int candidate = 2; candidate <= 16; candidate <<= 1)
        {
            if (source_rate % candidate != 0)
                continue;
            if (source_rate / candidate < 32)
                break;
            if (++seen == job.downsample_index)
            {
                divisor = candidate;
                break;
            }
        }
    }

    if (divisor > 1)
    {
        const double target_rate = static_cast<double>(source_rate) / divisor;
        const QVector<Biquad> anti_alias = butter_sos(target_rate * 0.45, sample_rate, false);
        for (QVector<double> &row : data)
        {
            zero_phase_filter(row, anti_alias, sample_rate);

            QVector<double> decimated;
            decimated.reserve(row.size() / divisor + 1);
            for (int i = 0; i < row.size(); i += divisor)
                decimated.append(row.at(i));
            row = decimated;
        }
        sample_rate = target_rate;
        chain.append(tr("降采样 %1 Hz").arg(target_rate, 0, 'g', 4));
    }

    const int frames = data.isEmpty() ? 0 : data.first().size();
    if (frames < 16)
    {
        result.error = tr("预处理后的数据太短，无法分析");
        return result;
    }

    // ---------- 6. 基线校正 ----------
    // 按整段记录的均值扣除（constant 去趋势），与算法侧 BaselineConfig
    //「对 baseline_range 内每通道的均值进行扣除」是同一件事
    if (job.baseline_enabled)
    {
        for (QVector<double> &row : data)
        {
            double sum = 0.0;
            for (const double value : row)
                sum += value;
            const double mean = sum / row.size();
            for (double &value : row)
                value -= mean;
        }
        chain.prepend(tr("基线校正"));
    }

    // ---------- 7. 分析片段 ----------
    const int first = std::clamp(static_cast<int>(std::lround(job.segment_start * sample_rate)),
                                 0, std::max(0, frames - 16));
    const int count = std::clamp(static_cast<int>(std::lround(job.segment_seconds * sample_rate)),
                                 16, frames - first);

    result.sample_rate = static_cast<int>(std::lround(sample_rate));
    result.channels = channels;
    result.segment_start = static_cast<double>(first) / sample_rate;
    result.segment_seconds = static_cast<double>(count) / sample_rate;
    result.processing_chain = chain;

    // 留一份预处理后的整段数据供「导出数据」用（见 Result::processed 的说明）。
    // 逐通道 → 帧优先交错，与 .eegbin 是同一种布局，导出的 CSV 按帧走一遍即可
    result.processed_channels = channels;
    result.processed_rate = sample_rate;
    result.processed.resize(static_cast<qsizetype>(frames) * channels);
    for (int i = 0; i < frames; ++i)
        for (int channel = 0; channel < channels; ++channel)
            result.processed[i * channels + channel] = static_cast<float>(data.at(channel).at(i));

    // ---------- 8. 每通道功率谱 ----------
    // **一次 Welch 供全页使用**：频谱页那条曲线、通道表的「优势频带」、统计页的
    // 频带占比、地形图的电极功率，都是它的不同投影。每处各算一遍的话，
    // 同一份数据在不同页面上会给出互相矛盾的数字
    QVector<Psd> spectra(channels);
    for (int channel = 0; channel < channels; ++channel)
        spectra[channel] = welch_psd(data.at(channel).constData() + first, count, sample_rate);

    // ---------- 9. 通道统计表与各通道频带占比 ----------
    QVariantList channel_stats;
    QVariantList channel_bands;
    QVector<QVector<double>> ratios(channels);
    QVector<ChannelStat> stats(channels);

    for (int channel = 0; channel < channels; ++channel)
    {
        stats[channel] = compute_stat(data.at(channel).constData() + first, count, sample_rate);
        const ChannelStat &stat = stats.at(channel);

        QVector<double> share(kBandCount, 0.0);
        double total = 0.0;
        int dominant = 0;
        QVector<double> powers(kBandCount, 0.0);
        for (int band = 0; band < kBandCount; ++band)
        {
            powers[band] = band_power(spectra.at(channel), kBands[band].low_hz, kBands[band].high_hz);
            total += powers.at(band);
            if (powers.at(band) > powers.at(dominant))
                dominant = band;
        }
        for (int band = 0; band < kBandCount; ++band)
            share[band] = total > 0.0 ? powers.at(band) / total : 0.0;
        ratios[channel] = share;

        const QString name = eeg_montage::channel_name(channel);
        const QString color = eeg_montage::channel_colors().value(channel);

        channel_stats.append(QVariantMap{
            {QStringLiteral("name"), name},
            {QStringLiteral("color"), color},
            {QStringLiteral("mean"), QString::number(stat.mean, 'f', 2)},
            {QStringLiteral("std"), QString::number(stat.std_dev, 'f', 2)},
            {QStringLiteral("rms"), QString::number(stat.rms, 'f', 2)},
            {QStringLiteral("peak"), QString::number(stat.peak, 'f', 2)},
            {QStringLiteral("min"), QString::number(stat.minimum, 'f', 2)},
            {QStringLiteral("max"), QString::number(stat.maximum, 'f', 2)},
            {QStringLiteral("zeroCross"), QString::number(stat.zero_cross, 'f', 1)},
            {QStringLiteral("skewness"), QString::number(stat.skewness, 'f', 2)},
            {QStringLiteral("kurtosis"), QString::number(stat.kurtosis, 'f', 2)},
            {QStringLiteral("band"),
             QString::fromUtf8(kBands[dominant].letter) + QLatin1Char(' ')
                 + QString::fromUtf8(kBands[dominant].name)},
        });

        QVariantList share_list;
        for (int band = 0; band < kBandCount; ++band)
            share_list.append(share.at(band));
        channel_bands.append(QVariantMap{
            {QStringLiteral("name"), name},
            {QStringLiteral("color"), color},
            {QStringLiteral("ratio"), share_list},
        });
    }
    result.channel_stats = channel_stats;
    result.channel_bands = channel_bands;

    // ---------- 10. 整段的频带分布 ----------
    // 五项都是**全通道平均**，统计页那五根大柱与报告页的占比都用它
    QVariantList distribution;
    QVector<double> band_mean(kBandCount, 0.0);
    {
        QVector<double> mean_psd(kBandCount, 0.0);
        for (int band = 0; band < kBandCount; ++band)
        {
            double psd_sum = 0.0;
            double power_sum = 0.0;
            for (int channel = 0; channel < channels; ++channel)
            {
                psd_sum += band_mean_psd(spectra.at(channel), kBands[band].low_hz, kBands[band].high_hz);
                power_sum += band_power(spectra.at(channel), kBands[band].low_hz, kBands[band].high_hz);
            }
            mean_psd[band] = psd_sum / channels;
            band_mean[band] = power_sum / channels;
        }

        double total_power = 0.0;
        for (const double value : band_mean)
            total_power += value;

        for (int band = 0; band < kBandCount; ++band)
        {
            distribution.append(QVariantMap{
                {QStringLiteral("key"), QString::fromUtf8(kBands[band].key)},
                {QStringLiteral("label"), QString::fromUtf8(kBands[band].letter) + QLatin1Char(' ')
                                              + QString::fromUtf8(kBands[band].name)},
                {QStringLiteral("color"), QString::fromUtf8(kBands[band].color)},
                {QStringLiteral("mean"), mean_psd.at(band)},
                {QStringLiteral("ratio"), total_power > 0.0 ? band_mean.at(band) / total_power : 0.0},
            });
        }
    }
    result.band_distribution = distribution;

    // ---------- 11. 通道相关性 ----------
    QVector<QVector<double>> correlation(channels, QVector<double>(channels, 0.0));
    for (int a = 0; a < channels; ++a)
    {
        correlation[a][a] = 1.0;
        const double *row_a = data.at(a).constData() + first;
        for (int b = a + 1; b < channels; ++b)
        {
            const double *row_b = data.at(b).constData() + first;
            double mean_a = 0.0;
            double mean_b = 0.0;
            for (int i = 0; i < count; ++i)
            {
                mean_a += row_a[i];
                mean_b += row_b[i];
            }
            mean_a /= count;
            mean_b /= count;

            double covariance = 0.0;
            double variance_a = 0.0;
            double variance_b = 0.0;
            for (int i = 0; i < count; ++i)
            {
                const double da = row_a[i] - mean_a;
                const double db = row_b[i] - mean_b;
                covariance += da * db;
                variance_a += da * da;
                variance_b += db * db;
            }
            const double denominator = std::sqrt(variance_a * variance_b);
            const double value = denominator > 1e-12 ? covariance / denominator : 0.0;
            correlation[a][b] = value;
            correlation[b][a] = value;
        }
    }
    result.correlation_image = render_correlation_image(correlation, 420);

    // ---------- 12. 质检 ----------
    // 三项都在这里一次算完：报告页与底栏读的是同一组数，
    // 各算各的迟早会出现「报告说 3 个、底栏说 0 个」
    int weak_channels = 0;
    QStringList weak_names;
    int outlier_samples = 0;
    for (int channel = 0; channel < channels; ++channel)
    {
        if (stats.at(channel).rms < 5.0)
        {
            ++weak_channels;
            weak_names.append(eeg_montage::channel_name(channel));
        }
        const double *row = data.at(channel).constData() + first;
        for (int i = 0; i < count; ++i)
        {
            if (std::abs(row[i]) > 300.0)
                ++outlier_samples;
        }
    }

    QStringList low_correlation;
    for (int channel = 0; channel < channels; ++channel)
    {
        double best = 0.0;
        for (int other = 0; other < channels; ++other)
        {
            if (other != channel)
                best = std::max(best, std::abs(correlation.at(channel).at(other)));
        }
        if (best < 0.3)
            low_correlation.append(eeg_montage::channel_name(channel));
    }

    // ---------- 13. 波形图 ----------
    {
        // 幅值标尺按**这一屏的实际范围**自动定，向上取整到 1/2/5×10ⁿ。
        // 写死 ±100 μV 的话，幅度小的记录会是一条平线，幅度大的会削顶
        double robust = 0.0;
        const int window_first = std::clamp(
            static_cast<int>(std::lround(job.window_start * sample_rate)), 0, frames - 1);
        const int window_last = std::clamp(
            window_first + static_cast<int>(std::lround(job.window_seconds * sample_rate)),
            window_first + 1, frames);
        for (int channel = 0; channel < channels; ++channel)
            for (int i = window_first; i < window_last; ++i)
                robust = std::max(robust, std::abs(data.at(channel).at(i)));

        const double exponent = robust > 0.0 ? std::pow(10.0, std::floor(std::log10(robust))) : 1.0;
        const double normalized = exponent > 0.0 ? robust / exponent : 1.0;
        // 1 / 2 / 5 / 10 四档。**不能只给到 5**：归一化值落在 (5,10) 时取 5 会
        // 算出一个比实际峰值还小的标尺，波形顶部会被削平
        const double step = normalized <= 1.0 ? 1.0
                          : (normalized <= 2.0 ? 2.0 : (normalized <= 5.0 ? 5.0 : 10.0));
        result.wave_range_uv = std::max(25.0, step * exponent);

        result.wave_image = render_wave_image(data, sample_rate, job.window_start,
                                              job.window_seconds, job.current_channel,
                                              result.wave_range_uv, job.wave_width, job.events);
    }

    // ---------- 14. 频谱图 ----------
    if (job.current_channel >= 0 && job.current_channel < spectra.size())
    {
        const Psd &psd = spectra.at(job.current_channel);
        double f_max = std::min(60.0, std::floor(sample_rate / 2.0));
        if (f_max <= 1.0)
            f_max = std::max(1.0, sample_rate / 2.0);

        double db_max = -1.0e9;
        double db_min = 1.0e9;
        for (int i = 0; i < psd.frequencies.size(); ++i)
        {
            if (psd.frequencies.at(i) > f_max)
                break;
            const double value = psd.values.at(i);
            const double db = value > 0.0 ? 10.0 * std::log10(value) : -120.0;
            db_max = std::max(db_max, db);
            db_min = std::min(db_min, db);
        }
        if (db_max < db_min)
        {
            db_max = 10.0;
            db_min = -90.0;
        }
        // 上下各留一档，曲线不贴边框；下界封在 -120（再低只是噪声地板）
        result.spectrum_f_min = 0.0;
        result.spectrum_f_max = f_max;
        result.spectrum_db_max = std::ceil(db_max / 10.0) * 10.0;
        result.spectrum_db_min = std::max(-120.0, std::floor(db_min / 10.0) * 10.0);
        result.spectrum_image = render_spectrum_image(psd, 0.0, f_max, result.spectrum_db_min,
                                                      result.spectrum_db_max,
                                                      job.spectrum_width, job.spectrum_height);
    }

    // ---------- 15. 地形图 ----------
    {
        QVector<QPointF> positions;
        positions.reserve(channels);
        for (int channel = 0; channel < channels; ++channel)
        {
            const eeg_montage::Electrode *table = eeg_montage::electrodes();
            positions.append(channel < eeg_montage::kChannelCount
                                 ? QPointF(table[channel].x, table[channel].y)
                                 : QPointF(0.0, 0.0));
        }
        normalize_positions(&positions);

        // 六张图：全频段 + 五档。每张**按自身峰值归一化** ——
        // γ 的绝对功率常常只有 δ 的百分之一，六张共用一根色标的话五张会是
        // 同一种深蓝，什么也看不出来。归一化不丢量纲：每张图的峰值功率与
        // 峰值电极都列在 topoStats 与报告里
        double edges[kBandCount + 1][2] = {{kFullBandLowHz, kFullBandHighHz}};
        for (int band = 0; band < kBandCount; ++band)
        {
            edges[band + 1][0] = kBands[band].low_hz;
            edges[band + 1][1] = kBands[band].high_hz;
        }

        QVariantList topo_stats;
        for (int band = 0; band < kBandCount + 1; ++band)
        {
            QVector<double> electrode_values;
            electrode_values.reserve(channels);
            for (int channel = 0; channel < channels; ++channel)
                electrode_values.append(band_mean_psd(spectra.at(channel), edges[band][0], edges[band][1]));

            int peak_index = 0;
            double peak_value = 0.0;
            double sum = 0.0;
            for (int i = 0; i < electrode_values.size(); ++i)
            {
                if (electrode_values.at(i) > peak_value)
                {
                    peak_value = electrode_values.at(i);
                    peak_index = i;
                }
                sum += electrode_values.at(i);
            }

            QVector<float> grid_values;
            interpolate_topography(positions, electrode_values, kTopoGrid, &grid_values);
            const double scale = nice_scale_max(peak_value);
            result.topo_images.append(render_topography_image(grid_values, kTopoGrid, scale));

            const QString label =
                band == 0
                    ? tr("全频段")
                    : QString::fromUtf8(kBands[band - 1].letter) + QLatin1Char(' ')
                          + QString::fromUtf8(kBands[band - 1].name);
            topo_stats.append(QVariantMap{
                {QStringLiteral("label"), label},
                {QStringLiteral("peakElectrode"), eeg_montage::channel_name(peak_index)},
                {QStringLiteral("peakValue"), QString::number(peak_value, 'f', 2)},
                {QStringLiteral("meanValue"),
                 QString::number(electrode_values.isEmpty() ? 0.0 : sum / electrode_values.size(),
                                 'f', 2)},
                {QStringLiteral("scaleMax"), QString::number(scale, 'f', 2)},
                {QStringLiteral("band"), band == 0 ? QString() : QString::fromUtf8(kBands[band - 1].key)},
            });

            if (band == 0)
                result.topo_scale_max = scale;
        }
        result.topo_stats = topo_stats;
    }

    // ---------- 16. 报告分节 ----------
    {
        // 主导节律取全通道平均功率最大的那一档
        int dominant_band = 0;
        for (int band = 1; band < kBandCount; ++band)
        {
            if (band_mean.at(band) > band_mean.at(dominant_band))
                dominant_band = band;
        }

        QVariantList sections;

        // 记录信息：与左侧面板那五行同源（Job 里带过来的），
        // 报告页与面板不会各说各话
        if (!job.record_info.isEmpty())
            sections.append(QVariantMap{
                {QStringLiteral("title"), tr("记录信息")},
                {QStringLiteral("rows"), job.record_info},
            });

        QVariantList chain_chips;
        if (chain.isEmpty())
            chain_chips.append(QVariantMap{{QStringLiteral("text"), tr("未启用任何处理")}});
        else
        {
            for (const QString &step : chain)
                chain_chips.append(QVariantMap{{QStringLiteral("text"), step}});
        }
        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("处理链")},
            {QStringLiteral("chips"), chain_chips},
            {QStringLiteral("note"), tr("顺序：带通 → 陷波 → 重参考 → ASR → 降采样 → 基线校正")},
        });

        double rms_sum = 0.0;
        double peak_sum = 0.0;
        for (int channel = 0; channel < channels; ++channel)
        {
            rms_sum += stats.at(channel).rms;
            peak_sum += stats.at(channel).peak;
        }
        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("片段统计")},
            {QStringLiteral("rows"), QVariantList{
                 QVariantMap{{QStringLiteral("label"), tr("片段范围")},
                             {QStringLiteral("value"),
                              QStringLiteral("%1 - %2 s")
                                  .arg(result.segment_start, 0, 'f', 1)
                                  .arg(result.segment_start + result.segment_seconds, 0, 'f', 1)}},
                 QVariantMap{{QStringLiteral("label"), tr("片段时长")},
                             {QStringLiteral("value"),
                              QStringLiteral("%1 s").arg(result.segment_seconds, 0, 'f', 1)}},
                 QVariantMap{{QStringLiteral("label"), tr("平均 RMS")},
                             {QStringLiteral("value"),
                              QStringLiteral("%1 μV").arg(rms_sum / channels, 0, 'f', 2)}},
                 QVariantMap{{QStringLiteral("label"), tr("平均峰值")},
                             {QStringLiteral("value"),
                              QStringLiteral("%1 μV").arg(peak_sum / channels, 0, 'f', 2)}},
                 QVariantMap{{QStringLiteral("label"), tr("主导节律")},
                             {QStringLiteral("value"),
                              QString::fromUtf8(kBands[dominant_band].letter) + QLatin1Char(' ')
                                  + QString::fromUtf8(kBands[dominant_band].name)}},
                 QVariantMap{{QStringLiteral("label"), tr("通道数")},
                             {QStringLiteral("value"), QString::number(channels)}},
             }},
        });

        QVariantList band_chips;
        if (job.current_channel >= 0 && job.current_channel < ratios.size())
        {
            for (int band = 0; band < kBandCount; ++band)
            {
                band_chips.append(QVariantMap{
                    {QStringLiteral("text"),
                     QString::fromUtf8(kBands[band].letter) + QLatin1Char(' ')
                         + QString::fromUtf8(kBands[band].name) + QLatin1Char(' ')
                         + QString::number(ratios.at(job.current_channel).at(band) * 100.0, 'f', 1)
                         + QLatin1Char('%')},
                    {QStringLiteral("color"), QString::fromUtf8(kBands[band].color)},
                });
            }
        }
        sections.append(QVariantMap{
            {QStringLiteral("title"),
             tr("频带分布（%1）").arg(eeg_montage::channel_name(job.current_channel))},
            {QStringLiteral("chips"), band_chips},
            {QStringLiteral("note"),
             tr("Welch 平均 PSD，窗函数 Hann（512 点）· 50% 重叠 · 密度谱；占比按各频段绝对功率积分算")},
        });

        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("伪差检测")},
            {QStringLiteral("note"),
             outlier_samples == 0
                 ? tr("所选片段未检测到超出 ±300 μV 的样本")
                 : tr("所选片段有 %1 个样本超出 ±300 μV").arg(outlier_samples)},
        });

        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("质检结果")},
            {QStringLiteral("note"),
             tr("弱信号 %1 个通道（RMS < 5 μV）· 异常值 %2 点 · 低相关通道 %3 个%4")
                 .arg(weak_channels)
                 .arg(outlier_samples)
                 .arg(low_correlation.size())
                 .arg(low_correlation.isEmpty()
                          ? QString()
                          : QStringLiteral("（") + low_correlation.join(QStringLiteral("、"))
                                + QStringLiteral("）"))},
        });

        result.report_sections = sections;
    }

    // ---------- 17. 底栏那一行 ----------
    {
        const QVector<double> &row = data.at(std::clamp(job.current_channel, 0, channels - 1));
        double lowest = row.at(first);
        double highest = row.at(first);
        for (int i = first; i < first + count; ++i)
        {
            lowest = std::min(lowest, row.at(i));
            highest = std::max(highest, row.at(i));
        }

        result.status_line =
            tr("%1(第%2/%3)通道   窗口内范围: %4 ~ %5 μV   片段: %6 - %7 s   %8   处理链: %9   质检: 弱信号 %10 点 · 异常值 %11 点 · 低相关 %12 通道")
                .arg(eeg_montage::channel_name(job.current_channel))
                .arg(job.current_channel + 1)
                .arg(channels)
                .arg(lowest, 0, 'f', 1)
                .arg(highest, 0, 'f', 1)
                .arg(result.segment_start, 0, 'f', 1)
                .arg(result.segment_start + result.segment_seconds, 0, 'f', 1)
                .arg(outlier_samples == 0 ? tr("无伪差") : tr("有伪差"))
                .arg(chain.isEmpty() ? tr("未启用") : chain.join(QStringLiteral(" → ")))
                .arg(weak_channels)
                .arg(outlier_samples)
                .arg(low_correlation.size());
    }

    result.ok = true;
    return result;
}

// ==================== 结果读取 ====================

QVariantList PostProcess::channel_stats() const
{
    return m_result.channel_stats;
}

QVariantList PostProcess::band_distribution() const
{
    return m_result.band_distribution;
}

QVariantList PostProcess::channel_bands() const
{
    return m_result.channel_bands;
}

QVariantList PostProcess::topo_stats() const
{
    return m_result.topo_stats;
}

QVariantList PostProcess::report_sections() const
{
    return m_result.report_sections;
}

QString PostProcess::status_line() const
{
    return m_result.status_line;
}

// ==================== 出图 ====================

QImage PostProcess::image_for(const QString &id) const
{
    // id 形如 "wave/12"、"topo/alpha/12"。最后一段只是用来制造新 URL 的版本号，
    // 取图靠的是前面那几段 —— 版本号本身不参与判断
    const QStringList parts = id.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    if (parts.isEmpty())
        return QImage();

    // provider 可能被别的线程调用，而 m_result 正被 GUI 线程写
    const QMutexLocker locker(&m_mutex);

    if (parts.first() == QLatin1String("wave"))
        return m_result.wave_image;
    if (parts.first() == QLatin1String("spectrum"))
        return m_result.spectrum_image;
    if (parts.first() == QLatin1String("correlation"))
        return m_result.correlation_image;
    if (parts.first() == QLatin1String("topo") && parts.size() >= 2)
    {
        const QStringList keys = band_keys();
        // 00 = 全频段，01..05 = δ…γ，顺序与 compute() 里填图的顺序一致
        int index = parts.at(1) == QLatin1String("full") ? 0 : keys.indexOf(parts.at(1)) + 1;
        if (index >= 0 && index < m_result.topo_images.size())
            return m_result.topo_images.at(index);
    }
    return QImage();
}

QQuickImageProvider *PostProcess::create_image_provider()
{
    return new PostProcessImageProvider(this);
}

PostProcessImageProvider::PostProcessImageProvider(PostProcess *analysis)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_analysis(analysis)
{
}

QImage PostProcessImageProvider::requestImage(const QString &id, QSize *size,
                                              const QSize &requested_size)
{
    Q_UNUSED(requested_size);

    const QImage image = m_analysis->image_for(id);
    if (size != nullptr)
        *size = image.size();
    // 交深拷贝：调用方可能缓存这张图，而下一轮重算会把源图整体换掉
    return image.isNull() ? image : image.copy();
}

// ==================== 导出 ====================

namespace
{

// 导出结果统一走这一个出口，三种导出的返回结构才不会各写一套
QVariantMap export_result(bool success, const QString &message, const QString &path = QString())
{
    QVariantMap result;
    result[QStringLiteral("success")] = success;
    result[QStringLiteral("message")] = message;
    if (!path.isEmpty())
        result[QStringLiteral("path")] = path;
    return result;
}

bool prepare_directory(const QString &directory, QString *error)
{
    QDir dir(directory);
    if (directory.trimmed().isEmpty())
    {
        *error = QObject::tr("没有可用的导出目录");
        return false;
    }
    if (!dir.exists() && !dir.mkpath(QStringLiteral(".")))
    {
        *error = QObject::tr("无法创建导出目录：%1").arg(directory);
        return false;
    }
    return true;
}

} // namespace

QVariantMap PostProcess::export_data(const QString &directory)
{
    QString error;
    if (!prepare_directory(directory, &error))
        return export_result(false, error);
    if (!m_loaded)
        return export_result(false, tr("还没有打开任何记录"));

    // 导出的是**预处理之后**的整段数据：这一页的意义就是把原始数据按当前参数
    // 处理一遍。只想要原始数据的话，历史记录页的「导出」给的就是原始文件
    QVector<float> processed;
    int channels = 0;
    double rate = 0.0;
    {
        const QMutexLocker locker(&m_mutex);
        processed = m_result.processed;
        channels = m_result.processed_channels;
        rate = m_result.processed_rate;
    }
    if (processed.isEmpty() || channels <= 0 || rate <= 0.0)
        return export_result(false, tr("还没有可导出的处理结果，请先等分析完成"));

    const QString target = QDir(directory).filePath(
        QStringLiteral("%1_预处理数据.csv").arg(m_record_no));
    QFile file(target);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return export_result(false, tr("无法写入导出文件：%1").arg(file.errorString()));

    QTextStream out(&file);
    // Excel 打开 UTF-8 的 CSV 要带 BOM，否则中文列名是乱码（与记录导出同一约定）
    out.setEncoding(QStringConverter::Utf8);
    out << QChar(0xFEFF);

    out << QStringLiteral("时间(s)");
    for (int channel = 0; channel < channels; ++channel)
        out << ',' << eeg_montage::channel_name(channel);
    out << '\n';

    const qsizetype frames = processed.size() / channels;
    for (qsizetype i = 0; i < frames; ++i)
    {
        out << QString::number(i / rate, 'f', 4);
        for (int channel = 0; channel < channels; ++channel)
            out << ',' << QString::number(processed.at(i * channels + channel), 'f', 2);
        out << '\n';
    }

    file.close();
    return export_result(true, tr("已导出预处理数据：%1").arg(target), target);
}

QVariantMap PostProcess::export_stats_csv(const QString &directory)
{
    QString error;
    if (!prepare_directory(directory, &error))
        return export_result(false, error);
    if (m_result.channel_stats.isEmpty())
        return export_result(false, tr("还没有可导出的统计结果"));

    const QString target = QDir(directory).filePath(
        QStringLiteral("%1_通道统计.csv").arg(m_record_no));
    QFile file(target);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return export_result(false, tr("无法写入导出文件：%1").arg(file.errorString()));

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QChar(0xFEFF);
    out << QStringLiteral("通道,均值μV,标准差,RMS,峰值μV,最小,最大,零交叉/s,偏度,峰度,优势频带\n");

    const QStringList columns = {QStringLiteral("name"), QStringLiteral("mean"),
                                 QStringLiteral("std"),  QStringLiteral("rms"),
                                 QStringLiteral("peak"), QStringLiteral("min"),
                                 QStringLiteral("max"),  QStringLiteral("zeroCross"),
                                 QStringLiteral("skewness"), QStringLiteral("kurtosis"),
                                 QStringLiteral("band")};
    for (const QVariant &item : m_result.channel_stats)
    {
        const QVariantMap row = item.toMap();
        QStringList cells;
        for (const QString &column : columns)
            cells.append(row.value(column).toString());
        out << cells.join(QLatin1Char(',')) << '\n';
    }

    file.close();
    return export_result(true, tr("已导出通道统计：%1").arg(target), target);
}

QVariantMap PostProcess::export_report_txt(const QString &directory)
{
    QString error;
    if (!prepare_directory(directory, &error))
        return export_result(false, error);
    if (!m_loaded)
        return export_result(false, tr("还没有打开任何记录"));

    const QString target = QDir(directory).filePath(
        QStringLiteral("%1_分析报告.txt").arg(m_record_no));
    QFile file(target);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return export_result(false, tr("无法写入导出文件：%1").arg(file.errorString()));

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QChar(0xFEFF);

    out << tr("EEG 分析报告") << '\n';
    out << QStringLiteral("========================================\n");
    out << tr("记录ID：%1\n").arg(m_record_no);
    out << tr("患者：%1\n").arg(m_info.value(QStringLiteral("patient")).toString());
    out << tr("采集时间：%1\n").arg(m_info.value(QStringLiteral("time")).toString());
    out << tr("时长：%1 秒   通道：%2   采样率：%3 Hz\n")
               .arg(m_duration_seconds, 0, 'f', 1)
               .arg(m_channels)
               .arg(m_sample_rate);
    out << '\n';

    for (const QVariant &item : m_result.report_sections)
    {
        const QVariantMap section = item.toMap();
        out << QStringLiteral("【") << section.value(QStringLiteral("title")).toString()
            << QStringLiteral("】\n");

        const QVariantList rows = section.value(QStringLiteral("rows")).toList();
        for (const QVariant &row_item : rows)
        {
            const QVariantMap row = row_item.toMap();
            out << QStringLiteral("  ") << row.value(QStringLiteral("label")).toString()
                << QStringLiteral("：") << row.value(QStringLiteral("value")).toString() << '\n';
        }

        const QVariantList chips = section.value(QStringLiteral("chips")).toList();
        if (!chips.isEmpty())
        {
            QStringList texts;
            for (const QVariant &chip_item : chips)
                texts.append(chip_item.toMap().value(QStringLiteral("text")).toString());
            out << QStringLiteral("  ") << texts.join(QStringLiteral("  ")) << '\n';
        }

        const QString note = section.value(QStringLiteral("note")).toString();
        if (!note.isEmpty())
            out << QStringLiteral("  ") << note << '\n';
        out << '\n';
    }

    out << QStringLiteral("【通道统计】\n");
    out << QStringLiteral("  通道  均值   标准差  RMS    峰值    优势频带\n");
    for (const QVariant &item : m_result.channel_stats)
    {
        const QVariantMap row = item.toMap();
        out << QStringLiteral("  %1  %2  %3  %4  %5  %6\n")
                   .arg(row.value(QStringLiteral("name")).toString(), -4)
                   .arg(row.value(QStringLiteral("mean")).toString(), 7)
                   .arg(row.value(QStringLiteral("std")).toString(), 7)
                   .arg(row.value(QStringLiteral("rms")).toString(), 7)
                   .arg(row.value(QStringLiteral("peak")).toString(), 8)
                   .arg(row.value(QStringLiteral("band")).toString());
    }

    file.close();
    return export_result(true, tr("已导出分析报告：%1").arg(target), target);
}
