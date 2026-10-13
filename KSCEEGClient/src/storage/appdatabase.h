#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// 应用本地数据库（SQLite）：账号、偏好设置、患者档案、标签、采集记录。
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
//
// ==================== 版本库里的这一份是**表结构模板** ====================
// 仓库里跟踪的 eeg-ksc.db 只承载表结构，里面**不留运行期数据**（内置超级管理员
// admin 写死在代码里，不落库，见 appdatabase.cpp 的 kBuiltinAdmin*）。
// 部署时把它拷到运行目录，程序在那一份上读写。
//
// 由此推出两条约定：
//   1. 表结构变了（加表、加列）要**同步改这一份模板**。只靠 createTables() 里的
//      CREATE TABLE IF NOT EXISTS 也能在老库上补出新表，但模板里没有的话，
//      新部署的机器要等第一次启动才建表，中间那段空窗期不好排查
//   2. 别拿它当测试库用。**开发期默认连的正是这一份**（见 appdatabase.cpp 的
//      defaultDatabasePath），调试产生的患者与采集记录会直接写进模板。
//      提交前记得清一下：各表清空、自增计数归零（admin 不落库，无需保留）
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

    // 用「账号 + 密码」登录：
    //   内置超级管理员 admin → 凭据写死在代码里，不查库、不落库，也不进用户列表；
    //   其余账号 → 库里已有则校验密码，库里没有一律拒绝（账号开通走用户管理页）。
    // 返回 { success, displayName, role, isNew }
    Q_INVOKABLE QVariantMap authenticateOrRegister(const QString &phone, const QString &password);

    // 最近一次登录的信息：{ phone, password, remember, hasRecord }
    Q_INVOKABLE QVariantMap lastLogin();

    // 记录最近一次登录（remember 为假时不保存密码）
    Q_INVOKABLE void saveLoginRecord(const QString &phone, const QString &password, bool remember);

    // ==================== 会话 ====================
    // 登录成功后由界面告知「现在是谁」，供患者可见性过滤使用：
    // 管理员看全部患者，其余角色只看自己录入的那一批（patients.created_by = 账号）。
    //
    // 判断放在数据层而不是各页面各写一遍 —— 患者列表有好几个入口
    //（患者管理页、选患者弹窗、历史记录页的患者下拉），漏一处就是一次越权可见
    Q_INVOKABLE void setCurrentUser(const QString &account, const QString &role);

    // ==================== 患者 ====================

    // 全部患者，按病历号排序。每一项的键与患者管理页表格的列一一对应：
    //   { no, name, gender, age, dept, diag, note, count, recordCount, last, createdAt }
    // count 是给表格直接贴的「6 次」；recordCount 是同一个数的原始值，
    // 给需要自己拼文案的地方用（选患者弹窗里的「1次记录」）
    //
    // 可见性与角色挂钩：管理员返回全部，其余角色只返回自己录入的
    //（created_by = 当前账号，见 setCurrentUser）。过滤做在这里而不是各页面，
    // 是为了让所有入口口径一致
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
    // 可见性与患者列表同一口径：管理员返回全部，其余角色只返回自己录入患者的记录
    //（记录没存录入人，靠它所属患者的 patients.created_by 判定）。
    // 每一项的键与历史记录页表格的列一一对应：
    //   { no, patientNo, patient, time, duration, channels, rate, events, quality, level }
    // 电极质量没有数据源（协议只给 4 路不带电极名的阻抗），固定返回「—」
    Q_INVOKABLE QVariantList sessions(const QString &patient_no);

    // 单条采集记录的全部字段（「采集记录预览」弹窗用）。
    // record_no 是界面上的那个编号（R-0011），不是主键 id。
    // 取不到时返回空 map
    Q_INVOKABLE QVariantMap session(const QString &record_no);

    // 一条记录里的事件标注，按时间先后。每一项：
    //   { offsetSeconds, wallClock, label, color }
    Q_INVOKABLE QVariantList sessionEvents(const QString &record_no);

    // 删一条采集记录：事件标注与**落盘的原始文件**一并删掉。
    // 留着文件的话确认框上那句「删除后无法恢复」就是假的
    Q_INVOKABLE bool removeSession(const QString &record_no);

    // 把一条采集记录导出到指定目录，返回 { success, message, path, isRawFile }。
    // 采集时落了盘就把那个原始文件复制过去；没落盘（比如采集中途退出、
    // 记录是旧版本写下的）就只能导出记录摘要的 CSV，并在 message 里说明 ——
    // 导出一份「看起来像数据但不是数据」的文件比拒绝导出更糟
    Q_INVOKABLE QVariantMap exportSession(const QString &record_no, const QString &directory);

    // ==================== 偏好设置 ====================
    // 全应用的键值对设置（app_settings 表）。系统设置页写、别处读。
    // 取不到（或存的是空串）时返回 fallback
    Q_INVOKABLE QString setting(const QString &key, const QString &fallback = QString()) const;
    Q_INVOKABLE bool setSetting(const QString &key, const QString &value);

    // 记录保存目录（record_dir 的专用读法）。库里存的值若指向本机不存在的路径
    // （典型是换一台机器后残留的旧路径），回退到默认值（exe 同级 records）并写回库，
    // 保证界面显示和实际落盘用的是同一个目录
    Q_INVOKABLE QString recordDirectory();

    // ==================== 标注标签 ====================
    // 标签管理页与工作台的「手动标记」共用这一份。每一项：
    //   { id, name, code, color }
    // code 是设备侧的触发编码（设计稿里的 "101,102"），配色供事件标记取用
    Q_INVOKABLE QVariantList tags();
    Q_INVOKABLE QVariantMap addTag(const QString &name, const QString &code, const QString &color);
    Q_INVOKABLE QVariantMap updateTag(int tag_id, const QString &name, const QString &code,
                                      const QString &color);
    Q_INVOKABLE bool removeTag(int tag_id);

    // ==================== 用户 ====================
    // 用户管理页的表格数据，按注册先后（id）排序。每一项：
    //   { uid, account, name, role, dept, status, registered, lastLogin }
    Q_INVOKABLE QVariantList users();
    // 新增 / 修改 / 重置密码 / 启停 / 删除，统一返回 { success, message }
    Q_INVOKABLE QVariantMap addUser(const QString &account, const QString &password,
                                    const QString &name, const QString &role,
                                    const QString &department);
    Q_INVOKABLE QVariantMap updateUser(const QString &account, const QString &name,
                                       const QString &role, const QString &department,
                                       const QString &status);
    // 重置密码：管理员在用户管理页重置别人（或自己）的密码。内置超级管理员
    //  不在列表、也不落库，这里再挡一道 —— 「超级管理员除外」
    Q_INVOKABLE QVariantMap resetPassword(const QString &account, const QString &new_password);
    // 用户自行修改密码：校验原密码，账号取当前登录身份（改不了别人的）。
    // 内置超级管理员不走这里（见 canChangeOwnPassword），返回 { success, message }
    Q_INVOKABLE QVariantMap changePassword(const QString &old_password, const QString &new_password);
    // 当前登录账号能否自行修改密码：内置超级管理员 admin 返回 false
    Q_INVOKABLE bool canChangeOwnPassword() const;
    Q_INVOKABLE QVariantMap setUserStatus(const QString &account, const QString &status);

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

    // 停止采集时把这条记录补全（时长、事件数、落盘路径），并把这次的事件标注
    // 一并存下来。分两次写而不是攒到停止时一次性写：中途崩了/掉电时，至少留下
    //「什么时候采过」。
    //
    // events 是 Acq.events 那一份（每项含 offsetSeconds/wallClock/label/dotColor），
    // 原样交给数据层拆列。事件不跟着记录存的话，「采集记录预览」里那条事件带
    // 就永远是空的 —— 记录里只存了事件**个数**，个数拼不回时刻与标签
    Q_INVOKABLE void finishCollection(const QString &patient_no, int duration_seconds,
                                      int event_count, const QString &file_path,
                                      const QVariantList &events = QVariantList());

private:
    bool ensureOpen();
    bool createTables();
    // 给已存在的表补列。CREATE TABLE IF NOT EXISTS 不会动已有的表，
    // 所以加字段必须显式 ALTER —— 否则老库上那些列永远不存在
    void ensure_column(const QString &table, const QString &column, const QString &definition);
    QString settingValue(const QString &key) const;
    // 下一个可用的病历号（P-0001 起）。生成规则只留这一处，别在别处再拼一次
    QString nextPatientNo() const;
    // 当前会话是不是管理员。角色为空（未登录）一律按非管理员处理，
    // 宁可少看也不要让未登录状态看到全部患者
    bool currentUserIsAdmin() const;

    // 归属校验：管理员放行；其余角色要求目标由当前账号录入
    //（patients.created_by = 当前账号）。patients()/sessions() 里的可见性过滤
    // 只管「读列表」，这里是「改 / 删 / 导出单条」那一侧 —— 两侧必须是同一套规则，
    // 否则别人看不到的患者仍然能被改、被删、被导出
    bool patientBelongsToCurrentUser(const QString &patient_no) const;
    bool sessionBelongsToCurrentUser(int record_id) const;

    QSqlDatabase m_database;
    QString m_path;
    // 当前登录账号（users.username）。新增患者时写进 patients.created_by，
    // 也是非管理员查询时的过滤条件
    QString m_current_user;
    // 当前登录角色，用来决定是否放开全部患者
    QString m_current_role;
};
