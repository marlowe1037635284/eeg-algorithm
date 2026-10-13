#pragma once

#include <QObject>
#include <QString>

// 授权校验：每次启动读取可执行文件同级的 license.lic，配合 public_key.pem
// 用 OpenSSL 做 RSA 验签，并校验 MAC 绑定与有效期。
//
// 与参考实现（tms-client）严格对齐的两点：
//   1. 待验签串 = nlohmann::json 对 license["data"] 调用 dump() 的紧凑结果
//（键按字典序、无多余空格）。**必须**用 nlohmann 序列化：Qt 的 QJsonObject
//      会按插入序输出、格式也不同，签名必然对不上。
//   2. 签名是 RSA PKCS#1 v1.5 over SHA256(data 串)，与验证侧的默认填充一致。
//
// 失败策略是 fail-closed：默认 checked=false、valid=false。读不到文件、
// JSON 解析失败、验签失败、MAC 不符、字段缺失或已过期，一律判定无效，
// 界面据此拦截，不允许进入登录页。
class LicenseManager : public QObject
{
    Q_OBJECT

    // 是否已跑完一次校验（界面用它判断要不要弹拦截框）
    Q_PROPERTY(bool checked READ is_checked NOTIFY resultChanged)
    // 校验是否通过
    Q_PROPERTY(bool valid READ is_valid NOTIFY resultChanged)
    // 失败原因（中文，供弹窗显示）；通过时为空
    Q_PROPERTY(QString message READ message NOTIFY resultChanged)

public:
    explicit LicenseManager(QObject *parent = nullptr);

    bool is_checked() const { return m_checked; }
    bool is_valid() const { return m_valid; }
    QString message() const { return m_message; }

    // 执行一次校验。启动时调用；重复调用安全
    Q_INVOKABLE void verify();

    // 退出程序。授权失败弹窗的「确定」按钮调用它
    Q_INVOKABLE void quitApplication();

signals:
    void resultChanged();

private:
    void setResult(bool valid, const QString &message);

    bool m_checked = false;
    bool m_valid = false;
    QString m_message;
};
