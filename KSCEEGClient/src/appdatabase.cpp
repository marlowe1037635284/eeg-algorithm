#include "appdatabase.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QSqlError>
#include <QSqlQuery>

#include <algorithm>

namespace {

// 数据库放哪儿。
// 开发时优先放**代码目录**（CMake 把源码路径作为宏传进来），这样清理 build 目录、
// 重新 cmake 都不会把账号与患者弄丢；部署到别处时源码目录不存在，退回可执行文件旁边。
QString defaultDatabasePath()
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

// 病历号前缀与位数。改成 P-0001 以外的格式时只看这一处
const char *kPatientNoPrefix = "P-";
constexpr int kPatientNoDigits = 4;

} // namespace

AppDatabase::AppDatabase(QObject *parent)
    : QObject(parent)
{
    m_path = defaultDatabasePath();

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

AppDatabase::~AppDatabase()
{
    if (m_database.isOpen())
        m_database.close();
}

bool AppDatabase::ensureOpen()
{
    if (m_database.isOpen())
        return true;

    if (!QSqlDatabase::isDriverAvailable(QStringLiteral("QSQLITE")))
    {
        qWarning() << "[db] 缺少 QSQLITE 驱动，无法使用本地数据库";
        return false;
    }

    m_database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("app"));
    m_database.setDatabaseName(m_path);

    if (!m_database.open())
    {
        qWarning() << "[db] 打开失败:" << m_path << m_database.lastError().text();
        return false;
    }

    qInfo() << "[db] 数据库:" << m_path;
    return true;
}

bool AppDatabase::createTables()
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

        // 患者档案。patient_no 是界面上叫「病历号」的那一列，留空时自动生成，
        // 所以给它 UNIQUE —— 撞号要当场报错，不能悄悄存成两条
        QStringLiteral("CREATE TABLE IF NOT EXISTS patients ("
                       "patient_no TEXT PRIMARY KEY NOT NULL,"
                       "name TEXT NOT NULL,"
                       "gender TEXT NOT NULL DEFAULT '',"
                       "age INTEGER NOT NULL DEFAULT 0,"
                       "department TEXT NOT NULL DEFAULT '',"
                       "diagnosis TEXT NOT NULL DEFAULT '',"
                       "note TEXT NOT NULL DEFAULT '',"
                       "created_at TEXT NOT NULL)"),

        // 采集记录。患者列表的「采集次数 / 最近采集」和历史记录页都来自这张表。
        // 开始采集时先写 patient_no/started_at，停止时再补齐时长等 ——
        // 分两次是为了中途崩了也留下「什么时候采过」
        QStringLiteral("CREATE TABLE IF NOT EXISTS recording_sessions ("
                       "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                       "patient_no TEXT NOT NULL,"
                       "started_at TEXT NOT NULL,"
                       "duration_s INTEGER NOT NULL DEFAULT 0,"
                       "channel_count INTEGER NOT NULL DEFAULT 0,"
                       "sample_rate INTEGER NOT NULL DEFAULT 0,"
                       "event_count INTEGER NOT NULL DEFAULT 0,"
                       "file_path TEXT NOT NULL DEFAULT '')"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_patient "
                       "ON recording_sessions(patient_no)"),
    };
    for (const QString &statement : statements)
    {
        if (!query.exec(statement))
        {
            qWarning() << "[db] 建表失败:" << query.lastError().text();
            return false;
        }
    }

    // 给**已经存在**的老库补列。上面那句 CREATE TABLE IF NOT EXISTS 对已建好的表
    // 什么都不做，所以新增字段必须单独 ALTER，否则老库上查这些列会直接报错
    ensure_column(QStringLiteral("recording_sessions"), QStringLiteral("duration_s"),
                  QStringLiteral("INTEGER NOT NULL DEFAULT 0"));
    ensure_column(QStringLiteral("recording_sessions"), QStringLiteral("channel_count"),
                  QStringLiteral("INTEGER NOT NULL DEFAULT 0"));
    ensure_column(QStringLiteral("recording_sessions"), QStringLiteral("sample_rate"),
                  QStringLiteral("INTEGER NOT NULL DEFAULT 0"));
    ensure_column(QStringLiteral("recording_sessions"), QStringLiteral("event_count"),
                  QStringLiteral("INTEGER NOT NULL DEFAULT 0"));
    ensure_column(QStringLiteral("recording_sessions"), QStringLiteral("file_path"),
                  QStringLiteral("TEXT NOT NULL DEFAULT ''"));
    return true;
}

void AppDatabase::ensure_column(const QString &table, const QString &column,
                                const QString &definition)
{
    QSqlQuery probe(m_database);
    if (!probe.exec(QStringLiteral("PRAGMA table_info(%1)").arg(table)))
    {
        qWarning() << "[db] 读取表结构失败:" << table << probe.lastError().text();
        return;
    }

    while (probe.next())
    {
        if (probe.value(1).toString() == column)
            return;   // 已经有了
    }

    QSqlQuery alter(m_database);
    if (!alter.exec(QStringLiteral("ALTER TABLE %1 ADD COLUMN %2 %3")
                        .arg(table, column, definition)))
    {
        qWarning() << "[db] 补列失败:" << table << column << alter.lastError().text();
    }
}

// ==================== 账号 ====================

QVariantMap AppDatabase::authenticateOrRegister(const QString &phone, const QString &password)
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

QString AppDatabase::settingValue(const QString &key) const
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

QVariantMap AppDatabase::lastLogin()
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

void AppDatabase::saveLoginRecord(const QString &phone, const QString &password, bool remember)
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

// ==================== 患者 ====================

QString AppDatabase::nextPatientNo() const
{
    // 取现有病历号里数字最大的那个再加一。
    //
    // 不用 COUNT(*)+1：删过患者之后那个值会与已有号撞车，而 patient_no 是主键，
    // 撞了就是一次静默的写入失败
    int maximum = 0;
    QSqlQuery query(m_database);
    if (query.exec(QStringLiteral("SELECT patient_no FROM patients")))
    {
        while (query.next())
        {
            const QString text = query.value(0).toString();
            bool ok = false;
            const int value = text.mid(int(qstrlen(kPatientNoPrefix))).toInt(&ok);
            if (ok)
                maximum = std::max(maximum, value);
        }
    }
    return QStringLiteral("%1%2")
        .arg(QString::fromLatin1(kPatientNoPrefix))
        .arg(maximum + 1, kPatientNoDigits, 10, QLatin1Char('0'));
}

QVariantList AppDatabase::patients()
{
    QVariantList rows;
    if (!ensureOpen())
        return rows;

    // 采集次数与最近采集时间用一条子查询汇总，避免在主查询里写两遍患者表。
    // LEFT JOIN 而不是 INNER JOIN：一次都没采过的患者也必须出现（次数 0、时间为空）
    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT p.patient_no, p.name, p.gender, p.age, p.department, p.diagnosis, p.note,"
        "       p.created_at,"
        "       COUNT(s.id) AS record_count,"
        "       COALESCE(MAX(s.started_at), '') AS last_record"
        "  FROM patients p"
        "  LEFT JOIN recording_sessions s ON s.patient_no = p.patient_no"
        " GROUP BY p.patient_no"
        " ORDER BY p.patient_no"));
    if (!query.exec())
    {
        qWarning() << "[db] 查询患者失败:" << query.lastError().text();
        return rows;
    }

    while (query.next())
    {
        const int count = query.value(8).toInt();
        const QString last = query.value(9).toString();

        QVariantMap row;
        row[QStringLiteral("no")] = query.value(0).toString();
        row[QStringLiteral("name")] = query.value(1).toString();
        row[QStringLiteral("gender")] = query.value(2).toString();
        row[QStringLiteral("age")] = query.value(3).toInt();
        row[QStringLiteral("dept")] = query.value(4).toString();
        row[QStringLiteral("diag")] = query.value(5).toString();
        row[QStringLiteral("note")] = query.value(6).toString();
        row[QStringLiteral("createdAt")] = query.value(7).toString();
        // 表格里这两列是文本，格式在数据层定好，界面直接贴
        row[QStringLiteral("count")] = QStringLiteral("%1 次").arg(count);
        row[QStringLiteral("last")] = last.isEmpty() ? QStringLiteral("—") : last;
        rows.append(row);
    }
    return rows;
}

QVariantMap AppDatabase::addPatient(const QString &patient_no, const QString &name,
                                    const QString &gender, int age, const QString &department,
                                    const QString &diagnosis, const QString &note)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;
    result[QStringLiteral("no")] = QString();

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    const QString trimmed_name = name.trimmed();
    if (trimmed_name.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写患者姓名");
        return result;
    }

    QString number = patient_no.trimmed();
    if (number.isEmpty())
        number = nextPatientNo();

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT INTO patients(patient_no, name, gender, age, department, diagnosis, note, created_at) "
        "VALUES(?, ?, ?, ?, ?, ?, ?, datetime('now'))"));
    query.addBindValue(number);
    query.addBindValue(trimmed_name);
    query.addBindValue(gender.trimmed());
    query.addBindValue(std::max(0, age));
    query.addBindValue(department.trimmed());
    query.addBindValue(diagnosis.trimmed());
    query.addBindValue(note.trimmed());

    if (!query.exec())
    {
        // 手填的病历号撞号是最常见的失败，单独给一句能看懂的话
        const QString error = query.lastError().text();
        result[QStringLiteral("message")] = error.contains(QStringLiteral("UNIQUE"), Qt::CaseInsensitive)
                                                ? QStringLiteral("病历号 %1 已存在").arg(number)
                                                : error;
        qWarning() << "[db] 新增患者失败:" << error;
        return result;
    }

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("no")] = number;
    return result;
}

bool AppDatabase::removePatient(const QString &patient_no)
{
    if (!ensureOpen())
        return false;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("DELETE FROM patients WHERE patient_no = ?"));
    query.addBindValue(patient_no);
    if (!query.exec())
    {
        qWarning() << "[db] 删除患者失败:" << query.lastError().text();
        return false;
    }

    // 采集记录跟着删：留着一堆指向已删患者的行，汇总查询要在 join 条件上
    // 额外排除它们，不如一起清掉
    QSqlQuery sessions(m_database);
    sessions.prepare(QStringLiteral("DELETE FROM recording_sessions WHERE patient_no = ?"));
    sessions.addBindValue(patient_no);
    sessions.exec();
    return true;
}

QVariantMap AppDatabase::updatePatient(const QString &original_no, const QString &patient_no,
                                        const QString &name, const QString &gender, int age,
                                        const QString &department, const QString &diagnosis,
                                        const QString &note)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    const QString trimmed_name = name.trimmed();
    if (trimmed_name.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写患者姓名");
        return result;
    }

    const QString number = patient_no.trimmed();
    if (number.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写病历号");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "UPDATE patients SET patient_no = ?, name = ?, gender = ?, age = ?, department = ?,"
        "       diagnosis = ?, note = ?"
        " WHERE patient_no = ?"));
    query.addBindValue(number);
    query.addBindValue(trimmed_name);
    query.addBindValue(gender.trimmed());
    query.addBindValue(std::max(0, age));
    query.addBindValue(department.trimmed());
    query.addBindValue(diagnosis.trimmed());
    query.addBindValue(note.trimmed());
    query.addBindValue(original_no.trimmed());

    if (!query.exec())
    {
        const QString error = query.lastError().text();
        result[QStringLiteral("message")] = error.contains(QStringLiteral("UNIQUE"), Qt::CaseInsensitive)
                                                ? QStringLiteral("病历号 %1 已被占用").arg(number)
                                                : error;
        qWarning() << "[db] 修改患者失败:" << error;
        return result;
    }

    // 改了病历号的话，采集记录里指向它的那一列也要跟着改，
    // 否则这位患者的「采集次数」会归零（记录挂在旧号上）
    if (number != original_no.trimmed() && !original_no.trimmed().isEmpty())
    {
        QSqlQuery move(m_database);
        move.prepare(QStringLiteral(
            "UPDATE recording_sessions SET patient_no = ? WHERE patient_no = ?"));
        move.addBindValue(number);
        move.addBindValue(original_no.trimmed());
        if (!move.exec())
            qWarning() << "[db] 迁移采集记录失败:" << move.lastError().text();
    }

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("no")] = number;
    return result;
}

QVariantList AppDatabase::sessions(const QString &patient_no)
{
    QVariantList rows;
    if (!ensureOpen())
        return rows;

    QSqlQuery query(m_database);
    const QString columns =
        QStringLiteral("SELECT s.id, s.patient_no, p.name, s.started_at, s.duration_s,"
                       "       s.channel_count, s.sample_rate, s.event_count"
                       "  FROM recording_sessions s"
                       "  LEFT JOIN patients p ON p.patient_no = s.patient_no");

    if (patient_no.trimmed().isEmpty())
    {
        query.prepare(columns + QStringLiteral(" ORDER BY s.id DESC"));
    }
    else
    {
        query.prepare(columns + QStringLiteral(" WHERE s.patient_no = ? ORDER BY s.id DESC"));
        query.addBindValue(patient_no.trimmed());
    }

    if (!query.exec())
    {
        qWarning() << "[db] 查询采集记录失败:" << query.lastError().text();
        return rows;
    }

    while (query.next())
    {
        const int id = query.value(0).toInt();
        const int duration = query.value(4).toInt();
        const int channels = query.value(5).toInt();
        const int rate = query.value(6).toInt();

        // 时间在库里是 SQLite 的 "yyyy-MM-dd hh:mm:ss"，界面上设计稿写的是
        // "2026-9-22 16:44:12"（月日时不补零），这里按界面的写法格式化
        const QDateTime started = QDateTime::fromString(query.value(3).toString(),
                                                       QStringLiteral("yyyy-MM-dd hh:mm:ss"));
        const QString time_text = started.isValid()
                                      ? QStringLiteral("%1-%2-%3 %4:%5:%6")
                                            .arg(started.date().year())
                                            .arg(started.date().month())
                                            .arg(started.date().day())
                                            .arg(started.time().hour(), 2, 10, QLatin1Char('0'))
                                            .arg(started.time().minute(), 2, 10, QLatin1Char('0'))
                                            .arg(started.time().second(), 2, 10, QLatin1Char('0'))
                                      : query.value(3).toString();

        QVariantMap row;
        row[QStringLiteral("no")] = QStringLiteral("R-%1").arg(id, 4, 10, QLatin1Char('0'));
        row[QStringLiteral("patientNo")] = query.value(1).toString();
        // 患者被删掉之后记录还在，这时姓名取不到，不能显示成空白
        row[QStringLiteral("patient")] = query.value(2).toString().isEmpty()
                                             ? QStringLiteral("（已删除患者）")
                                             : query.value(2).toString();
        row[QStringLiteral("time")] = time_text;
        row[QStringLiteral("duration")] = QStringLiteral("%1:%2:%3")
                                              .arg(duration / 3600, 2, 10, QLatin1Char('0'))
                                              .arg((duration / 60) % 60, 2, 10, QLatin1Char('0'))
                                              .arg(duration % 60, 2, 10, QLatin1Char('0'));
        row[QStringLiteral("channels")] = QString::number(channels);
        row[QStringLiteral("rate")] = QStringLiteral("%1 Hz").arg(rate);
        row[QStringLiteral("events")] = QString::number(query.value(7).toInt());
        // 电极质量没有数据源：协议一次只给 4 路不带电极名的阻抗值，
        // 推不出「N/16 良好」。写死一个数字比留空更糟
        row[QStringLiteral("quality")] = QStringLiteral("—");
        row[QStringLiteral("level")] = QString();
        rows.append(row);
    }
    return rows;
}

void AppDatabase::recordCollection(const QString &patient_no, int channel_count, int sample_rate)
{
    if (!ensureOpen() || patient_no.trimmed().isEmpty())
        return;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT INTO recording_sessions(patient_no, started_at, channel_count, sample_rate) "
        "VALUES(?, datetime('now'), ?, ?)"));
    query.addBindValue(patient_no.trimmed());
    query.addBindValue(std::max(0, channel_count));
    query.addBindValue(std::max(0, sample_rate));
    if (!query.exec())
        qWarning() << "[db] 写采集记录失败:" << query.lastError().text();
}

void AppDatabase::finishCollection(const QString &patient_no, int duration_seconds,
                                   int event_count, const QString &file_path)
{
    if (!ensureOpen() || patient_no.trimmed().isEmpty())
        return;

    // 补在**这一位患者最近一条**记录上：一次采集对应一条，停止时补的是刚开的那条。
    // 用 id 排序取最大，而不是按时间字符串排 —— 同一秒内开两条时字符串分不出先后
    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "UPDATE recording_sessions SET duration_s = ?, event_count = ?, file_path = ? "
        " WHERE id = (SELECT id FROM recording_sessions WHERE patient_no = ? "
        "             ORDER BY id DESC LIMIT 1)"));
    query.addBindValue(std::max(0, duration_seconds));
    query.addBindValue(std::max(0, event_count));
    query.addBindValue(file_path);
    query.addBindValue(patient_no.trimmed());
    if (!query.exec())
        qWarning() << "[db] 补全采集记录失败:" << query.lastError().text();
}
