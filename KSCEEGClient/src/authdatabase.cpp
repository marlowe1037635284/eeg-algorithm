#include "authdatabase.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QSqlError>
#include <QSqlQuery>

namespace {

// 数据库放哪儿。
// 开发时优先放**代码目录**（CMake 把源码路径作为宏传进来），这样清理 build 目录、
// 重新 cmake 都不会把账号弄丢；部署到别处时源码目录不存在，退回可执行文件旁边。
QString default_database_path()
{
#ifdef KSCEEG_SOURCE_DIR
    const QDir source_dir(QStringLiteral(KSCEEG_SOURCE_DIR));
    if (source_dir.exists())
        return source_dir.filePath(QStringLiteral("eeg-ksc.db"));
#endif
    return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("eeg-ksc.db"));
}

const char *kSettingRemember = "remember_login";
const char *kSettingPhone = "remembered_username";
const char *kSettingPassword = "remembered_password";

} // namespace

AuthDatabase::AuthDatabase(QObject *parent)
    : QObject(parent)
{
    m_path = default_database_path();

    if (!ensureOpen())
        return;

    if (!createTables())
        return;

    // 预置一个管理员账号，方便第一次就能登进来
    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT OR IGNORE INTO users(username, password, display_name, role, created_at) "
        "VALUES(?, ?, ?, ?, datetime('now'))"));
    query.addBindValue(QStringLiteral("admin"));
    query.addBindValue(QStringLiteral("admin123456"));
    query.addBindValue(QStringLiteral("管理员"));
    query.addBindValue(QStringLiteral("管理员"));
    if (!query.exec())
        qWarning() << "[db] 预置管理员账号失败:" << query.lastError().text();
}

AuthDatabase::~AuthDatabase()
{
    if (m_database.isOpen())
        m_database.close();
}

bool AuthDatabase::ensureOpen()
{
    if (m_database.isOpen())
        return true;

    if (!QSqlDatabase::isDriverAvailable(QStringLiteral("QSQLITE")))
    {
        qWarning() << "[db] 缺少 QSQLITE 驱动，无法使用本地账号库";
        return false;
    }

    m_database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("auth"));
    m_database.setDatabaseName(m_path);

    if (!m_database.open())
    {
        qWarning() << "[db] 打开失败:" << m_path << m_database.lastError().text();
        return false;
    }

    qInfo() << "[db] 账号库:" << m_path;
    return true;
}

bool AuthDatabase::createTables()
{
    QSqlQuery query(m_database);
    const QStringList statements = {
        QStringLiteral("CREATE TABLE IF NOT EXISTS users ("
                       "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                       "username TEXT UNIQUE NOT NULL,"
                       "password TEXT NOT NULL,"
                       "display_name TEXT NOT NULL,"
                       "role TEXT NOT NULL,"
                       "created_at TEXT NOT NULL)"),
        QStringLiteral("CREATE TABLE IF NOT EXISTS app_settings ("
                       "setting_key TEXT PRIMARY KEY NOT NULL,"
                       "setting_value TEXT NOT NULL)"),
    };
    for (const QString &statement : statements)
    {
        if (!query.exec(statement))
        {
            qWarning() << "[db] 建表失败:" << query.lastError().text();
            return false;
        }
    }
    return true;
}

QVariantMap AuthDatabase::authenticateOrRegister(const QString &phone, const QString &password)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;
    result[QStringLiteral("displayName")] = QString();
    result[QStringLiteral("role")] = QString();
    result[QStringLiteral("isNew")] = false;

    if (phone.isEmpty() || !ensureOpen())
        return result;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("SELECT password, display_name, role FROM users WHERE username = ? LIMIT 1"));
    query.addBindValue(phone);
    if (!query.exec())
    {
        qWarning() << "[db] 查询账号失败:" << query.lastError().text();
        return result;
    }

    if (query.next())
    {
        // 已有账号：校验密码
        if (query.value(0).toString() != password)
            return result;
        result[QStringLiteral("success")] = true;
        result[QStringLiteral("displayName")] = query.value(1).toString();
        result[QStringLiteral("role")] = query.value(2).toString();
        return result;
    }

    // 新手机号：直接登记（登录页填什么就存什么）
    QSqlQuery insert(m_database);
    insert.prepare(QStringLiteral(
        "INSERT INTO users(username, password, display_name, role, created_at) "
        "VALUES(?, ?, ?, ?, datetime('now'))"));
    insert.addBindValue(phone);
    insert.addBindValue(password);
    insert.addBindValue(phone);
    insert.addBindValue(QStringLiteral("普通用户"));
    if (!insert.exec())
    {
        qWarning() << "[db] 登记新账号失败:" << insert.lastError().text();
        return result;
    }

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("displayName")] = phone;
    result[QStringLiteral("role")] = QStringLiteral("普通用户");
    result[QStringLiteral("isNew")] = true;
    return result;
}

QString AuthDatabase::settingValue(const QString &key) const
{
    QString value;
    if (!m_database.isOpen())
        return value;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1"));
    query.addBindValue(key);
    if (query.exec() && query.next())
        value = query.value(0).toString();
    return value;
}

QVariantMap AuthDatabase::lastLogin()
{
    const QString remember = settingValue(QString::fromLatin1(kSettingRemember));
    QVariantMap result;
    result[QStringLiteral("phone")] = settingValue(QString::fromLatin1(kSettingPhone));
    result[QStringLiteral("password")] = settingValue(QString::fromLatin1(kSettingPassword));
    result[QStringLiteral("remember")] = remember == QStringLiteral("1");
    // 区分「从来没登录过」和「登录过但没勾记住密码」：前者按设计稿显示空表单 + 勾上记住密码
    result[QStringLiteral("hasRecord")] = !remember.isEmpty();
    return result;
}

void AuthDatabase::saveLoginRecord(const QString &phone, const QString &password, bool remember)
{
    if (!ensureOpen())
        return;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT OR REPLACE INTO app_settings(setting_key, setting_value) VALUES(?, ?)"));

    const auto store = [&](const QString &key, const QString &value) {
        query.bindValue(0, key);
        query.bindValue(1, value);
        if (!query.exec())
            qWarning() << "[db] 写入设置失败:" << key << query.lastError().text();
    };

    store(QString::fromLatin1(kSettingRemember), remember ? QStringLiteral("1") : QStringLiteral("0"));
    store(QString::fromLatin1(kSettingPhone), phone);

    // 不勾「记住密码」时把密码删掉，不要写空串占位
    if (remember && !password.isEmpty())
    {
        store(QString::fromLatin1(kSettingPassword), password);
    }
    else
    {
        QSqlQuery remove(m_database);
        remove.prepare(QStringLiteral("DELETE FROM app_settings WHERE setting_key = ?"));
        remove.addBindValue(QString::fromLatin1(kSettingPassword));
        remove.exec();
    }
}
