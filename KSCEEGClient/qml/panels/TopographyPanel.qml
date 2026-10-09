import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import KSCEEGClient

// 「实时脑电地形图」面板。
// 设计稿里位于画板 (1572,150)，尺寸 331×590；本文件坐标 = 设计坐标 - (1572,150)。
Item {
    id: root

    // 地形图上的电极：圆形标记 16×16，标签字号 8，标签竖直居中于圆点。
    // 点位与「电极贴合状态」面板（ElectrodePanel.mapPoints）**同一套 16 路**：
    // 名字一致，位置也一致 —— 同一个头型、同一套标准 10-20 归一化坐标
    // （相对头圆心、按头半径归一化），只是本面板头圆为圆心 (166,178)、半径 106。
    // x/y = 圆心 − 8（16×16 圆点左上角）；labelX/labelY = 圆心 − (6.5|4.5) / −14，
    // 使 8px 名称在圆点上居中
    readonly property var electrodeTable: [
        { name: "Fp1", x: 101.4, y: 81.7,  labelX: 102.9, labelY: 75.7 },
        { name: "Fp2", x: 214.6, y: 81.7,  labelX: 216.1, labelY: 75.7 },
        { name: "F7",  x: 68.6,  y: 118.0, labelX: 72.1,  labelY: 112.0 },
        { name: "F3",  x: 111.5, y: 125.9, labelX: 115.0, labelY: 119.9 },
        { name: "Fz",  x: 158.0, y: 125.4, labelX: 161.5, labelY: 119.4 },
        { name: "F4",  x: 204.4, y: 125.9, labelX: 207.9, labelY: 119.9 },
        { name: "F8",  x: 247.4, y: 118.0, labelX: 250.9, labelY: 112.0 },
        { name: "M1",  x: 54.1,  y: 169.3, labelX: 57.6,  labelY: 163.3 },
        { name: "C3",  x: 111.6, y: 168.9, labelX: 115.1, labelY: 162.9 },
        { name: "Cz",  x: 158.0, y: 170.0, labelX: 161.5, labelY: 164.0 },
        { name: "C4",  x: 204.3, y: 168.9, labelX: 207.8, labelY: 162.9 },
        { name: "M2",  x: 261.9, y: 169.3, labelX: 265.4, labelY: 163.3 },
        { name: "P3",  x: 111.7, y: 211.2, labelX: 115.2, labelY: 205.2 },
        { name: "P4",  x: 204.2, y: 211.2, labelX: 207.7, labelY: 205.2 },
        { name: "O1",  x: 121.2, y: 262.8, labelX: 124.7, labelY: 256.8 },
        { name: "O2",  x: 194.7, y: 262.8, labelX: 198.2, labelY: 256.8 }
    ]

    // 只画当前档位（4/8/16）激活的电极 —— 与「电极贴合状态」面板同一套规则
    // （Design.activeElectrodes 与 C++ 侧 display_channel_indices 同源）。
    // 16 档返回空数组，表示全部显示
    readonly property var electrodes: {
        var active = Design.activeElectrodes(Acq.channelCount)
        if (active.length === 0)
            return electrodeTable
        var out = []
        for (var i = 0; i < electrodeTable.length; ++i) {
            if (active.indexOf(electrodeTable[i].name) >= 0)
                out.push(electrodeTable[i])
        }
        return out
    }

    // 设计稿里有 3 个电极套了一圈白环（当前关注点），落在额区中线那三路 F3 / Fz / F4 上。
    // 只给当前档位里确实显示的电极加环，未显示的电极不留空环。
    // x/y = 电极 16×16 圆点左上角 − 2，环 20×20 正好套住圆点
    readonly property var highlightRings: {
        var names = ["F3", "Fz", "F4"]
        var out = []
        for (var i = 0; i < electrodes.length; ++i) {
            if (names.indexOf(electrodes[i].name) >= 0)
                out.push({ x: electrodes[i].x - 2, y: electrodes[i].y - 2 })
        }
        return out
    }

    // 色标条**不再自己抄一份色值**，而是取 Acq.topoPalette —— 与 C++ 画热力图
    // 用的是同一张表。设计稿那 16 段色值和实际渲染用的色标是两套，抄任何一套
    // 都会与图对不上，而色标是按图读值的唯一依据。
    // 频段选择块：range 原本五块全写成 "0.5-4"（占位），换成真实边界；
    // band 字段与 C++ 的 band_from_name 认的取值一一对应，写错那边会直接忽略
    readonly property var bandSelectors: [
        { band: "delta", letter: "δ", range: "0.5-4", boxX: 26,  letterX: 45,  rangeX: 33 },
        { band: "theta", letter: "θ", range: "4-8",   boxX: 84,  letterX: 103, rangeX: 91 },
        { band: "alpha", letter: "α", range: "8-13",  boxX: 142, letterX: 161, rangeX: 149 },
        { band: "beta",  letter: "β", range: "13-30", boxX: 199, letterX: 218, rangeX: 206 },
        { band: "gamma", letter: "γ", range: "30-45", boxX: 258, letterX: 278, rangeX: 265 }
    ]

    // 四项统计由 C++ 侧算好并格式化（topoStats 固定四项），这边不做二次加工。
    // 取不到时统一显示短横，免得界面上出现 "undefined"
    readonly property var metrics: {
        var stats = Acq.topoStats
        if (!stats || stats.length !== 4)
            stats = ["—", "—", "—", "—"]
        return [
            { label: qsTr("峰值电极"), value: stats[0] },
            { label: qsTr("峰值功率(μV²/Hz)"), value: stats[1] },
            { label: qsTr("全脑均值(μV²/Hz)"), value: stats[2] },
            { label: qsTr("枕/额比"), value: stats[3] },
            { label: qsTr("时窗"), value: "2.0s" }
        ]
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
        y: 6
        text: qsTr("实时脑电地形图")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    PanelDivider {
        x: 5
        y: 41
        width: 321
    }

    // 头型底盘（设计稿导出的矢量：一个圆 + 顶部鼻尖 + 两侧耳突，带主色描边）。
    //
    // 用**空白**的 head-outline.svg 而不是 topo-circle.svg：后者自带一条彩虹渐变，
    // 是设计稿里那张「示意地形图」。而热力图是按同一个头型掩膜裁的、且完全不透明，
    // 所以只要热力图在，底盘就被整张盖住 —— 也就是说这块底盘**只在还没出图的时候
    // 才看得见**。之前贴 topo-circle.svg，等于刚进界面、一条数据都没有，
    // 就已经顶着一颗画满颜色的头，看着像已经有地形图了。
    // 换成空白头型后，出图前是一颗干净的空头，出图后照旧被热力图盖住
    Image {
        id: topoBase
        x: 54
        y: 61
        width: 224
        height: 223
        source: Design.assetRoot + "icons/head-outline.svg"
        fillMode: Image.Stretch
    }

    // 热力图源图。C++ 侧画出来的是**标准圆**（原设计想按头型掩膜裁，但那边
    // 的掩膜是网格坐标下的圆、会被裁成八边形，照它裁会变成方块，只好退成画圆）。
    // 所以这里不能直接贴出来 —— 圆比头型大一圈，会把鼻尖和耳突盖掉，
    // 看上去就是个纯圆盘。改为隐藏源图，交给下面的 MultiEffect 按头型裁切。
    // revision 变化只是用来制造新 URL，否则 Image 会按 URL 缓存，图永远不更新
    Image {
        id: topoHeatmap
        x: 54
        y: 61
        width: 224
        height: 223
        fillMode: Image.Stretch
        cache: false
        asynchronous: false
        smooth: true
        visible: false
        source: "image://topography/render/" + Acq.topoRevision
    }

    // 遮罩源用同一张 topo-circle.svg：它头型内部 alpha 恒为 1、外部为 0，
    // 正是 MultiEffect 要的 alpha 遮罩。layer.enabled 是取纹理的前提。
    Image {
        id: topoMask
        x: 54
        y: 61
        width: 224
        height: 223
        source: Design.assetRoot + "icons/topo-circle.svg"
        fillMode: Image.Stretch
        visible: false
        layer.enabled: true
    }

    // 按头型裁切后的热力图。**必须夹在底盘与白环/电极点之间**：
    // 盖在底盘之上才有底色可叠，压在电极点之下才不会把导联名挡住
    MultiEffect {
        x: 54
        y: 61
        width: 224
        height: 223
        source: topoHeatmap
        maskEnabled: true
        maskSource: topoMask
    }

    // 关注点白环（画在圆点下面）
    Repeater {
        model: root.highlightRings

        delegate: Rectangle {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: 20
            height: 20
            radius: 10
            color: "transparent"
            border.width: 1
            border.color: "#ffffff"
        }
    }

    Repeater {
        model: root.electrodes

        delegate: Item {
            required property var modelData

            Rectangle {
                x: modelData.x
                y: modelData.y
                width: 16
                height: 16
                radius: 8
                color: "#ffffff"
                border.width: 1
                border.color: "#424242"
            }

            Text {
                x: modelData.labelX
                y: modelData.labelY
                width: 30
                height: 28
                verticalAlignment: Text.AlignVCenter
                text: modelData.name
                color: "#424242"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 8
            }
        }
    }

    // 「峰值」小徽标
    Image {
        x: 168
        y: 102
        width: 41
        height: 22
        source: Design.assetRoot + "icons/peak-badge.svg"
        fillMode: Image.Stretch
    }

    Text {
        x: 177
        y: 103
        width: 24
        height: 16
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: qsTr("峰值")
        color: "#ffffff"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- 色标 ----------
    Text {
        x: 141
        y: 286
        text: qsTr("μV²/Hz")
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // 色值一律从 Acq.topoPalette 取 —— 与 C++ 画热力图是同一份表。
    // 设计稿的色标是**贯穿整宽的连续渐变**（刻度 0 / 中值 / 最大值都落在同一条上），
    // 原来写成 7 个 17px 的离散方块，只铺到一半宽，和刻度根本对不齐。
    // 这里按 C++ LUT 的停靠点位置（0、1/6 … 1）铺 7 个停靠点做横向渐变，
    // 停靠点之间的插值方式与 C++ 的 palette_lut() 一致
    Rectangle {
        id: colorBar
        x: 26
        y: 308
        width: 276
        height: 17

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0000; color: Acq.topoPalette[0] }
            GradientStop { position: 0.1667; color: Acq.topoPalette[1] }
            GradientStop { position: 0.3333; color: Acq.topoPalette[2] }
            GradientStop { position: 0.5000; color: Acq.topoPalette[3] }
            GradientStop { position: 0.6667; color: Acq.topoPalette[4] }
            GradientStop { position: 0.8333; color: Acq.topoPalette[5] }
            GradientStop { position: 1.0000; color: Acq.topoPalette[6] }
        }

        // 刻度。右端**不能写死**：图是按每帧峰值归一化配色的，写死的话
        // 数字和实际配色对不上，读出来的值就是错的。
        // 三个刻度分别贴着色条左端 / 居中 / 右端，才和色条是同一条标尺
        Text {
            anchors.left: parent.left
            anchors.top: parent.bottom
            anchors.topMargin: -1
            text: "0"
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.bottom
            anchors.topMargin: -1
            text: (Acq.topoScaleMax / 2).toFixed(1)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Text {
            anchors.right: parent.right
            anchors.top: parent.bottom
            anchors.topMargin: -1
            text: Acq.topoScaleMax.toFixed(1)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // ---------- 频段选择块 ----------
    Repeater {
        model: root.bandSelectors

        delegate: Item {
            required property var modelData
            required property int index

            // 绑到 C++ 的 topoBand 而不是自己存一份选中态：切换频段后由
            // C++ 侧确认的结果说了算，两边不会各说各话
            readonly property bool active: Acq.topoBand === modelData.band

            Rectangle {
                x: modelData.boxX
                y: 353
                width: 48.74
                height: 51
                radius: 10
                color: parent.active ? Design.primarySoft : Qt.rgba(0xc9 / 255, 0xc9 / 255, 0xc9 / 255, 0.29)
                border.width: 1
                border.color: parent.active ? Design.primary : Qt.rgba(0xa3 / 255, 0xa3 / 255, 0xa3 / 255, 0.27)
            }

            Text {
                x: modelData.letterX
                y: 356
                width: 14
                height: 22
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.letter
                color: parent.active ? Design.primary : Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            Text {
                x: modelData.rangeX
                y: 378
                width: 34
                height: 19
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.range
                color: parent.active ? Design.primary : Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                x: modelData.boxX
                y: 353
                width: 48.74
                height: 51
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Acq.topoBand = modelData.band

                ToolTip.visible: containsMouse
                ToolTip.text: qsTr("%1 频段（%2 Hz）").arg(modelData.letter).arg(modelData.range)
                ToolTip.delay: 400
            }
        }
    }

    // ---------- 指标列表 ----------
    Repeater {
        model: root.metrics

        delegate: Item {
            required property var modelData
            required property int index

            readonly property int rowY: 421 + Math.round(32.75 * index)

            // 注意：delegate 必须给宽度，否则里面的 anchors.right: parent.right
            // 会锚到一个 0 宽的 Item 上，数值文字会跑到面板外面去。
            y: rowY
            width: root.width
            height: 22

            Text {
                x: 26
                y: 0
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: modelData.label
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 24
                y: 0
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: modelData.value
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }
    }
}
