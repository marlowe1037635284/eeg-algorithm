#include "common/licensemanager.h"

#include <QCoreApplication>
#include <QFile>
#include <QNetworkInterface>
#include <QStringList>
#include <QtDebug>

#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/sha.h>

#include <nlohmann/json.hpp>

#include <ctime>
#include <exception>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "common/auditlog.h"

namespace
{

using json = nlohmann::json;

// 授权文件与公钥都放在可执行文件同级目录，文件名与参考实现一致
constexpr const char *kLicenseFileName = "license.lic";
constexpr const char *kPublicKeyFileName = "public_key.pem";

// 一次性读入整个文件。走 QFile 而不是 ifstream：Windows 上路径可能带中文，
// QFile 会正确地按宽字符打开，ifstream 按 UTF-8 就找不到文件了
std::string read_file_utf8(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        throw std::runtime_error("open file failed: " + path.toStdString());

    const QByteArray content = file.readAll();
    return std::string(content.constData(), static_cast<size_t>(content.size()));
}

// Base64 解码。与参考实现同一套 BIO 用法（无换行、一次性读出）
std::string base64_decode(const std::string &in)
{
    BIO *bio = BIO_new_mem_buf(in.data(), static_cast<int>(in.size()));
    BIO *b64 = BIO_new(BIO_f_base64());
    bio = BIO_push(b64, bio);
    BIO_set_flags(bio, BIO_FLAGS_BASE64_NO_NL);

    std::vector<char> out(in.size());
    const int decoded_length = BIO_read(bio, out.data(), static_cast<int>(in.size()));

    if (decoded_length < 0)
    {
        BIO_free_all(bio);
        throw std::runtime_error("base64 decode failed");
    }

    BIO_free_all(bio);
    return std::string(out.data(), static_cast<size_t>(decoded_length));
}

// 从 PEM 文本读 RSA 公钥
EVP_PKEY *load_public_key(const std::string &pem)
{
    BIO *bio = BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size()));
    if (!bio)
        throw std::runtime_error("allocate bio failed");

    EVP_PKEY *pkey = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);

    if (!pkey)
        throw std::runtime_error("read public key failed");

    if (EVP_PKEY_id(pkey) != EVP_PKEY_RSA)
    {
        EVP_PKEY_free(pkey);
        throw std::runtime_error("public key is not RSA");
    }

    return pkey;
}

// 本机所有网卡的 MAC（冒号换成横线），格式与参考实现一致
QStringList local_mac_addresses()
{
    QStringList list;
    const QList<QNetworkInterface> interfaces = QNetworkInterface::allInterfaces();
    for (const QNetworkInterface &interface : interfaces)
    {
        if (interface.hardwareAddress().isEmpty())
            continue;

        QString mac = interface.hardwareAddress();
        mac.replace(QLatin1Char(':'), QLatin1Char('-'));
        list.append(mac);
    }
    return list;
}

bool parse_time(const std::string &text, const char *fmt, std::tm *out)
{
    std::istringstream ss(text);
    ss >> std::get_time(out, fmt);
    return !ss.fail();
}

// 验签：对 license["data"] 的紧凑序列化串做 SHA256，再 RSA 验签。
// data 串由 nlohmann 生成以保证与签发侧字节一致（见头文件说明）
bool verify_signature(const json &license, EVP_PKEY *pkey)
{
    const std::string data_str = license.at("data").dump();
    const std::string signature = base64_decode(license.at("signature").get<std::string>());

    unsigned char hash[SHA256_DIGEST_LENGTH];
    unsigned int hash_len = 0;
    if (EVP_Digest(data_str.data(), data_str.size(), hash, &hash_len, EVP_sha256(), nullptr) != 1)
        return false;

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(pkey, nullptr);
    if (!ctx)
        return false;

    bool ok = false;
    if (EVP_PKEY_verify_init(ctx) > 0
        && EVP_PKEY_CTX_set_signature_md(ctx, EVP_sha256()) > 0)
    {
        ok = EVP_PKEY_verify(ctx,
                             reinterpret_cast<const unsigned char *>(signature.data()),
                             signature.size(),
                             hash,
                             hash_len) > 0;
    }

    EVP_PKEY_CTX_free(ctx);
    return ok;
}

} // namespace

LicenseManager::LicenseManager(QObject *parent)
    : QObject(parent)
{
}

void LicenseManager::verify()
{
    const QString dir = QCoreApplication::applicationDirPath();
    const QString license_path = dir + QLatin1Char('/') + QString::fromLatin1(kLicenseFileName);
    const QString key_path = dir + QLatin1Char('/') + QString::fromLatin1(kPublicKeyFileName);

    if (!QFile::exists(license_path))
    {
        setResult(false, tr("未找到授权文件 license.lic。请将授权文件放到程序安装目录后重试。"));
        return;
    }
    if (!QFile::exists(key_path))
    {
        setResult(false, tr("未找到授权公钥 public_key.pem。请将公钥文件放到程序安装目录后重试。"));
        return;
    }

    json license;
    try
    {
        license = json::parse(read_file_utf8(license_path));
    }
    catch (const std::exception &)
    {
        setResult(false, tr("授权文件格式错误，无法解析。"));
        return;
    }

    if (!license.contains("data") || !license["data"].is_object() || !license.contains("signature"))
    {
        setResult(false, tr("授权文件内容不完整（缺少 data 或 signature 字段）。"));
        return;
    }

    EVP_PKEY *pkey = nullptr;
    try
    {
        pkey = load_public_key(read_file_utf8(key_path));
    }
    catch (const std::exception &e)
    {
        setResult(false, tr("读取公钥文件失败：%1").arg(QString::fromUtf8(e.what())));
        return;
    }

    bool signature_ok = false;
    try
    {
        signature_ok = verify_signature(license, pkey);
    }
    catch (const std::exception &)
    {
        signature_ok = false;
    }
    EVP_PKEY_free(pkey);

    if (!signature_ok)
    {
        setResult(false, tr("授权文件签名校验失败，文件可能已被篡改。"));
        return;
    }

    const std::string mac_in_license = license["data"].value("mac_address", std::string());
    if (mac_in_license.empty())
    {
        setResult(false, tr("授权文件缺少 MAC 地址绑定信息。"));
        return;
    }
    if (!local_mac_addresses().contains(QString::fromStdString(mac_in_license)))
    {
        setResult(false, tr("授权文件与本机不匹配（MAC 地址不一致）。"));
        return;
    }

    const std::string expire_str = license["data"].value("expire_date", std::string());
    if (expire_str.empty())
    {
        setResult(false, tr("授权文件缺少有效期信息。"));
        return;
    }

    std::tm tm{};
    if (!parse_time(expire_str, "%Y-%m-%dT%H:%M:%S", &tm))
    {
        setResult(false, tr("授权文件的有效期格式不正确。"));
        return;
    }
    if (std::mktime(&tm) < std::time(nullptr))
    {
        setResult(false, tr("授权已过期（有效期至 %1）。").arg(QString::fromStdString(expire_str)));
        return;
    }

    setResult(true, QString());
}

void LicenseManager::quitApplication()
{
    audit_log::record_as(QStringLiteral("system"),
                         QStringLiteral("授权校验未通过，退出程序"));
    QCoreApplication::quit();
}

void LicenseManager::setResult(bool valid, const QString &message)
{
    m_checked = true;
    m_valid = valid;
    m_message = message;

    audit_log::record_as(QStringLiteral("system"),
                         valid ? QStringLiteral("授权校验通过")
                               : QStringLiteral("授权校验失败：") + message);

    if (valid)
        qInfo().noquote() << "[license] 授权校验通过";
    else
        qWarning().noquote() << "[license] 授权校验失败:" << message;

    emit resultChanged();
}
