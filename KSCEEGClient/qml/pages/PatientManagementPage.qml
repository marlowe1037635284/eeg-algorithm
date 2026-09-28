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

    // 列表来自 patients 表。Q_INVOKABLE 没有变更通知，用一个 revision 显式触发重算：
    // 进页面、新增或删除患者之后调 reload()
    property int revision: 0
    function reload() { revision++ }

    readonly property var patients: {
        revision   // 绑定依赖
        return database ? database.patients() : []
    }

    function isCurrent(no) { return no === root.currentPatientNo && no !== "" }

    // ---------- 列表滚动 ----------
    // 设计稿右侧**没有滚动条**，所以默认不画；只有真的放不下时才出现。
    //
    // 不套裁剪容器：套了以后行就从「内容槽坐标系」变成「容器坐标系」，
    // 每一处 x/y 都要重算一遍（档案列表那次就是这么错的）。这里改成
    // 只渲染看得见的那几行，坐标体系完全不动
    readonly property int rowHeight: 51
    readonly property int bodyTop: 52          // 表头高 52，第一行紧接其后
    readonly property int bodyHeight: 788
    readonly property int visibleRowCount: Math.floor(bodyHeight / rowHeight)
    readonly property real maxScroll: Math.max(0, patients.length * rowHeight - bodyHeight)
    property real listScroll: 0
    function scrollBy(delta) {
        listScroll = Math.max(0, Math.min(maxScroll, listScroll + delta))
    }
    // 第一个可见行的下标。行渲染的是 patients 的一个切片
    readonly property int firstVisibleRow: Math.floor(listScroll / rowHeight)
    readonly property bool scrollBarVisible: maxScroll > 0
    readonly property real scrollThumbHeight:
        Math.max(40, bodyHeight * bodyHeight / Math.max(1, patients.length * rowHeight))
    readonly property real scrollThumbY:
        bodyTop + (bodyHeight - scrollThumbHeight) * (maxScroll > 0 ? listScroll / maxScroll : 0)

    // 表格列 x（设计稿坐标 272/442/597/752/907/1062/1217/1403/1559 减去卡片原点 201）
    readonly property var columnX: [71, 241, 396, 551, 706, 861, 1016, 1202, 1358]

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("患者管理")
        currentNav: qsTr("患者管理")
        // 底栏指标从真实数据来。原来那一串（256Hz、电极 10/16 良好、患者「张文强」）
        // 是写死的，与页面上的实际值互相矛盾
        statusItems: {
            var items = [qsTr("患者：") + root.patients.length + qsTr(" 位")]
            if (root.currentPatientNo.length > 0)
                items.push(qsTr("当前：") + root.currentPatientNo)
            return items
        }
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

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
        // 表格区的滚轮。放在行**之前**声明，所以行和行内按钮仍然先收到点击；
        // acceptedButtons: NoButton 让它只收滚轮事件
        MouseArea {
            x: -47
            y: root.bodyTop
            width: 1794
            height: root.bodyHeight
            acceptedButtons: Qt.NoButton
            onWheel: (wheel) => { console.log('wheel delta=' + wheel.angleDelta.y + ' max=' + root.maxScroll); root.scrollBy(-wheel.angleDelta.y / 3) }
        }

        Repeater {
            // 只渲染看得见的那几行（多一行做缓冲）。这样既不用裁剪容器，
            // 也不会在患者很多时白画几百行
            model: root.patients.slice(root.firstVisibleRow,
                                       root.firstVisibleRow + root.visibleRowCount + 1)

            delegate: Item {
                required property var modelData
                required property int index

                // 切片里的下标要还原成整张表里的下标，斑马纹和行位置都靠它
                readonly property int realIndex: root.firstVisibleRow + index
                // 设计稿里表头高 52、第一行紧接其后，所以行起点是 52 + 51*i。
                // 这里原先是 68，整张表往下偏了 16px；而分隔线又写成 rowY+35，
                // 正好把偏差凑了回去 —— 行位置错了、分隔线还落在行中间
                readonly property int rowY:
                    root.bodyTop + root.rowHeight * realIndex - root.listScroll
                // 行内元素一律按「在 51 高的行里居中」排：
                // 文字约 20 高 → +16；按钮 31 高 → +10；「当前」标记 17 高 → +16。
                // 历史记录页用的就是这套偏移，两页保持一致

                Rectangle {
                    y: rowY
                    x: -47
                    width: 1794
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (realIndex % 2) === 0
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
                    // 滚轮挂在行上而不是下面那个背景层：行在这一层之上，
                    // 滚轮事件被行吃掉后只会往父链冒泡，到不了下面的兄弟
                    onWheel: (wheel) => root.scrollBy(-wheel.angleDelta.y / 3)
                }

                Text { x: 68;  y: rowY + 16; text: modelData.no;   color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 241; y: rowY + 16; text: modelData.name; color: "#3b3b3b"; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
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
        // 库里一位患者都没有时，表格区是空的；不写一句话的话看起来像没加载出来
        Text {
            x: 71
            y: 200
            visible: root.patients.length === 0
            text: qsTr("暂无患者，点右上角「新增患者」登记一位")
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 右侧滚动条 ----------
        // 设计稿里没有这条；只有患者多到一屏放不下时才出现，
        // 而且滑块高度与位置跟着实际内容走（原来是一条常驻的轨道 + 一个写死的滑块，
        // 只有一位患者时它也挂在那儿，而且滑块位置和内容毫无关系）
        Rectangle {
            x: 1686
            y: root.bodyTop
            width: 7
            height: root.bodyHeight
            radius: 4
            color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
            visible: root.scrollBarVisible
        }

        Rectangle {
            x: 1686
            y: root.scrollThumbY
            width: 7
            height: root.scrollThumbHeight
            radius: 4
            color: Qt.rgba(0.4, 0.4, 0.4, 0.28)
            visible: root.scrollBarVisible
        }

        // ---------- 分页 ----------
        Text {
            x: 19
            y: 846
            text: qsTr("共 %1 条记录（当前显示 %1 条）").arg(root.patients.length)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        Rectangle {
            x: 1531
            y: 842
            width: 53
            height: 29
            radius: 6
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("上一页")
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }
        }

        Rectangle {
            x: 1631
            y: 842
            width: 53
            height: 29
            radius: 6
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("下一页")
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }
        }

        Text {
            x: 1596
            y: 845
            text: "1/1"
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }
    }

    // ---------- 标题条右侧的筛选/操作控件（设计稿绝对坐标）----------
    Rectangle {
        x: 1374
        y: 79
        width: 215
        height: 43
        radius: 12
        color: Design.primarySoft

        Text {
            x: 13
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("搜索病历号/姓名/诊断")
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.3)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }

    Rectangle {
        x: 1601
        y: 79
        width: 126
        height: 43
        radius: 12
        color: Design.primarySoft

        Text {
            x: 10
            y: 0
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: qsTr("全部科室")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Image {
            x: 109
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
        }
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
