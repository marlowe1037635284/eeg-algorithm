import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 应用入口。只管三件事：窗口、登录态、页面/弹窗路由。
// 账号库读写见 AuthDatabase.qml，界面本身见各页面文件。
//
// 结构：
//   DesignCanvas      把 1920×1080 的设计画布等比缩放到窗口大小
//   LoginPage         未登录时显示
//   pageLoader        按 currentPage 切换业务页
//   dialogLoader      弹窗，盖在当前页之上
//   各页面只管自己的内容，跳转通过信号交回这里，页面之间互不引用。
ApplicationWindow {
    id: window

    // 设计稿是 1920×1080，默认全屏：这样画布缩放正好是 1:1，界面不会发虚，
    // 也不会因为窗口比例和 16:9 不一致而在两侧留白。（最大化会受标题栏影响，
    // 客户区不足 1080 高，画布就得缩到 0.93 左右，字跟着糊。）
    width: 1920
    height: 1080
    visibility: Window.FullScreen
    visible: true
    color: Design.windowFill
    title: loggedIn ? qsTr("EEG-KSC 采集工作台") : qsTr("EEG-KSC 登录")

    // ---------- 登录态 ----------
    property bool loggedIn: false
    // 无人值守超时后置位：登录页切换成「设备已锁定」样式（锁图标 + 只留输入框）
    property bool locked: false
    property string currentUserName: ""
    property string currentUserRole: ""

    // ---------- 路由 ----------
    property string currentPage: "workbench"
    property string activeDialog: ""
    // 弹「采集记录预览」时要点开的那条记录号
    property string pendingRecordNo: ""

    // 工作台当前选中的患者病历号。它属于「本次会话」而不是患者表里的字段，
    // 所以放在这里由各页面共用（患者管理页拿它标出「当前」那一行）
    property string currentPatientNo: ""
    // 新增患者是从哪进来的："workbench" 表示选患者弹窗里点的登记，
    // 存完之后要把新患者选上并回工作台；"patients" 表示患者管理页点的，存完只要刷新列表
    property string newPatientOrigin: ""

    // 弹「编辑患者」「删除确认」时针对的那一行
    property var pendingPatientRow: null
    // 弹「编辑用户」「重置密码」时针对的那一行
    property var pendingUserRow: null
    // 弹「编辑标签」时针对的那一行（null 表示新建）
    property var pendingTagRow: null
    // 弹「删除标签」确认框时针对的那一个
    property int pendingTagId: 0
    property string pendingTagName: ""
    // 弹「删除记录」确认框时针对的那条记录号
    property string pendingRecordNoToDelete: ""
    // 本次采集属于哪位患者（用来在停止时把采集记录补全）。空串表示没有进行中的会话
    property string openSessionPatient: ""
    // 从患者管理页点「记录」进来时带的历史记录页过滤条件
    property string historyPatientFilter: ""
    // 「数据分析与后处理」要分析的那条记录号。它是**整屏替换**历史记录页的，
    // 记录号由历史记录页的「分析」按钮交上来
    property string analysisRecordNo: ""

    readonly property string defaultUserName: qsTr("管理员")
    readonly property string defaultUserRole: qsTr("管理员")

    // 只有管理员能进「用户管理」。角色为空（未登录）时按登录页给的默认口径走，
    // 与顶栏显示的角色保持同一个判断
    readonly property bool isAdmin: (currentUserRole.length > 0 ? currentUserRole : defaultUserRole)
                                    === defaultUserRole

    // 应用数据库：账号、偏好、患者共用同一个实例。
    //
    // 做成 Main 里的一个对象再显式传给需要的页面/弹窗，而不是让各处自己去开
    // 一个连接：SQLite 同文件多连接要自己处理锁，而且「文件放哪」的逻辑会散开
    AppDatabase {
        id: appDatabase
    }

    // 导出 PDF 用。无状态，只做「一条记录 → 一份 A4 报告」的排版
    RecordReport {
        id: recordReport
    }

    // 采集停止时把这次记录补全（时长、事件数、落盘路径）。
    //
    // 挂在 collectingChanged 上而不是工作台的停止按钮上：拔线、掉电时线程会自己
    // 结束并发出同一个信号，那种情况同样要把记录收尾
    Connections {
        target: Acq
        function onCollectingChanged() {
            if (Acq.collecting || window.openSessionPatient.length === 0)
                return
            var summary = Acq.collection_summary()
            // 事件要跟着记录一起存：只存个数的话，「采集记录预览」里那条事件带
            // 就永远是空的 —— 个数拼不回时刻与标签
            appDatabase.finishCollection(window.openSessionPatient, summary.durationSeconds,
                                         summary.eventCount, summary.filePath, Acq.events)
            window.openSessionPatient = ""
        }
    }

    // 无人值守超时 → 锁定界面。IdleGuard 由 main.cpp 注入（见 unattendedguard.h）
    Connections {
        target: IdleGuard
        function onIdleTimedOut() {
            window.handleIdleLockout()
        }
    }

    DesignCanvas {
        anchors.fill: parent

        LoginPage {
            id: loginPage
            anchors.fill: parent
            visible: !window.loggedIn
            enabled: visible
            // 无人值守超时锁定时，登录页换成「设备已锁定」样式
            locked: window.locked
            errorMessage: ""

            onLoginRequested: function(account, password, rememberPassword) {
                errorMessage = ""
                var result = appDatabase.authenticateOrRegister(account, password)
                if (!result.success) {
                    // 失败原因由数据层给（密码不对 / 账号被停用 / 还没过审），
                    // 这里不再一律说成「密码不正确」—— 被停用的人反复改密码是白费力气
                    errorMessage = result.message.length > 0
                                   ? result.message : qsTr("密码不正确，请重新输入")
                    clearPassword()
                    return
                }
                // 先完成登录并切页，再去存偏好设置：
                // 存设置属于「锦上添花」，不该因为它出错就把登录卡住。
                window.currentUserName = result.displayName
                window.currentUserRole = result.role
                // 把这个身份告诉数据层：管理员看全部患者，其余角色只看自己录入的。
                // 必须在读患者之前设置 —— 登录后进入的工作台/患者管理页都会按它取数据
                appDatabase.setCurrentUser(account, result.role)
                // 登录后按当前账号重取一次脱敏开关（设置存在库里，可能被别的账号改过）
                window.syncPrivacy()
                // 解锁：登录成功后清掉锁定态，表头恢复成「Welcome.」
                window.locked = false
                window.loggedIn = true
                window.enterWorkbench()
                // 登录成功后自动连接设备：串口从此独立于采集，一次连上后常开，
                // 「开始采集 / 阻抗扫描」不再各自补连。
                // 用 callLater 推迟到本帧渲染之后：connect_device 内部要等串口异步
                // 打开的结果（最多 2 秒），当场调用会把工作台的首帧一起卡住
                Qt.callLater(function() { Acq.connect_device() })
                appDatabase.saveLoginRecord(account, password, rememberPassword)
            }
        }

        Loader {
            id: pageLoader
            anchors.fill: parent
            visible: window.loggedIn
            enabled: visible
            sourceComponent: window.pageComponent()
        }

        Loader {
            id: dialogLoader
            anchors.fill: parent
            visible: window.loggedIn && window.activeDialog !== ""
            sourceComponent: window.dialogComponent()
        }

        // 授权校验失败的拦截框：盖在登录页与所有业务页之上，点「确定」退出程序。
        // 放在 Toast 之前，让「轻提示」仍然压在最上层（与下面的说明一致）
        LicenseAlertDialog {
            visible: License.checked && !License.valid
        }

        // 轻提示。放在弹窗层**之后**，所以即使弹着框也能看见
        //「已保存」这类反馈；它自己在顶栏中间那段空白里，不遮设计元素
        Toast {
            id: toast
        }
    }

    // 全应用统一的轻提示出口。页面/弹窗不各弹各的，免得两处同时在屏幕上说话
    function showToast(message, kind) {
        toast.show(message, kind)
    }

    // ---------- 路由逻辑 ----------

    // 导航项 → 页面标识
    function navigateTo(label) {
        // 从后处理页离开时把记录放掉：一条十分钟的记录映射着十几 MB，
        // 一直开着不划算。与预览弹窗关掉就 Recording.close() 是同一个理由
        if (currentPage === "analysis")
            Analysis.close()

        if (label === qsTr("采集工作台")) {
            currentPage = "workbench"
            // 等 Loader 把新页面实例化出来再回填患者卡片
            Qt.callLater(window.applyCurrentPatientToWorkbench)
        }
        else if (label === qsTr("患者管理"))
            currentPage = "patient"
        else if (label === qsTr("历史记录"))
            currentPage = "history"
        else if (label === qsTr("用户管理"))
        {
            // 非管理员在导航条里看不到这一项。这里再挡一道：万一被别处触发，
            // 也不让「用户管理」页切过去
            if (window.isAdmin)
                currentPage = "user"
        }
        else if (label === qsTr("系统设置"))
            currentPage = "settings"
    }

    function pageComponent() {
        switch (currentPage) {
        case "patient":  return patientPageComponent
        case "history":  return historyPageComponent
        case "user":     return userPageComponent
        case "settings": return settingsPageComponent
        case "analysis": return analysisPageComponent
        default:         return workbenchPageComponent
        }
    }

    // 历史记录页点「分析」：记下要分析哪一条，再换到后处理页。
    // 换页顺序不能反 —— 先把 currentPage 改了，页面在 Component.onCompleted
    // 里读 recordNo 时才是新值
    function openAnalysis(recordNo) {
        analysisRecordNo = recordNo
        currentPage = "analysis"
    }

    // 后处理页点「返回历史记录」
    function closeAnalysis() {
        Analysis.close()
        analysisRecordNo = ""
        currentPage = "history"
    }

    function dialogComponent() {
        switch (activeDialog) {
        case "precheck":      return precheckComponent
        case "selectPatient": return selectPatientComponent
        case "filter":        return filterComponent
        case "newPatient":    return newPatientComponent
        case "editPatient":   return editPatientComponent
        case "recordPreview": return recordPreviewComponent
        case "recordReport":  return recordReportComponent
        case "newTag":        return newTagComponent
        case "confirmDelete": return confirmDeleteComponent
        case "userEdit":      return userEditComponent
        case "resetPassword": return resetPasswordComponent
        case "changePassword": return changePasswordComponent
        case "confirmDeleteRecord": return confirmDeleteRecordComponent
        case "confirmDeleteTag":    return confirmDeleteTagComponent
        case "confirmLogout":       return confirmLogoutComponent
        case "deviceInfo":          return deviceInfoComponent
        default:              return null
        }
    }

    // 当前页面对象（Loader 里拿不到 id，只能通过 item 调页面的方法）
    function currentPageItem() {
        return pageLoader.item
    }

    // 按病历号在库里找一行患者。编辑 / 删除 / 刷新之后都要用最新的那一份，
    // 所以每次都重新查，不缓存
    function findPatientRow(patientNo) {
        if (!patientNo)
            return null
        var rows = appDatabase.patients()
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].no === patientNo)
                return rows[i]
        }
        return null
    }

    // 按账号在库里找一位用户。编辑 / 重置密码 / 启停之后都要用最新的那一份
    function findUserRow(account) {
        if (!account)
            return null
        var rows = appDatabase.users()
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].account === account)
                return rows[i]
        }
        return null
    }

    // 把库里的脱敏开关同步到全局 Privacy 单例。启动与登录各同步一次：
    // 启动是为了让登录页之后的页面一出来就是正确状态，登录是为了换账号后重取
    //（设置存在库里，别的账号可能刚改过）
    function syncPrivacy() {
        Privacy.enabled = appDatabase.setting("data_mask", "false") === "true"
    }

    // 导出一条采集记录。导出目录跟「系统设置 → 记录保存目录」用同一个 —— 记录本来就
    // 落在那里，导出再落到同一个地方，用户不必跑到两个目录里找东西。
    // recordDirectory() 会把「本机不存在的旧路径」自动纠正成默认目录，这里直接信它
    function exportRecord(recordNo) {
        var folder = appDatabase.recordDirectory()
        if (!folder || folder.length === 0) {
            showToast(qsTr("找不到可用的导出目录"), "error")
            return
        }

        var result = appDatabase.exportSession(recordNo, folder)
        showToast(result.message, result.success ? "success" : "error")
    }

    // 从预览弹窗里导出 PDF：排版全在 RecordReport 里做，这里只负责选目录与提示。
    // 与 exportRecord 的区别是产物 —— 那个导原始数据，这个导一份可读的报告
    function exportRecordPdf(recordNo) {
        var folder = appDatabase.recordDirectory()
        if (!folder || folder.length === 0) {
            showToast(qsTr("找不到可用的导出目录"), "error")
            return
        }

        // 脱敏开关打开时，交给报告排版的这份数据先把患者姓名 / 病历号换掉：
        // RecordReport 只负责排版、不碰数据库，脱敏必须在数据交给它之前完成。
        // session() 返回的是 JS 对象副本，改它不会写回本页其它地方的取数
        var detail = appDatabase.session(recordNo)
        if (Privacy.enabled) {
            if (detail.patient && detail.patient.length > 0)
                detail.patient = "***"
            if (detail.patientNo && detail.patientNo.length > 0)
                detail.patientNo = "***"
        }

        var result = recordReport.exportPdf(detail,
                                            appDatabase.sessionEvents(recordNo), folder)
        showToast(result.message, result.success ? "success" : "error")
    }

    function enterWorkbench() {
        currentPage = "workbench"
        activeDialog = ""
        var page = currentPageItem()
        if (page && page.resetSession)
            page.resetSession()
        // 会话里已经选过患者的话（比如从患者管理页设的），卡片直接显示他。
        // 延到下一轮事件循环：此刻 Loader 可能还没把工作台实例化出来
        Qt.callLater(window.applyCurrentPatientToWorkbench)
    }

    function closeDialog() {
        activeDialog = ""
    }

    // 点顶栏账号菜单里的「修改密码」。内置超级管理员不能改（canChangeOwnPassword
    // 为假），这里直接提示而不是弹一个必然失败的框
    function openChangePassword() {
        if (!appDatabase.canChangeOwnPassword()) {
            showToast(qsTr("超级管理员账号不支持修改密码"), "info")
            return
        }
        activeDialog = "changePassword"
    }

    function openRecordPreview(recordNo) {
        pendingRecordNo = recordNo
        activeDialog = "recordPreview"
    }

    function openRecordReport(recordNo) {
        pendingRecordNo = recordNo
        activeDialog = "recordReport"
    }

    // 选择/登记患者之后，把工作台的卡片也切成这一位
    function applyCurrentPatientToWorkbench() {
        var page = currentPageItem()
        if (page && page.setPatient) {
            var row = findPatientRow(currentPatientNo)
            if (row)
                page.setPatient(row)
        }
    }

    // 点「退出登录」先弹确认框：退出会断开设备、放掉当前会话，
    // 手滑点到就得重新登录一遍，值得多问一句。真正的退出在 handleLogout 里
    function requestLogout() {
        activeDialog = "confirmLogout"
    }

    // 退出登录 / 锁屏共用的会话清理：放掉当前会话、断开设备、清掉数据层身份。
    // 只做「会话」这一层，不动 loggedIn / locked —— 那两个由调用方决定
    function endSession() {
        currentPatientNo = ""
        historyPatientFilter = ""
        analysisRecordNo = ""
        openSessionPatient = ""
        pendingPatientRow = null
        // 后处理页可能开着一条记录：退出登录时把它放掉，别把文件留在手里
        Analysis.close()
        var page = window.currentPageItem()
        if (page && page.stopCollection)
            page.stopCollection()
        // 串口不再随采集关闭（登录后常开），退出登录时显式断开：
        // 这是除「关闭程序」外唯一的断开时机（界面上不设手动断开入口）
        Acq.close_port()
        activeDialog = ""
        // 清掉会话身份：不这样做的话，下一个登录的人在数据层眼里仍是上一个人，
        // 非管理员会继承到别人的可见范围
        appDatabase.setCurrentUser("", "")
    }

    function handleLogout() {
        endSession()
        locked = false
        loggedIn = false
        if (!loginPage.rememberChecked)
            loginPage.clearPassword()
    }

    // 无人值守超时：清会话并切到「设备已锁定」登录页。
    // 未登录时无事可做 —— 人已经在登录页上了，再锁一次没有意义
    function handleIdleLockout() {
        if (!loggedIn)
            return
        endSession()
        locked = true
        loggedIn = false
        // 锁定页是给「下一个人」用的，账号密码都不该留着
        loginPage.accountText = ""
        loginPage.clearPassword()
    }

    // ---------- 页面组件 ----------

    Component {
        id: workbenchPageComponent

        WorkbenchPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            // 事件标签取自系统设置里维护的那一份。工作台每次进入都会重建，
            // 所以这里读一次就是最新的
            tags: appDatabase.tags()
            // 落盘目录同理：工作台重建时读一次设置，采集时就近用它。
            // recordDirectory() 会把「本机不存在的旧路径」自动纠正成默认目录
            recordDir: appDatabase.recordDirectory()

            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onNavRequested: (label) => window.navigateTo(label)
            onNotifyRequested: (message, kind) => window.showToast(message, kind)
            // 点「开始采集」先弹确认框，确认后才真正开始
            onPrecheckRequested: window.activeDialog = "precheck"
            onSelectPatientRequested: window.activeDialog = "selectPatient"
            onFilterRequested: window.activeDialog = "filter"
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"
        }
    }

    Component {
        id: patientPageComponent

        PatientManagementPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            database: appDatabase
            currentPatientNo: window.currentPatientNo

            // 每次进这一页都重新读一遍库：在别处新增/删除过患者之后，
            // 页面重建时拿到的必须是新数据
            Component.onCompleted: reload()

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"
            onNewPatientRequested: {
                window.newPatientOrigin = "patients"
                window.activeDialog = "newPatient"
            }
            onPatientActivated: (patientNo) => {
                window.currentPatientNo = patientNo
                // 工作台可能还没建（它由 Loader 按需实例化），所以这里只改会话状态；
                // 进工作台时 resetSession 会清掉，需要重选 —— 但 currentPatientNo
                // 是会话级的，工作台卡片由用户自己再点一次选择，语义上更清楚
            }
            onOpenRecordsRequested: (patientNo) => {
                window.currentPatientNo = patientNo
                window.historyPatientFilter = patientNo
                window.navigateTo(qsTr("历史记录"))
            }
            onEditPatientRequested: (recordNo) => {
                window.pendingPatientRow = window.findPatientRow(recordNo)
                window.activeDialog = "editPatient"
            }
            onDeletePatientRequested: (patientNo) => {
                window.pendingPatientRow = window.findPatientRow(patientNo)
                window.activeDialog = "confirmDelete"
            }
        }
    }

    Component {
        id: historyPageComponent

        HistoryPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            database: appDatabase

            // 每次重建这一页都按当前的过滤条件读一遍库
            Component.onCompleted: applyPatientFilter(window.historyPatientFilter)

            onNavRequested: (label) => {
                // 从导航栏离开这一页时把过滤清掉，下次点「历史记录」看到的应该是全部
                if (label !== qsTr("历史记录"))
                    window.historyPatientFilter = ""
                window.navigateTo(label)
            }
            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"
            onRecordPreviewRequested: (recordNo) => window.openRecordPreview(recordNo)
            onRecordReportRequested: (recordNo) => window.openRecordReport(recordNo)
            // 删除是不可撤销的，先弹确认框
            onRecordDeleteRequested: (recordNo) => {
                window.pendingRecordNoToDelete = recordNo
                window.activeDialog = "confirmDeleteRecord"
            }
            onRecordExportRequested: (recordNo) => window.exportRecord(recordNo)
            onAnalysisRequested: (recordNo) => window.openAnalysis(recordNo)
        }
    }

    Component {
        id: analysisPageComponent

        AnalysisPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            database: appDatabase
            recordNo: window.analysisRecordNo

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"
            onBackRequested: window.closeAnalysis()
            onNotifyRequested: (message, kind) => window.showToast(message, kind)
        }
    }

    Component {
        id: userPageComponent

        UserManagementPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            database: appDatabase

            // 每次进这一页都重新读一遍库：在别处改过账号（比如刚登录时自动登记的
            // 新用户）之后，页面重建时拿到的必须是新数据
            Component.onCompleted: reload()

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"

            onAddUserRequested: {
                window.pendingUserRow = null
                window.activeDialog = "userEdit"
            }
            onEditUserRequested: (account) => {
                window.pendingUserRow = window.findUserRow(account)
                window.activeDialog = "userEdit"
            }
            onResetPasswordRequested: (account) => {
                window.pendingUserRow = window.findUserRow(account)
                window.activeDialog = "resetPassword"
            }
            // 启停直接生效：可逆的操作不值得再来一道确认
            onToggleStatusRequested: (account, nextStatus) => {
                var result = appDatabase.setUserStatus(account, nextStatus)
                if (!result.success) {
                    window.showToast(result.message, "error")
                    return
                }
                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                window.showToast(qsTr("已%1账号「%2」").arg(nextStatus).arg(account),
                                 nextStatus === qsTr("启用") ? "success" : "info")
            }
        }
    }

    Component {
        id: settingsPageComponent

        SystemSettingsPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole
            database: appDatabase

            // 进页面时把库里的设置读进草稿，标签也重新读一遍
            Component.onCompleted: {
                loadSettings()
                reload()
            }

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.requestLogout()
            onChangePasswordRequested: window.openChangePassword()
            onDeviceInfoRequested: window.activeDialog = "deviceInfo"
            // 新增与编辑共用同一个弹窗，靠 pendingTagRow 是否为空区分
            onNewTagRequested: {
                window.pendingTagRow = null
                window.activeDialog = "newTag"
            }
            onEditTagRequested: (tag) => {
                window.pendingTagRow = tag
                window.activeDialog = "newTag"
            }
            onDeleteTagRequested: (tagId, tagName) => {
                window.pendingTagId = tagId
                window.pendingTagName = tagName
                window.activeDialog = "confirmDeleteTag"
            }
            onSaved: window.showToast(qsTr("设置已保存"), "success")
        }
    }

    // ---------- 弹窗组件 ----------

    Component {
        id: precheckComponent

        PrecheckDialog {
            // 患者从工作台当前状态读，弹窗自己不存一份
            readonly property var page: window.currentPageItem()
            hasPatient: page !== null && page.hasPatient === true
            patientName: hasPatient ? page.patientName : ""
            patientGenderAge: hasPatient ? page.patientGenderAge : ""
            patientMeta: hasPatient ? page.patientMeta : ""

            onDismissed: window.closeDialog()
            onAccepted: {
                window.closeDialog()
                var page = window.currentPageItem()
                if (!page)
                    return
                // 先开一条采集记录再开采集：患者管理页的「采集次数 / 最近采集」
                // 两列和历史记录页都是从 recording_sessions 来的
                if (page.patientNo && page.patientNo.length > 0) {
                    // 采样率用**实际落盘**的速率：设备固定 1000Hz，系统设置选 2000 时
                    // 文件会升采样成 2000Hz，记录行要与文件头一致（否则历史列表和
                    // 分析页会对同一次采集显示出两个采样率）
                    appDatabase.recordCollection(page.patientNo, Acq.acquired_channel_count(),
                                                 Acq.effective_record_sample_rate())
                    // 记下这次会话属于谁，停止时用它补全记录
                    window.openSessionPatient = page.patientNo
                }
                if (page.startCollection)
                    page.startCollection()
            }
        }
    }

    Component {
        id: selectPatientComponent

        SelectPatientDialog {
            database: appDatabase
            Component.onCompleted: reload()

            onDismissed: window.closeDialog()

            onNewPatientRequested: {
                window.newPatientOrigin = "workbench"
                window.closeDialog()
                window.activeDialog = "newPatient"
            }

            onAccepted: {
                window.closeDialog()
                var rows = archiveRows
                if (selectedIndex < 0 || selectedIndex >= rows.length)
                    return
                window.currentPatientNo = rows[selectedIndex].no
                // 工作台左上角的卡片从「未选择患者」切成患者信息
                var page = window.currentPageItem()
                if (page && page.setPatient)
                    page.setPatient(rows[selectedIndex])
            }
        }
    }

    Component {
        id: filterComponent

        FilterDialog {
            onDismissed: window.closeDialog()
            onApplied: {
                window.closeDialog()
                window.showToast(qsTr("滤波参数已更新"), "success")
            }
        }
    }

    Component {
        id: newPatientComponent

        NewPatientDialog {
            database: appDatabase
            onDismissed: window.closeDialog()
            onAccepted: {
                var no = savedPatientNo
                window.closeDialog()

                if (window.newPatientOrigin === "patients") {
                    // 从患者管理页进来的：刷新列表就行
                    var patientPage = window.currentPageItem()
                    if (patientPage && patientPage.reload)
                        patientPage.reload()
                    return
                }

                // 从选患者弹窗进来的：把刚登记的这位选上，直接回工作台
                window.newPatientOrigin = ""
                var rows = appDatabase.patients()
                for (var i = 0; i < rows.length; ++i) {
                    if (rows[i].no === no) {
                        window.currentPatientNo = no
                        var page = window.currentPageItem()
                        if (page && page.setPatient)
                            page.setPatient(rows[i])
                        return
                    }
                }
            }
        }
    }

    Component {
        id: editPatientComponent

        EditPatientDialog {
            database: appDatabase
            Component.onCompleted: {
                if (window.pendingPatientRow)
                    load(window.pendingPatientRow)
            }
            onDismissed: window.closeDialog()
            onAccepted: {
                window.closeDialog()
                // 改了姓名/科室的话，工作台与患者页上显示的那一份要跟着更新
                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                if (window.pendingPatientRow
                        && window.pendingPatientRow.no === window.currentPatientNo) {
                    var refreshed = window.findPatientRow(window.currentPatientRowNo)
                    if (refreshed)
                        window.currentPatientRowNo = refreshed.no
                }
                window.pendingPatientRow = null
            }
        }
    }

    Component {
        id: recordPreviewComponent

        RecordPreviewDialog {
            database: appDatabase
            recordNo: window.pendingRecordNo
            onDismissed: {
                // 关掉预览就把文件释放掉：一条 10 分钟的记录映射着约 38 MB，
                // 一直开着不划算
                Recording.close()
                window.closeDialog()
            }
            onExportRequested: (recordNo) => window.exportRecordPdf(recordNo)
        }
    }

    Component {
        id: recordReportComponent

        ReportDialog {
            database: appDatabase
            recordNo: window.pendingRecordNo
            onDismissed: {
                // 关掉报告同样要把波形文件释放掉
                Recording.close()
                window.closeDialog()
            }
            onExportRequested: (recordNo) => window.exportRecordPdf(recordNo)
        }
    }

    Component {
        id: confirmDeleteComponent

        ConfirmDialog {
            title: qsTr("删除患者")
            confirmText: qsTr("删除")
            danger: true
            message: window.pendingPatientRow
                     ? qsTr("确定要删除「%1」吗？该患者的档案与全部采集记录都会被删除，且无法恢复。")
                           .arg(Privacy.masked(window.pendingPatientRow.name))
                     : ""
            onDismissed: window.closeDialog()
            onAccepted: {
                window.closeDialog()
                if (!window.pendingPatientRow)
                    return
                var no = window.pendingPatientRow.no
                appDatabase.removePatient(no)
                window.pendingPatientRow = null
                if (window.currentPatientNo === no)
                    window.currentPatientNo = ""
                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
            }
        }
    }

    Component {
        id: newTagComponent

        NewTagDialog {
            database: appDatabase
            Component.onCompleted: openFor(window.pendingTagRow)

            onDismissed: {
                window.closeDialog()
                window.pendingTagRow = null
            }
            onAccepted: {
                var wasEdit = editMode
                window.closeDialog()
                window.pendingTagRow = null

                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                window.showToast(wasEdit ? qsTr("标签已保存") : qsTr("标签已创建"), "success")
            }
        }
    }

    Component {
        id: confirmDeleteTagComponent

        ConfirmDialog {
            title: qsTr("删除标签")
            confirmText: qsTr("删除")
            danger: true
            message: window.pendingTagName.length > 0
                     ? qsTr("确定要删除标签「%1」吗？已用它标注过的历史事件不会被改动。")
                           .arg(window.pendingTagName)
                     : ""
            onDismissed: window.closeDialog()
            onAccepted: {
                var tagId = window.pendingTagId
                var tagName = window.pendingTagName
                window.closeDialog()
                window.pendingTagId = 0
                window.pendingTagName = ""

                if (!appDatabase.removeTag(tagId)) {
                    window.showToast(qsTr("删除标签失败"), "error")
                    return
                }
                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                window.showToast(qsTr("已删除标签「%1」").arg(tagName), "success")
            }
        }
    }

    Component {
        id: userEditComponent

        UserDialog {
            database: appDatabase
            Component.onCompleted: openFor(window.pendingUserRow)

            onDismissed: {
                window.closeDialog()
                window.pendingUserRow = null
            }
            onAccepted: {
                // 先把要用来报信的信息读出来：closeDialog() 会让 Loader 立刻销毁本对象
                var wasEdit = editMode
                var who = wasEdit ? editingAccount : accountText
                window.closeDialog()
                window.pendingUserRow = null

                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                window.showToast(wasEdit ? qsTr("已保存用户「%1」").arg(who)
                                         : qsTr("已新增用户「%1」").arg(who), "success")
            }
        }
    }

    Component {
        id: resetPasswordComponent

        ResetPasswordDialog {
            database: appDatabase
            Component.onCompleted: openFor(window.pendingUserRow)

            onDismissed: {
                window.closeDialog()
                window.pendingUserRow = null
            }
            onAccepted: {
                var who = displayName.length > 0 ? displayName : account
                window.closeDialog()
                window.pendingUserRow = null
                window.showToast(qsTr("已重置「%1」的密码").arg(who), "success")
            }
        }
    }

    // 用户自己改密码（顶栏账号菜单进入）。改的是当前登录账号，账号由数据层取，
    // 弹窗这边不传 —— 也就无从改到别人头上
    Component {
        id: changePasswordComponent

        ChangePasswordDialog {
            database: appDatabase
            Component.onCompleted: open()
            onDismissed: window.closeDialog()
            onAccepted: {
                window.closeDialog()
                window.showToast(qsTr("密码已修改"), "success")
            }
        }
    }

    Component {
        id: confirmDeleteRecordComponent

        ConfirmDialog {
            title: qsTr("删除采集记录")
            confirmText: qsTr("删除")
            danger: true
            // 说清楚原始文件也会被删：只删记录的话，那句「无法恢复」是假的，
            // 数据还好端端躺在磁盘上
            message: window.pendingRecordNoToDelete.length > 0
                     ? qsTr("确定要删除采集记录「%1」吗？该记录的事件标注与已落盘的原始数据文件都会一并删除，且无法恢复。")
                           .arg(window.pendingRecordNoToDelete)
                     : ""
            onDismissed: window.closeDialog()
            onAccepted: {
                var recordNo = window.pendingRecordNoToDelete
                window.closeDialog()
                window.pendingRecordNoToDelete = ""
                if (recordNo.length === 0)
                    return

                if (!appDatabase.removeSession(recordNo)) {
                    window.showToast(qsTr("删除记录失败"), "error")
                    return
                }
                var page = window.currentPageItem()
                if (page && page.reload)
                    page.reload()
                window.showToast(qsTr("已删除记录「%1」").arg(recordNo), "success")
            }
        }
    }

    Component {
        id: confirmLogoutComponent

        ConfirmDialog {
            title: qsTr("退出登录")
            confirmText: qsTr("退出登录")
            message: qsTr("确定要退出登录吗？")
            onDismissed: window.closeDialog()
            onAccepted: window.handleLogout()
        }
    }

    // 设备连接信息：只读展示，关掉即可
    Component {
        id: deviceInfoComponent

        DeviceInfoDialog {
            onDismissed: window.closeDialog()
        }
    }

    // ---------- 启动 ----------

    Component.onCompleted: {
        // 脱敏开关先同步一次：它存在库里，与登录与否无关，
        // 早于任何页面出现，避免首帧闪一下未脱敏的数据
        window.syncPrivacy()

        // 账号库在 AppDatabase 构造时就建好了表，这里只负责回填输入框。
        //
        // **没有登录记录时什么都不做**，让登录页保持自己那份默认值
        //（admin / admin123456，与代码内置的超级管理员一致）——
        // 清成空的话，每次开程序都要把账号密码重敲一遍，而版本库里那个
        // 模板本来就一条登录记录都不带。
        //
        // 有记录时：账号总是回填，密码只有当初勾了「记住密码」才回填
        //（没勾的话数据层已经把密码删了，这里也取不到）
        const last = appDatabase.lastLogin()
        if (!last.hasRecord)
            return
        // 账号总是回填；「记住密码」只在 Debug 构建里回填密码 —— 发布版没有该功能，
        // 不能把之前 Debug 跑出来的记录回填进输入框
        loginPage.accountText = last.phone
        if (AppDebugBuild) {
            loginPage.rememberChecked = last.remember
            loginPage.passwordText = last.remember ? last.password : ""
        }
    }
}
