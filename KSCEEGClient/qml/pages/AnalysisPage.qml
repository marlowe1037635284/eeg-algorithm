import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
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
    signal changePasswordRequested()
    signal deviceInfoRequested()
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

    // 底部那条「通道条」只在波形 / 频谱两页出现：它是**选当前导联**的，
    // 而通道页是一张只读的 16 行统计表（设计稿 post-channel.png 里表格直接
    // 铺到状态行、下方没有通道条）、统计页有每通道小柱、地形图页有六张全脑
    // 图、报告页是整段描述 —— 那几页没有「当前导联」这个概念，摆一条条上去
    // 只会让人以为点了会变
    readonly property bool tabHasChannelStrip:
        currentTab === "wave" || currentTab === "spectrum"

    // 时间轴是「换窗口」的导航条：波形、频谱两页用它换时间窗，地形图页用它换
    // 六张全脑图对应的时段；通道页是只读的 16 行统计表、统计页是一组汇总图、
    // 报告页是整段描述，底部都不摆时间轴
    readonly property bool tabHasTimeline:
        currentTab === "wave" || currentTab === "spectrum" || currentTab === "topography"

    // 舞台内容区（相对舞台左上角，见上面的坐标说明）
    readonly property int contentX: 10
    readonly property int contentY: 71
    readonly property int contentWidth: 1323
    // 有通道条时内容压在通道条（y=692）上沿；其余有图页的内容压到时间轴
    // （y=754）上沿，否则正文会盖住时间轴。通道页 / 统计页 / 报告页没有时间轴，
    // 内容压到状态条（y=824）上沿；地形图页最低到 674，在 683 之内，不会被裁
    readonly property int contentHeight:
        tabHasChannelStrip ? 608
                           : (tabHasTimeline ? 683 : 753)

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
    // 与历史记录页的导出同一套：目录跟「系统设置 → 记录保存目录」用同一个 —— 记录本来
    // 就落在那里，导出再落到同一个地方，用户不必跑到两个目录里找东西。
    // recordDirectory() 会把「本机不存在的旧路径」自动纠正成默认目录，这里直接信它
    function exportFolder() {
        return database ? database.recordDirectory() : ""
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
        onChangePasswordRequested: root.changePasswordRequested()
        onDeviceInfoRequested: root.deviceInfoRequested()

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

                // 导出图标：方框 + 指向右上的箭头，直接使用设计给的 SVG。
                // 之前是用几个矩形手拼的，与原型线条对不齐；SVG 自带 17×17 视框与白色填充
                Image {
                    x: 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: 17
                    height: 17
                    source: Design.assetRoot + "icons/icon-export.svg"
                    sourceSize: Qt.size(17, 17)
                    fillMode: Image.PreserveAspectFit
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

                // 图例行底板（设计稿 002：1272×61、圆角 12、#D9D9D9 35%）
                Rectangle {
                    anchors.fill: parent
                    radius: 12
                    color: Design.panelFill
                }

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
                                radius: 10
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
            // 自上而下：圆角容器 → 刻度尺（主/次刻度）→ mm:ss 标签 → 浅灰轨道
            // → 当前窗口的蓝色长条。刻度按**等距时间步长**生成（不是四等分），
            // 步长从 1/2/5×10ⁿ 与常用的「整分」里挑，保证主刻度不超过 10 条
            Item {
                id: timeline

                x: root.contentX
                y: 754
                width: root.contentWidth
                height: 62
                visible: root.tabHasTimeline

                readonly property real duration: Math.max(0.5, Analysis.durationSeconds)
                readonly property real majorStep: root.niceStep(duration)
                readonly property int majorCount:
                    Math.max(1, Math.floor(duration / majorStep + 1e-6))
                // 末格是主刻度，所以次刻度总数正好是 5 的整数倍
                readonly property int minorCount: majorCount * 5
                // 刻度尺左右各留 12；刻度从容器顶下方 13 起向下垂
                readonly property real rulerX: 12
                readonly property real rulerWidth: width - 24
                readonly property real tickTop: 13
                // 轨道贴容器底边、几乎铺满整个宽度；拖动/定位都按它算
                readonly property real trackX: 1
                readonly property real trackWidth: width - 2

                // 容器本身不填色（设计稿 019：1273×62、圆角 12.5、主色 20% 描边），
                // 底就是舞台面板的浅灰；填白会在这条上压出一块比周围更亮的底
                Rectangle {
                    anchors.fill: parent
                    radius: 12.5
                    color: "transparent"
                    border.width: 1
                    border.color: Design.panelBorder
                }

                Repeater {
                    model: timeline.minorCount + 1

                    delegate: Rectangle {
                        required property int index

                        readonly property bool major: index % 5 === 0

                        x: timeline.rulerX + timeline.rulerWidth * index / timeline.minorCount
                        y: timeline.tickTop
                        width: 1
                        height: major ? 14 : 9
                        color: major ? Qt.rgba(0, 0, 0, 0.62) : Qt.rgba(0, 0, 0, 0.42)
                    }
                }

                // mm:ss 标签：**左边缘对齐主刻度**（不是居中），末端夹住不越界
                Repeater {
                    model: timeline.majorCount + 1

                    delegate: Text {
                        required property int index

                        readonly property real seconds: index * timeline.majorStep

                        x: Math.min(timeline.rulerX
                                    + timeline.rulerWidth * index / timeline.majorCount,
                                    timeline.rulerX + timeline.rulerWidth - width)
                        y: 25
                        text: root.formatClock(seconds)
                        color: Qt.rgba(0, 0, 0, 0.45)
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 12
                    }
                }

                // 浅灰轨道：整段记录的范围
                Rectangle {
                    x: timeline.trackX
                    y: timeline.height - 18
                    width: timeline.trackWidth
                    height: 18
                    color: "#dad9d9"
                }

                // 当前显示窗口在整段记录里的位置。拖它就是换波形窗口
                Rectangle {
                    readonly property real ratio:
                        Math.max(0, Math.min(1, Analysis.windowStartSeconds / timeline.duration))
                    readonly property real windowRatio:
                        Math.max(0, Math.min(1, Analysis.windowSeconds / timeline.duration))

                    x: timeline.trackX + timeline.trackWidth * ratio
                    y: timeline.height - 18
                    width: Math.max(12, timeline.trackWidth * windowRatio)
                    height: 18
                    color: Design.primary
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

            // ---------- 状态条 ----------
            // 设计稿 info.png：1315×54 的胶囊条（圆角 9、panelFill 底 + panelBorder
            // 1px 描边），一行 14px 的「标签：值」——标签走正文色、值走主色，
            // 组与组之间留 20、组内紧贴（冒号后面不带空格）
            //
            // 文案很长（导联 / 窗口内范围 / 处理链 / 质检一长串），窄窗口放不下。
            // 不再直接省略号截断，而是横向可滚动：内容溢出时底部才浮出一条细滑块，
            // 提示「还能往右拖」。放得下时滑块不出现、文字照旧左对齐
            Rectangle {
                x: root.contentX
                y: 824
                width: root.contentWidth
                height: 54
                radius: 9
                clip: true
                color: Design.panelFill
                border.width: 1
                border.color: Design.panelBorder

                Flickable {
                    id: statusFlick
                    anchors.fill: parent
                    // 左右各留 23 的内边距（设计稿里文字压在离框 23 处）
                    contentWidth: Math.max(width, statusRow.implicitWidth + 46)
                    contentHeight: height
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.HorizontalFlick
                    // 放得下就别让它有可拖动的余量，免得跟点击/滚轮抢事件
                    interactive: contentWidth > width + 1

                    // 外层 Row 的 spacing 是「组间距」，内层 Row 的 0 让标签与值紧贴
                    Row {
                        id: statusRow
                        x: 23
                        y: Math.round((statusFlick.height - height) / 2)
                        spacing: 20

                        Repeater {
                            model: Analysis.statusGroups

                            delegate: Row {
                                required property var modelData
                                spacing: 0

                                Repeater {
                                    model: modelData

                                    // 声明了 required 的 delegate 不再从上下文取
                                    // modelData，这里显式拿内层 Repeater 的那一项
                                    delegate: Text {
                                        required property var modelData

                                        text: modelData.text
                                        color: modelData.kind === "value" ? Design.primary
                                                                          : Design.textPrimary
                                        font.family: Design.fontFamily
                                        font.styleName: Design.styleRegular
                                        font.pixelSize: 14
                                    }
                                }
                            }
                        }
                    }

                    // 还没结果 / 正在算 / 出错时的兜底。字号与配色跟上面那行对齐，
                    // 免得刚进页面时这条突然换个样
                    Text {
                        x: 23
                        height: statusFlick.height
                        verticalAlignment: Text.AlignVCenter
                        visible: Analysis.statusGroups.length === 0
                        text: Analysis.busy ? qsTr("正在计算…")
                                            : (Analysis.errorText.length > 0
                                               ? Analysis.errorText
                                               : qsTr("正在等待分析结果"))
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }

                    // 细滑块。只在内容溢出时出现（AsNeeded），不画底槽、只留滑块，
                    // 左右各留 15px 避开圆角；贴在状态条下沿，不挡正文
                    ScrollBar.horizontal: ScrollBar {
                        id: statusScroll
                        policy: ScrollBar.AsNeeded
                        height: 8
                        topPadding: 1
                        bottomPadding: 3
                        leftPadding: 15
                        rightPadding: 15

                        contentItem: Rectangle {
                            implicitHeight: 4
                            radius: 2
                            color: statusScroll.pressed
                                   ? Design.primary
                                   : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
                        }
                    }
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

    // 免责声明：贴在返回按钮左侧，避免分析结论被当成独立诊断依据
    Text {
        x: 1491
        y: 89
        width: 224
        height: 22
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: qsTr("仅供医师参考，不作为独立诊断依据")
        color: Design.textMuted
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 13
    }

    // 高度按原型比例：按钮高约为标题条(75)的 0.58 → 43，并在标题条内垂直居中
    Rectangle {
        x: 1739
        y: 79
        width: 147
        height: 43
        radius: 12
        color: backMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("返回历史记录")
            color: Design.textPrimary
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

    // 时间条主刻度的步长：从 1/2/5×10ⁿ 与几个常用的「整分」里挑最小的一档，
    // 使主刻度不超过 10 条。直接取 duration/4 会得到 01:07 这种读不出来的时刻
    function niceStep(duration) {
        const candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        for (let i = 0; i < candidates.length; ++i) {
            if (duration / candidates[i] <= 10)
                return candidates[i]
        }
        return duration / 10
    }

    // ---------- 标签页图标 ----------
    // 六个图标用设计给的 SVG（assets/icons/tab-*.svg：波形 / 频谱 / 通道 / 统计 /
    // 地形图 / 报告，kind 与文件名一一对应）。它们是单色填充，用 MultiEffect 把填充
    // 重染成当前态的颜色：选中 = 主色、未选中 = 次级灰 —— 与原来手绘 Canvas 的
    // tint 行为一致。Image 要先 layer.enabled 取到纹理，才能喂给 MultiEffect
    // 当 source（用法同 TopographyTab 里那张头型遮罩）
    component TabIcon: Item {
        id: icon

        property string kind: "wave"
        property color tint: Design.textSecondary

        Image {
            id: glyph

            anchors.fill: parent
            source: Design.assetRoot + "icons/tab-" + icon.kind + ".svg"
            sourceSize: Qt.size(Math.max(1, Math.round(icon.width)),
                                Math.max(1, Math.round(icon.height)))
            fillMode: Image.PreserveAspectFit
            visible: false
            layer.enabled: true
        }

        MultiEffect {
            anchors.fill: parent
            source: glyph
            // 1.0 = 完全按 colorizationColor 着色，只保留源图的 alpha
            colorization: 1.0
            colorizationColor: icon.tint
        }
    }
}
