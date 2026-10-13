import QtQuick
import KSCEEGClient

// 「用户管理」页。设计稿画板 1920×1080，用 AppShell 当外壳（左侧导航 + 顶栏 + 状态栏 + 内容卡片）。
//
// 两套坐标别混：
//   - 页面里直接摆在画布上的东西（顶栏右侧那排控件）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽里的东西，坐标要减去内容卡片原点 (154,150)，
//     因为 AppShell 的 contentArea 已经定位在那里了。
//
// 数据来自 users 表。原来这一页整张表都是写死的：6 行假用户、搜索框和角色下拉是
// 画出来的色块、四个按钮里有三个点了没反应（新增/编辑连弹窗都没有），
// 而登录页登录进来的账号在这儿根本看不到
Item {
    id: root

    // 顶栏右上角显示的用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    signal navRequested(string label)
    signal logoutRequested()
    signal changePasswordRequested()
    // 点顶栏设备状态胶囊 → 弹「设备连接」浮层（由 Main 统一路由）
    signal deviceInfoRequested()
    signal addUserRequested()
    signal editUserRequested(string account)
    signal resetPasswordRequested(string account)
    // 启用 / 停用：直接改状态，不弹确认框（改错了再点一次就回来了，可逆）
    signal toggleStatusRequested(string account, string nextStatus)

    // 应用数据库，由外层注入
    property var database

    // 当前登录账号。用来认出列表里「自己」那一行 —— 管理员不可以停用自己
    readonly property string currentAccount: database ? database.currentAccount() : ""

    property int revision: 0
    function reload() {
        revision++
        clampPage()
    }

    readonly property var allUsers: {
        revision   // 绑定依赖
        return database ? database.users() : []
    }

    // ---------- 搜索 / 筛选 / 分页 ----------
    // 与患者管理、历史记录三页共用同一套
    property string searchText: ""
    property int roleFilter: 0            // roleChoices 的下标，0 = 全部角色
    property int currentPage: 1

    readonly property var roleChoices: [qsTr("全部角色"), qsTr("管理员"), qsTr("医生"),
                                        qsTr("技师")]
    readonly property string roleKeyword:
        (roleFilter > 0 && roleFilter < roleChoices.length) ? roleChoices[roleFilter] : ""

    readonly property var filteredUsers: {
        var keyword = searchText.trim().toLowerCase()
        var result = []
        for (var i = 0; i < allUsers.length; ++i) {
            var row = allUsers[i]
            if (roleKeyword.length > 0 && row.role !== roleKeyword)
                continue
            if (keyword.length > 0) {
                // 与设计稿的提示一致：用户名 / 姓名 / 手机号（本系统里账号本身就是手机号）
                var haystack = (row.account + " " + row.name).toLowerCase()
                if (haystack.indexOf(keyword) < 0)
                    continue
            }
            result.push(row)
        }
        return result
    }

    onSearchTextChanged: currentPage = 1
    onRoleFilterChanged: currentPage = 1

    function clampPage() {
        const pages = Math.max(1, Math.ceil(filteredUsers.length / pageSize))
        currentPage = Math.max(1, Math.min(pages, currentPage))
    }

    // 列 x（设计稿绝对 x 减卡片原点 201）。表头与单元格在设计稿里本身就有几像素错位，各照各的抄。
    readonly property var headerX: [71, 232, 393, 539, 685, 877, 1023, 1200, 1358]
    readonly property var cellX: [68, 232, 393, 690, 1012, 1156]

    // 表头 52 高、之后每行 51 高：设计稿三条分隔线在 y=253/304/355，
    // 即卡片内 103/154/205，正好是 52 + 51 × (index + 1)，行距由分隔线反推。
    readonly property int headerHeight: 52
    readonly property int rowHeight: 51
    readonly property int bodyHeight: 788
    readonly property int pageSize: Math.floor(bodyHeight / rowHeight)

    readonly property var users: {
        const start = (currentPage - 1) * pageSize
        return filteredUsers.slice(start, start + pageSize)
    }

    // 状态 → 颜色。设计稿里 启用=绿、待审核=橙、停用=灰。
    function statusColor(status)
    {
        if (status === "启用")
            return Design.good
        if (status === "待审核")
            return Design.brand
        return Design.offline
    }

    // 角色 → 强调色。管理员蓝、医生紫取自设计稿；技师借用波形通道色里的青色。
    // 其余（旧库里的历史角色、空角色）一律用中性灰兜底 —— 不凭空引入新颜色
    function roleAccent(role)
    {
        if (role === "管理员")
            return "#1b74b8"
        if (role === "医生")
            return "#7b5cd6"
        if (role === "技师")
            return Design.channelColors[0]
        return "#6e7788"
    }

    // 行内第三个按钮随状态切换：已停用的给「启用」，其余给「停用」。
    // 待审核的也走「停用」—— 它的下一步是不让登录，与停用同义
    function toggleLabel(status)
    {
        return status === "停用" ? qsTr("启用") : qsTr("停用")
    }

    function nextStatus(status)
    {
        return status === "停用" ? qsTr("启用") : qsTr("停用")
    }

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("用户管理")
        currentNav: qsTr("用户管理")
        statusItems: {
            var items = [qsTr("用户：") + root.allUsers.length + qsTr(" 位")]
            if (root.filteredUsers.length !== root.allUsers.length)
                items.push(qsTr("筛选后：") + root.filteredUsers.length + qsTr(" 位"))
            return items
        }
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()
        onChangePasswordRequested: root.changePasswordRequested()
        onDeviceInfoRequested: root.deviceInfoRequested()

        // ---------- 表头 ----------
        Rectangle {
            x: -47
            y: 0
            width: 1796
            height: 52
            color: Design.primarySoft
        }

        Repeater {
            model: [
                { x: 71,   text: qsTr("用户ID") },
                { x: 232,  text: qsTr("用户名") },
                { x: 393,  text: qsTr("姓名") },
                { x: 539,  text: qsTr("角色") },
                { x: 685,  text: qsTr("部门 / 科室") },
                { x: 877,  text: qsTr("状态") },
                { x: 1023, text: qsTr("注册时间") },
                { x: 1200, text: qsTr("最后登录") },
                { x: 1358, text: qsTr("操作") }
            ]

            delegate: Text {
                required property var modelData
                x: modelData.x
                y: 15
                text: modelData.text
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }

        // ---------- 数据行 ----------
        Repeater {
            model: root.users

            delegate: Item {
                required property var modelData
                required property int index

                // 行顶相对内容卡片：表头之后每行 51
                readonly property int rowTop: 52 + 51 * index
                // 设计稿首行文字在 y=218，即行顶（202）往下 16
                readonly property int textY: rowTop + 16

                Rectangle {
                    x: -47
                    y: rowTop
                    width: 1794
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                Text { x: 68;   y: textY; text: modelData.uid;        color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 232;  y: textY; text: modelData.account;    color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 393;  y: textY; text: modelData.name;       color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 690;  y: textY; text: modelData.dept;       color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1012; y: textY; text: modelData.registered; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1156; y: textY; text: modelData.lastLogin;  color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }

                RoleBadge {
                    x: 513
                    y: rowTop + 13
                    role: modelData.role
                }

                StatusLabel {
                    y: textY
                    status: modelData.status
                }

                TableRowButton {
                    x: 1358
                    y: rowTop + 11
                    width: 59
                    text: qsTr("编辑")
                    onClicked: root.editUserRequested(modelData.account)
                }

                TableRowButton {
                    x: 1429
                    y: rowTop + 11
                    width: 81
                    text: qsTr("重置密码")
                    onClicked: root.resetPasswordRequested(modelData.account)
                }

                TableRowButton {
                    x: 1522
                    y: rowTop + 11
                    width: 59
                    text: root.toggleLabel(modelData.status)
                    // 管理员不能停用自己：自己那行且当前还有「停用」可选时，把按钮收起来
                    // （数据层也会拦，这里只是别让人白点一下再吃一个错误提示）
                    visible: !(modelData.account === root.currentAccount
                               && modelData.status !== "停用")
                    onClicked: root.toggleStatusRequested(modelData.account,
                                                          root.nextStatus(modelData.status))
                }

                Rectangle {
                    x: -47
                    y: rowTop + 51
                    width: 1763
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.10)
                }
            }
        }

        // ---------- 空态 ----------
        // 「一个人都没有」和「筛完没有了」提示语分开：筛没的时候让人去「新增用户」，
        // 他会以为库里的人丢了
        Text {
            x: 71
            y: 200
            width: 1400
            visible: root.users.length === 0
            text: root.allUsers.length === 0
                  ? qsTr("暂无用户，点右上角「新增用户」开通一个账号")
                  : qsTr("没有符合当前条件的用户，试试换个搜索词或角色")
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 分页 ----------
        Pager {
            x: 0
            y: 842
            totalCount: root.allUsers.length
            filteredCount: root.filteredUsers.length
            pageSize: root.pageSize
            currentPage: root.currentPage
            onPageRequested: (page) => root.currentPage = page
        }
    }

    // ---------- 标题条右侧的搜索/筛选/操作控件（设计稿绝对坐标）----------
    SearchField {
        x: 1374
        y: 79
        width: 215
        height: 43
        placeholder: qsTr("搜索用户名/姓名/手机号")
        onTextChanged: root.searchText = text
    }

    ChoiceField {
        x: 1601
        y: 79
        width: 126
        height: 43
        choices: root.roleChoices
        currentIndex: root.roleFilter
        onActivated: (index) => root.roleFilter = index
    }

    Rectangle {
        x: 1740
        y: 79
        width: 145
        height: 43
        radius: 12
        color: addUserMouse.pressed ? "#64879f" : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.9)
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("新增用户")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        MouseArea {
            id: addUserMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addUserRequested()
        }
    }

    // 角色胶囊：84×27，按角色换强调色
    component RoleBadge: Rectangle {
        id: roleBadge
        property string role: ""

        readonly property color accent: root.roleAccent(roleBadge.role)

        width: 84
        height: 27
        radius: 12
        color: Qt.rgba(accent.r, accent.g, accent.b, 0.10)
        border.width: 1
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.20)

        // 设计稿里两个标签（管理员/医生）的圆点都固定在 x=14，
        // 文字都居中于 x=50 —— 不是「整组居中」，所以这两个值照抄，不做反向计算。
        Rectangle {
            x: 14
            y: 10
            width: 8
            height: 8
            radius: 4
            color: roleBadge.accent
        }

        Text {
            id: roleText
            x: 50 - width / 2
            y: 4
            text: roleBadge.role
            color: roleBadge.accent
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // 状态：圆点 + 文字。设计稿里 2 字（启用/停用）的整组在 @1070 宽 48、
    // 3 字（待审核）的在 @1062 宽 63，两者中心都落在卡片坐标 893 ——
    // 所以按整组宽度反向定位，换词后不会跑偏。
    //
    // 注意不能像原来那样写 692：那是「部门 / 科室」那一列的位置
    //（设计稿 @891），状态标签压在上面，实际渲染出来是「信息中心」右边
    // 直接糊了一个绿点加两个字
    component StatusLabel: Item {
        id: statusLabel
        property string status: ""

        readonly property color accent: root.statusColor(statusLabel.status)

        width: 16 + statusText.width
        height: 22
        x: 893 - width / 2

        Rectangle {
            y: 7
            width: 10
            height: 10
            radius: 5
            color: statusLabel.accent
        }

        Text {
            id: statusText
            x: 16
            text: statusLabel.status
            color: statusLabel.accent
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }
}
