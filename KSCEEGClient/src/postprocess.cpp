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
#include <QSet>
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
#include "offlinealgorithm.h"
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

    // 镜像轴取**边界处的局部基线**（约 0.5 秒窗口均值），而不是边界那一个采样点。
    // 直接以 x[0]/x[-1] 为轴会在接缝处注入一个直流台阶：本项目原始数据被 ~50Hz
    // 伪迹主导，x[0] 往往是工频的一个峰值（远离真实基线），延拓段的均值随之偏离，
    // 接缝一跳变就被 0.1 Hz 高通响应成开头几秒的假斜坡 —— 而默认分析片段正好是
    // 开头这几秒。0.5 秒窗口含 ~25 个工频周期，均值对相位不敏感，又能跟随慢漂移
    const int base_win = std::min(pad, std::max(8, static_cast<int>(std::lround(0.5 * sample_rate))));
    double left_base = 0.0;
    double right_base = 0.0;
    for (int i = 0; i < base_win; ++i)
    {
        left_base += x[i];
        right_base += x[n - 1 - i];
    }
    left_base /= base_win;
    right_base /= base_win;

    QVector<double> buffer(total);
    // 奇数延拓：左端 = 2*left_base - x[pad..1]，右端同理。这样接缝处值连续、
    // 一阶差分也连续，滤波器的启动瞬变被推到接缝以外
    for (int i = 0; i < pad; ++i)
        buffer[i] = 2.0 * left_base - x[pad - i];
    std::copy(x.begin(), x.end(), buffer.begin() + pad);
    for (int i = 0; i < pad; ++i)
        buffer[pad + n + i] = 2.0 * right_base - x[n - 2 - i];

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
// 算法侧用的是 scipy 的薄板样条 RBF（全局光滑），本页取反距离加权：
// 反距离加权是加权平均，天然被电极值域夹住，不会出现「比最大电极还红」的点，
// 也不依赖 scipy —— 这一页不引入 Python 依赖
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

            // 双线性采样：按相邻四格的权重混合，而不是四舍五入到最近一格。
            // 网格是 64×64、图是 256×256，最近邻等于把每个格子摊成 4×4 的纯色方块，
            // 格子之间取值不连续 —— 看上去就是一圈圈硬邦邦的「分界线」
            const double fx = (nx + 1.0) / 2.0 * (grid - 1);
            const double fy = (ny + 1.0) / 2.0 * (grid - 1);
            const int x0 = std::clamp(static_cast<int>(std::floor(fx)), 0, grid - 1);
            const int y0 = std::clamp(static_cast<int>(std::floor(fy)), 0, grid - 1);
            const int x1 = std::min(x0 + 1, grid - 1);
            const int y1 = std::min(y0 + 1, grid - 1);
            const double tx = fx - x0;
            const double ty = fy - y0;

            const double value =
                grid_values.at(y0 * grid + x0) * (1.0 - tx) * (1.0 - ty)
                + grid_values.at(y0 * grid + x1) * tx * (1.0 - ty)
                + grid_values.at(y1 * grid + x0) * (1.0 - tx) * ty
                + grid_values.at(y1 * grid + x1) * tx * ty;
            line[x] = topography_palette::color(value / safe_max);
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
                         const QVector<double> &channel_range_uv, int width,
                         const QVariantList &events)
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

    // 时间网格线：与 WaveTab 底部 4 个相对秒数刻度（1/4、2/4、3/4、4/4）对齐，
    // 和泳道居中线一样画在所有波形之下。设计稿里是极淡的竖线
    painter.setPen(QPen(QColor(0, 0, 0, 12), 1.0));
    for (int i = 1; i <= 4; ++i)
    {
        const double x = width * i / 4.0;
        painter.drawLine(QPointF(x, 0.0), QPointF(x, height));
    }

    const double half_lane = PostProcess::lane_height() * 0.5;

    for (int channel = 0; channel < channels; ++channel)
    {
        const QVector<double> &row = data.at(channel);
        if (row.isEmpty())
            continue;

        // 每一路用各自的标尺：脑电通道幅度小、噪声通道幅度大，统一标尺时
        // 总有一头受委屈（要么脑电被压平，要么噪声被削成方块）
        const double range_uv = channel < channel_range_uv.size()
                                    ? channel_range_uv.at(channel) : 25.0;
        const double scale = half_lane / std::max(1.0, range_uv);

        const double centre = channel * PostProcess::lane_height() + half_lane;
        const bool active = channel == current_channel;
        // 当前导联用设计稿的红色（与 QML 侧的 Design.waveCurrent 同值），
        // 其余压成灰 —— 设计稿图例写的就是「当前通道 / 其余通道」
        QColor color = active ? QColor(0xd6, 0x5a, 0x5d) : QColor(150, 158, 168);

        QPolygonF polyline;
        polyline.reserve(std::max(2, width) * 2);
        const int samples = static_cast<int>(row.size());

        // 显示用去直流（AC 耦合）：减去本窗口内该通道的均值。
        // 与实时波形（AcquisitionBridge 的 m_dc_removal）和预览弹窗
        // （RecordingPreview::render_window）同一套约定：每帧现算、没有跨帧状态，
        // 所以不会像算法侧的因果高通那样在启动后拖出几秒的漂移。
        // 不减掉的话，电极直流偏置与启动漂移会把整条波形抬离泳道中线（甚至压到
        // 相邻泳道上），同时把自动量程顶到 ±1000，几十 µV 的脑电被压成一条平线
        const int offset_from = std::clamp(static_cast<int>(first_sample), 0, samples - 1);
        const int offset_to = std::clamp(static_cast<int>(last_sample), offset_from + 1, samples);
        double offset = 0.0;
        for (int i = offset_from; i < offset_to; ++i)
            offset += row.at(i);
        offset /= static_cast<double>(offset_to - offset_from);

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

            const double y_low = centre - std::clamp((lowest - offset) * scale, -half_lane, half_lane);
            const double y_high = centre - std::clamp((highest - offset) * scale, -half_lane, half_lane);
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
// 复用地形图那套「白底 → 饱和色」的插值思路，只是换成发散色标。
// highlight 落在有效范围时，给该通道的整行、整列描一圈边（十字准星）：
// 与下方「当前导联」联动，一眼看出该导联与其余各路的相关系数分布
QImage render_correlation_image(const QVector<QVector<double>> &matrix, int size, int highlight)
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

    // 所选通道的十字准星。往格内内缩 1 px，2 px 的线不至于糊到相邻格上
    if (highlight >= 0 && highlight < count)
    {
        const int first = static_cast<int>(std::lround(highlight * cell));
        const int last = static_cast<int>(std::lround((highlight + 1) * cell));
        const int span = last - first;
        painter.setBrush(Qt::NoBrush);
        painter.setPen(QPen(QColor(0x70, 0x92, 0xab), 2));
        painter.drawRect(QRect(1, first + 1, size - 2, span - 2));
        painter.drawRect(QRect(first + 1, 1, span - 2, size - 2));
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
    // 拖动时间轴时按这个节拍更新。命中指纹的话一轮只剩出图，几十毫秒就够；
    // 再大就变成明显的「跟手但不跟手」了
    m_debounce->setInterval(40);
    QObject::connect(m_debounce, &QTimer::timeout, this, &PostProcess::run_recompute);

    QObject::connect(&m_watcher, &QFutureWatcher<Result>::finished,
                     this, &PostProcess::on_recompute_finished);

    m_view_size = QSize(1200, 600);
}

PostProcess::~PostProcess()
{
    // 工作线程可能还在跑，但它只读 m_raw（shared_ptr），本对象析构后它照样安全；
    // m_watcher 的 finished 连接挂在 this 上，this 析构时 Qt 会自动断开。
    // 所以**不在这里等**：在 GUI 线程里 waitForFinished() 会阻塞事件循环，
    // 只要有一轮任务迟迟不返回，整个界面就假死
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
    // 这里**不能** m_watcher.waitForFinished()：在 GUI 线程上阻塞等一个 future，
    // 只要有一轮任务不返回（或 Qt 内部 future 状态机会话被占住），整个界面就假死。
    // 在途的旧任务回来时靠 generation 不等而被丢弃，无需在这里等它。
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
    m_busy = false;
    // 增量重算的底子是上一份结果，换记录后必须丢；否则会拿旧记录的数据去拼波形
    m_previous.reset();
    m_pending_recompute = false;
    emit busyChanged();
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

QStringList PostProcess::qc_repair_choices() const
{
    return {tr("off"), tr("线性插值修复")};
}

QStringList PostProcess::export_format_choices() const
{
    return {tr("EDF"), tr("CSV")};
}

QStringList PostProcess::export_type_choices() const
{
    return {tr("预处理数据"), tr("原始数据")};
}

QStringList PostProcess::export_range_choices() const
{
    return {tr("全记录"), tr("当前片段")};
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

void PostProcess::set_high_pass_enabled(bool value)
{
    if (m_params.high_pass_enabled == value)
        return;
    m_params.high_pass_enabled = value;
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

void PostProcess::set_low_pass_enabled(bool value)
{
    if (m_params.low_pass_enabled == value)
        return;
    m_params.low_pass_enabled = value;
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

void PostProcess::set_artifact_detection_enabled(bool value)
{
    if (m_params.artifact_detection_enabled == value)
        return;
    m_params.artifact_detection_enabled = value;
    invalidate();
}

void PostProcess::set_wave_amplitude_uv(double value)
{
    const double clamped = value <= 0.0 ? 0.0 : std::clamp(value, 5.0, 5000.0);
    if (qFuzzyCompare(m_params.wave_amplitude_uv + 1.0, clamped + 1.0))
        return;
    m_params.wave_amplitude_uv = clamped;
    invalidate();
}

void PostProcess::set_qc_signal_enabled(bool value)
{
    if (m_params.qc_signal_enabled == value)
        return;
    m_params.qc_signal_enabled = value;
    invalidate();
}

void PostProcess::set_qc_range_enabled(bool value)
{
    if (m_params.qc_range_enabled == value)
        return;
    m_params.qc_range_enabled = value;
    invalidate();
}

void PostProcess::set_qc_correlation_enabled(bool value)
{
    if (m_params.qc_correlation_enabled == value)
        return;
    m_params.qc_correlation_enabled = value;
    invalidate();
}

void PostProcess::set_qc_amplitude_ratio(double value)
{
    const double clamped = std::clamp(value, 0.0, 1.0);
    if (qFuzzyCompare(m_params.qc_amplitude_ratio, clamped))
        return;
    m_params.qc_amplitude_ratio = clamped;
    invalidate();
}

void PostProcess::set_qc_correlation(double value)
{
    const double clamped = std::clamp(value, 0.0, 1.0);
    if (qFuzzyCompare(m_params.qc_correlation, clamped))
        return;
    m_params.qc_correlation = clamped;
    invalidate();
}

void PostProcess::set_qc_repair_index(int value)
{
    const int last = static_cast<int>(qc_repair_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.qc_repair_index == clamped)
        return;
    m_params.qc_repair_index = clamped;
    invalidate();
}

void PostProcess::set_export_format_index(int value)
{
    const int last = static_cast<int>(export_format_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.export_format_index == clamped)
        return;
    m_params.export_format_index = clamped;
    emit paramsChanged();
}

void PostProcess::set_export_type_index(int value)
{
    const int last = static_cast<int>(export_type_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.export_type_index == clamped)
        return;
    m_params.export_type_index = clamped;
    emit paramsChanged();
}

void PostProcess::set_export_range_index(int value)
{
    const int last = static_cast<int>(export_range_choices().size()) - 1;
    const int clamped = std::clamp(value, 0, std::max(0, last));
    if (m_params.export_range_index == clamped)
        return;
    m_params.export_range_index = clamped;
    emit paramsChanged();
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
    // 拖动滑块会连投十几个改动：定时器已经在跑就别再重启它。要是每来一个新值都
    // start() 一遍，单次防抖会被一直往后推，滑块不停手就永远不触发 —— 表现成
    //「松手才刷新」。让已排上的那一拍自然到期，拖动过程中也能按节拍更新
    if (!m_debounce->isActive())
        m_debounce->start();
}

void PostProcess::run_recompute()
{
    if (!m_loaded || !m_raw)
        return;

    if (m_watcher.isRunning())
    {
        // 上一轮还没回来。只记一笔「还有新参数没算」，等它一结束由
        // on_recompute_finished 立刻补跑 —— 不在这里重启定时器（那等于再白等
        // 一个防抖周期，拖动时每帧都叠加这个延迟）
        m_pending_recompute = true;
        return;
    }

    m_pending_recompute = false;

    Job job;
    job.generation = ++m_generation;
    job.high_pass_enabled = m_params.high_pass_enabled;
    job.high_pass_hz = m_params.high_pass_hz;
    job.low_pass_enabled = m_params.low_pass_enabled;
    job.low_pass_hz = m_params.low_pass_hz;
    job.notch_enabled = m_params.notch_enabled;
    job.notch_hz = m_params.notch_hz;
    job.reference_index = m_params.reference_index;
    job.downsample_index = m_params.downsample_index;
    job.baseline_enabled = m_params.baseline_enabled;
    job.asr_enabled = m_params.asr_enabled;
    job.asr_cutoff = m_params.asr_cutoff;
    job.artifact_detection_enabled = m_params.artifact_detection_enabled;
    job.wave_amplitude_uv = m_params.wave_amplitude_uv;
    job.qc_signal_enabled = m_params.qc_signal_enabled;
    job.qc_range_enabled = m_params.qc_range_enabled;
    job.qc_correlation_enabled = m_params.qc_correlation_enabled;
    job.qc_amplitude_ratio = m_params.qc_amplitude_ratio;
    job.qc_correlation = m_params.qc_correlation;
    job.qc_repair_index = m_params.qc_repair_index;
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

    // 波形/频谱绘制区宽度：QML 那边报过来的 view_size 已经是**绘制区**尺寸
    //（通道名列与量程列都已扣掉），这里不能再减一次 —— 图比 Image 窄的话，
    // Image.Stretch 会把波形横向拉伸约 5%
    job.wave_width = std::max(64, m_view_size.width());
    job.wave_height = m_view_size.height();
    job.spectrum_width = std::max(64, m_view_size.width());
    job.spectrum_height = std::max(64, m_view_size.height());
    job.events = m_events;
    job.record_info = m_record_info;
    // 把最近一份结果一并交给工作线程：窗口类改动命中指纹时，它只重画波形
    job.previous = m_previous;

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
    // 只认最近派发的那一轮：close() 会 ++m_generation 但不派发新任务，
    // 所以在途的旧结果（generation 已被超过）一律作废，不会被写回界面
    if (result.generation != m_generation)
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
    // 留一份给下一轮做增量重算：窗口类改动（拖时间轴）只要指纹一致，
    // 下一轮就整份复用它、只重画波形，省掉滤波/Welch/相关性那一整条流水线
    m_previous = std::make_shared<const Result>(result);
    m_busy = false;

    // 采样率可能被降采样改过，界面上的「片段」读数要用改过之后的
    m_segment_start = result.segment_start;
    m_segment_seconds = result.segment_seconds;
    m_topo_scale_max = result.topo_scale_max;

    m_status_text = result.ok ? QString() : result.error;
    emit busyChanged();
    emit resultChanged();

    // 计算期间滑块又动过：立刻用最新参数补跑一轮，别让画面停在中间的位置
    if (m_pending_recompute && !m_debounce->isActive())
        m_debounce->start(0);
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

    // 这一轮「重流水线」输入的指纹。拖动时间轴只动 window_start/seconds，指纹不变，
    // 于是下面可以直接复用上一轮结果；改参数（滤波、重参考、片段、质检…）则指纹必变
    Fingerprint fingerprint;
    fingerprint.high_pass_enabled = job.high_pass_enabled;
    fingerprint.high_pass_hz = job.high_pass_hz;
    fingerprint.low_pass_enabled = job.low_pass_enabled;
    fingerprint.low_pass_hz = job.low_pass_hz;
    fingerprint.notch_enabled = job.notch_enabled;
    fingerprint.notch_hz = job.notch_hz;
    fingerprint.reference_index = job.reference_index;
    fingerprint.downsample_index = job.downsample_index;
    fingerprint.baseline_enabled = job.baseline_enabled;
    fingerprint.asr_enabled = job.asr_enabled;
    fingerprint.asr_cutoff = job.asr_cutoff;
    fingerprint.artifact_detection_enabled = job.artifact_detection_enabled;
    fingerprint.qc_signal_enabled = job.qc_signal_enabled;
    fingerprint.qc_range_enabled = job.qc_range_enabled;
    fingerprint.qc_correlation_enabled = job.qc_correlation_enabled;
    fingerprint.qc_amplitude_ratio = job.qc_amplitude_ratio;
    fingerprint.qc_correlation = job.qc_correlation;
    fingerprint.qc_repair_index = job.qc_repair_index;
    fingerprint.segment_start = job.segment_start;
    fingerprint.segment_seconds = job.segment_seconds;
    fingerprint.current_channel = job.current_channel;
    fingerprint.raw = raw.get();
    result.fingerprint = fingerprint;

    // 指纹命中 = 这一轮只有窗口/幅度标尺/事件这类「只进波形、频谱与地形图」的输入变了。
    // 直接拿上一轮的结果当底子，只重画这三样 —— 拖时间轴时真正卡住的滤波、
    // 相关性那一整条流水线（步骤 1–12、16–17）全部跳过
    if (job.previous && job.previous->ok && job.previous->fingerprint == fingerprint
        && job.previous->channels == channels && job.previous->processed_channels == channels)
    {
        Result reused = *job.previous;
        reused.generation = job.generation;

        // 上一轮留了预处理后的整段数据（帧优先交错），反交错回逐通道即可，
        // 不必再跑一遍预处理。float→double 的舍入远小于一个像素，看不出差别
        const int frames = static_cast<int>(reused.processed.size() / channels);
        QVector<QVector<double>> data(channels);
        for (int channel = 0; channel < channels; ++channel)
            data[channel].resize(frames);
        const QVector<float> &processed = reused.processed;
        for (int i = 0; i < frames; ++i)
        {
            const qsizetype base = static_cast<qsizetype>(i) * channels;
            for (int channel = 0; channel < channels; ++channel)
                data[channel][i] = processed.at(base + channel);
        }

        compute_wave(reused, data, reused.processed_rate, job);
        compute_spectrum(reused, data, reused.processed_rate, job);
        compute_topography(reused, data, reused.processed_rate, job);
        return reused;
    }

    // ---------- 1–8、15. 预处理与统计全部走 Python 离线接口 ----------
    //
    // 原来这一大段（高通/低通/陷波、重参考、ASR、降采样、基线校正、修复、Welch、
    // 通道统计、频带占比、相关性、地形图）是 C++ 自己实现的。现在算法统一收到
    // Python 的 eeg_algorithm 离线接口里，这一层只负责把 Job 翻成离线输入、把
    // 结果搬回普通容器；出图、报告、导出仍是下面原有的 C++ 代码，只是数据来源换了。
    //
    // 基线校正由离线层在送数据前按通道扣整段均值完成（见 offlinealgorithm）。
    offlinealgorithm::Input input;
    input.samples = raw->samples;
    input.channels = channels;
    input.frames = source_frames;
    input.sample_rate = source_rate;
    input.high_pass_enabled = job.high_pass_enabled;
    input.high_pass_hz = job.high_pass_hz;
    input.low_pass_enabled = job.low_pass_enabled;
    input.low_pass_hz = job.low_pass_hz;
    input.notch_enabled = job.notch_enabled;
    input.notch_hz = job.notch_hz;
    input.reference_index = job.reference_index;
    input.asr_enabled = job.asr_enabled && job.asr_cutoff > 0;
    input.asr_cutoff = job.asr_cutoff;
    input.artifact_detection_enabled = job.artifact_detection_enabled;
    input.baseline_enabled = job.baseline_enabled;
    input.segment_start = job.segment_start;
    input.segment_seconds = job.segment_seconds;
    input.qc_signal_enabled = job.qc_signal_enabled;
    input.qc_range_enabled = job.qc_range_enabled;
    input.qc_correlation_enabled = job.qc_correlation_enabled;
    input.qc_repair_enabled = job.qc_repair_index > 0;
    input.qc_amplitude_ratio = job.qc_amplitude_ratio;
    input.qc_correlation = job.qc_correlation;

    // 降采样档位 → 目标采样率（分频规则与 downsample_choices() 完全一致）
    int divisor = 1;
    if (job.downsample_index > 0 && source_rate > 0)
    {
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
    input.resample_enabled = divisor > 1;
    input.resample_target_hz =
        divisor > 1 ? static_cast<double>(source_rate) / divisor : 0.0;

    const offlinealgorithm::Output output = offlinealgorithm::run(input);
    if (!output.ok)
    {
        result.error = output.error.isEmpty() ? tr("后处理算法执行失败") : output.error;
        return result;
    }
    // 结果完整性守卫：下面每个通道都要按下标取统计/频谱，任何一路缺失都会越界，
    // 与其在各处零散判空，不如在这里一次把关（copy_* 失败时容器会留空）
    if (output.spectra.size() < channels || output.band_energies.size() != channels
        || output.correlation.size() != channels || output.mean.size() != channels
        || output.std_dev.size() != channels || output.rms.size() != channels
        || output.minimum.size() != channels || output.maximum.size() != channels
        || output.zero_cross.size() != channels || output.skewness.size() != channels
        || output.kurtosis.size() != channels || output.dominant_band.size() != channels
        || output.topo_electrode.size() != kBandCount + 1
        || output.topo_electrode.at(0).size() != channels)
    {
        result.error = tr("算法返回的结果不完整");
        return result;
    }

    // ---------- 处理链 ----------
    // Python 返回的 applied_steps 只作参考；界面文案仍由 C++ 按 Job 参数拼，与
    // 左侧面板的开关一一对应。Python 不做去直流，所以这里也没有那一步
    QStringList chain;
    if (job.high_pass_enabled)
        chain.append(tr("高通 %1 Hz").arg(job.high_pass_hz, 0, 'g', 4));
    if (job.low_pass_enabled)
        chain.append(tr("低通 %1 Hz").arg(job.low_pass_hz, 0, 'g', 4));
    if (job.notch_enabled)
        chain.append(tr("陷波 %1 Hz").arg(job.notch_hz, 0, 'g', 4));
    if (job.asr_enabled && job.asr_cutoff > 0)
        chain.append(tr("ASR 限幅 ×%1").arg(job.asr_cutoff));
    if (divisor > 1)
        chain.append(tr("降采样 %1 Hz").arg(static_cast<double>(source_rate) / divisor, 0, 'g', 4));
    if (job.baseline_enabled)
        chain.prepend(tr("基线校正"));
    if (job.qc_repair_index > 0)
        chain.append(tr("线性插值修复"));

    const int frames = output.sample_count;
    const double sample_rate = output.sample_rate;
    const QVector<QVector<double>> &data = output.processed;
    const int first = output.analysis_first;
    const int count = output.analysis_count;

    result.sample_rate = static_cast<int>(std::lround(sample_rate));
    result.channels = channels;
    result.segment_start = sample_rate > 0.0 ? static_cast<double>(first) / sample_rate : 0.0;
    result.segment_seconds = sample_rate > 0.0 ? static_cast<double>(count) / sample_rate : 0.0;
    result.processing_chain = chain;

    // 留一份预处理后的整段数据供「导出数据」用（见 Result::processed 的说明）。
    // 逐通道 → 帧优先交错，与 .eegbin 是同一种布局，导出的 CSV 按帧走一遍即可
    result.processed_channels = channels;
    result.processed_rate = sample_rate;
    result.processed.resize(static_cast<qsizetype>(frames) * channels);
    for (int i = 0; i < frames; ++i)
        for (int channel = 0; channel < channels; ++channel)
            result.processed[i * channels + channel] = static_cast<float>(data.at(channel).at(i));

    // ---------- 8. 每通道功率谱（Python Welch）----------
    // **一次谐算供全页使用**：频谱页那条曲线、通道表的「优势频带」、统计页的
    // 频带占比、地形图的电极功率，都是它的不同投影
    QVector<Psd> spectra(channels);
    for (int channel = 0; channel < channels; ++channel)
        spectra[channel] = Psd{output.spectra.at(channel).frequencies,
                               output.spectra.at(channel).values};

    // ---------- 9. 通道统计表与各通道频带占比 ----------
    QVariantList channel_stats;
    QVariantList channel_bands;
    QVector<QVector<double>> ratios(channels);
    QVector<ChannelStat> stats(channels);

    for (int channel = 0; channel < channels; ++channel)
    {
        // 统计量直接取算法的结果（口径见 statistics.py）；peak 算法不单列，
        // 用正负极值的绝对值大者，与原先「|value| 的最大值」同义
        ChannelStat stat;
        stat.mean = output.mean.at(channel);
        stat.std_dev = output.std_dev.at(channel);
        stat.rms = output.rms.at(channel);
        stat.minimum = output.minimum.at(channel);
        stat.maximum = output.maximum.at(channel);
        stat.peak = std::max(std::abs(stat.minimum), std::abs(stat.maximum));
        stat.zero_cross = output.zero_cross.at(channel);
        stat.skewness = output.skewness.at(channel);
        stat.kurtosis = output.kurtosis.at(channel);
        stats[channel] = stat;

        // 频带占比来自算法的 band_energies[C,5]（各频段绝对功率），归一化成占比
        const QVector<double> &energies = output.band_energies.at(channel);
        QVector<double> share(kBandCount, 0.0);
        double total = 0.0;
        for (int band = 0; band < kBandCount && band < energies.size(); ++band)
            total += energies.at(band);
        if (total > 0.0)
        {
            for (int band = 0; band < kBandCount && band < energies.size(); ++band)
                share[band] = energies.at(band) / total;
        }
        ratios[channel] = share;

        // 主导频带：算法给的是频段 key（或 "none"），映射回 kBands 的字母 + 名称
        int dominant = 0;
        const QString dominant_key = output.dominant_band.at(channel);
        for (int band = 0; band < kBandCount; ++band)
        {
            if (dominant_key == QString::fromLatin1(kBands[band].key))
            {
                dominant = band;
                break;
            }
        }

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

        // 该通道的五档绝对功率（Welch 平均功率谱密度，µV²/Hz）。统计页右上那五根
        // 大柱随「当前导联」切换，读的就是这里 —— 与整段全通道平均（band_distribution）
        // 同口径、同一份 spectra，只是不做跨通道平均
        QVector<double> band_psd(kBandCount, 0.0);
        for (int band = 0; band < kBandCount; ++band)
            band_psd[band] = band_mean_psd(spectra.at(channel), kBands[band].low_hz,
                                           kBands[band].high_hz);

        QVariantList share_list;
        QVariantList psd_list;
        for (int band = 0; band < kBandCount; ++band)
        {
            share_list.append(share.at(band));
            psd_list.append(band_psd.at(band));
        }
        channel_bands.append(QVariantMap{
            {QStringLiteral("name"), name},
            {QStringLiteral("color"), color},
            {QStringLiteral("ratio"), share_list},
            {QStringLiteral("mean"), psd_list},
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
    // 算法的 correlation_matrix 就是逐通道的 Pearson 相关（np.corrcoef），
    // 直接拿来配色标，不必在这里按定义重算一遍。矩阵数值与窗口无关，
    // 但十字准星跟着「当前导联」走 —— 换导联时整条流水线本来就重算，这里顺带重画出图
    result.correlation_image =
        render_correlation_image(output.correlation, 420, job.current_channel);

    // ---------- 12. 质检 ----------
    // 检测口径（弱信号 / 范围外值 / 低相关）与阈值都交给算法，这里只把返回的片段
    // 裁到所选片段上，折算成报告页与底栏读的同一组计数 —— 各算各的迟早会出现
    // 「报告说 3 个、底栏说 0 个」。片段是整段 sample 索引（start 闭、end 开），
    // 裁剪区间是 [first, first + count)
    int weak_channels = 0;
    int outlier_samples = 0;
    int artifact_samples = 0;
    QStringList low_correlation;
    {
        const int selection_end = first + count;
        const auto overlap = [&](const offlinealgorithm::Segment &segment) {
            return std::min(segment.end_sample, selection_end)
                   - std::max(segment.start_sample, first);
        };

        QSet<int> weak_set;
        QSet<int> low_set;
        for (const offlinealgorithm::Segment &segment : output.quality_segments)
        {
            const int length = overlap(segment);
            if (length <= 0)
                continue;
            if (segment.type == QLatin1String("amplitude_outlier"))
            {
                outlier_samples += length;
            }
            else if (segment.type == QLatin1String("weak_signal")
                     || segment.type == QLatin1String("null_value"))
            {
                const int index = eeg_montage::index_of(segment.channel_name);
                if (index >= 0)
                    weak_set.insert(index);
            }
            else if (segment.type == QLatin1String("low_correlation"))
            {
                const int index = eeg_montage::index_of(segment.channel_name);
                if (index >= 0)
                    low_set.insert(index);
            }
        }

        for (const offlinealgorithm::Segment &segment : output.artifact_segments)
        {
            const int length = overlap(segment);
            if (length > 0)
                artifact_samples += length;
        }

        for (int channel = 0; channel < channels; ++channel)
        {
            if (weak_set.contains(channel))
                ++weak_channels;
            if (low_set.contains(channel))
                low_correlation.append(eeg_montage::channel_name(channel));
        }
    }
    const double outlier_ratio =
        (count > 0 && channels > 0)
            ? static_cast<double>(outlier_samples) / (static_cast<double>(count) * channels)
            : 0.0;

    // ---------- 13. 波形图 ----------
    // 只进本图的那部分输入（窗口、当前导联、幅度标尺、事件）全交给 compute_wave：
    // 拖动时间轴命中指纹的增量重算走的也是它，两条路径共用同一份出图逻辑
    compute_wave(result, data, sample_rate, job);

    // ---------- 14. 频谱图 ----------
    // 频谱按**当前窗口**做 Welch（不再是整段片段），与波形图同一套窗口 —— 拖动
    // 时间轴时频谱随之变化。出图逻辑集中在 compute_spectrum：拖动命中指纹的增量
    // 重算走的也是它，两条路径共用同一份
    compute_spectrum(result, data, sample_rate, job);

    // ---------- 15. 地形图 ----------
    // 六张地形图按**当前窗口**逐通道做 Welch、取各频段的平均功率谱密度（µV²/Hz）作为
    // 电极值，与频谱图同一扇窗、同一份 Welch —— 拖动时间轴时六张图随之变化。出图
    // 逻辑集中在 compute_topography：拖动命中指纹的增量重算走的也是它，两条路径共用同一份
    compute_topography(result, data, sample_rate, job);

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
            {QStringLiteral("note"), tr("顺序：高通 → 低通 → 陷波 → 重参考 → ASR → 降采样 → 基线校正")},
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

        // 伪差检测：只有开关打开时才出一节。关掉时整节不出现，
        // 与左侧面板「伪迹检测」那块开关一致。算法给的是伪差片段，这里报样本点数
        if (job.artifact_detection_enabled)
        {
            sections.append(QVariantMap{
                {QStringLiteral("title"), tr("伪差检测")},
                {QStringLiteral("note"),
                 artifact_samples == 0
                     ? tr("所选片段未检测到伪差片段")
                     : tr("所选片段检测到 %1 个伪差样本点").arg(artifact_samples)},
            });
        }

        // 质检结果：按「质检与修复」那块里启用的检测项拼行
        QVariantList qc_rows;
        if (job.qc_signal_enabled)
            qc_rows.append(QVariantMap{
                {QStringLiteral("label"), tr("弱信号和空值")},
                {QStringLiteral("value"),
                 tr("%1 个通道（1 s 窗标准差 < 1 μV 或含空值）").arg(weak_channels)},
            });
        if (job.qc_range_enabled)
            qc_rows.append(QVariantMap{
                {QStringLiteral("label"), tr("异常 EEG 范围外值")},
                {QStringLiteral("value"),
                 tr("%1 点（占比 %2%，阈值 %3%）")
                     .arg(outlier_samples)
                     .arg(outlier_ratio * 100.0, 0, 'f', 2)
                     .arg(job.qc_amplitude_ratio * 100.0, 0, 'f', 2)},
            });
        if (job.qc_correlation_enabled)
            qc_rows.append(QVariantMap{
                {QStringLiteral("label"), tr("低相关性导联")},
                {QStringLiteral("value"),
                 low_correlation.isEmpty()
                     ? tr("无（阈值 %1）").arg(job.qc_correlation, 0, 'f', 2)
                     : tr("%1 个（阈值 %2）：%3")
                           .arg(low_correlation.size())
                           .arg(job.qc_correlation, 0, 'f', 2)
                           .arg(low_correlation.join(QStringLiteral("、")))},
            });
        const QString repair_note = job.qc_repair_index > 0
            ? tr("修复：线性插值修复（按检测出的伪差/异常片段做线性插值）")
            : tr("修复：off");
        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("质检结果")},
            {QStringLiteral("rows"), qc_rows},
            {QStringLiteral("note"), repair_note},
        });

        // 统计摘要与参考提示：把前面几节收成几句「数字说明了什么、要注意什么」。
        // 只提示、不下诊断 —— 标题特意避开「结论」二字，与页面右上角那句
        // 「仅供医师参考，不作为独立诊断依据」同一个口径
        QVariantList summary_bullets;

        const QString band_letter = QString::fromUtf8(kBands[dominant_band].letter);
        // 主导节律的一句话解读。各频段在脑电里的常见来源不同，读图的人先看到的是
        // 「以什么为主导」，这里顺势给出它的常见成因，而不是复述百分比
        switch (dominant_band)
        {
        case 0:
            summary_bullets.append(tr("所选片段以 %1 慢波为主导，可见于深睡或病理性慢波活动，建议专科随访。")
                                       .arg(band_letter));
            break;
        case 1:
            summary_bullets.append(tr("所选片段以 %1 节律为主导，可见于困倦或深部病变，建议结合临床判断。")
                                       .arg(band_letter));
            break;
        case 2:
            summary_bullets.append(tr("所选片段以 %1 节律为主导，属清醒安静状态下的常见背景节律。")
                                       .arg(band_letter));
            break;
        case 3:
            summary_bullets.append(tr("所选片段以 %1 快波为主导，可见于警觉紧张或受药物影响，建议结合临床判断。")
                                       .arg(band_letter));
            break;
        default:
            summary_bullets.append(tr("所选片段以 %1 快波为主导，易受肌电或环境噪声影响，建议结合原始波形复核。")
                                       .arg(band_letter));
            break;
        }

        // 伪差与信号质量：与「伪差检测」那一节同一组数，关掉时不出这句
        if (job.artifact_detection_enabled)
            summary_bullets.append(
                artifact_samples == 0
                    ? tr("所选片段未检测到明显伪差，信号质量良好。")
                    : tr("所选片段检测到 %1 个伪差样本点，建议人工复核伪差片段。")
                          .arg(artifact_samples));

        // 低相关导联：与「质检结果」里的那一行同源
        if (job.qc_correlation_enabled)
            summary_bullets.append(
                low_correlation.isEmpty()
                    ? tr("各通道间相关性正常，未见明显电极贴合问题。")
                    : tr("通道 %1 与其余通道相关性偏低，建议检查电极贴合。")
                          .arg(low_correlation.join(QStringLiteral("、"))));

        sections.append(QVariantMap{
            {QStringLiteral("title"), tr("统计摘要与参考提示")},
            {QStringLiteral("bullets"), summary_bullets},
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
            tr("%1(第%2/%3)通道   窗口内范围: %4 ~ %5 μV   片段: %6 - %7 s   %8   处理链: %9   质检: 弱信号 %10 · 异常值 %11 点 · 低相关 %12 通道")
                .arg(eeg_montage::channel_name(job.current_channel))
                .arg(job.current_channel + 1)
                .arg(channels)
                .arg(lowest, 0, 'f', 1)
                .arg(highest, 0, 'f', 1)
                .arg(result.segment_start, 0, 'f', 1)
                .arg(result.segment_start + result.segment_seconds, 0, 'f', 1)
                .arg(job.artifact_detection_enabled
                         ? (artifact_samples == 0 ? tr("无伪差") : tr("有伪差"))
                         : tr("伪差检测: 关"))
                .arg(chain.isEmpty() ? tr("未启用") : chain.join(QStringLiteral(" → ")))
                .arg(job.qc_signal_enabled ? QString::number(weak_channels) : tr("关"))
                .arg(job.qc_range_enabled ? QString::number(outlier_samples) : tr("关"))
                .arg(job.qc_correlation_enabled ? QString::number(low_correlation.size()) : tr("关"));
    }

    result.ok = true;
    return result;
}

// 波形图那一张的出图。原来是 compute() 里的步骤 13，提出来是为了让「命中指纹」
// 的增量重算能跳过整条流水线、只调这一个函数。窗口、当前导联、幅度标尺、事件
// 都只进这一张图，所以只重画它
void PostProcess::compute_wave(Result &result, const QVector<QVector<double>> &data,
                               double sample_rate, const Job &job)
{
    const int channels = data.size();
    if (channels <= 0 || data.first().isEmpty() || sample_rate <= 0.0)
        return;

    const int frames = data.first().size();

    // 幅值标尺：用户在「窗口和缩放」里拖过幅度滑块就用他的值，
    // 否则（0 = 自动）按**这一屏的稳健幅度**自动定，向上取整到 1/2/5×10ⁿ。
    // 稳健做法：逐通道取 |value| 的 P95（单点伪差尖峰影响不到它），再逐通道各自定尺
    // —— 直接取全通道最大值的话，少数几路大幅度噪声会把标尺顶到 ±1000，整屏波形
    // 被压成平线
    const int window_first = std::clamp(
        static_cast<int>(std::lround(job.window_start * sample_rate)), 0, frames - 1);
    const int window_last = std::clamp(
        window_first + static_cast<int>(std::lround(job.window_seconds * sample_rate)),
        window_first + 1, frames);

    QVector<double> channel_p95(channels, 0.0);
    QVector<double> magnitudes;
    for (int channel = 0; channel < channels; ++channel)
    {
        const QVector<double> &row = data.at(channel);
        const int stop = std::min(window_last, static_cast<int>(row.size()));
        if (stop <= window_first)
            continue;

        // 与画图时一致：先减掉本窗口均值（显示用去直流）再取幅度。
        // 不减的话，直流偏置与启动漂移会主导 P95，标尺被顶到 ±1000，
        // 脑电被压成一条平线（正是上面那段注释想避免的情况）
        double offset = 0.0;
        for (int i = window_first; i < stop; ++i)
            offset += row.at(i);
        offset /= static_cast<double>(stop - window_first);

        magnitudes.clear();
        magnitudes.reserve(stop - window_first);
        for (int i = window_first; i < stop; ++i)
            magnitudes.append(std::abs(row.at(i) - offset));
        if (magnitudes.isEmpty())
            continue;

        const int count = static_cast<int>(magnitudes.size());
        const int rank = std::clamp(
            static_cast<int>(std::lround(0.95 * (count - 1))), 0, count - 1);
        std::nth_element(magnitudes.begin(), magnitudes.begin() + rank, magnitudes.end());
        channel_p95[channel] = magnitudes.at(rank);
    }

    // 逐通道独立标尺：每一路各自向上取整到 1/2/5×10ⁿ。
    // 统一标尺时，噪声大的通道会把标尺顶高、把脑电压平；反过来用脑电的标尺
    // 又会让噪声通道削成方块 —— 各定各的，两种情况都不会出现
    QVector<double> channel_range_uv;
    channel_range_uv.reserve(channels);
    for (int channel = 0; channel < channels; ++channel)
    {
        if (job.wave_amplitude_uv > 0.0)
        {
            // 用户拖过幅度滑块：仍然全通道统一用他给的值
            channel_range_uv.append(job.wave_amplitude_uv);
            continue;
        }

        const double p95 = channel_p95.at(channel);
        const double exponent =
            p95 > 0.0 ? std::pow(10.0, std::floor(std::log10(p95))) : 1.0;
        const double normalized = exponent > 0.0 ? p95 / exponent : 1.0;
        // 1 / 2 / 5 / 10 四档。**不能只给到 5**：归一化值落在 (5,10) 时取 5 会
        // 算出一个比实际峰值还小的标尺，波形顶部会被削平
        const double step = normalized <= 1.0 ? 1.0
                          : (normalized <= 2.0 ? 2.0 : (normalized <= 5.0 ? 5.0 : 10.0));
        channel_range_uv.append(std::max(25.0, step * exponent));
    }

    // 右侧 +N/0/−N 标注只画在当前导联那条泳道上，所以取当前导联的标尺
    result.wave_range_uv = channel_range_uv.value(job.current_channel, 25.0);

    result.wave_image = render_wave_image(data, sample_rate, job.window_start,
                                          job.window_seconds, job.current_channel,
                                          channel_range_uv, job.wave_width, job.events);
}

// 频谱图那一张的出图。原来曲线取自 Python 对**分析片段**（整段）算的 Welch，窗口动
// 它不动；现在改成对**当前窗口**做 Welch —— 与波形图同一扇窗，拖时间轴时两者一起变。
// 窗口在预处理后的采样率上换算，与 compute_wave 取 window_first/window_last 的口径一致；
// welch_psd 的段长/重叠/窗函数也与算法侧 spectrum_core 对齐
void PostProcess::compute_spectrum(Result &result, const QVector<QVector<double>> &data,
                                   double sample_rate, const Job &job)
{
    const int channels = data.size();
    if (channels <= 0 || sample_rate <= 0.0)
        return;
    if (job.current_channel < 0 || job.current_channel >= channels)
        return;

    const QVector<double> &row = data.at(job.current_channel);
    const int frames = row.size();
    if (frames < 4)
        return;

    const int window_first = std::clamp(
        static_cast<int>(std::lround(job.window_start * sample_rate)), 0, frames - 1);
    const int window_last = std::clamp(
        window_first + static_cast<int>(std::lround(job.window_seconds * sample_rate)),
        window_first + 1, frames);

    const Psd psd = welch_psd(row.constData() + window_first, window_last - window_first,
                              sample_rate);

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

// 六张地形图那一批的出图。原来电极值取自 Python 对**分析片段**（整段）算的各频段电极
// RMS，窗口动它不动；现在改成对**当前窗口**逐通道做 Welch，再取各频段的平均功率谱密度
// （µV²/Hz）当电极值 —— 与频谱图同一扇窗、同一份 welch_psd，拖时间轴时六张图一起变。
// 每通道只需一次 Welch，六档频段都从这一份谱上取均值；网格插值/配色仍用本页原有实现
void PostProcess::compute_topography(Result &result, const QVector<QVector<double>> &data,
                                     double sample_rate, const Job &job)
{
    const int channels = data.size();
    if (channels <= 0 || sample_rate <= 0.0)
        return;

    const int frames = data.first().size();
    if (frames < 4)
        return;

    // 窗口换算口径与 compute_wave / compute_spectrum 完全一致
    const int window_first = std::clamp(
        static_cast<int>(std::lround(job.window_start * sample_rate)), 0, frames - 1);
    const int window_last = std::clamp(
        window_first + static_cast<int>(std::lround(job.window_seconds * sample_rate)),
        window_first + 1, frames);
    const int window_length = window_last - window_first;

    QVector<QPointF> positions;
    positions.reserve(channels);
    const eeg_montage::Electrode *table = eeg_montage::electrodes();
    for (int channel = 0; channel < channels; ++channel)
    {
        positions.append(channel < eeg_montage::kChannelCount
                             ? QPointF(table[channel].x, table[channel].y)
                             : QPointF(0.0, 0.0));
    }
    normalize_positions(&positions);

    // 每通道一次窗口 Welch；六档频段的电极值都是这份谱在频段内的均值
    QVector<Psd> spectra(channels);
    for (int channel = 0; channel < channels; ++channel)
        spectra[channel] = welch_psd(data.at(channel).constData() + window_first, window_length,
                                     sample_rate);

    QVector<QImage> images;
    images.reserve(kBandCount + 1);
    QVariantList topo_stats;
    double full_scale = 0.0;
    for (int band = 0; band < kBandCount + 1; ++band)
    {
        // band 0 是「全频段」（取五档的并集 0.5–45），1..5 依次是 δ/θ/α/β/γ
        const double low_hz = band == 0 ? kFullBandLowHz : kBands[band - 1].low_hz;
        const double high_hz = band == 0 ? kFullBandHighHz : kBands[band - 1].high_hz;

        QVector<double> electrode_values(channels, 0.0);
        for (int channel = 0; channel < channels; ++channel)
            electrode_values[channel] = band_mean_psd(spectra.at(channel), low_hz, high_hz);

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
        images.append(render_topography_image(grid_values, kTopoGrid, scale));

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
            full_scale = scale;
    }

    result.topo_images = images;
    result.topo_stats = topo_stats;
    result.topo_scale_max = full_scale;
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

// EDF 的字段都是定长 ASCII：短的右侧补空格，长的截断
QByteArray edf_field(const QString &text, int width)
{
    QByteArray bytes = text.toLatin1();
    if (bytes.size() > width)
        bytes.truncate(width);
    while (bytes.size() < width)
        bytes.append(' ');
    return bytes;
}

// 写一段 EDF（非 EDF+：不额外塞注释通道）。每个 data record 固定 1 秒，
// 每路每 record 的采样数 = 采样率，末尾不足的补零。
// samples 为帧优先交错（与 .eegbin / Result::processed 一致），单位 µV
bool write_edf(const QString &path, const QString &patient, const QString &recording,
               qint64 start_utc_ms, int channels, double rate, const QVector<float> &samples,
               qsizetype first_frame, qsizetype frames, QString *error)
{
    if (channels <= 0 || rate <= 0.0 || frames <= 0)
    {
        *error = QObject::tr("没有可导出的数据");
        return false;
    }

    const int samples_per_record = std::max(1, static_cast<int>(std::lround(rate)));
    const qsizetype data_records =
        std::max<qsizetype>(1, (frames + samples_per_record - 1) / samples_per_record);

    // 每路的物理量程：按导出范围的实际最小/最大值定，映射到 ±32767
    QVector<double> phys_min(channels, 0.0);
    QVector<double> phys_max(channels, 1.0);
    for (int channel = 0; channel < channels; ++channel)
    {
        double lo = std::numeric_limits<double>::max();
        double hi = std::numeric_limits<double>::lowest();
        for (qsizetype i = 0; i < frames; ++i)
        {
            const double value = samples.at((first_frame + i) * channels + channel);
            lo = std::min(lo, value);
            hi = std::max(hi, value);
        }
        if (!(hi > lo))
        {
            lo = -1.0;
            hi = 1.0;
        }
        phys_min[channel] = lo;
        phys_max[channel] = hi;
    }

    const qint64 header_bytes = static_cast<qint64>(256) * (channels + 1);

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
    {
        *error = QObject::tr("无法写入导出文件：%1").arg(file.errorString());
        return false;
    }

    QDateTime start = QDateTime::fromMSecsSinceEpoch(start_utc_ms, Qt::UTC);

    QByteArray header;
    header += edf_field(QStringLiteral("0"), 8);                       // version
    header += edf_field(patient, 80);                                  // patient id
    header += edf_field(recording, 80);                                // recording id
    header += edf_field(start.toString(QStringLiteral("dd.MM.yy")), 8); // start date
    header += edf_field(start.toString(QStringLiteral("hh.mm.ss")), 8); // start time
    header += edf_field(QString::number(header_bytes), 8);             // header bytes
    header += edf_field(QString(44, QLatin1Char(' ')), 44);            // reserved
    header += edf_field(QString::number(data_records), 8);             // num data records
    header += edf_field(QStringLiteral("1"), 8);                       // record duration (s)
    header += edf_field(QString::number(channels), 4);                 // num signals

    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(eeg_montage::channel_name(channel), 16);
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString(), 80);                            // transducer
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QStringLiteral("uV"), 8);                  // physical dimension
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString::number(phys_min.at(channel), 'f', 1), 8);
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString::number(phys_max.at(channel), 'f', 1), 8);
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QStringLiteral("-32767"), 8);              // digital min
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QStringLiteral("32767"), 8);               // digital max
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString(), 80);                            // prefiltering
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString::number(samples_per_record), 8);
    for (int channel = 0; channel < channels; ++channel)
        header += edf_field(QString(), 32);                            // reserved

    // 头部必须正好 256×(ns+1) 字节，短了补齐
    header.resize(header_bytes, ' ');
    file.write(header);

    // 数据区：按 record → 通道 → 记录内采样 交错
    QByteArray payload;
    payload.reserve(static_cast<qsizetype>(data_records) * channels * samples_per_record * 2);
    for (qsizetype record = 0; record < data_records; ++record)
    {
        for (int channel = 0; channel < channels; ++channel)
        {
            const double lo = phys_min.at(channel);
            const double span = phys_max.at(channel) - lo;
            for (int s = 0; s < samples_per_record; ++s)
            {
                const qsizetype frame = record * samples_per_record + s;
                double value = 0.0;
                if (frame < frames)
                    value = samples.at((first_frame + frame) * channels + channel);
                const double normalized = span > 0.0 ? (value - lo) / span : 0.5;
                const int digital = std::clamp(
                    static_cast<int>(std::lround(normalized * 65534.0 - 32767.0)), -32768, 32767);
                const qint16 raw = static_cast<qint16>(digital);
                payload.append(static_cast<char>(raw & 0xFF));
                payload.append(static_cast<char>((raw >> 8) & 0xFF));
            }
        }
    }
    file.write(payload);

    if (!file.commit())
    {
        *error = QObject::tr("无法写入导出文件：%1").arg(file.errorString());
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

    // 「脑电数据导出」三下选择：格式 / 类型 / 范围
    const bool as_raw = m_params.export_type_index == 1;   // 0=预处理, 1=原始
    const bool as_edf = m_params.export_format_index == 0; // 0=EDF, 1=CSV
    const bool as_segment = m_params.export_range_index == 1; // 0=全记录, 1=当前片段

    QVector<float> samples;
    int channels = 0;
    double rate = 0.0;
    qint64 start_ms = 0;
    double seg_start = 0.0;
    double seg_seconds = 0.0;
    if (as_raw)
    {
        const std::shared_ptr<const RawData> raw = m_raw;
        if (!raw || raw->samples.isEmpty())
            return export_result(false, tr("还没有可导出的原始数据"));
        samples = raw->samples;
        channels = raw->channels;
        rate = raw->sample_rate;
        start_ms = raw->start_utc_ms;
        const QMutexLocker locker(&m_mutex);
        seg_start = m_result.segment_start;
        seg_seconds = m_result.segment_seconds;
    }
    else
    {
        const QMutexLocker locker(&m_mutex);
        samples = m_result.processed;
        channels = m_result.processed_channels;
        rate = m_result.processed_rate;
        seg_start = m_result.segment_start;
        seg_seconds = m_result.segment_seconds;
        start_ms = m_raw ? m_raw->start_utc_ms : 0;
    }
    if (samples.isEmpty() || channels <= 0 || rate <= 0.0)
        return export_result(false, tr("还没有可导出的处理结果，请先等分析完成"));

    qsizetype first_frame = 0;
    qsizetype frames = samples.size() / channels;
    if (as_segment)
    {
        first_frame = std::clamp(
            static_cast<qsizetype>(std::lround(seg_start * rate)), qsizetype(0),
            std::max<qsizetype>(0, frames - 1));
        const qsizetype seg_frames = std::clamp(
            static_cast<qsizetype>(std::lround(seg_seconds * rate)), qsizetype(1),
            frames - first_frame);
        frames = seg_frames;
    }

    const QString typeLabel = as_raw ? tr("原始数据") : tr("预处理数据");
    const QString rangeLabel = as_segment ? tr("片段") : tr("全记录");

    if (as_edf)
    {
        const QString target = QDir(directory).filePath(
            QStringLiteral("%1_%2_%3.edf").arg(m_record_no, typeLabel, rangeLabel));
        const QString patient = m_info.value(QStringLiteral("patient")).toString();
        if (!write_edf(target, patient, m_record_no, start_ms, channels, rate, samples,
                       first_frame, frames, &error))
            return export_result(false, error);
        return export_result(true, tr("已导出 %1：%2").arg(typeLabel, target), target);
    }

    const QString target = QDir(directory).filePath(
        QStringLiteral("%1_%2_%3.csv").arg(m_record_no, typeLabel, rangeLabel));
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

    for (qsizetype i = 0; i < frames; ++i)
    {
        out << QString::number((first_frame + i) / rate, 'f', 4);
        for (int channel = 0; channel < channels; ++channel)
            out << ',' << QString::number(samples.at((first_frame + i) * channels + channel), 'f', 2);
        out << '\n';
    }

    file.close();
    return export_result(true, tr("已导出 %1：%2").arg(typeLabel, target), target);
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

        const QVariantList bullets = section.value(QStringLiteral("bullets")).toList();
        for (const QVariant &bullet_item : bullets)
            out << QStringLiteral("  · ") << bullet_item.toString() << '\n';

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
