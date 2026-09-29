import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「电极贴合状态」面板。
// 设计稿里位于画板 (107,225)，尺寸 331×499；本文件坐标 = 设计坐标 - (107,225)。
//
// 数据来源：扫描结果来自 Acq.electrodeQuality，**由采集到的信号估计**，不是设备
// 直读的阻抗 —— 协议一次只给 4 路不带电极名的阻抗值（见 serialprotocol.h），
// 推不出「16 个导联各是多少 kΩ」。所以数值列显示的是测得的噪声，量级标在单位上；
// 面板标题旁也写明了来源，不冒充设备读数。
Item {
    id: root

    signal scanFinished(string summary)

    // 扫描按钮的动画态。真正的计算在 C++ 侧是毫秒级的，这里等 1.2 秒再出结果 ——
    // 扫描一下就闪完，用户根本来不及看清「刚才那下点上了没有」
    property bool scanning: false
    property string scanError: ""

    // 设备实际采到的 16 路。有扫描结果就按结果走，否则退回设计稿那套静态示意
    readonly property var quality: Acq.electrodeScanValid ? Acq.electrodeQuality : []
    readonly property bool hasScan: quality.length > 0

    // 头部电极图上的电极点：x/y = 圆点左上角（16×16），
    // labelX/labelY = 导联名文本框左上角（高 28，字号 8）—— 位置照抄设计稿。
    //
    // 注意这张图上的电极**与设备的 16 路不是同一套**（设计稿画的是 AF3/F1/FC1/Cz/
    // M1/Oz 这些，设备给的是 F7/F8/T3/T4/T5/T6/O1/O2）。名字能对上的就直连，
    // 对不上的按**位置最近**的几路加权估计 —— 位置照设计稿不动，颜色跟真实数据走
    readonly property var mapPoints: [
        { name: "Fp1", x: 121, y: 123, labelX: 123, labelY: 117 },
        { name: "Fp2", x: 197, y: 123, labelX: 198, labelY: 117 },
        { name: "AF3", x: 124, y: 153, labelX: 125, labelY: 147 },
        { name: "F5",  x: 90,  y: 167, labelX: 94,  labelY: 161 },
        { name: "F3",  x: 112, y: 172, labelX: 116, labelY: 166 },
        { name: "F1",  x: 135, y: 176, labelX: 139, labelY: 170 },
        { name: "Fz",  x: 158, y: 177, labelX: 162, labelY: 171 },
        { name: "F2",  x: 180, y: 176, labelX: 184, labelY: 170 },
        { name: "F4",  x: 203, y: 170, labelX: 207, labelY: 164 },
        { name: "FC3", x: 108, y: 197, labelX: 110, labelY: 191 },
        { name: "FC1", x: 130, y: 200, labelX: 132, labelY: 194 },
        { name: "M1",  x: 52,  y: 213, labelX: 55,  labelY: 207 },
        { name: "M2",  x: 263, y: 213, labelX: 266, labelY: 207 },
        { name: "Cz",  x: 159, y: 216, labelX: 163, labelY: 210 },
        { name: "P3",  x: 120, y: 262, labelX: 123, labelY: 256 },
        { name: "Oz",  x: 158, y: 299, labelX: 161, labelY: 293 }
    ]

    // 设备那 16 路在本面板头型图里的落点。Acq.electrodeMap 给的是相对头半径的
    // 百分比（与地形图同一套坐标），这里按头型圆的中心与半径换算过来，
    // 好让「就近估计」能在同一个坐标系里比距离
    readonly property var deviceXY: {
        var center_x = 166.0
        var center_y = 215.5
        var radius = 112.0
        var table = ({})
        var list = Acq.electrodeMap
        for (var i = 0; i < list.length; ++i) {
            table[list[i].name] = { x: center_x + list[i].x / 100.0 * radius,
                                    y: center_y + list[i].y / 100.0 * radius }
        }
        return table
    }

    // 设计稿那套静态示意值。没做过扫描时用，保证打开就是设计稿的样子
    readonly property var placeholder: [
        { name: "Fp1", text: "—", level: "良好", ratio: 0.26 },
        { name: "Fp2", text: "—", level: "一般", ratio: 0.52 },
        { name: "F3",  text: "—", level: "不良", ratio: 0.19 },
        { name: "F4",  text: "—", level: "不良", ratio: 0.19 },
        { name: "C3",  text: "—", level: "良好", ratio: 0.30 },
        { name: "C4",  text: "—", level: "良好", ratio: 0.28 },
        { name: "P3",  text: "—", level: "一般", ratio: 0.42 },
        { name: "P4",  text: "—", level: "不良", ratio: 0.15 },
        { name: "O1",  text: "—", level: "良好", ratio: 0.32 },
        { name: "O2",  text: "—", level: "良好", ratio: 0.34 },
        { name: "F7",  text: "—", level: "一般", ratio: 0.47 },
        { name: "F8",  text: "—", level: "一般", ratio: 0.39 },
        { name: "T3",  text: "—", level: "良好", ratio: 0.29 },
        { name: "T4",  text: "—", level: "良好", ratio: 0.27 },
        { name: "T5",  text: "—", level: "良好", ratio: 0.35 },
        { name: "T6",  text: "—", level: "良好", ratio: 0.36 }
    ]

    // 数值列宽度够放多少行。设计稿画了 4 行 + 一根滚动条
    readonly property var rows: hasScan ? quality : placeholder
    readonly property int rowHeight: 32
    readonly property int viewHeight: 134
    property real scroll: 0
    readonly property real maxScroll: Math.max(0, rows.length * rowHeight - viewHeight)

    // 头部图上某个点位对应的接触等级：先在扫描结果里找同名通道，找不到就按
    // 最近的三路做反距离加权，取加权后噪声最大的那一档
    function levelAtPoint(name, pointX, pointY) {
        if (!hasScan)
            return ""
        var exact = -1
        for (var i = 0; i < quality.length; ++i) {
            if (quality[i].name === name) {
                exact = i
                break
            }
        }
        if (exact >= 0)
            return quality[exact].level

        // 就近估计：权重 1/(d²+1)，取权重最大的三路
        var best = []
        for (var c = 0; c < quality.length; ++c) {
            var position = deviceXY[quality[c].name]
            if (!position)
                continue
            var dx = position.x - pointX
            var dy = position.y - pointY
            var weight = 1.0 / (dx * dx + dy * dy + 1.0)
            best.push({ weight: weight, index: c })
        }
        best.sort(function(a, b) { return b.weight - a.weight })

        var worst = ""
        var worstRank = -1
        for (var k = 0; k < Math.min(3, best.length); ++k) {
            var level = quality[best[k].index].level
            var rank = level === "脱落" ? 3 : level === "不良" ? 2 : level === "一般" ? 1 : 0
            if (rank > worstRank) {
                worstRank = rank
                worst = level
            }
        }
        return worst
    }

    function startScan() {
        scanning = true
        scanTimer.restart()
    }

    Timer {
        id: scanTimer
        interval: 1200
        onTriggered: {
            root.scanning = false
            // 失败原因由 C++ 给（数据不够 / 没连设备），这里不猜
            if (!Acq.scan_electrodes()) {
                root.scanError = Acq.electrodeSummary
                errorTimer.restart()
                root.scanFinished("")
                return
            }
            root.scanError = ""
            root.scanFinished(Acq.electrodeSummary)
        }
    }

    Timer {
        id: errorTimer
        interval: 4000
        onTriggered: root.scanError = ""
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
        y: 10
        text: qsTr("电极贴合状态")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 数据来源说明。不做扫描的话这块面板就是一张图，说清了来源才不会有人
    // 把它当成设备直读的阻抗
    Text {
        x: 14
        y: 32
        width: 300
        elide: Text.ElideRight
        text: root.scanError.length > 0
              ? root.scanError
              : (root.hasScan ? qsTr("接触质量由信号噪声估计 · 非设备直读")
                              : qsTr("点「阻抗扫描」按实时信号估计"))
        color: root.scanError.length > 0 ? Design.bad : Design.textMuted
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // 阻抗扫描按钮（设计稿右上角）
    Rectangle {
        x: 202
        y: 7
        width: 115
        height: 31
        radius: 12
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        // 扫描中把图标转起来：1.2 秒的等待里没有动效，看着像卡住
        Image {
            id: scanIcon
            x: 17
            y: 10
            width: 16
            height: 13
            source: Design.assetRoot + "icons/icon-scan.svg"
            transformOrigin: Item.Center

            RotationAnimation on rotation {
                running: root.scanning
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
            }
        }

        Text {
            x: 36
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: root.scanning ? qsTr("扫描中…") : qsTr("阻抗扫描")
            color: "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 按钮始终可点，由扫描本身判断数据够不够并给出原因。
        // 按「是否在采集」来禁用是错的：串口开着但没在录制时信号照样在流，
        // 那时数据是有的，禁用反而把一个能用的功能挡在外面
        MouseArea {
            anchors.fill: parent
            enabled: !root.scanning
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.startScan()

            ToolTip.visible: containsMouse && !root.scanning
            ToolTip.text: qsTr("按最近 2 秒的实时信号估计各导联的接触质量")
            ToolTip.delay: 400
        }
    }

    PanelDivider {
        x: 5
        y: 45
        width: 321
    }

    // ---------- 图例 ----------
    // 设计稿只画了「良好/一般/脱落」三项（面板宽度放不下第四项），
    // 但颜色按语义修正：良好=绿、一般=橙、脱落=灰。
    Row {
        x: 129
        y: 54
        spacing: 21

        Repeater {
            model: [
                { label: "良好", state: "良好" },
                { label: "一般", state: "一般" },
                { label: "脱落", state: "脱落" }
            ]

            delegate: Item {
                required property var modelData
                width: 47
                height: 28

                Rectangle {
                    x: 0
                    y: 9
                    width: 10
                    height: 10
                    radius: 5
                    color: Design.impedanceColor(modelData.state)
                }

                Text {
                    x: 19
                    y: 0
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.label
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }
    }

    // ---------- 电极分布图 ----------
    Image {
        x: 14
        y: 89
        width: 303
        height: 260
        source: Design.assetRoot + "icons/head-panel.svg"
        fillMode: Image.Stretch
    }

    Image {
        x: 54
        y: 104
        width: 224
        height: 223
        source: Design.assetRoot + "icons/head-outline.svg"
        fillMode: Image.Stretch
    }

    Repeater {
        model: root.mapPoints

        delegate: Item {
            required property var modelData

            // 没扫过就保持设计稿的绿色示意，扫过之后跟着真实结果变
            readonly property string pointLevel:
                root.hasScan ? root.levelAtPoint(modelData.name, modelData.x + 8, modelData.y + 8)
                             : "良好"

            Rectangle {
                x: modelData.x
                y: modelData.y
                width: 16
                height: 16
                radius: 8
                color: Design.electrodeFill(parent.pointLevel)
                border.width: 1
                border.color: Design.impedanceColor(parent.pointLevel)
            }

            Text {
                x: modelData.x + 8 - 15
                y: modelData.labelY
                width: 30
                height: 28
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.name
                color: Design.impedanceColor(parent.pointLevel)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 8
            }
        }
    }

    // ---------- 接触质量列表（可视 4 行，滚轮滚动）----------
    Item {
        id: viewport
        x: 0
        y: 365
        width: root.width
        height: root.viewHeight
        clip: true

        Repeater {
            model: root.rows

            delegate: Item {
                required property var modelData
                required property int index

                readonly property int rowY: 32 * index - root.scroll

                // 行分隔线（首行上方不画）
                PanelDivider {
                    y: rowY - 1
                    width: 303
                    visible: index > 0
                }

                Text {
                    x: 14
                    y: rowY
                    width: 40
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.name
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Rectangle {
                    x: 46
                    y: rowY + 10
                    width: 178
                    height: 10
                    radius: 5
                    color: Qt.rgba(0, 0, 0, 0.07)
                }

                Rectangle {
                    x: 46
                    y: rowY + 10
                    width: 178 * modelData.ratio
                    height: 10
                    radius: 5
                    color: Design.impedanceColor(modelData.level)
                }

                Text {
                    x: 236
                    y: rowY
                    width: 50
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.text
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 280
                    y: rowY
                    width: 44
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.level
                    color: Design.impedanceColor(modelData.level)
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: (wheel) => {
                var step = wheel.angleDelta.y > 0 ? -root.rowHeight : root.rowHeight
                root.scroll = Math.max(0, Math.min(root.maxScroll, root.scroll + step))
            }
        }
    }

    // ---------- 滚动条 ----------
    Rectangle {
        x: 319
        y: 370
        width: 7
        height: 114
        radius: 4
        color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
        visible: root.maxScroll > 0
    }

    Rectangle {
        x: 319
        // 轨道 114 高、滑块 24 高，可走 90px
        y: 386 + (root.maxScroll > 0 ? root.scroll / root.maxScroll : 0) * 90
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
        visible: root.maxScroll > 0
    }
}
