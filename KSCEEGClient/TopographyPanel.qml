import QtQuick

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

    // 色标条：16 段，取自设计稿
    readonly property var colorBar: [
        "#1a2b72", "#243e9b", "#2b53bc", "#2b72c6", "#2d8fd0", "#29a4bd", "#22baab", "#45c288",
        "#6ac663", "#96c74a", "#c0c443", "#e2bc3c", "#eba23d", "#f1883c", "#e5643d", "#d9403c"
    ]

    // 色标下方的频段选择块。第一块是选中态（主色淡底 + 主色描边），其余为未选中态。
    // boxX/letterX/rangeX 都是设计稿里的 x 坐标（已减去面板原点）。
    readonly property var bandSelectors: [
        { letter: "δ", range: "0.5-4", boxX: 26,  letterX: 45,  rangeX: 33,  selected: true },
        { letter: "θ", range: "0.5-4", boxX: 84,  letterX: 103, rangeX: 91,  selected: false },
        { letter: "α", range: "0.5-4", boxX: 142, letterX: 161, rangeX: 149, selected: false },
        { letter: "β", range: "0.5-4", boxX: 199, letterX: 218, rangeX: 206, selected: false },
        { letter: "γ", range: "0.5-4", boxX: 258, letterX: 278, rangeX: 265, selected: false }
    ]

    readonly property var metrics: [
        { label: "峰值电极", value: "01" },
        { label: "峰值功率(μV²/Hz)", value: "56.5" },
        { label: "全脑均值(μV²/Hz)", value: "22.9" },
        { label: "枕/额比", value: "8.2" },
        { label: "时窗", value: "1.0s·50%重叠" }
    ]

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
        font.family: Design.fontRegular
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
        source: "assets/icons/topo-circle.svg"
        fillMode: Image.Stretch
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
                font.family: Design.fontRegular
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
        source: "assets/icons/peak-badge.svg"
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
        font.family: Design.fontRegular
        font.pixelSize: 12
    }

    // ---------- 色标 ----------
    Text {
        x: 141
        y: 286
        text: qsTr("μV²/Hz")
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    Row {
        x: 30
        y: 308

        Repeater {
            model: root.colorBar

            delegate: Rectangle {
                required property string modelData
                width: 17
                height: 17
                color: modelData
            }
        }
    }

    Text {
        x: 27
        y: 324
        text: "0"
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    Text {
        x: 159
        y: 324
        text: "30"
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    Text {
        x: 294
        y: 324
        text: "60"
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    // ---------- 频段选择块 ----------
    Repeater {
        model: root.bandSelectors

        delegate: Item {
            required property var modelData

            Rectangle {
                x: modelData.boxX
                y: 353
                width: 48.74
                height: 51
                radius: 10
                color: modelData.selected ? Design.primarySoft : Qt.rgba(0xc9 / 255, 0xc9 / 255, 0xc9 / 255, 0.29)
                border.width: 1
                border.color: modelData.selected ? Design.primary : Qt.rgba(0xa3 / 255, 0xa3 / 255, 0xa3 / 255, 0.27)
            }

            Text {
                x: modelData.letterX
                y: 356
                width: 14
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.letter
                color: modelData.selected ? Design.primary : Design.textMuted
                font.family: Design.fontRegular
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
                color: modelData.selected ? Design.primary : Design.textMuted
                font.family: Design.fontRegular
                font.pixelSize: 14
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
                font.family: Design.fontRegular
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
                font.family: Design.fontRegular
                font.pixelSize: 16
            }
        }
    }
}
