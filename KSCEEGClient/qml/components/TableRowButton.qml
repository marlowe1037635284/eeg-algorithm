import QtQuick
import KSCEEGClient

// 表格数据行里的小圆角按钮，患者管理 / 历史记录 / 用户管理三页共用。
//
// 设计稿里「设为当前」宽 81，其余（编辑/记录/删除/预览/分析/导出）宽 59，
// 所以默认给 59，需要更宽的调用方自己覆盖 width。
// danger 为真时用红色描边和文字（患者管理的「删除」是这样，历史记录页不是，按各自设计稿给）。
Rectangle {
    id: button

    property string text: ""
    property bool danger: false
    signal clicked()

    width: 59
    height: 31
    radius: 8
    color: danger ? Design.badSoft : Design.primarySoft
    border.width: 1
    border.color: danger ? Design.bad : Design.panelBorder
    // 禁用时压暗。Item 的 enabled 会传播给子项，所以里面的 MouseArea 自动不吃点击，
    // 不必再单独绑一次
    opacity: enabled ? 1.0 : 0.4

    Text {
        anchors.centerIn: parent
        text: button.text
        color: button.danger ? Design.bad : "#4f4f4f"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 16
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
