import QtQuick
import KSCEEGClient

// 「系统设置」页。设计稿画板 1920×1080，用 AppShell 当外壳。
//
// 两套坐标（同 PatientManagementPage.qml）：
//   - 直接摆在画布上的东西（顶栏右侧的「保存设置」）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽里的东西，坐标要减去内容卡片原点 (154,150)。
// 内容槽里的四个设置面板再各自以「面板」为原点摆放子元素（省去大量 +216/+1057 的平移），
// 每个面板上都注明了它在设计稿里的绝对原点，方便逐条对照施工图。
Item {
    id: root

    // 顶栏右上角显示的用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    signal navRequested(string label)
    signal logoutRequested()
    signal newTagRequested()
    // 设计稿顶栏右侧画了「保存设置」，这里给出对应的信号
    signal saveRequested()

    // 标签表数据。设计稿只画了 2 行，均为 rTMS / 101,102；第 1 行带白底高亮（当前选中行）。
    readonly property var tags: [
        { name: "rTMS", code: "101,102", color: "#295da1", selected: true },
        { name: "rTMS", code: "101,102", color: "#876ee3", selected: false }
    ]

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("系统设置")
        currentNav: qsTr("系统设置")
        userName: root.userName
        userRole: root.userRole
        onNavRequested: (label) => root.navRequested(label)
        onLogoutRequested: root.logoutRequested()

        // ================= 左栏 · 数据存储（设计稿 @216,164 828×223）=================
        Rectangle {
            x: 15
            y: 14
            width: 828
            height: 223
            radius: 7
            color: Design.panelFillSoft

            PanelDivider {
                x: 4
                y: 44
                width: 817
            }

            Text {
                x: 10
                y: 9
                text: qsTr("数据存储")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 18
            }

            // 首行是「目录 + 浏览按钮」，和下面的下拉选择行结构不同，单独写
            Text {
                x: 10
                y: 64
                text: qsTr("记录保存目录")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }

            // 路径右对齐贴在「浏览」按钮左侧（设计稿文本框 154 宽，右对齐）
            Text {
                x: 582
                y: 64
                width: 154
                horizontalAlignment: Text.AlignRight
                text: "D:\\EEGData\\Records"
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }

            Rectangle {
                x: 751
                y: 59
                width: 59
                height: 32
                radius: 10
                color: Design.primarySoft
                border.width: 1
                border.color: Design.panelBorder

                Text {
                    anchors.centerIn: parent
                    text: qsTr("浏览")
                    color: Design.primary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 14
                }
            }

            Rectangle {
                x: 10
                y: 104
                width: 818
                height: 1
                color: Qt.rgba(0, 0, 0, 0.10)
            }

            SettingRow {
                x: 0
                y: 122
                label: qsTr("自动保存间隔")
                value: qsTr("10分钟")
            }

            SettingRow {
                x: 0
                y: 181
                label: qsTr("记录文件格式")
                value: qsTr("BDF（.bdf）")
                dividerBelow: false   // 末行的分隔线正好压在面板下边缘，设计稿没画
            }
        }

        // ================= 左栏 · 采集默认值（设计稿 @216,401 828×220）=================
        Rectangle {
            x: 15
            y: 251
            width: 828
            height: 220
            radius: 7
            color: Design.panelFillSoft

            PanelDivider {
                x: 4
                y: 44
                width: 817
            }

            Text {
                x: 10
                y: 9
                text: qsTr("采集默认值")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 18
            }

            SettingRow {
                x: 0
                y: 64
                label: qsTr("默认采样率")
                value: qsTr("256Hz")
            }

            SettingRow {
                x: 0
                y: 122
                label: qsTr("默认通道数")
                value: qsTr("16通道")
            }

            SettingRow {
                x: 0
                y: 180
                label: qsTr("低阻抗自动提醒")
                hint: qsTr("阈值")
                value: qsTr("10kΩ")
                dividerBelow: false   // 末行的分隔线正好压在面板下边缘，设计稿没画
            }
        }

        // ================= 左栏 · 系统信息（设计稿 @216,636 828×384）=================
        Rectangle {
            x: 15
            y: 486
            width: 828
            height: 384
            radius: 7
            color: Design.panelFillSoft

            PanelDivider {
                x: 4
                y: 44
                width: 817
            }

            Text {
                x: 10
                y: 9
                text: qsTr("系统信息")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 18
            }

            // 三行信息在面板里是水平居中的（设计稿给的 x 已按下居中排好，照抄）
            Text {
                x: 338
                y: 121
                text: "EEG-KSC"
                color: Design.brand
                font.family: Design.fontFamily
                font.styleName: Design.styleLogo
                font.pixelSize: 36
            }

            Text {
                x: 341
                y: 191
                text: qsTr("型号:EEG-KSC-NN")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 18
            }

            Text {
                x: 367
                y: 234
                text: qsTr("版本:1.0.0.0")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleMedium
                font.pixelSize: 18
            }
        }

        // ================= 右栏 · 标签管理（设计稿 @1057,164 828×856）=================
        Rectangle {
            x: 856
            y: 14
            width: 828
            height: 856
            radius: 7
            color: Design.panelFillSoft

            PanelDivider {
                x: 5
                y: 44
                width: 817
            }

            Text {
                x: 11
                y: 9
                text: qsTr("标签管理")
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 18
            }

            // 表格外框（设计稿 807×714）
            Rectangle {
                x: 11
                y: 56
                width: 807
                height: 714
                radius: 7
                color: "transparent"
                border.width: 1
                border.color: Design.panelBorder
            }

            // 表头底色（设计稿是主色 7%，比按钮底还淡）
            Rectangle {
                x: 11
                y: 56
                width: 807
                height: 45
                color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.07)
            }

            Repeater {
                model: [
                    { x: 91,  text: qsTr("标签名称") },
                    { x: 268, text: qsTr("对应编码") },
                    { x: 649, text: qsTr("操作") }
                ]

                delegate: Text {
                    required property var modelData
                    x: modelData.x
                    y: 68
                    text: modelData.text
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }
            }

            // 标签行：行高 51，行首 265（设计稿绝对坐标）→ 面板内 101
            Repeater {
                model: root.tags

                delegate: Item {
                    required property var modelData
                    required property int index

                    readonly property int rowY: 101 + 51 * index

                    // 当前选中行的高亮（设计稿是白色 25%）
                    Rectangle {
                        x: 11
                        y: parent.rowY
                        width: 807
                        height: 51
                        color: Qt.rgba(1, 1, 1, 0.25)
                        visible: modelData.selected
                    }

                    Rectangle {
                        x: 29
                        y: parent.rowY + 17
                        width: 18
                        height: 18
                        radius: 4
                        color: modelData.color
                    }

                    Text {
                        x: 91
                        y: parent.rowY + 12
                        height: 28
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.name
                        color: Design.textPrimary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 14
                    }

                    Rectangle {
                        x: 268
                        y: parent.rowY + 11
                        width: 221
                        height: 29
                        radius: 10
                        color: Qt.rgba(0x8f / 255, 0x8f / 255, 0x8f / 255, 0.10)

                        Text {
                            x: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.code
                            color: "#3b3b3b"
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 14
                        }
                    }

                    TagAction {
                        x: 649
                        y: parent.rowY + 11
                        width: 59
                        text: qsTr("编辑")
                    }

                    TagAction {
                        x: 720
                        y: parent.rowY + 11
                        width: 59
                        text: qsTr("删除")
                    }

                    // 行分隔线：设计稿是主色 30%，比通用 divider（主色 20%）略重，照抄设计稿的 alpha
                    Rectangle {
                        x: 20
                        y: parent.rowY + 51
                        width: 789
                        height: 1
                        color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.30)
                    }
                }
            }

            // 新建标签按钮（设计稿 807×43，加号 + 文字整体居中）
            Rectangle {
                x: 11
                y: 212
                width: 807
                height: 43
                radius: 12
                color: Design.primarySoft

                PlusIcon {
                    x: 356
                    y: 14
                }

                Text {
                    x: 380
                    y: 8
                    height: 28
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("新增标签")
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 18
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.newTagRequested()
                }
            }

            // 底部提示条（设计稿 807×59，橙底 10%）
            Rectangle {
                x: 11
                y: 783
                width: 807
                height: 59
                radius: 10
                color: Qt.rgba(0xff / 255, 0x8d / 255, 0x1a / 255, 0.10)
            }

            WarnIcon {
                x: 37
                y: 803
            }

            // 两行提示文字按设计稿原样（含换行），用隐式宽度让两行都完整显示
            Text {
                x: 74
                y: 791
                text: qsTr("未使用过的标签,可修改名称,可删除;\n已使用过的标签,仅支持修改名称且修改后,历史数据及新数据全部修改,请情真操作!")
                color: Design.brand
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
                lineHeight: 22
                lineHeightMode: Text.FixedHeight
            }
        }
    }

    // ================= 顶栏右侧「保存设置」（画布绝对坐标）=================
    Rectangle {
        x: 1740
        y: 79
        width: 145
        height: 43
        radius: 12
        color: saveMouse.pressed ? "#64879f" : Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.9)
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("保存设置")
            color: "#ffffff"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        MouseArea {
            id: saveMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.saveRequested()
        }
    }

    // 设置行：左标签 + 右侧下拉框。设计稿里「数据存储」「采集默认值」两块共 5 行同构。
    // 自身原点 = 面板左边缘 / 本行标签文字顶边；行距 58（设计稿 286 → 345 → ...）。
    component SettingRow: Item {
        id: settingRow

        property string label: ""
        property string value: ""
        // 「阈值」这类夹在标签和下拉框之间的灰字提示，只有低阻抗那一行有
        property string hint: ""
        // 每块面板的最后一行下面没有分隔线（设计稿里那条线正好和面板下边缘重合）
        property bool dividerBelow: true

        width: 828
        height: 58

        Text {
            x: 10
            y: 0
            text: settingRow.label
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: 617
            y: 0
            visible: settingRow.hint.length > 0
            text: settingRow.hint
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Rectangle {
            x: 10
            y: 40
            width: 818
            height: 1
            color: Qt.rgba(0, 0, 0, 0.10)
            visible: settingRow.dividerBelow
        }

        Rectangle {
            x: 668
            y: -4
            width: 142
            height: 29
            radius: 10
            color: Design.primarySoft

            Text {
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                text: settingRow.value
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            Image {
                x: 132.5
                anchors.verticalCenter: parent.verticalCenter
                width: 7.47
                height: 7
                rotation: 90
                source: Design.assetRoot + "icons/icon-arrow-down.svg"
            }
        }
    }

    // 标签行里的小圆角按钮（编辑 / 删除）
    component TagAction: Rectangle {
        id: tagAction

        property string text: ""
        signal clicked()

        height: 31
        radius: 8
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: tagAction.text
            color: "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 行为待接口对接，这里只给出手型光标
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tagAction.clicked()
        }
    }

    // 「+」加号。设计稿是 12.72×12.72 的矢量，用两条细矩形拼出来，不值得为它引一个资源文件
    component PlusIcon: Item {
        width: 15
        height: 15

        Rectangle {
            x: 1.14
            y: 6.75
            width: 12.72
            height: 1.5
            color: Design.textPrimary
        }

        Rectangle {
            x: 6.75
            y: 1.14
            width: 1.5
            height: 12.72
            color: Design.textPrimary
        }
    }

    // 提示图标：橙色圆环 + 感叹号（设计稿里是描边圆，不是实心圆）
    component WarnIcon: Item {
        width: 20
        height: 20

        Rectangle {
            anchors.fill: parent
            radius: 10
            color: "transparent"
            border.width: 1.5
            border.color: Design.brand
        }

        Text {
            anchors.centerIn: parent
            text: "!"
            color: Design.brand
            font.family: Design.fontFamily
            font.styleName: Design.styleBold
            font.pixelSize: 13
        }
    }
}
