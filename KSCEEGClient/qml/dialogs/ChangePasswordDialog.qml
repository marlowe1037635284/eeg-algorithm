import QtQuick
import KSCEEGClient

// 「修改密码」弹窗（用户自行改密码）。
//
// 与「重置密码」不同：那个是管理员给**别人**设新密码，改错了被改的人也看不出来，
// 所以只要两个框；这个是自己改自己，必须先证明「你是你」，因此多一个原密码框，
// 校验交给数据层（changePassword 会拿库里那份原密码比对）。
//
// 版式沿用其它弹窗（DialogFrame 白卡 + 两个胶囊按钮），卡片按内容加高一行。
Item {
    id: root

    signal dismissed()
    signal accepted()

    property var database
    property string errorText: ""

    property alias oldText: oldField.text
    property alias passwordText: passwordField.text
    property alias confirmText: confirmField.text

    // 每次打开都清空，避免上一次的残留
    function open() {
        errorText = ""
        oldText = ""
        passwordText = ""
        confirmText = ""
    }

    function save() {
        errorText = ""
        if (!database) {
            errorText = qsTr("数据库不可用，无法修改密码")
            return
        }
        if (oldText.length === 0) {
            errorText = qsTr("请输入原密码")
            return
        }
        if (passwordText.length < 6) {
            errorText = qsTr("新密码至少 6 位")
            return
        }
        if (passwordText !== confirmText) {
            errorText = qsTr("两次输入的新密码不一致")
            return
        }

        const result = database.changePassword(oldText, passwordText)
        if (!result.success) {
            errorText = result.message
            return
        }
        accepted()
    }

    readonly property int cardWidth: 486
    readonly property int cardHeight: 400

    DialogFrame {
        title: qsTr("修改密码")
        cardX: (Design.canvasWidth - root.cardWidth) / 2
        cardY: (Design.canvasHeight - root.cardHeight) / 2
        cardWidth: root.cardWidth
        cardHeight: root.cardHeight
        dismissOnBackdrop: false
        onDismissed: root.dismissed()

        Text {
            x: 26
            y: 68
            width: root.cardWidth - 52
            elide: Text.ElideRight
            text: qsTr("需先输入原密码，再设置新密码")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        PanelDivider { x: 7; y: 96; width: root.cardWidth - 14 }

        FormLabel { x: 26; y: 116; text: qsTr("原密码") }

        PasswordField {
            id: oldField
            x: 128
            y: 107
            width: root.cardWidth - 154
            placeholder: qsTr("请输入当前密码")
        }

        FormLabel { x: 26; y: 166; text: qsTr("新密码") }

        PasswordField {
            id: passwordField
            x: 128
            y: 157
            width: root.cardWidth - 154
            placeholder: qsTr("至少 6 位")
        }

        FormLabel { x: 26; y: 216; text: qsTr("确认新密码") }

        PasswordField {
            id: confirmField
            x: 128
            y: 207
            width: root.cardWidth - 154
            placeholder: qsTr("再输入一次")
            onAccepted: root.save()
        }

        Text {
            x: 26
            y: 254
            width: root.cardWidth - 52
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
            x: root.cardWidth - 26 - 121 - 12 - 121
            y: root.cardHeight - 35 - 24
            text: qsTr("取消")
            onClicked: root.dismissed()
        }

        DialogButton {
            x: root.cardWidth - 26 - 121
            y: root.cardHeight - 35 - 24
            text: qsTr("确认修改")
            primary: true
            onClicked: root.save()
        }
    }

    component FormLabel: Text {
        height: 28
        verticalAlignment: Text.AlignVCenter
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 16
    }

    component PasswordField: Rectangle {
        id: passwordFieldItem

        property alias text: fieldInput.text
        property string placeholder: ""

        signal accepted()

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
            echoMode: TextInput.Password
            passwordCharacter: "●"
            maximumLength: 64
            onAccepted: passwordFieldItem.accepted()
        }

        Text {
            x: 20
            y: 11
            height: 22
            verticalAlignment: Text.AlignVCenter
            text: passwordFieldItem.placeholder
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
