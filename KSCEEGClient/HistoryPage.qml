import QtQuick

// 「历史记录」页。设计稿画板 1920×1080，外壳复用 AppShell。
//
// 两套坐标（同 PatientManagementPage）：
//   - 直接摆在画布上的东西（标题条右侧那排筛选控件）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽的东西，坐标要减去内容卡片原点 (201,150)。
Item {
    id: root

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

    // 设计稿只画了 3 行示意，页脚写的是「共 6 条记录（当前显示 6 条）」，
    // 所以按页脚补足 6 行——前 3 行照抄设计稿（设计稿里 ID/患者/时间三行相同，
    // 是 Figma 复制出来的占位数据，这里同样保留），后 3 行按同样的字段编合理数据。
    readonly property var records: [
        { no: "R-0013", patient: "刘娜", time: "2026-9-22 16:44:12", duration: "00:00:26", channels: "16", rate: "256 Hz", events: "0", quality: "16/16 良好", level: "良好" },
        { no: "R-0013", patient: "刘娜", time: "2026-9-22 16:44:12", duration: "00:00:26", channels: "16", rate: "256 Hz", events: "0", quality: "16/16 良好", level: "良好" },
        { no: "R-0013", patient: "刘娜", time: "2026-9-22 16:44:12", duration: "00:00:26", channels: "16", rate: "256 Hz", events: "0", quality: "8/16 不良", level: "不良" },
        { no: "R-0012", patient: "王芳", time: "2026-9-20 09:12:35", duration: "00:01:04", channels: "16", rate: "256 Hz", events: "2", quality: "16/16 良好", level: "良好" },
        { no: "R-0011", patient: "赵强", time: "2026-9-18 14:03:57", duration: "00:00:48", channels: "16", rate: "256 Hz", events: "1", quality: "15/16 良好", level: "良好" },
        { no: "R-0010", patient: "孙倩", time: "2026-9-15 11:27:09", duration: "00:02:12", channels: "16", rate: "256 Hz", events: "3", quality: "13/16 不良", level: "不良" }
    ]

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("历史采集记录")
        currentNav: qsTr("历史记录")
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

        // ---------- 表头 ----------
        // 设计稿坐标 x=272/438/589/771/922/1073/1239/1390/1559，均已减卡片原点 201
        Rectangle {
            x: 0
            y: 0
            width: 1702
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
                font.family: Design.fontRegular
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
                    x: 0
                    y: rowY
                    width: 1700
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                // 文本基线统一比行顶低 16（设计稿 218-202=16）
                Text { x: 68;   y: rowY + 16; text: modelData.no;       color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 237;  y: rowY + 16; text: modelData.patient;  color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 345;  y: rowY + 16; text: modelData.time;     color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 553;  y: rowY + 16; text: modelData.duration; color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 727;  y: rowY + 16; text: modelData.channels; color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 871;  y: rowY + 16; text: modelData.rate;     color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }
                Text { x: 1049; y: rowY + 16; text: modelData.events;   color: Design.textSecondary; font.family: Design.fontRegular; font.pixelSize: 16 }

                QualityPill {
                    x: 1169
                    y: rowY + 13
                    text: modelData.quality
                    accent: root.qualityColor(modelData.level)
                }

                RowAction {
                    x: 1358
                    y: rowY + 11
                    text: qsTr("预览")
                    onClicked: root.recordPreviewRequested(modelData.no)
                }
                RowAction {
                    x: 1429
                    y: rowY + 11
                    text: qsTr("分析")
                }
                RowAction {
                    x: 1500
                    y: rowY + 11
                    text: qsTr("导出")
                }
                RowAction {
                    x: 1571
                    y: rowY + 11
                    text: qsTr("删除")
                }

                Rectangle {
                    x: 0
                    y: rowY + 51
                    width: 1669
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

        // ---------- 分页 ----------
        Text {
            x: 19
            y: 846
            text: qsTr("共 %1 条记录（当前显示 %1 条）").arg(root.records.length)
            color: Design.textSecondary
            font.family: Design.fontRegular
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
                font.family: Design.fontRegular
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
                font.family: Design.fontRegular
                font.pixelSize: 14
            }
        }

        Text {
            x: 1596
            y: 845
            text: "1/1"
            color: "#000000"
            font.family: Design.fontRegular
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
            font.family: Design.fontRegular
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
            text: qsTr("全部患者")
            color: "#3b3b3b"
            font.family: Design.fontRegular
            font.pixelSize: 16
        }

        Image {
            x: 116.5
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: "assets/icons/icon-arrow-down.svg"
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
            font.family: Design.fontRegular
            font.pixelSize: 16
        }

        Image {
            x: 116.5
            anchors.verticalCenter: parent.verticalCenter
            width: 7.47
            height: 7
            rotation: 90
            source: "assets/icons/icon-arrow-down.svg"
        }
    }

    // 表格行里的文字小按钮。
    // 注意：本页设计稿里的「删除」和其他三个按钮长得完全一样（不像患者管理页那样画成红色），
    // 所以这里不做 danger 变体，四个按钮共用一套样式。
    component RowAction: Rectangle {
        id: rowAction
        property string text: ""
        signal clicked()

        width: 59
        height: 31
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: rowAction.text
            color: "#4f4f4f"
            font.family: Design.fontRegular
            font.pixelSize: 16
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: rowAction.clicked()
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
            font.family: Design.fontRegular
            font.pixelSize: 14
        }
    }
}
