#include "storage/appdatabase.h"

#include "common/auditlog.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QTextStream>
#include <QTimeZone>
#include <QUrl>

// 密码哈希与「记住密码」的对称加密都走 OpenSSL（与 licensemanager.cpp 同一套依赖，
// 编译期已链接 OpenSSL::Crypto，见 CMakeLists.txt）
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#include <algorithm>

namespace {

// 数据库放哪儿。
//
// 开发时优先放**代码目录**（CMake 把源码路径作为宏传进来），这样清理 build 目录、
// 重新 cmake 都不会把账号与患者弄丢；部署到别处时源码目录不存在，退回可执行文件旁边
// —— 也就是「把库拷到运行目录去写」的那一份。
//
// 副作用要知道：**开发期连的就是版本库里那一个文件**（它是表结构模板），
// 调试产生的患者与采集记录会直接写进模板。提交前按 appdatabase.h 顶部那两条约定清一遍
QString defaultDatabasePath()
{
#ifdef KSCEEG_SOURCE_DIR
    const QDir source_dir(QStringLiteral(KSCEEG_SOURCE_DIR));
    if (source_dir.exists())
        return source_dir.filePath(QStringLiteral("eeg-ksc.db"));
#endif
    return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("eeg-ksc.db"));
}

// 记录文件默认目录：可执行文件所在目录下的 records 子目录。
// 与 AcquisitionBridge::default_record_directory() 是同一个约定 —— 那边是采集落盘时
// 的兜底值，这里是写进 app_settings 的初始值，两处必须保持一致
QString defaultRecordDirectory()
{
    const QString base = QCoreApplication::applicationDirPath();
    return QDir::toNativeSeparators(base) + QStringLiteral("/records");
}

const char *kSettingRemember = "remember_login";
const char *kSettingPhone = "remembered_username";
const char *kSettingPassword = "remembered_password";

// 内置超级管理员：写死在代码里，**不进数据库、也不出现在用户列表中**。
// 它是进入系统的那把钥匙 —— 首次登录用它，之后在「用户管理」里开通其它账号。
// 库里所有账号都由它派生，因此这三个值一旦改动就等于换锁，务必与登录页的
// 默认回填值（LoginPage.qml）保持一致
const QString kBuiltinAdminUser = QStringLiteral("admin");
const QString kBuiltinAdminPassword = QStringLiteral("admin123456");
const QString kBuiltinAdminDisplay = QStringLiteral("管理员");
const QString kBuiltinAdminRole = QStringLiteral("管理员");

// 病历号前缀与位数。改成 P-0001 以外的格式时只看这一处
const char *kPatientNoPrefix = "P-";
constexpr int kPatientNoDigits = 4;

// ==================== 密码存储 ====================
//
// 库里不放明文密码。账号密码只用于「比对」，所以用单向哈希；「记住密码」要回填
// 到登录页，必须可解密，所以用对称加密。两者分开处理，不要混用。

// 密码哈希：PBKDF2-HMAC-SHA256 + 每账号随机盐。迭代次数是防爆破的代价因子，
// 存储格式 `pbkdf2_sha256$<迭代>$<盐hex>$<摘要hex>`；前缀同时用来识别
// 「这一行是不是已经哈希过的」，以便兼容老库里的明文
constexpr int kPasswordHashIterations = 120000;
constexpr int kPasswordSaltBytes = 16;
constexpr int kPasswordDigestBytes = 32; // SHA-256 摘要长度

QString hex_encode(const unsigned char *data, int length)
{
    return QString::fromLatin1(QByteArray(reinterpret_cast<const char *>(data), length).toHex());
}

QByteArray hex_decode(const QString &hex)
{
    return QByteArray::fromHex(hex.toLatin1());
}

bool secure_random(unsigned char *out, int length)
{
    return RAND_bytes(out, length) == 1;
}

// 返回空串代表生成失败（随机源或 KDF 出错），调用方必须据此放弃写入，
// 不能把空串当哈希存进库 —— 那样等于把密码清空
QString hash_password(const QString &password)
{
    unsigned char salt[kPasswordSaltBytes];
    if (!secure_random(salt, kPasswordSaltBytes))
        return QString();

    const QByteArray raw = password.toUtf8();
    unsigned char digest[kPasswordDigestBytes];
    if (PKCS5_PBKDF2_HMAC(raw.constData(), raw.size(),
                          salt, kPasswordSaltBytes,
                          kPasswordHashIterations, EVP_sha256(),
                          kPasswordDigestBytes, digest) != 1)
        return QString();

    return QStringLiteral("pbkdf2_sha256$%1$%2$%3")
        .arg(kPasswordHashIterations)
        .arg(hex_encode(salt, kPasswordSaltBytes), hex_encode(digest, kPasswordDigestBytes));
}

bool is_password_hash(const QString &stored)
{
    return stored.startsWith(QStringLiteral("pbkdf2_sha256$"));
}

// 校验密码。命中老库里的明文密码时，通过 out_needs_upgrade 告诉调用方
// 「这次是明文比对，请把这一行升级成哈希」；哈希比对用常量时间比较避免计时侧信道
bool verify_password(const QString &password, const QString &stored, bool *out_needs_upgrade)
{
    if (out_needs_upgrade)
        *out_needs_upgrade = false;

    if (!is_password_hash(stored))
    {
        const bool match = (stored == password);
        if (match && out_needs_upgrade)
            *out_needs_upgrade = true;
        return match;
    }

    const QStringList parts = stored.split(QLatin1Char('$'));
    if (parts.size() != 4)
        return false;

    bool ok = false;
    const int iterations = parts.at(1).toInt(&ok);
    const QByteArray salt = hex_decode(parts.at(2));
    const QByteArray expected = hex_decode(parts.at(3));
    if (!ok || iterations <= 0 || salt.isEmpty() || expected.isEmpty())
        return false;

    const QByteArray raw = password.toUtf8();
    QByteArray actual(expected.size(), '\0');
    if (PKCS5_PBKDF2_HMAC(raw.constData(), raw.size(),
                          reinterpret_cast<const unsigned char *>(salt.constData()), salt.size(),
                          iterations, EVP_sha256(),
                          actual.size(), reinterpret_cast<unsigned char *>(actual.data())) != 1)
        return false;

    return CRYPTO_memcmp(expected.constData(), actual.constData(),
                         static_cast<size_t>(expected.size())) == 0;
}

// 「记住密码」的密钥由固定口令派生。桌面端没有独立的密钥保管设施，这一层挡住的是
// 「直接打开数据库文件就能看到明文密码」，而不是有程序在旁主动攻击的场景 —— 后者
// 需要真正的密钥保管方案（如系统凭据库），超出当前范围
QByteArray remembered_password_key()
{
    static const QByteArray key =
        QCryptographicHash::hash(QByteArrayLiteral("ksceegclient.remembered-password.v1"),
                                 QCryptographicHash::Sha256);
    return key; // 32 字节，直接作为 AES-256 密钥
}

// 返回空串代表加密失败，调用方不要把空串写进库
QString encrypt_secret(const QString &plain)
{
    if (plain.isEmpty())
        return plain;

    const QByteArray key = remembered_password_key();
    unsigned char iv[16];
    if (!secure_random(iv, static_cast<int>(sizeof(iv))))
        return QString();

    const QByteArray in = plain.toUtf8();
    QByteArray out(in.size() + 16, '\0');

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        return QString();

    int len = 0;
    int total = 0;
    bool ok = EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), nullptr,
                                 reinterpret_cast<const unsigned char *>(key.constData()), iv) == 1
              && EVP_EncryptUpdate(ctx, reinterpret_cast<unsigned char *>(out.data()), &len,
                                   reinterpret_cast<const unsigned char *>(in.constData()),
                                   in.size()) == 1;
    total = len;
    if (ok)
        ok = EVP_EncryptFinal_ex(ctx, reinterpret_cast<unsigned char *>(out.data()) + total, &len) == 1;
    total += len;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        return QString();

    out.resize(total);
    return QStringLiteral("aes256cbc$%1$%2")
        .arg(hex_encode(iv, static_cast<int>(sizeof(iv))), QString::fromLatin1(out.toHex()));
}

// 老库明文：原样返回，等下次保存时升级为密文
QString decrypt_secret(const QString &stored)
{
    if (stored.isEmpty() || !stored.startsWith(QStringLiteral("aes256cbc$")))
        return stored;

    const QStringList parts = stored.split(QLatin1Char('$'));
    if (parts.size() != 3)
        return QString();

    const QByteArray iv = hex_decode(parts.at(1));
    const QByteArray in = hex_decode(parts.at(2));
    if (iv.size() != 16 || in.isEmpty())
        return QString();

    const QByteArray key = remembered_password_key();
    QByteArray out(in.size() + 16, '\0');

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        return QString();

    int len = 0;
    int total = 0;
    bool ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), nullptr,
                                 reinterpret_cast<const unsigned char *>(key.constData()),
                                 reinterpret_cast<const unsigned char *>(iv.constData())) == 1
              && EVP_DecryptUpdate(ctx, reinterpret_cast<unsigned char *>(out.data()), &len,
                                   reinterpret_cast<const unsigned char *>(in.constData()),
                                   in.size()) == 1;
    total = len;
    if (ok)
        ok = EVP_DecryptFinal_ex(ctx, reinterpret_cast<unsigned char *>(out.data()) + total, &len) == 1;
    total += len;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        return QString();

    out.resize(total);
    return QString::fromUtf8(out);
}

// 界面上的记录号（R-0011）→ 主键 id。不是这个格式就返回 -1。
// 只认这一个编号格式：把转换收在一处，改编号规则时不必满文件找
int parse_record_id(const QString &record_no)
{
    const QString text = record_no.trimmed();
    if (!text.startsWith(QStringLiteral("R-"), Qt::CaseInsensitive))
        return -1;
    bool ok = false;
    const int value = text.mid(2).toInt(&ok);
    return ok ? value : -1;
}

// SQLite 的 "yyyy-MM-dd hh:mm:ss" → 本地时间的 QDateTime。
//
// **必须显式按 UTC 解析再转本地**：库里所有时间戳都是 SQLite 的 datetime('now')，
// 那是 UTC。直接当本地时间用的话，东八区看到的每个时间都会早 8 小时 ——
// 而这个错很难被发现，因为时间本身看着完全合理（实测：界面显示 10:12 的那次采集，
// 落盘文件名是 18:12）。落盘文件名取的是本地时间，两者一直对不上
QDateTime parse_utc_stamp(const QString &raw)
{
    QDateTime stamp = QDateTime::fromString(raw, QStringLiteral("yyyy-MM-dd hh:mm:ss"));
    if (!stamp.isValid())
        return QDateTime();
    stamp.setTimeZone(QTimeZone::UTC);
    return stamp.toLocalTime();
}

// 界面上写的 "2026-9-22 16:44:12"（月日时不补零）
QString format_stamp(const QString &raw)
{
    const QDateTime stamp = parse_utc_stamp(raw);
    if (!stamp.isValid())
        return raw;
    return QStringLiteral("%1-%2-%3 %4:%5:%6")
        .arg(stamp.date().year())
        .arg(stamp.date().month())
        .arg(stamp.date().day())
        .arg(stamp.time().hour(), 2, 10, QLatin1Char('0'))
        .arg(stamp.time().minute(), 2, 10, QLatin1Char('0'))
        .arg(stamp.time().second(), 2, 10, QLatin1Char('0'));
}

// 只要日期那一段（用户管理页的「注册时间」）。同样要过一遍时区 ——
// 不转的话，本地 00:00~08:00 注册的用户会显示成前一天
QString format_date(const QString &raw)
{
    const QDateTime stamp = parse_utc_stamp(raw);
    if (!stamp.isValid())
        return raw.left(10);
    return stamp.date().toString(QStringLiteral("yyyy-MM-dd"));
}

} // namespace

AppDatabase::AppDatabase(QObject *parent)
    : QObject(parent)
{
    m_path = defaultDatabasePath();

    if (!ensureOpen())
        return;

    if (!createTables())
        return;

    // 内置超级管理员不落库（登录逻辑见 authenticateOrRegister）。
    // 这里顺手清掉老版本或模板库里可能残留的 admin 行，保证它既不在数据库里，
    // 也不会出现在用户列表中
    QSqlQuery cleanup(m_database);
    if (!cleanup.exec(QStringLiteral("DELETE FROM users WHERE username = 'admin'")))
        qWarning() << "[db] 清理内置管理员残留行失败:" << cleanup.lastError().text();
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
        // 所以给它 UNIQUE —— 撞号要当场报错，不能悄悄存成两条。
        //
        // created_by 记录录入人的账号（users.username）。患者可见性与角色挂钩：
        // 管理员看全部，其余角色只看自己录入的 —— 就靠这一列。老库里补出来的
        // 这一列为空串，于是那些历史患者只对管理员可见，这是安全的默认值
        QStringLiteral("CREATE TABLE IF NOT EXISTS patients ("
                       "patient_no TEXT PRIMARY KEY NOT NULL,"
                       "name TEXT NOT NULL,"
                       "gender TEXT NOT NULL DEFAULT '',"
                       "age INTEGER NOT NULL DEFAULT 0,"
                       "department TEXT NOT NULL DEFAULT '',"
                       "diagnosis TEXT NOT NULL DEFAULT '',"
                       "note TEXT NOT NULL DEFAULT '',"
                       "created_by TEXT NOT NULL DEFAULT '',"
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

        // 标注标签。系统设置页的「标签管理」与工作台的「手动标记」共用这一份 ——
        // 原来工作台那份标签是写死在 QML 里的，加一个标签要改代码
        QStringLiteral("CREATE TABLE IF NOT EXISTS tags ("
                       "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                       "name TEXT NOT NULL,"
                       "code TEXT NOT NULL DEFAULT '',"
                       "color TEXT NOT NULL DEFAULT '',"
                       "created_at TEXT NOT NULL)"),

        // 一次采集里标记过的事件。记录表里只存了事件**个数**，
        // 个数拼不回时刻与标签，所以「采集记录预览」里那条事件带要靠这张表
        QStringLiteral("CREATE TABLE IF NOT EXISTS session_events ("
                       "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                       "session_id INTEGER NOT NULL,"
                       "offset_s REAL NOT NULL DEFAULT 0,"
                       "wall_clock TEXT NOT NULL DEFAULT '',"
                       "label TEXT NOT NULL DEFAULT '',"
                       "color TEXT NOT NULL DEFAULT '')"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_session_events "
                       "ON session_events(session_id)"),
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

    // 用户管理页要用到、而最初建表时没有的几列。老库上这几列不存在，
    // 查询会直接报错，所以必须补
    ensure_column(QStringLiteral("users"), QStringLiteral("department"),
                  QStringLiteral("TEXT NOT NULL DEFAULT ''"));
    ensure_column(QStringLiteral("users"), QStringLiteral("status"),
                  QStringLiteral("TEXT NOT NULL DEFAULT '启用'"));
    ensure_column(QStringLiteral("users"), QStringLiteral("last_login"),
                  QStringLiteral("TEXT NOT NULL DEFAULT ''"));

    // 患者可见性按录入人区分，老库上没有这一列 —— 不补的话，非管理员的
    // patients() 查询会直接报「no such column」
    ensure_column(QStringLiteral("patients"), QStringLiteral("created_by"),
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
    result[QStringLiteral("message")] = QStringLiteral("密码不正确，请重新输入");

    if (phone.isEmpty() || !ensureOpen())
        return result;

    // 用户名最多 30 个字符（前端输入框也有同样的长度限制）
    if (phone.length() > 30)
    {
        result[QStringLiteral("message")] = QStringLiteral("用户名不能超过 30 个字符");
        return result;
    }

    // 内置超级管理员：凭据写死在代码里，不查库。命中后无论成败都不落库、
    // 也不进用户列表（列表查询另有过滤，双保险）。
    // 「登录成功」的审计由 setCurrentUser 的状态迁移统一记录，这里不重复记
    if (phone == kBuiltinAdminUser)
    {
        if (password != kBuiltinAdminPassword)
        {
            audit_log::record_as(phone, QStringLiteral("登录失败：密码不正确"));
            return result;   // message 默认即「密码不正确，请重新输入」
        }
        result[QStringLiteral("success")] = true;
        result[QStringLiteral("displayName")] = kBuiltinAdminDisplay;
        result[QStringLiteral("role")] = kBuiltinAdminRole;
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT password, display_name, role, status FROM users WHERE username = ? LIMIT 1"));
    query.addBindValue(phone);
    if (!query.exec())
    {
        qWarning() << "[db] 查询账号失败:" << query.lastError().text();
        result[QStringLiteral("message")] = QStringLiteral("数据库查询失败");
        return result;
    }

    if (query.next())
    {
        // 已有账号：校验密码（哈希比对；老库的明文命中后当场升级为哈希）
        const QString stored_password = query.value(0).toString();
        bool needs_upgrade = false;
        if (!verify_password(password, stored_password, &needs_upgrade))
        {
            audit_log::record_as(phone, QStringLiteral("登录失败：密码不正确"));
            return result;
        }
        if (needs_upgrade)
        {
            const QString upgraded = hash_password(password);
            if (!upgraded.isEmpty())
            {
                QSqlQuery upgrade(m_database);
                upgrade.prepare(QStringLiteral("UPDATE users SET password = ? WHERE username = ?"));
                upgrade.addBindValue(upgraded);
                upgrade.addBindValue(phone);
                if (!upgrade.exec())
                    qWarning() << "[db] 明文密码升级为哈希失败:" << upgrade.lastError().text();
            }
        }

        // 停用/待审核的账号不许登录。原来只看密码，用户管理页把一个人停用了，
        // 他照样能登进来 —— 那个「停用」按钮就是摆设
        const QString status = query.value(3).toString();
        if (status == QStringLiteral("停用"))
        {
            result[QStringLiteral("message")] = QStringLiteral("该账号已停用，请联系管理员");
            audit_log::record_as(phone, QStringLiteral("登录失败：账号已停用"));
            return result;
        }
        if (status == QStringLiteral("待审核"))
        {
            result[QStringLiteral("message")] = QStringLiteral("该账号尚未通过审核");
            audit_log::record_as(phone, QStringLiteral("登录失败：账号尚未通过审核"));
            return result;
        }

        result[QStringLiteral("success")] = true;
        result[QStringLiteral("displayName")] = query.value(1).toString();
        result[QStringLiteral("role")] = query.value(2).toString();

        // 记下这次登录时间：用户管理页的「最后登录」列就是从这里来的。
        // 失败不拦登录，只记一条日志。
        //
        // 用 datetime('now') 即 UTC，与这张表其它时间列一致；界面上由
        // format_stamp 统一转成本地时间。这里若写 'localtime'，同一屏里就会出现
        // 两套基准，而 format_stamp 又会把它再转一次
        QSqlQuery touch(m_database);
        touch.prepare(QStringLiteral(
            "UPDATE users SET last_login = datetime('now') WHERE username = ?"));
        touch.addBindValue(phone);
        if (!touch.exec())
            qWarning() << "[db] 更新最后登录时间失败:" << touch.lastError().text();
        return result;
    }

    // 库里没有这个账号：一律拒绝。账号的开通统一归到用户管理页，登录页只负责登录
    // —— 否则被停用的人把账号名改一个字符就能立刻拿到一个新账号登进来。
    // 首次进入系统用内置超级管理员（见上方 kBuiltinAdminUser），它不落库
    result[QStringLiteral("message")] = QStringLiteral("账号不存在，请联系管理员开通");
    audit_log::record_as(phone, QStringLiteral("登录失败：账号不存在"));
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

bool AppDatabase::maskingEnabled() const
{
    // 默认关闭：脱敏是「选择性开启」，不该开箱就替用户藏起数据
    return settingValue(QStringLiteral("data_mask")) == QStringLiteral("true");
}

QVariantMap AppDatabase::lastLogin()
{
    const QString remember = settingValue(QString::fromLatin1(kSettingRemember));
    QVariantMap result;
    result[QStringLiteral("phone")] = settingValue(QString::fromLatin1(kSettingPhone));
    // 「记住密码」在库里是密文，回填前先解密（老库明文则原样返回）
    result[QStringLiteral("password")] = decrypt_secret(settingValue(QString::fromLatin1(kSettingPassword)));
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
    const QString encrypted_password =
        (remember && !password.isEmpty()) ? encrypt_secret(password) : QString();
    if (!encrypted_password.isEmpty())
    {
        store(QString::fromLatin1(kSettingPassword), encrypted_password);
    }
    else
    {
        // 没勾选、密码为空、或加密失败：一律不留密码。加密失败时宁可删掉，
        // 也不能退回明文写库
        QSqlQuery remove(m_database);
        remove.prepare(QStringLiteral("DELETE FROM app_settings WHERE setting_key = ?"));
        remove.addBindValue(QString::fromLatin1(kSettingPassword));
        remove.exec();
    }
}

// ==================== 会话 ====================

void AppDatabase::setCurrentUser(const QString &account, const QString &role)
{
    const QString next_user = account.trimmed();
    const QString previous_user = m_current_user;

    // 会话身份的变化正好对应「登录 / 退出」两个审计事件，记在这一处比散到
    // 各页面可靠：任何一次登录成功、任何一次退出登录都会经过这里。
    // 空 -> 某人 = 登录；某人 -> 空 = 退出
    if (!next_user.isEmpty() && next_user != previous_user)
        audit_log::record_as(next_user, QStringLiteral("登录成功"));
    else if (next_user.isEmpty() && !previous_user.isEmpty())
        audit_log::record_as(previous_user, QStringLiteral("退出登录"));

    m_current_user = next_user;
    m_current_role = role.trimmed();
    // 同步给审计日志：登录后后续的操作日志都用这个身份
    audit_log::set_current_user(m_current_user);
}

// ==================== 患者 ====================

bool AppDatabase::currentUserIsAdmin() const
{
    // 角色文本与用户管理页、预置管理员一致。未登录（空角色）按非管理员处理：
    // 宁可少看，也不要让一个没登录的状态拿到全部患者
    return m_current_role == QStringLiteral("管理员");
}

QString AppDatabase::currentAccount() const
{
    return m_current_user;
}

bool AppDatabase::disablingSelf(const QString &account, const QString &status) const
{
    // 只有「要把状态改成停用」且目标正是当前登录账号时才拦。启用自己、改别人的
    // 状态都不受影响。未登录（账号为空）时不拦，免得空串意外撞上某个目标
    return status == QStringLiteral("停用") && !m_current_user.isEmpty()
           && account.trimmed() == m_current_user;
}

bool AppDatabase::patientBelongsToCurrentUser(const QString &patient_no) const
{
    // 管理员看全部，直接放行，省一次查询
    if (currentUserIsAdmin())
        return true;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT 1 FROM patients WHERE patient_no = ? AND created_by = ? LIMIT 1"));
    query.addBindValue(patient_no.trimmed());
    query.addBindValue(m_current_user);
    if (!query.exec())
    {
        // 查询本身出错（表缺失、库损坏等）与「不是本人录入」必须分开：
        // 前者要留下日志，否则会被静默当成一次越权拒绝，排障时毫无线索。
        // 返回值仍是拒绝 —— 出错时按安全策略默认不放行
        qWarning() << "[db] 检查患者归属失败:" << query.lastError().text();
        return false;
    }
    // 走到这里 exec 已成功，查不到行就说明该患者不存在或不是自己录入的，
    // 两种情况对外不作区分
    return query.next();
}

bool AppDatabase::sessionBelongsToCurrentUser(int record_id) const
{
    if (currentUserIsAdmin())
        return true;

    // 记录本身没存录入人，归属得看它挂在哪位患者上 —— 与 sessions() 的过滤口径一致
    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT 1 FROM recording_sessions s"
        "  JOIN patients p ON p.patient_no = s.patient_no"
        " WHERE s.id = ? AND p.created_by = ? LIMIT 1"));
    query.addBindValue(record_id);
    query.addBindValue(m_current_user);
    if (!query.exec())
    {
        // 与 patientBelongsToCurrentUser 同一口径：出错记日志并拒绝，不静默
        qWarning() << "[db] 检查记录归属失败:" << query.lastError().text();
        return false;
    }
    return query.next();
}

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
    //
    // 可见性过滤：管理员不加条件看全部，其余角色只看自己录入的（created_by = 账号）。
    // 与 LEFT JOIN 搭配时条件写在 WHERE 里针对的是患者行，语义正确
    QString sql = QStringLiteral(
        "SELECT p.patient_no, p.name, p.gender, p.age, p.department, p.diagnosis, p.note,"
        "       p.created_at,"
        "       COUNT(s.id) AS record_count,"
        "       COALESCE(MAX(s.started_at), '') AS last_record"
        "  FROM patients p"
        "  LEFT JOIN recording_sessions s ON s.patient_no = p.patient_no");
    if (!currentUserIsAdmin())
        sql += QStringLiteral(" WHERE p.created_by = ?");
    sql += QStringLiteral(" GROUP BY p.patient_no ORDER BY p.patient_no");

    QSqlQuery query(m_database);
    query.prepare(sql);
    // 绑定值必须与占位符同进同出 —— 只在拼了 WHERE 时才 bind
    if (!currentUserIsAdmin())
        query.addBindValue(m_current_user);
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
        // 同一件事给一个原始数值：选患者弹窗里要拼成「1次记录」，
        // 而从 "1 次" 这个字符串里往回抠数字是自找麻烦
        row[QStringLiteral("recordCount")] = count;
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
        "INSERT INTO patients(patient_no, name, gender, age, department, diagnosis, note,"
        "                    created_by, created_at) "
        "VALUES(?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))"));
    query.addBindValue(number);
    query.addBindValue(trimmed_name);
    query.addBindValue(gender.trimmed());
    query.addBindValue(std::max(0, age));
    query.addBindValue(department.trimmed());
    query.addBindValue(diagnosis.trimmed());
    query.addBindValue(note.trimmed());
    // 记下录入人：非管理员之后只能看到自己登记的患者（见 patients()）
    query.addBindValue(m_current_user);

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

    // 非管理员只能删自己录入的患者。列表里看不到的患者，这里也必须改不动
    if (!patientBelongsToCurrentUser(patient_no))
    {
        qWarning() << "[db] 拒绝删除非本人录入的患者:" << patient_no;
        return false;
    }

    // 这位患者名下所有记录落盘的文件路径要在删行之前查出来 —— 行一删就再也指不回文件
    QStringList recorded_files;
    QSqlQuery locate(m_database);
    locate.prepare(QStringLiteral(
        "SELECT file_path FROM recording_sessions WHERE patient_no = ?"));
    locate.addBindValue(patient_no);
    if (locate.exec())
    {
        while (locate.next())
        {
            const QString path = locate.value(0).toString();
            if (!path.isEmpty())
                recorded_files.append(path);
        }
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("DELETE FROM patients WHERE patient_no = ?"));
    query.addBindValue(patient_no);
    if (!query.exec())
    {
        qWarning() << "[db] 删除患者失败:" << query.lastError().text();
        return false;
    }

    // 采集记录跟着删：留着一堆指向已删患者的行，汇总查询要在 join 条件上
    // 额外排除它们，不如一起清掉。
    // 顺序是先事件再记录 —— 反过来的话，取「这位患者的记录 id」那一句就查不到东西了
    QSqlQuery events(m_database);
    events.prepare(QStringLiteral(
        "DELETE FROM session_events WHERE session_id IN "
        "(SELECT id FROM recording_sessions WHERE patient_no = ?)"));
    events.addBindValue(patient_no);
    events.exec();

    QSqlQuery sessions(m_database);
    sessions.prepare(QStringLiteral("DELETE FROM recording_sessions WHERE patient_no = ?"));
    sessions.addBindValue(patient_no);
    sessions.exec();

    // 库行删完再删磁盘文件。删不掉（被占用、已被手工移走）不算删除失败 ——
    // 记录确实已经没了，只是留一条日志；与 removeSession 同一口径。
    // 放在最后是为了万一上面 DB 删除失败（提前 return）时，文件先没掉就两头空了
    for (const QString &path : recorded_files)
    {
        if (QFile::exists(path) && !QFile::remove(path))
            qWarning() << "[db] 患者已删除，但原始文件删不掉:" << path;
    }
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

    // 非管理员只能改自己录入的患者。归属按改之前的病历号判定
    if (!patientBelongsToCurrentUser(original_no))
    {
        result[QStringLiteral("message")] = QStringLiteral("无权修改该患者");
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

    // 可见性过滤与患者列表同一口径：管理员看全部，其余角色只看自己录入患者的记录。
    // 记录本身没存录入人，归属得看它挂在哪位患者上（patients.created_by）。
    // 「按患者筛选」和「按录入人过滤」是并且关系，必须拼进同一句 WHERE
    const bool filter_by_patient = !patient_no.trimmed().isEmpty();
    const bool restrict_owner = !currentUserIsAdmin();

    QString sql = columns;
    if (filter_by_patient || restrict_owner)
    {
        sql += QStringLiteral(" WHERE ");
        if (filter_by_patient)
            sql += QStringLiteral("s.patient_no = ?");
        if (filter_by_patient && restrict_owner)
            sql += QStringLiteral(" AND ");
        if (restrict_owner)
            sql += QStringLiteral("p.created_by = ?");
    }
    sql += QStringLiteral(" ORDER BY s.id DESC");
    query.prepare(sql);

    // 绑定顺序必须跟占位符出现的顺序一致
    if (filter_by_patient)
        query.addBindValue(patient_no.trimmed());
    if (restrict_owner)
        query.addBindValue(m_current_user);

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
        const QString time_text = format_stamp(query.value(3).toString());

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
                                   int event_count, const QString &file_path,
                                   const QVariantList &events)
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
    {
        qWarning() << "[db] 补全采集记录失败:" << query.lastError().text();
        return;
    }

    if (events.isEmpty())
        return;

    // 事件要挂到刚补完的那条记录上，所以得把它的 id 取回来。取法必须与上面
    // 那句 UPDATE 完全一致（同一位患者、id 最大的那条），否则事件会挂到别人的记录上
    QSqlQuery locate(m_database);
    locate.prepare(QStringLiteral(
        "SELECT id FROM recording_sessions WHERE patient_no = ? ORDER BY id DESC LIMIT 1"));
    locate.addBindValue(patient_no.trimmed());
    if (!locate.exec() || !locate.next())
    {
        qWarning() << "[db] 事件落库时找不到对应记录:" << patient_no;
        return;
    }
    const int session_id = locate.value(0).toInt();

    // 重复写保护：同一份事件被写第二遍时先清掉旧的
    QSqlQuery clear(m_database);
    clear.prepare(QStringLiteral("DELETE FROM session_events WHERE session_id = ?"));
    clear.addBindValue(session_id);
    clear.exec();

    QSqlQuery insert(m_database);
    insert.prepare(QStringLiteral(
        "INSERT INTO session_events(session_id, offset_s, wall_clock, label, color) "
        "VALUES(?, ?, ?, ?, ?)"));
    for (const QVariant &entry : events)
    {
        const QVariantMap event = entry.toMap();
        insert.bindValue(0, session_id);
        insert.bindValue(1, event.value(QStringLiteral("offsetSeconds")).toDouble());
        insert.bindValue(2, event.value(QStringLiteral("wallClock")).toString());
        insert.bindValue(3, event.value(QStringLiteral("label")).toString());
        insert.bindValue(4, event.value(QStringLiteral("dotColor")).toString());
        if (!insert.exec())
        {
            qWarning() << "[db] 写入事件失败:" << insert.lastError().text();
            return;
        }
    }
}

QVariantList AppDatabase::sessionEvents(const QString &record_no)
{
    QVariantList rows;
    const int id = parse_record_id(record_no);
    if (id < 0 || !ensureOpen())
        return rows;

    // 与 session() 同一口径：越权时返回空列表
    if (!sessionBelongsToCurrentUser(id))
        return rows;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT offset_s, wall_clock, label, color FROM session_events"
        " WHERE session_id = ? ORDER BY offset_s"));
    query.addBindValue(id);
    if (!query.exec())
    {
        qWarning() << "[db] 查询事件失败:" << query.lastError().text();
        return rows;
    }

    while (query.next())
    {
        QVariantMap row;
        row[QStringLiteral("offsetSeconds")] = query.value(0).toDouble();
        row[QStringLiteral("wallClock")] = query.value(1).toString();
        row[QStringLiteral("label")] = query.value(2).toString();
        row[QStringLiteral("color")] = query.value(3).toString();
        rows.append(row);
    }
    return rows;
}

// ==================== 采集记录（单条） ====================

QVariantMap AppDatabase::session(const QString &record_no)
{
    QVariantMap row;
    const int id = parse_record_id(record_no);
    if (id < 0 || !ensureOpen())
        return row;

    // 非管理员只能看自己录入患者的记录。越权时返回空 map（与「记录不存在」同形），
    // 不给出「存在但无权」这种能用来探测别人数据的信息
    if (!sessionBelongsToCurrentUser(id))
        return row;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "SELECT s.id, s.patient_no, p.name, p.gender, p.age, p.department, s.started_at,"
        "       s.duration_s, s.channel_count, s.sample_rate, s.event_count, s.file_path"
        "  FROM recording_sessions s"
        "  LEFT JOIN patients p ON p.patient_no = s.patient_no"
        " WHERE s.id = ? LIMIT 1"));
    query.addBindValue(id);
    if (!query.exec() || !query.next())
    {
        if (query.lastError().isValid())
            qWarning() << "[db] 查询采集记录失败:" << query.lastError().text();
        return row;
    }

    const int duration = query.value(7).toInt();

    row[QStringLiteral("no")] = QStringLiteral("R-%1").arg(id, 4, 10, QLatin1Char('0'));
    row[QStringLiteral("patientNo")] = query.value(1).toString();
    row[QStringLiteral("patient")] = query.value(2).toString().isEmpty()
                                         ? QStringLiteral("（已删除患者）")
                                         : query.value(2).toString();
    row[QStringLiteral("gender")] = query.value(3).toString();
    row[QStringLiteral("age")] = query.value(4).toInt();
    row[QStringLiteral("dept")] = query.value(5).toString();
    row[QStringLiteral("time")] = format_stamp(query.value(6).toString());
    row[QStringLiteral("durationSeconds")] = duration;
    row[QStringLiteral("duration")] = QStringLiteral("%1:%2:%3")
                                          .arg(duration / 3600, 2, 10, QLatin1Char('0'))
                                          .arg((duration / 60) % 60, 2, 10, QLatin1Char('0'))
                                          .arg(duration % 60, 2, 10, QLatin1Char('0'));
    row[QStringLiteral("channels")] = query.value(8).toInt();
    row[QStringLiteral("rate")] = query.value(9).toInt();
    row[QStringLiteral("events")] = query.value(10).toInt();
    row[QStringLiteral("filePath")] = query.value(11).toString();
    // 电极质量没有数据源（协议只给 4 路不带电极名的阻抗），与 sessions() 保持一致
    row[QStringLiteral("quality")] = QStringLiteral("—");
    row[QStringLiteral("level")] = QString();
    return row;
}

bool AppDatabase::removeSession(const QString &record_no)
{
    const int id = parse_record_id(record_no);
    if (id < 0 || !ensureOpen())
        return false;

    // 非管理员只能删自己录入患者的记录，与 sessions() 的可见性口径一致
    if (!sessionBelongsToCurrentUser(id))
    {
        qWarning() << "[db] 拒绝删除非本人录入的记录:" << record_no;
        return false;
    }

    // 落盘路径要在删行之前读出来
    QString recorded;
    QSqlQuery locate(m_database);
    locate.prepare(QStringLiteral("SELECT file_path FROM recording_sessions WHERE id = ?"));
    locate.addBindValue(id);
    if (locate.exec() && locate.next())
        recorded = locate.value(0).toString();

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("DELETE FROM recording_sessions WHERE id = ?"));
    query.addBindValue(id);
    if (!query.exec())
    {
        qWarning() << "[db] 删除采集记录失败:" << query.lastError().text();
        return false;
    }

    // 事件跟着记录一起删。留着一堆指向已删记录的行，只会让库越来越大，
    // 而它们再也查不出来（查询都是按 session_id 走的）
    QSqlQuery events(m_database);
    events.prepare(QStringLiteral("DELETE FROM session_events WHERE session_id = ?"));
    events.addBindValue(id);
    events.exec();

    // 落盘的原始文件也删掉。删记录却留着数据文件的话，确认框上那句
    // 「删除后无法恢复」就是假的：数据还好端端躺在磁盘上，只是界面再也看不到它。
    // 删不掉（文件被占用、已被手工移走）不算删除失败 —— 记录确实已经没了，
    // 只是记一条日志
    if (!recorded.isEmpty())
    {
        if (QFile::exists(recorded) && !QFile::remove(recorded))
            qWarning() << "[db] 记录已删除，但原始文件删不掉:" << recorded;
    }
    return true;
}

QVariantMap AppDatabase::exportSession(const QString &record_no, const QString &directory)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;
    result[QStringLiteral("path")] = QString();
    result[QStringLiteral("isRawFile")] = false;

    // 归属校验在 session() 内部完成：非本人录入的记录会返回空 map，
    // 下面统一按「记录不存在」处理 —— 导出这条越权路径就此堵上，也不再额外透露存在性
    const QVariantMap row = session(record_no);
    if (row.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("记录不存在");
        return result;
    }

    // QML 侧 StandardPaths.writableLocation 给的是 file:/// 形式的 URL（QML 的 url
    // 类型，本身没有 toLocalFile），直接拿去构造 QDir 会判定为不存在的目录，
    // 所以先按 URL 解成本地路径再用
    QString target_path = directory;
    if (target_path.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive))
        target_path = QUrl(target_path).toLocalFile();

    const QDir target_dir(target_path);
    if (target_path.isEmpty() || !target_dir.exists())
    {
        result[QStringLiteral("message")] = QStringLiteral("导出目录不可用");
        return result;
    }

    // 脱敏开关打开时，导出的文件名与摘要里的患者姓名 / 病历号一并打码。
    // 导出物离开程序后就不再受界面开关约束，必须在写出的这一刻就换掉；
    // 只打码「展示用」的这两项，记录号（R-0011）与采集参数照旧 —— 那不是患者身份信息
    const bool masked = maskingEnabled();
    QString export_patient_no = row.value(QStringLiteral("patientNo")).toString();
    QString export_patient = row.value(QStringLiteral("patient")).toString();
    if (masked)
    {
        if (!export_patient_no.isEmpty())
            export_patient_no = QStringLiteral("***");
        if (!export_patient.isEmpty())
            export_patient = QStringLiteral("***");
    }

    // 文件名带上患者与记录号，导出一堆记录时不至于分不清谁是谁
    const QString stem = QStringLiteral("%1_%2")
                             .arg(row.value(QStringLiteral("no")).toString(), export_patient_no);

    const QString recorded = row.value(QStringLiteral("filePath")).toString();
    if (!recorded.isEmpty() && QFile::exists(recorded))
    {
        QString suffix = QFileInfo(recorded).suffix();
        if (suffix.isEmpty())
            suffix = QStringLiteral("bdf");
        const QString target = target_dir.filePath(stem + QLatin1Char('.') + suffix);

        // 目标已存在时 QFile::copy 会失败。先删掉旧的：反复导出覆盖上一次
        // 才是预期行为，报「文件已存在」只会让人以为导出坏了
        if (QFile::exists(target) && !QFile::remove(target))
        {
            result[QStringLiteral("message")] = QStringLiteral("目标文件被占用，无法覆盖：%1").arg(target);
            return result;
        }
        if (!QFile::copy(recorded, target))
        {
            result[QStringLiteral("message")] = QStringLiteral("复制原始数据失败");
            return result;
        }

        result[QStringLiteral("success")] = true;
        result[QStringLiteral("isRawFile")] = true;
        result[QStringLiteral("path")] = target;
        result[QStringLiteral("message")] = QStringLiteral("已导出原始数据：%1").arg(target);
        audit_log::record(QStringLiteral("导出采集记录：%1（原始数据）→ %2")
                              .arg(record_no, target));
        return result;
    }

    // 没有原始文件可导。写一份记录摘要，并在提示里说清这不是脑电数据
    const QString target = target_dir.filePath(stem + QStringLiteral("_记录摘要.csv"));
    QFile file(target);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
    {
        result[QStringLiteral("message")] = QStringLiteral("无法写入导出文件");
        return result;
    }

    QTextStream out(&file);
    // Excel 打开 UTF-8 的 CSV 要带 BOM，否则中文列名是乱码
    out.setEncoding(QStringConverter::Utf8);
    out << QChar(0xFEFF);
    out << QStringLiteral("项目,内容\n");
    out << QStringLiteral("记录ID,") << row.value(QStringLiteral("no")).toString() << "\n";
    out << QStringLiteral("患者,") << export_patient << "\n";
    out << QStringLiteral("病历号,") << export_patient_no << "\n";
    out << QStringLiteral("采集时间,") << row.value(QStringLiteral("time")).toString() << "\n";
    out << QStringLiteral("时长,") << row.value(QStringLiteral("duration")).toString() << "\n";
    out << QStringLiteral("通道数,") << row.value(QStringLiteral("channels")).toInt() << "\n";
    out << QStringLiteral("采样率,") << row.value(QStringLiteral("rate")).toInt() << "\n";
    out << QStringLiteral("事件数,") << row.value(QStringLiteral("events")).toInt() << "\n";
    out << QStringLiteral("电极质量,") << row.value(QStringLiteral("quality")).toString() << "\n";
    out << QStringLiteral("说明,本次采集未落盘原始数据，此文件仅为记录摘要\n");
    file.close();

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("path")] = target;
    result[QStringLiteral("message")] = QStringLiteral("该记录没有落盘原始数据，已导出记录摘要：%1").arg(target);
    audit_log::record(QStringLiteral("导出采集记录：%1（记录摘要）→ %2").arg(record_no, target));
    return result;
}

// ==================== 偏好设置 ====================
QString AppDatabase::setting(const QString &key, const QString &fallback) const
{
    // 注意：**「没设过」和「设成了空串」在这里是不分的**，两者都返回 fallback。
    // 对这个应用来说够用（所有设置项都有非空默认值，没人会把它设成空）
    const QString value = settingValue(key);
    return value.isEmpty() ? fallback : value;
}

bool AppDatabase::setSetting(const QString &key, const QString &value)
{
    if (!ensureOpen())
        return false;

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT OR REPLACE INTO app_settings(setting_key, setting_value) VALUES(?, ?)"));
    query.addBindValue(key);
    query.addBindValue(value);
    if (!query.exec())
    {
        qWarning() << "[db] 写入设置失败:" << key << query.lastError().text();
        return false;
    }
    return true;
}

QString AppDatabase::recordDirectory()
{
    const QString fallback = defaultRecordDirectory();
    const QString stored = settingValue(QStringLiteral("record_dir")).trimmed();

    // 存过、且本机这个目录真的在 → 尊重用户选的
    if (!stored.isEmpty() && stored != fallback && QDir(stored).exists())
        return QDir::toNativeSeparators(stored);

    // 其余情况统一回退默认值：从没存过，或存的是别处（换机器/重装）残留的旧路径。
    // 回退时把库里的值也改成默认，否则会出现「界面显示默认、落盘仍用旧路径」的裂脑
    if (stored != fallback)
        setSetting(QStringLiteral("record_dir"), fallback);
    return fallback;
}

// ==================== 标注标签 ====================

QVariantList AppDatabase::tags()
{
    QVariantList rows;
    if (!ensureOpen())
        return rows;

    // used：这个标签名有没有被任何一段历史事件标注过（session_events.label 按名字关联）。
    // 「已使用」的标签在界面上不允许删除（删除按钮置灰），改名字时要同步历史事件
    QSqlQuery query(m_database);
    if (!query.exec(QStringLiteral(
            "SELECT t.id, t.name, t.code, t.color, "
            "(SELECT COUNT(*) FROM session_events e WHERE e.label = t.name) AS used "
            "FROM tags t ORDER BY t.id")))
    {
        qWarning() << "[db] 查询标签失败:" << query.lastError().text();
        return rows;
    }

    while (query.next())
    {
        QVariantMap row;
        row[QStringLiteral("id")] = query.value(0).toInt();
        row[QStringLiteral("name")] = query.value(1).toString();
        row[QStringLiteral("code")] = query.value(2).toString();
        row[QStringLiteral("color")] = query.value(3).toString();
        row[QStringLiteral("used")] = query.value(4).toInt() > 0;
        rows.append(row);
    }
    return rows;
}

QVariantMap AppDatabase::addTag(const QString &name, const QString &code, const QString &color)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写标签名称");
        return result;
    }

    // 重名没有意义：事件列表里两个一模一样的标签分不清谁是谁
    QSqlQuery probe(m_database);
    probe.prepare(QStringLiteral("SELECT COUNT(*) FROM tags WHERE name = ?"));
    probe.addBindValue(trimmed);
    if (probe.exec() && probe.next() && probe.value(0).toInt() > 0)
    {
        result[QStringLiteral("message")] = QStringLiteral("标签「%1」已存在").arg(trimmed);
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT INTO tags(name, code, color, created_at) VALUES(?, ?, ?, datetime('now'))"));
    query.addBindValue(trimmed);
    query.addBindValue(code.trimmed());
    query.addBindValue(color);
    if (!query.exec())
    {
        qWarning() << "[db] 新增标签失败:" << query.lastError().text();
        result[QStringLiteral("message")] = query.lastError().text();
        return result;
    }

    result[QStringLiteral("success")] = true;
    result[QStringLiteral("id")] = query.lastInsertId().toInt();
    return result;
}

QVariantMap AppDatabase::updateTag(int tag_id, const QString &name, const QString &code,
                                   const QString &color)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写标签名称");
        return result;
    }

    // 改名字之前先记下旧名：session_events 是按标签名关联的，改名后要拿旧名
    // 去把历史事件的 label / color 一并改掉，否则历史标注会指向一个不存在的标签
    QString oldName;
    {
        QSqlQuery nameQuery(m_database);
        nameQuery.prepare(QStringLiteral("SELECT name FROM tags WHERE id = ?"));
        nameQuery.addBindValue(tag_id);
        if (nameQuery.exec() && nameQuery.next())
            oldName = nameQuery.value(0).toString();
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("UPDATE tags SET name = ?, code = ?, color = ? WHERE id = ?"));
    query.addBindValue(trimmed);
    query.addBindValue(code.trimmed());
    query.addBindValue(color);
    query.addBindValue(tag_id);
    if (!query.exec())
    {
        qWarning() << "[db] 修改标签失败:" << query.lastError().text();
        result[QStringLiteral("message")] = query.lastError().text();
        return result;
    }

    // 同步历史事件：新老名称都要改（名称没变时只更新颜色，也无副作用）
    if (!oldName.isEmpty())
    {
        QSqlQuery sync(m_database);
        sync.prepare(QStringLiteral(
            "UPDATE session_events SET label = ?, color = ? WHERE label = ?"));
        sync.addBindValue(trimmed);
        sync.addBindValue(color);
        sync.addBindValue(oldName);
        if (!sync.exec())
            qWarning() << "[db] 同步历史标签失败:" << sync.lastError().text();
    }

    result[QStringLiteral("success")] = true;
    return result;
}

bool AppDatabase::removeTag(int tag_id)
{
    if (!ensureOpen())
        return false;

    // 已经用它标注过历史事件的标签不允许删除（界面上删除按钮也置灰）：
    // 删掉会让那些历史事件的标注变成一个无主的名字
    {
        QSqlQuery usedQuery(m_database);
        usedQuery.prepare(QStringLiteral(
            "SELECT COUNT(*) FROM session_events WHERE label = (SELECT name FROM tags WHERE id = ?)"));
        usedQuery.addBindValue(tag_id);
        if (usedQuery.exec() && usedQuery.next() && usedQuery.value(0).toInt() > 0)
            return false;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("DELETE FROM tags WHERE id = ?"));
    query.addBindValue(tag_id);
    if (!query.exec())
    {
        qWarning() << "[db] 删除标签失败:" << query.lastError().text();
        return false;
    }
    return true;
}

// ==================== 用户 ====================

QVariantList AppDatabase::users()
{
    QVariantList rows;
    if (!ensureOpen())
        return rows;

    QSqlQuery query(m_database);
    // 内置超级管理员（见 kBuiltinAdminUser）不落库，这里再过滤一道做双保险
    if (!query.exec(QStringLiteral(
            "SELECT id, username, display_name, role, department, status, created_at, last_login"
            "  FROM users WHERE username <> 'admin' ORDER BY id")))
    {
        qWarning() << "[db] 查询用户失败:" << query.lastError().text();
        return rows;
    }

    while (query.next())
    {
        const QString created = query.value(6).toString();
        const QString last = query.value(7).toString();
        const QString status = query.value(5).toString();

        QVariantMap row;
        row[QStringLiteral("uid")] = QStringLiteral("U-%1")
                                         .arg(query.value(0).toInt(), 4, 10, QLatin1Char('0'));
        row[QStringLiteral("account")] = query.value(1).toString();
        row[QStringLiteral("name")] = query.value(2).toString();
        row[QStringLiteral("role")] = query.value(3).toString();
        // 老库上的用户没有部门，给一句「未分配」而不是留空 —— 空单元格看着像没加载出来
        row[QStringLiteral("dept")] = query.value(4).toString().isEmpty()
                                          ? QStringLiteral("未分配")
                                          : query.value(4).toString();
        row[QStringLiteral("status")] = status.isEmpty() ? QStringLiteral("启用") : status;
        // 注册时间只到天（设计稿就写到天），最后登录到秒
        row[QStringLiteral("registered")] = format_date(created);
        row[QStringLiteral("lastLogin")] = last.isEmpty() ? QStringLiteral("—")
                                                          : format_stamp(last);
        rows.append(row);
    }
    return rows;
}

namespace
{

// 用户表的写操作共用这几条校验，别在四个函数里各抄一遍
bool valid_account(const QString &account, QString *message)
{
    const QString trimmed = account.trimmed();
    if (trimmed.isEmpty())
    {
        *message = QStringLiteral("请填写用户名");
        return false;
    }
    // 用户名最多 30 个字符（前端输入框也有同样的长度限制）
    if (trimmed.length() > 30)
    {
        *message = QStringLiteral("用户名不能超过 30 个字符");
        return false;
    }
    // admin 是代码内置的超级管理员，账号名保留，不允许再建同名业务账号
    if (trimmed == kBuiltinAdminUser)
    {
        *message = QStringLiteral("用户名为系统保留（admin），请换一个");
        return false;
    }
    return true;
}

// 密码策略的唯一权威实现：设置密码的入口（新增用户 / 重置 / 修改）都调它，
// 别在几个函数里各写一份长度判断
bool valid_password(const QString &password, QString *message)
{
    if (password.isEmpty())
    {
        *message = QStringLiteral("请填写密码");
        return false;
    }
    if (password.length() < 8 || password.length() > 16)
    {
        *message = QStringLiteral("密码长度需为 8-16 位");
        return false;
    }
    // 「至少包含数字、英文字母中的两种」= 数字和字母都得出现
    bool has_digit = false;
    bool has_letter = false;
    for (const QChar &c : password)
    {
        if (c.isDigit())
        {
            has_digit = true;
        }
        else if (c.isLetter())
        {
            has_letter = true;
        }
    }
    if (!has_digit || !has_letter)
    {
        *message = QStringLiteral("密码至少包含数字、英文字母中的两种");
        return false;
    }
    return true;
}

const QStringList &known_statuses()
{
    static const QStringList statuses = {
        QStringLiteral("启用"), QStringLiteral("停用"), QStringLiteral("待审核")
    };
    return statuses;
}

} // namespace

QVariantMap AppDatabase::addUser(const QString &account, const QString &password,
                                 const QString &name, const QString &role,
                                 const QString &department)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    QString message;
    if (!valid_account(account, &message))
    {
        result[QStringLiteral("message")] = message;
        return result;
    }
    if (name.trimmed().isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写姓名");
        return result;
    }
    // 初始密码走统一策略：必填、8-16 位、数字与字母两类
    if (!valid_password(password, &message))
    {
        result[QStringLiteral("message")] = message;
        return result;
    }

    QSqlQuery probe(m_database);
    probe.prepare(QStringLiteral("SELECT COUNT(*) FROM users WHERE username = ?"));
    probe.addBindValue(account.trimmed());
    if (probe.exec() && probe.next() && probe.value(0).toInt() > 0)
    {
        result[QStringLiteral("message")] = QStringLiteral("用户名已存在");
        return result;
    }

    // 新账号一律「启用」：需要审核时由管理员在列表里改成「待审核」，
    // 而不是登记完发现自己登不进去
    const QString hashed_password = hash_password(password);
    if (hashed_password.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("密码处理失败，请重试");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "INSERT INTO users(username, password, display_name, role, department, status,"
        "                  created_at, last_login)"
        " VALUES(?, ?, ?, ?, ?, '启用', datetime('now'), '')"));
    query.addBindValue(account.trimmed());
    query.addBindValue(hashed_password);
    query.addBindValue(name.trimmed());
    const QString final_role =
        role.trimmed().isEmpty() ? QStringLiteral("医生") : role.trimmed();
    query.addBindValue(final_role);
    query.addBindValue(department.trimmed());
    if (!query.exec())
    {
        qWarning() << "[db] 新增用户失败:" << query.lastError().text();
        result[QStringLiteral("message")] = query.lastError().text();
        return result;
    }

    audit_log::record(QStringLiteral("创建账号：%1（账号：%2，角色：%3）")
                          .arg(name.trimmed(), account.trimmed(), final_role));

    result[QStringLiteral("success")] = true;
    return result;
}

QVariantMap AppDatabase::updateUser(const QString &account, const QString &name,
                                    const QString &role, const QString &department,
                                    const QString &status)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    QString message;
    if (!valid_account(account, &message))
    {
        result[QStringLiteral("message")] = message;
        return result;
    }
    if (name.trimmed().isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("请填写姓名");
        return result;
    }
    if (!known_statuses().contains(status))
    {
        result[QStringLiteral("message")] = QStringLiteral("账号状态不合法");
        return result;
    }

    // 编辑弹窗里的「账号状态」也能改成停用，是绕过 setUserStatus 的另一条路，
    // 同一条规则在这里再拦一道
    if (disablingSelf(account, status))
    {
        result[QStringLiteral("message")] = QStringLiteral("不能停用当前登录的账号");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral(
        "UPDATE users SET display_name = ?, role = ?, department = ?, status = ?"
        " WHERE username = ?"));
    query.addBindValue(name.trimmed());
    query.addBindValue(role.trimmed());
    query.addBindValue(department.trimmed());
    query.addBindValue(status);
    query.addBindValue(account.trimmed());
    if (!query.exec())
    {
        qWarning() << "[db] 修改用户失败:" << query.lastError().text();
        result[QStringLiteral("message")] = query.lastError().text();
        return result;
    }
    if (query.numRowsAffected() == 0)
    {
        result[QStringLiteral("message")] = QStringLiteral("用户「%1」不存在").arg(account);
        return result;
    }

    audit_log::record(QStringLiteral("修改账号：%1（角色：%2，状态：%3）")
                          .arg(account.trimmed(), role.trimmed(), status));

    result[QStringLiteral("success")] = true;
    return result;
}

QVariantMap AppDatabase::resetPassword(const QString &account, const QString &new_password)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }
    // 超级管理员写死在代码里，密码不可被重置
    if (account.trimmed() == kBuiltinAdminUser)
    {
        result[QStringLiteral("message")] = QStringLiteral("内置超级管理员不支持重置密码");
        return result;
    }
    QString message;
    if (!valid_password(new_password, &message))
    {
        result[QStringLiteral("message")] = message;
        return result;
    }

    const QString hashed_password = hash_password(new_password);
    if (hashed_password.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("密码处理失败，请重试");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("UPDATE users SET password = ? WHERE username = ?"));
    query.addBindValue(hashed_password);
    query.addBindValue(account.trimmed());
    if (!query.exec() || query.numRowsAffected() == 0)
    {
        qWarning() << "[db] 重置密码失败:" << account << query.lastError().text();
        result[QStringLiteral("message")] = QStringLiteral("用户「%1」不存在").arg(account);
        return result;
    }

    // 只记「重置了谁的密码」，密码本身绝不入日志
    audit_log::record(QStringLiteral("重置密码：%1").arg(account.trimmed()));

    result[QStringLiteral("success")] = true;
    return result;
}

bool AppDatabase::canChangeOwnPassword() const
{
    // 未登录（空）或内置超级管理员都不能自行修改密码
    const QString account = m_current_user.trimmed();
    return !account.isEmpty() && account != kBuiltinAdminUser;
}

QVariantMap AppDatabase::changePassword(const QString &old_password, const QString &new_password)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen())
    {
        result[QStringLiteral("message")] = QStringLiteral("数据库不可用");
        return result;
    }

    // 账号取当前登录身份，不接收调用方传入 —— 免得改到别人的密码上去
    const QString account = m_current_user.trimmed();
    if (account.isEmpty() || account == kBuiltinAdminUser)
    {
        result[QStringLiteral("message")] = QStringLiteral("当前账号不支持修改密码");
        return result;
    }
    QString message;
    if (!valid_password(new_password, &message))
    {
        result[QStringLiteral("message")] = message;
        return result;
    }

    QSqlQuery check(m_database);
    check.prepare(QStringLiteral("SELECT password FROM users WHERE username = ?"));
    check.addBindValue(account);
    if (!check.exec() || !check.next())
    {
        result[QStringLiteral("message")] = QStringLiteral("账号不存在，无法修改密码");
        return result;
    }
    if (!verify_password(old_password, check.value(0).toString(), nullptr))
    {
        audit_log::record(QStringLiteral("修改密码失败：原密码不正确"));
        result[QStringLiteral("message")] = QStringLiteral("原密码不正确");
        return result;
    }

    const QString hashed_password = hash_password(new_password);
    if (hashed_password.isEmpty())
    {
        result[QStringLiteral("message")] = QStringLiteral("密码处理失败，请重试");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("UPDATE users SET password = ? WHERE username = ?"));
    query.addBindValue(hashed_password);
    query.addBindValue(account);
    if (!query.exec() || query.numRowsAffected() == 0)
    {
        qWarning() << "[db] 修改密码失败:" << account << query.lastError().text();
        result[QStringLiteral("message")] = QStringLiteral("修改密码失败");
        return result;
    }

    // 只记「谁改了自己的密码」，密码本身绝不入日志
    audit_log::record(QStringLiteral("修改密码：%1").arg(account));

    result[QStringLiteral("success")] = true;
    return result;
}

QVariantMap AppDatabase::setUserStatus(const QString &account, const QString &status)
{
    QVariantMap result;
    result[QStringLiteral("success")] = false;

    if (!ensureOpen() || !known_statuses().contains(status))
    {
        result[QStringLiteral("message")] = QStringLiteral("账号状态不合法");
        return result;
    }

    if (disablingSelf(account, status))
    {
        result[QStringLiteral("message")] = QStringLiteral("不能停用当前登录的账号");
        return result;
    }

    QSqlQuery query(m_database);
    query.prepare(QStringLiteral("UPDATE users SET status = ? WHERE username = ?"));
    query.addBindValue(status);
    query.addBindValue(account.trimmed());
    if (!query.exec() || query.numRowsAffected() == 0)
    {
        result[QStringLiteral("message")] = QStringLiteral("用户「%1」不存在").arg(account);
        return result;
    }

    audit_log::record(QStringLiteral("修改账号状态：%1 → %2").arg(account.trimmed(), status));

    result[QStringLiteral("success")] = true;
    return result;
}
