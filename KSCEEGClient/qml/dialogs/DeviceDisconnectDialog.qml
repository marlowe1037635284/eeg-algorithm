import QtQuick
import KSCEEGClient

// 「设备断开连接」警示框：采集过程中拔线 / 掉电 / 驱动把设备移除时弹出。
//
// 版式取自设计稿的警告弹窗（截图 警告.png）：橙色「警告」标题 + 关闭叉、
// 居中一行说明、底部分隔线 +「返回检查」与「确认」两个按钮。
//
// 它**不走** Main.qml 的 activeDialog 单值路由，而是像 LicenseAlertDialog 一样直接
// 盖在 DesignCanvas 最上层 —— 断连可能发生在已经弹着别的框的时候，单值路由会被
// 覆盖或覆盖掉别的框，盖不住。
Item {
    id: root

    signal dismissed()    // 关闭叉 / 返回检查
    signal confirmed()    // 确认

    property string message: qsTr("设备连接已断开，实时采集已停止。请检查设备与上位机之间的连接线，重新连接后再继续采集。")

    readonly property int cardWidth: 486
    readonly property int cardHeight: 210

    DialogFrame {
        title: qsTr("警告")
        // 与截图一致：警告标题用品牌橙，不是错误红
        titleColor: Design.brand
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
                text: root.message
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
