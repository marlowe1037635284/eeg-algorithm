#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// 应用本地数据库（SQLite）：账号、偏好设置、患者档案。
//
// 三者共用一个 .db 文件、一个连接：本来就是同一份应用数据，拆成多个连接只会把
// 「文件放哪、什么时候打开」这套逻辑抄好几遍，而 SQLite 同文件多连接还要自己
// 处理锁。类名叫 AppDatabase 而不是 AuthDatabase 就是这个原因 ——
// 它从加上患者表起就不只管登录了。
//
// 为什么不用 QML 的 QtQuick.LocalStorage：它底层也是 SQLite，但会把文件塞进
// AppData 下一个按路径哈希命名的目录里（QML/OfflineStorage/Databases/<hash>.sqlite），
// 平时根本找不到。这里直接用 Qt Sql 打开一个明确的 .db 文件，
// 位置就贴在可执行文件旁边，要查数据用任何 SQLite 工具打开即可。
class AppDatabase : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    // 数据库文件路径（启动时会打日志，找不到文件时看日志即可）
    Q_PROPERTY(QString databasePath READ databasePath CONSTANT)

public:
    explicit AppDatabase(QObject *parent = nullptr);
    ~AppDatabase() override;

    QString databasePath() const { return m_path; }

    // ==================== 账号 ====================

    // 用「手机号 + 密码」登录，并把这一对凭据存进 users 表：
    //   库里已有该手机号 → 校验密码；没有 → 直接登记一条新用户。
    // 返回 { success, displayName, role, isNew }
    Q_INVOKABLE QVariantMap authenticateOrRegister(const QString &phone, const QString &password);

    // 最近一次登录的信息：{ phone, password, remember, hasRecord }
    Q_INVOKABLE QVariantMap lastLogin();

    // 记录最近一次登录（remember 为假时不保存密码）
    Q_INVOKABLE void saveLoginRecord(const QString &phone, const QString &password, bool remember);

    // ==================== 患者 ====================

    // 全部患者，按病历号排序。每一项的键与患者管理页表格的列一一对应：
    //   { no, name, gender, age, dept, diag, note, count, last, createdAt }
    //
    // 采集次数与最近采集时间是**从 recording_sessions 表汇总出来的**，
    // 不在患者表里另存一份 —— 同一件事存两处，迟早会对不上
    Q_INVOKABLE QVariantList patients();

    // 改一位患者。original_no 是改之前的病历号（病历号本身也允许改）
    Q_INVOKABLE QVariantMap updatePatient(const QString &original_no, const QString &patient_no,
                                          const QString &name, const QString &gender, int age,
                                          const QString &department, const QString &diagnosis,
                                          const QString &note);

    // 采集记录，最新的排在最前。patient_no 留空表示不过滤。
    // 每一项的键与历史记录页表格的列一一对应：
    //   { no, patientNo, patient, time, duration, channels, rate, events, quality, level }
    // 电极质量没有数据源（协议只给 4 路不带电极名的阻抗），固定返回「—」
    Q_INVOKABLE QVariantList sessions(const QString &patient_no);

    // 新增患者，返回 { success, message, no }。
    // patient_no 留空时按 P-0001 的规则自动生成
    Q_INVOKABLE QVariantMap addPatient(const QString &patient_no, const QString &name,
                                       const QString &gender, int age,
                                       const QString &department, const QString &diagnosis,
                                       const QString &note);

    Q_INVOKABLE bool removePatient(const QString &patient_no);

    // 开始采集时开一条记录。患者列表里的「采集次数 / 最近采集」和
    // 历史记录页都是从这张表来的，所以必须在真的开始采集时写
    Q_INVOKABLE void recordCollection(const QString &patient_no, int channel_count,
                                      int sample_rate);

    // 停止采集时把这条记录补全（时长、事件数、落盘路径）。
    // 分两次写而不是攒到停止时一次性写：中途崩了/掉电时，至少留下「什么时候采过」
    Q_INVOKABLE void finishCollection(const QString &patient_no, int duration_seconds,
                                      int event_count, const QString &file_path);

private:
    bool ensureOpen();
    bool createTables();
    // 给已存在的表补列。CREATE TABLE IF NOT EXISTS 不会动已有的表，
    // 所以加字段必须显式 ALTER —— 否则老库上那些列永远不存在
    void ensure_column(const QString &table, const QString &column, const QString &definition);
    QString settingValue(const QString &key) const;
    // 下一个可用的病历号（P-0001 起）。生成规则只留这一处，别在别处再拼一次
    QString nextPatientNo() const;

    QSqlDatabase m_database;
    QString m_path;
};
