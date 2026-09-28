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
    signal recordPreviewRequested(string recordNo)

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
    function reload() { revision++ }

    readonly property var records: {
        revision   // 绑定依赖
        return database ? database.sessions(patientFilter) : []
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
            var items = [qsTr("记录：") + root.records.length + qsTr(" 条")]
            if (root.patientFilter.length > 0)
                items.push(qsTr("筛选：") + (root.patientFilterName.length > 0
                                             ? root.patientFilterName : root.patientFilter))
            return items
        }
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

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
                Text { x: 237;  y: rowY + 16; text: modelData.patient;  color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
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
                    text: qsTr("分析")
                }
                TableRowButton {
                    x: 1500
                    y: rowY + 11
                    text: qsTr("导出")
                }
                TableRowButton {
                    x: 1571
                    y: rowY + 11
                    text: qsTr("删除")
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

        // ---------- 右侧滚动条 ----------
        Rectangle {
            x: 1686
            y: 64
            width: 7
            height: 758
            radius: 4
            color: Qt.rgba(0.478, 0.478, 0.478, 0.10)
        }

        Rectangle {
            x: 1686
            y: 319
            width: 7
            height: 278
            radius: 4
            color: Qt.rgba(0.4, 0.4, 0.4, 0.15)
        }

        // ---------- 空态 ----------
        Text {
            x: 71
            y: 200
            visible: root.records.length === 0
            text: root.patientFilter.length > 0
                  ? qsTr("这位患者还没有采集记录")
                  : qsTr("还没有采集记录，去采集工作台开始一次采集")
            color: Design.textMuted
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 分页 ----------
        Text {
            x: 19
            y: 846
            text: qsTr("共 %1 条记录（当前显示 %1 条）").arg(root.records.length)
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

    // ---------- 标题条右侧的筛选控件（设计稿绝对坐标）----------
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
            text: qsTr("搜索记录ID/患者姓名")
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
            width: parent.width - 30
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            // 有过滤时显示这位患者，否则是「全部患者」。设计稿只有后者的样子
            text: root.patientFilter.length > 0
                  ? (root.patientFilterName.length > 0 ? root.patientFilterName : root.patientFilter)
                  : qsTr("全部患者")
            color: root.patientFilter.length > 0 ? Design.primary : "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Image {
            x: 116.5
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
            visible: root.patientFilter.length === 0
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.patientFilter.length > 0
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clearPatientFilter()

            ToolTip.visible: containsMouse
            ToolTip.text: qsTr("点一下回到全部患者")
            ToolTip.delay: 300
        }
    }

    Rectangle {
        x: 1739
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
            text: qsTr("全部通道")
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Image {
            x: 116.5
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: Design.assetRoot + "icons/icon-arrow-down.svg"
        }
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
