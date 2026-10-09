import QtQuick
import KSCEEGClient

// 「滤波与后处理」弹窗。
//
// 版式按新版设计稿：顶部一排可点的频段预设，下面高通 / 低通两根滑杆，
// 再下面是工频陷波开关，底部取消 / 确认。
//
// 一个刻意的取舍：**先在本地改，点「确认」才下发**。
// 不是因为怕麻烦 —— 每改一次滤波参数，算法侧都会清空滚动缓存并重新预热
// （接口规定「处理配置变化后必须清空滚动缓存」）。边拖边下发的话，
// 拖一次滑杆就会触发一串清空，地形图和频谱会一直停在「数据累积中」。
//
// 另一处：两根滑杆的读数胶囊本身就是开关 —— 蓝色表示该滤波器在起作用，
// 灰色表示关掉了，点一下切换。设计稿里没有单独的开关控件，这个「圆环 + 内点」
// 的语汇和右下角工频陷波那个开关是同一套。
Item {
    id: root

    signal dismissed()
    signal applied()

    // 本地编辑副本。打开时从 Acq 读一次初值，之后只改副本，
    //「确认」才整体写回去
    property bool highPassOn: true
    property real highPassLow: 0.5
    property bool lowPassOn: true
    property real lowPassHigh: 45.0
    property bool notchOn: true

    // 陷波上下限这次没有对应的界面控件，但读写要原样带过去 ——
    // 后端配置是整体的，漏掉就等于把用户原来的设置抹了
    property real notchLow: 48.0
    property real notchHigh: 52.0

    // 采样率决定 Nyquist，进而在输入阶段就挡住必然被算法拒绝的值。
    // 让用户先拖到 900 Hz 再被拒，不如当场夹住
    readonly property real nyquist: Acq.sample_rate() / 2.0
    readonly property real lowPassMax: Math.max(2, Math.min(100, nyquist - 1))

    // 频段预设。副标题是真频率范围，不是设计稿里那串复制粘贴出来的占位值
    readonly property var bandPresets: [
        { symbol: qsTr("全频"), range: "",      highOn: true, high: 0.5, lowOn: true,  low: 45 },
        { symbol: "δ",        range: "0.5-4",   highOn: true, high: 0.5, lowOn: true,  low: 4 },
        { symbol: "θ",        range: "4-8",     highOn: true, high: 4,   lowOn: true,  low: 8 },
        { symbol: "α",        range: "8-13",    highOn: true, high: 8,   lowOn: true,  low: 13 },
        { symbol: "β",        range: "13-30",   highOn: true, high: 13,  lowOn: true,  low: 30 },
        { symbol: "γ",        range: "30-45",   highOn: true, high: 30,  lowOn: true,  low: 45 }
    ]

    // 当前参数落在哪个预设上。落不上任何一个就返回 -1（比如用户自己拖了个
    // 非预设的截止频率），此时一个都不高亮 —— 硬凑到最近的反而会误导
    readonly property int activeBand: {
        if (!highPassOn)
            return -1
        for (var i = 0; i < bandPresets.length; ++i) {
            var p = bandPresets[i]
            if (!p.lowOn) {
                if (!lowPassOn && Math.abs(highPassLow - p.high) < 0.05)
                    return i
                continue
            }
            if (lowPassOn
                && Math.abs(highPassLow - p.high) < 0.3
                && Math.abs(lowPassHigh - Math.min(p.low, lowPassMax)) < 0.6)
                return i
        }
        return -1
    }

    // 当前配置是否有必然被算法拒绝的地方。有就禁用「确认」，
    // 并把原因显示出来 —— 算法侧也有一道校验（会给出规范错误码），
    // 但让用户先看到一个必然失败的操作不如当场说清楚
    readonly property string problem: {
        if (highPassOn && lowPassOn && highPassLow >= lowPassHigh)
            return qsTr("高通截止频率必须低于低通，否则通带为空")
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
    }

    function apply_to_bridge() {
        // 顺序有讲究：先把频率写进去，最后才写开关。
        // 开关一写就会立即下发一次配置；若那一刻频率还是旧值，
        // 用户会看到「确认之后波形弹一下才稳定」
        Acq.highPassLowHz = highPassLow
        Acq.lowPassHighHz = lowPassHigh
        Acq.notchLowHz = notchLow
        Acq.notchHighHz = notchHigh

        Acq.highPassEnabled = highPassOn
        Acq.lowPassEnabled = lowPassOn
        Acq.notchEnabled = notchOn
    }

    function apply_preset(index) {
        var preset = bandPresets[index]
        if (!preset)
            return
        highPassOn = preset.highOn
        highPassLow = preset.high
        lowPassOn = preset.lowOn
        // 关掉低通时不动它的截止频率：用户再打开时还是原来那个值
        if (preset.lowOn)
            lowPassHigh = Math.min(preset.low, lowPassMax)
    }

    // 弹窗每次打开都是新建的（走 Main.qml 的 dialogLoader），
    // 所以在这里读一次初值就够，不需要监听重新可见
    Component.onCompleted: load_from_bridge()

    DialogFrame {
        title: qsTr("滤波")
        cardX: 740
        cardY: 309
        cardWidth: 440
        cardHeight: 462
        dismissOnBackdrop: true
        onDismissed: root.dismissed()

        // ---------- 频段预设 ----------
        PanelDivider { x: 26; y: 74; width: 388 }

        Row {
            x: 26
            y: 94
            spacing: 11

            Repeater {
                model: root.bandPresets

                BandPill {
                    required property int index
                    required property var modelData

                    symbol: modelData.symbol
                    range: modelData.range
                    selected: root.activeBand === index
                    onPicked: root.apply_preset(index)
                }
            }
        }

        // ---------- 高通 ----------
        Text {
            x: 26
            y: 166
            text: qsTr("高通")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        FreqSlider {
            x: 26
            y: 202
            width: 276
            height: 24
            on_: root.highPassOn
            value: root.highPassLow
            from: 0.1
            to: 45
            onEdited: (v) => root.highPassLow = v
        }

        ReadOut {
            x: 318
            y: 200
            on_: root.highPassOn
            value: root.highPassLow
            onToggled: root.highPassOn = !root.highPassOn
        }

        // ---------- 低通 ----------
        Text {
            x: 26
            y: 240
            text: qsTr("低通")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        FreqSlider {
            x: 26
            y: 276
            width: 276
            height: 24
            on_: root.lowPassOn
            value: root.lowPassHigh
            from: 1
            to: root.lowPassMax
            onEdited: (v) => root.lowPassHigh = v
        }

        ReadOut {
            x: 318
            y: 274
            on_: root.lowPassOn
            value: root.lowPassHigh
            onToggled: root.lowPassOn = !root.lowPassOn
        }

        // ---------- 工频陷波 ----------
        Text {
            x: 26
            y: 316
            height: 24
            verticalAlignment: Text.AlignVCenter
            text: qsTr("50Hz工频陷波")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        SwitchPill {
            x: 364
            y: 316
            on_: root.notchOn
            onToggled: root.notchOn = !root.notchOn
        }

        // ---------- 校验提示 ----------
        Text {
            x: 26
            y: 346
            width: 388
            wrapMode: Text.WordWrap
            visible: root.problem.length > 0
            text: root.problem
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 12
        }

        // ---------- 底部按钮 ----------
        PanelDivider { x: 26; y: 372; width: 388 }

        Rectangle {
            x: 108
            y: 396
            width: 145
            height: 40
            radius: 12
            color: "transparent"
            border.width: 1
            border.color: Design.pillBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("取消")
                color: "#4f4f4f"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.dismissed()
            }
        }

        Rectangle {
            x: 269
            y: 396
            width: 145
            height: 40
            radius: 12
            opacity: root.problem.length === 0 ? 1.0 : 0.45
            color: confirmMouse.pressed ? "#64879f" : Design.primary
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("确认")
                color: "#ffffff"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                id: confirmMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.problem.length === 0
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.apply_to_bridge()
                    root.applied()
                }
            }
        }
    }

    // 频段预设胶囊。选中是主色描边 + 淡主色底，未选中是灰底灰字。
    //「全频」只有符号，单行居中；其余符号在上、范围在下
    component BandPill: Rectangle {
        id: band

        property string symbol: ""
        property string range: ""
        property bool selected: false
        signal picked()

        width: 54
        height: 54
        radius: 10
        color: band.selected ? Design.primarySoft
                             : Qt.rgba(0xc9 / 255, 0xc9 / 255, 0xc9 / 255, 0.29)
        border.width: 1
        border.color: band.selected ? Design.primary
                                    : Qt.rgba(0xa3 / 255, 0xa3 / 255, 0xa3 / 255, 0.27)

        Text {
            anchors.centerIn: parent
            visible: band.range.length === 0
            text: band.symbol
            color: band.selected ? Design.primary : Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 15
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8
            visible: band.range.length > 0
            text: band.symbol
            color: band.selected ? Design.primary : Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 15
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 30
            visible: band.range.length > 0
            text: band.range
            color: band.selected ? Design.primary : Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 11
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: band.picked()
        }
    }

    // 频率滑杆。截止频率是按对数分的 —— 0.1 到 45 Hz 用线性的话，
    // 0.1 到 1 这段（最常调的漂移区）会被挤在最左边几个像素里
    component FreqSlider: Item {
        id: slider

        property real value: 1
        property real from: 0.1
        property real to: 30
        property bool on_: true
        signal edited(real value)

        height: 24
        opacity: slider.on_ ? 1.0 : 0.55

        readonly property real safeFrom: Math.max(0.0001, slider.from)
        readonly property real safeTo: Math.max(slider.safeFrom * 1.0001, slider.to)
        readonly property real fraction: {
            var v = Math.max(slider.safeFrom, Math.min(slider.safeTo, slider.value))
            return Math.log(v / slider.safeFrom) / Math.log(slider.safeTo / slider.safeFrom)
        }

        function commit(px) {
            var usable = slider.width - 24
            if (usable <= 0)
                return
            var f = Math.max(0, Math.min(1, (px - 12) / usable))
            slider.edited(slider.safeFrom * Math.pow(slider.safeTo / slider.safeFrom, f))
        }

        Rectangle {
            x: 0
            y: (slider.height - 14) / 2
            width: slider.width
            height: 14
            radius: 7
            color: Qt.rgba(0, 0, 0, 0.07)
        }

        Rectangle {
            x: 0
            y: (slider.height - 14) / 2
            height: 14
            radius: 7
            width: knob.x + knob.width / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: slider.on_ ? "#a8bcc9" : "#cfcfcf" }
                GradientStop { position: 1.0; color: slider.on_ ? Design.primary : "#a1a1a1" }
            }
        }

        Rectangle {
            id: knob
            x: (slider.width - width) * Math.max(0, Math.min(1, slider.fraction))
            y: (slider.height - height) / 2
            width: 24
            height: 24
            radius: 12
            color: slider.on_ ? "#59809c" : "#a1a1a1"
            border.width: 1
            border.color: slider.on_ ? "#416a87" : "#cfcfcf"

            Rectangle {
                anchors.centerIn: parent
                width: 12
                height: 12
                radius: 6
                color: slider.on_ ? "#416a87" : "#919191"
                border.width: 1
                border.color: slider.on_ ? "#ffffff" : "#cfcfcf"
            }
        }

        MouseArea {
            id: sliderMouse
            anchors.fill: parent
            enabled: slider.on_
            cursorShape: Qt.PointingHandCursor
            onPressed: (mouse) => slider.commit(mouse.x)
            onPositionChanged: (mouse) => {
                if (sliderMouse.pressed)
                    slider.commit(mouse.x)
            }
        }
    }

    // 频率读数胶囊，同时也是开/关。蓝 = 开，灰 = 关
    component ReadOut: Rectangle {
        id: readOut

        property real value: 0
        property bool on_: true
        signal toggled()

        width: 96
        height: 28
        radius: 14
        color: readOut.on_ ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
                           : Qt.rgba(0xba / 255, 0xba / 255, 0xba / 255, 0.20)

        Rectangle {
            x: 5
            anchors.verticalCenter: parent.verticalCenter
            width: 17
            height: 17
            radius: 8.5
            color: "transparent"
            border.width: 1
            border.color: readOut.on_ ? Design.primary : "#919191"

            Rectangle {
                anchors.centerIn: parent
                width: 9
                height: 9
                radius: 4.5
                color: readOut.on_ ? Design.primary : "#919191"
            }
        }

        Text {
            x: 28
            anchors.verticalCenter: parent.verticalCenter
            text: Number(readOut.value.toFixed(1)) + "Hz"
            color: readOut.on_ ? Design.primary : "#919191"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: readOut.toggled()
        }
    }

    // 开关。与读数胶囊同一套「圆环 + 内点」，只是会左右滑
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
            id: switchKnob
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
