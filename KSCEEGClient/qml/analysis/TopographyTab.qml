import QtQuick
import QtQuick.Effects
import KSCEEGClient

// 「数据分析与后处理」· 地形图页。
//
// 六张图：全频段 + δ/θ/α/β/γ，3 列 × 2 行。热力图本身由 C++ 画好（网格插值 +
// 配色是逐像素的事），这里负责头型底盘、按头型裁切、标题与色标。
//
// **头型裁切这一段与实时地形图面板是同一套做法**（TopographyPanel.qml）：
// C++ 出的是标准圆的热力图，直接贴会把鼻尖和耳突盖掉，看着就是个圆盘；
// 用 topo-circle.svg 当 alpha 遮罩裁一次，才是设计稿里那颗有鼻子有耳朵的头
Item {
    id: root

    // 六张图的顺序必须与 C++ 侧一致：0 = 全频段，1..5 = δ/θ/α/β/γ
    readonly property var bands: [""].concat(Analysis.bandKeys)
    readonly property int mapSize: 232
    readonly property int columnCount: 3

    // ---------- 顶部：说明 + 色标 ----------
    Text {
        x: 0
        y: 2
        text: qsTr("各频段绝对功率（Welch PSD 在所选片段上的均值）")
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 13
    }

    Item {
        id: colorbarArea

        anchors.right: parent.right
        y: 0
        width: 300
        height: 40

        Text {
            x: 0
            y: 0
            text: qsTr("μV²/Hz")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }

        // 色值一律从 Acq.topoPalette 取 —— 与 C++ 画热力图是同一份表。
        // 停靠点位置按 C++ 的 palette_lut() 等分，两边口径一致
        Rectangle {
            id: colorBar

            x: 0
            y: 18
            width: parent.width
            height: 14

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
        }

        // 六张图**各按自身峰值归一化**，所以色标右端写的是「峰值」而不是某个
        // 数值：写死一个数会在五张图上都是错的。每张图自己的峰值功率列在
        // 标题下方，需要精确读数时看那里
        Text {
            x: 0
            y: 34
            text: qsTr("0")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }

        Text {
            anchors.right: parent.right
            y: 34
            text: qsTr("峰值")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }

    // ---------- 六张地形图 ----------
    Repeater {
        model: 6

        delegate: Item {
            required property int index

            readonly property int column: index % root.columnCount
            readonly property int row: Math.floor(index / root.columnCount)
            readonly property var stat: Analysis.topoStats[index] !== undefined
                                        ? Analysis.topoStats[index] : ({})

            readonly property real columnWidth: root.width / root.columnCount

            x: column * columnWidth
            y: 44 + row * 320
            width: columnWidth
            height: 310

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0
                text: parent.stat.label !== undefined ? parent.stat.label : ""
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 17
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                text: parent.stat.peakElectrode !== undefined
                      ? qsTr("峰值 %1 · %2 μV²/Hz")
                            .arg(parent.stat.peakElectrode).arg(parent.stat.peakValue)
                      : ""
                color: Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
            }

            Image {
                id: headBase
                anchors.horizontalCenter: parent.horizontalCenter
                y: 46
                width: root.mapSize
                height: root.mapSize
                source: Design.assetRoot + "icons/head-outline.svg"
                fillMode: Image.Stretch
            }

            // 热力图源图：C++ 出的是标准圆，圆比头型大一圈，直接贴会盖掉鼻尖和耳突。
            // 所以隐藏源图，交给下面按头型裁切
            Image {
                id: heatmap
                anchors.horizontalCenter: parent.horizontalCenter
                y: 46
                width: root.mapSize
                height: root.mapSize
                fillMode: Image.Stretch
                cache: false
                asynchronous: false
                smooth: true
                visible: false
                source: "image://analysis/topo/"
                        + (parent.index === 0 ? "full" : root.bands[parent.index])
                        + "/" + Analysis.revision
            }

            // 遮罩源：topo-circle.svg 头型内部 alpha 恒为 1、外部为 0，
            // 正是 MultiEffect 要的 alpha 遮罩。layer.enabled 是取纹理的前提
            Image {
                id: headMask
                anchors.horizontalCenter: parent.horizontalCenter
                y: 46
                width: root.mapSize
                height: root.mapSize
                source: Design.assetRoot + "icons/topo-circle.svg"
                fillMode: Image.Stretch
                visible: false
                layer.enabled: true
            }

            MultiEffect {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 46
                width: root.mapSize
                height: root.mapSize
                source: heatmap
                maskEnabled: true
                maskSource: headMask
            }
        }
    }

    // 还没算出结果时的说明
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 300
        visible: Analysis.topoStats.length === 0
        text: Analysis.busy ? qsTr("正在计算…") : qsTr("没有可显示的地形图")
        color: Design.textMuted
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }
}
