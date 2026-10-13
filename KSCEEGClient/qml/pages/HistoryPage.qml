import QtQuick
import QtQuick.Controls.Basic
import KSCEEGClient

// 「历史记录」页。设计稿画板 1920×1080，外壳复用 AppShell。
//
// 两套坐标（同 PatientManagementPage）：
//   - 直接摆在画布上的东西（标题条右侧那排筛选控件）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽的东西，坐标要减去内容卡片原点 (154,150)。
Item {
    id: root

    // 顶栏右上角显示的用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    signal navRequested(string label)
    signal logoutRequested()
    signal changePasswordRequested()
    signal deviceInfoRequested()
    signal recordPreviewRequested(string recordNo)
    // 「报告」：打开这条记录的报告（弹框内容与行为待定，先只把记录号交回外层）
    signal recordReportRequested(string recordNo)
    // 删记录：交给外层弹确认框，确认后才真删
    signal recordDeleteRequested(string recordNo)
    // 导出一条记录：落盘了原始数据就复制它，否则导出记录摘要
    signal recordExportRequested(string recordNo)
    // 「分析」：整屏的「数据分析与后处理」。页面自己不认识那一页，
    // 只把记录号交回 Main，由它换页
    signal analysisRequested(string recordNo)

    // 设计稿的电极质量小胶囊：描边与文字同色，良好=绿、不良=橙（描边色即 #ff8d1a）。
    // 注意这里的「不良」在设计稿里画的是品牌橙而不是红色，按设计稿原样保留。
    function qualityColor(level) {
        if (level === "良好")
            return Design.good
        if (level === "一般")
            return Design.warning
        if (level === "不良")
            return Design.brand
        return Design.offline
    }

    // 应用数据库，由外层注入
    property var database
    // 按患者过滤。空串表示不过滤 —— 患者管理页点「记录」进来时会带上这位患者的病历号
    property string patientFilter: ""
    // 过滤时显示的患者名（库里查一次就够，不放在 records 的绑定里）
    property string patientFilterName: ""

    property int revision: 0
    function reload() {
        revision++
        clampPage()
    }

    // 库里的记录（已按患者预筛过）。界面上还要再过一道搜索与通道筛选
    readonly property var allRecords: {
        revision   // 绑定依赖
        return database ? database.sessions(patientFilter) : []
    }

    // ---------- 搜索 / 筛选 / 分页 ----------
    // 与患者管理、用户管理同一套：搜索词 + 一个下拉筛选 + 分页。
    // 原来这一页的搜索框和「全部通道」都是画出来的色块，点不动也筛不了
    property string searchText: ""
    property int channelFilter: 0         // channelChoices 的下标
    property int currentPage: 1

    readonly property var channelChoices: [qsTr("全部通道"), "4", "8", "16"]
    readonly property string channelKeyword:
        channelFilter > 0 && channelFilter < channelChoices.length ? channelChoices[channelFilter] : ""

    readonly property var filteredRecords: {
        var keyword = searchText.trim().toLowerCase()
        var result = []
        for (var i = 0; i < allRecords.length; ++i) {
            var row = allRecords[i]
            if (channelKeyword.length > 0 && row.channels !== channelKeyword)
                continue
            if (keyword.length > 0) {
                // 与设计稿的提示一致：记录ID / 患者姓名
                var haystack = (row.no + " " + Privacy.masked(row.patient)).toLowerCase()
                if (haystack.indexOf(keyword) < 0)
                    continue
            }
            result.push(row)
        }
        return result
    }

    onSearchTextChanged: currentPage = 1
    onChannelFilterChanged: currentPage = 1

    function clampPage() {
        const pages = Math.max(1, Math.ceil(filteredRecords.length / pageSize))
        currentPage = Math.max(1, Math.min(pages, currentPage))
    }

    readonly property int rowHeight: 51
    readonly property int bodyTop: 52
    readonly property int bodyHeight: 788
    // 一屏正好装下的行数，与患者管理页同一口径
    readonly property int pageSize: Math.floor(bodyHeight / rowHeight)

    readonly property var records: {
        const start = (currentPage - 1) * pageSize
        return filteredRecords.slice(start, start + pageSize)
    }

    // 患者下拉的选项：第一项固定是「全部患者」（病案号用空串表示不过滤），
    // 后面按库里患者的顺序排
    readonly property var patientOptions: {
        revision
        var rows = database ? database.patients() : []
        var result = [{ no: "", label: qsTr("全部患者") }]
        for (var i = 0; i < rows.length; ++i)
            result.push({ no: rows[i].no, label: Privacy.masked(rows[i].name) })
        return result
    }

    readonly property var patientOptionLabels: {
        var labels = []
        for (var i = 0; i < patientOptions.length; ++i)
            labels.push(patientOptions[i].label)
        return labels
    }

    // 当前过滤对应的下拉下标；从患者管理页带病历号进来时也要能对上
    readonly property int patientFilterIndex: {
        for (var i = 0; i < patientOptions.length; ++i) {
            if (patientOptions[i].no === patientFilter)
                return i
        }
        return 0
    }

    // 下拉里选患者：0 是「全部患者」，其余按病案号过筛
    function applyPatientIndex(index) {
        if (index <= 0 || index >= patientOptions.length) {
            clearPatientFilter()
            return
        }
        applyPatientFilter(patientOptions[index].no)
    }

    // 清掉过滤，回到全部记录
    function clearPatientFilter() {
        patientFilter = ""
        patientFilterName = ""
        reload()
    }

    // 外层带着病历号进来时调它：把患者名一并从库里补上，界面上要显示是哪一位
    function applyPatientFilter(patientNo) {
        patientFilter = patientNo
        patientFilterName = ""
        if (patientNo.length > 0 && database) {
            var rows = database.patients()
            for (var i = 0; i < rows.length; ++i) {
                if (rows[i].no === patientNo) {
                    patientFilterName = rows[i].name
                    break
                }
            }
        }
        reload()
    }

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("历史采集记录")
        currentNav: qsTr("历史记录")
        statusItems: {
            var items = [qsTr("记录：") + root.allRecords.length + qsTr(" 条")]
            if (root.filteredRecords.length !== root.allRecords.length)
                items.push(qsTr("筛选后：") + root.filteredRecords.length + qsTr(" 条"))
            if (root.patientFilter.length > 0)
                items.push(qsTr("患者：") + (root.patientFilterName.length > 0
                                             ? Privacy.masked(root.patientFilterName)
                                             : Privacy.masked(root.patientFilter)))
            return items
        }
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()
        onChangePasswordRequested: root.changePasswordRequested()
        onDeviceInfoRequested: root.deviceInfoRequested()

        // ---------- 表头 ----------
        // 设计稿坐标 x=272/438/589/771/922/1073/1239/1390/1559，均已减卡片原点 201
        Rectangle {
            x: -47
            y: 0
            width: 1796
            height: 52
            color: Design.primarySoft
        }

        Repeater {
            model: [
                { x: 71,   text: qsTr("记录ID") },
                { x: 237,  text: qsTr("患者") },
                { x: 388,  text: qsTr("采集时间") },
                { x: 570,  text: qsTr("时长") },
                { x: 721,  text: qsTr("通道") },
                { x: 872,  text: qsTr("采样率") },
                { x: 1038, text: qsTr("事件") },
                { x: 1189, text: qsTr("电极质量") },
                { x: 1358, text: qsTr("操作") }
            ]

            delegate: Text {
                required property var modelData
                x: modelData.x
                y: 15
                text: modelData.text
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }

        // ---------- 数据行 ----------
        // 行高 51：设计稿第 1 行底边在卡片内 y=103、第 2 行 154、第 3 行 206，
        // 取整后统一 51，行内各元素再按设计稿的相对偏移摆放。
        Repeater {
            model: root.records

            delegate: Item {
                required property var modelData
                required property int index

                readonly property int rowY: 52 + 51 * index

                // 交替行底色（设计稿只画了第 1 行的 25% 白底）
                Rectangle {
                    x: -47
                    y: rowY
                    width: 1794
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                // 文本基线统一比行顶低 16（设计稿 218-202=16）
                Text { x: 68;   y: rowY + 16; text: modelData.no;       color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 237;  y: rowY + 16; text: Privacy.masked(modelData.patient);  color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 345;  y: rowY + 16; text: modelData.time;     color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 553;  y: rowY + 16; text: modelData.duration; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 727;  y: rowY + 16; text: modelData.channels; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 871;  y: rowY + 16; text: modelData.rate;     color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1049; y: rowY + 16; text: modelData.events;   color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }

                QualityPill {
                    x: 1169
                    y: rowY + 13
                    text: modelData.quality
                    accent: root.qualityColor(modelData.level)
                }

                TableRowButton {
                    x: 1358
                    y: rowY + 11
                    text: qsTr("预览")
                    onClicked: root.recordPreviewRequested(modelData.no)
                }
                TableRowButton {
                    x: 1429
                    y: rowY + 11
                    text: qsTr("报告")
                    onClicked: root.recordReportRequested(modelData.no)
                }
                TableRowButton {
                    x: 1500
                    y: rowY + 11
                    text: qsTr("分析")
                    // 「数据分析与后处理」是另一整屏，由 Main 换页（见 AnalysisPage）
                    onClicked: root.analysisRequested(modelData.no)
                }
                TableRowButton {
                    x: 1571
                    y: rowY + 11
                    text: qsTr("导出")
                    onClicked: root.recordExportRequested(modelData.no)
                }
                // 历史记录页的「删除」在设计稿里不是红色（患者管理页那个才是），照设计稿
                TableRowButton {
                    x: 1642
                    y: rowY + 11
                    text: qsTr("删除")
                    onClicked: root.recordDeleteRequested(modelData.no)
                }

                Rectangle {
                    x: -47
                    y: rowY + 51
                    width: 1763
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.10)
                }
            }
        }

        // ---------- 空态 ----------
        // 三种「空」的原因不同，提示语也要分开：一位记录都没有、这位患者没有、
        // 筛没的。一律说「去工作台采集一次」的话，正在筛选的人会以为数据丢了
        Text {
            x: 71
            y: 200
            width: 1400
            visible: root.records.length === 0
            text: {
                if (root.allRecords.length === 0)
                    return root.patientFilter.length > 0
                           ? qsTr("这位患者还没有采集记录")
                           : qsTr("还没有采集记录，去采集工作台开始一次采集")
                return qsTr("没有符合当前条件的记录，试试换个搜索词或通道数")
            }
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 分页 ----------
        Pager {
            x: 0
            y: 842
            totalCount: root.allRecords.length
            filteredCount: root.filteredRecords.length
            pageSize: root.pageSize
            currentPage: root.currentPage
            onPageRequested: (page) => root.currentPage = page
        }
    }

    // ---------- 标题条右侧的筛选控件（设计稿绝对坐标）----------
    SearchField {
        x: 1374
        y: 79
        width: 215
        height: 43
        placeholder: qsTr("搜索记录ID/患者姓名")
        onTextChanged: root.searchText = text
    }

    // 患者筛选：与右边「全部通道」用同一个 ChoiceField —— 之前这个是手画的色块，
    // 箭头贴在 x=116.5（比 ChoiceField 的 width-24 靠右一截），而且只能「点一下
    // 回到全部患者」，选不了具体某位。现在点开列表挑，第一项是「全部患者」
    ChoiceField {
        id: patientField

        x: 1601
        y: 79
        width: 126
        height: 43
        choices: root.patientOptionLabels
        currentIndex: root.patientFilterIndex
        onActivated: (index) => root.applyPatientIndex(index)
    }

    // ChoiceField 点选时会直接改自己的 currentIndex，把上面的绑定冲掉；
    // 这里在过滤条件真正变化后补一次，保证从患者管理页带病历号进来时也能对上
    onPatientFilterIndexChanged: patientField.currentIndex = patientFilterIndex

    ChoiceField {
        x: 1739
        y: 79
        width: 126
        height: 43
        choices: root.channelChoices
        currentIndex: root.channelFilter
        onActivated: (index) => root.channelFilter = index
    }

    // 电极质量胶囊：设计稿里只有描边没有底色，且文字与描边同色
    // （规格文件把文字记成 #4f4f4f，但渲染图里是跟着档位变的彩色，以渲染图为准）
    component QualityPill: Rectangle {
        id: qualityPill
        property string text: ""
        property color accent: Design.good

        width: 103
        height: 27
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: qualityPill.accent

        Text {
            anchors.centerIn: parent
            text: qualityPill.text
            color: qualityPill.accent
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }
}
