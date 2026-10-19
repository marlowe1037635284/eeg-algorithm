import QtQuick
import KSCEEGClient

// 弹窗外框：整屏遮罩 + 白色圆角卡片 + 标题 + 右上角关闭叉。
//
// 六个弹窗共用这一层，正文直接写成 DialogFrame 的子项即可（坐标相对卡片左上角）。
// 卡片位置和尺寸按各弹窗的设计稿给；标题和关闭叉的位置设计稿里每个弹窗差几个像素，
// 这里统一成一套（差距肉眼不可见，也省得每处都写一遍）。
Item {
    id: frame

    property string title: ""
    property real cardX: 657
    property real cardY: 298
    property real cardWidth: 606
    property real cardHeight: 484
    // 点遮罩是否关闭：设计稿里有的弹窗点空白处会关、有的只是吞掉点击
    property bool dismissOnBackdrop: true
    // 遮罩要不要压暗整屏。浮层类弹窗（如设备连接）贴在按钮下方，不该把整屏压灰
    property bool showBackdrop: true
    // 要不要画右上角的关闭叉。浮层靠点外面关，就不画叉
    property bool showClose: true
    // 卡片底色。默认白卡；设备连接浮层按设计稿用浅灰（rgb 220）
    property color cardColor: "#ffffff"
    // 新建标签那张卡片矮，标题和关闭叉要跟着上移一点
    property real titleY: 23
    property real closeY: 32
    // 标题颜色。默认正文色；授权失败这类警告弹窗要把它改成红色
    property color titleColor: Design.textPrimary

    // 正文用「画板绝对坐标」还是「卡片内相对坐标」。
    // 六个弹窗里两种写法都有，这里给个开关，省得为了统一去改几十个坐标。
    property bool contentInCanvasCoords: false

    // 内容槽的坐标原点：默认落在卡片左上角，所以正文按「卡片内相对坐标」写
    default property alias contentChildren: body.data
    // 卡片内的正文容器。需要把「整份内容」渲染成图片时（如报告导出 PDF），
    // 调用方要从这里 grabToImage —— 只截正文，不带遮罩与标题栏
    readonly property Item contentRoot: body

    signal dismissed()

    // ---------- 遮罩 ----------
    // 尺寸取整张画板，而不是 anchors.fill: parent —— 本组件被各弹窗直接写成子项、
    // 自身没有尺寸（0×0），anchors.fill 会让遮罩缩成 0×0：既看不见、也接不到点击，
    // 于是「点外面关闭」永远不触发，浮层就关不掉了。各弹窗的根 Item 都被 Loader
    // 拉成 1920×1080，这里按画板尺寸铺满，收点击的范围就对了
    Rectangle {
        x: 0
        y: 0
        width: Design.canvasWidth
        height: Design.canvasHeight
        // showBackdrop 关掉时遮罩透明：浮层贴在按钮下方，不压暗整屏；但这层仍然在，
        // 点它（也就是卡片以外的地方）就把浮层收起来
        color: Qt.rgba(0xdb / 255, 0xdd / 255, 0xe0 / 255, frame.showBackdrop ? 0.60 : 0.0)

        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (frame.dismissOnBackdrop)
                    frame.dismissed()
            }
        }
    }

    // ---------- 卡片 ----------
    Rectangle {
        x: frame.cardX
        y: frame.cardY
        width: frame.cardWidth
        height: frame.cardHeight
        radius: 16
        color: frame.cardColor

        // 吞掉卡片范围内的点击：否则点在卡片空白处会穿透到底下的遮罩，被当成「点外面」
        // 而把弹窗关掉。放在最前面（正文之前），正文里的按钮仍在它上层，不受影响
        MouseArea {
            anchors.fill: parent
        }

        Text {
            x: 26
            y: frame.titleY
            text: frame.title
            color: frame.titleColor
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 24
        }

        Image {
            x: frame.cardWidth - 42
            y: frame.closeY
            width: 14.12
            height: 14.12
            visible: frame.showClose
            source: Design.assetRoot + "icons/icon-close.svg"

            MouseArea {
                anchors.fill: parent
                anchors.margins: -8
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: frame.dismissed()
            }
        }

        // 正文插槽：原点在卡片左上角，正文沿用卡内相对坐标
        Item {
            id: body
            // 绝对坐标模式下把原点挪回画板左上角
            x: frame.contentInCanvasCoords ? -frame.cardX : 0
            y: frame.contentInCanvasCoords ? -frame.cardY : 0
            width: frame.cardWidth
            height: frame.cardHeight
        }
    }
}
