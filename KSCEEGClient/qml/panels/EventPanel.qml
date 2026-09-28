import QtQuick
import KSCEEGClient

// 「事件标注」面板。
// 设计稿里位于画板 (107,738)，尺寸 331×296；本文件坐标 = 设计坐标 - (107,738)。
Item {
    id: root

    // 事件源在 C++ 侧（Acq.events）。原来这里有一份写死的 ListModel，
    // 六条事件的时间全是 16:13:05、偏移全是 +3s；而波形面板上那两条事件竖线
    // 又完全是另一套硬编码坐标 —— 两处互不相干。现在两边共用 Acq.events，
    // 标记一次事件会在列表和波形上同时出现
    readonly property var eventModel: Acq.events
    property int eventCount: Acq.eventCount

    // 事件列表可视 3 行，超出部分滚轮滚动（设计稿画了 3 行 + 一根滚动条）
    property real eventScroll: 0
    readonly property int eventRowHeight: 44
    readonly property int eventViewHeight: 132
    readonly property real eventMaxScroll: Math.max(0, eventCount * eventRowHeight - eventViewHeight)

    function clearEvents() {
        Acq.clear_events()
    }

    // 时间戳交给 C++ 取（它才有采集计时与墙钟），这里只传标签
    function addEvent(label) {
        Acq.add_event(label)
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
        y: 13
        text: qsTr("事件标注")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 事件条数徽标
    Rectangle {
        x: 92
        y: 17
        width: 20
        height: 20
        radius: 10
        color: "#e0e0e0"

        Text {
            anchors.centerIn: parent
            text: root.eventCount
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // 清空按钮
    Rectangle {
        x: 245
        y: 12
        width: 67
        height: 29
        radius: 12
        color: clearMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("清空")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        MouseArea {
            id: clearMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clearEvents()
        }
    }

    PanelDivider {
        x: 5
        y: 52
        width: 321
    }

    // 手动标记下拉（设计稿里是静态样式，这里保留外观）
    Rectangle {
        x: 14
        y: 60
        width: 141
        height: 29
        radius: 10
        color: Design.primarySoft

        Text {
            x: 11
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("手动标记")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Image {
            x: 132
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
        }
    }

    // 标记事件按钮
    Rectangle {
        x: 162
        y: 60
        width: 150
        height: 29
        radius: 12
        color: markMouse.pressed ? "#64879f" : Design.primary

        Text {
            anchors.centerIn: parent
            text: qsTr("标记事件")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        MouseArea {
            id: markMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addEvent(qsTr("手动"))
        }
    }

    // ---------- 事件列表（可视 3 行，滚轮滚动）----------
    // 列表区高度按设计稿取「3 行」：设计稿画了 3 条事件、下面留白，
    // 条数徽标却写 6 —— 说明列表是可滚动的，这里露出 3 行，其余靠滚动看。
    Item {
        id: eventViewport
        x: 0
        y: 101
        width: root.width
        height: root.eventViewHeight
        clip: true

        Repeater {
            model: eventModel

            delegate: Item {
                required property var modelData
                required property int index

                readonly property int rowY: root.eventRowHeight * index - root.eventScroll

                PanelDivider {
                    y: rowY + 36
                    width: 298
                    visible: index < root.eventCount - 1
                }

                Rectangle {
                    x: 14
                    y: rowY + 8
                    width: 12
                    height: 12
                    radius: 6
                    color: modelData.dotColor
                }

                Text {
                    x: 32
                    y: rowY + 3
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.wallClock
                    color: "#333333"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 16
                }

                Text {
                    x: 111
                    y: rowY + 5
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.offset
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }

                Text {
                    x: 163
                    y: rowY + 3
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.label
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }

                // 标签下拉
                Rectangle {
                    x: 148
                    y: rowY
                    width: 116
                    height: 27
                    radius: 10
                    color: Qt.rgba(0.561, 0.561, 0.561, 0.10)

                    Image {
                        x: 108
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7.47
                        height: 7
                        rotation: 90
                        source: Design.assetRoot + "icons/icon-arrow-down.svg"
                    }
                }

                // 删除按钮
                Rectangle {
                    x: 284
                    y: rowY
                    width: 28
                    height: 28
                    radius: 14
                    color: deleteMouse.pressed ? Qt.rgba(0.561, 0.561, 0.561, 0.22)
                                               : Qt.rgba(0.561, 0.561, 0.561, 0.10)

                    Image {
                        x: 7
                        y: 7
                        width: 14
                        height: 14
                        source: Design.assetRoot + "icons/icon-trash.svg"
                    }

                    MouseArea {
                        id: deleteMouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Acq.remove_event(index)
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: (wheel) => {
                var step = wheel.angleDelta.y > 0 ? -root.eventRowHeight : root.eventRowHeight
                root.eventScroll = Math.max(0, Math.min(root.eventMaxScroll, root.eventScroll + step))
            }
        }
    }

    // ---------- 滚动条 ----------
    Rectangle {
        x: 319
        y: 92
        width: 7
        height: 186
        radius: 4
        color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
    }

    Rectangle {
        x: 319
        // 轨道 186 高、滑块 24 高，可走 162px
        y: 108 + (root.eventMaxScroll > 0 ? root.eventScroll / root.eventMaxScroll : 0) * 162
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
    }
}
