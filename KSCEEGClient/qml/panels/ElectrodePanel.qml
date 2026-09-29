import QtQuick
import KSCEEGClient

// 「电极贴合状态」面板。
// 设计稿里位于画板 (107,225)，尺寸 331×499；本文件坐标 = 设计坐标 - (107,225)。
Item {
    id: root

    // 电极点：位置来自设计稿，state 决定颜色（良好/一般/不良/脱落）
    // x,y = 圆点左上角（16×16），labelX/labelY = 导联名文本框左上角（高 28，字号 8）
    readonly property var electrodes: [
        { name: "Fp1", x: 121, y: 123, labelX: 123, labelY: 117, state: "良好" },
        { name: "Fp2", x: 197, y: 123, labelX: 198, labelY: 117, state: "良好" },
        { name: "AF3", x: 124, y: 153, labelX: 125, labelY: 147, state: "良好" },
        { name: "F5",  x: 90,  y: 167, labelX: 94,  labelY: 161, state: "良好" },
        { name: "F3",  x: 112, y: 172, labelX: 116, labelY: 166, state: "良好" },
        { name: "F1",  x: 135, y: 176, labelX: 139, labelY: 170, state: "不良" },
        { name: "Fz",  x: 158, y: 177, labelX: 162, labelY: 171, state: "良好" },
        { name: "F2",  x: 180, y: 176, labelX: 184, labelY: 170, state: "良好" },
        { name: "F4",  x: 203, y: 170, labelX: 207, labelY: 164, state: "脱落" },
        { name: "FC3", x: 108, y: 197, labelX: 110, labelY: 191, state: "良好" },
        { name: "FC1", x: 130, y: 200, labelX: 132, labelY: 194, state: "良好" },
        { name: "Cz",  x: 159, y: 216, labelX: 163, labelY: 210, state: "良好" },
        { name: "M1",  x: 52,  y: 213, labelX: 55,  labelY: 207, state: "良好" },
        { name: "M2",  x: 263, y: 213, labelX: 266, labelY: 207, state: "良好" },
        { name: "P3",  x: 120, y: 262, labelX: 123, labelY: 256, state: "良好" },
        { name: "Oz",  x: 158, y: 299, labelX: 161, labelY: 293, state: "良好" }
    ]

    // 阻抗列表：barWidth 是设计稿给出的进度条长度（照抄，不做换算）
    readonly property var impedances: [
        { name: "Fp1", value: "8.2kΩ", level: "良好", barWidth: 45 },
        { name: "Fp2", value: "4.1kΩ", level: "一般", barWidth: 89 },
        { name: "F3",  value: "4.1kΩ", level: "不良", barWidth: 33 },
        { name: "F4",  value: "4.1kΩ", level: "不良", barWidth: 33 },
        { name: "C3",  value: "3.2kΩ", level: "良好", barWidth: 52 },
        { name: "C4",  value: "3.6kΩ", level: "良好", barWidth: 48 },
        { name: "P3",  value: "5.4kΩ", level: "一般", barWidth: 72 },
        { name: "P4",  value: "9.1kΩ", level: "不良", barWidth: 26 },
        { name: "O1",  value: "3.0kΩ", level: "良好", barWidth: 55 },
        { name: "O2",  value: "2.8kΩ", level: "良好", barWidth: 58 },
        { name: "F7",  value: "4.8kΩ", level: "一般", barWidth: 80 },
        { name: "F8",  value: "6.2kΩ", level: "一般", barWidth: 66 },
        { name: "T7",  value: "3.4kΩ", level: "良好", barWidth: 50 },
        { name: "T8",  value: "4.0kΩ", level: "良好", barWidth: 46 },
        { name: "Fz",  value: "2.6kΩ", level: "良好", barWidth: 60 },
        { name: "Cz",  value: "2.4kΩ", level: "良好", barWidth: 62 }
    ]

    // 阻抗列表可视高度与滚动：设计稿画了 4 行 + 右侧滚动条，说明下面是可滚的
    readonly property int impedanceRowHeight: 32
    readonly property int impedanceViewHeight: 134
    property real impedanceScroll: 0
    readonly property real impedanceMaxScroll: Math.max(0, impedances.length * impedanceRowHeight - impedanceViewHeight)


    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Text {
        x: 14
        y: 10
        text: qsTr("电极贴合状态")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 阻抗扫描按钮（设计稿右上角）
    Rectangle {
        x: 202
        y: 7
        width: 115
        height: 31
        radius: 12
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Image {
            x: 17
            y: 10
            width: 16
            height: 13
            source: Design.assetRoot + "icons/icon-scan.svg"
        }

        Text {
            x: 36
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("阻抗扫描")
            color: "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }

    PanelDivider {
        x: 5
        y: 45
        width: 321
    }

    // ---------- 图例 ----------
    // 设计稿只画了「良好/一般/脱落」三项（面板宽度放不下第四项），
    // 但颜色按语义修正：良好=绿、一般=橙、脱落=灰。
    Row {
        x: 129
        y: 54
        spacing: 21

        Repeater {
            model: [
                { label: "良好", state: "良好" },
                { label: "一般", state: "一般" },
                { label: "脱落", state: "脱落" }
            ]

            delegate: Item {
                required property var modelData
                width: 47
                height: 28

                Rectangle {
                    x: 0
                    y: 9
                    width: 10
                    height: 10
                    radius: 5
                    color: Design.impedanceColor(modelData.state)
                }

                Text {
                    x: 19
                    y: 0
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.label
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }
    }

    // ---------- 电极分布图 ----------
    Image {
        x: 14
        y: 89
        width: 303
        height: 260
        source: Design.assetRoot + "icons/head-panel.svg"
        fillMode: Image.Stretch
    }

    Image {
        x: 54
        y: 104
        width: 224
        height: 223
        source: Design.assetRoot + "icons/head-outline.svg"
        fillMode: Image.Stretch
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
                color: Design.electrodeFill(modelData.state)
                border.width: 1
                border.color: Design.impedanceColor(modelData.state)
            }

            Text {
                x: modelData.x + 8 - 15
                y: modelData.labelY
                width: 30
                height: 28
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.name
                color: Design.impedanceColor(modelData.state)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 8
            }
        }
    }

    // ---------- 阻抗列表（可视 4 行，滚轮滚动）----------
    Item {
        id: impedanceViewport
        x: 0
        y: 365
        width: root.width
        height: root.impedanceViewHeight
        clip: true

        Repeater {
            model: root.impedances

            delegate: Item {
                required property var modelData
                required property int index

                readonly property int rowY: 32 * index - root.impedanceScroll

                // 行分隔线（首行上方不画）
                PanelDivider {
                    y: rowY - 1
                    width: 303
                    visible: index > 0
                }

                Text {
                    x: 14
                    y: rowY
                    width: 40
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.name
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Rectangle {
                    x: 46
                    y: rowY + 10
                    width: 178
                    height: 10
                    radius: 5
                    color: Qt.rgba(0, 0, 0, 0.07)
                }

                Rectangle {
                    x: 46
                    y: rowY + 10
                    width: modelData.barWidth
                    height: 10
                    radius: 5
                    color: Design.impedanceColor(modelData.level)
                }

                Text {
                    x: 236
                    y: rowY
                    width: 50
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.value
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 280
                    y: rowY
                    width: 44
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.level
                    color: Design.impedanceColor(modelData.level)
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: (wheel) => {
                var step = wheel.angleDelta.y > 0 ? -root.impedanceRowHeight : root.impedanceRowHeight
                root.impedanceScroll = Math.max(0, Math.min(root.impedanceMaxScroll, root.impedanceScroll + step))
            }
        }
    }

    // ---------- 滚动条 ----------
    Rectangle {
        x: 319
        y: 370
        width: 7
        height: 114
        radius: 4
        color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
    }

    Rectangle {
        x: 319
        // 轨道 114 高、滑块 24 高，可走 90px
        y: 386 + (root.impedanceMaxScroll > 0 ? root.impedanceScroll / root.impedanceMaxScroll : 0) * 90
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
    }
}
