import QtQuick
import KSCEEGClient

// 「数据分析与后处理」· 统计页。
//
// 三块：左上通道相关性矩阵、右上五频段绝对功率柱、下方每通道的频带占比小柱。
// 只有相关性矩阵交给 C++ 画（16×16 = 256 个小格，画在 QML 里是 256 个矩形，
// 而它每次重算都要整体换掉）；柱状图用 Rectangle —— 十几根柱子而已，
// 用 QML 画随手就能加悬停提示，也随界面缩放不发虚
Item {
    id: root

    readonly property int matrixSize: 380
    readonly property int barAreaTop: 470
    readonly property int miniRows: 2
    readonly property int miniColumns: 8

    // ---------- 标题与图例 ----------
    Text {
        x: 0
        y: 0
        text: qsTr("通道相关性矩阵")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleMedium
        font.pixelSize: 17
    }

    Row {
        anchors.right: parent.right
        y: 2
        spacing: 16

        Repeater {
            model: Analysis.bandKeys

            delegate: Row {
                required property int index

                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 12
                    height: 12
                    radius: 3
                    color: Analysis.bandColors[index]
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Analysis.bandNames[index]
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 13
                }
            }
        }
    }

    // ---------- 相关性矩阵 ----------
    // 左边与下面各留一条格子，写通道名。不留的话标签会压在矩阵上，
    // 而矩阵是满格的色块，压上去就分不清哪一格对应哪一路
    readonly property int matrixLeft: 44
    readonly property int matrixTop: 34

    Image {
        x: root.matrixLeft
        y: root.matrixTop
        width: root.matrixSize
        height: root.matrixSize
        fillMode: Image.Stretch
        cache: false
        asynchronous: false
        source: "image://analysis/correlation/" + Analysis.revision
    }

    Repeater {
        model: Analysis.channelStats

        delegate: Item {
            required property var modelData
            required property int index

            // 格宽 = 矩阵边长 / 通道数，与 C++ 那边同一个算法，标签和格子必然对齐
            readonly property real cell: root.matrixSize / Math.max(1, Analysis.channelCount)

            Text {
                x: 0
                y: root.matrixTop + index * parent.cell + parent.cell / 2 - height / 2
                width: root.matrixLeft - 6
                horizontalAlignment: Text.AlignRight
                text: modelData.name
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 10
            }

            Text {
                x: root.matrixLeft + index * parent.cell + parent.cell / 2 - width / 2
                y: root.matrixTop + root.matrixSize + 4
                text: modelData.name
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 10
            }
        }
    }

    // ---------- 五频段绝对功率 ----------
    // 高度取**整段全通道平均**的功率谱密度（µV²/Hz），与报告页的占比同源
    Item {
        id: bandChart

        readonly property int bandCount: Analysis.bandDistribution.length
        // 右侧可用宽度。五根柱子铺满整个剩余宽度的话柱间距会拉到 160 像素，
        // 五根孤零零的柱子散在 800 像素里，看着不像一组数据 —— 封顶后居中
        readonly property real available:
            Math.max(200, root.width - root.matrixLeft - root.matrixSize - 30)

        x: root.matrixLeft + root.matrixSize + 30 + (available - width) / 2
        y: root.matrixTop
        width: Math.min(640, available)
        height: root.matrixSize

        readonly property real peak: {
            var maximum = 0
            const rows = Analysis.bandDistribution
            for (var i = 0; i < rows.length; ++i)
                maximum = Math.max(maximum, rows[i].mean)
            return maximum > 0 ? maximum : 1
        }

        Repeater {
            model: Analysis.bandDistribution

            delegate: Item {
                required property var modelData
                required property int index

                readonly property real slot: bandChart.width / Math.max(1, bandChart.bandCount)
                readonly property real barWidth: Math.min(72, slot * 0.42)
                readonly property real barHeight:
                    Math.max(4, (bandChart.height - 60) * modelData.mean / bandChart.peak)

                x: slot * index + (slot - barWidth) / 2
                y: 0
                width: barWidth
                height: bandChart.height

                // 柱身从底往上长。圆角只在顶端 —— 底端是基线，圆角会看着浮起来
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: bandChart.height - 40 - parent.barHeight
                    width: parent.barWidth
                    height: parent.barHeight
                    radius: Math.min(18, parent.barWidth / 2)
                    color: modelData.color
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: bandChart.height - 34
                    text: modelData.label
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: bandChart.height - 16
                    text: (modelData.ratio * 100).toFixed(1) + "%"
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }
        }
    }

    // ---------- 每通道频带占比 ----------
    Text {
        x: 0
        y: root.barAreaTop - 26
        text: qsTr("各通道频带占比")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleMedium
        font.pixelSize: 15
    }

    Grid {
        id: miniGrid

        x: 0
        y: root.barAreaTop
        columns: root.miniColumns
        spacing: 6

        readonly property real cellWidth: (root.width - spacing * (columns - 1)) / columns

        Repeater {
            model: Analysis.channelBands

            delegate: Item {
                required property var modelData
                required property int index

                readonly property bool active: index === Analysis.currentChannel

                // 用 id 而不是 parent：Repeater 的 delegate 会被挂到 Repeater 的
                // 父项上，parent 在静态分析里指向 Repeater，读它的属性拿不到值
                width: miniGrid.cellWidth
                height: 96

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: parent.active ? Design.primarySoft
                                         : Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17)
                    border.width: parent.active ? 1 : 0
                    border.color: Design.primary
                }

                // 五根小柱。纵轴不用真实功率而用**占比**：16 路之间绝对功率能差
                // 几十倍，不归一化的话除了最亮的一路，其余全是贴地的一条线
                Item {
                    id: miniBars

                    x: 8
                    y: 12
                    width: parent.width - 16
                    height: 52

                    readonly property real peak: {
                        var maximum = 0
                        for (var i = 0; i < modelData.ratio.length; ++i)
                            maximum = Math.max(maximum, modelData.ratio[i])
                        return maximum > 0 ? maximum : 1
                    }

                    Repeater {
                        model: modelData.ratio

                        delegate: Rectangle {
                            required property real modelData
                            required property int index

                            readonly property real slot: miniBars.width / 5

                            x: slot * index + slot * 0.2
                            y: miniBars.height - height
                            width: slot * 0.6
                            height: Math.max(3, miniBars.height * modelData / miniBars.peak)
                            radius: Math.min(4, width / 2)
                            color: Analysis.bandColors[index]
                        }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 70
                    text: modelData.name
                    color: parent.active ? Design.primary : Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: parent.active ? Design.styleMedium : Design.styleRegular
                    font.pixelSize: 13
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
