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
        var result = []
        for (var i = 0; i < letters.length; ++i) {
            result.push({
                letter: letters[i],
                value: (values && values.length === 5) ? values[i] : "—"
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
    //
    // 面板总共就 280 高、列表从 y=40 起，而 16 个通道按每项 26 撑开要 424px，
    // 会一路画到窗口外，尾部通道根本点不到。所以这里限高（最多到面板底边
    // 留 8px）并在内部滚动：内容没超时和以前完全一样，超了就能滚。
    Rectangle {
        id: channelMenu

        x: 248
        y: 40
        width: 71
        height: Math.min(contentHeight, 232)
        radius: 8
        color: "#ffffff"
        border.width: 1
        border.color: Design.panelBorder
        visible: root.channelMenuOpen
        clip: true
        z: 10

        readonly property int contentHeight: Acq.channelNames.length * 26 + 8
        readonly property int maxScroll: Math.max(0, contentHeight - height)
        property int scroll: 0

        // 每次重新展开都回到顶部
        onVisibleChanged: if (visible) scroll = 0

        Column {
            x: 4
            y: 4 - channelMenu.scroll
            width: channelMenu.width - 8
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

        // 这个 MouseArea 只为滚轮而存在，声明在列表之后、层级更高。
        // 默认它会吞掉按下事件，所以主动放弃 press（滚轮不走这条路径，
        // onWheel 照常生效），点击才能落到下面各通道上
        MouseArea {
            anchors.fill: parent
            onPressed: (mouse) => { mouse.accepted = false }
            onWheel: (wheel) => {
                var step = wheel.angleDelta.y > 0 ? -26 : 26
                channelMenu.scroll = Math.max(0, Math.min(channelMenu.maxScroll,
                                                          channelMenu.scroll + step))
            }
        }

        // ---------- 滚动条 ----------
        // 内容没超（maxScroll = 0）时整条隐藏，不留一根空轨道
        Rectangle {
            x: channelMenu.width - 7
            y: 4
            width: 3
            height: channelMenu.height - 8
            radius: 1.5
            color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
            visible: channelMenu.maxScroll > 0
        }

        Rectangle {
            x: channelMenu.width - 7
            width: 3
            height: channelMenu.maxScroll > 0
                    ? Math.max(24, (channelMenu.height - 8) * channelMenu.height / channelMenu.contentHeight)
                    : 0
            radius: 1.5
            color: Qt.rgba(0.478, 0.478, 0.478, 0.35)
            visible: channelMenu.maxScroll > 0
            y: 4 + (channelMenu.height - 8 - height) * channelMenu.scroll / channelMenu.maxScroll
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

    // ---------- 频段数值（只展示，不可点选） ----------
    Repeater {
        model: root.bands

        delegate: Item {
            required property var modelData
            required property int index

            readonly property int blockX: 14 + 63 * index

            Rectangle {
                x: parent.blockX
                y: 206
                width: 54
                height: 60
                radius: 7
                color: Design.panelFillSoft
            }

            Text {
                x: parent.blockX
                y: 215
                width: 54
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.letter
                color: Design.primary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 15
            }

            Text {
                x: parent.blockX
                y: 236
                width: 54
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.value
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 13
                // 值形如 "368.8μV²"，块宽固定 54，缩到放得下为止，免得溢出
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 8
            }
        }
    }
}
