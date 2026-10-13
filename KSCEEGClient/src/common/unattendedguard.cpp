#include "common/unattendedguard.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QTimer>
#include <QtGlobal>

namespace
{

const auto k_config_file_name = QStringLiteral("client-config.json");
const auto k_auto_exit_key = QStringLiteral("unattended_auto_exit_minutes");

// 配置文件路径：先看可执行文件同级（打包后的正式形态），再看源码目录
//（开发期直接跑 build/ 里的 exe 时用）。
//
// 这里**刻意**与 defaultDatabasePath() 的优先序相反：数据库模板希望开发期
// 用源码目录里那份，而配置文件希望打包后 exe 同级那份说了算 —— 现场要调
// 阈值不该回源码目录改。
QString config_file_path()
{
    const QString beside_exe =
        QDir(QCoreApplication::applicationDirPath()).filePath(k_config_file_name);
    if (QFile::exists(beside_exe))
        return beside_exe;

#ifdef KSCEEG_SOURCE_DIR
    const QDir source_dir(QString(KSCEEG_SOURCE_DIR));
    if (source_dir.exists())
    {
        const QString in_source = source_dir.filePath(k_config_file_name);
        if (QFile::exists(in_source))
            return in_source;
    }
#endif

    return beside_exe;
}

// 这个事件算不算「有人在操作」。
//
// 只认真正的输入：鼠标动、点、滚轮，键盘按，触摸，手写笔。像 UpdateRequest、
// Paint、Timer 这些系统自己发的噪声事件不能算，否则计时器永远清零，功能形同虚设。
bool is_user_input(const QEvent *event)
{
    switch (event->type())
    {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonDblClick:
    case QEvent::MouseMove:
    case QEvent::Wheel:
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::HoverMove:
    case QEvent::TabletMove:
    case QEvent::TabletPress:
        return true;
    default:
        return false;
    }
}

} // namespace

int unattended_auto_exit_minutes(int fallback)
{
    const QString path = config_file_path();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
    {
        qWarning().noquote() << "[idle] 配置文件打不开，用默认值" << fallback << ":" << path;
        return fallback;
    }

    QJsonParseError parse_error{};
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &parse_error);
    if (parse_error.error != QJsonParseError::NoError || !doc.isObject())
    {
        qWarning().noquote() << "[idle] 配置文件解析失败，用默认值" << fallback
                             << ":" << parse_error.errorString();
        return fallback;
    }

    const QJsonValue value = doc.object().value(k_auto_exit_key);
    if (!value.isDouble())
    {
        // 字段缺失、写成字符串、写成 null 都走这里
        qWarning().noquote() << "[idle] 配置里没有" << k_auto_exit_key
                             << "（或类型不对），用默认值" << fallback;
        return fallback;
    }

    return static_cast<int>(value.toDouble());
}

UnattendedGuard::UnattendedGuard(int timeout_minutes, QObject *parent)
    : QObject(parent)
{
    m_timeout_ms = qMax(0, timeout_minutes) * 60 * 1000;
    if (m_timeout_ms <= 0)
        return;

    // 单次触发：到点就通知界面锁定。每次用户输入都 start() 重新计时，等价于
    // 「距上次操作过了多久」的倒计时
    m_timer = new QTimer(this);
    m_timer->setSingleShot(true);
    m_timer->setInterval(m_timeout_ms);
    connect(m_timer, &QTimer::timeout, this, [this]() {
        qInfo().noquote() << "[idle] 无人值守超时，锁定设备";
        emit idleTimedOut();
    });

    if (QCoreApplication::instance() != nullptr)
        QCoreApplication::instance()->installEventFilter(this);
    m_timer->start();
}

UnattendedGuard::~UnattendedGuard()
{
    // 事件过滤器指向 this，必须显式摘掉；否则 this 释放后应用再派发事件就是
    // 悬空指针。虽然正常路径下析构发生在 quit() 之后、事件循环已经停了，但
    // 析构顺序不该依赖这个巧合
    if (QCoreApplication::instance() != nullptr)
        QCoreApplication::instance()->removeEventFilter(this);
}

bool UnattendedGuard::eventFilter(QObject *watched, QEvent *event)
{
    if (m_timeout_ms > 0 && m_timer != nullptr && is_user_input(event))
        m_timer->start();

    return QObject::eventFilter(watched, event);
}
