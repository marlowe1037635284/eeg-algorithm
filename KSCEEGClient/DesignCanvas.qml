import QtQuick

// 设计画布：把 1920×1080 的绝对坐标内容等比缩放到实际窗口大小。
//
// 所有页面都按设计稿画板（1920×1080）的绝对坐标来写，由这一层统一负责缩放，
// 页面自己不用管窗口尺寸。之前这段代码在 LoginPage / WorkbenchPage 里各写了一遍，
// 页面一多就重复了，抽到这里。
Item {
    id: canvasRoot

    // 页面内容：直接作为子项写进来即可，坐标按 1920×1080 的绝对坐标给
    default property alias pageChildren: designCanvas.data

    readonly property real contentScale: Math.min(width / Design.canvasWidth,
                                                 height / Design.canvasHeight)

    Rectangle {
        anchors.fill: parent
        color: "#f2f2f2"
    }

    Item {
        anchors.centerIn: parent
        width: Design.canvasWidth * canvasRoot.contentScale
        height: Design.canvasHeight * canvasRoot.contentScale
        clip: true

        Item {
            id: designCanvas
            width: Design.canvasWidth
            height: Design.canvasHeight
            scale: canvasRoot.contentScale
            transformOrigin: Item.TopLeft
        }
    }
}
