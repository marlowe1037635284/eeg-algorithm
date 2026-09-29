import QtQuick
import KSCEEGClient

// 「新建 / 编辑标签」弹窗。按 Figma 设计稿实现，并补上「对应编码」一栏。
//
// 设计稿画板 1920×1080，白色卡片位于 (657,382)、尺寸 606×315；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (657,382)。
//
// 补编码栏的原因：标签管理表格里有「对应编码」这一列（设计稿写的是 101,102），
// 而设计稿的新建弹窗只有名称和颜色两项 —— 照抄的话新建出来的标签编码永远是空的，
// 那一列就成了摆设。编码是设备侧的触发码，建标签时正是唯一能填它的时机。
//
// 一个弹窗兼两种模式：新建与编辑的字段完全一样，拆两份只是多一份要同步维护的表单。
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 应用数据库，由外层注入。保存成功才 accepted()
    property var database
    // 保存失败的原因（名称重复、数据库不可用），显示在分隔线上方的空处
    property string errorText

    // 编辑模式：非 0 表示改的是这个标签；0 表示新建
    property int editingTagId: 0
    readonly property bool editMode: editingTagId > 0

    // 8 个可选标签色（取自施工图）
    readonly property var tagColors: ["#e5494d", "#f76b14", "#e6a014", "#31a46d",
                                      "#12a593", "#3f63dd", "#8e4ec6", "#6e7788"]
    // 标签名最长 20 个字符，右下角的计数提示跟着走
    readonly property int maxNameLength: 20

    property alias tagName: tagNameInput.text
    property alias tagCode: tagCodeInput.text
    property int selectedColorIndex: 7      // 设计稿默认选中第 8 个（灰）
    readonly property string selectedColor: root.tagColors[root.selectedColorIndex]

    // 打开时把已有标签读进来；tag 为空就是新建
    function openFor(tag) {
        errorText = ""
        if (!tag) {
            editingTagId = 0
            tagName = ""
            tagCode = ""
            selectedColorIndex = 7
            return
        }
        editingTagId = tag.id
        tagName = tag.name
        tagCode = tag.code
        const at = tagColors.indexOf(tag.color)
        selectedColorIndex = at >= 0 ? at : 7
    }

    function save() {
        errorText = ""
        if (!database) {
            errorText = qsTr("数据库不可用，无法保存")
            return
        }
        var result = editMode
                     ? database.updateTag(editingTagId, tagName, tagCode, selectedColor)
                     : database.addTag(tagName, tagCode, selectedColor)
        if (!result.success) {
            errorText = result.message
            return
        }
        accepted()
    }

    DialogFrame {
        title: root.editMode ? qsTr("编辑标签") : qsTr("新建标签")
        cardX: 657
        cardY: 382
        cardWidth: 606
        cardHeight: 315
        titleY: 14
        closeY: 20
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        // 上下两条分隔线（设计稿是渐变描边）
        PanelDivider { x: 7; y: 57; width: 592 }
        PanelDivider { x: 7; y: 244; width: 592 }

        // ---------- 标签名称 ----------
        Text {
            x: 26
            y: 78
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("标签名称")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
            font.letterSpacing: -0.27
        }

        Rectangle {
            x: 113
            y: 70
            width: 463
            height: 43
            radius: 12
            color: Design.primarySoft

            TextInput {
                id: tagNameInput
                x: 20
                y: 11
                width: parent.width - 20 - 40     // 右侧给字数提示留位置
                height: 22
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
                selectionColor: Design.primary
                selectedTextColor: "#ffffff"
                selectByMouse: true
                clip: true
                maximumLength: root.maxNameLength
            }

            // 输入提示
            Text {
                x: 20
                y: 11
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: qsTr("例如：rTMS、闪光刺激···")
                visible: tagNameInput.text.length === 0
                color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                font.letterSpacing: -0.27
            }

            // 字数提示，跟着输入长度变
            Text {
                x: 428
                y: 11
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: tagNameInput.text.length + "/" + root.maxNameLength
                color: Qt.rgba(0, 0, 0, 0.40)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 12
                font.letterSpacing: -0.27
            }
        }

        // ---------- 对应编码 ----------
        Text {
            x: 26
            y: 133
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("对应编码")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
            font.letterSpacing: -0.27
        }

        Rectangle {
            x: 113
            y: 125
            width: 463
            height: 43
            radius: 12
            color: Design.primarySoft

            TextInput {
                id: tagCodeInput
                x: 20
                y: 11
                width: parent.width - 40
                height: 22
                color: "#3b3b3b"
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
                selectionColor: Design.primary
                selectedTextColor: "#ffffff"
                selectByMouse: true
                clip: true
                maximumLength: 32
            }

            Text {
                x: 20
                y: 11
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: qsTr("设备侧的触发码，多个用逗号分隔，如 101,102")
                visible: tagCodeInput.text.length === 0
                color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 16
            }
        }

        // ---------- 标签颜色 ----------
        Text {
            x: 26
            y: 190
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("标签颜色")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
            font.letterSpacing: -0.27
        }

        Repeater {
            model: root.tagColors

            delegate: Item {
                required property int index
                required property string modelData

                x: 115 + 45 * index    // 色块起点 772，间距 45
                y: 187
                width: 33
                height: 33

                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: modelData
                }

                // 选中项：外面套一圈黑框（施工图是偏移 -3 的 39×39 描边框）
                Rectangle {
                    x: -3
                    y: -3
                    width: 39
                    height: 39
                    radius: 10
                    color: "transparent"
                    border.width: 1
                    border.color: "#000000"
                    visible: index === root.selectedColorIndex
                }

                Image {
                    anchors.centerIn: parent
                    width: 13.63
                    height: 9.48
                    source: Design.assetRoot + "icons/icon-check-bold.svg"
                    visible: index === root.selectedColorIndex
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectedColorIndex = index
                }
            }
        }

        // 保存失败的原因
        Text {
            x: 113
            y: 222
            width: 463
            height: 20
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            visible: root.errorText.length > 0
            text: root.errorText
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        // ---------- 底部按钮 ----------
        DialogButton {
            x: 328
            y: 258
            text: qsTr("返回检查")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: 460
            y: 258
            text: root.editMode ? qsTr("保存") : qsTr("创建标签")
            primary: true
            onClicked: root.save()
        }
    }

    // 弹窗底部的胶囊按钮：次要按钮主色 50% 描边，主按钮实心主色
    component DialogButton: Rectangle {
        id: dialogButton

        property string text: ""
        property bool primary: false
        signal clicked()

        width: 121
        height: 35
        radius: 12
        color: dialogButton.primary
               ? (dialogButtonMouse.pressed ? "#64879f" : Design.primary)
               : "transparent"
        border.width: 1
        border.color: dialogButton.primary ? Design.panelBorder : Design.pillBorder

        Text {
            anchors.centerIn: parent
            text: dialogButton.text
            color: dialogButton.primary ? "#ffffff" : "#4f4f4f"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
            font.letterSpacing: -0.27
        }

        MouseArea {
            id: dialogButtonMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dialogButton.clicked()
        }
    }
}
