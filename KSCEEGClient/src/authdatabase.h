#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// 本地账号库（SQLite）。
//
// 为什么不用 QML 的 QtQuick.LocalStorage：它底层也是 SQLite，但会把文件塞进
// AppData 下一个按路径哈希命名的目录里（QML/OfflineStorage/Databases/<hash>.sqlite），
// 平时根本找不到。这里直接用 Qt Sql 打开一个明确的 .db 文件，
// 位置就贴在可执行文件旁边，要查数据用任何 SQLite 工具打开即可。
class AuthDatabase : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    // 数据库文件路径（启动时会打日志，找不到文件时看日志即可）
    Q_PROPERTY(QString databasePath READ databasePath CONSTANT)

public:
    explicit AuthDatabase(QObject *parent = nullptr);
    ~AuthDatabase() override;

    QString databasePath() const { return m_path; }

    // 用「手机号 + 密码」登录，并把这一对凭据存进 users 表：
    //   库里已有该手机号 → 校验密码；没有 → 直接登记一条新用户。
    // 返回 { success, displayName, role, isNew }
    Q_INVOKABLE QVariantMap authenticateOrRegister(const QString &phone, const QString &password);

    // 最近一次登录的信息：{ phone, password, remember, hasRecord }
    Q_INVOKABLE QVariantMap lastLogin();

    // 记录最近一次登录（remember 为假时不保存密码）
    Q_INVOKABLE void saveLoginRecord(const QString &phone, const QString &password, bool remember);

private:
    bool ensureOpen();
    bool createTables();
    QString settingValue(const QString &key) const;

    QSqlDatabase m_database;
    QString m_path;
};
