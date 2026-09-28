import QtQuick

// 「实时波形」面板。
// 设计稿里位于画板 (450,150)，尺寸 1109×884；本文件内的坐标都相对面板左上角，
// 换算关系是「设计坐标 - (450,150)」。
Item {
    id: root

    property bool collecting: false
    property bool frozen: false
    property real waveformPhase: 0
    property string eventTime: "02:16"

    // 波形绘制区。设计稿里网格线从 (501,227) 起、宽 1037；
    // 通道中心从 242 开始每 106px 一个，正好落在每两条网格线之间。
    readonly property int plotX: 51                 // 501 - 450
    readonly property int plotY: 77                 // 227 - 150
    readonly property int plotWidth: 1037
    readonly property int plotHeight: 770
    readonly property int laneStep: 106             // 相邻通道中心间距
    readonly property int firstLaneCenter: 15       // 第一个通道中心，相对绘制区顶部

    // 相位变化时重绘（动画由 WorkbenchPage 的定时器推进）
    onWaveformPhaseChanged: plot.requestPaint()

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    // ---------- 标题栏 ----------
    Text {
        x: 21
        y: 13
        text: qsTr("实时波形")
        color: Design.textPrimary
        font.family: Design.fontRegular
        font.pixelSize: 18
    }

    // 设计稿这里写的是「16通道·1000HZ」，但同页底部状态栏和其它画板都是 256Hz，
    // 按语义统一成 256Hz。
    Text {
        anchors.right: parent.right
        anchors.rightMargin: 21
        y: 16
        text: qsTr("16通道·256HZ")
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 16
    }

    PanelDivider {
        x: 0
        y: 49
        width: 1107
        strong: true
    }

    // ---------- 事件胶囊（设计稿右上角的 02:16）----------
    Rectangle {
        x: 105
        y: 11
        width: 79
        height: 29
        radius: 12
        color: "transparent"
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
            text: root.eventTime
            color: Design.bad
            font.family: Design.fontRegular
            font.pixelSize: 16
        }
    }

    // ---------- 波形绘制区 ----------
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
            var w = width
            var h = height
            var step = root.laneStep
            var first = root.firstLaneCenter

            // 横向网格：从第一个通道中心起，每半个通道一条
            ctx.strokeStyle = "rgba(0, 0, 0, 0.14)"
            ctx.lineWidth = 1
            for (var k = 0; k <= 14; ++k) {
                var gy = Math.round(first + 53 * k) + 0.5
                ctx.beginPath()
                ctx.moveTo(0, gy)
                ctx.lineTo(w, gy)
                ctx.stroke()
            }

            // 纵向网格：设计稿里只有三条
            var vlines = [186, 470, 743]
            for (var v = 0; v < vlines.length; ++v) {
                ctx.beginPath()
                ctx.moveTo(vlines[v] + 0.5, 0)
                ctx.lineTo(vlines[v] + 0.5, h - 1)
                ctx.stroke()
            }

            // 事件竖线：紫线是眼动事件，蓝线是睁眼事件
            ctx.strokeStyle = "#7c3aed"
            ctx.beginPath()
            ctx.moveTo(72.5, 0)
            ctx.lineTo(72.5, h - 1)
            ctx.stroke()

            ctx.strokeStyle = Design.primary
            ctx.beginPath()
            ctx.moveTo(170.5, 0)
            ctx.lineTo(170.5, h - 1)
            ctx.stroke()

            // 8 条通道波形。振幅控制在设计稿给的 ±10px 内。
            for (var c = 0; c < Design.channelNames.length; ++c) {
                var center = first + step * c
                var phase = root.waveformPhase + c * 1.7
                ctx.strokeStyle = Design.channelColors[c]
                ctx.lineWidth = 1
                ctx.beginPath()
                for (var x = 0; x <= w; x += 2) {
                    var t = x * 0.045 + phase
                    var burst = Math.sin(t * 2.8 + c * 0.7) * 5.0
                    var alpha = Math.sin(t * 0.82 + c) * 3.2
                    var spike = Math.pow(Math.max(0, Math.sin(t * 0.23 + c * 0.42)), 14) * (c % 3 === 0 ? 12 : 6)
                    var noise = Math.sin(x * 0.39 + c * 2.2) * 1.6
                    var y = center + burst + alpha + noise - spike
                    if (x === 0)
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
        model: Design.channelNames

        delegate: Text {
            required property int index
            required property string modelData
            x: 21
            y: 81 + 106 * index
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: modelData
            color: Design.channelColors[index]
            font.family: Design.fontMedium
            font.pixelSize: 16
        }
    }

    // ---------- 量程 ----------
    Text {
        x: 1047
        y: 61
        text: qsTr("±100μV")
        color: Qt.rgba(0, 0, 0, 0.4)
        font.family: Design.fontRegular
        font.pixelSize: 12
    }

    // ---------- 事件标签（波形顶部的小色块）----------
    Rectangle {
        x: 103
        y: 55
        width: 40
        height: 17
        radius: 6
        color: "#7c3aed"

        Text {
            anchors.centerIn: parent
            text: qsTr("眼动")
            color: "#ffffff"
            font.family: Design.fontRegular
            font.pixelSize: 12
        }
    }

    Rectangle {
        x: 201
        y: 55
        width: 40
        height: 17
        radius: 6
        color: Design.primary

        Text {
            anchors.centerIn: parent
            text: qsTr("睁眼")
            color: "#ffffff"
            font.family: Design.fontRegular
            font.pixelSize: 12
        }
    }

    // ---------- 时间轴 ----------
    Repeater {
        model: [
            { label: "-8s", offset: 43 },
            { label: "-8s", offset: 228 },
            { label: "-6s", offset: 512 },
            { label: "-2s", offset: 785 },
            { label: "0s", offset: 1081 }
        ]

        delegate: Text {
            required property var modelData
            x: modelData.offset
            y: 851
            text: modelData.label
            color: Qt.rgba(0, 0, 0, 0.4)
            font.family: Design.fontRegular
            font.pixelSize: 12
        }
    }
}
