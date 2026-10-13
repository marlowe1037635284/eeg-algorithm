#include <QCoreApplication>
#include <QDebug>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickImageProvider>
#include <QStringList>
#include <QTimer>

#include "bridge/acquisitionbridge.h"
#include "analysis/postprocess.h"
#include "algorithm/pythonengine.h"
#include "algorithm/pythonworker.h"
#include "analysis/recordingpreview.h"
#include "acquisition/serialcollector.h"
#include "common/licensemanager.h"
#include "common/unattendedguard.h"

namespace
{

// 加载设计稿用的「阿里巴巴普惠体 2.0」。
//
// 为什么随程序打包：这套字体不是 Windows 自带的，用户机器上基本不会装，
// 不带上就只能回退到微软雅黑，字形和设计稿对不上。
//
// 注意字重的取法：普惠体每个字重在文件里是独立的家族名
// （如 "Alibaba PuHuiTi 2.0 55 Regular"），子家族名统一是 "Regular"，
// 所以 QML 里要按家族名选字重，用 font.weight 是选不出来的。
void load_design_fonts()
{
    // 从可执行文件同级的 assets/fonts 读（CMake 编译后会拷过去）。
    // 不走 Qt 资源：字体太大，嵌进资源会把 rcc 生成的 .cpp 撑到 130MB，编译不过。
    const QString font_dir = QCoreApplication::applicationDirPath() + QStringLiteral("/assets/fonts");
    const QStringList font_files = {
        font_dir + QStringLiteral("/AlibabaPuHuiTi-2-55-Regular.ttf"),
        font_dir + QStringLiteral("/AlibabaPuHuiTi-2-65-Medium.ttf"),
        font_dir + QStringLiteral("/AlibabaPuHuiTi-2-85-Bold.ttf"),
        font_dir + QStringLiteral("/AlibabaPuHuiTi-2-105-Heavy.ttf"),
    };

    for (const QString &font_file : font_files)
    {
        const int font_id = QFontDatabase::addApplicationFont(font_file);
        if (font_id < 0)
        {
            qWarning() << "[font] 加载失败，将回退到系统字体:" << font_file;
            continue;
        }
        qInfo() << "[font] 已加载" << font_file << "家族名:" << QFontDatabase::applicationFontFamilies(font_id);
    }

    // 普惠体四个字重在 Qt 里会合并成一个家族，靠 styleName 区分。
    // 把实际可用的家族/样式打出来，字体对不上时看日志就能定位。
    for (const QString &family : QFontDatabase::families())
    {
        if (family.contains(QStringLiteral("PuHuiTi")))
            qInfo() << "[font] 可用家族:" << family << "样式:" << QFontDatabase::styles(family);
    }
}

} // namespace

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    // 产品名要显式设置：QStandardPaths 的 AppLocalDataLocation 会以它为一级目录，
    // 采集记录的落盘位置由它决定，不设的话会退化成可执行文件名。
    //（日志已改为可执行文件同级的 logs 目录，不再走这里）
    //
    // **组织名刻意不设**：Qt 这个位置是「组织/应用」两级，两个都设成 EEG-KSC 的话
    // 会得到 %LOCALAPPDATA%\EEG-KSC\EEG-KSC\... 这种重复一层的路径
    QCoreApplication::setApplicationName(QStringLiteral("EEG-KSC"));

    // --selfcheck：不启界面，在控制台把两条最容易出错、又最难在界面上看出来的
    // 链路跑一遍 —— 串口协议的字节换算与切帧，以及 C++ 与算法包之间的接口。
    // 两者都不会有编译错误，错了只表现为「波形幅度不对」或「某个开关点了没反应」
    if (QCoreApplication::arguments().contains(QStringLiteral("--selfcheck")))
    {
        install_console_message_handler();

        // 解释器**一个进程只能起一次**：CPython 不支持 finalize 之后再初始化
        // 并重新导入扩展模块（numpy 会报 "cannot load module more than once
        // per process"）。所以三个自检共用同一个实例，这里建一次、最后关一次
        PythonEngine engine;
        QString python_error;
        if (!engine.start(&python_error))
        {
            qWarning().noquote() << "解释器启动失败，只能跑串口自检:" << python_error;
        }

        int failures = 0;
        if (run_serial_selfcheck() != 0)
        {
            ++failures;
        }
        if (engine.is_running())
        {
            if (run_python_selfcheck(engine) != 0)
            {
                ++failures;
            }
            if (run_worker_selfcheck(engine) != 0)
            {
                ++failures;
            }
            if (run_bridge_selfcheck(engine) != 0)
            {
                ++failures;
            }
            engine.shutdown();
        }
        else
        {
            ++failures;
        }
        return failures == 0 ? 0 : 1;
    }

    // 无人值守自动退出：连续一段时间没有任何鼠标 / 键盘操作就退出程序。
    // 阈值从 client-config.json 读，缺省 60 分钟。声明在 main 作用域里，
    // 生命周期与事件循环一致，退出时由事件循环正常收尾。
    const int auto_exit_minutes =
        unattended_auto_exit_minutes(kDefaultUnattendedAutoExitMinutes);
    UnattendedGuard unattended_guard(auto_exit_minutes, &app);
    if (unattended_guard.is_active())
        qInfo().noquote() << "[idle] 无人值守自动退出已启用，空闲阈值" << auto_exit_minutes << "分钟";
    else
        qInfo().noquote() << "[idle] 无人值守自动退出已关闭（unattended_auto_exit_minutes <= 0）";

    load_design_fonts();

    // 授权校验：每次启动都跑一次，读可执行文件同级的 license.lic 与 public_key.pem。
    //
    // 声明在 main 作用域里，生命周期长于内层作用域的 QML 引擎 —— 弹窗要读它的属性，
    // 引擎析构时不能再指向已释放的对象。
    //
    // 校验不通过**不在这里直接退出**：界面照常起来，由 QML 层的全屏弹窗盖住登录页，
    // 点「确定」才退出。这样用户能看到失败原因，而不是程序闪一下就没了。
    // 放在 Python 解释器之前：授权不通过就没必要再花时间起算法环境
    LicenseManager license;
    license.verify();

    // 解释器要在界面之前起来：QML 一起来就会读算法状态，
    // 而那时 Python 若还没准备好，界面会先闪一下「未连接」
    PythonEngine python_engine;
    QString python_error;
    const bool python_ok = python_engine.start(&python_error);
    if (!python_ok)
    {
        qWarning().noquote() << "[main] Python 解释器启动失败:" << python_error;
    }
    // 注意 error_message 非空**不只**在返回 false 时出现：解释器起来了但
    // 算法模块导入失败时，start() 仍返回 true 并把原因写在 error_message 里
    //（解释器可用，只是接口不可用）。只判断返回值会把这个最有价值的原因丢掉，
    // 日志里只剩一个空白的「算法接口版本: 」
    if (python_ok && !python_error.isEmpty())
    {
        qWarning().noquote() << "[main] 算法接口不可用:" << python_error;
    }
    if (python_ok)
    {
        qInfo().noquote() << "[main] 算法接口版本:" << python_engine.api_version();
    }

    int exit_code = 0;

    // 界面与采集门面必须关在**内层作用域**里。
    //
    // 这是个容易写错、而且错了只在退出时随机崩溃的地方：如果把 bridge /
    // engine 声明成 main 的局部量，那么 python_engine.shutdown() 会在函数体
    // 里执行，而它们的析构要等到 main 返回 —— 也就是解释器会先被 finalize，
    // 而那时算法线程可能还在跑、还持有 py::object。
    // 关在这里，作用域结束时它们的析构函数先把两个线程 wait() 干净，
    // 之后 shutdown() 才是安全的。
    {
        // **必须声明在 engine 之前**：局部对象按声明的逆序析构，
        // 这样 engine（连同它的 image provider）先析构完，
        // provider 里那个指向 bridge 的裸指针才不会指到已释放的对象上
        AcquisitionBridge bridge(&python_engine);
        // 历史记录的波形回放。与 bridge 分开：它读的是磁盘上的文件，
        // 与串口、算法会话、采集线程全无关系。
        // 同样**必须声明在 engine 之前** —— provider 里存着指向它的裸指针
        RecordingPreview preview;
        // 「数据分析与后处理」页的全部计算。同样读磁盘上的记录文件，
        // 与分析无关的事情一概不碰；重算走 QtConcurrent，不占 GUI 线程
        PostProcess analysis;

        QQmlApplicationEngine engine;
        // 波形与地形图都由 C++ 画好交给 Image 贴。波形留在 QML Canvas 里画的话
        // 实测一帧要 76~120ms（三万个点全走 JS 侧的软件光栅化），界面只能跑到
        // 十几帧；同样的内容 QPainter 画是毫秒级
        engine.addImageProvider(QStringLiteral("waveform"),
                                bridge.create_wave_image_provider());
        engine.addImageProvider(QStringLiteral("topography"),
                                bridge.create_topo_image_provider());
        engine.addImageProvider(QStringLiteral("recording"),
                                preview.create_image_provider());
        engine.addImageProvider(QStringLiteral("analysis"),
                                analysis.create_image_provider());
        // 注入成 QML 里的 Acq。用 setContextProperty 而不是注册 QML 类型：
        // 只有一个实例，没有多实例需求，注册类型反而要处理「谁来创建」的问题
        engine.rootContext()->setContextProperty(QStringLiteral("Acq"), &bridge);
        engine.rootContext()->setContextProperty(QStringLiteral("Recording"), &preview);
        engine.rootContext()->setContextProperty(QStringLiteral("Analysis"), &analysis);
        // 授权状态给 QML 读：License.checked / License.valid / License.message
        engine.rootContext()->setContextProperty(QStringLiteral("License"), &license);

        QObject::connect(
            &engine,
            &QQmlApplicationEngine::objectCreationFailed,
            &app,
            []() { QCoreApplication::exit(-1); },
            Qt::QueuedConnection);
        engine.loadFromModule("KSCEEGClient", "Main");

        // --demo：切到进程内合成的演示数据源。没有设备时用它把整条链路
        //（算法会话 → 波形 → 地形图 → 频谱）跑起来看效果。
        // 必须等 QML 加载完再启动，否则属性绑定还没建立，第一批数据画的图会被丢掉
        if (QCoreApplication::arguments().contains(QStringLiteral("--demo")))
        {
            QTimer::singleShot(0, &bridge, [&bridge]() { bridge.start_demo_source(); });
        }

        exit_code = QGuiApplication::exec();
    }

    // 走到这里时 engine 与 bridge 都已经析构：bridge 的析构函数先关串口、
    // 等采集线程退出，再等算法线程退出，所有 py::object 都已释放。
    // 只有到这一步，关解释器才是安全的 —— 少任何一个 wait()，
    // Py_FinalizeEx 都会和一个还在析构 py::object 的线程抢生命周期
    python_engine.shutdown();

    return exit_code;
}
