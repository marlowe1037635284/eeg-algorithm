import QtQuick
import KSCEEGClient

// 「实时波形」面板。
// 设计稿里位于画板 (450,150)，尺寸 1109×884；本文件内的坐标都相对面板左上角，
// 换算关系是「设计坐标 - (450,150)」。
//
// 波形数据来自 C++ 的 Acq（AcquisitionBridge）：每列取该列的最小/最大值
// 做包络抽稀，比逐点连线更能反映真实幅度 —— 10 秒时窗下每列要压掉十几个点，
// 只取一个点会把峰削平。
Item {
    id: root

    property bool collecting: false
    property bool frozen: false
    property int channelCount: 16
    property string eventTime: "02:16"

    // 波形绘制区。设计稿里网格线从 (501,227) 起、宽 1037；
    // 通道中心从 242 开始每 106px 一个，正好落在每两条网格线之间。
    //
    // 那是**8 通道**的排法（106 = 770/8 向下取整附近）。设计稿的通道档位选的
    // 却是 16，两者对不上，所以这里按实际通道数算：770/16 得 48px 一条，
    // 首道中心落在半个行高上，保证 16 条泳道均匀铺满且不越界
    readonly property int plotX: 51                 // 501 - 450
    readonly property int plotY: 77                 // 227 - 150
    readonly property int plotWidth: 1037
    readonly property int plotHeight: 770
    readonly property int laneStep: Math.floor(plotHeight / Math.max(1, channelCount))
    readonly property int firstLaneCenter: Math.floor(laneStep / 2)

    // 有新数据且没冻结时才重绘。冻结是「画面停住」而不是「停止采集」，
    // 数据照常进缓冲，解冻后立刻接上
    Connections {
        target: Acq
        function onWaveRevisionChanged() {
            if (!root.frozen)
                plot.requestPaint()
        }
    }
    onFrozenChanged: plot.requestPaint()
    onChannelCountChanged: plot.requestPaint()

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
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 设计稿这里写的就是「16通道·1000HZ」（与设备一致），而底部状态栏写 256Hz ——
    // 两处对不上，按实际采样率显示，取 Acq 的真实值
    Text {
        anchors.right: parent.right
        anchors.rightMargin: 21
        y: 16
        text: root.channelCount + qsTr("通道·") + Acq.sample_rate() + "HZ"
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
            var lanes = Math.max(1, root.channelCount)

            // 横向网格：从第一个通道中心起，每半个通道一条。
            // 条数跟着通道数走，固定成 15 条的话 16 通道时下半屏就没线了
            ctx.strokeStyle = "rgba(0, 0, 0, 0.14)"
            ctx.lineWidth = 1
            for (var k = 0; k <= lanes * 2; ++k) {
                var gy = Math.round(first + (step / 2) * k) + 0.5
                if (gy > h)
                    break
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

            // 事件竖线。原来这里是两条写死坐标的线（紫线 72.5、蓝线 170.5），
            // 与事件面板那份假数据互不相干。现在两处共用 Acq.events：
            // 标记一次事件，列表里多一行、波形上多一条线，位置按采集偏移算。
            //
            // 位置随窗口滑动：采集时刻 t 的事件，在当前窗口里离右端
            // (now - t) 秒；超出窗口就不画
            var now = Acq.elapsed_seconds()
            var windowSeconds = Math.max(0.1, Acq.timeWindow)
            var events = Acq.events
            for (var e = 0; e < events.length; ++e) {
                var event = events[e]
                var age = now - event.offsetSeconds
                if (age < 0 || age > windowSeconds)
                    continue

                var eventX = w * (1 - age / windowSeconds)
                ctx.strokeStyle = event.dotColor
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(Math.round(eventX) + 0.5, 0)
                ctx.lineTo(Math.round(eventX) + 0.5, h - 1)
                ctx.stroke()

                // 线顶端的标签块。宽度按字数估，够用即可 —— 画布上量文字宽度
                // 要额外一次 measureText，而这里只有几个字
                var chipWidth = 15 + event.label.length * 12
                ctx.fillStyle = event.dotColor
                ctx.fillRect(eventX - chipWidth / 2, 2, chipWidth, 17)
                ctx.fillStyle = "#ffffff"
                ctx.font = "12px sans-serif"
                ctx.textAlign = "center"
                ctx.textBaseline = "middle"
                ctx.fillText(event.label, eventX, 11)
            }
            ctx.textAlign = "start"
            ctx.textBaseline = "alphabetic"

            // 各通道波形。数据来自 Acq.lane_samples()：每列依次给出该列的
            // 最小值与最大值，顺次连线就得到包络正确的折线
            var colors = Acq.channelColors
            // 每个通道自己的量程。自动量程下各通道独立算，所以通道之间不能直接比大小
            var maxHalf = step / 2 - 3
            for (var c = 0; c < lanes; ++c) {
                if (!Acq.is_channel_visible(c))
                    continue

                var center = first + step * c
                var half = Math.max(2, maxHalf)
                var scale = half / Math.max(1e-6, Acq.lane_range_uv(c))
                var data = Acq.lane_samples(c, Math.round(w))

                ctx.strokeStyle = colors[c % colors.length]
                ctx.lineWidth = 1
                ctx.beginPath()
                for (var i = 0; i < data.length; ++i) {
                    var x = Math.floor(i / 2)
                    var y = center - data[i] * scale
                    if (i === 0)
                        ctx.moveTo(x, y)
                    else
                        ctx.lineTo(x, y)
                }
                ctx.stroke()
            }
        }
    }

    // ---------- 通道名 ----------
    // 名字与配色都从 Acq 取 —— 通道档位切到 8 时挑的是 Fp1 Fp2 F3 F4 C3 C4 P3 P4
    // 这几个有代表性的位置，而不是简单取前 8 路（那样会得到 Fp1 Fp2 F7 F3 …）
    Repeater {
        model: Acq.channelNames

        delegate: Text {
            required property int index
            required property string modelData
            x: 21
            // 与波形同一个中心：绘制区顶部 + 该通道的中心，文字再上移半行高居中。
            // 不能沿用设计稿写死的 81 + 106*index：那个步长只对 8 通道成立
            y: root.plotY + root.firstLaneCenter + root.laneStep * index - 11
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: modelData
            color: Acq.channelColors[index % Acq.channelColors.length]
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 16
        }
    }

    // ---------- 量程 ----------
    Text {
        x: 1047
        y: 61
        text: Acq.yRangeUV > 0 ? "±" + Acq.yRangeUV + "μV" : qsTr("自动量程")
        color: Qt.rgba(0, 0, 0, 0.4)
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- 事件标签（波形顶部的小色块）----------
    // 原来这里是两个写死的色块（「眼动」紫、「睁眼」蓝），指向两条同样写死的竖线。
    // 现在改成画在 Canvas 里：标签跟着真实事件走，位置随显示窗口滑动，
    // 划出窗口就一起消失。写死的色块做不到这件事
    // （见上面 onPaint 里画事件竖线那一段）

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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }
}
