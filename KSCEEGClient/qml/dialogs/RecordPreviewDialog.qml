import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「采集记录预览」弹窗。按 Figma 设计稿的版式实现。
//
// 设计稿画板 1920×1080，白色卡片位于 (516,61)、尺寸 888×957；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (516,61)，数值照抄施工图。
//
// 数据全部来自真实记录：患者、时间、时长、通道、事件都在库里，
// 波形是**读回那次落盘的原始文件**画出来的（RecordingPreview）。
// 原来这一整屏是假的 —— 患者写死「张文涛」、波形是按正弦函数现编的、
// 回放与导出按钮点了没有任何反应。
Item {
    id: root

    signal dismissed()
    signal exportRequested(string recordNo)

    // 要预览的记录号，弹出前由 Main 回填
    property string recordNo: ""
    // 应用数据库，由外层注入
    property var database

    function reload() {
        const row = database ? database.session(recordNo) : ({})
        detail = row
        events = database ? database.sessionEvents(recordNo) : []

        // 波形读的是这条记录落盘的那个原始文件；没落盘就退到空态说明白
        if (row.filePath !== undefined && row.filePath.length > 0)
            Recording.open(row.filePath)
        else
            Recording.close()
    }

    Component.onCompleted: reload()

    // ---------- 头部信息 ----------
    property var detail: ({})
    property var events: []

    readonly property string patientName:
        Privacy.masked(detail.patient !== undefined ? detail.patient : "")
    readonly property string patientMeta: {
        if (detail.gender === undefined)
            return ""
        return detail.gender + "  " + detail.age + qsTr("岁")
    }
    readonly property string patientRecordNo:
        detail.patientNo !== undefined ? (Privacy.masked(detail.patientNo) + "·" + detail.dept) : ""

    // ---------- 概览信息卡 ----------
    readonly property var infoCards: [
        { x: 25,  y: 141, label: qsTr("采集时间"),      value: detail.time !== undefined ? detail.time : "—" },
        { x: 309, y: 141, label: qsTr("时长"),          value: detail.duration !== undefined ? detail.duration : "—" },
        { x: 594, y: 141, label: qsTr("通道 / 采样率"),
          value: detail.channels !== undefined
                 ? detail.channels + " ch · " + detail.rate + " Hz" : "—" },
        { x: 25,  y: 236, label: qsTr("幅值 / 时基"), value: displayScaleText },
        { x: 309, y: 236, label: qsTr("事件数"),   value: detail.events !== undefined ? String(detail.events) : "0" },
        // 电极贴合是采集时实测的阻抗分档；没扫过阻抗时库里是空串（数据层不写占位），
        // 这里补一个破折号 —— 后处理页那边区分得更细，写的是「未扫描」
        { x: 594, y: 236, label: qsTr("电极贴合"),
          value: detail.quality !== undefined && detail.quality.length > 0 ? detail.quality : "—" }
    ]

    // 「幅值 / 时基」= 这一屏波形现在的显示标尺。幅值取 Recording 那一栏
    // （标尺默认 100 μV，见 recordingpreview.h；0 才是自动量程）；时基是当前
    // 时间窗除以 4，工作台也是这么把时窗换算成 s/div 的
    readonly property string displayScaleText: {
        const amplitude = Recording.yRangeUV > 0
                          ? Recording.yRangeUV + qsTr(" μV") : qsTr("自动")
        return amplitude + " · " + Number((Recording.windowSeconds / 4).toFixed(2))
               + qsTr(" s/div")
    }

    // ---------- 波形几何（均为卡片内坐标）----------
    readonly property int plotX: 24
    readonly property int plotY: 333
    readonly property int plotWidth: 842
    // 绘图区到控制条上沿（791）为止。施工图这一格给的是 518，比实际可用高度
    // 多出 60 —— 照着写的话最下面三路波形会被控制条盖住
    readonly property int plotHeight: 458
    // 通道名占住左边一条，波形从它右边起画。宽度按像素传给 C++，
    // 那边只负责把窗口内的样本铺满给它的这块画布
    readonly property int traceX: 64
    readonly property int traceWidth: root.plotX + root.plotWidth - root.traceX
    // 波形本身到时间轴上方为止（时间轴在 762）。与背景块分开两个高度：
    // 背景要铺到控制条上沿，而波形不能压到时间轴的字上
    readonly property int traceHeight: 762 - root.plotY

    // 回放：把显示窗口按秒推进，速度按每秒 4 格（一屏 5 秒走 1.25 秒）
    property bool playing: false
    readonly property double playbackSeconds: Recording.windowStart
    readonly property double totalSeconds: Math.max(0.01, Recording.durationSeconds)
    // 窗口起点能推进到的最大位置。窗口本身占一屏，回放推到这里就该停 ——
    // 拿总时长当终点的话，进度条会先按比例钉在最右端，波形却还接着走
    readonly property double windowSpan:
        Math.max(0, Recording.durationSeconds - Recording.windowSeconds)

    // 播放进度条几何。设计稿起点是 209，但播放头直径 24、以轨道为中线摆放，
    // 归零时左半边会探出轨道 12 像素，正好贴住「重置」的右缘（197）。
    // 起点右移、宽度相应收窄，右端仍止于 641，不去挤右边的时刻文本
    readonly property int progressX: 225
    readonly property int progressWidth: 416

    // 把某个事件定位到窗口正中。点事件卡片时用
    function seekTo(offsetSeconds) {
        root.playing = false
        Recording.windowStart = Math.max(0, Math.min(windowSpan,
                                                     offsetSeconds - Recording.windowSeconds / 2))
    }

    // 当前落在窗口正中附近的事件（离窗口中心最近的），卡片据此高亮；
    // 点某张卡片把它定位到正中后，高亮就跟着转到那张上
    readonly property int activeEventIndex: {
        const center = Recording.windowStart + Recording.windowSeconds / 2
        let best = -1
        let bestDistance = Infinity
        for (let i = 0; i < events.length; ++i) {
            const distance = Math.abs(events[i].offsetSeconds - center)
            if (distance < bestDistance) {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    Timer {
        interval: 16
        repeat: true
        running: root.playing && Recording.loaded
        onTriggered: {
            const next = Recording.windowStart + 0.05
            if (next >= root.windowSpan) {
                Recording.windowStart = root.windowSpan
                root.playing = false
                return
            }
            Recording.windowStart = next
        }
    }

    // 事件在进度条上的位置（0~1）。超出记录时长的忽略
    function eventProgress(event) {
        if (totalSeconds <= 0)
            return 0
        return Math.max(0, Math.min(1, event.offsetSeconds / totalSeconds))
    }

    DialogFrame {
        title: root.recordNo.length > 0 ? qsTr("采集记录预览 · %1").arg(root.recordNo)
                                        : qsTr("采集记录预览")
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
            text: root.patientName.length > 0 ? root.patientName : qsTr("—")
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
            x: 600
            y: 93
            width: 250
            height: 22
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
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
                    width: parent.width - 36
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideMiddle
                    text: modelData.value
                    color: modelData.good ? Design.good : "#333333"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 16
                    font.letterSpacing: 0.73
                }
            }
        }

        // ---------- 波形区 ----------
        Rectangle {
            x: root.plotX
            y: root.plotY
            width: root.plotWidth
            height: root.plotHeight
            radius: 7
            color: Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17)
        }

        // 每路的泳道基线。用静态网格而不是把网格画进 C++ 那张图里 ——
        // 网格不随窗口变，画进图里等于每帧重画一遍
        Repeater {
            model: Math.max(0, Recording.channelCount)

            delegate: Rectangle {
                required property int index

                readonly property real laneStep:
                    Recording.channelCount > 0 ? root.traceHeight / Recording.channelCount : 0

                x: root.traceX
                y: root.plotY + Math.round(laneStep * index + laneStep / 2)
                width: root.traceWidth
                height: 1
                color: Qt.rgba(0, 0, 0, 0.10)
            }
        }

        // 波形本体：由 C++ 从落盘文件里读出来画好，这里只管贴。
        // revision 变化只是用来制造新 URL，否则 Image 会按 URL 缓存
        Image {
            id: plotImage
            x: root.traceX
            y: root.plotY
            width: root.traceWidth
            height: root.traceHeight
            fillMode: Image.Stretch
            cache: false
            asynchronous: false
            visible: Recording.loaded
            source: "image://recording/render/" + Recording.revision

            function report_size() {
                if (width > 0 && height > 0) {
                    const scale = Math.min(Screen.devicePixelRatio, 1.5)
                    Recording.set_view_size(Math.round(width * scale), Math.round(height * scale))
                }
            }
            onWidthChanged: report_size()
            onHeightChanged: report_size()
            Component.onCompleted: report_size()
        }

        // 空态：没落盘、或文件读不了时把原因写清楚，而不是留一块空白
        Text {
            x: root.plotX
            anchors.verticalCenter: parent.verticalCenter
            width: root.plotWidth
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: !Recording.loaded
            text: Recording.errorText.length > 0
                  ? Recording.errorText
                  : qsTr("这条记录没有落盘原始数据，无法回放波形")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 通道名 ----------
        Repeater {
            model: Recording.channelNames

            delegate: Text {
                required property int index
                required property string modelData

                readonly property real laneStep:
                    Recording.channelCount > 0 ? root.traceHeight / Recording.channelCount : 0

                x: 31
                y: root.plotY + laneStep * index + laneStep / 2 - 8
                height: 16
                verticalAlignment: Text.AlignVCenter
                text: modelData
                color: Recording.channelColors[index % Recording.channelColors.length]
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 12
                font.letterSpacing: -0.27
            }
        }

        // ---------- 事件竖线 ----------
        // 位置来自记录里存下的真实时刻：先换算成「距窗口左端多少秒」，再折算成
        // 横坐标。沿用实时波形那一套 —— 划出窗口的事件跟着消失，
        // 而不是钉在窗口边上（钉住会让人以为那一刻就在画面边缘）
        Repeater {
            model: root.events

            delegate: Item {
                required property var modelData

                readonly property bool inWindow:
                    modelData.offsetSeconds >= Recording.windowStart
                    && modelData.offsetSeconds <= Recording.windowStart + Recording.windowSeconds

                x: root.traceX + root.traceWidth
                   * (modelData.offsetSeconds - Recording.windowStart)
                   / Math.max(0.001, Recording.windowSeconds)
                y: root.plotY
                width: 1
                height: root.traceHeight
                visible: Recording.loaded && inWindow

                Rectangle {
                    width: 1
                    height: parent.height
                    color: modelData.color !== undefined && modelData.color.length > 0
                           ? modelData.color : "#7c3aed"
                }

                // 竖线顶端的标签
                Rectangle {
                    x: -20
                    y: 0
                    width: 40
                    height: 17
                    radius: 6
                    color: modelData.color !== undefined && modelData.color.length > 0
                           ? modelData.color : "#7c3aed"

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: -2
                        height: 22
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.label
                        color: "#ffffff"
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 12
                        font.letterSpacing: -0.27
                    }
                }
            }
        }

        // ---------- 已播放时长胶囊（设计稿波形区右上角的 ● 02:16）----------
        // 采集页那一颗显示的是「本次已采集多久」，这里同理显示「已回放到第几秒」：
        // 读数跟进度条同一套进度，条清零就是 00:00、条走满就是总时长
        Rectangle {
            x: 848 - width
            y: root.plotY + 11
            // 常态是设计稿的 81；读数涨到三位数时按文本撑开，不把数字挤出去
            width: Math.max(81, elapsedLabel.implicitWidth + 38)
            height: 30
            radius: 12
            visible: Recording.loaded
            // 实心底色：波形就画在下面，半透明会把波形透出来糊住读数。
            // 取值 = 波形区那块半透明灰叠在白卡上的合成色，看着仍是一块背景
            color: "#f5f5f5"
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
                id: elapsedLabel
                x: 30
                y: 0
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: root.formatClock(root.playheadRatio * root.totalSeconds)
                color: Design.bad
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }

        // ---------- 时间轴 ----------
        // 设计稿那五个刻度写的是 -6.4/-4.4/-2.4/-0.4/1.6s（角度偏了），
        // 这里按当前窗口的起止与总时长算真实时刻
        Repeater {
            model: 5

            delegate: Text {
                required property int index

                readonly property double markSeconds:
                    Recording.windowStart + Recording.windowSeconds * index / 4

                // 每个刻度居中对齐到自己的位置，但最后一个不能居中 —— 它的中心
                // 就在轨迹右端（866），半个字宽会探出波形区，看着就是「时间超出
                // 显示区域」。设计稿里末刻度也是往内收的（右缘落在 856）
                x: Math.min(root.traceX + root.traceWidth * index / 4 - width / 2,
                            root.traceX + root.traceWidth - 10 - width)
                y: 762
                height: 22
                verticalAlignment: Text.AlignVCenter
                visible: Recording.loaded
                text: root.formatClock(markSeconds)
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

        // 回放 / 暂停
        Rectangle {
            x: 39
            y: 804
            width: 82
            height: 34
            radius: 8
            color: replayMouse.pressed ? "#64879f" : Design.primary
            opacity: Recording.loaded ? 1.0 : 0.45

            // 播放时是两条竖线（暂停符号），停下来是三角形
            Row {
                x: 17
                y: 11
                spacing: 5
                visible: root.playing

                Repeater {
                    model: 2

                    delegate: Rectangle {
                        width: 4
                        height: 12
                        color: "#ffffff"
                    }
                }
            }

            Image {
                x: 17
                y: 11
                width: 12
                height: 12
                rotation: 90
                visible: !root.playing
                source: Design.assetRoot + "icons/icon-play.svg"
            }

            Text {
                x: 35
                y: 1
                height: 33
                verticalAlignment: Text.AlignVCenter
                text: root.playing ? qsTr("暂停") : qsTr("回放")
                color: "#ffffff"
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }

            MouseArea {
                id: replayMouse
                anchors.fill: parent
                enabled: Recording.loaded
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    // 已经推到末尾时再按「回放」要能从头开始，否则一按就被终点判停
                    if (!root.playing && Recording.windowStart >= root.windowSpan - 0.001)
                        Recording.windowStart = 0
                    root.playing = !root.playing
                }
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
            opacity: Recording.loaded ? 1.0 : 0.45

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
                enabled: Recording.loaded
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.playing = false
                    Recording.windowStart = 0
                }
            }
        }

        // 播放进度条
        Rectangle {
            x: root.progressX
            y: 809
            width: root.progressWidth
            height: 24
            radius: 17
            color: Qt.rgba(0, 0, 0, 0.07)
        }

        // 已播放部分。进度按窗口起点在记录里的位置算
        Rectangle {
            x: root.progressX
            y: 809
            width: root.progressWidth * root.playheadRatio
            height: 24
            radius: 17
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
        }

        // 播放头
        Rectangle {
            x: root.progressX + root.progressWidth * root.playheadRatio - 12
            y: 809
            width: 24
            height: 24
            radius: 12
            color: "#59809c"
            border.width: 1
            border.color: "#416a87"

            Rectangle {
                x: 6
                y: 6
                width: 12
                height: 12
                radius: 6
                color: "#416a87"
                border.width: 1
                border.color: "#ffffff"
            }
        }

        Text {
            x: 655
            y: 810
            height: 22
            verticalAlignment: Text.AlignVCenter
            // 读数跟进度条同一套进度：条走满就是总时长，条清零就是 00:00。
            // 用窗口起点当读数的话，条已经贴在最右、数字还停在「总时长减一屏」，
            // 看起来就是「划到头了时间还没到」
            text: root.formatClock(root.playheadRatio * root.totalSeconds)
                  + " / " + root.formatClock(root.totalSeconds)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
            font.letterSpacing: -0.27
        }

        // 导出
        Rectangle {
            x: 758
            y: 805
            width: 96
            height: 32
            radius: 10
            color: exportMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
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
                id: exportMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.exportRequested(root.recordNo)
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

        // 事件卡片横向排开，多了可以滚。原来这里只有两张写死的卡片
        Item {
            id: eventStrip

            x: 24
            y: 867
            width: 842
            height: 74
            clip: true

            property real scroll: 0
            // 卡片宽度按标签文字撑开（见 delegate），所以整条内容宽直接取 Row
            // 的隐式宽度，再加左右各 19 的边距。固定按 246/张算的话，
            // 长标签卡片变宽后滚动条会提前到头，最后几张滑不出来
            readonly property real contentWidth:
                root.events.length > 0 ? 19 + eventRow.implicitWidth + 19 : 0
            readonly property real maxScroll: Math.max(0, contentWidth - width)

            Row {
                id: eventRow
                x: 19 - eventStrip.scroll
                y: 16
                spacing: 11

                Repeater {
                    model: root.events

                    delegate: Item {
                        id: card

                        required property var modelData
                        required property int index

                        // 标签可能很长。卡片按「时刻 + 标签」的实际宽度撑开，
                        // 只保底 235；否则固定宽度会把标签截成「啊手机...」，
                        // 用户没法从事件带上认出标的是什么
                        readonly property real labelX:
                            61 + cardClockMetrics.advanceWidth + 14

                        width: Math.max(235, labelX + cardLabelMetrics.advanceWidth + 12)
                        height: 42

                        TextMetrics {
                            id: cardClockMetrics
                            font.family: Design.fontFamily
                            font.styleName: Design.styleMedium
                            font.pixelSize: 20
                            text: modelData.wallClock
                        }

                        TextMetrics {
                            id: cardLabelMetrics
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 16
                            text: modelData.label
                        }

                        // 定位到窗口正中的那张高亮。原来写死 index === 0，
                        // 点了别的卡片也一直亮第一张，看不出定位到哪儿了
                        readonly property bool active: index === root.activeEventIndex

                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: card.active ? Design.primarySoft
                                               : Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.30)
                            border.width: card.active ? 1 : 0
                            border.color: Design.primary
                        }

                        Rectangle {
                            x: 9
                            y: 15
                            width: 12
                            height: 12
                            radius: 6
                            color: modelData.color !== undefined && modelData.color.length > 0
                                   ? modelData.color : "#7c3aed"
                        }

                        Text {
                            x: 61
                            y: 10
                            height: 22
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.wallClock
                            color: "#333333"
                            font.family: Design.fontFamily
                            font.styleName: Design.styleMedium
                            font.pixelSize: 20
                            font.letterSpacing: 0.73
                        }

                        Text {
                            x: card.labelX
                            y: 10
                            width: parent.width - x - 12
                            height: 22
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.label
                            color: "#3b3b3b"
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 16
                            font.letterSpacing: -0.27
                        }

                        // 点卡片就把这一刻的波形定位到窗口正中，标记随之落到画面中间
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.seekTo(modelData.offsetSeconds)
                        }
                    }
                }
            }

            // 一条都没有时说清楚，而不是留一块空灰底
            Text {
                x: 19
                y: 26
                visible: root.events.length === 0
                text: qsTr("该记录没有事件标注")
                color: Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            // 这个 MouseArea 只为滚轮而存在。必须声明在卡片之后（层级更高）——
            // 滚轮只沿光标下那个节点的父链往上走，光标压在卡片上时收不到；
            // 原来它排在 Row 前面，所以怎么滚都不动。默认它会吞掉按下事件，
            // 这里主动放弃 press（滚轮不走这条路径，onWheel 照常生效）
            MouseArea {
                anchors.fill: parent
                onPressed: (mouse) => { mouse.accepted = false }
                onWheel: (wheel) => {
                    const next = eventStrip.scroll - wheel.angleDelta.y / 3
                    eventStrip.scroll = Math.max(0, Math.min(eventStrip.maxScroll, next))
                }
            }
        }

        // ---------- 底部横向滚动条 ----------
        // 卡片没超一屏（maxScroll = 0）时整条隐藏，不留一根空轨道
        Rectangle {
            x: 31
            y: 935
            width: 824
            height: 6
            radius: 3
            color: Qt.rgba(0x7a / 255, 0x7a / 255, 0x7a / 255, 0.10)
            visible: eventStrip.maxScroll > 0
        }

        Rectangle {
            id: scrollThumb

            // 轨道 824 宽（31~855）。滑块长度按「一屏占内容的比例」定，
            // 起点必须对齐轨道左端 31，scroll = 0 时才不会凭空缩进去一截
            readonly property real thumbWidth:
                eventStrip.maxScroll > 0
                    ? Math.max(48, 824 * eventStrip.width / eventStrip.contentWidth) : 0

            x: 31 + (824 - width)
               * (eventStrip.maxScroll > 0 ? eventStrip.scroll / eventStrip.maxScroll : 0)
            y: 935
            width: thumbWidth
            height: 6
            radius: 3
            color: Qt.rgba(0x66 / 255, 0x66 / 255, 0x66 / 255, 0.15)
            visible: eventStrip.maxScroll > 0
        }

        // 滑块可拖动。原来只有一条画出来的轨道，没有任何鼠标交互 ——
        // 事件卡片多了以后，右边几张只能靠滚轮才滚得出来，滑动条本身怎么拖都不动。
        // 热区比 6px 的轨道高一些，细条不好按
        MouseArea {
            x: 31
            y: 929
            width: 824
            height: 18
            visible: eventStrip.maxScroll > 0
            enabled: eventStrip.maxScroll > 0

            // 按下时鼠标相对滑块左端的位置；点在空白轨道上时取滑块中心，
            // 让滑块中心跳到这里再跟着走
            property real grabOffset: 0

            function apply(mouseX) {
                const travel = 824 - scrollThumb.width
                if (travel <= 0)
                    return
                const ratio = Math.max(0, Math.min(1, (mouseX - grabOffset) / travel))
                eventStrip.scroll = eventStrip.maxScroll * ratio
            }

            onPressed: (mouse) => {
                const thumbLeft = scrollThumb.x - 31
                grabOffset = (mouse.x >= thumbLeft
                              && mouse.x <= thumbLeft + scrollThumb.width)
                             ? mouse.x - thumbLeft
                             : scrollThumb.width / 2
                apply(mouse.x)
            }

            onPositionChanged: (mouse) => {
                if (pressed)
                    apply(mouse.x)
            }
        }
    }

    // 播放头在整条记录里的比例。分母是「窗口起点能走的范围」而不是总时长 ——
    // 窗口本身有宽度，拿窗口右端去比总时长的话，短记录一进界面就刚好贴住
    // 最右端（比例恒为 1），按「重置」把 windowStart 归零也回不到 0。
    // 这个范围就是 windowSpan，回放的终点也以它为准
    readonly property real playheadRatio: {
        if (windowSpan <= 0)
            return 0
        return Math.max(0, Math.min(1, Recording.windowStart / windowSpan))
    }

    // 秒 → "mm:ss"。记录最长可能几十分钟，用时分秒
    function formatClock(seconds) {
        const total = Math.max(0, Math.round(seconds))
        const h = Math.floor(total / 3600)
        const m = Math.floor((total % 3600) / 60)
        const s = total % 60
        if (h > 0)
            return h + ":" + String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0")
        return String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0")
    }
}
