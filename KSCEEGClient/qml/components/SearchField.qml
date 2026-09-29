import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 列表页右上角的搜索框（患者管理 / 历史记录 / 用户管理三页共用）。
//
// 设计稿里它只是一个写着提示文字的色块，没有输入态 —— 三页的搜索在原型里都是
// 真的能过滤的，所以这里接成可输入的框，外观照抄设计稿（主色 10% 底、圆角 12、
// 提示文字 #3b3b3b 30%）。
//
// 多出来的只有一个「✕」：清空按钮。设计稿没有它，但搜索框一旦有内容，
// 想把内容删干净只能靠全选再删，三页都会遇到
Item {
    id: root

    property alias text: input.text
    property string placeholder: ""
    // 输入焦点在框上时把光标形状也换掉，否则鼠标移上去像块静态色块
    property int pixelSize: 16

    signal cleared()
    // 回车：过滤器本来就是即时的，这个信号只给「回车时想额外做点什么」的页面留着
    signal accepted()

    implicitWidth: 215
    implicitHeight: 43

    function clear() { input.text = "" }

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Design.primarySoft
        border.width: 1
        // 聚焦时描边变主色：不然根本看不出这个框可以输入
        border.color: input.activeFocus ? Design.primary : Design.panelBorder
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 13
        anchors.rightMargin: 30      // 给右侧的清空按钮让位
        verticalAlignment: TextInput.AlignVCenter
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: root.pixelSize
        selectionColor: Design.primary
        selectedTextColor: "#ffffff"
        selectByMouse: true
        activeFocusOnTab: true
        clip: true
        onAccepted: root.accepted()
    }

    // 提示文字（#3b3b3b 30%，与各弹窗的占位提示同一套）
    Text {
        x: 13
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 43
        elide: Text.ElideRight
        text: root.placeholder
        visible: input.text.length === 0
        color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: root.pixelSize
    }

    // 清空。只在有内容时出现，空框上挂个没用的叉只会添乱
    Item {
        x: parent.width - 30
        y: 0
        width: 30
        height: parent.height
        visible: input.text.length > 0
        opacity: clearMouse.containsMouse ? 1.0 : 0.55

        Rectangle {
            anchors.centerIn: parent
            width: 17
            height: 17
            radius: 9
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.16)

            Image {
                anchors.centerIn: parent
                width: 7.5
                height: 7.5
                source: Design.assetRoot + "icons/icon-close.svg"
            }
        }

        MouseArea {
            id: clearMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                input.text = ""
                root.cleared()
                input.forceActiveFocus()
            }
        }
    }
}
