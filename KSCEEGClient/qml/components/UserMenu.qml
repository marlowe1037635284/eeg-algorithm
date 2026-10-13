import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 顶栏右上角用户区点开的小菜单：修改密码 / 退出登录。
//
// 用户区在 AppShell（业务页共用）和采集工作台里各画了一份，菜单跟着抽成一个组件，
// 免得两处的选项与样式慢慢走岔。
//
// 走 Popup 而不是手写浮层：它渲染在窗口 overlay 层，天然盖住页面内容，
// 点别处 / 按 Esc 关闭也都是现成的（与 ChoiceField 的做法一致）
Popup {
    id: root

    signal changePasswordRequested()
    signal logoutRequested()

    width: 150
    padding: 6
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        radius: 10
        color: "#ffffff"
        border.width: 1
        border.color: Design.panelBorder
    }

    contentItem: Column {
        spacing: 2

        Repeater {
            model: [qsTr("修改密码"), qsTr("退出登录")]

            delegate: Rectangle {
                required property string modelData
                required property int index

                width: root.width - 12
                height: 34
                radius: 6
                color: itemMouse.containsMouse ? Design.primarySoft : "transparent"

                Text {
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData
                    color: "#3b3b3b"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                MouseArea {
                    id: itemMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.close()
                        if (index === 0)
                            root.changePasswordRequested()
                        else
                            root.logoutRequested()
                    }
                }
            }
        }
    }
}
