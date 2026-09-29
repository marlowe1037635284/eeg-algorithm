import QtQuick
import KSCEEGClient

// 「实时波形」面板。
// 设计稿里位于画板 (450,150)，尺寸 1109×884；本文件内的坐标都相对面板左上角，
// 换算关系是「设计坐标 - (450,150)」。
//
// 波形本体由 C++ 画（AcquisitionBridge::render_wave_image），这里只留静态文字：
// 通道名、量程标注、时间轴刻度、事件胶囊。绘制搬到 C++ 的原因见下面绘制区那段注释。
Item {
    id: root

    property bool collecting: false
    property bool frozen: false
    property int channelCount: 16

    // 顶部的事件胶囊显示最近一条事件的墙钟时刻。原来这里是写死的「02:16」，
    // 与事件面板那份假数据同源；现在两个面板共用 Acq.events，
    // 没有事件时整个胶囊收起来，而不是挂一个不存在的时刻
    readonly property var latestEvent: Acq.eventCount > 0
                                       ? Acq.events[Acq.eventCount - 1] : null

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

    // 冻结时把当前这一帧钉住（见下面 Image 的 source 绑定）
    onFrozenChanged: {
        if (frozen)
            waveImage.frozenRevision = Acq.waveRevision
    }

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
        visible: root.latestEvent !== null
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
            text: root.latestEvent !== null ? root.latestEvent.wallClock : ""
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }

    // ---------- 波形绘制区 ----------
    //
    // 图由 C++ 画好（onPaint 那套逻辑整体搬到了 AcquisitionBridge::render_wave_image），
    // 这里只管贴。
    //
    // 为什么搬走：留在 Canvas 里画时实测一帧 76~120 ms —— 其中约 104 ms 花在
    // Canvas 上（16 路 × 每列两个点共三万个 lineTo，走 JS 侧的软件光栅化），
    // 另约 14 ms 花在把三万个 QVariant 跨线程搬进 JS 数组。GUI 线程因此只能跑到
    // 十几帧，表现就是波形一卡一卡。同样的内容用 QPainter 画是毫秒级 ——
    // 参考实现（pybindwithqt）正是这么做的，也正因如此它才顺。
    //
    // 通道名、量程标注、时间轴刻度仍然留在 QML：它们是静态文字，不随每帧变化，
    // 画进图里反而每帧都要重排一遍字
    Image {
        id: waveImage
        x: root.plotX
        y: root.plotY
        width: root.plotWidth
        height: root.plotHeight

        // 图像由 C++ 按这里的像素尺寸绘制，Stretch 就是 1:1 贴上
        fillMode: Image.Stretch
        // cache: false 是必须的：每来一帧就是一个新 URL，
        // 不关缓存会为每个 revision 攒下一份纹理
        cache: false
        asynchronous: false

        // 冻结时停在当前这一帧：冻结是「画面停住」而不是「停止采集」，
        // 数据照常进缓冲，解冻后立刻接上。
        // frozenRevision 由 root 的 onFrozenChanged 写入 —— frozen 是 root 的属性，
        // 信号处理器必须声明在拥有该属性的对象上
        property int frozenRevision: 0
        source: "image://waveform/wave/" + (root.frozen ? frozenRevision : Acq.waveRevision)

        // 按物理像素画：波形是 1 像素宽的折线，若按逻辑像素画再被系统放大，
        // 线条会发虚、细节糊掉。C++ 侧照这个尺寸出图，贴回来时正好是 1:1
        function report_size() {
            if (width > 0 && height > 0) {
                // 200% 显示缩放下像素数是 4 倍，每帧的绘制与纹理上传会吃掉
                // 大量 CPU 与显存带宽。封顶 1.5 倍
                var scale = Math.min(Screen.devicePixelRatio, 1.5)
                Acq.set_wave_view_size(Math.round(width * scale), Math.round(height * scale))
            }
        }
        onWidthChanged: report_size()
        onHeightChanged: report_size()
        Component.onCompleted: report_size()
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
        // 单位与工具栏那格保持一致（μV/div）。原来写「±100μV」，
        // 同一个量程在两处显示成两种单位，看着像两个参数
        text: Acq.yRangeUV > 0 ? Acq.yRangeUV + "μV/div" : qsTr("自动量程")
        color: Qt.rgba(0, 0, 0, 0.4)
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- 事件标签（波形顶部的小色块）----------
    // 事件竖线与它顶端的标签现在由 C++ 画进波形图里（见 render_wave_image）：
    // 位置随显示窗口滑动，划出窗口就一起消失。原来这里有两个写死的色块
    //（「眼动」紫、「睁眼」蓝），指向两条同样写死的竖线，与真实事件无关

    // ---------- 时间轴 ----------
    // 设计稿那五个刻度写的是「-8s / -8s / -6s / -2s / 0s」—— 既有重复也对不上
    // 默认的 2 秒时窗（看着像从别的画板抄过来的）。这里按当前时窗均分生成，
    // 位置也按绘制区宽度算，切时窗时刻度跟着变
    Repeater {
        model: 5

        delegate: Text {
            required property int index

            readonly property real seconds: -Acq.timeWindow * (1 - index / 4)

            x: root.plotX + root.plotWidth * index / 4 - width / 2
            y: 851
            text: index === 4 ? "0s" : seconds.toFixed(1) + "s"
            color: Qt.rgba(0, 0, 0, 0.4)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }
}
