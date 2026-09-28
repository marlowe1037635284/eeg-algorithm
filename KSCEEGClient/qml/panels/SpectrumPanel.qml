import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「频谱分析」面板。
// 设计稿里位于画板 (1572,754)，尺寸 331×280；本文件坐标 = 设计坐标 - (1572,754)。
Item {
    id: root

    property bool collecting: false
    property bool frozen: false
    property real waveformPhase: 0
    property string channelName: "Fp1"
    property bool channelMenuOpen: false
    // 选中的频段（下面那排数值块），点一下切换
    property int selectedBand: 2

    // 通道序号：切换通道时曲线形态也跟着变，不然点了没反馈
    readonly property int channelIndex: Math.max(0, Design.channelNames.indexOf(channelName))

    // 采集时让曲线轻微起伏，冻结/停止时归于静态（形状按设计稿的三个峰）
    readonly property bool live: collecting && !frozen
    onWaveformPhaseChanged: curve.requestPaint()

    // 频段统计，取自设计稿
    readonly property var bands: [
        { letter: "δ", value: "8.4μV²",  labelX: 36,  valueX: 23 },
        { letter: "θ", value: "12.8μV²", labelX: 99,  valueX: 82 },
        { letter: "α", value: "8.4μV²",  labelX: 162, valueX: 149 },
        { letter: "β", value: "8.4μV²",  labelX: 225, valueX: 212 },
        { letter: "γ", value: "8.4μV²",  labelX: 288, valueX: 275 }
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
        y: 8
        text: qsTr("频谱分析")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    Text {
        x: 211
        y: 8
        height: 28
        verticalAlignment: Text.AlignVCenter
        text: qsTr("通道")
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // 通道选择（设计稿是静态样式）
    Rectangle {
        x: 248
        y: 6
        width: 71
        height: 31
        radius: 10
        color: Design.primarySoft

        Text {
            x: 9
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: root.channelName
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Image {
            x: 62
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.channelMenuOpen = !root.channelMenuOpen

            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("切换显示通道")
            ToolTip.delay: 400
        }
    }

    // 通道下拉列表（盖在面板内容之上）
    Rectangle {
        x: 248
        y: 40
        width: 71
        height: Design.channelNames.length * 26 + 8
        radius: 8
        color: "#ffffff"
        border.width: 1
        border.color: Design.panelBorder
        visible: root.channelMenuOpen
        z: 10

        Column {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 0

            Repeater {
                model: Design.channelNames

                delegate: Rectangle {
                    required property string modelData

                    width: parent.width
                    height: 26
                    radius: 5
                    color: (root.channelName === modelData || channelItemMouse.containsMouse)
                           ? Design.primarySoft : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: root.channelName === modelData ? Design.primary : "#3b3b3b"
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 13
                    }

                    MouseArea {
                        id: channelItemMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.channelName = modelData
                            root.channelMenuOpen = false
                            curve.requestPaint()
                        }
                    }
                }
            }
        }
    }

    PanelDivider {
        x: 5
        y: 41
        width: 321
    }

    // ---------- PSD 曲线 ----------
    Rectangle {
        x: 14
        y: 52
        width: 305
        height: 141
        radius: 7
        color: Design.panelFillSoft
        border.width: 1
        border.color: Design.panelBorder
    }

    Canvas {
        id: curve
        x: 14
        y: 56
        width: 305
        height: 133

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width
            var h = height
            var base = h - 26                      // 曲线基线
            var jitter = root.live ? Math.sin(root.waveformPhase * 1.6) * 2.2 : 0

            // 纵向网格
            ctx.strokeStyle = "rgba(0, 0, 0, 0.16)"
            ctx.lineWidth = 1
            for (var g = 25; g < w; g += 42) {
                ctx.beginPath()
                ctx.moveTo(g + 0.5, 0)
                ctx.lineTo(g + 0.5, h - 1)
                ctx.stroke()
            }

            // 三个峰的 PSD 形状（δ / α / β 主峰），与设计稿的曲线走势一致
            // 各通道主峰位置略有差异，切通道时曲线会跟着变
            var shift = (root.channelIndex % 4) * 0.018
            function psd(x) {
                var p1 = 34 * Math.exp(-Math.pow((x - w * (0.22 + shift)) / (w * 0.075), 2))
                var p2 = 52 * Math.exp(-Math.pow((x - w * (0.46 + shift)) / (w * 0.070), 2))
                var p3 = 26 * Math.exp(-Math.pow((x - w * (0.68 + shift)) / (w * 0.095), 2))
                var p4 = 6 * Math.exp(-Math.pow((x - w * 0.92) / (w * 0.070), 2))
                return p1 + p2 + p3 + p4 + jitter
            }

            // 面积填充（设计稿是自上而下的渐变）
            var grad = ctx.createLinearGradient(0, 0, 0, base)
            grad.addColorStop(0, "rgba(112, 146, 171, 0.55)")
            grad.addColorStop(1, "rgba(112, 146, 171, 0.06)")
            ctx.beginPath()
            ctx.moveTo(0, base)
            for (var x = 0; x <= w; x += 2)
                ctx.lineTo(x, base - psd(x))
            ctx.lineTo(w, base)
            ctx.closePath()
            ctx.fillStyle = grad
            ctx.fill()

            // 曲线本身
            ctx.beginPath()
            for (var xx = 0; xx <= w; xx += 2) {
                var y = base - psd(xx)
                if (xx === 0)
                    ctx.moveTo(xx, y)
                else
                    ctx.lineTo(xx, y)
            }
            ctx.strokeStyle = Design.primary
            ctx.lineWidth = 1
            ctx.stroke()
        }
    }

    Text {
        x: 21
        y: 58
        text: qsTr("PSD·dB")
        color: "#898989"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    Text {
        x: 21
        y: 166
        text: "Θ"
        color: "#898989"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    Text {
        x: 287
        y: 166
        text: "50Hz"
        color: "#898989"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- 频段数值 ----------
    Repeater {
        model: root.bands

        delegate: Item {
            required property var modelData
            required property int index

            readonly property bool active: root.selectedBand === index

            Rectangle {
                x: 14 + 63 * index
                y: 206
                width: 54
                height: 60
                radius: 7
                color: parent.active ? Design.primarySoft : Design.panelFillSoft
                border.width: parent.active ? 1 : 0
                border.color: Design.primary
            }

            Text {
                x: modelData.labelX
                y: 215
                width: 20
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.letter
                color: Design.primary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 16
            }

            Text {
                x: modelData.valueX
                y: 236
                width: 44
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.value
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 14
            }

            MouseArea {
                x: 14 + 63 * index
                y: 206
                width: 54
                height: 60
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectedBand = index

                ToolTip.visible: containsMouse
                ToolTip.text: qsTr("查看 %1 频段").arg(modelData.letter)
                ToolTip.delay: 400
            }
        }
    }
}
