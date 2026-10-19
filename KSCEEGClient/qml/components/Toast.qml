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
    // 屏显文本：message 被清空时**先不跟着清**，等淡出结束（opacity 归零）
    // 再清。否则 label 一瞬间变空、pill 立刻缩回 60px 的底座，在 160ms 的淡出里
    // 会看到一条空提示条闪一下（#320）
    property string displayText: ""
    // info / success / warn / error，决定底色
    property string kind: "info"
    // 每次调用都自增，用来在「连续弹同一条提示」时也能重新播一次动画
    property int serial: 0

    readonly property bool active: message.length > 0
    readonly property color accent: {
        if (kind === "success")
            return Design.good
        // 提醒（「请先选择患者」这类）：不是错误，但比普通提示更需要被看到，
        // 用设计系统里的警示橙
        if (kind === "warn")
            return Design.warning
        if (kind === "error")
            return Design.bad
        return Design.primary
    }

    function show(text, style) {
        if (!text || text.length === 0)
            return
        message = text
        displayText = text
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

    // 淡出到不可见之后，才把屏显文本清掉 —— 这正是「空提示条屏闪」的消除点：
    // 清空动作发生时 opacity 已经归零、visible 已为 false，用户看不到那一瞬
    onOpacityChanged: {
        if (opacity <= 0.01 && root.message.length === 0)
            root.displayText = ""
    }

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
            // 用 displayText 而不是 message：淡出期间 message 已空，文本与宽度
            // 要保持到真正不可见为止
            text: root.displayText
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
