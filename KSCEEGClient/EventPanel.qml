import QtQuick

// 「事件标注」面板。
// 设计稿里位于画板 (107,738)，尺寸 331×296；本文件坐标 = 设计坐标 - (107,738)。
Item {
    id: root

    property alias eventCount: eventModel.count

    function clearEvents() {
        eventModel.clear()
    }

    function addEvent(label, timeText) {
        eventModel.append({
            "time": timeText,
            "offset": "+3s",
            "label": label,
            "dotColor": "#7c3aed"
        })
    }

    ListModel {
        id: eventModel

        // 设计稿的条数徽标是 6，列表区只放得下 3 条，其余靠裁剪切掉
        Component.onCompleted: {
            append({ "time": "16:13:05", "offset": "+3s", "label": "闭眼", "dotColor": "#7c3aed" })
            append({ "time": "16:13:05", "offset": "+3s", "label": "闭眼", "dotColor": "#7c3aed" })
            append({ "time": "16:13:05", "offset": "+3s", "label": "睁眼", "dotColor": "#7092ab" })
            append({ "time": "16:13:05", "offset": "+3s", "label": "睁眼", "dotColor": "#7092ab" })
            append({ "time": "16:13:05", "offset": "+3s", "label": "闭眼", "dotColor": "#7c3aed" })
            append({ "time": "16:13:05", "offset": "+3s", "label": "睁眼", "dotColor": "#7092ab" })
        }
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
        font.family: Design.fontRegular
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
            text: eventModel.count
            color: Design.textMuted
            font.family: Design.fontRegular
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
            font.family: Design.fontRegular
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
            font.family: Design.fontRegular
            font.pixelSize: 14
        }

        Image {
            x: 132
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            rotation: 90
            source: "assets/icons/icon-arrow-down.svg"
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
            font.family: Design.fontRegular
            font.pixelSize: 14
        }

        MouseArea {
            id: markMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addEvent("手动", "16:13:05")
        }
    }

    // ---------- 事件列表 ----------
    // 列表区高度按设计稿取「3 行」：设计稿画了 3 条事件，下面留白，
    // 条数徽标却写 6 —— 说明列表是可滚动的，这里就只露出前 3 行，
    // 其余留在模型里（删掉前面的会自然露出来）。
    Item {
        x: 0
        y: 101
        width: root.width
        height: 132
        clip: true

        Repeater {
            model: eventModel

            delegate: Item {
                required property var model
                required property int index

                readonly property int rowY: 44 * index

                PanelDivider {
                    y: rowY + 36
                    width: 298
                    visible: index < eventModel.count - 1
                }

                Rectangle {
                    x: 14
                    y: rowY + 8
                    width: 12
                    height: 12
                    radius: 6
                    color: model.dotColor
                }

                Text {
                    x: 32
                    y: rowY + 3
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: model.time
                    color: "#333333"
                    font.family: Design.fontMedium
                    font.pixelSize: 16
                }

                Text {
                    x: 111
                    y: rowY + 5
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: model.offset
                    color: Design.textSecondary
                    font.family: Design.fontRegular
                    font.pixelSize: 12
                }

                Text {
                    x: 163
                    y: rowY + 3
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: model.label
                    color: Design.textSecondary
                    font.family: Design.fontRegular
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
                        width: 7
                        height: 7
                        rotation: 90
                        source: "assets/icons/icon-arrow-down.svg"
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
                        source: "assets/icons/icon-trash.svg"
                    }

                    MouseArea {
                        id: deleteMouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: eventModel.remove(index)
                    }
                }
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
        y: 108
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
    }
}
