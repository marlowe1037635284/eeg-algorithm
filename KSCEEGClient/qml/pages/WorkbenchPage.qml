import QtQuick
import QtQuick.Controls.Basic
import QtCore
import KSCEEGClient

// 采集工作台。按设计稿「采集工作台」画板 1:1 还原。
//
// 所有坐标都是设计稿画板（1920×1080）上的绝对坐标，缩放由外层的 DesignCanvas 统一负责。
// 各面板拆成了独立文件（WaveformPanel 等），那些文件内部用的是「相对面板左上角」
// 的坐标，方便单独维护。
Item {
    id: root

    signal logoutRequested()
    signal snapshotRequested()
    signal clearRequested()
    // 点「开始采集」时发出去，由外层弹「开始采集前确认」；确认后再调 startCollection()
    signal precheckRequested()
    // 窄导航条（只有图标）点击时把目标页交给外层
    signal navRequested(string label)
    // 点患者卡片 → 弹「选择/登记患者」
    signal selectPatientRequested()
    // 点工具栏「滤波与后处理」→ 弹滤波配置
    signal filterRequested()

    property string userName: "管理员"
    property string userRole: "管理员"
    property string patientName: "张文涛"
    property string patientGenderAge: "男  45岁"
    property string patientMeta: "P-0001·神经内科·记录1次"

    // collecting 直接绑到 Acq：真正的开关是 C++ 侧的采集线程，
    // QML 再存一份的话两者迟早不同步（拔线时线程自己就退了）
    readonly property bool collecting: Acq.collecting
    // 冻结是**显示**上的暂停：数据照常采集与进缓冲，只是画面停住
    property bool frozen: false
    property int elapsedSeconds: 0
    property string selectedNav: qsTr("采集工作台")

    readonly property string elapsedText: {
        var hours = Math.floor(elapsedSeconds / 3600)
        var minutes = Math.floor((elapsedSeconds % 3600) / 60)
        var seconds = elapsedSeconds % 60
        return String(hours).padStart(2, "0") + ":" +
               String(minutes).padStart(2, "0") + ":" +
               String(seconds).padStart(2, "0")
    }


    function resetSession() {
        frozen = false
        elapsedSeconds = 0
        selectedNav = qsTr("采集工作台")
    }

    function stopCollection() {
        frozen = false
        Acq.stop_collection()
    }

    // 采集前确认通过后由外层调用。
    // 「开始采集」在 C++ 侧做三件事：建在线算法会话、开串口、按时间戳建文件落盘
    function startCollection() {
        frozen = false
        if (elapsedSeconds === 0)
            Acq.clear_events()
        Acq.start_collection("")
    }

    // 「截图」：把当前界面存成 PNG 放到系统图片目录下，失败就静默跳过
    function saveSnapshot() {
        canvas.grabToImage(function(result) {
            var stamp = Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss")
            var folder = StandardPaths.writableLocation(StandardPaths.PicturesLocation)
            if (!folder)
                folder = StandardPaths.writableLocation(StandardPaths.HomeLocation)
            if (folder)
                result.saveToFile(folder + "/EEG-KSC-" + stamp + ".png")
        })
    }

    onClearRequested: eventPanel.clearEvents()
    onSnapshotRequested: saveSnapshot()

    // 波形不再由定时器推进：数据由 C++ 侧的采集线程经算法处理后推过来，
    // WaveformPanel 收到 Acq.waveRevision 变化才重绘。这里只留计时
    Timer {
        interval: 1000
        repeat: true
        running: root.collecting && root.visible
        onTriggered: root.elapsedSeconds += 1
    }

    DesignCanvas {
        id: canvas
        anchors.fill: parent

    // ---------- 背景 ----------
    Image {
        x: -8
        y: -2
        width: 1928
        height: 1085
        source: Design.assetRoot + "login-background.jpg"
        fillMode: Image.Stretch
        smooth: true
        mipmap: true
    }

    // 设计稿里两个大椭圆装饰（浅蓝在上、浅橙在下），都带 272px 模糊
    SoftBlob {
        x: 659
        y: -370
        tint: Design.primary
        peakAlpha: 0.19
    }

    SoftBlob {
        x: -596
        y: 700
        tint: Design.brand
        peakAlpha: 0.05
    }

    // ---------- 左侧导航条（与各业务页共用同一个组件）----------
    AppNavRail {
        current: root.selectedNav
        onNavRequested: (label) => root.navRequested(label)
    }

    // ---------- 顶栏 ----------
    Rectangle {
        x: 92
        y: 51
        width: 1828
        height: 1
        color: Design.divider
    }

    // 设备状态胶囊
    Rectangle {
        x: 1412
        y: 12
        width: 188
        height: 27
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: Design.pillBorder

        Rectangle {
            x: 13
            y: 10
            width: 8
            height: 8
            radius: 4
            color: Acq.portOpen ? Design.good : Design.offline
        }

        Text {
            x: 31
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: Acq.portOpen ? qsTr("Neurolink-6016 已连接") : qsTr("Neurolink-6016 未连接")
            color: "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // 电极贴合胶囊。
    // 注意这一项**没有数据源**：串口协议一次只给 4 路不带电极名的阻抗值
    // （见 serialprotocol.h 的 parse_impedance_kohm），没法推出「16 个电极各有
    // 多好」。所以它保持设计稿的静态显示，不做假数据绑定
    Rectangle {
        x: 1612
        y: 12
        width: 153
        height: 27
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: Design.pillBorder

        Text {
            x: 12
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("电极贴合  16/16 良好")
            color: "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // 用户信息（点击退出登录）
    Rectangle {
        x: 1788
        y: 7
        width: 37
        height: 37
        radius: 19
        color: Design.primary

        Text {
            anchors.centerIn: parent
            text: Design.avatarText(root.userName)
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    Text {
        x: 1833
        y: 8
        text: root.userName
        color: "#4f4f4f"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    Text {
        x: 1833
        y: 26
        text: root.userRole
        color: "#878787"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 12
    }

    Image {
        x: 1893.5
        y: 22.77
        width: 7.47
        height: 7
        rotation: -90
        source: Design.assetRoot + "icons/icon-arrow-down.svg"
    }

    MouseArea {
        x: 1788
        y: 4
        width: 122
        height: 44
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.logoutRequested()

        ToolTip.visible: containsMouse
        ToolTip.text: qsTr("点击退出登录")
        ToolTip.delay: 400
    }

    // ---------- 患者信息卡片 ----------
    Rectangle {
        x: 107
        y: 63
        width: 331
        height: 75
        radius: 18
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Rectangle {
            x: 96
            y: 16
            width: 1
            height: 44
            color: "#c2c2c2"
        }

        Text {
            x: 12
            y: 21
            text: root.patientName
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 24
        }

        Text {
            x: 110
            y: 12
            text: root.patientGenderAge
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: 110
            y: 42
            text: root.patientMeta
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectPatientRequested()

            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("选择/登记患者")
            ToolTip.delay: 400
        }
    }

    // ---------- 工具栏 ----------
    Rectangle {
        x: 450
        y: 63
        width: 1453
        height: 75
        radius: 18
        color: Design.panelFill
        border.width: 1
        border.color: Design.panelBorder
    }

    Text {
        x: 471
        y: 87
        text: qsTr("通道")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 通道档位：4 / 8 / 16
    Item {
        x: 518
        y: 79
        width: 139
        height: 43

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder
        }

        // 当前档位的高亮块（设计稿里是橙色圆角块，位置对准选中的数字）
        Image {
            x: Acq.channelCount === 4 ? 5 : Acq.channelCount === 8 ? 48 : 91
            y: 4
            width: 43
            height: 36
            source: Design.assetRoot + "icons/slider-thumb.svg"
            fillMode: Image.Stretch
        }

        Repeater {
            model: [
                { value: 4,  x: 21,  w: 11 },
                { value: 8,  x: 64,  w: 11 },
                { value: 16, x: 102, w: 21 }
            ]

            delegate: Text {
                required property var modelData
                x: modelData.x
                y: 0
                width: modelData.w
                height: 43
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData.value
                color: Acq.channelCount === modelData.value ? "#ffffff" : Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 18

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -8
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Acq.channelCount = modelData.value
                }
            }
        }
    }

    Rectangle {
        x: 673
        y: 87
        width: 1
        height: 27
        color: Design.primary
    }

    Text {
        x: 689
        y: 87
        text: qsTr("幅值")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 设计稿这里是静态样式，但幅值直接影响波形怎么读，做成可点击循环 ——
    // 不新增控件，只多一个点击区域
    ToolField {
        id: rangeField
        x: 734
        y: 79
        width: 116
        value: Acq.yRangeUV > 0 ? "±" + Acq.yRangeUV + "μV" : qsTr("自动量程")

        readonly property var choices: [0, 50, 100, 200, 400, 1000]

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                var list = rangeField.choices
                var index = list.indexOf(Acq.yRangeUV)
                Acq.yRangeUV = list[(index + 1) % list.length]
            }
            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("点击切换量程")
            ToolTip.delay: 400
        }
    }

    Text {
        x: 872
        y: 87
        text: qsTr("时基")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 18
    }

    // 设计稿这一格的值写的是「50μV/div」，与后面的括号说明「走纸速度 15mm/s」
    // 以及它自己「时基」的标题都对不上 —— 幅值已经有一格了，这里按语义显示时窗
    ToolField {
        id: windowField
        x: 917
        y: 79
        width: 104
        value: Acq.timeWindow + qsTr("秒/屏")
        showArrow: true
        arrowX: 85

        readonly property var choices: [0.5, 1, 2, 5, 10]

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                var list = windowField.choices
                var index = list.indexOf(Acq.timeWindow)
                Acq.timeWindow = list[(index + 1) % list.length]
            }
            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("点击切换显示时窗")
            ToolTip.delay: 400
        }
    }

    // 新版设计稿在时基后面加了一段括号说明（照抄）
    Text {
        x: 1037
        y: 90
        text: qsTr("(走纸速度：15mm/s)")
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 16
    }

    Rectangle {
        x: 1204
        y: 87
        width: 1
        height: 27
        color: Design.primary
    }

    // 滤波与后处理。设计稿里它只是个色块，这里接上弹窗
    Rectangle {
        x: 1224
        y: 79
        width: 137
        height: 43
        radius: 12
        color: filterMouse.containsMouse ? Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.18)
                                         : Design.primarySoft

        Text {
            x: 16
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("滤波与后处理")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        MouseArea {
            id: filterMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.filterRequested()

            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("高通 / 低通 / 陷波 / ASR / 重参考")
            ToolTip.delay: 400
        }
    }

    // 冻结
    ToolButton {
        x: 1582
        width: 89
        text: root.frozen ? qsTr("继续") : qsTr("冻结")
        iconSource: Design.assetRoot + "icons/icon-freeze.svg"
        iconWidth: 17
        iconHeight: 17
        enabled: root.collecting
        onClicked: root.frozen = !root.frozen
    }

    // 截图
    ToolButton {
        x: 1689
        width: 89
        text: qsTr("截图")
        iconSource: Design.assetRoot + "icons/icon-camera.svg"
        iconWidth: 16
        iconHeight: 16
        onClicked: root.snapshotRequested()
    }

    // 清空
    ToolButton {
        x: 1796
        width: 89
        text: qsTr("清空")
        hasIcon: false
        onClicked: root.clearRequested()
    }

    // ---------- 开始 / 停止采集 ----------
    // 设计稿只有「开始采集」这一态；采集中沿用原实现的语义，做成红色「停止采集」
    Rectangle {
        id: startButton
        x: 107
        y: 150
        width: 331
        height: 64
        radius: 18
        color: root.collecting ? (startMouse.pressed ? "#bd4d45" : Design.bad)
                               : (startMouse.pressed ? "#64879f" : Design.primary)

        Image {
            x: 103.75
            y: 22.19
            width: 16.13
            height: 14.5
            rotation: -90
            source: Design.assetRoot + "icons/icon-play.svg"
        }

        Text {
            x: 131
            y: 15
            text: root.collecting ? qsTr("停止采集") : qsTr("开始采集")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 24
        }

        MouseArea {
            id: startMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                // 开始之前先走「开始采集前确认」，停止则直接停
                if (root.collecting)
                    root.stopCollection()
                else
                    root.precheckRequested()
            }
        }
    }

    // ---------- 三个主面板 ----------
    WaveformPanel {
        x: 450
        y: 150
        width: 1109
        height: 884
        collecting: root.collecting
        frozen: root.frozen
        channelCount: Acq.channelCount
    }

    ElectrodePanel {
        x: 107
        y: 225
        width: 331
        height: 499
    }

    EventPanel {
        id: eventPanel
        x: 107
        y: 738
        width: 331
        height: 296
    }

    TopographyPanel {
        x: 1572
        y: 150
        width: 331
        height: 590
    }

    SpectrumPanel {
        x: 1572
        y: 754
        width: 331
        height: 280
        collecting: root.collecting
        frozen: root.frozen
    }

    // ---------- 错误条 ----------
    // 设计稿没有这一条。加它是必需的：算法调用失败、串口打不开这类问题
    // 在原来那份静态界面上根本无处显示，用户只会看到「点了没反应」。
    // 只在出错时出现，且做成一条细带，尽量不干扰设计稿的排布
    Rectangle {
        x: 450
        y: Acq.errorText.length > 0 ? 1000 : 1046
        width: 1109
        height: Acq.errorText.length > 0 ? 40 : 0
        radius: 10
        visible: Acq.errorText.length > 0
        color: "#f7e7e7"
        border.width: 1
        border.color: "#e0b4b4"
        clip: true

        Text {
            x: 14
            y: 0
            width: parent.width - 120
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: Acq.errorText
            color: "#8a3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        // 会话进了 ERROR 之后，复位是唯一的恢复入口（接口规定此时只允许
        // reset / get_status / close）。所以错误条上直接给按钮，
        // 不让用户去别处找
        Rectangle {
            x: parent.width - 196
            y: 6
            width: 90
            height: 28
            radius: 10
            visible: Acq.canReset
            color: resetMouse.pressed ? "#64879f" : Design.primary

            Text {
                anchors.centerIn: parent
                text: qsTr("重置会话")
                color: "#ffffff"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                id: resetMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Acq.reset_session()
            }
        }

        Rectangle {
            x: parent.width - 96
            y: 6
            width: 82
            height: 28
            radius: 10
            color: closeErrorMouse.pressed ? "transparent" : Qt.rgba(0, 0, 0, 0.04)
            border.width: 1
            border.color: Design.pillBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("关闭")
                color: "#4f4f4f"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                id: closeErrorMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Acq.clear_error()
            }
        }
    }

    // ---------- 底部状态栏 ----------
    Rectangle {
        x: 92
        y: 1046
        width: 1828
        height: 34
        color: Design.panelFill
    }

    Rectangle {
        x: 92
        y: 1046
        width: 1828
        height: 1
        color: Design.divider
    }

    Rectangle {
        x: 117
        y: 1057
        width: 12
        height: 12
        radius: 6
        color: root.collecting ? Design.good : Design.offline
    }

    // 状态栏第一段：采集状态 + 串口/算法给的状态文本。
    // 原来的「采集进行中/已停止」只有两种状态，看不出「串口开着但没采」
    // 和「算法在预热」这些中间态
    // 放在「记录时长」之后、右侧那排指标之前的那段空白里（设计稿这里是空的），
    // 不和任何已有元素重叠
    Text {
        x: 430
        y: 1052
        width: 690
        elide: Text.ElideRight
        text: {
            if (Acq.errorText.length > 0)
                return qsTr("异常：") + Acq.errorText
            if (Acq.warmupText.length > 0)
                return Acq.warmupText
            return Acq.statusText
        }
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // 设计稿这一行没有「记录时长」，但原来实现里有计时，放在这处空白
    Text {
        x: 250
        y: 1052
        text: qsTr("记录时长  ") + root.elapsedText
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    // 底栏这几项原来全是写死的（采样率 256Hz、数据点 1,024、电极 10/16 良好…），
    // 与面板上的实际值互相矛盾。全部换成真实值；「电极良好数」没有数据源
    // （协议只有 4 路无名字的阻抗，见 serialprotocol.h），所以整条去掉。
    //
    // 排布改成**从右往左依次排列**，不再是设计稿里那套写死的 x 坐标：
    // 那些坐标是按「采样率：256Hz」这类固定短文本量的，而真实数值长度会变
    // （「已收 12514 帧 · 已存 12514 帧 · 丢弃 0 字节」比它长一倍多），
    // 按固定 x 排就会和后一项叠在一起、糊成一片
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 27
        y: 1052
        spacing: 22

        Repeater {
            model: [
                qsTr("采样率：") + Acq.sample_rate() + "Hz",
                qsTr("时窗：") + Acq.timeWindow + qsTr("秒/屏"),
                Acq.yRangeUV > 0 ? qsTr("幅值：±") + Acq.yRangeUV + "μV" : qsTr("幅值：自动"),
                Acq.statsText,
                qsTr("患者：") + root.patientName
            ]

            delegate: Text {
                required property string modelData
                text: modelData
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }
        }
    }
    }

    // 工具栏里的下拉样控件（设计稿是静态样式，这里只是外观）
    component ToolField: Rectangle {
        id: toolField
        property string value: ""
        property bool showArrow: false
        property real arrowX: 0
        height: 43
        radius: 12
        color: Design.primarySoft

        Text {
            x: 9
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: toolField.value
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Image {
            x: toolField.arrowX
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
            visible: toolField.showArrow
        }
    }

    // 工具栏右侧的圆角按钮（冻结 / 截图 / 清空）
    component ToolButton: Rectangle {
        id: toolButton
        property string text: ""
        property string iconSource: ""
        property real iconWidth: 16
        property real iconHeight: 16
        property bool hasIcon: true
        property bool interactive: true
        signal clicked()

        y: 79
        height: 43
        radius: 12
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder
        opacity: toolButton.interactive && toolButton.enabled ? 1 : 0.45

        Image {
            x: 17
            y: 13
            width: toolButton.iconWidth
            height: toolButton.iconHeight
            source: toolButton.iconSource
            visible: toolButton.hasIcon
        }

        Text {
            x: toolButton.hasIcon ? 39 : 27
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: toolButton.text
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        MouseArea {
            anchors.fill: parent
            enabled: toolButton.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toolButton.clicked()
        }
    }
}
