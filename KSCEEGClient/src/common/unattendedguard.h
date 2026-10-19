#pragma once

#include <QObject>
#include <QString>

class QEvent;
class QTimer;

// 无人值守自动锁屏的默认阈值（分钟）。配置文件里没写 / 写坏时用它。
inline constexpr int kDefaultUnattendedAutoExitMinutes = 60;

// client-config.json 的路径：先看可执行文件同级（打包后的正式形态），
// 再看源码目录（开发期直接跑 build/ 里的 exe 时用）。
QString client_config_path();

// 从配置文件 client-config.json 读「无人值守自动退出」的分钟数。
//
// 配置文件路径按「可执行文件同级 → 源码目录（开发期从 build/ 里跑）」的顺序解析，
// 与数据库模板 eeg-ksc.db 同一套约定；两处都没有时返回 fallback。
//
// 字段 unattended_auto_exit_minutes：
//   > 0   空闲超过这么多分钟就锁定设备
//   <= 0  关闭该功能
// 字段缺失或类型不对时返回 fallback。
int unattended_auto_exit_minutes(int fallback);

// 无人值守锁屏：连续一段时间没有任何鼠标 / 键盘操作就锁定设备、回到登录页。
//
// 场景是临床工作台「人离开但程序还开着」—— 不管的话，下一个走到机器前的人会
// 直接接着上一个人的登录态继续用。
//
// 实现：在应用上装一个事件过滤器，任何一次用户输入都把计时器清零；连续空闲超过
// 阈值就发出 idleTimedOut() 信号，由 QML 切到「设备已锁定」登录页。
// 阈值 <= 0 时不装过滤器、不起计时器，功能关闭。
class UnattendedGuard : public QObject
{
    Q_OBJECT

public:
    explicit UnattendedGuard(int timeout_minutes, QObject *parent = nullptr);
    ~UnattendedGuard() override;

    // 当前是否启用（阈值 > 0）
    bool is_active() const { return m_timeout_ms > 0; }

signals:
    // 连续空闲超过阈值时发出，QML 收到后切到「设备已锁定」登录页。
    void idleTimedOut();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    QTimer *m_timer = nullptr;
    int m_timeout_ms = 0;
};
