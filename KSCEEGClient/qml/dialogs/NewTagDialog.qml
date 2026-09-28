import QtQuick
import KSCEEGClient

// 「新建标签」弹窗。按 Figma 设计稿 1:1 实现。
//
// 设计稿画板 1920×1080，白色卡片位于 (657,413)、尺寸 606×255；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (657,413)，数值照抄施工图。
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 8 个可选标签色（取自施工图）
    readonly property var tagColors: ["#e5494d", "#f76b14", "#e6a014", "#31a46d",
                                      "#12a593", "#3f63dd", "#8e4ec6", "#6e7788"]
    // 标签名最长 20 个字符，右下角的计数提示跟着走
    readonly property int maxNameLength: 20

    property alias tagName: tagNameInput.text
    property int selectedColorIndex: 7      // 设计稿默认选中第 8 个（灰）
    readonly property string selectedColor: root.tagColors[root.selectedColorIndex]

    DialogFrame {
        title: qsTr("新建标签")
        cardX: 657
        cardY: 413
        cardWidth: 606
        cardHeight: 255
        titleY: 14
        closeY: 20
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        // 上下两条分隔线（设计稿是渐变描边）
        PanelDivider { x: 7; y: 57; width: 592 }
        PanelDivider { x: 7; y: 192; width: 592 }

        // ---------- 标签名称 ----------
        Text {
            x: 26
            y: 78
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("标签名称")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
            font.letterSpacing: -0.27
        }

        Rectangle {
            x: 113
            y: 70
            width: 463
            height: 43
            radius: 12
            color: Design.primarySoft

            TextInput {
                id: tagNameInput
                x: 20
                y: 11
                width: parent.width - 20 - 40     // 右侧给字数提示留位置
                height: 22
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
                selectionColor: Design.primary
                selectedTextColor: "#ffffff"
                selectByMouse: true
                clip: true
                maximumLength: root.maxNameLength
            }

            // 输入提示
            Text {
                x: 20
                y: 11
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: qsTr("例如：紧急、设计评审···")
                visible: tagNameInput.text.length === 0
                color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }

            // 字数提示，跟着输入长度变
            Text {
                x: 428
                y: 11
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: tagNameInput.text.length + "/" + root.maxNameLength
                color: Qt.rgba(0, 0, 0, 0.40)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
                font.letterSpacing: -0.27
            }
        }

        // ---------- 标签颜色 ----------
        Text {
            x: 26
            y: 135
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("标签颜色")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
            font.letterSpacing: -0.27
        }

        Repeater {
            model: root.tagColors

            delegate: Item {
                required property int index
                required property string modelData

                x: 115 + 45 * index    // 色块起点 772，间距 45
                y: 132                  // 545 - 413
                width: 33
                height: 33

                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: modelData
                }

                // 选中项：外面套一圈黑框（施工图是偏移 -3 的 39×39 描边框）
                Rectangle {
                    x: -3
                    y: -3
                    width: 39
                    height: 39
                    radius: 10
                    color: "transparent"
                    border.width: 1
                    border.color: "#000000"
                    visible: index === root.selectedColorIndex
                }

                Image {
                    anchors.centerIn: parent
                    width: 13.63
                    height: 9.48
                    source: Design.assetRoot + "icons/icon-check-bold.svg"
                    visible: index === root.selectedColorIndex
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectedColorIndex = index
                }
            }
        }

        // ---------- 底部按钮 ----------
        DialogButton {
            x: 328
            y: 206
            text: qsTr("返回检查")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: 460
            y: 206
            text: qsTr("创建标签")
            primary: true
            onClicked: root.accepted()
        }
    }

    // 弹窗底部的胶囊按钮：次要按钮主色 50% 描边，主按钮实心主色
    component DialogButton: Rectangle {
        id: dialogButton

        property string text: ""
        property bool primary: false
        signal clicked()

        width: 121
        height: 35
        radius: 12
        color: dialogButton.primary
               ? (dialogButtonMouse.pressed ? "#64879f" : Design.primary)
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
            font.letterSpacing: -0.27
        }

        MouseArea {
            id: dialogButtonMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dialogButton.clicked()
        }
    }
}
