import QtQuick
import KSCEEGClient

// 「数据分析与后处理」· 频谱页。
//
// 曲线与频带底色由 C++ 画（幅频两条轴都要按数据换算，画在 JS 里既慢又要
// 维护第二套坐标映射）；刻度字留在这里 —— 它们是静态文字，画进图里等于
// 每次重算都要重排一遍字
Item {
    id: root

    readonly property int axisWidth: 46
    readonly property int axisHeight: 24
    readonly property int plotWidth: Math.max(64, width - axisWidth)
    readonly property int plotHeight: Math.max(64, height - axisHeight)

    function report_size() {
        if (plotWidth > 0 && plotHeight > 0)
            Analysis.set_view_size(plotWidth, plotHeight)
    }
    onPlotWidthChanged: report_size()
    onPlotHeightChanged: report_size()
    Component.onCompleted: report_size()

    Image {
        x: root.axisWidth
        y: 0
        width: root.plotWidth
        height: root.plotHeight
        fillMode: Image.Stretch
        cache: false
        asynchronous: false
        source: "image://analysis/spectrum/" + Analysis.revision
    }

    // ---------- Y 轴（功率谱密度，dB）----------
    Repeater {
        model: 5

        delegate: Text {
            required property int index

            readonly property real db:
                Analysis.spectrumDbMax
                - (Analysis.spectrumDbMax - Analysis.spectrumDbMin) * index / 4

            x: 0
            y: root.plotHeight * index / 4 - height / 2
            width: root.axisWidth - 8
            horizontalAlignment: Text.AlignRight
            text: Math.round(db)
            color: Qt.rgba(0, 0, 0, 0.40)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }

    Text {
        x: 0
        y: -20
        width: root.axisWidth - 8
        horizontalAlignment: Text.AlignRight
        text: qsTr("dB")
        color: Qt.rgba(0, 0, 0, 0.40)
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    // ---------- X 轴（Hz）----------
    // 刻度按 10 Hz 一档铺，末档落在奈奎斯特或 60 Hz（哪个更小取哪个）
    Repeater {
        model: {
            var ticks = []
            const maximum = Analysis.spectrumFMax
            for (var hz = 0; hz <= maximum + 0.001; hz += 10)
                ticks.push(hz)
            if (ticks.length === 0 || ticks[ticks.length - 1] < maximum - 0.5)
                ticks.push(maximum)
            return ticks
        }

        delegate: Text {
            required property real modelData

            x: Math.min(root.axisWidth + root.plotWidth * modelData
                        / Math.max(1, Analysis.spectrumFMax) - width / 2,
                        root.axisWidth + root.plotWidth - 24)
            y: root.plotHeight + 4
            text: Math.round(modelData) + "Hz"
            color: Qt.rgba(0, 0, 0, 0.40)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }

    // ---------- 当前导联标记 ----------
    Text {
        x: root.axisWidth + 8
        y: 6
        text: Analysis.channelNames[Analysis.currentChannel] + qsTr(" · 功率谱密度")
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleMedium
        font.pixelSize: 13
    }
}
