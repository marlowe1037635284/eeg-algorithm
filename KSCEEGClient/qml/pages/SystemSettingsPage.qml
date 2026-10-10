import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import KSCEEGClient

// 「系统设置」页。设计稿画板 1920×1080，用 AppShell 当外壳。
//
// 两套坐标（同 PatientManagementPage.qml）：
//   - 直接摆在画布上的东西（顶栏右侧的「保存设置」）用设计稿绝对坐标；
//   - 放进 AppShell 内容槽里的东西，坐标要减去内容卡片原点 (154,150)。
// 内容槽里的四个设置面板再各自以「面板」为原点摆放子元素（省去大量 +216/+1057 的平移），
// 每个面板上都注明了它在设计稿里的绝对原点，方便逐条对照施工图。
//
// 数据落点：所有设置项存在 app_settings 表里，标签存在 tags 表里。
// 原来这一页整页都是静态的 —— 5 行设置全是画出来的色块、标签表是两份写死的假数据、
// 「浏览」「保存设置」点了没反应、标签的编辑/删除也没有行为。
Item {
    id: root

    // 顶栏右上角显示的用户（登录后由 Main 传进来）
    property string userName: qsTr("管理员")
    property string userRole: qsTr("管理员")

    // 应用数据库，由外层注入
    property var database

    signal navRequested(string label)
    signal logoutRequested()
    signal newTagRequested()
    signal editTagRequested(var tag)
    // 删除标签是不可撤销的（设计稿的提示条也这么写），交给外层弹确认框
    signal deleteTagRequested(int tagId, string tagName)
    // 保存成功，外层弹轻提示
    signal saved()

    // ---------- 标签 ----------
    // Q_INVOKABLE 没有变更通知，用一个 revision 显式触发重算
    property int revision: 0
    function reload() { revision++ }

    readonly property var tags: {
        revision
        return database ? database.tags() : []
    }

    // ---------- 设置项草稿 ----------
    // 打开页面时从库里读一次，之后改的是本地副本；点「保存设置」才整体写回。
    // 边改边写的话，改错了连反悔的机会都没有
    property string recordDir: Acq.defaultRecordDir
    property int saveIntervalIndex: 1
    property int fileFormatIndex: 0
    property int channelCountIndex: 2
    property int impedanceThresholdIndex: 1

    readonly property var saveIntervalChoices: [qsTr("5分钟"), qsTr("10分钟"), qsTr("30分钟")]
    readonly property var saveIntervalValues: ["5", "10", "30"]
    readonly property var fileFormatChoices: [qsTr("BDF（.bdf）"), qsTr("EDF（.edf）"), qsTr("EEG（.eeg）")]
    readonly property var fileFormatValues: ["bdf", "edf", "eeg"]
    readonly property var channelCountChoices: [qsTr("4通道"), qsTr("8通道"), qsTr("16通道")]
    readonly property var channelCountValues: [4, 8, 16]
    readonly property var impedanceChoices: [qsTr("5kΩ"), qsTr("10kΩ"), qsTr("20kΩ")]
    readonly property var impedanceValues: ["5", "10", "20"]

    function loadSettings() {
        if (!database)
            return
        recordDir = database.setting("record_dir", Acq.defaultRecordDir)
        saveIntervalIndex = Math.max(0, saveIntervalValues.indexOf(
                                        database.setting("auto_save_minutes", "10")))
        fileFormatIndex = Math.max(0, fileFormatValues.indexOf(
                                      database.setting("record_format", "bdf")))
        channelCountIndex = Math.max(0, channelCountValues.indexOf(
                                        Number(database.setting("default_channels", "16"))))
        impedanceThresholdIndex = Math.max(0, impedanceValues.indexOf(
                                              database.setting("low_impedance_kohm", "10")))
    }

    function saveSettings() {
        if (!database)
            return

        database.setSetting("record_dir", recordDir)
        database.setSetting("auto_save_minutes", saveIntervalValues[saveIntervalIndex])
        database.setSetting("record_format", fileFormatValues[fileFormatIndex])
        database.setSetting("default_channels", String(channelCountValues[channelCountIndex]))
        database.setSetting("low_impedance_kohm", impedanceValues[impedanceThresholdIndex])

        // 「默认通道数」顺带应用到工作台的档位，否则这个设置要等到下次开程序
        // 才看得出效果，等于没生效。采集进行中不动它 —— 泳道数量在中途变样
        // 会让人以为数据出了问题
        if (!Acq.collecting)
            Acq.channelCount = channelCountValues[channelCountIndex]

        saved()
    }

    // file:///D:/x/y → D:\x\y。只为文件对话框服务，不引入额外的模块
    function pathFromUrl(url) {
        var text = url.toString()
        if (text.indexOf("file:///") === 0)
            text = text.substring(8)
        return decodeURIComponent(text).replace(/\//g, "\\")
    }

    FolderDialog {
        id: folderDialog
        title: qsTr("选择记录保存目录")
        onAccepted: root.recordDir = root.pathFromUrl(selectedFolder)
    }

    // 采集默认值的「默认采样率」是只读的：设备按固定的 1000 Hz 出帧，
    // 这个值必须与设备一致，不能由用户改（改了只会让时间轴与算法的时间基准全错）
    readonly property string deviceRateText: Acq.sample_rate() + "Hz"

    AppShell {
        anchors.fill: parent
        pageTitle: qsTr("系统设置")
        currentNav: qsTr("系统设置")
        statusItems: {
            var items = [qsTr("标签：") + root.tags.length + qsTr(" 个")]
            items.push(qsTr("记录目录：") + root.recordDir)
            return items
        }
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
                elide: Text.ElideLeft
                text: root.recordDir
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16

                ToolTip.visible: pathMouse.containsMouse
                ToolTip.text: root.recordDir
                ToolTip.delay: 400
            }

            Rectangle {
                x: 751
                y: 59
                width: 59
                height: 32
                radius: 10
                color: browseMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
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

                MouseArea {
                    id: browseMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: folderDialog.open()
                }
            }

            // 路径文字本身也可以点开目录选择：看到路径不对时第一反应是点它
            MouseArea {
                id: pathMouse
                x: 582
                y: 59
                width: 154
                height: 32
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: folderDialog.open()
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
                choices: root.saveIntervalChoices
                currentIndex: root.saveIntervalIndex
                onActivated: (index) => root.saveIntervalIndex = index
            }

            SettingRow {
                x: 0
                y: 181
                label: qsTr("记录文件格式")
                choices: root.fileFormatChoices
                currentIndex: root.fileFormatIndex
                onActivated: (index) => root.fileFormatIndex = index
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

            // 只读：设备的采样率不能改，写成下拉框只会让人以为能改
            SettingRow {
                x: 0
                y: 64
                label: qsTr("默认采样率")
                readOnly: true
                value: root.deviceRateText
                hint: qsTr("由设备决定")
            }

            SettingRow {
                x: 0
                y: 122
                label: qsTr("默认通道数")
                choices: root.channelCountChoices
                currentIndex: root.channelCountIndex
                onActivated: (index) => root.channelCountIndex = index
            }

            SettingRow {
                x: 0
                y: 180
                label: qsTr("低阻抗自动提醒")
                hint: qsTr("阈值")
                choices: root.impedanceChoices
                currentIndex: root.impedanceThresholdIndex
                onActivated: (index) => root.impedanceThresholdIndex = index
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

            Text {
                x: 100
                y: 9
                height: 28
                verticalAlignment: Text.AlignVCenter
                text: qsTr("共 %1 个").arg(root.tags.length)
                color: Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
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
                        visible: index === 0
                    }

                    Rectangle {
                        x: 29
                        y: parent.rowY + 17
                        width: 18
                        height: 18
                        radius: 4
                        color: modelData.color.length > 0 ? modelData.color : Design.primary
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
                            width: parent.width - 24
                            elide: Text.ElideRight
                            text: modelData.code.length > 0 ? modelData.code : qsTr("未设置")
                            color: modelData.code.length > 0 ? "#3b3b3b" : Design.textMuted
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
                        onClicked: root.editTagRequested(modelData)
                    }

                    TagAction {
                        x: 720
                        y: parent.rowY + 11
                        width: 59
                        text: qsTr("删除")
                        onClicked: root.deleteTagRequested(modelData.id, modelData.name)
                    }

                    // 行分隔线：设计稿是主色 30%，比通用 divider（主色 20%）略重，照抄设计稿的 alpha
                    Rectangle {
                        x: 20
                        y: parent.rowY + 51
                        width: 789
                        height: 1
                        color: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.30)
                        visible: index < root.tags.length - 1
                    }
                }
            }

            // 一个标签都没有时说明该点哪儿，否则表格区一大片空白看着像没加载出来
            Text {
                x: 31
                y: 120
                visible: root.tags.length === 0
                text: qsTr("还没有标签，点下方「新增标签」建一个")
                color: Design.textMuted
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
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
            onClicked: root.saveSettings()
        }
    }

    // 设置行：左标签 + 右侧下拉框。设计稿里「数据存储」「采集默认值」两块共 5 行同构。
    // 自身原点 = 面板左边缘 / 本行标签文字顶边；行距 58（设计稿 286 → 345 → ...）。
    component SettingRow: Item {
        id: settingRow

        property string label: ""
        // 只读行直接显示这个值
        property string value: ""
        // 「阈值」这类夹在标签和下拉框之间的灰字提示，只有低阻抗那一行有
        property string hint: ""
        property bool dividerBelow: true
        // 只读：不画下拉框也不可点，值直接写在框里（设备决定的值，如采样率）
        property bool readOnly: false

        property var choices: []
        property int currentIndex: 0
        signal activated(int index)

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

        // 右对齐贴着下拉框左侧：只读行那个「由设备决定」比「阈值」长得多，
        // 从固定 x 左对齐会一路顶进右边的数值框，和「1000Hz」叠在一起
        Text {
            x: 480
            y: 0
            width: 169
            horizontalAlignment: Text.AlignRight
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

        // 只读行：灰底 + 数值，不给箭头也不给点击 —— 看不出能点，就不会有人去点
        Rectangle {
            x: 668
            y: -4
            width: 142
            height: 29
            radius: 10
            visible: settingRow.readOnly
            color: Design.panelFillSoft

            Text {
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                text: settingRow.value
                color: Design.textSecondary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }
        }

        ChoiceField {
            x: 668
            y: -4
            width: 142
            height: 29
            visible: !settingRow.readOnly
            pixelSize: 14
            fieldRadius: 10
            choices: settingRow.choices
            currentIndex: settingRow.currentIndex
            onActivated: (index) => settingRow.activated(index)
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

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
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
