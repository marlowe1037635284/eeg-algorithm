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
    // 底栏右侧显示的指标项。各页按自己知道的信息传，不传就是不显示 ——
    // 这些值没有一个能在 AppShell 这一层拿到，写死就只能是假的
    property var statusItems: []
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
        userRole: shell.userRole
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

        // 设备连接状态接的是真实值。原来所有业务页都写死「已连接」+ 绿灯，
        // 而采集工作台那一处是绑 Acq 的 —— 同一台机器上拔掉串口，两个页面对
        // 同一件事给出相反的答案
        Rectangle {
            x: 13
            y: 10
            width: 8
            height: 8
            radius: 4
            color: Acq.portOpen ? Design.good : Design.offline
        }

        Text {
            x: 31
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: Acq.portOpen ? qsTr("Neurolink-6016 已连接") : qsTr("Neurolink-6016 未连接")
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
            // 工作台上扫过阻抗之后，这几处显示的都是同一份结果
            text: Design.electrodePillText(Acq.electrodeScanValid ? Acq.electrodeQuality : [])
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

    // 底栏右侧那排指标。原来全是写死的（256Hz、数据点 1,024、电极 10/16 良好、
    // 患者「张文强」——连名字都是「张文涛」的错字），与页面上的实际值互相矛盾。
    //
    // 现在改成由各页把自己的那几项传进来（`statusItems`）：采集相关的那几项只有
    // 采集页知道，别的页没有这些概念，硬凑一串数字只是假数据。传空数组就不显示。
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 27
        y: 1052
        spacing: 22

        Repeater {
            model: shell.statusItems

            delegate: Text {
                required property string modelData
                text: modelData
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }
        }
    }
}
