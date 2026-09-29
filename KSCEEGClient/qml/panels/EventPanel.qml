import QtQuick
import QtQuick.Controls.Basic
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

    // 采集是否进行中。事件要挂在「采集开始以来的第几秒」上，没在采集时标了
    // 也没有时间基准可用，所以按钮在待机时是禁用的
    property bool collecting: false

    // 可选的标签。来自系统设置里的「标签管理」（由工作台传进来）。
    // 一个标签都没建过时退回一项「手动标记」—— 否则标记按钮就没得选了
    property var tags: []
    readonly property var tagNames: {
        var names = []
        for (var i = 0; i < tags.length; ++i)
            names.push(tags[i].name)
        return names.length > 0 ? names : [qsTr("手动标记")]
    }
    property int tagIndex: 0

    // 标签色跟着标签走，事件列表里的圆点与波形上的竖线用同一个颜色
    function tagColorAt(index) {
        return (index >= 0 && index < tags.length && tags[index].color.length > 0)
                ? tags[index].color : "#7c3aed"
    }

    // 事件列表可视 3 行，超出部分滚轮滚动（设计稿画了 3 行 + 一根滚动条）
    property real eventScroll: 0
    readonly property int eventRowHeight: 44
    readonly property int eventViewHeight: 132
    readonly property real eventMaxScroll: Math.max(0, eventCount * eventRowHeight - eventViewHeight)

    function clearEvents() {
        Acq.clear_events()
    }

    // 时间戳交给 C++ 取（它才有采集计时与墙钟），这里只传标签与颜色
    function addEvent() {
        Acq.add_event(tagNames[tagIndex], tagColorAt(tagIndex))
    }

    // 改某条事件的标签：列表里那一行的下拉直接改，不再删掉重标 ——
    // 事件在时间轴上的位置是按当时那一刻记的，删了重标就落到别的时间点去了
    function relabelEvent(index, label) {
        var at = tagNames.indexOf(label)
        Acq.set_event_label(index, label, tagColorAt(at))
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

    // 手动标记下拉。设计稿里只是一个写着「手动标记」的色块，
    // 这里接成真的可选列表 —— 标签就是系统设置里维护的那一份
    ChoiceField {
        x: 14
        y: 60
        width: 141
        height: 29
        pixelSize: 14
        fieldRadius: 10
        choices: root.tagNames
        currentIndex: root.tagIndex
        onActivated: (index) => root.tagIndex = index
    }

    // 标记事件按钮。待机时压暗并禁用：没有采集起点就没有「第几秒」可言
    Rectangle {
        x: 162
        y: 60
        width: 150
        height: 29
        radius: 12
        color: markMouse.pressed ? "#64879f" : Design.primary
        opacity: root.collecting ? 1.0 : 0.45

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
            enabled: root.collecting
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addEvent()

            ToolTip.visible: containsMouse && !root.collecting
            ToolTip.text: qsTr("请先开始采集再标记事件")
            ToolTip.delay: 300
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

                // 标签名不再单独画一个 Text：它由下面那个下拉显示。
                // 两个都留的话，下拉那层底是半透明的，两层字会叠在一起

                // 标签下拉。原来只是一个画出来的灰块 —— 标错标签只能删掉重标，
                // 而重标会把事件挪到当前时刻，时间点就丢了。
                // 这里直接改标签名，事件在时间轴上的位置保持不变。
                //
                // currentIndex 允许是 -1：标签被删掉之后，老事件身上还留着
                // 那个已经不在列表里的名字。这时用 placeholder 显示它自己的标签，
                // 而不是硬凑成第 0 项 —— 那会让界面显示一个跟事实不符的标签
                ChoiceField {
                    x: 148
                    y: rowY
                    width: 116
                    height: 27
                    pixelSize: 13
                    fieldRadius: 10
                    choices: root.tagNames
                    placeholder: modelData.label
                    currentIndex: root.tagNames.indexOf(modelData.label)
                    onActivated: (tagAt) => root.relabelEvent(index, root.tagNames[tagAt])
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
