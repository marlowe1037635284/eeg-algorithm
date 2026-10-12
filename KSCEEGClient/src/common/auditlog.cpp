#include "common/auditlog.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QMutexLocker>
#include <QStandardPaths>
#include <QTextStream>

namespace
{

// 当前登录用户（环境态）。登录成功写入、退出登录清空。record() 用它的值。
QString g_current_user;
// 同时保护 g_current_user 与写文件 —— 保证一条日志不会和别人交错写坏
QMutex g_mutex;

const char *k_log_file_name = "audit.log";

// 日志目录：%LOCALAPPDATA%\<应用名>\logs。与 pythonengine.cpp 的 log_dir()
// 指向同一处。取不到标准位置时退到临时目录，保证任何机器上都有个能写的地方
QString log_directory()
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    if (base.isEmpty())
        base = QDir::tempPath() + QStringLiteral("/EEG-KSC");
    return QDir::fromNativeSeparators(base) + QStringLiteral("/logs");
}

// 事件文本里混进换行会把一条日志拆成两行，破坏「一行一条」。统一换成空格
QString single_line(const QString &text)
{
    QString cleaned = text;
    cleaned.replace(QLatin1Char('\n'), QLatin1Char(' '));
    cleaned.replace(QLatin1Char('\r'), QLatin1Char(' '));
    return cleaned;
}

// 在已持锁的前提下追加一条。四个字段：用户ID | 日期 | 时间 | 事件
void append_line(const QString &user_id, const QString &event)
{
    const QDateTime now = QDateTime::currentDateTime();
    const QString line = QStringLiteral("%1 | %2 | %3 | %4\n")
                             .arg(user_id.isEmpty() ? QStringLiteral("未登录") : user_id,
                                  now.toString(QStringLiteral("yyyy-MM-dd")),
                                  now.toString(QStringLiteral("HH:mm:ss")),
                                  single_line(event));

    const QString dir = log_directory();
    QDir().mkpath(dir);
    const QString path = dir + QLatin1Char('/') + QLatin1String(k_log_file_name);

    // 文件还不存在时写一行表头，文件自己说明字段含义
    const bool first_write = !QFile::exists(path);

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
    {
        qWarning() << "[audit] 无法写入审计日志:" << path << file.errorString();
        return;
    }

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    if (first_write)
        out << QStringLiteral("# 审计日志：用户ID | 日期 | 时间 | 事件\n");
    out << line;
}

} // namespace

namespace audit_log
{

void set_current_user(const QString &user_id)
{
    const QMutexLocker locker(&g_mutex);
    g_current_user = user_id.trimmed();
}

void clear_current_user()
{
    const QMutexLocker locker(&g_mutex);
    g_current_user.clear();
}

QString current_user()
{
    const QMutexLocker locker(&g_mutex);
    return g_current_user;
}

void record(const QString &event)
{
    const QMutexLocker locker(&g_mutex);
    append_line(g_current_user, event);
}

void record_as(const QString &user_id, const QString &event)
{
    const QMutexLocker locker(&g_mutex);
    append_line(user_id.trimmed(), event);
}

QString log_file_path()
{
    return log_directory() + QLatin1Char('/') + QLatin1String(k_log_file_name);
}

} // namespace audit_log
