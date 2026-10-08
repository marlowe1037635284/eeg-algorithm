import QtQuick
import KSCEEGClient

// 「数据分析与后处理」· 波形页。
//
// 波形本体由 C++ 画（Analysis 的 wave 图）：16 路 × 上千个点走 QML 的 Canvas
// 一帧要上百毫秒，界面会卡成幻灯片 —— 与实时波形、回放预览是同一个理由
//（见 bridgeimageproviders.h）。
//
// 这里只摆静态的东西：通道名、量程标注、时间轴刻度。
// **图的纵向尺寸是「通道数 × 泳道高」，比视口高** —— 用 Flickable 滚动着看，
// 而不是把滚动位置告诉 C++ 重画：滚动不重算，一帧都不用等
Item {
    id: root

    // 左侧通道名列宽、右侧量程标注列宽、底部时间轴高
    readonly property int nameWidth: 56
    readonly property int rangeWidth: 62
    readonly property int axisHeight: 26
    readonly property int laneHeight: Analysis.laneHeight
    readonly property int lanes: Math.max(1, Analysis.channelCount)
    readonly property int traceWidth: Math.max(64, width - nameWidth - rangeWidth)

    // 绘制区（不含时间轴）作为波形图的像素尺寸报给 C++
    function report_size() {
        if (traceWidth > 0 && height > axisHeight)
            Analysis.set_view_size(traceWidth, Math.round(height - axisHeight))
    }
    onTraceWidthChanged: report_size()
    onHeightChanged: report_size()
    Component.onCompleted: report_size()

    // 通道条上选了别的导联时滚过去。不这么做的话，点了「C4」却还在看 Fp1
    //（当前导联的配色变了、位置没变），比不动更让人困惑
    onCurrentChannelRowChanged: scrollToCurrent()

    readonly property int currentChannelRow: Analysis.currentChannel

    function scrollToCurrent() {
        const centre = (Analysis.currentChannel + 0.5) * laneHeight
        const target = Math.max(0, Math.min(view.contentHeight - view.height,
                                            centre - view.height / 2))
        view.contentY = target
    }

    // 绘图区底板（设计稿 003：1272×682、圆角 12、#D9D9D9 35%）。波形图由 C++
    // 画成透明底，没有这层底板波形就浮在舞台底色上；它同时兜住左侧通道名列与
    // 底部秒数刻度，是整个波形页的范围
    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Design.panelFill
    }

    Flickable {
        id: view

        x: root.nameWidth
        y: 0
        width: root.traceWidth
        height: parent.height - root.axisHeight
        contentWidth: width
        contentHeight: root.lanes * root.laneHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // 没有滚轮时也要能拖：波形本身不响应拖拽，拖它就是滚动
        interactive: contentHeight > height

        Image {
            x: 0
            y: 0
            width: view.width
            height: root.lanes * root.laneHeight
            fillMode: Image.Stretch
            cache: false
            asynchronous: false
            // revision 为 0 表示还没有结果（未算出 / 已 close）。这时若仍按
            // "wave/0" 去取图，provider 只能返回空图，Qt 就打
            // "Failed to get image from provider"。空串 = 不请求
            source: Analysis.revision > 0
                    ? "image://analysis/wave/" + Analysis.revision
                    : ""
        }
    }

    // ---------- 通道名 ----------
    // 与波形同一个泳道中心：泳道高由 C++ 与 QML 共用（Analysis.laneHeight），
    // 两处各写一个数就会错行
    Repeater {
        model: root.lanes

        delegate: Item {
            required property int index

            x: 0
            y: index * root.laneHeight - view.contentY
            width: root.nameWidth
            height: root.laneHeight
            visible: y > -root.laneHeight && y < view.height
            clip: true

            Text {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                text: Analysis.channelNames[index]
                color: index === Analysis.currentChannel
                       ? Design.waveCurrent
                       : Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: index === Analysis.currentChannel
                                ? Design.styleMedium : Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Analysis.currentChannel = index
            }
        }
    }

    // ---------- 泳道分隔线与量程标注 ----------
    Repeater {
        model: root.lanes

        delegate: Item {
            required property int index

            x: 0
            y: index * root.laneHeight - view.contentY
            width: root.width
            height: root.laneHeight
            visible: y > -root.laneHeight && y < view.height

            Rectangle {
                x: root.nameWidth
                y: 0
                width: root.traceWidth
                height: 1
                color: Qt.rgba(0, 0, 0, 0.08)
            }

            // 量程标注只画在**当前导联**那一条上：每一路都标一遍的话，
            // 16 路上百个数字糊成一片，反而看不出标尺是多少
            Text {
                x: root.nameWidth + root.traceWidth + 6
                y: parent.height / 2 - height
                visible: index === Analysis.currentChannel
                text: "+" + Math.round(Analysis.waveRangeUV)
                color: Design.waveCurrent
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 11
            }

            Text {
                x: root.nameWidth + root.traceWidth + 6
                y: parent.height / 2 - height / 2
                visible: index === Analysis.currentChannel
                text: "0"
                color: Design.waveCurrent
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 11
            }

            Text {
                x: root.nameWidth + root.traceWidth + 6
                y: parent.height / 2 + 2
                visible: index === Analysis.currentChannel
                text: "−" + Math.round(Analysis.waveRangeUV)
                color: Design.waveCurrent
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 11
            }
        }
    }

    // ---------- 时间轴 ----------
    // 写的是**窗口内的相对秒数**（0.0s 不画）：它标的是横轴刻度，拖窗口时要跟着
    // 窗口一起走才对得上波形；记录内的绝对时刻交给底部的整段导航条去标
    Repeater {
        model: 4

        delegate: Text {
            required property int index

            readonly property real seconds:
                Analysis.windowSeconds * (index + 1) / 4

            // 末刻度不居中：它的中心就在轨迹右端，半个字宽会探到绘制区外面
            x: root.nameWidth + Math.min(root.traceWidth * (index + 1) / 4 - width / 2,
                                         root.traceWidth - 12 - width)
            y: root.height - root.axisHeight + 4
            text: seconds.toFixed(1) + "s"
            color: Qt.rgba(0, 0, 0, 0.40)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }
    }
}
