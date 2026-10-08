import QtQuick
import KSCEEGClient

// 「数据分析与后处理」页左侧的参数面板。
//
// 坐标相对面板左上角：面板本身在设计稿里位于内容卡片内 (48,0)、尺寸 415×882，
// 各行 y 值取自设计稿（面板原点在设计稿绝对坐标 (202,151)）。
//
// 所有控件都直连 C++ 的 Analysis —— 不在这里另存一份草稿。这一页的参数是
// 「改一下、图立刻变」的探索式操作，存草稿再点确认反而挡路；重算的节流与
// 去抖都在 C++ 侧做（见 PostProcess::schedule_recompute）
Item {
    id: root

    implicitWidth: 415
    implicitHeight: 882

    Rectangle {
        anchors.fill: parent
        radius: 16
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    // 内容比面板高时滚轮可滚。设计稿这一栏正好放满，但「片段选取」的选项
    // 跟着记录里的事件标签走，标签多了就会溢出 —— 溢出的部分会画到面板外面，
    // 那不是「稍微不好看」，是和下面的内容叠在一起
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(root.implicitHeight, content.height)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: content
            width: parent.width
            height: 882

            // ---------- 基本信息 ----------
            SectionTitle { x: 25; y: 14; text: qsTr("基本信息") }

            Repeater {
                model: Analysis.recordInfo

                delegate: Item {
                    required property var modelData
                    required property int index

                    x: 0
                    y: 66 + index * 34
                    width: root.width
                    height: 24

                    // 标签定宽、值左对齐紧跟其后。原来值右对齐到面板最右（x=390），
                    // 短标签（「采集时间」）和值之间空出一大片，整栏看着像漏了东西
                    RowLabel {
                        x: 25
                        width: 120
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        text: modelData.label
                    }

                    Text {
                        x: 150
                        width: 240
                        height: parent.height
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.value
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 15
                    }
                }
            }

            PanelDivider { x: 21; y: 238; width: 373 }

            // ---------- 滤波 ----------
            SectionTitle { x: 25; y: 250; text: qsTr("滤波") }

            // 带通滤波器：一个总开关（自定义 = 开）。关掉之后下面三个输入框
            // 仍可编辑，只是不生效 —— 灰掉会让人以为控件坏了
            RowLabel { x: 25; y: 288; text: qsTr("带通滤波器") }
            ChoiceField {
                x: 231; y: 277; width: 152; height: 30
                pixelSize: 14
                fieldRadius: 8
                choices: [qsTr("自定义"), qsTr("关闭")]
                currentIndex: Analysis.bandPassEnabled ? 0 : 1
                onActivated: (index) => Analysis.bandPassEnabled = (index === 0)
            }

            RowLabel { x: 25; y: 322; text: qsTr("高通滤波器") }
            ValueField {
                x: 231; y: 311
                value: Analysis.highPassHz
                suffix: "Hz"
                onEdited: (value) => Analysis.highPassHz = value
            }

            RowLabel { x: 25; y: 355; text: qsTr("低通滤波器") }
            ValueField {
                x: 231; y: 344
                value: Analysis.lowPassHz
                suffix: "Hz"
                onEdited: (value) => Analysis.lowPassHz = value
            }

            RowLabel { x: 25; y: 388; text: qsTr("陷波滤波器") }
            ValueField {
                id: notchField
                x: 231; y: 377
                width: 86
                value: Analysis.notchHz
                suffix: "Hz"
                onEdited: (value) => Analysis.notchHz = value
            }
            SwitchPill {
                x: 333; y: 380
                on_: Analysis.notchEnabled
                onToggled: Analysis.notchEnabled = !Analysis.notchEnabled
            }

            PanelDivider { x: 21; y: 435; width: 373 }

            // ---------- 重参考 ----------
            SectionTitle { x: 25; y: 447; text: qsTr("重参考") }
            ChoiceField {
                x: 25; y: 483; width: 398; height: 38
                pixelSize: 15
                fieldRadius: 10
                choices: Analysis.referenceChoices
                currentIndex: Analysis.referenceIndex
                onActivated: (index) => Analysis.referenceIndex = index
            }

            // ---------- 降采样 ----------
            SectionTitle { x: 25; y: 553; text: qsTr("降采样") }
            ChoiceField {
                x: 25; y: 589; width: 398; height: 38
                pixelSize: 15
                fieldRadius: 10
                // 档位按记录的**实际采样率**算（能整除才给），
                // 不照抄设计稿写死的 1000Hz —— 那条记录是 256Hz 的
                choices: Analysis.downsampleChoices
                currentIndex: Analysis.downsampleIndex
                onActivated: (index) => Analysis.downsampleIndex = index
            }

            // ---------- 基线校正 ----------
            SectionTitle { x: 25; y: 652; text: qsTr("基线校正") }
            SwitchPill {
                x: 340; y: 648
                on_: Analysis.baselineEnabled
                onToggled: Analysis.baselineEnabled = !Analysis.baselineEnabled
            }

            // ---------- 片段选取 ----------
            SectionTitle { x: 25; y: 700; text: qsTr("片段选取") }
            ChoiceField {
                x: 130; y: 690; width: 293; height: 34
                pixelSize: 14
                fieldRadius: 9
                // 前三项是固定的「整段记录 / 前 10 秒 / 前 30 秒」，
                // 其后是这条记录里真实出现过的事件标签
                choices: Analysis.segmentChoices
                currentIndex: Analysis.segmentIndex
                onActivated: (index) => Analysis.segmentIndex = index
            }

            // 前后范围。设计稿写的是「前 -0.2 s -- 后 0.8 s」：前值是**负数**，
            // 表示从事件时刻往前推 0.2 秒。这里照这个语义做；只有选了具体事件
            // 标签时才生效，所以非事件片段下压暗
            RowLabel { x: 25; y: 738; text: qsTr("前后范围") }
            RowLabel { x: 122; y: 738; text: qsTr("前") }
            ValueField {
                x: 150; y: 732
                width: 90
                value: Analysis.beforeSeconds
                suffix: "s"
                enabled: Analysis.segmentIndex >= 3
                onEdited: (value) => Analysis.beforeSeconds = value
            }
            RowLabel { x: 248; y: 738; text: qsTr("后") }
            ValueField {
                x: 276; y: 732
                width: 90
                value: Analysis.afterSeconds
                suffix: "s"
                enabled: Analysis.segmentIndex >= 3
                onEdited: (value) => Analysis.afterSeconds = value
            }

            // ---------- ASR 去伪迹 ----------
            SectionTitle { x: 25; y: 784; text: qsTr("ASR 去伪迹") }
            SwitchPill {
                x: 340; y: 780
                on_: Analysis.asrEnabled
                onToggled: Analysis.asrEnabled = !Analysis.asrEnabled
            }

            RowLabel { x: 25; y: 828; text: qsTr("Cutoff 程度") }

            // 滑块：值域 5~100，与 C++ 侧 set_asr_cutoff 的夹取范围一致
            Item {
                x: 150; y: 820
                width: 200
                height: 30
                opacity: Analysis.asrEnabled ? 1.0 : 0.45

                Rectangle {
                    x: 0; y: 13
                    width: parent.width; height: 5
                    radius: 2.5
                    color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
                }

                Rectangle {
                    x: 0; y: 13
                    width: parent.width * (Analysis.asrCutoff - 5) / 95
                    height: 5
                    radius: 2.5
                    color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
                }

                Rectangle {
                    x: parent.width * (Analysis.asrCutoff - 5) / 95 - 9
                    y: 6
                    width: 18; height: 18
                    radius: 9
                    color: Design.sliderThumb
                    border.width: 1
                    border.color: "#ffffff"
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: Analysis.asrEnabled
                    cursorShape: Qt.PointingHandCursor

                    function apply(position) {
                        const ratio = Math.max(0, Math.min(1, position / width))
                        Analysis.asrCutoff = Math.round(5 + ratio * 95)
                    }

                    onPressed: (mouse) => apply(mouse.x)
                    onPositionChanged: (mouse) => { if (pressed) apply(mouse.x) }
                }
            }

            Text {
                x: 360
                y: 825
                width: 45
                height: 20
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                text: Analysis.asrCutoff
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 15
            }
        }
    }

    // ---------- 行内小组件 ----------

    component SectionTitle: Text {
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleMedium
        font.pixelSize: 17
    }

    component RowLabel: Text {
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }

    // 连续量的输入框。用 TextInput 而不是 ChoiceField：截止频率、前后秒数都是
    // 连续量，给一串预设值反而限制人。**失焦或回车才提交** —— 边打字边提交会把
    //「输入 0.1」的中间态（"0"、"0."）也当成一次参数变化，每敲一个字重算一遍
    component ValueField: Rectangle {
        id: valueField

        property real value: 0
        property string suffix: ""

        signal edited(real value)

        width: 152
        height: 30
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: input.activeFocus ? Design.primary : Design.panelBorder
        opacity: enabled ? 1.0 : 0.45

        function format(number) {
            return number.toFixed(2)
        }

        function commit() {
            const parsed = Number(input.text)
            if (isNaN(parsed)) {
                // 输入的不是数字：退回当前值，而不是把 nan 送进 C++
                input.text = format(valueField.value)
                return
            }
            valueField.value = parsed
            valueField.edited(parsed)
            input.text = format(parsed)
        }

        TextInput {
            id: input
            x: 10
            y: 0
            width: parent.width - 10 - suffixLabel.width - 12
            height: parent.height
            verticalAlignment: TextInput.AlignVCenter
            enabled: valueField.enabled
            selectByMouse: true
            color: Design.textPrimary
            selectionColor: Design.primary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
            text: valueField.format(valueField.value)

            onEditingFinished: valueField.commit()
            Keys.onReturnPressed: valueField.commit()
            Keys.onEnterPressed: valueField.commit()
        }

        Text {
            id: suffixLabel
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: valueField.suffix
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 13
        }
    }

    // 开关。与采集页「滤波」弹窗里的开关同一套语汇（圆环 + 内点，左右滑）——
    // 全应用只有这一种开关样式
    component SwitchPill: Rectangle {
        id: switchPill

        property bool on_: false
        signal toggled()

        width: 50
        height: 24
        radius: 12
        color: switchPill.on_ ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
                              : Qt.rgba(0xba / 255, 0xba / 255, 0xba / 255, 0.20)

        Rectangle {
            y: (switchPill.height - height) / 2
            x: switchPill.on_ ? switchPill.width - width - 4 : 4
            width: 17
            height: 17
            radius: 8.5
            color: "transparent"
            border.width: 1
            border.color: switchPill.on_ ? Design.primary : "#919191"

            Behavior on x { NumberAnimation { duration: 120 } }

            Rectangle {
                anchors.centerIn: parent
                width: 9
                height: 9
                radius: 4.5
                color: switchPill.on_ ? Design.primary : "#919191"
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: switchPill.toggled()
        }
    }
}
