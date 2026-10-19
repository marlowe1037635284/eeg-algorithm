import QtQuick
import KSCEEGClient

// 「新增用户 / 编辑用户」弹窗。
//
// 设计稿里没有这一屏 —— 用户管理页上的「新增用户」「编辑」原来点了没有任何反应，
// 因为对应的弹窗根本没建。版式沿用同一套设计语言（DialogFrame 白卡 + 底部两个
// 胶囊按钮 + 主色 10% 的圆角输入框），与「新增患者」对齐。
//
// 一个弹窗兼两种模式而不是拆两个：两种模式的字段只差最后一行的语义
//（新增填初始密码、编辑改账号状态），其余完全一样，拆开就是两份要同步维护的表单
Item {
    id: root

    signal dismissed()
    signal accepted()

    // 应用数据库，由外层注入
    property var database
    // 编辑模式：非空表示改的是这个账号；空串表示新增
    property string editingAccount: ""
    readonly property bool editMode: editingAccount.length > 0

    property string errorText: ""

    readonly property var roleChoices: [qsTr("管理员"), qsTr("医生"), qsTr("技师")]
    readonly property var statusChoices: [qsTr("启用"), qsTr("停用"), qsTr("待审核")]

    property alias accountText: accountField.text
    property alias nameText: nameField.text
    property alias deptText: deptField.text
    property alias passwordText: passwordField.text
    property int roleIndex: 1          // 默认「医生」：这个系统里医生最多
    property int statusIndex: 0

    function openFor(row) {
        errorText = ""
        passwordText = ""
        roleIndex = 1
        statusIndex = 0
        if (!row) {
            editingAccount = ""
            accountText = ""
            nameText = ""
            deptText = ""
            return
        }
        editingAccount = row.account
        accountText = row.account
        nameText = row.name
        // 「未分配」是列表里为了不留空单元格补的显示值，编辑时不能当成真科室填回库里
        deptText = row.dept === qsTr("未分配") ? "" : row.dept
        const roleAt = roleChoices.indexOf(row.role)
        roleIndex = roleAt >= 0 ? roleAt : roleChoices.length - 1
        const statusAt = statusChoices.indexOf(row.status)
        statusIndex = statusAt >= 0 ? statusAt : 0
    }

    function save() {
        errorText = ""
        if (!database) {
            errorText = qsTr("数据库不可用，无法保存")
            return
        }

        var result
        if (editMode) {
            result = database.updateUser(editingAccount, nameText, roleChoices[roleIndex],
                                         deptText, statusChoices[statusIndex])
        } else {
            result = database.addUser(accountText, passwordText, nameText,
                                      roleChoices[roleIndex], deptText)
        }

        if (!result.success) {
            errorText = result.message
            return
        }
        accepted()
    }

    DialogFrame {
        title: root.editMode ? qsTr("编辑用户") : qsTr("新增用户")
        cardX: 657
        cardY: 315
        cardWidth: 606
        cardHeight: 450
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        PanelDivider { x: 7; y: 66; width: 592 }

        // ---------- 用户名 ----------
        // 标签列统一 26 起、输入框统一 150 起：输入框列宽固定，
        //「部门 / 科室」这类较长的标签才不会和输入框贴在一起（见 bug#332）
        FormLabel { x: 26; y: 89; text: root.editMode ? qsTr("用户名") : qsTr("用户名*") }

        Rectangle {
            x: 150
            y: 80
            width: 426
            height: 43
            radius: 12
            // 编辑模式压暗：账号是登录凭据，改掉它等于换个人，不该在「编辑资料」里顺手做
            color: root.editMode ? Design.panelFillSoft : Design.primarySoft
        }

        TextInput {
            id: accountField
            x: 170
            y: 91
            width: 386
            height: 22
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
            selectionColor: Design.primary
            selectedTextColor: "#ffffff"
            selectByMouse: true
            readOnly: root.editMode
            clip: true
            maximumLength: 30
        }

        Text {
            x: 170
            y: 91
            height: 22
            verticalAlignment: Text.AlignVCenter
            visible: accountField.text.length === 0
            text: qsTr("登录账号，如 13800000000")
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 姓名 ----------
        FormLabel { x: 26; y: 139; text: qsTr("姓名*") }

        EditField {
            id: nameField
            x: 150
            y: 130
            placeholder: qsTr("真实姓名")
            maxLength: 20
        }

        // ---------- 角色 ----------
        FormLabel { x: 26; y: 189; text: qsTr("角色") }

        ChoiceField {
            x: 150
            y: 180
            width: 426
            height: 43
            choices: root.roleChoices
            currentIndex: root.roleIndex
            onActivated: (index) => root.roleIndex = index
        }

        // ---------- 部门 / 科室 ----------
        FormLabel { x: 26; y: 239; text: qsTr("部门 / 科室") }

        EditField {
            id: deptField
            x: 150
            y: 230
            placeholder: qsTr("如：神经内科")
            maxLength: 32
        }

        // ---------- 最后一行：新增填初始密码，编辑改账号状态 ----------
        FormLabel {
            x: 26
            y: 289
            text: root.editMode ? qsTr("账号状态") : qsTr("初始密码*")
        }

        ChoiceField {
            x: 150
            y: 280
            width: 426
            height: 43
            visible: root.editMode
            choices: root.statusChoices
            currentIndex: root.statusIndex
            onActivated: (index) => root.statusIndex = index
        }

        EditField {
            id: passwordField
            x: 150
            y: 280
            visible: !root.editMode
            placeholder: qsTr("8-16 位，含数字与字母")
            echoMode: TextInput.Password
            maxLength: 16
        }

        // 保存失败的原因。设计稿没有错误栏，放在分隔线上方的空处
        Text {
            x: 150
            y: 331
            width: 426
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

        PanelDivider { x: 7; y: 355; width: 592 }

        DialogButton {
            x: 328
            y: 369
            text: qsTr("取消")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: 460
            y: 369
            text: qsTr("保存")
            primary: true
            onClicked: root.save()
        }
    }

    // 标签：必填项的「*」单独一个红色 Text，不能只染末尾字符，所以拆成两个 Text
    component FormLabel: Row {
        id: formLabel

        property string text: ""

        spacing: 0

        Text {
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: formLabel.text.replace("*", "")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        Text {
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: "*"
            visible: formLabel.text.indexOf("*") !== -1
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }
    }

    // 输入框：主色 10% 底 + 内嵌输入 + 占位提示。与「编辑患者」里的 Field 同构，
    // 这里多一个 echoMode（初始密码要打码）
    component EditField: Rectangle {
        id: editField

        property alias text: fieldInput.text
        property string placeholder: ""
        property int echoMode: TextInput.Normal
        property int maxLength: 64

        width: 426
        height: 43
        radius: 12
        color: Design.primarySoft

        TextInput {
            id: fieldInput
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
            activeFocusOnTab: true
            clip: true
            echoMode: editField.echoMode
            maximumLength: editField.maxLength
        }

        Text {
            x: 20
            y: 11
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: editField.placeholder
            visible: fieldInput.text.length === 0
            color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }

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
