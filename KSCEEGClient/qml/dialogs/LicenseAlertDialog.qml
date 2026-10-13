import QtQuick
import KSCEEGClient

// 授权校验失败拦截框：全屏模态，标题「警告」，正文给出失败原因，只有一个「确定」。
//
// 与普通弹窗不同：不给关闭叉、点遮罩也不关 —— 授权不通过就进不去，唯一出路是
// 点「确定」退出程序。这样可以避免用户误关后以为自己绕过了授权。
//
// 显示条件由 Main.qml 控制（License.checked && !License.valid），盖在登录页与所有
// 业务页之上；卡片尺寸沿用同一套设计规格。
Item {
    id: root

    readonly property int cardWidth: 486
    readonly property int cardHeight: 210

    DialogFrame {
        title: qsTr("警告")
        titleColor: Design.bad
        cardX: (Design.canvasWidth - root.cardWidth) / 2
        cardY: (Design.canvasHeight - root.cardHeight) / 2
        cardWidth: root.cardWidth
        cardHeight: root.cardHeight
        dismissOnBackdrop: false
        showClose: false

        Text {
            x: 26
            y: 78
            width: root.cardWidth - 52
            wrapMode: Text.WordWrap
            // 具体原因由 C++ 侧给（缺文件 / 验签失败 / MAC 不符 / 已过期等）
            text: License.message.length > 0
                  ? License.message
                  : qsTr("授权校验未通过，程序即将退出。")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Rectangle {
            x: root.cardWidth - 26 - 121
            y: root.cardHeight - 35 - 24
            width: 121
            height: 35
            radius: 12
            color: mouse.pressed ? "#64879f" : Design.primary
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("确定")
                color: "#ffffff"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: License.quitApplication()
            }
        }
    }
}
