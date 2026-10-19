import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「脑电检查报告」弹窗。按 Figma 设计稿的版式实现。
//
// 设计稿画板 1920×1080：外层白卡位于 (645,62)、尺寸 630×956；
// 卡内坐标 = 设计稿绝对坐标 - (645,62)，本文件照抄施工图数值。
// 白卡里还有一层「报告纸张」内卡 (9,79)、612×866，正文都排在这一层上。
//
// 数据用的都是这条记录在库里的真实值（患者、时间、时长、通道、采样率），
// 波形读回那次落盘的原始文件，与「采集记录预览」同一套 Recording 接口。
Item {
    id: root

    signal dismissed()
    signal exportRequested(string recordNo)

    // 要出报告的记录号，弹出前由 Main 回填
    property string recordNo: ""
    // 应用数据库，由外层注入
    property var database

    function reload() {
        const row = database ? database.session(recordNo) : ({})
        detail = row

        // 波形读的是这条记录落盘的那个原始文件；没落盘就退到空态说明白
        if (row.filePath !== undefined && row.filePath.length > 0)
            Recording.open(row.filePath)
        else
            Recording.close()
    }

    Component.onCompleted: reload()

    property var detail: ({})

    // ---------- 报告取数 ----------
    // 报告编号直接用记录号（如 R-0001）
    readonly property string reportNo:
        detail.no !== undefined && detail.no.length > 0 ? detail.no : "—"

    // 医院名走系统设置；没配过就显示空
    readonly property string hospitalName: {
        if (!database)
            return ""
        const name = database.setting("hospital_name", "")
        if (name === undefined || name === null)
            return ""
        return String(name)
    }

    readonly property string patientName:
        Privacy.masked(detail.patient !== undefined ? detail.patient : "—")
    readonly property string patientGender:
        detail.gender !== undefined && detail.gender.length > 0 ? detail.gender : "—"
    readonly property string patientAge:
        detail.age !== undefined ? String(detail.age) + qsTr("岁") : "—"
    readonly property string patientId:
        Privacy.masked(detail.patientNo !== undefined ? detail.patientNo : "—")
    readonly property string collectDate: {
        const stamp = detail.time !== undefined ? detail.time : ""
        return stamp.length > 0 ? stamp.split(" ")[0] : "—"
    }

    // 参数摘要：采集时长按秒数换算成「约 N 分钟」，通道配置与采样率带上单位
    readonly property string durationText: {
        if (detail.duration === undefined)
            return "—"
        const minutes = detail.durationSeconds !== undefined
                        ? Number((detail.durationSeconds / 60).toFixed(1)) : 0
        return detail.duration + qsTr("(约%1分钟)").arg(minutes)
    }
    readonly property string channelText:
        detail.channels !== undefined
        ? qsTr("%1通道(10-20系统)").arg(detail.channels) : "—"
    readonly property string rateText:
        detail.rate !== undefined ? String(detail.rate) + qsTr("HZ") : "—"

    // ---------- 回放 ----------
    property bool playing: false
    readonly property double totalSeconds: Math.max(0.01, Recording.durationSeconds)
    // 窗口起点能推进到的最大位置：窗口本身占一屏，推到这儿就该停
    readonly property double windowSpan:
        Math.max(0, Recording.durationSeconds - Recording.windowSeconds)
    readonly property real playheadRatio: {
        if (windowSpan <= 0)
            return 0
        return Math.max(0, Math.min(1, Recording.windowStart / windowSpan))
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

    // ---------- 报告里的两个小零件 ----------

    // 小节标题：「▎标题」
    component SectionTitle: Item {
        id: section
        property string text: ""

        implicitWidth: accent.width + 8 + titleText.implicitWidth
        implicitHeight: 22

        Rectangle {
            id: accent
            x: 0
            y: 1
            width: 5
            height: 20
            radius: 2
            color: Design.primary
        }

        Text {
            id: titleText
            x: 13
            y: 0
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: section.text
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 16
        }
    }

    // 点状分隔线。设计稿里报告正文靠它分段，工程里没有现成的点线组件，
    // 用一排小圆点铺出来（宽度由调用方给定，点数按宽度算）
    component DottedLine: Item {
        id: line
        property color lineColor: "#bdbdbd"
        property real dotSize: 2
        property real dotGap: 4

        implicitHeight: dotSize
        height: dotSize

        Repeater {
            model: Math.max(1, Math.floor(line.width / (line.dotSize + line.dotGap)))

            delegate: Rectangle {
                required property int index

                x: index * (line.dotSize + line.dotGap)
                y: 0
                width: line.dotSize
                height: line.dotSize
                radius: line.dotSize / 2
                color: line.lineColor
            }
        }
    }

    // 报告顶部信息行里的一格：「标签：值」。标签用灰、值用深色，
    // 两者错开的距离设计稿里两行不一样，交给调用方给
    component InfoCell: Item {
        id: cell
        property string label: ""
        property string value: ""
        property real valueOffset: 45

        implicitHeight: 18

        Text {
            x: 0
            y: 0
            height: cell.height
            verticalAlignment: Text.AlignVCenter
            text: cell.label
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Text {
            x: cell.valueOffset
            y: 0
            height: cell.height
            verticalAlignment: Text.AlignVCenter
            text: cell.value
            color: "#333333"
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 14
        }
    }

    DialogFrame {
        title: qsTr("脑电检查报告")
        cardX: 645
        cardY: 62
        cardWidth: 630
        cardHeight: 956
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        // ---------- 标题右侧的「导出PDF」 ----------
        Rectangle {
            x: 192
            y: 20
            width: 94
            height: 34
            radius: 10
            color: headerExportMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22)
                                             : Design.primarySoft
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
                id: headerExportMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.exportRequested(root.recordNo)
            }
        }

        // ---------- 报告纸张 ----------
        Rectangle {
            x: 9
            y: 79
            width: 612
            height: 866
            radius: 6
            color: "#ffffff"
            border.width: 1
            border.color: "#8e9ea8"
        }

        // ---------- 报告编号（右上） ----------
        Text {
            x: 382
            y: 88
            width: 200
            height: 16
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: qsTr("报告编号：%1").arg(root.reportNo)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
            font.letterSpacing: -0.27
        }

        // ---------- 医院名 / 报告标题 ----------
        Text {
            id: hospitalText
            x: 48
            y: 110
            width: 534
            height: 26
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: root.hospitalName
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 20
            font.letterSpacing: 0.73
        }

        Text {
            id: reportTitleText
            x: 48
            y: 144
            width: 534
            height: 30
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("脑电检查报告")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 24
        }

        DottedLine {
            x: 48
            y: 191
            width: 534
        }

        // ---------- 患者信息两行 ----------
        InfoCell {
            x: 49
            y: 203
            label: qsTr("姓名：")
            value: root.patientName
        }
        InfoCell {
            x: 247
            y: 203
            label: qsTr("性别：")
            value: root.patientGender
        }
        InfoCell {
            x: 431
            y: 203
            label: qsTr("年龄：")
            value: root.patientAge
        }

        InfoCell {
            x: 49
            y: 234
            label: qsTr("患者ID：")
            value: root.patientId
            valueOffset: 60
        }
        InfoCell {
            x: 247
            y: 234
            label: qsTr("病历号：")
            value: root.patientId
            valueOffset: 60
        }
        InfoCell {
            x: 431
            y: 234
            label: qsTr("采集日期：")
            value: root.collectDate
            valueOffset: 60
        }

        // ---------- 参数摘要 ----------
        SectionTitle {
            x: 48
            y: 267
            text: qsTr("参数摘要")
        }

        // 表格：4 列 × 2 行，浅灰底 + 灰分隔线
        // 列边界（表内坐标）0 | 87 | 262 | 348 | 534，文字左右各留 18 的边距
        Item {
            id: summaryTable

            x: 48
            y: 299
            width: 534
            height: 72

            // 行高 / 列内边距
            readonly property real rowHeight: 36
            readonly property real padX: 18

            // 每格的内容：label 为真表示这一格是标题（灰），否则是值（深）
            readonly property var cells: [
                { col: 0, row: 0, label: true,  text: qsTr("采集时间") },
                { col: 1, row: 0, label: false, text: root.detail.time !== undefined ? root.detail.time : "—" },
                { col: 2, row: 0, label: true,  text: qsTr("采集时长") },
                { col: 3, row: 0, label: false, text: root.durationText },
                { col: 0, row: 1, label: true,  text: qsTr("通道配置") },
                { col: 1, row: 1, label: false, text: root.channelText },
                { col: 2, row: 1, label: true,  text: qsTr("采样率") },
                { col: 3, row: 1, label: false, text: root.rateText }
            ]

            // 每列的起点（表内坐标）
            readonly property var columnX: [0, 87, 262, 348, 534]

            Rectangle {
                anchors.fill: parent
                color: "#f5f5f5"
            }

            // 行分隔
            Rectangle {
                x: 0
                y: summaryTable.rowHeight
                width: parent.width
                height: 1
                color: "#dcdcdc"
            }

            // 列分隔
            Repeater {
                model: summaryTable.columnX.slice(1, 4)

                delegate: Rectangle {
                    required property int modelData

                    x: modelData
                    y: 0
                    width: 1
                    height: summaryTable.height
                    color: "#dcdcdc"
                }
            }

            Repeater {
                model: summaryTable.cells

                delegate: Text {
                    required property var modelData

                    x: summaryTable.columnX[modelData.col] + summaryTable.padX
                    y: modelData.row * summaryTable.rowHeight
                    width: summaryTable.columnX[modelData.col + 1]
                           - summaryTable.columnX[modelData.col]
                           - summaryTable.padX * 2
                    height: summaryTable.rowHeight
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: modelData.text
                    color: modelData.label ? Design.textSecondary : "#333333"
                    font.family: Design.fontFamily
                    font.styleName: modelData.label ? Design.styleRegular : Design.styleMedium
                    font.pixelSize: 12
                    font.letterSpacing: -0.27
                }
            }
        }

        SectionTitle {
            x: 48
            y: 384
            text: qsTr("实时波形截图")
        }

        // 「编辑」：设计稿里是浅蓝灰的圆角胶囊。本轮只做样式与点击态
        // 位置调整：放在标题右侧，与标题保持间距
        Rectangle {
            x: 170
            y: 383
            width: 67
            height: 28
            radius: 6
            color: editMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.26)
                                     : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.14)
            border.width: 1
            border.color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.29)

            Text {
                anchors.centerIn: parent
                text: qsTr("编辑")
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
                font.letterSpacing: -0.27
            }

            MouseArea {
                id: editMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
            }
        }

        // ---------- 波形面板 ----------
        // 面板内统一用「面板相对坐标」，原点在面板左上角：
        // 左侧一条通道名列（宽 58），右边是轨迹区，底部依次是时间轴与控制条
        Item {
            id: wavePanel

            x: 48
            y: 418
            width: 534
            height: 388

            readonly property real nameX: 15
            readonly property real traceX: 58
            readonly property real traceTop: 8
            readonly property real traceBottom: 318
            readonly property real traceHeight: traceBottom - traceTop
            readonly property real traceWidth: width - traceX

            Rectangle {
                anchors.fill: parent
                color: "#f5f5f5"
            }

            // 通道名列与轨迹列之间的竖分隔线
            Rectangle {
                x: wavePanel.traceX
                y: 0
                width: 1
                height: wavePanel.traceBottom
                color: Qt.rgba(0, 0, 0, 0.08)
            }

            // 每路的泳道基线
            Repeater {
                model: Math.max(0, Recording.channelCount)

                delegate: Rectangle {
                    required property int index

                    readonly property real laneStep:
                        Recording.channelCount > 0
                        ? wavePanel.traceHeight / Recording.channelCount : 0

                    x: wavePanel.traceX
                    y: wavePanel.traceTop + Math.round(laneStep * index + laneStep / 2)
                    width: wavePanel.traceWidth
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.08)
                }
            }

            // 波形本体：由 C++ 从落盘文件里读出来画好，这里只管贴
            Image {
                id: plotImage

                x: wavePanel.traceX
                y: wavePanel.traceTop
                width: wavePanel.traceWidth
                height: wavePanel.traceHeight
                fillMode: Image.Stretch
                cache: false
                asynchronous: false
                visible: Recording.loaded
                source: "image://recording/render/" + Recording.revision

                function report_size() {
                    if (width > 0 && height > 0) {
                        const scale = Math.min(Screen.devicePixelRatio, 1.5)
                        Recording.set_view_size(Math.round(width * scale),
                                                Math.round(height * scale))
                    }
                }
                onWidthChanged: report_size()
                onHeightChanged: report_size()
                Component.onCompleted: report_size()
            }

            // 空态：没落盘、或文件读不了时把原因写清楚
            Text {
                x: wavePanel.traceX
                y: wavePanel.traceTop
                width: wavePanel.traceWidth
                height: wavePanel.traceHeight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
                visible: !Recording.loaded
                text: Recording.errorText.length > 0
                      ? Recording.errorText
                      : qsTr("这条记录没有落盘原始数据，无法回放波形")
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
            }

            // 通道名
            Repeater {
                model: Recording.channelNames

                delegate: Text {
                    required property int index
                    required property string modelData

                    readonly property real laneStep:
                        Recording.channelCount > 0
                        ? wavePanel.traceHeight / Recording.channelCount : 0

                    x: wavePanel.nameX
                    y: wavePanel.traceTop + laneStep * index + laneStep / 2 - 6
                    height: 12
                    verticalAlignment: Text.AlignVCenter
                    text: modelData
                    color: Recording.channelColors[index % Recording.channelColors.length]
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 10
                }
            }

            // 事件竖线：位置来自记录里存下的真实时刻
            Repeater {
                model: root.events

                delegate: Item {
                    required property var modelData

                    readonly property bool inWindow:
                        modelData.offsetSeconds >= Recording.windowStart
                        && modelData.offsetSeconds <= Recording.windowStart + Recording.windowSeconds

                    x: wavePanel.traceX + wavePanel.traceWidth
                       * (modelData.offsetSeconds - Recording.windowStart)
                       / Math.max(0.001, Recording.windowSeconds)
                    y: wavePanel.traceTop
                    width: 1
                    height: wavePanel.traceHeight
                    visible: Recording.loaded && inWindow

                    Rectangle {
                        width: 1
                        height: parent.height
                        color: modelData.color !== undefined && modelData.color.length > 0
                               ? modelData.color : "#7c3aed"
                    }

                    // 竖线底端的事件名标签，落在时间轴这一带上
                    Rectangle {
                        x: -18
                        y: parent.height - 17
                        width: 36
                        height: 15
                        radius: 6
                        color: modelData.color !== undefined && modelData.color.length > 0
                               ? modelData.color : "#7c3aed"

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: "#ffffff"
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 10
                        }
                    }
                }
            }

            // 右上角「● 已回放到第几秒」胶囊
            Rectangle {
                x: wavePanel.width - 8 - width
                y: wavePanel.traceTop
                width: Math.max(58, elapsedLabel.implicitWidth + 34)
                height: 25
                radius: 12
                visible: Recording.loaded
                color: "#ffffff"
                border.width: 1
                border.color: Design.bad

                Rectangle {
                    x: 8
                    y: 8
                    width: 9
                    height: 9
                    radius: 4.5
                    color: Design.bad
                }

                Text {
                    id: elapsedLabel
                    x: 22
                    y: 0
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: root.formatClock(root.playheadRatio * root.totalSeconds)
                    color: Design.bad
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 11
                }
            }

            // 时间轴刻度
            Repeater {
                model: 5

                delegate: Text {
                    required property int index

                    readonly property double markSeconds:
                        Recording.windowStart + Recording.windowSeconds * index / 4

                    x: Math.min(wavePanel.traceX + wavePanel.traceWidth * index / 4 - width / 2,
                                wavePanel.traceX + wavePanel.traceWidth - 8 - width)
                    y: 328
                    height: 14
                    verticalAlignment: Text.AlignVCenter
                    visible: Recording.loaded
                    text: root.formatClock(markSeconds)
                    color: Qt.rgba(0, 0, 0, 0.40)
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 10
                }
            }

            // ---------- 控制条 ----------
            Rectangle {
                x: 0
                y: 347
                width: wavePanel.width
                height: 34
                color: Qt.rgba(0, 0, 0, 0.04)
            }

            // 回放 / 暂停
            Rectangle {
                x: 6
                y: 350
                width: 70
                height: 28
                radius: 6
                color: replayMouse.pressed ? "#64879f" : Design.primary
                opacity: Recording.loaded ? 1.0 : 0.45

                Row {
                    x: 12
                    y: 9
                    spacing: 4
                    visible: root.playing

                    Repeater {
                        model: 2

                        delegate: Rectangle {
                            width: 3
                            height: 10
                            color: "#ffffff"
                        }
                    }
                }

                Image {
                    x: 12
                    y: 9
                    width: 10
                    height: 10
                    rotation: 90
                    visible: !root.playing
                    source: Design.assetRoot + "icons/icon-play.svg"
                }

                Text {
                    x: 27
                    y: 1
                    height: 27
                    verticalAlignment: Text.AlignVCenter
                    text: root.playing ? qsTr("暂停") : qsTr("回放")
                    color: "#ffffff"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 12
                }

                MouseArea {
                    id: replayMouse
                    anchors.fill: parent
                    enabled: Recording.loaded
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // 已经推到末尾时再按「回放」要能从头开始
                        if (!root.playing
                                && Recording.windowStart >= root.windowSpan - 0.001)
                            Recording.windowStart = 0
                        root.playing = !root.playing
                    }
                }
            }

            // 播放进度条
            Rectangle {
                x: 85
                y: 362
                width: 181
                height: 4
                radius: 2
                color: Qt.rgba(0, 0, 0, 0.10)
            }

            Rectangle {
                x: 85
                y: 362
                width: 181 * root.playheadRatio
                height: 4
                radius: 2
                color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.65)
            }

            Rectangle {
                x: 85 + 181 * root.playheadRatio - 5
                y: 359.5
                width: 10
                height: 10
                radius: 5
                color: "#59809c"
                border.width: 1
                border.color: "#ffffff"
            }

            Text {
                x: 277
                y: 350
                height: 28
                verticalAlignment: Text.AlignVCenter
                text: root.formatClock(root.playheadRatio * root.totalSeconds)
                      + " / " + root.formatClock(root.totalSeconds)
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 10
            }

            // 「截取」：本轮只做样式与点击态
            Rectangle {
                x: 376
                y: 350
                width: 67
                height: 28
                radius: 6
                color: clipMouse.pressed ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(0, 0, 0, 0.06)

                Text {
                    anchors.centerIn: parent
                    text: qsTr("截取")
                    color: "#4f4f4f"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }

                MouseArea {
                    id: clipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }

            // 「确认」：按当前这份报告导出 PDF
            Rectangle {
                x: 452
                y: 350
                width: 71
                height: 28
                radius: 6
                color: confirmMouse.pressed ? "#64879f" : Design.primary

                Text {
                    anchors.centerIn: parent
                    text: qsTr("确认")
                    color: "#ffffff"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 12
                }

                MouseArea {
                    id: confirmMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.exportRequested(root.recordNo)
                }
            }
        }

        // ---------- 签名行 ----------
        Text {
            x: 48
            y: 836
            height: 16
            verticalAlignment: Text.AlignVCenter
            text: qsTr("报告医师：")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
        Rectangle {
            x: 112
            y: 851
            width: 87
            height: 1
            color: "#dcdcdc"
        }

        Text {
            x: 244
            y: 836
            height: 16
            verticalAlignment: Text.AlignVCenter
            text: qsTr("审核医师：")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
        Rectangle {
            x: 307
            y: 851
            width: 87
            height: 1
            color: "#dcdcdc"
        }

        Text {
            x: 433
            y: 836
            height: 16
            verticalAlignment: Text.AlignVCenter
            text: qsTr("报告日期：")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
        Rectangle {
            x: 495
            y: 851
            width: 87
            height: 1
            color: "#dcdcdc"
        }

        DottedLine {
            x: 48
            y: 870
            width: 534
        }

        // ---------- 页脚 ----------
        Text {
            x: 48
            y: 882
            width: 534
            height: 12
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: qsTr("本报告由EEG-KSC系统自动生成,仅对本次记录时段内的数据负责;报告须经执业医师审核签发后方具有临床效力")
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 10
        }

        Text {
            x: 48
            y: 901
            width: 534
            height: 12
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: qsTr("报告编号%1·本文档为电子报告,打印签字后归档").arg(root.reportNo)
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 10
        }

        // 报告底部下划线，与标题下方的下划线呼应
        Rectangle {
            x: 48
            y: 925
            width: 534
            height: 2
            color: Design.primary
        }
    }
}
