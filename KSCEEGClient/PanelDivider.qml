import QtQuick

// 面板分隔线。设计稿里有两类：
//  - 默认（fade）：标题下方那条，从左侧的主色向右淡出
//  - strong       ：波形面板标题下方那条，贯穿整宽、颜色偏实
// 两种都是从设计稿渲染图里采样出来的近似值。
Item {
    id: root

    property bool strong: false

    implicitHeight: 1
    height: 1

    Rectangle {
        anchors.fill: parent
        visible: root.strong

        gradient: Gradient {
            GradientStop { position: 0.0; color: "#9c9c9c" }
            GradientStop { position: 0.5; color: "#98a3aa" }
            GradientStop { position: 1.0; color: "#9c9c9c" }
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: !root.strong

        gradient: Gradient {
            GradientStop { position: 0.00; color: Qt.rgba(0.44, 0.57, 0.67, 0.30) }
            GradientStop { position: 0.55; color: Qt.rgba(0.44, 0.57, 0.67, 0.10) }
            GradientStop { position: 1.00; color: Qt.rgba(0.44, 0.57, 0.67, 0.00) }
        }
    }
}
