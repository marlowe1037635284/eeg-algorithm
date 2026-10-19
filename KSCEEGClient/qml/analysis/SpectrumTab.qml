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
            // 第三参数是物理像素倍率，频谱按逻辑像素出图（曲线是矢量的，放大后由
            // Image 自身平滑），故显式传 1.0 —— QML 不会替 C++ 的默认参数兜底
            Analysis.set_view_size(plotWidth, plotHeight, 1.0)
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
        // revision 为 0（无结果 / 已 close）时不请求，避免 provider 返回空图报警
        source: Analysis.revision > 0
                ? "image://analysis/spectrum/" + Analysis.revision
                : ""
    }

    // ---------- 频段名（δ θ α β γ）----------
    // 写在各自色带的正中。位置按频段边界算，边界来自 C++（bandRanges）——
    // QML 里再抄一套边界就成了第四处副本，将来改一处忘一处也不会报错
    Repeater {
        model: Analysis.bandRanges

        delegate: Text {
            required property var modelData

            readonly property real center:
                Math.min(Math.max((modelData.low + modelData.high) / 2,
                                  Analysis.spectrumFMin), Analysis.spectrumFMax)

            x: root.axisWidth + root.plotWidth * (center - Analysis.spectrumFMin)
               / Math.max(1, Analysis.spectrumFMax - Analysis.spectrumFMin) - width / 2
            y: 6
            text: modelData.letter
            color: Design.primary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 13
        }
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

    // ---------- X 轴（Hz）----------
    // 10 Hz 一档，两端补上坐标轴的真实首尾（0.5Hz 与 45Hz）—— 首尾都不是 10 的
    // 整数倍，光按步进铺的话看不出横轴从哪开始、到哪结束
    Repeater {
        model: {
            var ticks = []
            const minimum = Analysis.spectrumFMin
            const maximum = Analysis.spectrumFMax
            ticks.push(minimum)
            for (var hz = Math.ceil(minimum / 10) * 10; hz < maximum - 0.001; hz += 10)
                ticks.push(hz)
            ticks.push(maximum)
            return ticks
        }

        delegate: Text {
            required property real modelData

            readonly property real labelX:
                root.axisWidth + root.plotWidth * (modelData - Analysis.spectrumFMin)
                / Math.max(1, Analysis.spectrumFMax - Analysis.spectrumFMin) - width / 2

            // 首尾两个字会被画到绘制区外面，夹回边界内（左端左对齐、右端右对齐）
            x: Math.max(root.axisWidth,
                        Math.min(labelX, root.axisWidth + root.plotWidth - width))
            y: root.plotHeight + 4
            text: (modelData % 1 === 0 ? modelData : modelData.toFixed(1)) + "Hz"
            color: Qt.rgba(0, 0, 0, 0.40)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }
}
