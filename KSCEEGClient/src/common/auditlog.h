#pragma once

#include <QString>

// 审计日志：记录「谁、什么时候、做了什么」。
//
// 覆盖三类事件：
//   - 用户：登录、退出，以及登录后进行的各类操作
//   - 账号：创建、修改、重置密码、启停
//   - 核心功能：采集过程、后处理过程、导出
//
// 每条记录固定四个字段：用户ID、日期、时间、事件。落盘为按行分隔的文本，
// 字段之间用 " | "（竖线）分隔。事件永远排在最后，因此事件文本里出现竖线
// 也不会影响前三个字段的解析。
//
// 落盘位置沿用既有约定：%LOCALAPPDATA%\EEG-KSC\logs\audit.log
//（与 pythonengine 的 log_dir() 是同一个目录，只是文件名不同）。
//
// 「用户ID」取登录账号（users.username），也就是登录页上填的手机号。不用用户
// 管理页里那个 U-0001 的原因：登录失败时账号可能根本不存在，拿不到 uid，而失败
// 的尝试同样要留痕；用账号名这两种情形都能记。
//
// 线程安全：内部用互斥锁保护当前用户与写文件，可从任意线程调用。
namespace audit_log
{

// 设置 / 清除「当前登录用户」。登录成功后由 AppDatabase::setCurrentUser 调用，
// 之后 record() 就用这个身份；退出登录时清除。
// 明确知道用户是谁时（登录失败、账号管理）用 record_as，绕开这份环境态。
void set_current_user(const QString &user_id);
void clear_current_user();
QString current_user();

// 记一条以「当前登录用户」为操作者的日志
void record(const QString &event);

// 记一条指定用户的日志（登录失败、账号管理等场景）
void record_as(const QString &user_id, const QString &event);

// 日志文件的完整路径（供诊断与文档说明用）
QString log_file_path();

} // namespace audit_log
