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
    // 需要在界面上说一句话（阻抗扫描完成、导出结果之类），由外层弹轻提示
    signal notifyRequested(string message, string kind)

    property string userName: "管理员"
    property string userRole: "管理员"
    // 可选的事件标签，来自系统设置里维护的那一份（由 Main 注入）。
    // 原来事件只有「手动标记」一种，标签是写死的
    property var tags: []
    // 记录落盘目录，取自系统设置的「记录保存目录」（由 Main 注入）。
    // 空串表示没设过，由 C++ 侧退回默认目录 —— 原来这里**始终**传空串，
    // 于是系统设置里那个目录改了也不生效，记录一直落在默认位置
    property string recordDir: ""
    // 刚进工作台时是**没有患者**的：设计稿对应「未选择患者 / 点击选择/登记」
    // 那块空态卡片，选完患者才切成患者信息。效果图 E:/UI/效果/未选择患者.png
    property bool hasPatient: false
    property string patientNo: ""
    property string patientName: ""
    property string patientGenderAge: ""
    property string patientMeta: ""

    // 「选择/登记患者」弹窗确认后由外层调用，参数是 patients 表里的一行
    function setPatient(row) {
        if (!row || !row.no) {
            return
        }
        patientNo = row.no
        patientName = row.name
        patientGenderAge = row.gender + "  " + row.age + qsTr("岁")
        // 「记录1次」：N 与「次」之间设计稿没有空格，所以用原始数值拼。
        // 数据层那个 count 是给表格列的 "1 次"，格式不一样，贴在这里会多一个空格
        patientMeta = row.no + "·" + row.dept + qsTr("·记录") + row.recordCount + qsTr("次")
        hasPatient = true
    }

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

    // ---------- 时基 / 走纸速度的换算 ----------
    // 波形区横向分 4 格（见 WaveformPanel：5 个刻度、4 段间隔），所以每格秒数 = 时窗 / 4。
    // 默认时窗 2 秒 → 0.5 s/div，正是工具栏和底栏要显示的值
    readonly property real secondsPerDiv: Acq.timeWindow / 4
    // 走纸速度按**屏幕真实物理尺寸**反算，不再用设计稿那句「一屏 30mm、15mm/s」的标称值：
    // 那句假定一屏(4格)只有 30mm，而本机屏幕实测宽 525mm、一屏(1037px) 实为 ≈283.55mm，
    // 两者差 9.45 倍。下面三个常量给出这个物理换算的全部输入：
    //   屏幕物理宽 525mm ↔ 原生横向 1920px  →  1 逻辑px = 525 / 1920 mm
    //   波形区宽 1037px（与 WaveformPanel.plotWidth 一致）  →  一屏 = 1037 × 525 / 1920 ≈ 283.55mm
    // 时窗 seconds 内正好走完这一屏，所以 走纸速度 = 一屏毫米数 / 时窗（时窗 2s 时 ≈141.8mm/s）。
    // 屏幕换了或分辨率/缩放变了，只要改 screenWidthMM / screenWidthPx 即可
    readonly property real screenWidthMM: 525
    readonly property real screenWidthPx: 1920
    readonly property real plotWidthPx: 1037
    readonly property real plotWidthMM: plotWidthPx * screenWidthMM / screenWidthPx
    readonly property real paperSpeed: plotWidthMM / Math.max(0.1, Acq.timeWindow)

    // 去掉多余的零：0.50 → "0.5"、15.0 → "15"
    readonly property string timeBaseText: Number(secondsPerDiv.toFixed(2)) + " s/div"
    readonly property string paperSpeedText: Number(paperSpeed.toFixed(1)) + "mm/s"


    function resetSession() {
        frozen = false
        elapsedSeconds = 0
        // 重新进工作台就回到「未选择患者」：设计稿里这一页是**从选患者开始**的
        hasPatient = false
        patientNo = ""
        patientName = ""
        patientGenderAge = ""
        patientMeta = ""
        selectedNav = qsTr("采集工作台")
    }

    function stopCollection() {
        frozen = false
        Acq.stop_collection()
    }

    // 采集前确认通过后由外层调用。
    // 「开始采集」在 C++ 侧做三件事：建在线算法会话、开串口、按时间戳建文件落盘；
    // C++ 那边每次也会重置采集计时器并清空事件列表，所以这里同步把时长归零、清事件，
    // 让「开始采集」一律从 00:00 重新计
    function startCollection() {
        frozen = false
        elapsedSeconds = 0
        Acq.clear_events()
        // 开始采集时把阻抗扫描关掉：先复位面板上可能还在跑的扫描动画，
        // 再由 C++ 侧的 start_collection() 发 's' 让设备停发阻抗帧、切回脑电数据流
        electrodePanel.cancelScan()
        // 带上病历号：C++ 会按患者建子目录落盘（目录名用病历号，不用姓名）
        Acq.start_collection(recordDir, patientNo)
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
        userRole: root.userRole
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

    // 电极贴合胶囊。**没有设备直读的电极级阻抗**（协议只给 4 路不带电极名的值，
    // 见 serialprotocol.h 的 parse_impedance_kohm），所以扫过阻抗之后这里显示的是
    // 由信号估计出来的接触质量；没扫过时按设计稿写 16/16。
    // 与左侧面板、采集前确认弹窗共用同一份结果，三处不会再各说各话
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
            text: Design.electrodePillText(Acq.electrodeScanValid ? Acq.electrodeQuality : [])
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

        // 姓名与档案摘要之间的竖分隔线。空态下没有姓名，这条线就没有意义。
        //
        // 位置取「设计稿的 96」与「姓名右边缘 + 空隙」中较大的那个：三个字的名字
        // 正好落在设计稿的位置上，更长的名字才把分隔线和右边两行一起往右让 ——
        // 写死 96 的话四个字以上就会跨过这条线压到性别年龄上
        Rectangle {
            id: nameDivider
            x: Math.max(96, nameText.x + nameText.width + 10)
            y: 16
            width: 1
            height: 44
            visible: root.hasPatient
            color: "#c2c2c2"
        }

        // ---------- 有患者：姓名 + 性别年龄 + 档案摘要 ----------
        // 姓名按文字实际宽度排，200 只是名字太长时的截断上限。
        // 不能写死 width: 200 —— 分隔线是按姓名右边缘 + 空隙算的，死宽会让
        // 三个字的名字也把分隔线顶到 222，右边两行被挤到卡片边上
        Text {
            id: nameText
            x: 12
            y: 21
            width: Math.min(implicitWidth, 200)
            elide: Text.ElideRight
            visible: root.hasPatient
            text: root.patientName
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 24
        }

        Text {
            x: nameDivider.x + 14
            y: 12
            visible: root.hasPatient
            text: root.patientGenderAge
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: nameDivider.x + 14
            y: 42
            width: Math.max(0, parent.width - x - 12)
            elide: Text.ElideRight
            visible: root.hasPatient
            text: root.patientMeta
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 未选择患者：两行居中文字 ----------
        // 位置按效果图量的：两行都水平居中于卡片，第一行中心 y≈23、第二行 y≈53
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 12
            visible: !root.hasPatient
            text: qsTr("未选择患者")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 45
            visible: !root.hasPatient
            text: qsTr("点击选择/登记")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 15
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
    // 量程。用下拉列表选，不再点一下切到下一档 —— 六档要连点好几次才轮到想要的
    ChoiceField {
        x: 734
        y: 79
        width: 116
        // 单位用 EEG 灵敏度的标准写法「μV/div」（每格多少微伏），不再只写「±100μV」——
        // 后者看不出「每格」这层意思，和旁边的时基也对不上
        choices: rangeValues.map(function (v) { return v > 0 ? v + "μV/div" : qsTr("自动") })
        currentIndex: Math.max(0, rangeValues.indexOf(Acq.yRangeUV))
        onActivated: (index) => Acq.yRangeUV = rangeValues[index]

        readonly property var rangeValues: [0, 50, 100, 200, 400, 1000]
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

    // 时基。单位是 s/div（每竖格多少秒），不再是「秒/屏」，也不再照抄设计稿那个
    // 明显写错的「50μV/div」——那是幅值的单位，标在时基上没有任何意义。
    // 选项按 s/div 取整（换算成一屏秒数就是 0.4/0.8/2/4/8 秒）
    ChoiceField {
        x: 917
        y: 79
        width: 104
        choices: windowValues.map(function (w) { return Number((w / 4).toFixed(2)) + " s/div" })
        currentIndex: Math.max(0, windowValues.indexOf(Acq.timeWindow))
        onActivated: (index) => Acq.timeWindow = windowValues[index]

        readonly property var windowValues: [0.4, 0.8, 2, 4, 8]
    }

    // 走纸速度不是写死的：它由屏幕物理尺寸与时基算出（见 root.paperSpeed），
    // 否则用户改了时基之后这句说明还挂着旧值，与真实参数自相矛盾
    Text {
        id: paperSpeedLabel
        x: 1037
        y: 90
        text: qsTr("(走纸速度：") + root.paperSpeedText + ")"
        color: "#3b3b3b"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 16
    }

    // 分隔线与「滤波与后处理」跟随走纸速度文字的实际宽度向右排。
    // 设计稿把两者写死在 1204 / 1224，那是按「15mm/s」这种短文本量的；
    // 走纸速度改用物理真值后文本变成「141.8mm/s」，写死的竖杠就压住最后一个字
    Rectangle {
        id: paperSpeedSeparator
        x: paperSpeedLabel.x + paperSpeedLabel.width + 18
        y: 87
        width: 1
        height: 27
        color: Design.primary
    }

    // 滤波与后处理。设计稿里它只是个色块，这里接上弹窗
    Rectangle {
        x: paperSpeedSeparator.x + 20
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
            ToolTip.text: qsTr("频段预设 / 高通 / 低通 / 陷波")
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
    // 采集中切成设计稿的「停止采集」态：橙色底 + 白色方块 + 停止采集。
    // 效果图 E:/UI/效果/停止采集.png —— 底色是设计系统的橙（不是红），
    // 图标是圆角方块（不是播放三角）
    Rectangle {
        id: startButton
        x: 107
        y: 150
        width: 331
        height: 64
        radius: 18
        color: root.collecting ? (startMouse.pressed ? "#e8954f" : Design.stopButton)
                               : (startMouse.pressed ? "#64879f" : Design.primary)
        // 未选患者时压暗：按钮点不动必须有视觉依据，否则用户只会觉得「点了没反应」
        opacity: (!root.collecting && !root.hasPatient) ? 0.45 : 1.0

        // 开始态：设计稿的播放三角（矢量原样用，只旋转 -90 让它朝右）
        Image {
            x: 103.75
            y: 22.19
            width: 16.13
            height: 14.5
            rotation: -90
            visible: !root.collecting
            source: Design.assetRoot + "icons/icon-play.svg"
        }

        // 停止态：白色圆角方块。位置与尺寸按效果图量的（16×16、垂直居中、
        // 与播放三角同一列）。用 Rectangle 画而不是再加一个 svg ——
        // 一个方块不值得多一个资源文件
        Rectangle {
            x: 104
            y: 24
            width: 16
            height: 16
            radius: 4
            visible: root.collecting
            color: "#ffffff"
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
                if (root.collecting) {
                    root.stopCollection()
                } else if (root.hasPatient) {
                    // 串口在登录成功后已独立连上，这里只做检查：没连上就提示，
                    // 不再自动补连（连接与采集已解耦）。演示模式没有真实串口，
                    // 由 Acq.demoSource 放行。
                    // 真正的采集指令仍要等用户在框里点「确认并开始」才发
                    if (!Acq.portOpen && !Acq.demoSource) {
                        root.notifyRequested(qsTr("请先连接设备"), "warn")
                        return
                    }
                    root.precheckRequested()
                } else {
                    // 没选患者：这一页采集的数据要挂到某位患者名下，没有对象就开始采
                    // 会后无从归属。这里只给一句提示，**不主动把选择患者弹窗推出来** ——
                    // 用户可能只是想先看看，也可能是误点，一屏弹窗盖上来太打扰。
                    // 要选患者，点左上角那张卡片（那里本来就写着「点击选择/登记」）
                    root.notifyRequested(qsTr("请先选择患者再开始采集"), "warn")
                }
            }

            ToolTip.visible: containsMouse && !root.collecting && !root.hasPatient
            ToolTip.text: qsTr("请先选择患者")
            ToolTip.delay: 300
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
        elapsedSeconds: root.elapsedSeconds
    }

    ElectrodePanel {
        id: electrodePanel
        x: 107
        y: 225
        width: 331
        height: 499
        // 扫描结果由面板自己算，这里只负责把小结交给外层弹提示 ——
        // 16 行列表在 331 宽的格子里只能露出 4 行，不看提示就不知道整体如何
        onScanFinished: (summary) => {
            if (summary.length > 0)
                root.notifyRequested(qsTr("阻抗扫描完成：") + summary, "info")
        }
    }

    EventPanel {
        id: eventPanel
        x: 107
        y: 738
        width: 331
        height: 296
        collecting: root.collecting
        tags: root.tags
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
                qsTr("时基：") + root.timeBaseText + qsTr("(走纸速度：") + root.paperSpeedText + ")",
                Acq.yRangeUV > 0 ? qsTr("幅值：") + Acq.yRangeUV + "μV/div" : qsTr("幅值：自动"),
                Acq.statsText,
                // 未选患者时不能还挂着一个人名 —— 与左上角那张卡片保持一致
                qsTr("患者：") + (root.hasPatient ? root.patientName : qsTr("未选择"))
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
