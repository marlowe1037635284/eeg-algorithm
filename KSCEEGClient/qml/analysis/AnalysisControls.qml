import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「数据分析与后处理」页左侧的参数面板。
//
// 版面：面板底（panelFill）之上，每个分区各是一张**独立的浅色圆角卡**
//（panelFillSoft，见 Design.qml），卡片之间留 14 的空隙；卡片内是
// 「标题 —— 渐变分割线 —— 内容」三段。坐标一律取设计稿（后处理.png）的
// 卡片内相对值，面板宽度按程序里的 415（设计稿导出的是 405），
// 所以只用左侧绝对值定位、右侧一律对齐到卡片右边缘（card.width 减出去），
// 免得卡片宽了 10 而右边那列控件还停在设计稿的 387 上。
//
// 所有控件都直连 C++ 的 Analysis —— 不在这里另存一份草稿。这一页的参数是
// 「改一下、图立刻变」的探索式操作，存草稿再点确认反而挡路；重算的节流与
// 去抖都在 C++ 侧做（见 PostProcess::schedule_recompute）
Item {
    id: root

    implicitWidth: 415
    implicitHeight: 882

    // 卡片左右各内缩 9、上下各留 10，卡片之间 14（设计稿量出来的值）
    readonly property int cardInset: 9
    readonly property int cardGap: 14
    readonly property int cardTopPadding: 10
    readonly property int cardBottomPadding: 10
    readonly property real cardWidth: width - 2 * cardInset

    Rectangle {
        anchors.fill: parent
        radius: 16
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    // 内容比面板高时滚轮可滚。这一栏现在有九张卡片，总高远超面板高度，
    // 所以 content 的高度必须跟着内容走 —— 写死成 882 会让 contentHeight
    // 恒等于面板高度，Flickable 永远没有可滚动的区域
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(root.implicitHeight,
                                cards.height + root.cardTopPadding + root.cardBottomPadding)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // 竖直滚动条。这一栏九张卡片总深远超面板高度，没有滑块时用户看不出
        // 下面还接着内容。常显（AlwaysOn）而非常规的「需要时才出现」——它在这里
        // 就是个提示。上下各留 14px 的 padding，避开面板 16px 的圆角；
        // 不画底槽，只留滑块，免得底槽在圆角处露出方角。
        // 卡片右边缩进 9，滑块只占 6，正好落在卡片外侧那条缝里
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

        Column {
            id: cards

            x: root.cardInset
            y: root.cardTopPadding
            width: root.cardWidth
            spacing: root.cardGap

            // ---------- 基本信息 ----------
            SectionCard {
                width: cards.width
                height: 196
                title: qsTr("基本信息")

                Repeater {
                    model: Analysis.recordInfo

                    delegate: Item {
                        required property var modelData
                        required property int index

                        x: 0
                        y: 42 + index * 30
                        width: cards.width
                        height: 28

                        // 标签定宽、值右对齐到卡片右内边缘，与设计稿一致：
                        // 记录号 / 时间 / 采样率这些长短不一的值靠在同一条右边线上，
                        // 竖着扫一遍就能对齐比较
                        RowLabel {
                            x: 11
                            width: 130
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: modelData.label
                        }

                        Text {
                            x: 150
                            width: parent.width - 159
                            height: parent.height
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: modelData.value
                            color: Design.textSecondary
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 15
                        }
                    }
                }
            }

            // ---------- 滤波 ----------
            // 三档滤波器各占一行：值 + 单位 + 开关。设计稿里这三行是「宽输入框、
            // 只有陷波带开关」，但程序里三档各有自己的启停（C++ 侧 highPassEnabled /
            // lowPassEnabled / notchEnabled），做成三行同构、都能关，
            // 免得高通低通变成「只能改值、关不掉」
            SectionCard {
                width: cards.width
                height: 159
                title: qsTr("滤波")

                FilterRow {
                    y: 44
                    label: qsTr("高通滤波器")
                    value: Analysis.highPassHz
                    on_: Analysis.highPassEnabled
                    onValueEdited: (value) => Analysis.highPassHz = value
                    onToggled: Analysis.highPassEnabled = !Analysis.highPassEnabled
                }

                FilterRow {
                    y: 81
                    label: qsTr("低通滤波器")
                    value: Analysis.lowPassHz
                    on_: Analysis.lowPassEnabled
                    onValueEdited: (value) => Analysis.lowPassHz = value
                    onToggled: Analysis.lowPassEnabled = !Analysis.lowPassEnabled
                }

                FilterRow {
                    y: 118
                    label: qsTr("陷波滤波器")
                    value: Analysis.notchHz
                    on_: Analysis.notchEnabled
                    onValueEdited: (value) => Analysis.notchHz = value
                    onToggled: Analysis.notchEnabled = !Analysis.notchEnabled
                }
            }

            // ---------- 重参考 ----------
            SectionCard {
                width: cards.width
                height: 86
                title: qsTr("重参考")

                ChoiceField {
                    x: 11
                    y: 46
                    width: parent.width - 20
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    choices: Analysis.referenceChoices
                    currentIndex: Analysis.referenceIndex
                    onActivated: (index) => Analysis.referenceIndex = index
                }
            }

            // ---------- 降采样 ----------
            SectionCard {
                width: cards.width
                height: 86
                title: qsTr("降采样")

                ChoiceField {
                    x: 11
                    y: 47
                    width: parent.width - 20
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    // 档位按记录的**实际采样率**算（能整除才给），
                    // 不照抄设计稿写死的 1000Hz —— 那条记录是 256Hz 的
                    choices: Analysis.downsampleChoices
                    currentIndex: Analysis.downsampleIndex
                    onActivated: (index) => Analysis.downsampleIndex = index
                }
            }

            // ---------- ASR 去伪迹 ----------
            SectionCard {
                width: cards.width
                height: 86
                title: qsTr("ASR 去伪迹")

                // 开关与标题同高：压在标题那条 35 高的带上居中
                SwitchPill {
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    y: (35 - height) / 2
                    on_: Analysis.asrEnabled
                    onToggled: Analysis.asrEnabled = !Analysis.asrEnabled
                }

                // 滑块：值域 5~100，与 C++ 侧 set_asr_cutoff 的夹取范围一致
                RowSlider {
                    y: 50
                    label: qsTr("Cutoff 程度")
                    text: Analysis.asrCutoff
                    from: 5
                    to: 100
                    value: Analysis.asrCutoff
                    onMoved: (value) => Analysis.asrCutoff = Math.round(value)
                }
            }

            // ---------- 伪迹检测 ----------
            // 这一档没有可调参数，就是一张「开 / 关」的卡片，所以卡片本身就矮
            SectionCard {
                width: cards.width
                height: 39
                title: qsTr("伪迹检测")

                SwitchPill {
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    y: (35 - height) / 2
                    on_: Analysis.artifactDetectionEnabled
                    onToggled: Analysis.artifactDetectionEnabled = !Analysis.artifactDetectionEnabled
                }
            }

            // ---------- 窗口和缩放 ----------
            // 位移 / 窗口长度改的是时间轴上那扇窗（Analysis.windowStartSeconds /
            // windowSeconds），幅度是波形每一格的 µV 标尺，0 表示「自动」
            SectionCard {
                width: cards.width
                height: 167
                title: qsTr("窗口和缩放")

                RowSlider {
                    y: 50
                    label: qsTr("位移")
                    text: Analysis.windowStartSeconds.toFixed(1) + " s"
                    from: 0
                    to: Math.max(0.5, Analysis.durationSeconds - Analysis.windowSeconds)
                    value: Analysis.windowStartSeconds
                    onMoved: (value) => Analysis.windowStartSeconds = value
                }

                RowSlider {
                    y: 88
                    label: qsTr("窗口长度")
                    text: Analysis.windowSeconds.toFixed(1) + " s"
                    from: 0.5
                    to: Math.max(1.0, Analysis.durationSeconds)
                    value: Analysis.windowSeconds
                    onMoved: (value) => Analysis.windowSeconds = value
                }

                RowSlider {
                    y: 128
                    label: qsTr("幅度")
                    text: Analysis.waveAmplitudeUV > 0
                          ? Analysis.waveAmplitudeUV + " μV" : qsTr("自动")
                    from: 0
                    to: 500
                    value: Analysis.waveAmplitudeUV
                    onMoved: (value) => Analysis.waveAmplitudeUV = Math.round(value)
                }
            }

            // ---------- 质检与修复 ----------
            SectionCard {
                width: cards.width
                height: 233
                title: qsTr("质检与修复")

                RowLabel {
                    x: 11
                    y: 48
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("检测")
                }

                // 三项检测各自一个独立的圆形开关（左），阈值输入在其右侧。
                // 关掉某一项，报告页与底栏就不再统计它
                RowToggle {
                    y: 81
                    label: qsTr("弱信号和空值")
                    on_: Analysis.qcSignalEnabled
                    onToggled: Analysis.qcSignalEnabled = !Analysis.qcSignalEnabled
                }

                RowToggle {
                    y: 117
                    label: qsTr("异常 EEG 范围外值")
                    on_: Analysis.qcRangeEnabled
                    onToggled: Analysis.qcRangeEnabled = !Analysis.qcRangeEnabled

                    RowLabel {
                        anchors.right: rangeSpin.left
                        anchors.rightMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("幅度占比")
                    }

                    SpinField {
                        id: rangeSpin
                        anchors.right: parent.right
                        anchors.rightMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: Analysis.qcRangeEnabled ? 1.0 : 0.45
                        value: Analysis.qcAmplitudeRatio
                        onEdited: (value) => Analysis.qcAmplitudeRatio = value
                    }
                }

                RowToggle {
                    y: 155
                    label: qsTr("低相关性导联")
                    on_: Analysis.qcCorrelationEnabled
                    onToggled: Analysis.qcCorrelationEnabled = !Analysis.qcCorrelationEnabled

                    RowLabel {
                        anchors.right: correlationSpin.left
                        anchors.rightMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("相关性阈值")
                    }

                    SpinField {
                        id: correlationSpin
                        anchors.right: parent.right
                        anchors.rightMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: Analysis.qcCorrelationEnabled ? 1.0 : 0.45
                        value: Analysis.qcCorrelation
                        onEdited: (value) => Analysis.qcCorrelation = value
                    }
                }

                RowLabel {
                    x: 11
                    y: 196
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("修复")
                }

                ChoiceField {
                    x: 237
                    y: 192.5
                    width: parent.width - 246
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    choices: Analysis.qcRepairChoices
                    currentIndex: Analysis.qcRepairIndex
                    onActivated: (index) => Analysis.qcRepairIndex = index
                }
            }

            // ---------- 脑电数据导出 ----------
            // 三个下拉决定页面底部「导出数据」按钮写出的内容
            SectionCard {
                width: cards.width
                height: 159
                title: qsTr("脑电数据导出")

                RowLabel { x: 11; y: 44; height: 29; verticalAlignment: Text.AlignVCenter; text: qsTr("格式") }
                ChoiceField {
                    x: 237
                    y: 44
                    width: parent.width - 246
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    choices: Analysis.exportFormatChoices
                    currentIndex: Analysis.exportFormatIndex
                    onActivated: (index) => Analysis.exportFormatIndex = index
                }

                RowLabel { x: 11; y: 81; height: 29; verticalAlignment: Text.AlignVCenter; text: qsTr("类型") }
                ChoiceField {
                    x: 237
                    y: 81
                    width: parent.width - 246
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    choices: Analysis.exportTypeChoices
                    currentIndex: Analysis.exportTypeIndex
                    onActivated: (index) => Analysis.exportTypeIndex = index
                }

                RowLabel { x: 11; y: 118; height: 29; verticalAlignment: Text.AlignVCenter; text: qsTr("范围") }
                ChoiceField {
                    x: 237
                    y: 118
                    width: parent.width - 246
                    height: 29
                    pixelSize: 15
                    fieldRadius: 8
                    arrowRightMargin: 8.5
                    choices: Analysis.exportRangeChoices
                    currentIndex: Analysis.exportRangeIndex
                    onActivated: (index) => Analysis.exportRangeIndex = index
                }
            }
        }
    }

    // ---------- 卡片与行内小组件 ----------

    // 一张分区卡：浅色圆角底 + 标题 + 标题下那条渐变分割线。
    // 标题与分割线画在卡片内部，内容（调用方写进来的子对象）坐标相对卡片左上角
    component SectionCard: Rectangle {
        id: card

        property string title: ""

        radius: 6
        color: Design.panelFillSoft

        // 标题压在一整条 35 高的带上垂直居中（设计稿里字身落在 10.5~26.5）
        Text {
            x: 11
            y: 0
            width: card.width - 22
            height: 35
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: card.title
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 17
        }

        // 分割线铺满整张卡片（不含圆角外的留白）
        PanelDivider {
            x: 0
            y: 34.5
            width: card.width
        }
    }

    // 分区里的普通行标签
    component RowLabel: Text {
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }

    // 滑块右侧显示的当前值。**左对齐**：设计稿里 "14.5s" 与 "20" 都从同一条
    // 竖线起笔，右对齐会让长短不一的读数来回跳
    component RowValue: Text {
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }

    // 「滤波」里的一行：标签 + 数值输入 + 单位 + 开关
    component FilterRow: Item {
        id: filterRow

        property string label: ""
        property real value: 0
        property bool on_: false
        property string unit: "Hz"

        signal valueEdited(real value)
        signal toggled()

        width: parent ? parent.width : 0
        height: 29

        RowLabel {
            x: 11
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: filterRow.label
        }

        ValueField {
            x: 237
            y: 0
            width: 53
            height: 29
            value: filterRow.value
            onEdited: (value) => filterRow.valueEdited(value)
        }

        // 单位写在输入框外侧（设计稿里陷波那一行就是「49 | Hz | 开关」），
        // 不塞进框里 —— 53 宽的框塞不下数值加单位
        Text {
            x: 292
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: filterRow.unit
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        SwitchPill {
            large: true
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            on_: filterRow.on_
            onToggled: filterRow.toggled()
        }
    }

    // 一行「标签 + 滑块 + 读数」
    component RowSlider: Item {
        id: rowSlider

        property string label: ""
        property string text: ""
        property real value: 0
        property real from: 0
        property real to: 1

        signal moved(real value)

        width: parent ? parent.width : 0
        height: 24

        RowLabel {
            x: 11
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: rowSlider.label
        }

        // 轨道起点固定，宽度吃掉卡片右侧让出来的那一截（设计稿 387 宽卡片里
        // 轨道是 94~330、读数从 341 起笔）
        Slider {
            x: 94
            y: 0
            width: Math.max(40, rowSlider.width - 151)
            height: rowSlider.height
            value: rowSlider.value
            from: rowSlider.from
            to: rowSlider.to
            onMoved: (value) => rowSlider.moved(value)
        }

        RowValue {
            x: rowSlider.width - 46
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: rowSlider.text
        }
    }

    // 「质检与修复 → 检测」里的一项：圆形开关 + 项目名，右侧可再挂阈值控件
    //（子对象写在调用处，坐标相对本行）
    component RowToggle: Item {
        id: rowToggle

        property string label: ""
        property bool on_: false

        signal toggled()

        x: 0
        width: parent ? parent.width : 0
        height: 24

        RoundToggle {
            x: 11
            y: 0
            on_: rowToggle.on_
            onToggled: rowToggle.toggled()
        }

        RowLabel {
            x: 42
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: rowToggle.label
        }
    }

    // 连续量滑块。设计稿里的样子与采集页「滤波」弹窗的滑块同一套：
    // 中性灰轨道 + 主色由浅到深的渐变已选段 + 深蓝圆钮（内部白圈套深蓝点）。
    // 钮在轨道两端**不探出**：行程按 (width - 钮径) 算，不然滑到 0 会半个钮挂在轨道外面
    component Slider: Item {
        id: slider

        property real value: 0
        property real from: 0
        property real to: 1

        readonly property int knobSize: 24

        signal moved(real value)

        width: 236
        height: 24

        readonly property real ratio: (to > from)
            ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0

        // 轨道底：中性灰，不带蓝
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.07)
        }

        // 已选段：主色从 30% 拉到实色，压在轨道上 —— 设计稿里这一段左端是
        // 半透明的浅蓝灰、越靠钮越实，用「同一个主色的透明度渐变」比配两个
        // 固定色值更贴合（左端实测落在主色 30% 上）。渐变从轨道左端拉到钮心，
        // 所以宽度跟着钮走
        Rectangle {
            x: 0
            y: 0
            width: knob.x + knob.width / 2
            height: parent.height
            radius: height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.30) }
                GradientStop { position: 1.0; color: Design.primary }
            }
        }

        Rectangle {
            id: knob

            x: (slider.width - width) * slider.ratio
            y: (slider.height - height) / 2
            width: slider.knobSize
            height: slider.knobSize
            radius: width / 2
            color: "#59809c"
            border.width: 1
            border.color: "#416a87"

            // 白圈套深蓝点
            Rectangle {
                anchors.centerIn: parent
                width: 14
                height: 14
                radius: 7
                color: "#ffffff"

                Rectangle {
                    anchors.centerIn: parent
                    width: 12
                    height: 12
                    radius: 6
                    color: "#416a87"
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            function apply(position) {
                const usable = slider.width - slider.knobSize
                const r = Math.max(0, Math.min(1, (position - slider.knobSize / 2) / usable))
                slider.moved(slider.from + r * (slider.to - slider.from))
            }

            onPressed: (mouse) => apply(mouse.x)
            onPositionChanged: (mouse) => { if (pressed) apply(mouse.x) }
        }
    }

    // 连续量的输入框。用 TextInput 而不是 ChoiceField：截止频率是连续量，
    // 给一串预设值反而限制人。**失焦或回车才提交** —— 边打字边提交会把
    //「输入 0.1」的中间态（"0"、"0."）也当成一次参数变化，每敲一个字重算一遍
    component ValueField: Rectangle {
        id: valueField

        property real value: 0

        signal edited(real value)

        width: 152
        height: 30
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: input.activeFocus ? Design.primary : Design.panelBorder
        opacity: enabled ? 1.0 : 0.45

        function format(number) {
            // 保留两位、去掉多余的零：截止频率常写 0.1 / 0.5，但 49 不该显示成
            // 49.00，0.1 也不该显示成 0.10（设计稿里就是 49 和 0.1）
            return String(parseFloat(Number(number).toFixed(2)))
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

            x: 13
            y: 0
            width: parent.width - 13 - 10
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
    }

    // 「质检与修复」里的阈值输入：左边一个数值，右边一列上下步进三角。
    // 阈值都是 0~1 的比例，点一下走一格（默认 0.1），到边界就停住
    component SpinField: Rectangle {
        id: spinField

        property real value: 0
        property real from: 0
        property real to: 1
        property real step: 0.1

        signal edited(real value)

        width: 60
        height: 29
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder
        opacity: enabled ? 1.0 : 0.45

        readonly property int stepperWidth: 21

        function format(number) {
            return Number(number).toFixed(1)
        }

        // 吸附到步长并夹在 (from, to) 之间，避免浮点误差留下 0.30000000000000004
        function clampValue(number) {
            const snapped = Math.round((number - spinField.from) / spinField.step) * spinField.step + spinField.from
            return Math.max(spinField.from, Math.min(spinField.to, snapped))
        }

        function nudge(direction) {
            const next = clampValue(spinField.value + direction * spinField.step)
            spinField.value = next
            spinField.edited(next)
        }

        Text {
            anchors.left: parent.left
            anchors.right: stepper.left
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: spinField.format(spinField.value)
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Item {
            id: stepper
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: spinField.stepperWidth

            // 值区与步进列之间的细分隔线
            Rectangle {
                x: 0
                width: 1
                height: parent.height
                color: Design.panelBorder
            }

            // 上一格
            Canvas {
                width: 8
                height: 5
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: upArea.verticalCenter
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.beginPath()
                    ctx.moveTo(0, height)
                    ctx.lineTo(width / 2, 0)
                    ctx.lineTo(width, height)
                    ctx.closePath()
                    ctx.fillStyle = Design.primary
                    ctx.fill()
                }
            }
            MouseArea {
                id: upArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: parent.height / 2 - 1
                cursorShape: Qt.PointingHandCursor
                onClicked: spinField.nudge(1)
            }

            // 上下两格之间的横线
            Rectangle {
                x: 0
                y: parent.height / 2
                width: parent.width
                height: 1
                color: Design.panelBorder
            }

            // 下一格
            Canvas {
                width: 8
                height: 5
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: downArea.verticalCenter
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.beginPath()
                    ctx.moveTo(0, 0)
                    ctx.lineTo(width / 2, height)
                    ctx.lineTo(width, 0)
                    ctx.closePath()
                    ctx.fillStyle = Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.40)
                    ctx.fill()
                }
            }
            MouseArea {
                id: downArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height / 2 - 1
                cursorShape: Qt.PointingHandCursor
                onClicked: spinField.nudge(-1)
            }
        }
    }

    // 开关。与采集页「滤波」弹窗里的开关同一套语汇（圆环 + 内点，左右滑）——
    // 全应用只有这一种开关样式。设计稿在这个面板里给了两档尺寸：
    // **标题行**（ASR / 伪迹检测）用紧凑档 57×23，**内容行**（滤波那三行）用大档 60×29
    component SwitchPill: Rectangle {
        id: switchPill

        property bool on_: false
        property bool large: false

        signal toggled()

        readonly property int knobSize: large ? 24 : 18
        readonly property int dotSize: large ? 12 : 8
        // 钮离轨道边缘的间距，与它上下留白一致
        readonly property real knobMargin: (height - knobSize) / 2

        width: large ? 60 : 57
        height: large ? 29 : 23
        radius: height / 2
        color: switchPill.on_ ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
                              : Qt.rgba(0xba / 255, 0xba / 255, 0xba / 255, 0.20)

        Rectangle {
            id: knob

            y: (switchPill.height - height) / 2
            x: switchPill.on_ ? switchPill.width - width - switchPill.knobMargin
                              : switchPill.knobMargin
            width: switchPill.knobSize
            height: switchPill.knobSize
            radius: width / 2
            // 开着时钮内是主色淡底（比轨道重一点点），外圈描主色
            color: switchPill.on_ ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.24)
                                  : "transparent"
            border.width: 1
            border.color: switchPill.on_ ? Design.primary : "#919191"

            Behavior on x { NumberAnimation { duration: 120 } }

            // 白圈套内点：设计稿里内点与钮内底色之间隔着一圈白
            Rectangle {
                anchors.centerIn: parent
                width: switchPill.dotSize + 2
                height: width
                radius: width / 2
                color: switchPill.on_ ? "#ffffff" : "transparent"

                Rectangle {
                    anchors.centerIn: parent
                    width: switchPill.dotSize
                    height: switchPill.dotSize
                    radius: width / 2
                    color: switchPill.on_ ? Design.primary : "#919191"
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: switchPill.toggled()
        }
    }

    // 「质检与修复 → 检测」三项左侧的圆形开关：开着是蓝色实心点 + 一圈外晕，
    // 关掉是灰色空圈。与右侧那排长条开关（SwitchPill）区分开 —— 这里问的是
    //「要不要查这一项」，圆点更像勾选；三项各自独立，互不影响
    component RoundToggle: Item {
        id: roundToggle

        property bool on_: false

        signal toggled()

        width: 24
        height: 24

        // 外圈柔光：选中时铺一层很淡的蓝，让圆点像被点亮
        Rectangle {
            anchors.centerIn: parent
            width: 24
            height: 24
            radius: 12
            color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, roundToggle.on_ ? 0.20 : 0.0)
        }

        // 蓝圈 + 蓝淡底（关掉时退成灰环空圈）
        Rectangle {
            anchors.centerIn: parent
            width: 19
            height: 19
            radius: 9.5
            color: roundToggle.on_ ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.24)
                                   : "transparent"
            border.width: 1
            border.color: roundToggle.on_ ? Design.primary : "#919191"

            // 白圈套实心点
            Rectangle {
                anchors.centerIn: parent
                width: 11
                height: 11
                radius: 5.5
                color: roundToggle.on_ ? "#ffffff" : "transparent"

                Rectangle {
                    anchors.centerIn: parent
                    width: 9
                    height: 9
                    radius: 4.5
                    color: roundToggle.on_ ? Design.primary : "#919191"
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: roundToggle.toggled()
        }
    }
}
