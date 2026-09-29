import QtQuick
import KSCEEGClient

// 全局轻提示。设计稿里没有这一屏 —— 它是为「保存设置」「导出」「重置密码」
// 这类**动作完成但界面看不出变化**的操作补的：没有反馈的话，用户只能靠
// 「再点一次看看会不会有不一样」来判断刚才那下到底成没成。
//
// 挂在 Main 的弹窗层之上，落在顶栏中间那段空白里（那一行除了右侧的设备胶囊
// 和左侧的导航条之外没有别的东西），不遮挡任何设计元素。
Item {
    id: root

    // 空串表示不显示
    property string message: ""
    // info / success / error，决定底色
    property string kind: "info"
    // 每次调用都自增，用来在「连续弹同一条提示」时也能重新播一次动画
    property int serial: 0

    readonly property bool active: message.length > 0
    readonly property color accent: {
        if (kind === "success")
            return Design.good
        if (kind === "error")
            return Design.bad
        return Design.primary
    }

    function show(text, style) {
        if (!text || text.length === 0)
            return
        message = text
        kind = style === undefined || style === null ? "info" : style
        serial += 1
        hideTimer.restart()
    }

    function hide() {
        message = ""
        hideTimer.stop()
    }

    anchors.horizontalCenter: parent.horizontalCenter
    y: 14
    width: pill.width
    height: 40
    // 淡出之后彻底不占层级
    visible: opacity > 0.01
    opacity: active ? 1.0 : 0.0
    z: 1000

    Behavior on opacity { NumberAnimation { duration: 160 } }

    Timer {
        id: hideTimer
        interval: 3200
        onTriggered: root.message = ""
    }

    Rectangle {
        id: pill

        // 宽度跟着文字走（长提示不会被截断，短提示也不会拖出一大条）
        width: label.implicitWidth + 60
        height: 40
        radius: 20
        color: root.accent

        // 状态点：一律白色，类型靠外圈底色区分
        Rectangle {
            x: 18
            anchors.verticalCenter: parent.verticalCenter
            width: 8
            height: 8
            radius: 4
            color: "#ffffff"
        }

        Text {
            id: label
            x: 34
            anchors.verticalCenter: parent.verticalCenter
            text: root.message
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }

    // 从上方轻轻落下来。由 serial 触发，同一条提示连弹两次也会重新播一遍
    NumberAnimation on y {
        id: dropIn
        running: false
        from: -6
        to: 14
        duration: 180
        easing.type: Easing.OutCubic
    }

    onSerialChanged: dropIn.restart()
}
