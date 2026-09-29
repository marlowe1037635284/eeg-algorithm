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
        detail.patient !== undefined ? detail.patient : ""
    readonly property string patientMeta: {
        if (detail.gender === undefined)
            return ""
        return detail.gender + "  " + detail.age + qsTr("岁")
    }
    readonly property string patientRecordNo:
        detail.patientNo !== undefined ? (detail.patientNo + "·" + detail.dept) : ""

    // ---------- 概览信息卡 ----------
    // 设计稿第 4 格写的是「幅值 / 时基」，那两个值是**当时界面上的显示设置**，
    // 没有跟着记录存下来（存了也只是抄一份界面状态，不是这次采集的属性）。
    // 换成「原始数据」，显示这次落盘的文件名 —— 这一格本来就该说数据在哪
    readonly property var infoCards: [
        { x: 25,  y: 141, label: qsTr("采集时间"),      value: detail.time !== undefined ? detail.time : "—" },
        { x: 309, y: 141, label: qsTr("时长"),          value: detail.duration !== undefined ? detail.duration : "—" },
        { x: 594, y: 141, label: qsTr("通道 / 采样率"),
          value: detail.channels !== undefined
                 ? detail.channels + " ch · " + detail.rate + " Hz" : "—" },
        { x: 25,  y: 236, label: qsTr("原始数据"), value: rawFileText },
        { x: 309, y: 236, label: qsTr("事件数"),   value: detail.events !== undefined ? String(detail.events) : "0" },
        { x: 594, y: 236, label: qsTr("电极贴合"), value: detail.quality !== undefined ? detail.quality : "—" }
    ]

    readonly property string rawFileText: {
        if (detail.filePath === undefined || detail.filePath.length === 0)
            return qsTr("未落盘")
        const parts = detail.filePath.split(/[\\/]/)
        return parts[parts.length - 1]
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

    Timer {
        interval: 16
        repeat: true
        running: root.playing && Recording.loaded
        onTriggered: {
            const next = Recording.windowStart + 0.05
            if (next >= Math.max(0, Recording.durationSeconds - 0.05)) {
                Recording.windowStart = Math.max(0, Recording.durationSeconds - Recording.windowSeconds)
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

        // 幅值标注。波形会从它底下穿过，所以垫一块半透明白底 ——
        // 不垫的话这行灰字压在彩色曲线上，读不出来
        Rectangle {
            x: 700
            y: root.plotY + 4
            width: 138
            height: 18
            radius: 4
            visible: Recording.loaded
            color: Qt.rgba(1, 1, 1, 0.72)

            Text {
                anchors.centerIn: parent
                text: qsTr("自动量程 · 已去直流")
                color: Qt.rgba(0, 0, 0, 0.45)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
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

                x: root.traceX + root.traceWidth * index / 4 - width / 2
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
                onClicked: root.playing = !root.playing
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
            x: 209
            y: 809
            width: 437
            height: 24
            radius: 17
            color: Qt.rgba(0, 0, 0, 0.07)
        }

        // 已播放部分。进度按「窗口右端走到了总时长的哪里」算 ——
        // 波形显示的是窗口，不是整条记录
        Rectangle {
            x: 209
            y: 809
            width: 437 * root.playheadRatio
            height: 24
            radius: 17
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
        }

        // 播放头
        Rectangle {
            x: 209 + 437 * root.playheadRatio - 12
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
            text: root.formatClock(Recording.windowStart) + " / " + root.formatClock(root.totalSeconds)
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
                text: qsTr("导出")
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
            x: 24
            y: 867
            width: 842
            height: 74
            clip: true

            property real scroll: 0
            readonly property real contentWidth: root.events.length * 246

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: (wheel) => {
                    const next = parent.scroll - wheel.angleDelta.y / 3
                    parent.scroll = Math.max(0, Math.min(Math.max(0, parent.contentWidth - 842), next))
                }
            }

            Row {
                x: 19 - parent.scroll
                y: 16
                spacing: 11

                Repeater {
                    model: root.events

                    delegate: Item {
                        required property var modelData
                        required property int index

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
                            x: 150
                            y: 10
                            width: 78
                            height: 22
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
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
            visible: root.events.length > 3
        }
    }

    // 播放头在整条记录里的比例
    readonly property real playheadRatio: {
        if (totalSeconds <= 0)
            return 0
        const position = Recording.windowStart + Recording.windowSeconds
        return Math.max(0, Math.min(1, position / totalSeconds))
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
