// pybind11 必须先于任何 Qt 头文件包含：Qt 的 qtmetamacros.h 会把 `slots` 定义成宏
// （`#define slots Q_SLOTS`），一旦先包含 Qt 头，Python 的 `PyType_Slot *slots;`
// 就会被替换成 `PyType_Slot *Q_SLOTS;` 而编译失败。不要调整这个顺序。
#include <pybind11/embed.h>
#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QStringList>
#include <QStandardPaths>

// 只为了自检里那次 SetConsoleOutputCP：控制台默认是 cp936，
// 中文输出会乱码。WIN32_LEAN_AND_MEAN 用来躲开 windows.h 与 Qt 的符号冲突
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "eegmontage.h"
#include "pythonengine.h"
#include "pythontypes.h"

#include <cstring>
#include <string>

namespace py = pybind11;

// 兜底默认值。正常情况下由 CMake 的 CACHE 变量经 target_compile_definitions 注入，
// 运行时的同名环境变量优先级更高（见 resolve_dir）
#ifndef PYTHON_ROOT_DIR
#  define PYTHON_ROOT_DIR "C:/Program Files/Python311"
#endif

#ifndef PYTHON_VENV_DIR
#  define PYTHON_VENV_DIR "D:/myproject/eeg-algorithm/PythonScript/venv"
#endif

// 算法包源码根目录。注意它是 **src 布局**（源码在 <PythonScript>/src/eeg_algorithm），
// 而 venv 里并没有装 eeg_algorithm，所以必须把 src 这一层加进 sys.path，
// 不能像参考实现那样只加项目根目录（它的实时滤波模块是平铺在顶层的）。
#ifndef EEG_ALGO_SRC_DIR
#  define EEG_ALGO_SRC_DIR "D:/myproject/eeg-algorithm/PythonScript/src"
#endif

// Python 项目根目录。实时滤波模块 Realtime_IIR.py 平铺在这里（不在 src 那一层），
// 显示通路要直接 import 它，所以这一层也得进 sys.path
#ifndef PYTHON_PROJECT_DIR
#  define PYTHON_PROJECT_DIR "D:/myproject/eeg-algorithm/PythonScript"
#endif

// 宿主侧适配层 eeg_bridge.py 所在目录
#ifndef EEG_BRIDGE_DIR
#  define EEG_BRIDGE_DIR "D:/myproject/eeg-algorithm/KSCEEGClient/python"
#endif

namespace
{

// 解析顺序：环境变量 > exe 同目录下的约定位置 > 编译期默认值。
//
// 中间那层是给打包分发用的：把 Python 运行期、venv、算法包放到 exe 旁边，
// 整个目录拷到别的机器就能跑。开发机的构建目录旁边没有这几个目录，
// 自然落到编译期默认值，两者互不干扰。
QString resolve_dir(const char *env_name, const char *portable_name, const QString &fallback)
{
    const QByteArray from_env = qgetenv(env_name);
    if (!from_env.isEmpty())
    {
        return QDir::fromNativeSeparators(QString::fromLocal8Bit(from_env));
    }

    const QString portable = QCoreApplication::applicationDirPath()
                             + QLatin1Char('/') + QLatin1String(portable_name);
    if (QDir(portable).exists())
    {
        return portable;
    }

    return QDir::fromNativeSeparators(fallback);
}

// 名字一律带 resolve_ 前缀：这几个自由函数一旦叫 venv_dir() / bridge_dir()，
// PythonEngine 里同名的**成员函数**就会把它们在类作用域内遮蔽掉，
// `m_impl->resolved_bridge_dir = bridge_dir();` 会变成「自己赋值给自己」，
// 结果是空串而且不报任何错。
QString resolve_python_root_dir()
{
    return resolve_dir("PYTHON_ROOT_DIR", "python", QStringLiteral(PYTHON_ROOT_DIR));
}

QString resolve_venv_dir()
{
    return resolve_dir("PYTHON_VENV_DIR", "venv", QStringLiteral(PYTHON_VENV_DIR));
}

QString resolve_algo_src_dir()
{
    return resolve_dir("EEG_ALGO_SRC_DIR", "app", QStringLiteral(EEG_ALGO_SRC_DIR));
}

QString resolve_python_project_dir()
{
    return resolve_dir("PYTHON_PROJECT_DIR", "project", QStringLiteral(PYTHON_PROJECT_DIR));
}

QString resolve_bridge_dir()
{
    return resolve_dir("EEG_BRIDGE_DIR", "bridge", QStringLiteral(EEG_BRIDGE_DIR));
}

// Python 侧日志目录。算法包约定「目录由 C++ 传入，Python 不硬编码用户目录」，
// 所以这里统一给出产品自己的位置。
QString log_dir()
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    if (base.isEmpty())
    {
        base = QDir::tempPath() + QStringLiteral("/EEG-KSC");
    }
    return QDir::fromNativeSeparators(base) + QStringLiteral("/logs");
}

// 把嵌入式解释器配置成「就以这个 venv 的身份运行」。必须在 py::scoped_interpreter 之前调用。
//
// 关键在于让 sys.executable 指向 venv 的 python.exe：CPython 的 site.py 会以它为起点
// 向上找 pyvenv.cfg（Scripts 的父目录正好是 venv 根），找到之后自己得出
// sys.prefix = venv、base_prefix = 基础安装、ENABLE_USER_SITE = False。
// 于是「只用 venv，系统安装与用户级的 site-packages 都不可见」全由 CPython 保证，
// 我们不必再去手工增删 sys.path。
//
// 注意：config 由 pybind11 在初始化之后自行 PyConfig_Clear，调用方不要再碰它。
void prepare_python_config(PyConfig &config)
{
    // 不解析命令行：sys.argv 本来是给宿主程序的，
    // 交给 Python 解析会把 Qt 自己的参数当成脚本参数混进来
    config.parse_argv = 0;

    // 关掉用户级 site-packages。venv 身份本身也会关掉它，这里再显式写一次，
    // 不去依赖那条路径
    config.user_site_directory = 0;

    // home 指向基础安装：解释器本体（python311.dll、标准库）在那里，链接期链接的
    // 也是它 —— venv 里没有这些。直接写进 config 而不是设 PYTHONHOME 环境变量：
    // qputenv 改的是进程环境块，而解释器读环境变量走的是 CRT 那份副本，本机实测并不可靠
    const QString root = resolve_python_root_dir();
    if (!QDir(root).exists())
    {
        qWarning().noquote() << "[python] Python 安装目录不存在:" << root;
    }
    else
    {
        const std::wstring home = QDir::toNativeSeparators(root).toStdWString();
        const PyStatus status = PyConfig_SetString(&config, &config.home, home.c_str());
        if (PyStatus_Exception(status) != 0)
        {
            qWarning().noquote() << "[python] 设置 PyConfig.home 失败:" << status.err_msg;
        }
    }

    // executable 指向 venv 的 python.exe —— 「整个运行期是 venv」就落在这一行。
    // 判据是 pyvenv.cfg 是否存在，而不是 Scripts/python.exe：site.py 认 venv
    // 靠的就是从 sys.executable 的目录向上找这个文件，它才是「这是个 venv」的实际标志
    const QString venv_config = resolve_venv_dir() + QStringLiteral("/pyvenv.cfg");
    if (!QFileInfo::exists(venv_config))
    {
        // 不静默回退到系统解释器：那样跑的其实不是 venv，必须说出来
        qWarning().noquote() << "[python] venv 缺少 pyvenv.cfg，无法以 venv 身份运行:"
                             << venv_config;
        return;
    }

    const QString venv_python = resolve_venv_dir() + QStringLiteral("/Scripts/python.exe");
    const std::wstring executable = QDir::toNativeSeparators(venv_python).toStdWString();
    const PyStatus status = PyConfig_SetString(&config, &config.executable, executable.c_str());
    if (PyStatus_Exception(status) != 0)
    {
        qWarning().noquote() << "[python] 设置 PyConfig.executable 失败:" << status.err_msg;
    }
}

// 把算法包源码目录、Python 项目根目录与适配层目录加进 sys.path。
// venv / 用户级 / 系统级的 site-packages 都不在这里管 —— 那些由 venv 身份决定。
//
// 项目根目录是给显示通路的实时滤波模块 Realtime_IIR.py 用的（它平铺在顶层）；
// 顺序上适配层放最前：它是最不可能与别的模块重名的那个名字。
void setup_python_path()
{
    const QStringList dirs = {resolve_bridge_dir(), resolve_python_project_dir(),
                              resolve_algo_src_dir()};

    try
    {
        const py::module_ sys = py::module_::import("sys");
        for (const QString &dir : dirs)
        {
            if (!QDir(dir).exists())
            {
                qWarning().noquote() << "[python] 路径不存在，import 可能失败:" << dir;
            }
            sys.attr("path").attr("insert")(0, dir.toStdString());
        }
    }
    catch (const std::exception &exc)
    {
        // error_already_set 与 cast_error 都派生自 std::exception，一并接住
        qWarning().noquote() << "[python] 配置 sys.path 失败:" << exc.what();
    }
}

// 启动自检：确认解释器与依赖都可用。失败只告警不中断，
// 让界面能起来并把错误显示给用户，而不是启动即崩
void log_python_environment()
{
    try
    {
        const py::module_ sys = py::module_::import("sys");
        qInfo().noquote() << "[python] version    :"
                          << QString::fromStdString(sys.attr("version").attr("split")().cast<py::list>()[0].cast<std::string>());
        qInfo().noquote() << "[python] executable :"
                          << QString::fromStdString(sys.attr("executable").cast<std::string>());
        qInfo().noquote() << "[python] prefix     :"
                          << QString::fromStdString(sys.attr("prefix").cast<std::string>());
        qInfo().noquote() << "[python] base_prefix:"
                          << QString::fromStdString(sys.attr("base_prefix").cast<std::string>());

        const QStringList modules = {QStringLiteral("numpy"), QStringLiteral("scipy"),
                                     QStringLiteral("eeg_algorithm"), QStringLiteral("eeg_bridge"),
                                     QStringLiteral("Realtime_IIR")};
        for (const QString &name : modules)
        {
            try
            {
                const py::module_ module = py::module_::import(name.toStdString().c_str());
                const py::object file = module.attr("__file__");
                qInfo().noquote() << QStringLiteral("[python] %1:").arg(name, -14)
                                  << QString::fromStdString(py::str(file).cast<std::string>());
            }
            catch (const std::exception &exc)
            {
                qWarning().noquote() << QStringLiteral("[python] %1: 导入失败 ->").arg(name, -14)
                                     << QString::fromUtf8(exc.what());
            }
        }
    }
    catch (const std::exception &exc)
    {
        qWarning().noquote() << "[python] 环境自检失败:" << QString::fromUtf8(exc.what());
    }
}

} // namespace

// ==================== Impl ====================

struct PythonEngine::Impl
{
    // 声明顺序即析构逆序：gil_release 先析构（主线程重新持有 GIL），
    // 然后才是 interpreter（Py_FinalizeEx）。反过来的话 finalize 会撞上
    // 一个还持有 GIL 状态的线程。
    std::unique_ptr<py::scoped_interpreter> interpreter;
    std::unique_ptr<py::gil_scoped_release> gil_release;

    QString api_version;
    QString resolved_project_dir;
    QString resolved_bridge_dir;
    QString resolved_venv_dir;

    // 显示滤波的「待预热」标记：参数刚配置好、历史状态刚清空时为 true。
    // 下一块数据进来时用它的首帧把状态填到稳态（思路同参考实现的 _zi_seed）
    bool display_filter_seed_pending = false;
};

PythonEngine::PythonEngine()
    : m_impl(std::make_unique<Impl>())
{
}

PythonEngine::~PythonEngine()
{
    shutdown();
}

bool PythonEngine::start(QString *error_message)
{
    if (m_impl->interpreter != nullptr)
    {
        return true;
    }

    // PyConfig 必须在创建解释器之前建好；它由 pybind11 在初始化之后自行 PyConfig_Clear
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    prepare_python_config(config);

    try
    {
        // 第四个实参 add_program_dir_to_path = false：不把 exe 所在目录或当前目录
        // 塞进 sys.path，我们只显式加算法包与适配层目录（见 setup_python_path）
        m_impl->interpreter = std::make_unique<py::scoped_interpreter>(&config, 0, nullptr, false);
    }
    catch (const std::exception &exc)
    {
        if (error_message != nullptr)
        {
            *error_message = QString::fromUtf8(exc.what());
        }
        qWarning().noquote() << "[python] 解释器初始化失败:" << QString::fromUtf8(exc.what());
        return false;
    }

    {
        // 这一段必须持 GIL：Py_Initialize 之后 GIL 一直由调用它的（本）主线程持有
        const py::gil_scoped_acquire gil;
        setup_python_path();
        log_python_environment();

        try
        {
            const py::object bridge = py::module_::import("eeg_bridge");
            m_impl->api_version = QString::fromStdString(
                bridge.attr("api_version")().cast<std::string>());
        }
        catch (const std::exception &exc)
        {
            if (error_message != nullptr)
            {
                *error_message = QString::fromUtf8(exc.what());
            }
            qWarning().noquote() << "[python] 读取算法接口版本失败:" << QString::fromUtf8(exc.what());
        }
    }

    // 让出 GIL。不主动让出的话，算法线程第一次 gil_scoped_acquire 就会永远阻塞在那里，
    // 表现为「界面正常但算法一个结果都不出」，而且没有任何报错。
    // 让出之后，GUI 线程自己的 Python 调用（自检、日志拉取）各自现取现还。
    //
    // 这个对象要活到 shutdown() —— 提前析构会让主线程重新持有 GIL，算法线程又被挡住。
    m_impl->gil_release = std::make_unique<py::gil_scoped_release>();

    m_impl->resolved_project_dir = resolve_algo_src_dir();
    m_impl->resolved_bridge_dir = resolve_bridge_dir();
    m_impl->resolved_venv_dir = resolve_venv_dir();
    return true;
}

void PythonEngine::shutdown()
{
    if (m_impl->interpreter == nullptr)
    {
        return;
    }

    // 收尾 API：刷新并关闭算法侧的日志线程。必须在解释器还活着的时候做 ——
    // finalize 之后这个模块就取不到了。取不到就跳过，不能因为它失败就卡住退出
    {
        const py::gil_scoped_acquire gil;
        try
        {
            if (py::module_::import("sys").attr("modules").contains("eeg_bridge"))
            {
                py::module_::import("eeg_bridge").attr("close_api")();
            }
        }
        catch (const std::exception &exc)
        {
            qWarning().noquote() << "[python] 关闭算法 API 时出错（不影响退出）:"
                                 << QString::fromUtf8(exc.what());
        }
    }

    // 逆序拆：先还 GIL，再 finalize。调用方必须已经 wait() 完所有碰 Python 的线程 ——
    // 否则 finalize 会与还在析构 py::object 的线程抢生命周期
    m_impl->gil_release.reset();
    m_impl->interpreter.reset();
}

bool PythonEngine::is_running() const
{
    return m_impl->interpreter != nullptr;
}

QString PythonEngine::api_version() const
{
    return m_impl->api_version;
}

QString PythonEngine::project_dir() const
{
    return m_impl->resolved_project_dir;
}

QString PythonEngine::bridge_dir() const
{
    return m_impl->resolved_bridge_dir;
}

QString PythonEngine::venv_dir() const
{
    return m_impl->resolved_venv_dir;
}

// ==================== 显示通路的独立滤波 ====================

namespace
{

// 显示侧滤波器阶数与采样率。采样率必须与 Realtime_IIR.py 的模块级 fs 一致（也是 1000），
// 否则同一个 [低, 高] 区间两边算出的归一化截止频率不同、系数也就对不上。
//
// 阶数取 2：显示只要求「看起来是被滤过的」，阶数越低启动瞬态越短。
// 模块自己的 order（4）是它独立跑时的默认值，显示通路不用它
constexpr int kDisplayFilterOrder = 2;
constexpr double kDisplayFilterFs = 1000.0;

// 用本块的首帧把 Realtime_IIR 的历史 buffer 填到稳态，免得波形在启动/改参瞬间
// 冲出一个要衰减好几秒的包（思路同参考实现的 _zi_seed）。
//
// 依据：输入恒为 x0 时，滤波器稳态输出就是直流增益 x0 * H(0) = x0 * sum(b) / sum(a)。
// Realtime_IIR 的 x_buffer[ch, :] 是「越靠后越新」的输入历史（内部做 ::-1 取用），
// 所以整行填 x0 就等价于「过去一直是 x0」；y_buffer 同理整行填那个稳态输出
void seed_display_filter_history(const py::module_ &np, const py::module_ &iir,
                                 const py::array_t<float> &input, int channels)
{
    const py::object b = iir.attr("b");
    const py::object a = iir.attr("a");

    // 首帧，形状 (channels, 1)，后面按列广播
    const py::object first_frame = input.attr("__getitem__")(py::slice(0, channels, 1))
                                       .attr("reshape")(py::make_tuple(channels, 1));

    const py::object dc_gain = np.attr("divide")(np.attr("sum")(b), np.attr("sum")(a));

    iir.attr("x_buffer") = np.attr("tile")(first_frame, py::make_tuple(1, py::len(b)));
    iir.attr("y_buffer") =
        np.attr("tile")(first_frame, py::make_tuple(1, py::len(a) - 1)).attr("__mul__")(dc_gain);
}

} // namespace

bool PythonEngine::configure_display_filter(const ProcessingParams &params, int channels,
                                            QString *error_message)
{
    if (m_impl->interpreter == nullptr)
    {
        if (error_message != nullptr)
        {
            *error_message = QStringLiteral("Python 解释器未启动");
        }
        return false;
    }
    if (channels <= 0)
    {
        if (error_message != nullptr)
        {
            *error_message = QStringLiteral("通道数非法");
        }
        return false;
    }

    const py::gil_scoped_acquire gil;
    try
    {
        using namespace py::literals;   // btype_a / fs_a 这些字面量

        const py::module_ np = py::module_::import("numpy");
        const py::module_ signal = py::module_::import("scipy.signal");
        const py::module_ iir = py::module_::import("Realtime_IIR");

        // ---- 主滤波：高通 / 低通 → 一个 butter 系数对 ----
        // Realtime_IIR 只提供 IIR_weights()（带通），所以这里自己决定 btype：
        //   两个都开 → bandpass(低, 高)；只开一个 → highpass / lowpass；全关 → 直通
        const bool has_high = params.high_pass_enabled;
        const bool has_low = params.low_pass_enabled;
        const double high_hz = params.high_pass_low_hz;
        const double low_hz = params.low_pass_high_hz;

        py::object b;
        py::object a;
        if (has_high && has_low && high_hz < low_hz)
        {
            const py::tuple coeffs = signal.attr("butter")(
                kDisplayFilterOrder, py::make_tuple(high_hz, low_hz), "btype"_a = "bandpass",
                "fs"_a = kDisplayFilterFs);
            b = coeffs[0];
            a = coeffs[1];
        }
        else if (has_high)
        {
            const py::tuple coeffs = signal.attr("butter")(
                kDisplayFilterOrder, high_hz, "btype"_a = "highpass", "fs"_a = kDisplayFilterFs);
            b = coeffs[0];
            a = coeffs[1];
        }
        else if (has_low)
        {
            const py::tuple coeffs = signal.attr("butter")(
                kDisplayFilterOrder, low_hz, "btype"_a = "lowpass", "fs"_a = kDisplayFilterFs);
            b = coeffs[0];
            a = coeffs[1];
        }
        else
        {
            // 直通：b = a = [1] 时差分方程退化成 y = x
            b = np.attr("array")(py::make_tuple(1.0));
            a = np.attr("array")(py::make_tuple(1.0));
        }

        // ---- 陷波：由 [低, 高] 区间反推中心频率与 Q ----
        // 界面给的是区间而不是 Q，这里按 Q = 中心频率 / 带宽 换算，区间越窄陷波越尖锐
        const bool has_notch = params.notch_enabled;
        const double notch_center = (params.notch_low_hz + params.notch_high_hz) / 2.0;
        const double notch_width = params.notch_high_hz - params.notch_low_hz;

        if (has_notch && notch_width > 0.0 && notch_center > 0.0)
        {
            const py::tuple coeffs = signal.attr("iirnotch")(
                notch_center, notch_center / notch_width, "fs"_a = kDisplayFilterFs);
            // Realtime_IIR 只认一对 b/a，串联两个滤波器等于把系数做多项式相乘：
            // H_total(z) = H_main(z) * H_notch(z)
            b = np.attr("convolve")(b, coeffs[0]);
            a = np.attr("convolve")(a, coeffs[1]);
        }

        // 系数写回模块级全局 —— Realtime_IIR.process_frame 在调用时读的就是 b / a
        iir.attr("b") = b;
        iir.attr("a") = a;

        // 清掉历史 buffer：下一块数据进来时 process_frame_iir 会按新系数的长度
        // 重新 IIR_init()，随后由 C++ 侧用该块首帧把状态填到稳态
        iir.attr("x_buffer") = py::none();
        iir.attr("y_buffer") = py::none();
        m_impl->display_filter_seed_pending = true;
        return true;
    }
    catch (const std::exception &exc)
    {
        if (error_message != nullptr)
        {
            *error_message = QString::fromUtf8(exc.what());
        }
        return false;
    }
}

bool PythonEngine::process_display_filter(const float *samples, int total_samples, int channels,
                                          QVector<float> *out, QString *error_message)
{
    if (out == nullptr)
    {
        return false;
    }
    if (m_impl->interpreter == nullptr)
    {
        if (error_message != nullptr)
        {
            *error_message = QStringLiteral("Python 解释器未启动");
        }
        return false;
    }
    if (samples == nullptr || total_samples <= 0 || channels <= 0
        || total_samples % channels != 0)
    {
        if (error_message != nullptr)
        {
            *error_message = QStringLiteral("样本数与通道数不匹配");
        }
        return false;
    }

    const py::gil_scoped_acquire gil;
    try
    {
        const py::module_ np = py::module_::import("numpy");
        const py::module_ iir = py::module_::import("Realtime_IIR");

        // 交错样本原样拷进 numpy 数组：Realtime_IIR.process_frame 的输入就是这个布局
        py::array_t<float> input(total_samples);
        std::memcpy(input.mutable_data(), samples,
                    static_cast<size_t>(total_samples) * sizeof(float));

        if (m_impl->display_filter_seed_pending)
        {
            seed_display_filter_history(np, iir, input, channels);
            m_impl->display_filter_seed_pending = false;
        }

        const py::object result = iir.attr("process_frame")(input, channels);
        // 输出是一维 float32。copy_py_float_array 内部 forcecast，
        // Python 侧若换了 dtype 会自动拷一份而不是按错误类型读内存
        if (!pytypes::copy_py_float_array(result, out, total_samples))
        {
            if (error_message != nullptr)
            {
                *error_message = QStringLiteral("显示滤波返回值长度不符");
            }
            return false;
        }
        return true;
    }
    catch (const std::exception &exc)
    {
        if (error_message != nullptr)
        {
            *error_message = QString::fromUtf8(exc.what());
        }
        return false;
    }
}

// ==================== 自检 ====================

namespace
{

int g_selfcheck_failures = 0;

void check(bool condition, const QString &what)
{
    if (condition)
    {
        qInfo().noquote() << "  [通过]" << what;
        return;
    }
    ++g_selfcheck_failures;
    qWarning().noquote() << "  [失败]" << what;
}

// 自检的输出处理。见 pythonengine.h 的说明：默认处理器在重定向管道里什么都不输出
void selfcheck_message_handler(QtMsgType type, const QMessageLogContext &, const QString &message)
{
    static const bool console_ready = []() {
        SetConsoleOutputCP(CP_UTF8);
        return true;
    }();
    Q_UNUSED(console_ready);

    const char *prefix = "  ";
    if (type == QtWarningMsg || type == QtCriticalMsg)
    {
        prefix = "[!] ";
    }
    else if (type == QtFatalMsg)
    {
        prefix = "[X] ";
    }
    // 写 stdout 而不是 stderr：自检的「通过」输出也在这里，
    // 混进 stderr 会让「构建脚本把 stderr 当错误」的判断失效
    const QString line = QString::fromUtf8(prefix) + message + QStringLiteral("\n");
    fputs(line.toUtf8().constData(), stdout);
    fflush(stdout);
}

// 造一块合成样本（10 Hz 主峰 + 50 Hz 工频，好让 PSD 与频段值不是纯噪声），
// 单位 µV，交错布局。
//
// **每个通道必须不一样**：默认重参考是 common_average（减掉各通道均值），
// 16 个通道喂同一条波形的话，重参考会把整段减成 0 —— 看上去像滤波器失效，
// 实际是测试数据自己退化
SignalChunk make_block(int channels, int samples, qint64 first_sequence_id)
{
    constexpr double kPi = 3.14159265358979323846;

    SignalChunk chunk;
    chunk.channels = channels;
    chunk.samples_per_channel = samples;
    chunk.first_sequence_id = first_sequence_id;
    chunk.first_timestamp_ns = first_sequence_id * 1000000;   // 1000 Hz
    chunk.samples.resize(static_cast<qsizetype>(channels) * samples);
    for (int ch = 0; ch < channels; ++ch)
    {
        const double amplitude = 10.0 + static_cast<double>(ch) * 1.0;
        const double phase = kPi * static_cast<double>(ch) / static_cast<double>(channels);
        for (int i = 0; i < samples; ++i)
        {
            const double t = static_cast<double>(first_sequence_id + i) / 1000.0;
            chunk.samples[static_cast<qsizetype>(i) * channels + ch] =
                static_cast<float>(amplitude * std::sin(2.0 * kPi * 10.0 * t + phase)
                                   + 2.0 * std::sin(2.0 * kPi * 50.0 * t + phase));
        }
    }
    return chunk;
}

} // namespace

void install_console_message_handler()
{
    qInstallMessageHandler(selfcheck_message_handler);
}

int run_python_selfcheck(PythonEngine &engine)
{
    // 输出处理器由调用方装好（它要在解释器起来之前就生效，才能看见启动失败的输出）
    install_console_message_handler();

    qInfo().noquote() << "== eeg_bridge 自检 ==";
    qInfo().noquote() << "算法源码目录:" << engine.project_dir();
    qInfo().noquote() << "适配层目录  :" << engine.bridge_dir();
    qInfo().noquote() << "接口版本    :" << engine.api_version();

    {
        // start() 里主线程已经交出了 GIL，自检要自己现取现还
        const py::gil_scoped_acquire gil;
        try
        {
            const py::module_ bridge = py::module_::import("eeg_bridge");

            const QString version =
                QString::fromStdString(bridge.attr("api_version")().cast<std::string>());
            check(version.startsWith(QLatin1String("1.")),
                  QStringLiteral("接口主版本号为 1.x（实际 %1）").arg(version));

            // 自检不写日志文件，只看接口通不通
            bridge.attr("configure_logging")(log_dir().toStdString(), false, "INFO");

            const py::dict defaults = bridge.attr("processing_defaults")().cast<py::dict>();
            check(defaults.size() == 11,
                  QStringLiteral("processing_defaults 返回 11 项（实际 %1）").arg(defaults.size()));

            py::dict processing = py::dict(defaults);
            processing["config_version"] = 1;

            // QStringList 不能直接传给 pybind11 —— 必须先转成 py::list，
            // 否则得到的是运行期的 "Unable to convert call argument" 而不是编译错误
            const int session_id =
                bridge
                    .attr("create_online_session")(
                        pytypes::to_py_list(eeg_montage::channel_names()), 1000.0,
                        pytypes::to_py_positions(), "mni", 10.0, "common_average", py::tuple(),
                        20.0, 1.0, 0.5, 120.0, processing)
                    .cast<int>();
            check(session_id >= 0,
                  QStringLiteral("建在线会话成功，session_id=%1").arg(session_id));

            // 40 块 × 100 样本 = 4 秒，足够填满 2 秒的查询窗口
            constexpr int kBlockSamples = 100;
            constexpr int kBlocks = 40;
            constexpr qint64 kSamplePeriodNs = 1000000;   // 1000 Hz
            qint64 next_sequence_id = 0;
            py::dict last_result;
            for (int block = 0; block < kBlocks; ++block)
            {
                const SignalChunk chunk =
                    make_block(eeg_montage::kChannelCount, kBlockSamples, next_sequence_id);
                last_result = bridge
                                  .attr("push_block")(session_id, next_sequence_id,
                                                      pytypes::to_py_values(chunk),
                                                      pytypes::to_py_timestamps(
                                                          chunk.first_timestamp_ns, kBlockSamples,
                                                          kSamplePeriodNs))
                                  .cast<py::dict>();
                next_sequence_id += kBlockSamples;
            }
            check(!last_result["processed_values"].is_none(),
                  QStringLiteral("push_block 返回处理后的数据块"));
            check(last_result["config_version"].cast<int>() == 1,
                  QStringLiteral("在线结果带回正确的 config_version"));

            const py::dict status = bridge.attr("online_status")(session_id).cast<py::dict>();
            const QString state = QString::fromStdString(status["state"].cast<std::string>());
            check(state == QLatin1String("running"),
                  QStringLiteral("会话进入 running（实际 %1）").arg(state));
            const double buffer_s = status["rolling_buffer_duration_s"].cast<double>();
            check(buffer_s > 3.0,
                  QStringLiteral("滚动缓存已积满 4 秒（实际 %1 秒）").arg(buffer_s, 0, 'f', 2));

            const py::dict topo =
                bridge.attr("query_topography")(session_id, 1, "alpha", 8.0, 13.0, 2.0, 64, 64)
                    .cast<py::dict>();
            const py::buffer_info grid_info =
                topo["grid_values"].cast<py::array_t<float>>().request();
            check(grid_info.ndim == 2 && grid_info.shape[0] == 64 && grid_info.shape[1] == 64,
                  QStringLiteral("地形图网格形状为 64×64"));

            const py::dict spectrum =
                bridge.attr("query_spectrum")(session_id, 2, "C3", "full_0_5_30", 0.5, 30.0, 2.0)
                    .cast<py::dict>();
            const py::ssize_t freq_count =
                spectrum["psd"].cast<py::array_t<float>>().request().shape[0];
            check(freq_count > 1,
                  QStringLiteral("频谱返回多个频点（实际 %1 个）").arg(freq_count));

            // 合法配置更新
            py::dict update = py::dict(defaults);
            update["config_version"] = 2;
            update["low_pass_high_hz"] = 45.0;
            const py::dict update_result =
                bridge.attr("update_processing_config")(session_id, update).cast<py::dict>();
            check(update_result["config_version"].cast<int>() == 2,
                  QStringLiteral("配置更新生效，config_version=2"));

            // 重复版本号必须被拒 —— 这条验证的是「版本号只在成功后递增」这个前提成立
            bool rejected_duplicate = false;
            try
            {
                bridge.attr("update_processing_config")(session_id, update);
            }
            catch (const py::error_already_set &)
            {
                rejected_duplicate = true;
            }
            check(rejected_duplicate, QStringLiteral("重复的 config_version 被拒绝"));

            // 非法频率必须被适配层拦成 INVALID_ARGUMENT，而不是漏成 INTERNAL_ERROR
            QString rejected_code;
            QString rejected_message;
            try
            {
                py::dict bad = py::dict(defaults);
                bad["config_version"] = 3;
                bad["low_pass_high_hz"] = 900.0;   // 超过 Nyquist
                bridge.attr("update_processing_config")(session_id, bad);
            }
            catch (const py::error_already_set &exc)
            {
                const py::dict info = bridge.attr("describe_error")(exc.value()).cast<py::dict>();
                rejected_code = QString::fromStdString(info["code"].cast<std::string>());
                rejected_message = QString::fromStdString(info["message"].cast<std::string>());
            }
            check(rejected_code == QLatin1String("INVALID_ARGUMENT"),
                  QStringLiteral("超 Nyquist 的频率给出 INVALID_ARGUMENT（实际 %1）")
                      .arg(rejected_code.isEmpty() ? QStringLiteral("未拒绝") : rejected_code));
            // 顺带看一眼消息能不能正确解码成中文：C++ 与 Python 之间的字符串一旦
            // 编码搞错，界面上就是一片乱码，而错误码仍然是对的、很容易漏过去
            check(!rejected_message.isEmpty() && !rejected_message.contains(QChar(0xFFFD)),
                  QStringLiteral("错误消息可解码为中文：%1").arg(rejected_message));

            // 三次失败调用之后会话必须还活着 —— 接口约定「输入校验失败不得推进状态」
            const QString state_after =
                QString::fromStdString(bridge.attr("online_status")(session_id)
                                           .cast<py::dict>()["state"]
                                           .cast<std::string>());
            check(state_after != QLatin1String("error"),
                  QStringLiteral("参数错误之后会话仍然可用（实际 %1）").arg(state_after));

            // 复位与关闭
            bridge.attr("reset_session")(session_id);
            check(QString::fromStdString(bridge.attr("online_status")(session_id)
                                             .cast<py::dict>()["state"]
                                             .cast<std::string>())
                      == QLatin1String("warming_up"),
                  QStringLiteral("复位后会话回到预热状态"));

            // 只关会话，**不**调 close_api()：API 门面与解释器同生命周期，
            // 由 PythonEngine::shutdown() 统一收尾。这里提前关掉会让后续自检
            // 拿到一个已关闭的门面（create_api 是单例，返回的还是同一个）
            bridge.attr("close_session")(session_id);
            qInfo().noquote() << "  会话已关闭";
        }
        catch (const std::exception &exc)
        {
            ++g_selfcheck_failures;
            qWarning().noquote() << "  自检抛出异常:" << QString::fromUtf8(exc.what());
        }
    }

    if (g_selfcheck_failures == 0)
    {
        qInfo().noquote() << "== 算法接口自检全部通过 ==";
        return 0;
    }
    qWarning().noquote() << QStringLiteral("== 算法接口自检失败 %1 项 ==").arg(g_selfcheck_failures);
    return 1;
}
