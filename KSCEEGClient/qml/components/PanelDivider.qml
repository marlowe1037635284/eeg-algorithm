import QtQuick
import KSCEEGClient

// 面板分隔线 —— 标题下面那条横线。设计稿里有两类：
//  - 默认：设计导出的 assets/icons/divider-section.svg 本身，382×2 的描边，
//    主色 #7092AB 在两端几乎透明（1%）、在 47.8% 处最重（53%）。
//    直接放这个 SVG 而不是自己拼一条近似渐变：它是 0.75 宽的描边，
//    用 1px 矩形画出来会重三分之一，还会把两端淡出的形状丢掉。
//    注意渐变方向 —— 早先这里没写 orientation，Gradient 默认是**竖直**的，
//    压在 1px 高的矩形上等于整条线只剩一个中间色，整条既没有淡出、也偏淡。
//  - strong：波形面板标题下方那条，贯穿整宽、颜色偏实
Item {
    id: root

    property bool strong: false

    // SVG 是 2 高（描边落在 y=1.375），所以默认态元件本身就占 2
    implicitHeight: root.strong ? 1 : 2

    Rectangle {
        anchors.fill: parent
        visible: root.strong

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#9c9c9c" }
            GradientStop { position: 0.5; color: "#98a3aa" }
            GradientStop { position: 1.0; color: "#9c9c9c" }
        }
    }

    Image {
        anchors.left: parent.left
        anchors.right: parent.right
        y: 0
        height: 2
        visible: !root.strong
        source: Design.assetRoot + "icons/divider-section.svg"
        // 设计稿里这条线铺满所在容器的宽度（382 只是导出时的画布宽），
        // 所以横向拉伸到元件宽度，不做等比留白
        fillMode: Image.Stretch
        smooth: true
    }
}
