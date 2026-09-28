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
    color: "#eef2f5"
    title: loggedIn ? qsTr("EEG-KSC 采集工作台") : qsTr("EEG-KSC 登录")

    // ---------- 登录态 ----------
    property bool loggedIn: false
    property string currentUserName: ""
    property string currentUserRole: ""

    // ---------- 路由 ----------
    property string currentPage: "workbench"
    property string activeDialog: ""
    // 弹「采集记录预览」时要点开的那条记录号
    property string pendingRecordNo: ""

    readonly property string defaultUserName: qsTr("管理员")
    readonly property string defaultUserRole: qsTr("管理员")

    AuthDatabase {
        id: authDatabase
    }

    DesignCanvas {
        anchors.fill: parent

        LoginPage {
            id: loginPage
            anchors.fill: parent
            visible: !window.loggedIn
            enabled: visible
            errorMessage: ""

            onLoginRequested: function(account, password, rememberPassword) {
                errorMessage = ""
                var result = authDatabase.authenticateOrRegister(account, password)
                if (!result.success) {
                    errorMessage = qsTr("密码不正确，请重新输入")
                    clearPassword()
                    return
                }
                // 先完成登录并切页，再去存偏好设置：
                // 存设置属于「锦上添花」，不该因为它出错就把登录卡住。
                window.currentUserName = result.displayName
                window.currentUserRole = result.role
                window.loggedIn = true
                window.enterWorkbench()
                authDatabase.saveLoginRecord(account, password, rememberPassword)
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
    }

    // ---------- 路由逻辑 ----------

    // 导航项 → 页面标识
    function navigateTo(label) {
        if (label === qsTr("采集工作台"))
            currentPage = "workbench"
        else if (label === qsTr("患者管理"))
            currentPage = "patient"
        else if (label === qsTr("历史记录"))
            currentPage = "history"
        else if (label === qsTr("用户管理"))
            currentPage = "user"
        else if (label === qsTr("系统设置"))
            currentPage = "settings"
    }

    function pageComponent() {
        switch (currentPage) {
        case "patient":  return patientPageComponent
        case "history":  return historyPageComponent
        case "user":     return userPageComponent
        case "settings": return settingsPageComponent
        default:         return workbenchPageComponent
        }
    }

    function dialogComponent() {
        switch (activeDialog) {
        case "precheck":      return precheckComponent
        case "selectPatient": return selectPatientComponent
        case "newPatient":    return newPatientComponent
        case "editPatient":   return editPatientComponent
        case "recordPreview": return recordPreviewComponent
        case "newTag":        return newTagComponent
        default:              return null
        }
    }

    // 当前页面对象（Loader 里拿不到 id，只能通过 item 调页面的方法）
    function currentPageItem() {
        return pageLoader.item
    }

    function enterWorkbench() {
        currentPage = "workbench"
        activeDialog = ""
        var page = currentPageItem()
        if (page && page.resetSession)
            page.resetSession()
    }

    function closeDialog() {
        activeDialog = ""
    }

    function openRecordPreview(recordNo) {
        pendingRecordNo = recordNo
        activeDialog = "recordPreview"
    }

    function handleLogout() {
        var page = currentPageItem()
        if (page && page.stopCollection)
            page.stopCollection()
        activeDialog = ""
        loggedIn = false
        if (!loginPage.rememberChecked)
            loginPage.clearPassword()
    }

    // ---------- 页面组件 ----------

    Component {
        id: workbenchPageComponent

        WorkbenchPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole

            onLogoutRequested: window.handleLogout()
            onNavRequested: (label) => window.navigateTo(label)
            // 点「开始采集」先弹确认框，确认后才真正开始
            onPrecheckRequested: window.activeDialog = "precheck"
            onSelectPatientRequested: window.activeDialog = "selectPatient"
        }
    }

    Component {
        id: patientPageComponent

        PatientManagementPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onNewPatientRequested: window.activeDialog = "newPatient"
            onEditPatientRequested: (recordNo) => window.activeDialog = "editPatient"
        }
    }

    Component {
        id: historyPageComponent

        HistoryPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onRecordPreviewRequested: (recordNo) => window.openRecordPreview(recordNo)
        }
    }

    Component {
        id: userPageComponent

        UserManagementPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
        }
    }

    Component {
        id: settingsPageComponent

        SystemSettingsPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : window.defaultUserName
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : window.defaultUserRole

            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onNewTagRequested: window.activeDialog = "newTag"
        }
    }

    // ---------- 弹窗组件 ----------

    Component {
        id: precheckComponent

        PrecheckDialog {
            onDismissed: window.closeDialog()
            onAccepted: {
                window.closeDialog()
                var page = window.currentPageItem()
                if (page && page.startCollection)
                    page.startCollection()
            }
        }
    }

    Component {
        id: selectPatientComponent

        SelectPatientDialog {
            onDismissed: window.closeDialog()
            onAccepted: window.closeDialog()
        }
    }

    Component {
        id: newPatientComponent

        NewPatientDialog {
            onDismissed: window.closeDialog()
            onAccepted: window.closeDialog()
        }
    }

    Component {
        id: editPatientComponent

        EditPatientDialog {
            onDismissed: window.closeDialog()
            onAccepted: window.closeDialog()
        }
    }

    Component {
        id: recordPreviewComponent

        RecordPreviewDialog {
            recordNo: window.pendingRecordNo.length > 0 ? window.pendingRecordNo : "R-0011"
            onDismissed: window.closeDialog()
            onAccepted: window.closeDialog()
        }
    }

    Component {
        id: newTagComponent

        NewTagDialog {
            onDismissed: window.closeDialog()
            onAccepted: window.closeDialog()
        }
    }

    // ---------- 启动 ----------

    Component.onCompleted: {
        // 账号库在 AuthDatabase 构造时就建好了表和默认管理员，这里只负责回填输入框。
        //
        // 从没登录过时按设计稿的样子：输入框留空显示占位提示、「记住密码」勾上；
        // 登录过之后：手机号总是回填，密码只有勾了「记住密码」才回填。
        var last = authDatabase.lastLogin()
        loginPage.rememberChecked = last.hasRecord ? last.remember : true
        loginPage.accountText = last.phone
        loginPage.passwordText = (last.remember && last.password.length > 0) ? last.password : ""
    }
}
