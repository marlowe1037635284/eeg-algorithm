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

    // 设计稿表格区只画了 3 行，但页脚写的是「共 6 条记录（当前显示 6 条）」——
    // 按页脚的说法补全到 6 行，否则表格里只有 3 行、下面一大片空白，看起来像没做完。
    readonly property var patients: [
        { no: "P-0001", name: "李明", gender: "男", age: "45", dept: "神经内科", diag: "癫痫", count: "1 次", last: "2026-09-12 10:23:41", current: false },
        { no: "P-0001", name: "李明", gender: "男", age: "45", dept: "神经内科", diag: "癫痫", count: "1 次", last: "2026-09-12 10:23:41", current: false },
        { no: "P-0001", name: "李明", gender: "男", age: "45", dept: "神经内科", diag: "癫痫", count: "1 次", last: "2026-09-12 10:23:41", current: true },
        { no: "P-0002", name: "王芳", gender: "女", age: "38", dept: "神经内科", diag: "偏头痛", count: "2 次", last: "2026-09-10 09:15:02", current: false },
        { no: "P-0003", name: "赵强", gender: "男", age: "52", dept: "神经外科", diag: "帕金森", count: "3 次", last: "2026-09-08 15:40:18", current: false },
        { no: "P-0004", name: "孙倩", gender: "女", age: "29", dept: "神经内科", diag: "睡眠障碍", count: "1 次", last: "2026-09-05 11:02:37", current: false }
    ]

    // 表格列 x（设计稿坐标 272/442/597/752/907/1062/1217/1403/1559 减去卡片原点 201）
    readonly property var columnX: [71, 241, 396, 551, 706, 861, 1016, 1202, 1358]

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("患者管理")
        currentNav: qsTr("患者管理")
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
        Repeater {
            model: root.patients

            delegate: Item {
                required property var modelData
                required property int index

                readonly property int rowY: 68 + 51 * index

                Rectangle {
                    y: rowY
                    x: -47
                    width: 1794
                    height: 51
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                Text { x: 68;  y: rowY + 18; text: modelData.no;   color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 241; y: rowY + 18; text: modelData.name; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 404; y: rowY + 18; text: modelData.gender; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 557; y: rowY + 18; text: modelData.age;  color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 690; y: rowY + 18; text: modelData.dept; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 861; y: rowY + 18; text: modelData.diag; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1033; y: rowY + 18; text: modelData.count; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }
                Text { x: 1156; y: rowY + 18; text: modelData.last; color: Design.textSecondary; font.family: Design.fontFamily; font.styleName: Design.styleRegular; font.pixelSize: 16 }

                // 「当前患者」小标记（设计稿只画在第 3 行上，这里跟着数据走）
                Rectangle {
                    x: 281
                    y: rowY + 22
                    width: 29
                    height: 17
                    radius: 4
                    color: Design.primarySoft
                    visible: modelData.current

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
                    y: rowY - 5
                    width: 81
                    text: qsTr("设为当前")
                }
                TableRowButton {
                    x: 1451
                    y: rowY - 5
                    width: 59
                    text: qsTr("编辑")
                    onClicked: root.editPatientRequested(modelData.no)
                }
                TableRowButton {
                    x: 1522
                    y: rowY - 5
                    width: 59
                    text: qsTr("记录")
                }
                TableRowButton {
                    x: 1593
                    y: rowY - 5
                    width: 59
                    text: qsTr("删除")
                    danger: true
                }

                Rectangle {
                    y: rowY + 35
                    x: -47
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
