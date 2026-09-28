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
    // 新建标签那张卡片矮，标题和关闭叉要跟着上移一点
    property real titleY: 23
    property real closeY: 32

    // 正文用「画板绝对坐标」还是「卡片内相对坐标」。
    // 六个弹窗里两种写法都有，这里给个开关，省得为了统一去改几十个坐标。
    property bool contentInCanvasCoords: false

    // 内容槽的坐标原点：默认落在卡片左上角，所以正文按「卡片内相对坐标」写
    default property alias contentChildren: body.data

    signal dismissed()

    // ---------- 遮罩 ----------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0xdb / 255, 0xdd / 255, 0xe0 / 255, 0.60)

        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (frame.dismissOnBackdrop)
                    frame.dismissed()
            }
        }
    }

    // ---------- 白色卡片 ----------
    Rectangle {
        x: frame.cardX
        y: frame.cardY
        width: frame.cardWidth
        height: frame.cardHeight
        radius: 16
        color: "#ffffff"

        Text {
            x: 26
            y: frame.titleY
            text: frame.title
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 24
        }

        Image {
            x: frame.cardWidth - 42
            y: frame.closeY
            width: 14.12
            height: 14.12
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
