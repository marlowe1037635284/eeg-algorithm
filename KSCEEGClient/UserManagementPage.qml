import QtQuick

// 「用户管理」页。设计稿画板 1920×1080，用 AppShell 当外壳（左侧导航 + 顶栏 + 状态栏 + 内容卡片）。
//
// 两套坐标别混：
//   - 页面里直接摆在画布上的东西（顶栏右侧那排控件）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽里的东西，坐标要减去内容卡片原点 (201,150)，
//     因为 AppShell 的 contentArea 已经定位在那里了。
Item {
    id: root

    signal navRequested(string label)
    signal logoutRequested()
    signal addUserRequested()
    signal editUserRequested(string userName)

    // 设计稿只画了 3 行示意，但页脚写死「共 6 条记录（当前显示 6 条）」——
    // 按页脚补到 6 行，否则表格下面空一大片，看着像没做完。
    // 前 3 行照抄设计稿（正好覆盖 启用/停用/待审核 三种状态），后 3 行按同样口径编。
    readonly property var users: [
        { uid: "U-0001", account: "admin",      name: "张伟", role: "管理员", dept: "信息中心", status: "启用",   registered: "2025-03-12", lastLogin: "2026-09-12 10:23:41" },
        { uid: "U-0001", account: "admin",      name: "张伟", role: "医生",   dept: "信息中心", status: "停用",   registered: "2025-03-12", lastLogin: "2026-09-12 10:23:41" },
        { uid: "U-0001", account: "admin",      name: "张伟", role: "管理员", dept: "信息中心", status: "待审核", registered: "2025-03-12", lastLogin: "2026-09-12 10:23:41" },
        { uid: "U-0002", account: "doctor.li",  name: "李静", role: "医生",   dept: "神经内科", status: "启用",   registered: "2025-04-08", lastLogin: "2026-09-10 09:15:02" },
        { uid: "U-0003", account: "tech.wang",  name: "王强", role: "技师",   dept: "电生理室", status: "启用",   registered: "2025-06-21", lastLogin: "2026-09-08 15:40:18" },
        { uid: "U-0004", account: "nurse.zhao", name: "赵敏", role: "医生",   dept: "神经内科", status: "停用",   registered: "2025-07-15", lastLogin: "2026-09-05 11:02:37" }
    ]

    // 列 x（设计稿绝对 x 减卡片原点 201）。表头与单元格在设计稿里本身就有几像素错位，各照各的抄。
    readonly property var headerX: [71, 232, 393, 539, 685, 877, 1023, 1200, 1358]
    readonly property var cellX: [68, 232, 393, 690, 1012, 1156]

    // 表头 52 高、之后每行 51 高：设计稿三条分隔线在 y=253/304/355，
    // 即卡片内 103/154/205，正好是 52 + 51 × (index + 1)，行距由分隔线反推。
    readonly property int headerHeight: 52
    readonly property int rowHeight: 51

    // 状态 → 颜色。设计稿里 启用=绿、待审核=橙、停用=灰。
    function statusColor(status)
    {
        if (status === "启用")
            return Design.good
        if (status === "待审核")
            return Design.brand
        return Design.offline
    }

    // 角色 → 强调色。管理员蓝、医生紫取自设计稿；技师设计稿里没有，
    // 借用波形通道色里的青色，避免再凭空引入新颜色。
    function roleAccent(role)
    {
        if (role === "管理员")
            return "#1b74b8"
        if (role === "医生")
            return "#7b5cd6"
        return Design.channelColors[0]
    }

    // 行内第三个按钮随状态切换：已停用的给「启用」，其余给「停用」
    function toggleLabel(status)
    {
        return status === "停用" ? qsTr("启用") : qsTr("停用")
    }

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("用户管理")
        currentNav: qsTr("用户管理")
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

        // ---------- 表头 ----------
        Rectangle {
            x: 0
            y: 0
            width: 1702
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
                font.family: Design.fontRegular
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
                    x: 0
                    y: rowTop
                    width: 1700
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                Text { x: 68;   y: textY; text: modelData.uid;        color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 232;  y: textY; text: modelData.account;    color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 393;  y: textY; text: modelData.name;       color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 690;  y: textY; text: modelData.dept;       color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 1012; y: textY; text: modelData.registered; color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 1156; y: textY; text: modelData.lastLogin;  color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }

                RoleBadge {
                    x: 513
                    y: rowTop + 13
                    role: modelData.role
                }

                StatusLabel {
                    y: textY
                    status: modelData.status
                }

                TableAction {
                    x: 1358
                    y: rowTop + 11
                    width: 59
                    text: qsTr("编辑")
                    onClicked: root.editUserRequested(modelData.account)
                }

                TableAction {
                    x: 1429
                    y: rowTop + 11
                    width: 81
                    text: qsTr("重置密码")
                }

                TableAction {
                    x: 1522
                    y: rowTop + 11
                    width: 59
                    text: root.toggleLabel(modelData.status)
                }

                Rectangle {
                    x: 0
                    y: rowTop + 51
                    width: 1669
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.10)
                }
            }
        }

        // ---------- 右侧滚动条 ----------
        Rectangle {
            x: 1686
            y: 64
            width: 7
            height: 758
            radius: 4
            color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
        }

        Rectangle {
            x: 1686
            y: 319
            width: 7
            height: 278
            radius: 4
            color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
        }

        // ---------- 分页 ----------
        Text {
            x: 19
            y: 846
            text: qsTr("共 %1 条记录（当前显示 %1 条）").arg(root.users.length)
            color: Design.textSecondary
            font.family: Design.fontRegular
            font.pixelSize: 14
        }

        Rectangle {
            x: 1531
            y: 842
            width: 53
            height: 29
            radius: 6
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("上一页")
                color: "#3b3b3b"
                font.family: Design.fontRegular
                font.pixelSize: 14
            }
        }

        Rectangle {
            x: 1631
            y: 842
            width: 53
            height: 29
            radius: 6
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("下一页")
                color: "#3b3b3b"
                font.family: Design.fontRegular
                font.pixelSize: 14
            }
        }

        Text {
            x: 1596
            y: 845
            text: "1/1"
            color: "#000000"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }

    // ---------- 标题条右侧的搜索/筛选/操作控件（设计稿绝对坐标）----------
    Rectangle {
        x: 1374
        y: 79
        width: 215
        height: 43
        radius: 12
        color: Design.primarySoft

        Text {
            x: 13
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("搜索用户名/姓名/手机号")
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.3)
            font.family: Design.fontRegular
            font.pixelSize: 16
        }
    }

    Rectangle {
        x: 1601
        y: 79
        width: 126
        height: 43
        radius: 12
        color: Design.primarySoft

        Text {
            x: 10
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("全部角色")
            color: "#3b3b3b"
            font.family: Design.fontRegular
            font.pixelSize: 16
        }

        Image {
            x: 116.5
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: "assets/icons/icon-arrow-down.svg"
        }
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
            font.family: Design.fontRegular
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

    // 表格行里的小圆角按钮
    component TableAction: Rectangle {
        id: tableAction
        property string text: ""
        signal clicked()

        height: 31
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: tableAction.text
            color: "#4f4f4f"
            font.family: Design.fontRegular
            font.pixelSize: 16
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tableAction.clicked()
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
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }

    // 状态：圆点 + 文字。设计稿里 2 字（启用/停用）和 3 字（待审核）都居中于卡片坐标 692，
    // 所以按整组宽度反向定位，换词后不会跑偏。
    component StatusLabel: Item {
        id: statusLabel
        property string status: ""

        readonly property color accent: root.statusColor(statusLabel.status)

        width: 16 + statusText.width
        height: 22
        x: 692 - width / 2

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
            font.family: Design.fontRegular
            font.pixelSize: 16
        }
    }
}
