import QtQuick
import QtQuick.Controls.Basic
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

    // 内容比面板高时滚轮可滚。这一栏现在有九块分区，总高远超面板高度，
    // 所以 content 的高度必须跟着内容走 —— 写死成 882 会让 contentHeight
    // 恒等于面板高度，Flickable 永远没有可滚动的区域
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(root.implicitHeight, content.height)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // 竖直滚动条。这一栏九块分区总深远超面板高度，没有滑块时用户看不出
        // 下面还接着内容。常显（AlwaysOn）而非常规的「需要时才出现」——它在这里
        // 就是个提示。上下各留 14px 的 padding，避开面板 16px 的圆角；
        // 不画底槽，只留滑块，免得底槽在圆角处露出方角
        ScrollBar.vertical: ScrollBar {
            id: verticalScrollBar

            policy: ScrollBar.AlwaysOn
            width: 8
            topPadding: 14
            bottomPadding: 14
            leftPadding: 1
            rightPadding: 1

            contentItem: Rectangle {
                implicitWidth: 6
                radius: 3
                color: verticalScrollBar.pressed
                       ? Design.primary
                       : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.45)
            }
        }

        Item {
            id: content
            width: parent.width
            // 最后一块（脑电数据导出）落在 y ≈ 1319，底部再留一点余量
            height: 1344

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

                    // 标签定宽、值右对齐到内容右边缘（x=390），与设计稿一致：
                    // 记录号 / 时间 / 采样率这些长短不一的值靠在同一条右边线上，
                    // 竖着扫一遍就能对齐比较
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
                        horizontalAlignment: Text.AlignRight
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
            // 三个滤波器各占一行、各自一个开关。关掉只是不生效，输入框仍可编辑 ——
            // 灰掉会让人以为控件坏了
            SectionTitle { x: 25; y: 250; text: qsTr("滤波") }

            RowLabel { x: 25; y: 294; text: qsTr("高通滤波") }
            ValueField {
                x: 231; y: 283
                width: 86
                value: Analysis.highPassHz
                suffix: "Hz"
                onEdited: (value) => Analysis.highPassHz = value
            }
            SwitchPill {
                x: 333; y: 286
                on_: Analysis.highPassEnabled
                onToggled: Analysis.highPassEnabled = !Analysis.highPassEnabled
            }

            RowLabel { x: 25; y: 334; text: qsTr("低通滤波") }
            ValueField {
                x: 231; y: 323
                width: 86
                value: Analysis.lowPassHz
                suffix: "Hz"
                onEdited: (value) => Analysis.lowPassHz = value
            }
            SwitchPill {
                x: 333; y: 326
                on_: Analysis.lowPassEnabled
                onToggled: Analysis.lowPassEnabled = !Analysis.lowPassEnabled
            }

            RowLabel { x: 25; y: 374; text: qsTr("陷波滤波") }
            ValueField {
                x: 231; y: 363
                width: 86
                value: Analysis.notchHz
                suffix: "Hz"
                onEdited: (value) => Analysis.notchHz = value
            }
            SwitchPill {
                x: 333; y: 366
                on_: Analysis.notchEnabled
                onToggled: Analysis.notchEnabled = !Analysis.notchEnabled
            }

            PanelDivider { x: 21; y: 435; width: 373 }

            // ---------- 重参考 ----------
            SectionTitle { x: 25; y: 447; text: qsTr("重参考") }
            ChoiceField {
                x: 25; y: 483; width: 365; height: 38
                pixelSize: 15
                fieldRadius: 10
                choices: Analysis.referenceChoices
                currentIndex: Analysis.referenceIndex
                onActivated: (index) => Analysis.referenceIndex = index
            }

            // ---------- 降采样 ----------
            SectionTitle { x: 25; y: 553; text: qsTr("降采样") }
            ChoiceField {
                x: 25; y: 589; width: 365; height: 38
                pixelSize: 15
                fieldRadius: 10
                // 档位按记录的**实际采样率**算（能整除才给），
                // 不照抄设计稿写死的 1000Hz —— 那条记录是 256Hz 的
                choices: Analysis.downsampleChoices
                currentIndex: Analysis.downsampleIndex
                onActivated: (index) => Analysis.downsampleIndex = index
            }

            // ---------- 伪迹检测 ----------
            SectionTitle { x: 25; y: 652; text: qsTr("伪迹检测") }
            SwitchPill {
                x: 340; y: 648
                on_: Analysis.artifactDetectionEnabled
                onToggled: Analysis.artifactDetectionEnabled = !Analysis.artifactDetectionEnabled
            }

            PanelDivider { x: 21; y: 692; width: 373 }

            // ---------- ASR 去伪迹 ----------
            SectionTitle { x: 25; y: 704; text: qsTr("ASR 去伪迹") }
            SwitchPill {
                x: 340; y: 700
                on_: Analysis.asrEnabled
                onToggled: Analysis.asrEnabled = !Analysis.asrEnabled
            }

            RowLabel { x: 25; y: 748; text: qsTr("Cutoff 程度") }

            // 滑块：值域 5~100，与 C++ 侧 set_asr_cutoff 的夹取范围一致
            Item {
                x: 150; y: 740
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
                x: 352
                y: 745
                width: 38
                height: 20
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                text: Analysis.asrCutoff
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 15
            }

            PanelDivider { x: 21; y: 786; width: 373 }

            // ---------- 窗口和缩放 ----------
            // 位移 / 窗口长度改的是时间轴上那扇窗（Analysis.windowStartSeconds /
            // windowSeconds），幅度是波形每一格的 µV 标尺，0 表示「自动」
            SectionTitle { x: 25; y: 798; text: qsTr("窗口和缩放") }

            RowLabel { x: 25; y: 837; text: qsTr("位移") }
            Slider {
                x: 150; y: 829
                from: 0
                to: Math.max(0.5, Analysis.durationSeconds - Analysis.windowSeconds)
                value: Analysis.windowStartSeconds
                onMoved: (v) => Analysis.windowStartSeconds = v
            }
            RowValue { x: 352; y: 834; text: Analysis.windowStartSeconds.toFixed(1) + " s" }

            RowLabel { x: 25; y: 873; text: qsTr("窗口长度") }
            Slider {
                x: 150; y: 865
                from: 0.5
                to: Math.max(1.0, Analysis.durationSeconds)
                value: Analysis.windowSeconds
                onMoved: (v) => Analysis.windowSeconds = v
            }
            RowValue { x: 352; y: 870; text: Analysis.windowSeconds.toFixed(1) + " s" }

            RowLabel { x: 25; y: 909; text: qsTr("幅度") }
            Slider {
                x: 150; y: 901
                from: 0
                to: 500
                value: Analysis.waveAmplitudeUV
                onMoved: (v) => Analysis.waveAmplitudeUV = Math.round(v)
            }
            RowValue {
                x: 352; y: 906
                text: Analysis.waveAmplitudeUV > 0 ? Analysis.waveAmplitudeUV + " μV" : qsTr("自动")
            }

            PanelDivider { x: 21; y: 949; width: 373 }

            // ---------- 质检与修复 ----------
            SectionTitle { x: 25; y: 961; text: qsTr("质检与修复") }

            RowLabel { x: 25; y: 993; text: qsTr("检测") }

            // 三项检测各自一个独立的圆形开关（左），阈值输入在其右侧。
            // 关掉某一项，报告页与底栏就不再统计它
            RoundToggle {
                x: 25; y: 1027
                on_: Analysis.qcSignalEnabled
                onToggled: Analysis.qcSignalEnabled = !Analysis.qcSignalEnabled
            }
            RowLabel { x: 51; y: 1028; text: qsTr("弱信号和空值") }

            RoundToggle {
                x: 25; y: 1063
                on_: Analysis.qcRangeEnabled
                onToggled: Analysis.qcRangeEnabled = !Analysis.qcRangeEnabled
            }
            RowLabel { x: 51; y: 1064; text: qsTr("异常 EEG 范围外值") }
            RowLabel { x: 160; y: 1064; text: qsTr("幅度占比") }
            ValueField {
                x: 231; y: 1056
                opacity: Analysis.qcRangeEnabled ? 1.0 : 0.45
                value: Analysis.qcAmplitudeRatio
                onEdited: (value) => Analysis.qcAmplitudeRatio = value
            }

            RoundToggle {
                x: 25; y: 1099
                on_: Analysis.qcCorrelationEnabled
                onToggled: Analysis.qcCorrelationEnabled = !Analysis.qcCorrelationEnabled
            }
            RowLabel { x: 51; y: 1100; text: qsTr("低相关性导联") }
            RowLabel { x: 160; y: 1100; text: qsTr("相关性") }
            ValueField {
                x: 231; y: 1092
                opacity: Analysis.qcCorrelationEnabled ? 1.0 : 0.45
                value: Analysis.qcCorrelation
                onEdited: (value) => Analysis.qcCorrelation = value
            }

            RowLabel { x: 25; y: 1144; text: qsTr("修复") }
            ChoiceField {
                x: 231; y: 1133; width: 152; height: 30
                pixelSize: 14
                fieldRadius: 8
                choices: Analysis.qcRepairChoices
                currentIndex: Analysis.qcRepairIndex
                onActivated: (index) => Analysis.qcRepairIndex = index
            }

            PanelDivider { x: 21; y: 1184; width: 373 }

            // ---------- 脑电数据导出 ----------
            // 三个下拉决定页面底部「导出数据」按钮写出的内容
            SectionTitle { x: 25; y: 1196; text: qsTr("脑电数据导出") }

            RowLabel { x: 25; y: 1234; text: qsTr("格式") }
            ChoiceField {
                x: 231; y: 1223; width: 152; height: 30
                pixelSize: 14
                fieldRadius: 8
                choices: Analysis.exportFormatChoices
                currentIndex: Analysis.exportFormatIndex
                onActivated: (index) => Analysis.exportFormatIndex = index
            }

            RowLabel { x: 25; y: 1271; text: qsTr("类型") }
            ChoiceField {
                x: 231; y: 1260; width: 152; height: 30
                pixelSize: 14
                fieldRadius: 8
                choices: Analysis.exportTypeChoices
                currentIndex: Analysis.exportTypeIndex
                onActivated: (index) => Analysis.exportTypeIndex = index
            }

            RowLabel { x: 25; y: 1308; text: qsTr("范围") }
            ChoiceField {
                x: 231; y: 1297; width: 152; height: 30
                pixelSize: 14
                fieldRadius: 8
                choices: Analysis.exportRangeChoices
                currentIndex: Analysis.exportRangeIndex
                onActivated: (index) => Analysis.exportRangeIndex = index
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

    // 滑块右侧显示的当前值
    component RowValue: Text {
        width: 38
        height: 20
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }

    // 连续量滑块。与 ASR「Cutoff 程度」是同一套样式，
    // 拖动时把 (from, to) 之间的位置换算成实际值发出去
    component Slider: Item {
        id: slider

        property real value: 0
        property real from: 0
        property real to: 1

        signal moved(real value)

        width: 200
        height: 30

        readonly property real ratio: (to > from)
            ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0

        Rectangle {
            x: 0; y: 13
            width: parent.width; height: 5
            radius: 2.5
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
        }

        Rectangle {
            x: 0; y: 13
            width: parent.width * slider.ratio
            height: 5
            radius: 2.5
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.55)
        }

        Rectangle {
            x: parent.width * slider.ratio - 9
            y: 6
            width: 18; height: 18
            radius: 9
            color: Design.sliderThumb
            border.width: 1
            border.color: "#ffffff"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            function apply(position) {
                const r = Math.max(0, Math.min(1, position / width))
                slider.moved(slider.from + r * (slider.to - slider.from))
            }

            onPressed: (mouse) => apply(mouse.x)
            onPositionChanged: (mouse) => { if (pressed) apply(mouse.x) }
        }
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

    // 「质检与修复 → 检测」三项左侧的圆形开关：开着是蓝色实心点，关掉是灰色空圈。
    // 与右侧那排长条开关（SwitchPill）区分开 —— 这里问的是「要不要查这一项」，
    // 圆点更像勾选；三项各自独立，互不影响
    component RoundToggle: Item {
        id: roundToggle

        property bool on_: false
        signal toggled()

        width: 16
        height: 16

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: roundToggle.on_ ? Design.primary : "#919191"

            Rectangle {
                anchors.centerIn: parent
                width: 8
                height: 8
                radius: 4
                color: roundToggle.on_ ? Design.primary : "transparent"
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: roundToggle.toggled()
        }
    }
}
