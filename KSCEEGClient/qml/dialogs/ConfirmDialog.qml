import QtQuick
import KSCEEGClient

// 通用确认弹窗。设计稿里没有这一屏 —— 它是为「删除患者」这类不可撤销的操作补的：
// 没有确认框的话，一次误点就把患者连同他的全部采集记录删掉了。
//
// 版式沿用其它弹窗（DialogFrame 白卡 + 底部两个胶囊按钮），尺寸取同一套卡片宽度。
// 做成通用的而不是「删除患者专用」：以后别的地方要确认（清空数据、覆盖记录）
// 直接换文案即可，不必再抄一遍版式。
Item {
    id: root

    signal dismissed()
    signal accepted()

    property string title: qsTr("请确认")
    property string message: ""
    // 主按钮文案。默认「确定」，删除类操作传「删除」更明确
    property string confirmText: qsTr("确定")
    // 危险操作：主按钮用红色，让人点之前多看一眼
    property bool danger: false

    readonly property int cardWidth: 486
    readonly property int cardHeight: 210

    DialogFrame {
        title: root.title
        cardX: (Design.canvasWidth - root.cardWidth) / 2
        cardY: (Design.canvasHeight - root.cardHeight) / 2
        cardWidth: root.cardWidth
        cardHeight: root.cardHeight
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        Text {
            x: 26
            y: 78
            width: root.cardWidth - 52
            wrapMode: Text.WordWrap
            text: root.message
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        DialogButton {
            x: root.cardWidth - 26 - 121 - 12 - 121
            y: root.cardHeight - 35 - 24
            text: qsTr("取消")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: root.cardWidth - 26 - 121
            y: root.cardHeight - 35 - 24
            text: root.confirmText
            primary: true
            danger: root.danger
            onClicked: root.accepted()
        }
    }

    component DialogButton: Rectangle {
        id: dialogButton

        property string text: ""
        property bool primary: false
        property bool danger: false
        signal clicked()

        width: 121
        height: 35
        radius: 12
        color: dialogButton.primary ? (dialogButton.danger ? (mouse.pressed ? "#c04a4d" : Design.bad)
                                                          : (mouse.pressed ? "#64879f" : Design.primary))
                                    : "transparent"
        border.width: 1
        border.color: dialogButton.primary ? Design.panelBorder : Design.pillBorder

        Text {
            anchors.centerIn: parent
            text: dialogButton.text
            color: dialogButton.primary ? "#ffffff" : "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dialogButton.clicked()
        }
    }
}
