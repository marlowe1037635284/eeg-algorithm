import QtQuick
import QtQuick.Controls.Basic

// 除「采集工作台」以外所有页面共用的外壳：左侧 189px 导航栏 + 顶栏 + 底部状态栏 + 内容卡片。
//
// 设计稿里这几个页面（患者管理 / 历史记录 / 用户管理 / 系统设置，以及采集前确认等弹窗页
// 的背景）共用同一套外壳，这里抽出来一份，避免每个页面抄一遍。
//
// 注意：采集工作台用的是另一套「窄导航（92px、只有图标）」的外壳，见 WorkbenchPage.qml。
// 这是设计稿本身的差异，没有合并。
//
// 坐标一律是设计稿画板（1920×1080）上的绝对坐标。
Item {
    id: shell

    property string pageTitle: ""
    property string currentNav: ""

    // 内容区插槽：页面把自己的东西塞进来即可，会被放进内容卡片里
    default property alias contentChildren: contentArea.data

    signal navRequested(string label)
    signal logoutRequested()

    readonly property var navItems: [
        qsTr("采集工作台"), qsTr("患者管理"), qsTr("历史记录"), qsTr("用户管理"), qsTr("系统设置")
    ]

    // ---------- 背景 ----------
    Image {
        x: -8
        y: -2
        width: 1928
        height: 1085
        source: "assets/login-background.jpg"
        fillMode: Image.Stretch
        smooth: true
        mipmap: true
    }

    Rectangle {
        x: 931
        y: -98
        width: 1247
        height: 280
        radius: 140
        color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.19)
    }

    Rectangle {
        x: -324
        y: 972
        width: 1247
        height: 280
        radius: 140
        color: Qt.rgba(0xff / 255, 0x8d / 255, 0x1a / 255, 0.05)
    }

    // ---------- 左侧导航 ----------
    Rectangle {
        x: 0
        y: 0
        width: 189
        height: 1080
        color: Design.panelFill
    }

    Rectangle {
        x: 189
        y: 0
        width: 1
        height: 1080
        color: Design.divider
    }

    Text {
        x: 18
        y: 28
        text: "EEG-KSC"
        color: Design.brand
        font.family: Design.fontLogo
        font.pixelSize: 36
    }

    Repeater {
        model: shell.navItems

        delegate: Item {
            required property string modelData
            required property int index

            readonly property bool active: shell.currentNav === modelData
            readonly property int itemY: 120 + 74 * index

            Rectangle {
                x: 14
                y: parent.itemY
                width: 161
                height: 56
                color: Design.primarySoft
                border.width: 1
                border.color: Design.primary
                visible: parent.active
            }

            Text {
                x: 56
                y: parent.itemY + 14
                text: modelData
                color: parent.active ? Design.primary : Qt.rgba(0x57 / 255, 0x57 / 255, 0x57 / 255, 0.8)
                font.family: parent.active ? Design.fontBold : Design.fontRegular
                font.pixelSize: 20
            }

            MouseArea {
                x: 14
                y: parent.itemY
                width: 161
                height: 56
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: shell.navRequested(modelData)
            }
        }
    }

    // ---------- 顶栏 ----------
    Rectangle {
        x: 189
        y: 51
        width: 1731
        height: 1
        color: Design.divider
    }

    Rectangle {
        x: 1412
        y: 12
        width: 188
        height: 27
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: Design.pillBorder

        Rectangle {
            x: 13
            y: 10
            width: 8
            height: 8
            radius: 4
            color: Design.good
        }

        Text {
            x: 31
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Neurolink-6016 已连接")
            color: "#4f4f4f"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }

    Rectangle {
        x: 1612
        y: 12
        width: 153
        height: 27
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: Design.pillBorder

        Text {
            x: 12
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("电极贴合  16/16 良好")
            color: "#4f4f4f"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }

    Rectangle {
        x: 1788
        y: 7
        width: 37
        height: 37
        radius: 19
        color: Design.primary

        Text {
            anchors.centerIn: parent
            text: "AD"
            color: "#ffffff"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }

    Text {
        x: 1833
        y: 8
        text: "admin"
        color: "#4f4f4f"
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    Text {
        x: 1833
        y: 26
        text: qsTr("管理员")
        color: "#878787"
        font.family: Design.fontRegular
        font.pixelSize: 12
    }

    Image {
        x: 1893.5
        y: 22.77
        width: 7.47
        height: 7
        rotation: -90
        source: "assets/icons/icon-arrow-down.svg"
    }

    MouseArea {
        x: 1788
        y: 4
        width: 122
        height: 44
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: shell.logoutRequested()

        ToolTip.visible: containsMouse
        ToolTip.text: qsTr("点击退出登录")
        ToolTip.delay: 400
    }

    // ---------- 内容区标题条 ----------
    Rectangle {
        x: 201
        y: 63
        width: 1702
        height: 75
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Text {
        x: 229
        y: 87
        text: shell.pageTitle
        color: Design.textPrimary
        font.family: Design.fontBold
        font.pixelSize: 24
    }

    // ---------- 内容卡片 ----------
    Rectangle {
        x: 201
        y: 150
        width: 1702
        height: 883
        radius: 16
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Item {
        id: contentArea
        x: 201
        y: 150
        width: 1702
        height: 883
    }

    // ---------- 底部状态栏 ----------
    Rectangle {
        x: 189
        y: 1046
        width: 1731
        height: 34
        color: Design.panelFill
    }

    Rectangle {
        x: 189
        y: 1046
        width: 1731
        height: 1
        color: Design.divider
    }

    Rectangle {
        x: 214
        y: 1057
        width: 12
        height: 12
        radius: 6
        color: Design.offline
    }

    Text {
        x: 235
        y: 1052
        text: qsTr("采集待机")
        color: "#3b3b3b"
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    Repeater {
        model: [
            { x: 1283, text: qsTr("采样率：256Hz") },
            { x: 1390, text: qsTr("时基：2s/div") },
            { x: 1483, text: qsTr("幅值：100μV/div") },
            { x: 1602, text: qsTr("数据点：1,024") },
            { x: 1703, text: qsTr("电极：10/16良好") },
            { x: 1821, text: qsTr("患者：张文强") }
        ]

        delegate: Text {
            required property var modelData
            x: modelData.x
            y: 1052
            text: modelData.text
            color: "#3b3b3b"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }
}
