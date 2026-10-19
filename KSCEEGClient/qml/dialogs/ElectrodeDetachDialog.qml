import QtQuick
import KSCEEGClient

// 「电极脱落」错误框：每次阻抗扫描完成后，只要当前激活通道里存在脱落电极就弹出，
// 提醒用户检查电极后重新扫描。
//
// 版式与「设备断开连接」警示框一致，但标题是红色「错误」。
// 同样**不走** Main.qml 的 activeDialog 单值路由，而是直接盖在 DesignCanvas
// 最上层 —— 扫描可能在别的弹窗开着时完成，单值路由会互相覆盖。
Item {
    id: root

    signal dismissed()    // 关闭叉 / 返回检查
    signal confirmed()    // 确认

    readonly property int cardWidth: 486
    readonly property int cardHeight: 210

    DialogFrame {
        title: qsTr("错误")
        titleColor: Design.bad
        cardX: (Design.canvasWidth - root.cardWidth) / 2
        cardY: (Design.canvasHeight - root.cardHeight) / 2
        cardWidth: root.cardWidth
        cardHeight: root.cardHeight
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        // 正文居中：标题下方到按钮分隔线之间的那一段里垂直居中
        Item {
            x: 26
            y: 60
            width: root.cardWidth - 52
            height: root.cardHeight - 60 - (35 + 24 + 22)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("电极贴合程度较差！请检查电极后，重新进行阻抗扫描")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }

        // 按钮上方的渐隐分隔线
        PanelDivider {
            x: 26
            y: root.cardHeight - 35 - 24 - 22
            width: root.cardWidth - 52
        }

        DialogButton {
            x: root.cardWidth - 26 - 121 - 12 - 121
            y: root.cardHeight - 35 - 24
            text: qsTr("返回检查")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: root.cardWidth - 26 - 121
            y: root.cardHeight - 35 - 24
            text: qsTr("确认")
            primary: true
            onClicked: root.confirmed()
        }
    }

    component DialogButton: Rectangle {
        id: dialogButton

        property string text: ""
        property bool primary: false
        signal clicked()

        width: 121
        height: 35
        radius: 12
        color: dialogButton.primary ? (mouse.pressed ? "#64879f" : Design.primary) : "transparent"
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
