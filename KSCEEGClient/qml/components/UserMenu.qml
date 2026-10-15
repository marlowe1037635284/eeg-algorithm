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

    // 设计稿规格：整卡 240 宽，两行各 48 高，行间 1px 分隔线；圆角 10
    readonly property int rowHeight: 48
    readonly property int cornerRadius: 10
    // 行内左边距（相对卡片内缘）。图标统一放在 18px 的方格里居中 ——
    // 两枚图标源文件的留白差得多（锁 24×24 里只占 18.3，退出 19×19 几乎占满），
    // 所以各自按「缩放完看起来一样大」给尺寸，而不是共用一个值
    readonly property int iconLeft: 18
    readonly property int iconSlot: 18
    readonly property int textLeft: 45

    width: 240
    padding: 1
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    // 设计稿里这是一张浅灰卡片，不是白底浮层。底色与波形页「标注放大器」那张
    // 小卡同一套：#d9d9d9 92% 叠在窗口底色上 ≈ #dcdcdc
    background: Rectangle {
        radius: root.cornerRadius
        color: Qt.rgba(0xd9 / 255, 0xd9 / 255, 0xd9 / 255, 0.92)
        border.width: 1
        border.color: Design.panelBorder
    }

    contentItem: Column {
        spacing: 0

        Repeater {
            model: [
                {
                    label: qsTr("修改密码"),
                    icon: Design.assetRoot + "icons/icon-change-password.svg",
                    iconSize: 18
                },
                {
                    label: qsTr("退出登录"),
                    icon: Design.assetRoot + "icons/icon-logout.svg",
                    iconSize: 14
                }
            ]

            delegate: Item {
                required property var modelData
                required property int index

                width: parent.width
                height: root.rowHeight

                // 悬停行的底色。卡片是圆角，而 Rectangle 的 radius 四角一起给，
                // 方角色块会溢出圆角；于是「四角圆角的底色 + 一块补齐内侧方角的
                // 补丁」拼出只在外侧圆角的形状（第一行补下两角，第二行补上两角）
                Rectangle {
                    anchors.fill: parent
                    radius: root.cornerRadius - root.padding
                    color: Design.primarySoft
                    visible: rowMouse.containsMouse
                }

                Rectangle {
                    y: index === 0 ? parent.height - height : 0
                    width: parent.width
                    height: root.cornerRadius - root.padding
                    color: Design.primarySoft
                    visible: rowMouse.containsMouse
                }

                // 行间分隔线。画在第二行顶部，免得给第一行多撑出 1px
                Rectangle {
                    width: parent.width
                    height: 1
                    visible: index === 1
                    color: Design.divider
                }

                Item {
                    x: root.iconLeft
                    width: root.iconSlot
                    height: root.iconSlot
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.centerIn: parent
                        width: modelData.iconSize
                        height: modelData.iconSize
                        source: modelData.icon
                    }
                }

                Text {
                    x: root.textLeft
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                MouseArea {
                    id: rowMouse
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
