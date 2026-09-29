import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「滤波与后处理」弹窗。
//
// 设计稿里工具栏那个按钮只是个色块，没有展开态，所以这一屏没有设计稿可依；
// 版式沿用同一套设计变量（圆角、描边、字体、主色）与其它弹窗保持一致。
//
// 一个刻意的取舍：**先在本地改，点「应用」才下发**。
// 不是因为怕麻烦 —— 每改一次滤波参数，算法侧都会清空滚动缓存并重新预热
// （接口规定「处理配置变化后必须清空滚动缓存」）。改成边输入边下发的话，
// 拖一次数字框就会触发一串清空，地形图和频谱会一直停在「数据累积中」。
//
// 外层用 Window 而不是像设计稿那样的全屏 DialogFrame：这一屏的元素数量
// 远超设计稿的静态弹窗，靠绝对坐标摆不下，用布局器更稳
Window {
    id: root

    width: 720
    height: 520
    visible: false
    title: qsTr("滤波与后处理")
    modality: Qt.ApplicationModal
    color: "#eef2f5"

    signal applied()

    // 本地编辑副本。打开时从 Acq 读一次初值，之后只改副本，
    //「应用」才整体写回去
    property bool highPassOn: true
    property real highPassLow: 0.5
    property bool lowPassOn: true
    property real lowPassHigh: 30.0
    property bool notchOn: true
    property real notchLow: 48.0
    property real notchHigh: 52.0
    property bool asrOn: false
    property string referenceMethod: "common_average"

    readonly property var referenceChoices: [
        { value: "off", label: qsTr("不重参考") },
        { value: "common_average", label: qsTr("全脑平均") },
        { value: "bilateral_mastoids", label: qsTr("双侧乳突") }
    ]

    // 采样率决定 Nyquist，进而在输入阶段就挡住必然被算法拒绝的值。
    // 让用户先填 900 Hz 再被拒，不如当场夹住
    readonly property real nyquist: Acq.sample_rate() / 2.0

    // 当前配置是否有必然被算法拒绝的地方。有就禁用「应用」，
    // 并把原因显示出来 —— 算法侧也有一道校验（会给出规范错误码），
    // 但让用户先看到一个必然失败的操作不如当场说清楚
    readonly property string problem: {
        if (highPassOn && lowPassOn && highPassLow >= lowPassHigh)
            return qsTr("高通截止频率必须低于低通，否则通带为空")
        if (notchOn && notchLow >= notchHigh)
            return qsTr("陷波的下限必须小于上限")
        if (notchOn && notchHigh >= nyquist)
            return qsTr("陷波已超出采样率允许的范围（上限 %1 Hz）").arg(nyquist.toFixed(0))
        return ""
    }

    function load_from_bridge() {
        highPassOn = Acq.highPassEnabled
        highPassLow = Acq.highPassLowHz
        lowPassOn = Acq.lowPassEnabled
        lowPassHigh = Acq.lowPassHighHz
        notchOn = Acq.notchEnabled
        notchLow = Acq.notchLowHz
        notchHigh = Acq.notchHighHz
        asrOn = Acq.asrEnabled
        referenceMethod = Acq.referenceMethod
    }

    function apply_to_bridge() {
        // 顺序有讲究：先把频率与重参考写进去，最后才写开关。
        // 开关一写就会立即下发一次配置；若那一刻频率还是旧值，
        // 用户会看到「应用之后波形弹一下才稳定」
        Acq.highPassLowHz = highPassLow
        Acq.lowPassHighHz = lowPassHigh
        Acq.notchLowHz = notchLow
        Acq.notchHighHz = notchHigh
        Acq.referenceMethod = referenceMethod

        Acq.highPassEnabled = highPassOn
        Acq.lowPassEnabled = lowPassOn
        Acq.notchEnabled = notchOn
        Acq.asrEnabled = asrOn
    }

    // 打开时把当前参数读进来，否则显示的会是上一次打开时的旧值
    onVisibleChanged: {
        if (visible)
            load_from_bridge()
    }

    Rectangle {
        anchors.fill: parent
        color: "#ffffff"

        Column {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            Text {
                text: qsTr("滤波与后处理")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleBold
                font.pixelSize: 22
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: qsTr("参数在点「应用」后一次性下发。每改一次参数，算法都会清空滚动缓存，"
                           + "地形图与频谱需要几秒重新累积。")
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 13
            }

            PanelDivider { width: parent.width }

            // ---------- 高通 ----------
            Item {
                width: parent.width
                height: 34

                ToggleChip {
                    anchors.verticalCenter: parent.verticalCenter
                    on_: root.highPassOn
                    onToggled: root.highPassOn = !root.highPassOn
                }

                Row {
                    x: 132
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("高通")
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 16
                    }

                    NumberField {
                        width: 100
                        value: root.highPassLow
                        from: 0.1
                        to: Math.max(1, root.nyquist / 4)
                        onEdited: (v) => root.highPassLow = v
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Hz"
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("去掉缓慢漂移")
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }

            // ---------- 低通 ----------
            Item {
                width: parent.width
                height: 34

                ToggleChip {
                    anchors.verticalCenter: parent.verticalCenter
                    on_: root.lowPassOn
                    onToggled: root.lowPassOn = !root.lowPassOn
                }

                Row {
                    x: 132
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("低通")
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 16
                    }

                    NumberField {
                        width: 100
                        value: root.lowPassHigh
                        from: 1
                        to: Math.max(2, root.nyquist - 1)
                        onEdited: (v) => root.lowPassHigh = v
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Hz"
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("去掉高频噪声")
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }

            // ---------- 陷波 ----------
            Item {
                width: parent.width
                height: 34

                ToggleChip {
                    anchors.verticalCenter: parent.verticalCenter
                    on_: root.notchOn
                    onToggled: root.notchOn = !root.notchOn
                }

                Row {
                    x: 132
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("陷波")
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 16
                    }

                    NumberField {
                        width: 86
                        value: root.notchLow
                        from: 1
                        to: Math.max(2, root.nyquist - 2)
                        onEdited: (v) => root.notchLow = v
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "–"
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }

                    NumberField {
                        width: 86
                        value: root.notchHigh
                        from: 2
                        to: Math.max(3, root.nyquist - 1)
                        onEdited: (v) => root.notchHigh = v
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Hz"
                        color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("去掉工频干扰")
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }

            // ---------- ASR ----------
            Item {
                width: parent.width
                height: 34

                ToggleChip {
                    anchors.verticalCenter: parent.verticalCenter
                    on_: root.asrOn
                    onToggled: root.asrOn = !root.asrOn
                }

                Text {
                    x: 132
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("ASR")
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("抑制伪迹；开启后需先累计 60 秒数据自动建立参考")
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }

            // ---------- 重参考 ----------
            Item {
                width: parent.width
                height: 34

                Text {
                    x: 132
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("重参考")
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }

                Rectangle {
                    id: referenceBox
                    x: 216
                    width: 150
                    height: 30
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 8
                    color: referenceMouse.containsMouse
                           ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.18)
                           : Design.primarySoft
                    border.width: 1
                    border.color: Design.panelBorder

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            for (var i = 0; i < root.referenceChoices.length; ++i) {
                                if (root.referenceChoices[i].value === root.referenceMethod)
                                    return root.referenceChoices[i].label
                            }
                            return root.referenceMethod
                        }
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }

                    MouseArea {
                        id: referenceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var list = root.referenceChoices
                            var index = 0
                            for (var i = 0; i < list.length; ++i) {
                                if (list[i].value === root.referenceMethod)
                                    index = i
                            }
                            root.referenceMethod = list[(index + 1) % list.length].value
                        }
                    }

                    ToolTip.visible: referenceMouse.containsMouse
                    ToolTip.text: qsTr("点击切换重参考方式")
                    ToolTip.delay: 300
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("改变会重建在线会话")
                    color: Design.textMuted
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 12
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                visible: root.problem.length > 0
                text: root.problem
                color: Design.bad
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 13
            }

            Item { width: 1; height: 8 }

            Row {
                anchors.right: parent.right
                spacing: 12

                DialogButton {
                    text: qsTr("取消")
                    onClicked: root.visible = false
                }

                DialogButton {
                    text: qsTr("应用")
                    primary: true
                    enabled: root.problem.length === 0
                    onClicked: {
                        root.apply_to_bridge()
                        root.applied()
                        root.visible = false
                    }
                }
            }
        }
    }

    // 开/关胶囊。设计系统里没有开关组件，这里做一个与工具栏色块同语言的
    component ToggleChip: Rectangle {
        id: chip

        property bool on_: false
        signal toggled()

        width: 52
        height: 26
        radius: 13
        color: chip.on_ ? Design.primary : Qt.rgba(0.5, 0.5, 0.5, 0.35)

        Text {
            anchors.centerIn: parent
            text: chip.on_ ? qsTr("开") : qsTr("关")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 13
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.toggled()
        }
    }

    // 只能输入数字的小输入框
    component NumberField: Rectangle {
        id: numberField

        property real value: 0
        property real from: 0
        property real to: 100
        property int decimals: 1
        signal edited(real value)

        height: 30
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        function refresh() {
            input.text = numberField.value.toFixed(numberField.decimals)
        }

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 8
            verticalAlignment: TextInput.AlignVCenter
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
            selectByMouse: true
            selectionColor: Design.primary
            selectedTextColor: "#ffffff"
            // DoubleValidator 按数值比较，能把范围与小数位数一起管住
            validator: DoubleValidator {
                bottom: numberField.from
                top: numberField.to
                decimals: numberField.decimals
                notation: DoubleValidator.StandardNotation
            }

            Component.onCompleted: numberField.refresh()
            onEditingFinished: {
                var parsed = Number(input.text)
                if (isNaN(parsed)) {
                    numberField.refresh()
                    return
                }
                // 夹到合法区间再往上写：用户填了越界值时，与其让算法拒绝，
                // 不如当场落到最近的合法值，并在框里显示出来
                parsed = Math.max(numberField.from, Math.min(numberField.to, parsed))
                numberField.edited(parsed)
                numberField.refresh()
            }
        }

        Connections {
            target: numberField
            function onValueChanged() { numberField.refresh() }
        }
    }

    // 弹窗底部的胶囊按钮，与其它弹窗同一套样式
    component DialogButton: Rectangle {
        id: dialogButton

        property string text: ""
        property bool primary: false
        signal clicked()

        width: 121
        height: 35
        radius: 12
        opacity: enabled ? 1.0 : 0.45
        color: dialogButton.primary
               ? (dialogButtonMouse.pressed ? "#64879f" : Design.primary)
               : "transparent"
        border.width: 1
        border.color: dialogButton.primary ? Design.panelBorder : Design.pillBorder

        Text {
            anchors.centerIn: parent
            text: dialogButton.text
            color: dialogButton.primary ? "#ffffff" : "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        MouseArea {
            id: dialogButtonMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: dialogButton.enabled
            onClicked: dialogButton.clicked()
        }
    }
}
