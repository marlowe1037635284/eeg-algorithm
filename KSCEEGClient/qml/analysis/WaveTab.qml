import QtQuick
import QtQuick.Controls.Basic
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

    // 左上角图钉：直径、距两边的偏移，以及它占出的顶部间隙。波形整块下移一个
    // 间隙，图钉就不会压住最上面那一路波形
    readonly property int pinSize: 36
    readonly property int pinInset: 4
    readonly property int pinGap: pinInset + pinSize

    // 图钉点开后那块「标注放大器」：卡片宽、每行事件的高与行距
    readonly property int pinPopupWidth: 240
    readonly property int pinRowHeight: 38
    readonly property int pinRowSpacing: 10

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
        y: root.pinGap
        width: root.traceWidth
        height: parent.height - root.axisHeight - root.pinGap
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

    // ---------- 图钉 ----------
    // 卡片左上角的标记：浅灰圆底 + 图钉。波形已按 pinGap 整体下移，图钉落在
    // 顶部那段空出来的绘制区里。声明在 Flickable 之后，压在波形图上层。
    // 点它开合「标注放大器」，开着时圆底转浅蓝、描边与图钉字形转主色
    Rectangle {
        id: pin

        x: root.pinInset
        y: root.pinInset
        width: root.pinSize
        height: root.pinSize
        radius: root.pinSize / 2
        color: pinPopup.visible ? "#e5e9eb" : "#d9d9d9"
        border.width: 1
        border.color: pinPopup.visible ? Design.primary : "transparent"

        Image {
            anchors.centerIn: parent
            width: 19
            height: 19
            source: Design.assetRoot
                    + (pinPopup.visible ? "icons/icon-pin-active.svg"
                                        : "icons/icon-pin.svg")
            sourceSize: Qt.size(19, 19)
            fillMode: Image.PreserveAspectFit
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: pinPopup.visible ? pinPopup.close() : pinPopup.open()
        }
    }

    // ---------- 标注放大器 ----------
    // 图钉展开的那块：这一路记录里标过的事件，圆点色号与波形上的事件竖线同源
    //（都用 Analysis.events 里的 color），时间写墙钟、标签写当时选的那一个
    Popup {
        id: pinPopup

        // 贴在图钉右侧、与图钉顶大致齐平
        x: root.pinInset + root.pinSize + 10
        y: root.pinInset + 4
        width: root.pinPopupWidth
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: 12
            color: Qt.rgba(0xd9 / 255, 0xd9 / 255, 0xd9 / 255, 0.92)
        }

        contentItem: Item {
            implicitWidth: root.pinPopupWidth
            implicitHeight: 50 + eventList.height + 10

            Text {
                x: 16
                y: 13
                text: qsTr("标注放大器")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 16
            }

            Rectangle {
                x: 14
                y: 40
                width: parent.width - 28
                height: 1
                color: Design.divider
            }

            ListView {
                id: eventList

                x: 14
                y: 50
                width: parent.width - 28
                // 限高：事件标多了会一路往下铺，顶出窗口底部就没法看了
                height: Math.min(contentHeight, 264)
                spacing: root.pinRowSpacing
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                model: Analysis.events

                delegate: Rectangle {
                    required property var modelData

                    width: eventList.width
                    height: root.pinRowHeight
                    radius: 6
                    color: Qt.rgba(0, 0, 0, 0.06)

                    Rectangle {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        height: 12
                        radius: 6
                        // 颜色缺失时退回波形侧画竖线用的那个紫
                        color: modelData.color && modelData.color.length > 0
                               ? modelData.color : "#7c3aed"
                    }

                    Text {
                        x: 58
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.wallClock
                        color: "#333333"
                        font.family: Design.fontFamily
                        font.styleName: Design.styleMedium
                        font.pixelSize: 16
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }
                }
            }
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
            y: root.pinGap + index * root.laneHeight - view.contentY
            width: root.nameWidth
            height: root.laneHeight
            visible: y > root.pinGap - root.laneHeight
                     && y < root.height - root.axisHeight
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
            y: root.pinGap + index * root.laneHeight - view.contentY
            width: root.width
            height: root.laneHeight
            visible: y > root.pinGap - root.laneHeight
                     && y < root.height - root.axisHeight

            Rectangle {
                x: root.nameWidth
                y: 0
                width: root.traceWidth
                height: 1
                color: Qt.rgba(0, 0, 0, 0.08)
            }

            // 量程标注只画在**当前导联**那一条上：每一路都标一遍的话，
            // 16 路上百个数字糊成一片，反而看不出标尺是多少。
            // 竖直位置必须和波形对得上：波形在泳道里按 ±量程 取值，+N 落在泳道顶、
            // −N 落在泳道底、0 落在泳道中线（画图侧 centre = 泳道中线、half_lane = 半泳道）
            Text {
                x: root.nameWidth + root.traceWidth + 6
                y: 0
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
                y: parent.height - height
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
