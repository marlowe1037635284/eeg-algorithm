import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 除「采集工作台」以外所有页面共用的外壳：左侧 92px 图标导航 + 顶栏 + 底部状态栏 + 内容卡片。
//
// 导航条和采集工作台用的是同一个 AppNavRail —— 全应用只有这一种导航样式，
// 页面之间跳转时导航栏不会变形（图标含义靠悬停提示补足）。
//
// 坐标一律是设计稿画板（1920×1080）上的绝对坐标。
// 内容槽 contentArea 的原点在 (154,150)：页面把自己的内容写进来，
// 坐标按「内容卡片内的相对坐标」给即可。
Item {
    id: shell

    property string pageTitle: ""
    property string currentNav: ""
    // 顶栏右上角的当前用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    // 内容区插槽：页面把自己的东西塞进来即可，会被放进内容卡片里
    default property alias contentChildren: contentArea.data

    signal navRequested(string label)
    signal logoutRequested()

    // ---------- 背景 ----------
    Image {
        x: -8
        y: -2
        width: 1928
        height: 1085
        source: Design.assetRoot + "login-background.jpg"
        fillMode: Image.Stretch
        smooth: true
        mipmap: true
    }

    // 两个带模糊的大椭圆装饰（设计稿里是 FOREGROUND_BLUR 272）
    SoftBlob {
        x: 659
        y: -370
        tint: Design.primary
        peakAlpha: 0.19
    }

    SoftBlob {
        x: -596
        y: 700
        tint: Design.brand
        peakAlpha: 0.05
    }

    // ---------- 左侧导航 ----------
    AppNavRail {
        current: shell.currentNav
        onNavRequested: (label) => shell.navRequested(label)
    }

    // ---------- 顶栏 ----------
    Rectangle {
        x: 92
        y: 51
        width: 1828
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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
            text: Design.avatarText(shell.userName)
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    Text {
        x: 1833
        y: 8
        text: shell.userName
        color: "#4f4f4f"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    Text {
        x: 1833
        y: 26
        text: shell.userRole
        color: "#878787"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    Image {
        x: 1893.5
        y: 22.77
        width: 7.47
        height: 7
        rotation: -90
        source: Design.assetRoot + "icons/icon-arrow-down.svg"
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
        x: 107
        y: 63
        width: 1796
        height: 75
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Text {
        x: 135
        y: 87
        text: shell.pageTitle
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleBold
        font.pixelSize: 24
    }

    // ---------- 内容卡片 ----------
    Rectangle {
        x: 107
        y: 150
        width: 1796
        height: 883
        radius: 16
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    // 内容槽：原点放在卡片内居中（左右各留 47），页面内容按这个原点的相对坐标写
    Item {
        id: contentArea
        x: 154
        y: 150
        width: 1702
        height: 883
    }

    // ---------- 底部状态栏 ----------
    Rectangle {
        x: 92
        y: 1046
        width: 1828
        height: 34
        color: Design.panelFill
    }

    Rectangle {
        x: 92
        y: 1046
        width: 1828
        height: 1
        color: Design.divider
    }

    Rectangle {
        x: 117
        y: 1057
        width: 12
        height: 12
        radius: 6
        color: Design.offline
    }

    Text {
        x: 140
        y: 1052
        text: qsTr("采集待机")
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }
}
