import QtQuick
import QtQuick.Controls.Basic
import QtQuick.LocalStorage

// 应用入口：登录页 + 各业务页面的路由 + 弹窗层。
//
// 结构说明：
//   DesignCanvas 负责把 1920×1080 的设计画布等比缩放到窗口大小；
//   页面用一个 Loader 按 currentPage 切换，弹窗用一个 Loader 叠在页面之上。
//   页面本身只管自己的内容，不知道窗口尺寸，也不管跳转（通过信号交给这里处理）。
ApplicationWindow {
    id: window

    width: 1440
    height: 810
    minimumWidth: 1100
    minimumHeight: 680
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

    // 当前页面对象（Loaders 里拿不到 id，用 item 调页面的方法）
    function currentPageItem() {
        return pageLoader.item
    }

    // ---------- 本地账号数据库 ----------
    QtObject {
        id: authDatabase
        property var database: null
        property bool ready: false

        function initialize() {
            database = LocalStorage.openDatabaseSync(
                        "KSCEEGAuth", "1.0", "EEG-KSC 本地账号数据库", 1024 * 1024)
            database.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS users (" +
                              "id INTEGER PRIMARY KEY AUTOINCREMENT," +
                              "username TEXT UNIQUE NOT NULL," +
                              "password TEXT NOT NULL," +
                              "display_name TEXT NOT NULL," +
                              "role TEXT NOT NULL," +
                              "created_at TEXT NOT NULL)")
                tx.executeSql("CREATE TABLE IF NOT EXISTS app_settings (" +
                              "setting_key TEXT PRIMARY KEY NOT NULL," +
                              "setting_value TEXT NOT NULL)")
                tx.executeSql("INSERT OR REPLACE INTO users " +
                              "(username, password, display_name, role, created_at) " +
                              "VALUES (?, ?, ?, ?, datetime('now'))",
                              ["admin", "admin123456", "管理员", "管理员"])
            })
            ready = true
            loadRememberedLogin()
        }

        function authenticate(username, password) {
            var result = { success: false, displayName: "", role: "" }
            if (!ready || !database)
                return result
            database.readTransaction(function(tx) {
                var rows = tx.executeSql(
                            "SELECT display_name, role FROM users WHERE username = ? AND password = ? LIMIT 1",
                            [username, password])
                if (rows.rows.length > 0) {
                    result.success = true
                    result.displayName = rows.rows.item(0).display_name
                    result.role = rows.rows.item(0).role
                }
            })
            return result
        }

        // 保存「记住密码」设置。
        // 注意：不要往 setting_value 里写空串占位 —— 之前就是这么写的，
        // 取消勾选「记住密码」时会触发 "NOT NULL constraint failed"，
        // 异常一路冒泡出去把调用方的后续语句（包括登录成功后的 loggedIn = true）
        // 全打断，表现就是「取消记住密码之后再也登不进去」。
        // 不记住时直接把这几个键删掉即可。
        function saveRememberedLogin(username, password, remember) {
            try {
                database.transaction(function(tx) {
                    if (remember) {
                        tx.executeSql("INSERT OR REPLACE INTO app_settings(setting_key, setting_value) VALUES('remember_login', '1')")
                        tx.executeSql("INSERT OR REPLACE INTO app_settings(setting_key, setting_value) VALUES('remembered_username', ?)", [username])
                        tx.executeSql("INSERT OR REPLACE INTO app_settings(setting_key, setting_value) VALUES('remembered_password', ?)", [password])
                    } else {
                        tx.executeSql("DELETE FROM app_settings WHERE setting_key IN " +
                                      "('remember_login', 'remembered_username', 'remembered_password')")
                    }
                })
            } catch (error) {
                console.warn("保存「记住密码」设置失败:", error)
            }
        }

        function settingValue(key) {
            var value = ""
            database.readTransaction(function(tx) {
                var rows = tx.executeSql("SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1", [key])
                if (rows.rows.length > 0) {
                    var stored = rows.rows.item(0).setting_value
                    // 兼容历史数据里可能存在的 NULL，避免后面 .length 直接抛异常
                    if (stored !== null && stored !== undefined)
                        value = String(stored)
                }
            })
            return value
        }

        function loadRememberedLogin() {
            var remembered = settingValue("remember_login") === "1"
            var savedUsername = settingValue("remembered_username")
            var savedPassword = settingValue("remembered_password")
            var hasSavedLogin = remembered && savedUsername.length > 0 && savedPassword.length > 0
            loginPage.rememberChecked = hasSavedLogin
            loginPage.accountText = hasSavedLogin ? savedUsername : "admin"
            loginPage.passwordText = hasSavedLogin ? savedPassword : "admin123456"
        }
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
                var result = authDatabase.authenticate(account, password)
                if (result.success) {
                    // 先完成登录并切页，再去存偏好设置：
                    // 存设置属于「锦上添花」，不该因为它出错就把登录卡住。
                    window.currentUserName = result.displayName
                    window.currentUserRole = result.role
                    window.loggedIn = true
                    window.currentPage = "workbench"
                    window.activeDialog = ""
                    if (window.currentPageItem() && window.currentPageItem().resetSession)
                        window.currentPageItem().resetSession()
                    authDatabase.saveRememberedLogin(account, password, rememberPassword)
                } else {
                    errorMessage = qsTr("账号或密码错误，请重新输入")
                    clearPassword()
                }
            }

            onForgotPasswordRequested: {
                errorMessage = qsTr("默认管理员：admin / admin123456")
            }
        }

        // ---------- 业务页面 ----------
        Loader {
            id: pageLoader
            anchors.fill: parent
            visible: window.loggedIn
            enabled: visible
            sourceComponent: window.pageComponent()
        }

        // ---------- 弹窗层（盖在页面之上）----------
        Loader {
            id: dialogLoader
            anchors.fill: parent
            visible: window.loggedIn && window.activeDialog !== ""
            sourceComponent: window.dialogComponent()
        }
    }

    // ================= 页面组件 =================

    Component {
        id: workbenchPageComponent

        WorkbenchPage {
            userName: window.currentUserName.length > 0 ? window.currentUserName : qsTr("管理员")
            userRole: window.currentUserRole.length > 0 ? window.currentUserRole : qsTr("管理员")

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
            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onNewPatientRequested: window.activeDialog = "newPatient"
            onEditPatientRequested: (recordNo) => window.activeDialog = "editPatient"
        }
    }

    Component {
        id: historyPageComponent

        HistoryPage {
            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onRecordPreviewRequested: (recordNo) => window.activeDialog = "recordPreview"
        }
    }

    Component {
        id: userPageComponent

        UserManagementPage {
            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
        }
    }

    Component {
        id: settingsPageComponent

        SystemSettingsPage {
            onNavRequested: (label) => window.navigateTo(label)
            onLogoutRequested: window.handleLogout()
            onNewTagRequested: window.activeDialog = "newTag"
        }
    }

    // ================= 弹窗组件 =================

    Component {
        id: precheckComponent

        PrecheckDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: {
                window.activeDialog = ""
                var page = window.currentPageItem()
                if (page && page.startCollection)
                    page.startCollection()
            }
        }
    }

    Component {
        id: selectPatientComponent

        SelectPatientDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: window.activeDialog = ""
        }
    }

    Component {
        id: newPatientComponent

        NewPatientDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: window.activeDialog = ""
        }
    }

    Component {
        id: editPatientComponent

        EditPatientDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: window.activeDialog = ""
        }
    }

    Component {
        id: recordPreviewComponent

        RecordPreviewDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: window.activeDialog = ""
        }
    }

    Component {
        id: newTagComponent

        NewTagDialog {
            onDismissed: window.activeDialog = ""
            onAccepted: window.activeDialog = ""
        }
    }

    // ---------- 其它 ----------

    function handleLogout() {
        var page = window.currentPageItem()
        if (page && page.stopCollection)
            page.stopCollection()
        window.activeDialog = ""
        window.loggedIn = false
        if (!loginPage.rememberChecked)
            loginPage.clearPassword()
    }

    Component.onCompleted: authDatabase.initialize()
}
