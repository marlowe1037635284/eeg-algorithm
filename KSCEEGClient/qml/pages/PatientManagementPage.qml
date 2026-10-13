import QtQuick
import KSCEEGClient

// 「患者管理」页。设计稿画板 1920×1080，用 AppShell 当外壳。
//
// 注意两套坐标：
//   - 页面里直接摆在画布上的东西（顶栏右侧那排控件）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽里的东西，坐标要减去内容卡片原点 (154,150)，
//     因为 AppShell 的 contentArea 已经定位在那里了。
Item {
    id: root

    // 顶栏右上角显示的用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    signal navRequested(string label)
    signal logoutRequested()
    signal changePasswordRequested()
    signal deviceInfoRequested()
    signal newPatientRequested()
    signal editPatientRequested(string recordNo)
    // 「设为当前」与点整行：把这位患者设为工作台的当前患者
    signal patientActivated(string patientNo)
    // 「记录」：设为当前并跳到历史记录页（按这位患者过滤）
    signal openRecordsRequested(string patientNo)
    // 「删除」：交给外层弹确认框，确认后才真删
    signal deletePatientRequested(string patientNo)

    // 应用数据库，由外层注入
    property var database
    // 工作台当前选中的患者。它属于「本次会话」，不是患者表里的字段，
    // 所以由外层传进来而不是从库里读
    property string currentPatientNo: ""

    // ---------- 数据 ----------
    // 列表来自 patients 表。Q_INVOKABLE 没有变更通知，用一个 revision 显式触发重算：
    // 进页面、新增或删除患者之后调 reload()
    property int revision: 0
    function reload() {
        revision++
        clampPage()
    }

    readonly property var allPatients: {
        revision   // 绑定依赖
        return database ? database.patients() : []
    }

    // ---------- 搜索 / 筛选 / 分页 ----------
    // 三个列表页共用同一套：搜索词 + 一个下拉筛选 + 分页。
    // 原来这一页的搜索框和科室下拉都是画出来的色块，点不动也筛不了
    property string searchText: ""
    property int deptFilter: 0            // deptChoices 的下标，0 = 全部科室
    property int currentPage: 1

    // 科室下拉的选项从**库里实际有的科室**归纳，不另写一份固定表：
    // 写死的话，新增患者时填了表外的科室，这里就永远筛不出来
    readonly property var deptChoices: {
        var names = [qsTr("全部科室")]
        for (var i = 0; i < allPatients.length; ++i) {
            var dept = allPatients[i].dept
            if (dept.length > 0 && names.indexOf(dept) < 0)
                names.push(dept)
        }
        return names
    }
    readonly property string deptKeyword:
        (deptFilter > 0 && deptFilter < deptChoices.length) ? deptChoices[deptFilter] : ""

    readonly property var filteredPatients: {
        var keyword = searchText.trim().toLowerCase()
        var result = []
        for (var i = 0; i < allPatients.length; ++i) {
            var row = allPatients[i]
            if (deptKeyword.length > 0 && row.dept !== deptKeyword)
                continue
            if (keyword.length > 0) {
                // 与设计稿的提示一致：病历号 / 姓名 / 诊断
                var haystack = (row.no + " " + Privacy.masked(row.name) + " " + row.diag).toLowerCase()
                if (haystack.indexOf(keyword) < 0)
                    continue
            }
            result.push(row)
        }
        return result
    }

    // 改搜索词或换科室之后回到第 1 页：留在第 3 页看一份只剩两条的结果没有意义
    onSearchTextChanged: currentPage = 1
    onDeptFilterChanged: currentPage = 1

    // 科室选项是从数据里归纳的，会随患者增减伸缩。原来选中的那个科室
    // 如果最后一个患者被删掉，下标就悬空了 —— 回到「全部科室」，
    // 而不是留一个空的下拉框配一张完整的表
    onDeptChoicesChanged: {
        if (deptFilter >= deptChoices.length)
            deptFilter = 0
    }

    function resetFilters() {
        searchText = ""
        deptFilter = 0
        currentPage = 1
    }

    // 删掉患者之后当前页可能已经不存在了（停在最后一页时最常遇到）
    function clampPage() {
        const pages = Math.max(1, Math.ceil(filteredPatients.length / pageSize))
        currentPage = Math.max(1, Math.min(pages, currentPage))
    }

    readonly property int rowHeight: 51
    readonly property int bodyTop: 52          // 表头高 52，第一行紧接其后
    readonly property int bodyHeight: 788
    // 一屏正好装下的行数。分页之后每页就这么多行，滚动条自然不再出现 ——
    // 设计稿给的是分页，不是滚动
    readonly property int pageSize: Math.floor(bodyHeight / rowHeight)

    // 当前页的那一段
    readonly property var patients: {
        const start = (currentPage - 1) * pageSize
        return filteredPatients.slice(start, start + pageSize)
    }

    function isCurrent(no) { return no === root.currentPatientNo && no !== "" }

    // 表格列 x（设计稿坐标 272/442/597/752/907/1062/1217/1403/1559 减去卡片原点 201）
    readonly property var columnX: [71, 241, 396, 551, 706, 861, 1016, 1202, 1358]

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("患者管理")
        currentNav: qsTr("患者管理")
        // 底栏指标从真实数据来。原来那一串（256Hz、电极 10/16 良好、患者「张文强」）
        // 是写死的，与页面上的实际值互相矛盾
        statusItems: {
            var items = [qsTr("患者：") + root.allPatients.length + qsTr(" 位")]
            if (root.filteredPatients.length !== root.allPatients.length)
                items.push(qsTr("筛选后：") + root.filteredPatients.length + qsTr(" 位"))
            if (root.currentPatientNo.length > 0)
                items.push(qsTr("当前：") + root.currentPatientNo)
            return items
        }
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()
        onChangePasswordRequested: root.changePasswordRequested()
        onDeviceInfoRequested: root.deviceInfoRequested()

        // ---------- 表头 ----------
        Rectangle {
            x: -47
            y: 0
            width: 1796
            height: 52
            color: Design.primarySoft
        }

        Repeater {
            model: [
                { x: 71,   text: qsTr("病历号") },
                { x: 241,  text: qsTr("姓名") },
                { x: 396,  text: qsTr("性别") },
                { x: 551,  text: qsTr("年龄") },
                { x: 706,  text: qsTr("科室") },
                { x: 861,  text: qsTr("诊断") },
                { x: 1016, text: qsTr("采集次数") },
                { x: 1202, text: qsTr("最近采集") },
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
        Repeater {
            // 只渲染**当前页**的那一段（patients 已经是切片）
            model: root.patients

            delegate: Item {
                required property var modelData
                required property int index

                // 设计稿里表头高 52、第一行紧接其后，所以行起点是 52 + 51*i。
                // 这里原先是 68，整张表往下偏了 16px；而分隔线又写成 rowY+35，
                // 正好把偏差凑了回去 —— 行位置错了、分隔线还落在行中间
                readonly property int rowY: root.bodyTop + root.rowHeight * index
                // 行内元素一律按「在 51 高的行里居中」排：
                // 文字约 20 高 → +16；按钮 31 高 → +10；「当前」标记 17 高 → +16。
                // 历史记录页用的就是这套偏移，两页保持一致

                Rectangle {
                    y: rowY
                    x: -47
                    width: 1794
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                // 点整行 = 把这位患者设为当前患者。
                // 声明在四个按钮**之前**，按钮压在它上面 —— 点按钮不会顺带触发这一下
                MouseArea {
                    y: rowY
                    x: -47
                    width: 1794
                    height: 51
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.patientActivated(modelData.no)
                }

                Text { x: 68;  y: rowY + 16; text: Privacy.masked(modelData.no);   color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 241; y: rowY + 16; text: Privacy.masked(modelData.name); color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 404; y: rowY + 16; text: modelData.gender; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 557; y: rowY + 16; text: modelData.age;  color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 690; y: rowY + 16; text: modelData.dept; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 861; y: rowY + 16; text: modelData.diag; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1033; y: rowY + 16; text: modelData.count; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1156; y: rowY + 16; text: modelData.last; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }

                // 「当前患者」小标记（设计稿只画在第 3 行上，这里跟着数据走）
                Rectangle {
                    x: 281
                    y: rowY + 16
                    width: 29
                    height: 17
                    radius: 4
                    color: Design.primarySoft
                    visible: root.isCurrent(modelData.no)

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("当前")
                        color: Design.primary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 12
                    }
                }

                TableRowButton {
                    x: 1358
                    y: rowY + 10
                    width: 81
                    text: qsTr("设为当前")
                    // 已经是当前患者就没必要再点
                    enabled: !root.isCurrent(modelData.no)
                    onClicked: root.patientActivated(modelData.no)
                }
                TableRowButton {
                    x: 1451
                    y: rowY + 10
                    width: 59
                    text: qsTr("编辑")
                    onClicked: root.editPatientRequested(modelData.no)
                }
                TableRowButton {
                    x: 1522
                    y: rowY + 10
                    width: 59
                    text: qsTr("记录")
                    onClicked: root.openRecordsRequested(modelData.no)
                }
                TableRowButton {
                    x: 1593
                    y: rowY + 10
                    width: 59
                    text: qsTr("删除")
                    danger: true
                    onClicked: root.deletePatientRequested(modelData.no)
                }

                // 行分隔线画在行底。设计稿里这条线相当明显（量下来约 #a0a0a0），
                // 原来的 10% 黑几乎看不见
                Rectangle {
                    y: rowY + root.rowHeight
                    x: -47
                    width: 1763
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.30)
                }
            }
        }

        // ---------- 空态 ----------
        // 库里一位患者都没有时，表格区是空的；不写一句话的话看起来像没加载出来。
        // 「一位都没有」和「筛完没有了」是两回事，提示语也要分开 ——
        // 筛没的时候让用户去「新增患者」，他会以为自己的数据丢了
        Text {
            x: 71
            y: 200
            width: 1400
            visible: root.patients.length === 0
            text: root.allPatients.length === 0
                  ? qsTr("暂无患者，点右上角「新增患者」登记一位")
                  : qsTr("没有符合当前条件的患者，试试换个搜索词或科室")
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 分页 ----------
        // 设计稿这一段是「共 N 条记录（当前显示 M 条）」+ 上一页 / 1/1 / 下一页。
        // 原来三个元素都是写死的静态文字，按钮连点击区都没有
        Pager {
            x: 0
            y: 842
            totalCount: root.allPatients.length
            filteredCount: root.filteredPatients.length
            pageSize: root.pageSize
            currentPage: root.currentPage
            onPageRequested: (page) => root.currentPage = page
        }
    }

    // ---------- 标题条右侧的筛选/操作控件（设计稿绝对坐标）----------
    SearchField {
        x: 1374
        y: 79
        width: 215
        height: 43
        placeholder: qsTr("搜索病历号/姓名/诊断")
        // 即时过滤：列表就那么几十行，按一次键重算一遍完全跟得上，
        // 不必再要求用户按回车
        onTextChanged: root.searchText = text
    }

    ChoiceField {
        x: 1601
        y: 79
        width: 126
        height: 43
        choices: root.deptChoices
        currentIndex: root.deptFilter
        onActivated: (index) => root.deptFilter = index
    }

    Rectangle {
        x: 1740
        y: 79
        width: 145
        height: 43
        radius: 12
        color: newPatientMouse.pressed ? "#64879f" : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.9)
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("新增患者")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        MouseArea {
            id: newPatientMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.newPatientRequested()
        }
    }

}
