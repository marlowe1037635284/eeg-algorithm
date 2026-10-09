import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「电极贴合状态」面板。
// 设计稿里位于画板 (107,225)，尺寸 331×499；本文件坐标 = 设计坐标 - (107,225)。
//
// 数据来源：扫描结果来自 Acq.electrodeQuality，是设备**实测的阻抗**。
// 按下按钮时调 Acq.begin_electrode_scan() 发 'Z'，设备改为上传 B0…D0 阻抗帧
//（每帧 16 路，与 16 个电极 1:1 对应）；1.2 秒后调 Acq.scan_electrodes() 读回最新
// 一帧并发 's' 停发。数值列给的就是设备给出的阻抗（kΩ）。
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

    // 头部电极图上的电极点，照新设计稿：**标准 10-20 的 16 个位置**，
    // cx/cy = 电极环圆心（环半径 8.5，名称嵌在环内）。
    // 坐标 = 头型圆心 (166.9,213.2) + 归一化坐标 × 半径 105.6，
    // 圆心/半径与下面 head-outline.svg 头型层的头圆一致
    readonly property var mapPoints: [
        { name: "Fp1", cx: 110.5, cy: 125.2 },
        { name: "Fp2", cx: 223.3, cy: 125.2 },
        { name: "F7",  cx: 77.8,  cy: 161.4 },
        { name: "F3",  cx: 120.6, cy: 169.3 },
        { name: "Fz",  cx: 166.9, cy: 168.8 },
        { name: "F4",  cx: 213.1, cy: 169.3 },
        { name: "F8",  cx: 256.0, cy: 161.4 },
        { name: "M1",  cx: 63.4,  cy: 212.5 },
        { name: "C3",  cx: 120.7, cy: 212.1 },
        { name: "Cz",  cx: 166.9, cy: 213.2 },
        { name: "C4",  cx: 213.0, cy: 212.1 },
        { name: "M2",  cx: 270.4, cy: 212.5 },
        { name: "P3",  cx: 120.8, cy: 254.2 },
        { name: "P4",  cx: 212.9, cy: 254.2 },
        { name: "O1",  cx: 130.2, cy: 305.6 },
        { name: "O2",  cx: 203.5, cy: 305.6 }
    ]

    // 设备那 16 路在本面板头型图里的落点。Acq.electrodeMap 给的是相对头半径的
    // 百分比（与地形图同一套坐标），这里按头型圆的中心与半径换算过来，
    // 好让「就近估计」能在同一个坐标系里比距离
    readonly property var deviceXY: {
        var center_x = 166.9
        var center_y = 213.2
        var radius = 105.6
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
        { name: "F3",  text: "—", level: "不良", ratio: 0.62 },
        { name: "F4",  text: "—", level: "脱落", ratio: 0.19 },
        { name: "C3",  text: "—", level: "良好", ratio: 0.30 },
        { name: "C4",  text: "—", level: "良好", ratio: 0.28 },
        { name: "P3",  text: "—", level: "一般", ratio: 0.42 },
        { name: "P4",  text: "—", level: "脱落", ratio: 0.15 },
        { name: "O1",  text: "—", level: "良好", ratio: 0.32 },
        { name: "O2",  text: "—", level: "良好", ratio: 0.34 },
        { name: "F7",  text: "—", level: "一般", ratio: 0.47 },
        { name: "F8",  text: "—", level: "不良", ratio: 0.58 },
        { name: "T3",  text: "—", level: "良好", ratio: 0.29 },
        { name: "T4",  text: "—", level: "良好", ratio: 0.27 },
        { name: "T5",  text: "—", level: "良好", ratio: 0.35 },
        { name: "T6",  text: "—", level: "良好", ratio: 0.36 }
    ]

    // 当前档位（4/8/16）下头型图上**激活**的电极名。未激活的位置在头型图上只画
    // 浅灰占位点；16 档返回空数组，表示全部激活（见 Design.activeElectrodes，
    // 与 C++ 侧 display_channel_indices 同源）
    readonly property var activeNames: Design.activeElectrodes(Acq.channelCount)
    function isActive(name) {
        return activeNames.length === 0 || activeNames.indexOf(name) >= 0
    }

    // 数值列宽度够放多少行，设计稿画了 4 行 + 一根滚动条。
    // **只列当前档位激活的通道** —— 头型图上没亮的电极不该出现在列表里，
    // 8 档列 8 行、4 档列 4 行
    readonly property var rows: {
        var source = hasScan ? quality : placeholder
        var out = []
        for (var i = 0; i < source.length; ++i) {
            if (isActive(source[i].name))
                out.push(source[i])
        }
        return out
    }
    readonly property int rowHeight: 32
    readonly property int viewHeight: 134
    property real scroll: 0
    readonly property real maxScroll: Math.max(0, rows.length * rowHeight - viewHeight)

    // 头部图上某个点位对应的接触等级。
    // 数据源与下方列表**同一份**（rows）：有扫描结果是设备 16 路，没有则是设计稿
    // 示意值 —— 两边同源，同名字的电极在图上与列表里永远是同一个档位。
    // 图上那 16 个位置就是设备那 16 路，名字全部能对上；万一有对不上的点，
    // 取最近的几路做反距离加权、取最差档兜底
    function levelAtPoint(name, pointX, pointY) {
        var data = rows
        if (data.length === 0)
            return ""
        var exact = -1
        for (var i = 0; i < data.length; ++i) {
            if (data[i].name === name) {
                exact = i
                break
            }
        }
        if (exact >= 0)
            return data[exact].level

        // 就近估计：权重 1/(d²+1)，取权重最大的三路
        var best = []
        for (var c = 0; c < data.length; ++c) {
            var position = deviceXY[data[c].name]
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
            var level = data[best[k].index].level
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
        // 按下就发 'Z'，让设备开始上传阻抗；1.2 秒后由 scanTimer 读回结果并发 's' 停止
        Acq.begin_electrode_scan()
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

    // 只有扫描失败时才在标题下出现一行红字说明原因，平时不占位
    // （设计稿标题下方是空的，常态下不该有文字）
    Text {
        x: 14
        y: 32
        width: 300
        elide: Text.ElideRight
        visible: root.scanError.length > 0
        text: root.scanError
        color: Design.bad
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
            ToolTip.text: qsTr("向设备请求一次阻抗扫描，读取各导联的实测阻抗")
            ToolTip.delay: 400
        }
    }

    PanelDivider {
        x: 5
        y: 45
        width: 321
    }

    // ---------- 图例 ----------
    // 新设计稿是四项：良好=绿、一般=红、不良=橙、脱落=灰。
    Row {
        x: 64
        y: 54
        spacing: 20

        Repeater {
            model: [
                { label: "良好", state: "良好" },
                { label: "一般", state: "一般" },
                { label: "不良", state: "不良" },
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
    // 底盘：浅灰圆角矩形。头型单独一层叠在上面（见下），与设计稿分层一致
    Image {
        x: 14
        y: 89
        width: 303
        height: 260
        source: Design.assetRoot + "icons/head-panel.svg"
        fillMode: Image.Stretch
    }

    // 头型：圆头 + 鼻尖 + 两侧耳突，直接复用**地形图那张** head-outline.svg ——
    // 与「实时脑电地形图」是同一个头型资源，两边耳朵自然长得一样，不再各画各的。
    // 位置按新设计稿的头圆反推：目标圆心（面板坐标）(166.9,213.2)、半径 105.6；
    // head-outline.svg 里头圆圆心 (112,117)、半径 106，故缩放 k=105.6/106≈0.99623，
    // 图幅 224×223 → 223.2×222.2，左上角 = (166.9-112k, 213.2-117k) ≈ (55.3, 96.6)
    Image {
        x: 55.3
        y: 96.6
        width: 223.2
        height: 222.2
        source: Design.assetRoot + "icons/head-outline.svg"
        fillMode: Image.Stretch
    }

    Repeater {
        model: root.mapPoints

        delegate: Item {
            required property var modelData

            // 当前档位下这个位置是不是激活通道（4/8 档只有部分是）
            readonly property bool active: root.isActive(modelData.name)

            // 与下方列表同源（见 levelAtPoint）：同名电极在图上与列表里永远同一档位，
            // 不会再出现「图上一片绿、列表却有红黄」的对不上
            readonly property string pointLevel:
                root.levelAtPoint(modelData.name, modelData.cx, modelData.cy)

            // 激活：浅底 + 同色描边的环形电极，导联名嵌在环内
            Rectangle {
                visible: parent.active
                x: modelData.cx - 8.5
                y: modelData.cy - 8.5
                width: 17
                height: 17
                radius: 8.5
                color: Design.electrodeFill(parent.pointLevel)
                border.width: 1
                border.color: Design.impedanceColor(parent.pointLevel)
            }

            Text {
                visible: parent.active
                x: modelData.cx - 20
                y: modelData.cy - 8.5
                width: 40
                height: 17
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.name
                color: Design.impedanceColor(parent.pointLevel)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 7
            }

            // 未激活：只留一个浅灰圆点占位（设计稿 8 通道档的样子）
            Rectangle {
                visible: !parent.active
                x: modelData.cx - 3.5
                y: modelData.cy - 3.5
                width: 7
                height: 7
                radius: 3.5
                color: Design.electrodeIdle
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

                // 行分隔线（首行上方不画）。x 与面板里其它元素对齐（标题/头型图都是 14），
                // 不设 x 会从面板最左边 0 起画，看起来整条贴左
                PanelDivider {
                    x: 14
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
                    width: 168
                    height: 10
                    radius: 5
                    color: Qt.rgba(0, 0, 0, 0.07)
                }

                Rectangle {
                    x: 46
                    y: rowY + 10
                    width: 168 * modelData.ratio
                    height: 10
                    radius: 5
                    color: Design.impedanceColor(modelData.level)
                }

                // 数值列：右对齐。阻抗文案（如「122.4kΩ」）比原来 50px 的列宽，
                // 之前会溢出到右侧把等级文字压住 —— 这里加宽到 70 并右对齐，
                // 保证「kΩ」贴齐等级列左侧留出间隙，不再互相遮挡
                Text {
                    x: 218
                    y: rowY
                    width: 70
                    height: 28
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.text
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 292
                    y: rowY
                    width: 32
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
        // 轨道 114 高、滑块 24 高，可走 90px。起点必须对齐轨道顶 370，
        // 否则 scroll=0 时滑块顶比轨道顶低一截（滚不到最上面）、
        // scroll=maxScroll 时底边到 500 越过面板高 499（出框）
        y: 370 + (root.maxScroll > 0 ? root.scroll / root.maxScroll : 0) * 90
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
        visible: root.maxScroll > 0
    }
}
