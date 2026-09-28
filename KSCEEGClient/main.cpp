#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QFontDatabase>
#include <QCoreApplication>
#include <QDebug>

namespace {

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
}

} // namespace

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    load_design_fonts();

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("KSCEEGClient", "Main");

    return QGuiApplication::exec();
}
