import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 下拉选择：点开一个列表来挑，而不是点一下切到下一个。
//
// 原来各处（新增/编辑患者的性别与科室、滤波与后处理的参考方式、工作台工具栏的
// 幅值与时基）都是「点击循环取值」：两个选项时凑合，三个以上就根本点不到想要的那个，
// 而且完全没有「有哪些可选」的提示。这里统一换成弹出列表。
//
// 用 Popup 而不是自己铺一层遮罩：Popup 在窗口的 overlay 层渲染，天然盖在所有内容
// 之上（手写的列表会被后面声明的兄弟控件压住），点别处关闭、Esc 关闭也都是现成的。
Item {
    id: root

    property var choices: []
    property int currentIndex: 0
    property string placeholder: ""
    // 调用方已经画了底（比如编辑患者里的 Field）时置 false
    property bool showBackground: true
    property int pixelSize: 16
    property color textColor: "#3b3b3b"
    property real fieldRadius: 12

    signal activated(int index)

    readonly property string currentText:
        (currentIndex >= 0 && currentIndex < choices.length) ? choices[currentIndex] : ""

    implicitWidth: 204
    implicitHeight: 43

    Rectangle {
        anchors.fill: parent
        visible: root.showBackground
        radius: root.fieldRadius
        color: Design.primarySoft
        border.width: 1
        border.color: (mouse.containsMouse || popup.visible) ? Design.primary : Design.panelBorder
    }

    Text {
        x: 13
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 13 - 26
        elide: Text.ElideRight
        text: root.currentText.length > 0 ? root.currentText : root.placeholder
        // 没选中时用占位色，和文本框那一套一致
        color: root.currentText.length > 0
               ? root.textColor
               : Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: root.pixelSize
    }

    Image {
        x: parent.width - 24
        anchors.verticalCenter: parent.verticalCenter
        width: 7.47
        height: 7
        rotation: 90
        source: Design.assetRoot + "icons/icon-arrow-down.svg"
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: popup.visible ? popup.close() : popup.open()
    }

    Popup {
        id: popup

        // 贴着控件下方展开，宽度与控件一致
        x: 0
        y: root.height + 4
        width: root.width
        padding: 0
        // 点别处 / 按 Esc 关闭交给 Popup 自己处理
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: 8
            color: "#ffffff"
            border.width: 1
            border.color: Design.panelBorder
        }

        contentItem: ListView {
            id: listView

            // 限高：超过 7 项（7×36=252）就内部滚动。不限高的话列表会一路往下铺，
            // 顶出窗口底部 —— 标签建到七八个以后，后半截选项根本点不到
            implicitHeight: Math.min(contentHeight, 252)
            model: root.choices
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // 内容装得下时锁住滚动，避免整列被拖出空白
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                required property string modelData
                required property int index

                width: popup.width
                height: 36
                radius: 6
                color: (index === root.currentIndex || itemMouse.containsMouse)
                       ? Design.primarySoft : "transparent"

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 16
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: modelData
                    color: index === root.currentIndex ? Design.primary : "#3b3b3b"
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
                        root.currentIndex = index
                        root.activated(index)
                        popup.close()
                    }
                }
            }
        }
    }
}
