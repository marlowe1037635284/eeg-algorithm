import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 左侧 92px 的图标导航条。
//
// 全应用只有这一种导航条：采集工作台和各业务页都用它，这样页面之间跳转时导航栏
// 不会变形（原来各业务页用的是 189px 带文字的导航，从工作台跳过去会整条换样）。
// 图标含义靠悬停提示补足（设计稿里就没有文字）。
//
// 坐标取自设计稿：条宽 92，导航项 60×60 从 y=99 起、每项间隔 74。
Item {
    id: rail

    property string current: ""
    // 当前登录角色。导航项里「用户管理」只对管理员开放，其余角色整项不显示
    property string userRole: ""
    signal navRequested(string label)

    readonly property bool isAdmin: userRole === qsTr("管理员")

    readonly property var items: {
        var all = [
            { icon: Design.assetRoot + "icons/nav-monitor.svg", activeIcon: Design.assetRoot + "icons/nav-monitor-active.svg",
              label: qsTr("采集工作台"), w: 29, h: 25 },
            { icon: Design.assetRoot + "icons/nav-patient.svg", activeIcon: Design.assetRoot + "icons/nav-patient-active.svg",
              label: qsTr("患者管理"), w: 23, h: 24 },
            { icon: Design.assetRoot + "icons/nav-history.svg", activeIcon: Design.assetRoot + "icons/nav-history-active.svg",
              label: qsTr("历史记录"), w: 25, h: 24 },
            { icon: Design.assetRoot + "icons/nav-user.svg", activeIcon: Design.assetRoot + "icons/nav-user-active.svg",
              label: qsTr("用户管理"), w: 19, h: 24 },
            { icon: Design.assetRoot + "icons/nav-setting.svg", activeIcon: Design.assetRoot + "icons/nav-setting-active.svg",
              label: qsTr("系统设置"), w: 26, h: 24 }
        ]
        if (isAdmin)
            return all
        // 非管理员去掉「用户管理」。过滤后其余项按 index 依次排上去，中间不留空位
        var visible = []
        for (var i = 0; i < all.length; ++i) {
            if (all[i].label !== qsTr("用户管理"))
                visible.push(all[i])
        }
        return visible
    }

    width: 92
    height: 1080

    Rectangle {
        anchors.fill: parent
        color: Design.panelFill
    }

    Rectangle {
        x: 91
        y: 0
        width: 1
        height: 1080
        color: Design.divider
    }

    Text {
        x: 16
        y: 14
        text: "EEG\nKSC"
        color: Design.brand
        font.family: Design.fontFamily
        font.styleName: Design.styleLogo
        font.pixelSize: 24
        lineHeight: 29
        lineHeightMode: Text.FixedHeight
    }

    Repeater {
        model: rail.items

        delegate: Item {
            required property var modelData
            required property int index

            readonly property bool active: rail.current === modelData.label
            readonly property int itemY: 99 + 74 * index

            Rectangle {
                x: 16
                y: parent.itemY
                width: 60
                height: 60
                radius: 10
                color: Design.primarySoft
                visible: parent.active
            }

            Rectangle {
                x: 19
                y: parent.itemY + 18
                width: 3
                height: 24
                color: Design.primary
                visible: parent.active
            }

            Image {
                x: 16 + (60 - modelData.w) / 2
                y: parent.itemY + (60 - modelData.h) / 2
                width: modelData.w
                height: modelData.h
                source: parent.active ? modelData.activeIcon : modelData.icon
                fillMode: Image.PreserveAspectFit
            }

            MouseArea {
                x: 16
                y: parent.itemY
                width: 60
                height: 60
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: rail.navRequested(modelData.label)

                ToolTip.visible: containsMouse
                ToolTip.text: modelData.label
                ToolTip.delay: 400
            }
        }
    }
}
