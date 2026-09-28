import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「实时脑电地形图」面板。
// 设计稿里位于画板 (1572,150)，尺寸 331×590；本文件坐标 = 设计坐标 - (1572,150)。
Item {
    id: root

    // 地形图上的电极：圆形标记 16×16，标签字号 8，标签竖直居中于圆点
    readonly property var electrodes: [
        { name: "Fp1", x: 122, y: 75,  labelX: 124, labelY: 69 },
        { name: "Fp2", x: 198, y: 75,  labelX: 199, labelY: 69 },
        { name: "AF3", x: 125, y: 105, labelX: 126, labelY: 99 },
        { name: "F5",  x: 91,  y: 119, labelX: 95,  labelY: 113 },
        { name: "F3",  x: 113, y: 124, labelX: 117, labelY: 118 },
        { name: "F1",  x: 135, y: 128, labelX: 139, labelY: 122 },
        { name: "Fz",  x: 159, y: 129, labelX: 163, labelY: 123 },
        { name: "F2",  x: 181, y: 128, labelX: 185, labelY: 122 },
        { name: "FC3", x: 109, y: 149, labelX: 111, labelY: 143 },
        { name: "FC1", x: 131, y: 152, labelX: 133, labelY: 146 },
        { name: "M1",  x: 53,  y: 171, labelX: 56,  labelY: 165 },
        { name: "M2",  x: 264, y: 171, labelX: 267, labelY: 165 },
        { name: "Cz",  x: 159, y: 178, labelX: 163, labelY: 172 },
        { name: "P3",  x: 121, y: 214, labelX: 124, labelY: 208 },
        { name: "Oz",  x: 159, y: 251, labelX: 162, labelY: 245 }
    ]

    // 设计稿里有 3 个电极套了一圈白环（当前关注点）
    readonly property var highlightRings: [
        { x: 133, y: 126 },
        { x: 157, y: 127 },
        { x: 179, y: 126 }
    ]

    // 色标条**不再自己抄一份色值**，而是取 Acq.topoPalette —— 与 C++ 画热力图
    // 用的是同一张表。设计稿那 16 段色值和实际渲染用的色标是两套，抄任何一套
    // 都会与图对不上，而色标是按图读值的唯一依据。
    // 频段选择块：range 原本五块全写成 "0.5-4"（占位），换成真实边界；
    // band 字段与 C++ 的 band_from_name 认的取值一一对应，写错那边会直接忽略
    readonly property var bandSelectors: [
        { band: "delta", letter: "δ", range: "0.5-4", boxX: 26,  letterX: 45,  rangeX: 33 },
        { band: "theta", letter: "θ", range: "4-8",   boxX: 84,  letterX: 103, rangeX: 91 },
        { band: "alpha", letter: "α", range: "8-13",  boxX: 142, letterX: 161, rangeX: 149 },
        { band: "beta",  letter: "β", range: "13-30", boxX: 199, letterX: 218, rangeX: 206 },
        { band: "gamma", letter: "γ", range: "30-45", boxX: 258, letterX: 278, rangeX: 265 }
    ]

    // 四项统计由 C++ 侧算好并格式化（topoStats 固定四项），这边不做二次加工。
    // 取不到时统一显示短横，免得界面上出现 "undefined"
    readonly property var metrics: {
        var stats = Acq.topoStats
        if (!stats || stats.length !== 4)
            stats = ["—", "—", "—", "—"]
        return [
            { label: qsTr("峰值电极"), value: stats[0] },
            { label: qsTr("峰值功率(μV²/Hz)"), value: stats[1] },
            { label: qsTr("全脑均值(μV²/Hz)"), value: stats[2] },
            { label: qsTr("枕/额比"), value: stats[3] },
            { label: qsTr("时窗"), value: "2.0s" }
        ]
    }

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Text {
        x: 14
        y: 6
        text: qsTr("实时脑电地形图")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    PanelDivider {
        x: 5
        y: 41
        width: 321
    }

    // 地形图圆（渐变底色 + 主色描边，直接用了设计稿导出的矢量）
    Image {
        x: 54
        y: 61
        width: 224
        height: 223
        source: Design.assetRoot + "icons/topo-circle.svg"
        fillMode: Image.Stretch
    }

    // 热力图。**必须夹在底盘与白环/电极点之间**：盖在底盘之上才有底色可叠，
    // 压在电极点之下才不会把导联名挡住。
    // 图由 C++ 画好（头型掩膜外是透明的），这里只管贴；
    // revision 变化只是用来制造新 URL，否则 Image 会按 URL 缓存，图永远不更新
    Image {
        x: 54
        y: 61
        width: 224
        height: 223
        fillMode: Image.Stretch
        cache: false
        asynchronous: false
        smooth: true
        source: "image://topography/render/" + Acq.topoRevision
    }

    // 关注点白环（画在圆点下面）
    Repeater {
        model: root.highlightRings

        delegate: Rectangle {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: 20
            height: 20
            radius: 10
            color: "transparent"
            border.width: 1
            border.color: "#ffffff"
        }
    }

    Repeater {
        model: root.electrodes

        delegate: Item {
            required property var modelData

            Rectangle {
                x: modelData.x
                y: modelData.y
                width: 16
                height: 16
                radius: 8
                color: "#ffffff"
                border.width: 1
                border.color: "#424242"
            }

            Text {
                x: modelData.labelX
                y: modelData.labelY
                width: 30
                height: 28
                verticalAlignment: Text.AlignVCenter
                text: modelData.name
                color: "#424242"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 8
            }
        }
    }

    // 「峰值」小徽标
    Image {
        x: 168
        y: 102
        width: 41
        height: 22
        source: Design.assetRoot + "icons/peak-badge.svg"
        fillMode: Image.Stretch
    }

    Text {
        x: 177
        y: 103
        width: 24
        height: 16
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: qsTr("峰值")
        color: "#ffffff"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- 色标 ----------
    Text {
        x: 141
        y: 286
        text: qsTr("μV²/Hz")
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // 色值一律从 Acq.topoPalette 取 —— 与 C++ 画热力图是同一份表。
    // 设计稿那张 16 段色标和实际渲染用的色标是两套色值，抄任何一套都会与图对不上
    Row {
        x: 30
        y: 308

        Repeater {
            model: Acq.topoPalette

            delegate: Rectangle {
                required property string modelData
                width: 17
                height: 17
                color: modelData
            }
        }
    }

    // 刻度。右端**不能写死**：图是按每帧峰值归一化配色的，写死的话
    // 数字和实际配色对不上，读出来的值就是错的
    Text {
        x: 27
        y: 324
        text: "0"
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    Text {
        x: 159
        y: 324
        text: (Acq.topoScaleMax / 2).toFixed(1)
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    Text {
        x: 294
        y: 324
        text: Acq.topoScaleMax.toFixed(1)
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // ---------- 频段选择块 ----------
    Repeater {
        model: root.bandSelectors

        delegate: Item {
            required property var modelData
            required property int index

            // 绑到 C++ 的 topoBand 而不是自己存一份选中态：切换频段后由
            // C++ 侧确认的结果说了算，两边不会各说各话
            readonly property bool active: Acq.topoBand === modelData.band

            Rectangle {
                x: modelData.boxX
                y: 353
                width: 48.74
                height: 51
                radius: 10
                color: parent.active ? Design.primarySoft : Qt.rgba(0xc9 / 255, 0xc9 / 255, 0xc9 / 255, 0.29)
                border.width: 1
                border.color: parent.active ? Design.primary : Qt.rgba(0xa3 / 255, 0xa3 / 255, 0xa3 / 255, 0.27)
            }

            Text {
                x: modelData.letterX
                y: 356
                width: 14
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.letter
                color: parent.active ? Design.primary : Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            Text {
                x: modelData.rangeX
                y: 378
                width: 34
                height: 19
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.range
                color: parent.active ? Design.primary : Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                x: modelData.boxX
                y: 353
                width: 48.74
                height: 51
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Acq.topoBand = modelData.band

                ToolTip.visible: containsMouse
                ToolTip.text: qsTr("%1 频段（%2 Hz）").arg(modelData.letter).arg(modelData.range)
                ToolTip.delay: 400
            }
        }
    }

    // ---------- 指标列表 ----------
    Repeater {
        model: root.metrics

        delegate: Item {
            required property var modelData
            required property int index

            readonly property int rowY: 421 + Math.round(32.75 * index)

            // 注意：delegate 必须给宽度，否则里面的 anchors.right: parent.right
            // 会锚到一个 0 宽的 Item 上，数值文字会跑到面板外面去。
            y: rowY
            width: root.width
            height: 22

            Text {
                x: 26
                y: 0
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: modelData.label
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 24
                y: 0
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: modelData.value
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }
    }
}
