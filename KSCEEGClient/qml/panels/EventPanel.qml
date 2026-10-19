import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「事件标注」面板。
// 设计稿里位于画板 (107,738)，尺寸 331×296；本文件坐标 = 设计坐标 - (107,738)。
Item {
    id: root

    // 清空与删除都是**不可撤销**的操作，清空按钮还就挨在「标记事件」旁边，
    // 很容易误点。面板自身不画确认框 —— 弹窗统一由 Main.qml 路由（与删除标签、
    // 删除记录同一范式），这里只把意图交上去，由外层决定弹什么
    signal clearRequested()
    signal deleteRequested(int index)

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

    // 事件列表可视 4 行，超出部分滚轮滚动。设计稿只画了 3 行，
    // 但列表底（233）到面板底（296）还空着一块没用上，这里放开到 4 行把它填满
    property real eventScroll: 0
    readonly property int eventRowHeight: 44
    readonly property int eventViewHeight: 176
    readonly property real eventMaxScroll: Math.max(0, eventCount * eventRowHeight - eventViewHeight)

    // 时间戳交给 C++ 取（它才有采集计时与墙钟），这里只传标签与颜色
    function addEvent() {
        Acq.add_event(tagNames[tagIndex], tagColorAt(tagIndex))
    }

    // 新标记的事件追加在列表末尾，落在可视区之外就看不见了。
    // 条数一变就把列表滚到最下面一行（清空时 eventMaxScroll 归 0，滚动量也归 0）
    onEventCountChanged: Qt.callLater(function() {
        root.eventScroll = root.eventMaxScroll
    })

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
            // 只上报意图，确认框由 Main.qml 弹（清空不可撤销）
            onClicked: root.clearRequested()
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

    // ---------- 事件列表（可视 4 行，滚轮滚动）----------
    // 设计稿画了 3 条事件、下面留白，条数徽标却写 6 —— 说明列表是可滚动的。
    // 面板高 296、列表从 101 起，4 行（176px）刚好铺到底部留白，其余靠滚动看。
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

                // 行分隔线。x 要与列表里其它元素对齐（圆点/时间/下拉都是 14 起），
                // 不设 x 会从面板最左边 0 起画，整条看起来贴左
                PanelDivider {
                    x: 14
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
                        // 与清空同理：删除也不可撤销，交外层弹确认框
                        onClicked: root.deleteRequested(index)
                    }
                }
            }
        }

        // 这个 MouseArea 只为滚轮而存在。它声明在 Repeater 之后、层级更高，
        // 会盖住每一行的删除按钮与标签下拉；默认它会吞掉按下事件，
        // 所以这里主动放弃 press（滚轮不走这条路径，onWheel 照常生效），
        // 点击才能落到下面各行的控件上
        MouseArea {
            anchors.fill: parent
            onPressed: (mouse) => { mouse.accepted = false }
            onWheel: (wheel) => {
                var step = wheel.angleDelta.y > 0 ? -root.eventRowHeight : root.eventRowHeight
                root.eventScroll = Math.max(0, Math.min(root.eventMaxScroll, root.eventScroll + step))
            }
        }
    }

    // ---------- 滚动条 ----------
    // 事件没满 4 行（eventMaxScroll = 0）时整条隐藏，不留一根空轨道
    Rectangle {
        x: 319
        y: 92
        width: 7
        height: 186
        radius: 4
        color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
        visible: root.eventMaxScroll > 0
    }

    Rectangle {
        x: 319
        visible: root.eventMaxScroll > 0
        // 轨道 186 高（92~278）、滑块 24 高，可走 162px。
        // 起点必须对齐轨道顶 92，否则 scroll=0 时滑块顶比轨道顶低一截
        // （滚不到最上面）、scroll=maxScroll 时底边 294 越过轨道底 278（出框）
        y: 92 + (root.eventMaxScroll > 0 ? root.eventScroll / root.eventMaxScroll : 0) * 162
        width: 7
        height: 24
        radius: 4
        color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
    }
}
