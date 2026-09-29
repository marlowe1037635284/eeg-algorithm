import QtQuick
import KSCEEGClient

// 「采集记录预览」弹窗。按 Figma 设计稿 1:1 实现。
//
// 设计稿画板 1920×1080，白色卡片位于 (516,61)、尺寸 888×957；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (516,61)，数值照抄施工图。
//
// 注意：施工图导出文件开头还有一批 @1374,79 / @546,218 / @1370,215 之类的节点，
// 它们是被这个弹窗盖住的「采集记录」页表格（施工图里排在卡片之前绘制、随后被白色卡片完全遮住），
// 所以这里不重复实现。
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 要预览的记录号，弹出前由 Main 回填
    property string recordNo: "R-0011"

    // ---------- 头部信息 ----------
    property string recordId: "R-0011"
    property string patientName: qsTr("张文涛")
    property string patientMeta: qsTr("男  45岁")
    property string patientRecordNo: qsTr("P-0001·神经内科")

    // ---------- 概览信息卡（施工图 2 行 3 列）----------
    property var infoCards: [
        { x: 25,  y: 141, label: qsTr("采集时间"),      value: "2026-9-22 14:06:30" },
        { x: 309, y: 141, label: qsTr("时长"),          value: "00:00:01" },
        { x: 594, y: 141, label: qsTr("通道 / 采样率"), value: "16 ch · 256 Hz" },
        { x: 25,  y: 236, label: qsTr("幅值 / 时基"),   value: "100 μV · 2 s/div" },
        { x: 309, y: 236, label: qsTr("事件数"),        value: "2" },
        { x: 594, y: 236, label: qsTr("电极贴合"),      value: "14/16", good: true }
    ]

    property string playbackTime: "2.5 / 00:00:04"

    // 事件条（施工图底部两个「眼动/闭眼」事件）
    property var events: [
        { x: 43,  time: "16:13:05", label: qsTr("闭眼") },
        { x: 289, time: "16:13:05", label: qsTr("闭眼") }
    ]

    // ---------- 波形几何（均为卡片内坐标）----------
    readonly property int plotX: 24            // 绘图区（施工图 矩形 223）
    readonly property int plotY: 333
    readonly property int plotWidth: 842
    readonly property int plotHeight: 518

    readonly property int gridLeft: 64         // 横向网格线 x 范围 64..845
    readonly property int gridRight: 845
    readonly property int vLineTop: 345        // 纵向网格线 y 范围 345..761
    readonly property int vLineBottom: 761
    readonly property int laneTop: 354         // 第 1 条通道的中心线，间距 25
    readonly property int laneStep: 25
    readonly property int laneCount: 16

    readonly property var vGridX: [250, 455, 660]   // 纵向网格线（施工图 直线 43/63/64）
    readonly property var eventX: [142, 550]        // 紫色眼动竖线（施工图 直线 65/66）

    // 通道名与配色。施工图是 16 导联蒙太奇：前 8 条正是 Design.channelNames /
    // Design.channelColors 定义的那 8 条，直接复用设计变量；后 8 条施工图另有其名与配色，照抄
    // （施工图里写作 01/02，按 10-20 导联体系应为 O1/O2）。
    readonly property var laneNames: Design.channelNames.concat(["O1", "O2", "F7", "F8",
                                                                 "T7", "T8", "FZ", "CZ"])
    readonly property var laneColors: Design.channelColors.concat(["#c2b32e", "#c67342", "#b770d2", "#3eb5a7",
                                                                   "#beb459", "#76ac96", "#cb933e", "#4f86dc"])

    // 时间轴刻度（施工图给的绝对位置，间距 2s）
    readonly property var timeMarks: [
        { x: 50,  label: "-6.4s" },
        { x: 236, label: "-4.4s" },
        { x: 441, label: "-2.4s" },
        { x: 646, label: "-0.4s" },
        { x: 836, label: "1.6s" }
    ]

    DialogFrame {
        title: qsTr("采集记录预览 · %1").arg(root.recordNo)
        cardX: 516
        cardY: 61
        cardWidth: 888
        cardHeight: 957
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        PanelDivider { x: 7; y: 66; width: 859 }

        // ---------- 患者条 ----------
        Rectangle {
            x: 24
            y: 81
            width: 842
            height: 45
            radius: 10
            color: Design.primarySoft
        }

        Text {
            x: 47
            y: 87
            height: 33
            verticalAlignment: Text.AlignVCenter
            text: root.patientName
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
            font.letterSpacing: 0.73
        }

        Text {
            x: 118
            y: 93
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: root.patientMeta
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
            font.letterSpacing: 0.73
        }

        Text {
            x: 723
            y: 93
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: root.patientRecordNo
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
            font.letterSpacing: -0.27
        }

        // ---------- 概览信息卡 ----------
        Repeater {
            model: root.infoCards

            delegate: Item {
                required property var modelData

                x: modelData.x
                y: modelData.y
                width: 272
                height: 80

                Rectangle {
                    anchors.fill: parent
                    radius: 7
                    color: Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17)
                }

                Text {
                    x: 18
                    y: 13
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.label
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                    font.letterSpacing: -0.27
                }

                Text {
                    x: 18
                    y: 44
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.value
                    color: modelData.good ? Design.good : "#333333"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 16
                    font.letterSpacing: 0.73
                }
            }
        }

        // ---------- 波形区底 ----------
        Rectangle {
            x: root.plotX
            y: root.plotY
            width: root.plotWidth
            height: root.plotHeight
            radius: 7
            color: Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17)
        }

        // ---------- 波形（16 条通道 + 网格）----------
        Canvas {
            id: plot

            x: root.plotX
            y: root.plotY
            width: root.plotWidth
            height: root.plotHeight

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()

                // 画布内坐标 = 卡片坐标 - 绘图区原点
                var left = root.gridLeft - root.plotX
                var right = root.gridRight - root.plotX
                var top = root.vLineTop - root.plotY
                var bottom = root.vLineBottom - root.plotY
                var first = root.laneTop - root.plotY

                ctx.lineWidth = 1

                // 横向网格：每条通道的中心线
                ctx.strokeStyle = "rgba(0, 0, 0, 0.10)"
                for (var k = 0; k < root.laneCount; ++k)
                {
                    var gy = Math.round(first + root.laneStep * k) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(left, gy)
                    ctx.lineTo(right, gy)
                    ctx.stroke()
                }

                // 纵向网格
                for (var v = 0; v < root.vGridX.length; ++v)
                {
                    var vx = Math.round(root.vGridX[v] - root.plotX) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(vx, top)
                    ctx.lineTo(vx, bottom)
                    ctx.stroke()
                }

                // 紫色眼动事件竖线
                ctx.strokeStyle = "#7c3aed"
                for (var e = 0; e < root.eventX.length; ++e)
                {
                    var ex = Math.round(root.eventX[e] - root.plotX) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(ex, top)
                    ctx.lineTo(ex, bottom)
                    ctx.stroke()
                }

                // 通道曲线。振幅按 ±10px 内合成（通道间距只有 25，不能画太满）。
                for (var c = 0; c < root.laneCount; ++c)
                {
                    var center = Math.round(first + root.laneStep * c)
                    ctx.strokeStyle = root.laneColors[c]
                    ctx.beginPath()
                    for (var x = left; x <= right; x += 1.5)
                    {
                        var t = x * 0.045 + c * 1.7
                        var drift = Math.sin(t * 0.9 + c) * 2.2          // 基线慢漂移
                        var rhythm = Math.sin(t * 5.3 + c * 0.7) * 1.8   // α 节律
                        var noise = Math.sin(x * 0.55 + c * 2.2) * 0.9
                        var spike = Math.pow(Math.max(0, Math.sin(t * 0.42 + c * 0.9)), 10) * 5.0
                        var y = center + drift + rhythm + noise - spike
                        if (x === left)
                            ctx.moveTo(x, y)
                        else
                            ctx.lineTo(x, y)
                    }
                    ctx.stroke()
                }
            }
        }

        // ---------- 通道名 ----------
        Repeater {
            model: root.laneCount

            delegate: Text {
                required property int index

                x: 31
                y: 343 + root.laneStep * index
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: root.laneNames[index]
                color: root.laneColors[index]
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }
        }

        // ---------- 事件胶囊（02:16）----------
        Rectangle {
            x: 769
            y: 345
            width: 79
            height: 29
            radius: 12
            color: "#ffffff"
            border.width: 1
            border.color: Design.bad

            Rectangle {
                x: 8
                y: 9
                width: 12
                height: 12
                radius: 6
                color: Design.bad
            }

            Text {
                x: 30
                y: 0
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "02:16"
                color: Design.bad
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }
        }

        // ---------- 眼动标记（两条紫色竖线顶端的标签）----------
        Repeater {
            model: root.eventX

            delegate: Item {
                required property int index

                x: root.eventX[index] - 20    // 40 宽的标签居中在竖线上
                y: 751
                width: 40
                height: 17

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: "#7c3aed"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: -2
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("眼动")
                    color: "#ffffff"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                    font.letterSpacing: -0.27
                }
            }
        }

        // ---------- 时间轴 ----------
        Repeater {
            model: root.timeMarks

            delegate: Text {
                required property var modelData

                x: modelData.x
                y: 756
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: modelData.label
                color: Qt.rgba(0, 0, 0, 0.40)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
                font.letterSpacing: -0.27
            }
        }

        // ---------- 控制条 ----------
        Rectangle {
            x: 24
            y: 791
            width: 842
            height: 60
            color: Qt.rgba(0xd9 / 255, 0xd9 / 255, 0xd9 / 255, 0.20)
        }

        // 回放
        Rectangle {
            x: 39
            y: 804
            width: 82
            height: 34
            radius: 8
            color: replayMouse.pressed ? "#64879f" : Design.primary

            Image {
                x: 17
                y: 23
                width: 12
                height: 11
                rotation: -90
                transformOrigin: Item.TopLeft
                source: Design.assetRoot + "icons/icon-play.svg"
            }

            Text {
                x: 35
                y: 1
                height: 33
                verticalAlignment: Text.AlignVCenter
                text: qsTr("回放")
                color: "#ffffff"
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }

            MouseArea {
                id: replayMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
            }
        }

        // 重置
        Rectangle {
            x: 134
            y: 805
            width: 63
            height: 33
            radius: 8
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("重置")
                color: "#4f4f4f"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
            }
        }

        // 播放进度条
        Rectangle {
            x: 209
            y: 809
            width: 437
            height: 24
            radius: 17
            color: Qt.rgba(0, 0, 0, 0.07)
        }

        // 已播放部分。施工图里这个节点没有导出填充色，按渲染图采样约为主色 55%。
        Rectangle {
            x: 209
            y: 809
            width: 131
            height: 24
            radius: 17
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
        }

        // 播放头
        Rectangle {
            x: 316
            y: 809
            width: 24
            height: 24
            radius: 12
            color: "#59809c"
            border.width: 1
            border.color: "#416a87"
        }

        Rectangle {
            x: 322
            y: 815
            width: 12
            height: 12
            radius: 6
            color: "#416a87"
            border.width: 1
            border.color: "#ffffff"
        }

        Text {
            x: 655
            y: 810
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: root.playbackTime
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
            font.letterSpacing: -0.27
        }

        // 导出 PDF
        Rectangle {
            x: 758
            y: 805
            width: 96
            height: 32
            radius: 10
            color: Design.primarySoft
            border.width: 1
            border.color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.29)

            Text {
                anchors.centerIn: parent
                text: qsTr("导出PDF")
                color: Design.primary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 14
                font.letterSpacing: -0.27
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
            }
        }

        // ---------- 事件条 ----------
        Rectangle {
            x: 24
            y: 867
            width: 842
            height: 74
            radius: 7
            color: Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17)
        }

        Repeater {
            model: root.events

            delegate: Item {
                required property var modelData
                required property int index

                x: modelData.x
                y: 883
                width: 235
                height: 42

                Rectangle {
                    anchors.fill: parent
                    radius: 7
                    color: index === 0 ? Design.primarySoft
                                       : Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.30)
                    border.width: index === 0 ? 1 : 0
                    border.color: Design.primary
                }

                Rectangle {
                    x: 9
                    y: 15
                    width: 12
                    height: 12
                    radius: 6
                    color: "#7c3aed"
                }

                Text {
                    x: 61
                    y: 10
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.time
                    color: "#333333"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 20
                    font.letterSpacing: 0.73
                }

                Text {
                    x: 190
                    y: 10
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.label
                    color: "#3b3b3b"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                    font.letterSpacing: -0.27
                }
            }
        }

        // ---------- 底部横向滚动条 ----------
        Rectangle {
            x: 31
            y: 935
            width: 824
            height: 6
            radius: 3
            color: Qt.rgba(0x7a / 255, 0x7a / 255, 0x7a / 255, 0.10)
        }

        Rectangle {
            x: 105
            y: 935
            width: 321
            height: 6
            radius: 3
            color: Qt.rgba(0x66 / 255, 0x66 / 255, 0x66 / 255, 0.15)
        }
    }
}
