import QtQuick
import KSCEEGClient

// 「编辑患者」弹窗。按 Figma 设计稿 1:1 实现。
//
// 设计稿画板 1920×1080，白色卡片位于 (657,339)、尺寸 606×402；
// 本文件里卡片内部的坐标 = 设计稿绝对坐标 - (657,339)，数值照抄施工图。
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 应用数据库，由外层注入
    property var database
    // 改的是哪一位（改病历号时要用它定位原记录）
    property string originalNo
    // 保存失败的原因
    property string errorText

    // 表单初值，外部在弹出前回填当前患者信息
    property alias recordNo: recordNoField.text
    property alias patientName: nameField.text
    property alias age: ageField.text
    property alias diagnosis: diagnosisField.text
    property alias remark: remarkField.text
    property string gender: qsTr("男")
    property string department: qsTr("神经内科")

    readonly property var genderChoices: [qsTr("男"), qsTr("女")]
    readonly property var departmentChoices: [qsTr("神经内科"), qsTr("神经外科"), qsTr("康复科"), qsTr("其他")]

    // 把一行患者数据填进表单
    function load(row) {
        if (!row)
            return
        errorText = ""
        originalNo = row.no
        recordNo = row.no
        patientName = row.name
        age = String(row.age)
        diagnosis = row.diag
        remark = row.note
        gender = row.gender.length > 0 ? row.gender : genderChoices[0]
        department = row.dept.length > 0 ? row.dept : departmentChoices[0]
    }

    function save() {
        errorText = ""
        if (!database) {
            errorText = qsTr("数据库不可用，无法保存")
            return
        }

        var years = Number(age)
        if (isNaN(years))
            years = 0

        var result = database.updatePatient(originalNo, recordNo, patientName, gender, years,
                                            department, diagnosis, remark)
        if (!result.success) {
            errorText = result.message
            return
        }
        accepted()
    }


    DialogFrame {
        title: qsTr("编辑患者")
        cardX: 657
        cardY: 339
        cardWidth: 606
        cardHeight: 402
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        // 上下两条分隔线（设计稿是渐变描边，用 PanelDivider 的淡出效果）
        PanelDivider { x: 7; y: 66; width: 592 }
        PanelDivider { x: 7; y: 339; width: 592 }

        // ---------- 表单标签（左列 / 右列）----------
        FormLabel { x: 26;  y: 87;  text: qsTr("病历号") }
        FormLabel { x: 26;  y: 152; text: qsTr("性别") }
        FormLabel { x: 26;  y: 217; text: qsTr("科室") }
        FormLabel { x: 26;  y: 282; text: qsTr("备注") }
        // 姓名是必填项，星号单独拆出来画成红色（与「新增患者」一致）：
        // 整条标签只用一个 Text 的话没法只染色末尾那个星号
        Row {
            x: 321
            y: 87
            spacing: 0

            FormLabel { text: qsTr("姓名") }
            FormLabel { text: "*"; color: Design.bad }
        }
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

        // 下拉：点开列表来选
        ChoiceField {
            x: 89
            y: 144
            width: 204
            choices: root.genderChoices
            currentIndex: Math.max(0, root.genderChoices.indexOf(root.gender))
            onActivated: (index) => root.gender = root.genderChoices[index]
        }

        ChoiceField {
            x: 89
            y: 209
            width: 204
            choices: root.departmentChoices
            currentIndex: Math.max(0, root.departmentChoices.indexOf(root.department))
            onActivated: (index) => root.department = root.departmentChoices[index]
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
            placeholder: qsTr("如：45")
            numeric: true
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

        // 保存失败的原因。设计稿没有错误栏，放在分隔线上方的空处
        Text {
            x: 89
            y: 340
            width: 487
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

        DialogButton {
            x: 460
            y: 353
            text: qsTr("保存")
            primary: true
            onClicked: root.save()
        }
    }

    // 表单标签：18/28，正文字色
    component FormLabel: Text {
        height: 28
        verticalAlignment: Text.AlignVCenter
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
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
        // 只收整数（年龄这种）。校验器挂在 TextInput 上，非法字符根本敲不进去
        property bool numeric: false

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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
            font.letterSpacing: -0.27
            selectionColor: Design.primary
            selectedTextColor: "#ffffff"
            selectByMouse: true
            clip: true
            validator: field.numeric ? ageValidator : null

            IntValidator { id: ageValidator; bottom: 0; top: 150 }
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
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
        source: Design.assetRoot + "icons/icon-arrow-down.svg"
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
