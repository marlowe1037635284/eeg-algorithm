#ifndef PYTHONENGINE_H
#define PYTHONENGINE_H

#include <QString>
#include <QVector>

#include <memory>

#include "eegtypes.h"

// 嵌入式 CPython 解释器的生命周期门面。
//
// 为什么不把解释器的初始化直接写在 main.cpp 里（参考实现就是这么做的）：
// 那段代码要处理 PyConfig、venv 身份、sys.path、GIL 让出、启动自检五件事，
// 掺进 Qt 的组装逻辑里会让 main.cpp 变成整个项目最难维护的一块。这里用 pimpl
// 把 pybind11 完全关在 .cpp 里，main.cpp 因此一个 pybind11 头都不用包含。
//
// 使用顺序（每一步都不能换位置）：
//   QGuiApplication 构造之后
//     → start()          建解释器，并让主线程交出 GIL
//     → ... 建算法线程、跑事件循环 ...
//     → shutdown()       必须在线程全部 wait() 回来之后再调
//   ~PythonEngine()      兜底，正常路径下这时已经是空操作
class PythonEngine
{
public:
    PythonEngine();
    ~PythonEngine();

    PythonEngine(const PythonEngine &) = delete;
    PythonEngine &operator=(const PythonEngine &) = delete;

    // 建解释器。不抛异常 —— 界面照常起来，用户能从日志区看到 Python 没接对，
    // 比启动即崩好。
    //
    // 返回值的**完整含义**（调用方必须两个都看）：
    //   false              解释器没起来，error_message 是原因
    //   true + error 非空   解释器起来了，但算法接口不可用（模块导入失败等）
    //   true + error 为空   一切正常
    // 只判断返回值的话，第二种情况下最有价值的那行原因会被丢掉
    bool start(QString *error_message);

    // 关解释器。调用之后本对象不可再用。**必须**先停掉并 wait 所有会碰
    // Python 的线程：解释器 finalize 与还在析构 py::object 的线程抢生命周期，
    // 表现为退出时随机崩溃或静默挂死。
    //
    // 这也是本进程里唯一一处调用 close_api() 的地方 —— 会话的关闭由算法线程
    // 自己负责，而 API 门面与解释器同生命周期，交给这里统一收尾
    void shutdown();

    bool is_running() const;

    // 解释器启动时读到的接口版本。未启动时为空。
    QString api_version() const;

    // 解释器实际解析出来的路径，启动时打日志用：新旧目录各有一份同名模块时，
    // 加载错目录是不会报错的，全靠这几行日志能看出来。
    QString project_dir() const;
    QString bridge_dir() const;
    QString venv_dir() const;

    // ---- 显示通路的独立滤波（不经过算法线程）----
    //
    // 波形显示不复用算法线程的处理结果，而是自己跑一遍滤波：算法侧的滤波器状态
    // 是按「输入恒为直流偏置」的稳态初始化的，一旦按真实信号启动/改参，IIR 状态
    // 与信号不匹配就会冲出与直流偏置同量级的瞬变（几百 µV、要几秒才衰减）。
    // 显示侧改用 FIR_test.py —— 它的 _zi_seed() 拿本批首个样本把状态预热到稳态，
    // 启动与改参都不会有瞬变（参考项目 pybindwithqt 就是这么做显示通路的）。
    //
    // 为什么放在这里而不是 acquisitionbridge：pybind11 必须先于 Qt 头文件包含，
    // 而 acquisitionbridge.cpp 头一个 include 就是自己的头（内含 Qt），
    // 没法再引入 pybind11。这里把 pybind11 关在 .cpp 里，对外只暴露普通类型。

    // 按滤波参数重建显示侧滤波状态。channels 是显示缓冲的通道数（16）。
    // 内部会调 FIR_test.reset_state()，下一块数据的首个样本自动完成稳态预热，
    // 于是「改参数」与「刚启动」都不会有瞬变
    bool configure_display_filter(const ProcessingParams &params, int channels,
                                  QString *error_message);
    // 对一块交错样本做显示滤波。samples 的长度必须是 channels 的整数倍。
    // 成功时把结果写进 out（同长度，float32）；失败返回 false 并填 error_message
    bool process_display_filter(const float *samples, int total_samples, int channels,
                                QVector<float> *out, QString *error_message);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

// 给自检装一个直接写 stdout 的消息处理器。
//
// Qt 默认的消息处理器只把输出送到控制台**正在附加**的终端，从 Git Bash / CI
// 的重定向管道里跑时一个字都看不到 —— 表现为「进程返回 1，但没有任何输出」，
// 比报错还难查。同时把控制台输出码页切到 UTF-8，否则中文全是乱码。
//
// 幂等，可在任何自检入口调用
void install_console_message_handler();

// 自检：把 eeg_bridge 的全部接口跑一遍
// （建会话 → 灌合成数据 → 查询地形图/频谱 → 改配置 → 触发一次非法参数 →
// 重置 → 关闭）。返回退出码，0 表示全部通过。
//
// 存在的意义：C++ 与 Python 之间是靠字符串键名和位置参数连起来的，
// 写错一个键名不会有编译错误，只会在用户恰好点到那个开关时才炸。
// 自检把所有路径都走一遍，让这类错误在启动时就暴露。
//
// engine 必须是**已经 start() 过**的实例，函数内部不会创建也不会关闭它：
// CPython 不支持「finalize 之后再初始化并重新导入扩展模块」
// （numpy 会报 "cannot load module more than once per process"），
// 一个进程只能起一次解释器，所以所有自检必须共用同一个
int run_python_selfcheck(PythonEngine &engine);

#endif // PYTHONENGINE_H
