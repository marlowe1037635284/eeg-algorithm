import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「频谱分析」面板。
// 设计稿里位于画板 (1572,754)，尺寸 331×280；本文件坐标 = 设计坐标 - (1572,754)。
Item {
    id: root

    property bool collecting: false
    property bool frozen: false
    property bool channelMenuOpen: false
    // 选中的频段（下面那排数值块），点一下切换
    property int selectedBand: 2

    // 采集时重绘；冻结/停止时画面停住。数据仍在后台更新，
    // 解冻后下一次 revision 变化会立刻接上
    Connections {
        target: Acq
        function onSpectrumRevisionChanged() {
            if (!root.frozen)
                curve.requestPaint()
        }
    }
    onFrozenChanged: curve.requestPaint()

    // 频段数值由 C++ 侧按真实 PSD 算好（固定五项），这边只负责贴。
    // 取不到时显示短横，免得界面上出现 "undefined"
    readonly property var bands: {
        var values = Acq.spectrumBandValues
        var letters = ["δ", "θ", "α", "β", "γ"]
        var labelX = [36, 99, 162, 225, 288]
        var valueX = [23, 82, 149, 212, 275]
        var result = []
        for (var i = 0; i < letters.length; ++i) {
            result.push({
                letter: letters[i],
                value: (values && values.length === 5) ? values[i] : "—",
                labelX: labelX[i],
                valueX: valueX[i]
            })
        }
        return result
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
            text: Acq.spectrumChannel
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
        height: Acq.channelNames.length * 26 + 8
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
                model: Acq.channelNames

                delegate: Rectangle {
                    required property string modelData

                    width: parent.width
                    height: 26
                    radius: 5
                    color: (Acq.spectrumChannel === modelData || channelItemMouse.containsMouse)
                           ? Design.primarySoft : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: Acq.spectrumChannel === modelData ? Design.primary : "#3b3b3b"
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
                            Acq.spectrumChannel = modelData
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

            // 纵向网格
            ctx.strokeStyle = "rgba(0, 0, 0, 0.16)"
            ctx.lineWidth = 1
            for (var g = 25; g < w; g += 42) {
                ctx.beginPath()
                ctx.moveTo(g + 0.5, 0)
                ctx.lineTo(g + 0.5, h - 1)
                ctx.stroke()
            }

            var values = Acq.spectrumCurve
            if (!values || values.length < 2)
                return

            // 曲线已由 C++ 归一化成 0~1（按本帧峰值），这里按画布高度缩放。
            //
            // 注意点数很少：算法侧的 nperseg 固定为 256，1000 Hz 下频率分辨率
            // 是 3.9 Hz，0.5–30 Hz 只有 7 个点 —— 所以这条线本来就是折线，
            // 不是显示做得粗糙，而是分辨率决定的
            var top = 8
            var span = base - top

            ctx.beginPath()
            ctx.moveTo(0, base)
            for (var i = 0; i < values.length; ++i) {
                var x = w * i / (values.length - 1)
                ctx.lineTo(x, base - values[i] * span)
            }
            ctx.lineTo(w, base)
            ctx.closePath()

            // 面积填充（设计稿是自上而下的渐变）
            var grad = ctx.createLinearGradient(0, 0, 0, base)
            grad.addColorStop(0, "rgba(112, 146, 171, 0.55)")
            grad.addColorStop(1, "rgba(112, 146, 171, 0.06)")
            ctx.fillStyle = grad
            ctx.fill()

            // 曲线本身
            ctx.beginPath()
            for (var j = 0; j < values.length; ++j) {
                var xx = w * j / (values.length - 1)
                var y = base - values[j] * span
                if (j === 0)
                    ctx.moveTo(xx, y)
                else
                    ctx.lineTo(xx, y)
            }
            ctx.strokeStyle = Design.primary
            ctx.lineWidth = 2
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
        text: "0.5"
        color: "#898989"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    Text {
        x: 287
        y: 166
        text: "30Hz"
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
