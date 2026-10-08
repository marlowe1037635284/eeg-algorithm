import QtQuick
import QtQuick.Controls.Basic
import QtCore
import KSCEEGClient

// 「数据分析与后处理」页。从历史记录页的「分析」进来，整屏替换掉历史记录。
//
// 两套坐标（与历史记录页、患者管理页一致）：
//   · 直接摆在画布上的东西（导航、标题条）走 AppShell；
//   · 放进 AppShell 内容槽的东西，坐标减去内容卡片原点 (154,150)。
//     内容槽原点相对卡片左边界（107）还多缩进 47，所以要让参数面板贴到卡片
//     左内侧 14 处，这里就得写 x=-33（历史记录页的整宽表头同样用负 x 补偿）。
//     参数面板在 (-33,0) 尺寸 415×882、右侧舞台跟在面板后面 (395,0) 尺寸 1340×883，
//     舞台右端落在卡片右内侧 14 处，卡片内左右留白对称。
//
// 页面自己不持有任何分析状态：参数、结果、图都在 C++ 的 Analysis 里
//（见 postprocess.h）。这一层只做三件事 —— 把记录喂进去、按当前标签页摆内容、
// 把导出请求转出去
Item {
    id: root

    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")
    // 应用数据库，由外层注入
    property var database
    // 要分析的记录号，进来之前由 Main 回填
    property string recordNo: ""

    signal navRequested(string label)
    signal logoutRequested()
    // 点「返回历史记录」
    signal backRequested()
    signal notifyRequested(string message, string kind)

    property string currentTab: "wave"

    readonly property var tabs: [
        { key: "wave",       label: qsTr("波形") },
        { key: "spectrum",   label: qsTr("频谱") },
        { key: "channel",    label: qsTr("通道") },
        { key: "stats",      label: qsTr("统计") },
        { key: "topography", label: qsTr("地形图") },
        { key: "report",     label: qsTr("报告") }
    ]

    // 底部那条「通道条」只在波形 / 频谱 / 通道三页出现：它是**选当前导联**的，
    // 而统计页有每通道小柱、地形图页有六张全脑图、报告页是整段描述 ——
    // 那三页没有「当前导联」这个概念，摆一条条上去只会让人以为点了会变
    readonly property bool tabHasChannelStrip:
        currentTab === "wave" || currentTab === "spectrum" || currentTab === "channel"

    // 舞台内容区（相对舞台左上角，见上面的坐标说明）
    readonly property int contentX: 10
    readonly property int contentY: 71
    readonly property int contentWidth: 1323
    readonly property int contentHeight: tabHasChannelStrip ? 608 : 700

    // ---------- 打开记录 ----------
    // 记录号进来之后，从库里取这条记录的字段与事件标注，一并交给 Analysis。
    // 页面不自己读 .eegbin，也不自己算任何东西
    function openRecord(no) {
        if (!database) {
            notifyRequested(qsTr("数据库不可用，无法打开记录"), "error")
            return
        }
        const row = database.session(no)
        if (row.filePath === undefined || row.filePath.length === 0) {
            notifyRequested(qsTr("这条记录没有落盘原始数据，无法做后处理"), "error")
            return
        }

        const events = database.sessionEvents(no)
        Analysis.open(no, row.filePath, {
            "patient": row.patient !== undefined ? row.patient : "",
            "patientNo": row.patientNo !== undefined ? row.patientNo : "",
            "time": row.time !== undefined ? row.time : "",
            "quality": row.quality !== undefined ? row.quality : "",
            // 事件**个数**取库里那一列（字符形态的 "4"），事件**列表**另给一个键。
            // 两个都叫 events 的话，后写的一个会悄悄把前一个盖掉
            "eventCount": row.events !== undefined ? row.events : "0",
            "events": events
        })
    }

    onRecordNoChanged: {
        if (recordNo.length > 0)
            openRecord(recordNo)
    }

    // 页面由 Loader 按需实例化，进来时 recordNo 已经是新值（属性没变过，
    // 上面那个处理器不会响），所以这里也得开一次
    Component.onCompleted: {
        if (recordNo.length > 0)
            openRecord(recordNo)
    }

    // ---------- 导出 ----------
    // 与历史记录页的导出同一套：目录固定「文档」，提示语里带完整路径。
    // StandardPaths 返回的是 url 而不是字符串，这里显式 toString() 再判空 ——
    // 直接对 url 取 length 拿不到长度（那是 undefined），空目录就漏过去了
    function exportFolder() {
        const documents = StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        if (documents && documents.toString().length > 0)
            return documents.toString()
        const home = StandardPaths.writableLocation(StandardPaths.HomeLocation)
        return home ? home.toString() : ""
    }

    function exportData() {
        const folder = exportFolder()
        if (folder.length === 0) {
            notifyRequested(qsTr("找不到可用的导出目录"), "error")
            return
        }
        const result = Analysis.export_data(folder)
        notifyRequested(result.message, result.success ? "success" : "error")
    }

    function exportStats() {
        const folder = exportFolder()
        if (folder.length === 0) {
            notifyRequested(qsTr("找不到可用的导出目录"), "error")
            return
        }
        const result = Analysis.export_stats_csv(folder)
        notifyRequested(result.message, result.success ? "success" : "error")
    }

    function exportReport() {
        const folder = exportFolder()
        if (folder.length === 0) {
            notifyRequested(qsTr("找不到可用的导出目录"), "error")
            return
        }
        const result = Analysis.export_report_txt(folder)
        notifyRequested(result.message, result.success ? "success" : "error")
    }

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("数据分析与后处理")
        // 导航栏标在「历史记录」上：这一页是从那里进来的，返回也回到那里
        currentNav: qsTr("历史记录")
        userName: root.userName
        userRole: root.userRole
        statusItems: {
            var items = []
            if (Analysis.loaded) {
                items.push(qsTr("采样率：") + Analysis.sampleRate + qsTr("Hz"))
                items.push(qsTr("通道：") + Analysis.channelCount)
                items.push(qsTr("当前导联：")
                           + Analysis.channelNames[Analysis.currentChannel])
                items.push(qsTr("分析片段：")
                           + Analysis.segmentStartSeconds.toFixed(1) + " - "
                           + (Analysis.segmentStartSeconds + Analysis.segmentSeconds).toFixed(1)
                           + qsTr(" s"))
            }
            return items
        }
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

        // ---------- 左侧参数面板 ----------
        AnalysisControls {
            x: -33
            y: 0
        }

        // ---------- 右侧舞台 ----------
        Item {
            id: stage

            x: 395
            y: 0
            width: 1340
            height: 883

            Rectangle {
                anchors.fill: parent
                radius: 16
                color: Design.panelFill
                border.width: 1
                border.color: Design.panelBorder
            }

            // ---------- 标签页 ----------
            Repeater {
                model: root.tabs

                delegate: Rectangle {
                    required property var modelData
                    // index 必须显式声明：声明了 required 属性的 delegate 不会
                    // 再从上下文里拿 index，漏掉它会得到 undefined，
                    // 六个标签页全叠在同一个 x 上
                    required property int index

                    readonly property bool active: root.currentTab === modelData.key

                    x: 15 + index * 150
                    y: 11
                    width: 134
                    height: 52
                    radius: 10
                    color: active ? Design.primarySoft : Qt.rgba(0xba / 255, 0xba / 255, 0xba / 255, 0.14)
                    border.width: active ? 1 : 0
                    border.color: Design.primary

                    TabIcon {
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18
                        height: 18
                        kind: modelData.key
                        tint: parent.active ? Design.primary : Design.textSecondary
                    }

                    Text {
                        x: 44
                        width: parent.width - 52
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.label
                        color: parent.active ? Design.primary : Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: parent.active ? Design.styleMedium : Design.styleRegular
                        font.pixelSize: 16
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.currentTab = modelData.key
                    }
                }
            }

            // ---------- 导出按钮 ----------
            Rectangle {
                x: 1187
                y: 11
                width: 136
                height: 51
                radius: 12
                color: exportMouse.pressed ? "#64879f" : Design.primary
                opacity: Analysis.loaded ? 1.0 : 0.5

                Text {
                    x: 40
                    width: parent.width - 48
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("导出数据")
                    color: "#ffffff"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 16
                }

                // 下载图标：一个向下的箭头 + 底下的托盘，用两个矩形拼出来，
                // 不值得为此单拉一个 SVG 资源
                Item {
                    x: 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 1
                        width: 2
                        height: 9
                        color: "#ffffff"
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 6
                        width: 7
                        height: 2
                        rotation: 45
                        color: "#ffffff"
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 6
                        width: 7
                        height: 2
                        rotation: -45
                        color: "#ffffff"
                    }

                    Rectangle {
                        x: 1
                        y: 13
                        width: 14
                        height: 2
                        color: "#ffffff"
                    }
                }

                MouseArea {
                    id: exportMouse
                    anchors.fill: parent
                    enabled: Analysis.loaded
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.exportData()
                }
            }

            // ---------- 标签页内容 ----------
            // 用 Loader 而不是六个都建出来：只有当前这一页是活的，
            // 它就只报自己那块绘制区的尺寸给 C++（波形图和频谱图的像素尺寸不同）
            Loader {
                id: tabLoader

                x: root.contentX
                y: root.contentY
                width: root.contentWidth
                height: root.contentHeight
                sourceComponent: {
                    switch (root.currentTab) {
                    case "spectrum":   return spectrumComponent
                    case "channel":    return channelComponent
                    case "stats":      return statsComponent
                    case "topography": return topographyComponent
                    case "report":     return reportComponent
                    default:           return waveComponent
                    }
                }
            }

            // 通道页另有一个导出统计 CSV 的小按钮（设计稿里只在那一页出现）。
            //
            // **必须声明在内容 Loader 之后**：它落在内容区（y=71 起）里，
            // 声明在前面就会被上面的 Flickable 盖住 —— 按钮看得见，点下去却
            // 毫无反应（事件被 Flickable 吃掉）。z 序在 QML 里就是声明顺序
            Rectangle {
                x: 1187
                y: 74
                width: 136
                height: 30
                radius: 8
                visible: root.currentTab === "channel"
                color: statsMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
                border.width: 1
                border.color: Design.panelBorder

                Text {
                    anchors.centerIn: parent
                    text: qsTr("导出统计CSV")
                    color: Design.primary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 14
                }

                MouseArea {
                    id: statsMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.exportStats()
                }
            }

            // ---------- 底部通道条 ----------
            Item {
                id: channelStrip

                x: root.contentX
                y: 692
                width: root.contentWidth
                height: 62
                visible: root.tabHasChannelStrip

                Flickable {
                    anchors.fill: parent
                    contentWidth: Analysis.channelCount * 109
                    contentHeight: height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Row {
                        x: 12
                        y: 11
                        spacing: 13

                        Repeater {
                            model: Analysis.channelCount

                            delegate: Rectangle {
                                required property int index

                                readonly property bool active: index === Analysis.currentChannel

                                width: 96
                                height: 40
                                radius: 8
                                color: active ? Design.primarySoft
                                              : Qt.rgba(0xba / 255, 0xba / 255, 0xba / 255, 0.14)
                                border.width: active ? 1 : 0
                                border.color: active ? Design.primary : "transparent"

                                Text {
                                    anchors.centerIn: parent
                                    text: Analysis.channelNames[index]
                                    color: active ? Design.primary : Design.textSecondary
                                    font.family: Design.fontFamily
                                    font.styleName: active ? Design.styleMedium : Design.styleRegular
                                    font.pixelSize: 15
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Analysis.currentChannel = index
                                }
                            }
                        }
                    }
                }
            }

            // ---------- 时间轴：整段记录的导航条 ----------
            Item {
                id: timeline

                x: root.contentX
                y: 765
                width: root.contentWidth
                height: 67

                readonly property real duration: Math.max(0.5, Analysis.durationSeconds)
                readonly property real trackX: 26
                readonly property real trackWidth: width - 52

                // 刻度：整段记录按四等分标绝对时刻，与回放预览同一口径
                Repeater {
                    model: 5

                    delegate: Text {
                        required property int index

                        readonly property real seconds: timeline.duration * index / 4

                        x: Math.min(timeline.trackX + timeline.trackWidth * index / 4 - width / 2,
                                    timeline.trackX + timeline.trackWidth - width)
                        y: 0
                        text: root.formatClock(seconds)
                        color: Qt.rgba(0, 0, 0, 0.45)
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 12
                    }
                }

                Rectangle {
                    x: timeline.trackX
                    y: 28
                    width: timeline.trackWidth
                    height: 16
                    radius: 8
                    color: Qt.rgba(0, 0, 0, 0.07)
                }

                // 事件位置的小色点，钉在轨道上
                Repeater {
                    model: Analysis.events

                    delegate: Rectangle {
                        required property var modelData

                        readonly property real ratio:
                            Math.max(0, Math.min(1, modelData.offsetSeconds / timeline.duration))

                        x: timeline.trackX + timeline.trackWidth * ratio - 3
                        y: 33
                        width: 6
                        height: 6
                        radius: 3
                        color: modelData.color !== undefined && String(modelData.color).length > 0
                               ? modelData.color : "#7c3aed"
                    }
                }

                // 当前显示窗口在整段记录里的位置。拖它就是换波形窗口
                Rectangle {
                    readonly property real ratio:
                        Math.max(0, Math.min(1, Analysis.windowStartSeconds / timeline.duration))

                    x: timeline.trackX + timeline.trackWidth * ratio
                    y: 28
                    width: Math.max(12, timeline.trackWidth
                                    * Math.min(1, Analysis.windowSeconds / timeline.duration))
                    height: 16
                    radius: 8
                    color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor

                    function seek(mouseX) {
                        const ratio = Math.max(0, Math.min(1,
                            (mouseX - timeline.trackX) / timeline.trackWidth))
                        // 窗口居中对齐到点击处，再让 C++ 侧夹到记录范围内
                        Analysis.windowStartSeconds = ratio * timeline.duration
                            - Analysis.windowSeconds / 2
                    }

                    onPressed: (mouse) => seek(mouse.x)
                    onPositionChanged: (mouse) => { if (pressed) seek(mouse.x) }
                }
            }

            // ---------- 状态行 ----------
            Rectangle {
                x: root.contentX
                y: 848
                width: root.contentWidth
                height: 30
                radius: 6
                color: Qt.rgba(0xd9 / 255, 0xd9 / 255, 0xd9 / 255, 0.28)

                Text {
                    x: 14
                    width: parent.width - 28
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: Analysis.statusLine.length > 0
                          ? Analysis.statusLine
                          : (Analysis.busy ? qsTr("正在计算…")
                                           : (Analysis.errorText.length > 0
                                              ? Analysis.errorText
                                              : qsTr("正在等待分析结果")))
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 13
                }
            }
        }
    }

    // ---------- 标题条上的副标题与返回按钮 ----------
    // 直接按**画板绝对坐标**摆在这一页上，声明在 AppShell 之后，所以画在
    // 标题条底色之上。之所以不走 AppShell 的插槽：它在标题条里得再开一个
    // 列表插槽，而 AppShell 是五个页面共用的 —— 为一个页面改动公共外壳，
    // 别的页面就多一分被牵连的风险
    Text {
        x: 434
        y: 93
        height: 22
        verticalAlignment: Text.AlignVCenter
        text: Analysis.subtitle
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }

    Rectangle {
        x: 1739
        y: 64
        width: 147
        height: 73
        radius: 12
        color: backMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("返回历史记录")
            color: Design.primary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 16
        }

        MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.backRequested()
        }
    }

    // ---------- 标签页组件 ----------
    Component { id: waveComponent;       WaveTab { } }
    Component { id: spectrumComponent;   SpectrumTab { } }
    Component { id: channelComponent;    ChannelTab { } }
    Component { id: statsComponent;      StatsTab { } }
    Component { id: topographyComponent; TopographyTab { } }
    Component {
        id: reportComponent
        ReportTab {
            onDownloadRequested: root.exportReport()
        }
    }

    // 秒 → mm:ss
    function formatClock(seconds) {
        const total = Math.max(0, Math.round(seconds))
        const minutes = Math.floor(total / 60)
        return String(minutes).padStart(2, "0") + ":" + String(total % 60).padStart(2, "0")
    }

    // ---------- 标签页图标 ----------
    // 设计稿里每个标签前有个小图标。导出的素材里只有背景与外框矢量、没有这六个
    // （它们在 Figma 里是 foreignObject 包着的图标帧），所以按同一套线条语汇
    // 用 Canvas 现画：线宽 1.6、圆头圆角，尺寸与设计稿的 18×18 一致
    component TabIcon: Canvas {
        id: icon

        property string kind: "wave"
        property color tint: Design.textSecondary

        onKindChanged: requestPaint()
        onTintChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = icon.tint
            ctx.lineWidth = 1.6
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            var w = width
            var h = height

            if (kind === "wave") {
                ctx.beginPath()
                ctx.moveTo(w * 0.05, h * 0.55)
                ctx.lineTo(w * 0.25, h * 0.55)
                ctx.lineTo(w * 0.38, h * 0.15)
                ctx.lineTo(w * 0.55, h * 0.85)
                ctx.lineTo(w * 0.70, h * 0.35)
                ctx.lineTo(w * 0.82, h * 0.55)
                ctx.lineTo(w * 0.95, h * 0.55)
                ctx.stroke()
            } else if (kind === "spectrum") {
                ctx.beginPath()
                ctx.moveTo(w * 0.08, h * 0.08)
                ctx.lineTo(w * 0.08, h * 0.92)
                ctx.lineTo(w * 0.94, h * 0.92)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(w * 0.18, h * 0.80)
                ctx.lineTo(w * 0.36, h * 0.45)
                ctx.lineTo(w * 0.55, h * 0.65)
                ctx.lineTo(w * 0.88, h * 0.18)
                ctx.stroke()
            } else if (kind === "channel") {
                ctx.beginPath()
                for (var i = 0; i < 4; ++i) {
                    var x = w * (0.18 + i * 0.22)
                    var top = h * (0.55 - i * 0.09)
                    ctx.moveTo(x, h * 0.92)
                    ctx.lineTo(x, top)
                }
                ctx.stroke()
            } else if (kind === "stats") {
                ctx.beginPath()
                ctx.moveTo(w * 0.08, h * 0.92)
                ctx.lineTo(w * 0.94, h * 0.92)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(w * 0.24, h * 0.92)
                ctx.lineTo(w * 0.24, h * 0.58)
                ctx.moveTo(w * 0.50, h * 0.92)
                ctx.lineTo(w * 0.50, h * 0.30)
                ctx.moveTo(w * 0.76, h * 0.92)
                ctx.lineTo(w * 0.76, h * 0.46)
                ctx.stroke()
            } else if (kind === "topography") {
                ctx.beginPath()
                ctx.arc(w / 2, h / 2, w * 0.42, 0, Math.PI * 2)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(w * 0.08, h * 0.5)
                ctx.lineTo(w * 0.92, h * 0.5)
                ctx.stroke()
                ctx.beginPath()
                ctx.ellipse(w * 0.30, h * 0.12, w * 0.20, h * 0.38, 0, 0, Math.PI * 2)
                ctx.stroke()
            } else {
                // 报告：一页纸 + 两条正文线
                ctx.beginPath()
                ctx.moveTo(w * 0.22, h * 0.08)
                ctx.lineTo(w * 0.62, h * 0.08)
                ctx.lineTo(w * 0.82, h * 0.30)
                ctx.lineTo(w * 0.82, h * 0.92)
                ctx.lineTo(w * 0.22, h * 0.92)
                ctx.closePath()
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(w * 0.36, h * 0.54)
                ctx.lineTo(w * 0.68, h * 0.54)
                ctx.moveTo(w * 0.36, h * 0.72)
                ctx.lineTo(w * 0.68, h * 0.72)
                ctx.stroke()
            }
        }
    }
}
