import QtQuick

// 「编辑患者」弹窗。按 Figma 设计稿 1:1 实现。
//
// 设计稿画板 1920×1080，白色卡片位于 (657,339)、尺寸 606×402；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (657,339)，数值照抄施工图。
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 表单初值，外部在弹出前回填当前患者信息
    property alias recordNo: recordNoField.text
    property alias patientName: nameField.text
    property alias age: ageField.text
    property alias diagnosis: diagnosisField.text
    property alias remark: remarkField.text
    property string gender: qsTr("男")
    property string department: qsTr("神经内科")

    // ---------- 遮罩 ----------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0xdb / 255, 0xdd / 255, 0xe0 / 255, 0.60)

        // 弹窗是模态的：吞掉点击，避免穿透到底下的列表
        MouseArea {
            anchors.fill: parent
        }
    }

    // ---------- 白色卡片 ----------
    Rectangle {
        x: 657
        y: 339
        width: 606
        height: 402
        radius: 16
        color: "#ffffff"

        // 标题（设计稿 85 Bold，24/28）
        Text {
            x: 26
            y: 23
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: qsTr("编辑患者")
            color: Design.textPrimary
            font.family: Design.fontBold
            font.pixelSize: 24
            font.letterSpacing: -0.27
        }

        // 关闭叉（设计稿矢量 14.12×14.12）
        Image {
            x: 560.44
            y: 29.44
            width: 14.12
            height: 14.12
            source: "assets/icons/icon-close.svg"

            MouseArea {
                anchors.fill: parent
                anchors.margins: -8      // 放大点击热区
                cursorShape: Qt.PointingHandCursor
                onClicked: root.dismissed()
            }
        }

        // 上下两条分隔线（设计稿是渐变描边，用 PanelDivider 的淡出效果）
        PanelDivider { x: 7; y: 66; width: 592 }
        PanelDivider { x: 7; y: 339; width: 592 }

        // ---------- 表单标签（左列 / 右列）----------
        FormLabel { x: 26;  y: 87;  text: qsTr("病历号") }
        FormLabel { x: 26;  y: 152; text: qsTr("性别") }
        FormLabel { x: 26;  y: 217; text: qsTr("科室") }
        FormLabel { x: 26;  y: 282; text: qsTr("备注") }
        FormLabel { x: 321; y: 87;  text: qsTr("姓名*") }
        FormLabel { x: 321; y: 152; text: qsTr("年龄") }
        FormLabel { x: 321; y: 217; text: qsTr("诊断") }

        // ---------- 输入框 ----------
        Field {
            id: recordNoField
            x: 89
            y: 79
            width: 204
            placeholder: qsTr("留空自动生成")
        }

        Field {
            id: genderField
            x: 89
            y: 144
            width: 204
            text: root.gender
            readOnly: true

            // 下拉箭头（设计稿 10×8 rot=90，绕左上角旋转）
            DropArrow { x: 189; y: 16 }
        }

        Field {
            id: deptField
            x: 89
            y: 209
            width: 204
            text: root.department
            readOnly: true

            DropArrow { x: 189; y: 16 }
        }

        Field {
            id: remarkField
            x: 89
            y: 274
            width: 487
            placeholder: qsTr("选填")
        }

        Field {
            id: nameField
            x: 372
            y: 79
            width: 204
            placeholder: qsTr("患者姓名")
        }

        Field {
            id: ageField
            x: 372
            y: 144
            width: 204
            placeholder: qsTr("如：李四")
        }

        Field {
            id: diagnosisField
            x: 372
            y: 209
            width: 204
            placeholder: qsTr("如：癫痫")
        }

        // ---------- 底部按钮 ----------
        DialogButton {
            x: 328
            y: 353
            text: qsTr("返回检查")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: 460
            y: 353
            text: qsTr("保存")
            primary: true
            onClicked: root.accepted()
        }
    }

    // 表单标签：18/28，正文字色
    component FormLabel: Text {
        height: 28
        verticalAlignment: Text.AlignVCenter
        color: Design.textPrimary
        font.family: Design.fontRegular
        font.pixelSize: 18
        font.letterSpacing: -0.27
    }

    // 输入框：主色 10% 的圆角底 + 内嵌输入。
    // 设计稿里 7 个输入框的内边距都是 (13,11)，所以统一写在这里。
    component Field: Rectangle {
        id: field

        property alias text: fieldInput.text
        property alias readOnly: fieldInput.readOnly
        property string placeholder: ""

        height: 43
        radius: 12
        color: Design.primarySoft

        TextInput {
            id: fieldInput
            x: 13
            y: 11
            width: field.width - 26
            height: 22
            color: "#3b3b3b"
            font.family: Design.fontRegular
            font.pixelSize: 16
            font.letterSpacing: -0.27
            selectionColor: Design.primary
            selectedTextColor: "#ffffff"
            selectByMouse: true
            clip: true
        }

        // 占位提示（设计稿里占位文字同样是 #3b3b3b，只是 30% 透明）
        Text {
            x: 13
            y: 11
            width: field.width - 26
            height: 22
            text: field.placeholder
            visible: fieldInput.text.length === 0
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
            font.family: Design.fontRegular
            font.pixelSize: 16
            font.letterSpacing: -0.27
        }
    }

    // 下拉箭头（施工图里是矢量 10×8 旋转 90°，旋转轴在左上角）
    component DropArrow: Image {
        width: 10
        height: 8
        rotation: 90
        transformOrigin: Item.TopLeft
        source: "assets/icons/icon-arrow-down.svg"
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
            font.family: Design.fontRegular
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
