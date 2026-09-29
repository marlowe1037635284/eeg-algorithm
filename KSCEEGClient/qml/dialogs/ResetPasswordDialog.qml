import QtQuick
import KSCEEGClient

// 「重置密码」弹窗。
//
// 设计稿里没有这一屏 —— 用户管理页那个「重置密码」按钮原来没有任何行为。
// 版式沿用其它弹窗（DialogFrame 白卡 + 两个胶囊按钮），卡片按内容收窄。
//
// 两个框而不是一个：重置密码是管理员手输新密码，敲错一次就把别人的密码改成了
// 自己以为的那个，而除了被重置的人谁也看不出来
Item {
    id: root

    signal dismissed()
    signal accepted()

    property var database
    // 正在重置谁的密码
    property string account: ""
    property string displayName: ""
    property string errorText: ""

    property alias passwordText: passwordField.text
    property alias confirmText: confirmField.text

    function openFor(row) {
        account = row ? row.account : ""
        displayName = row ? row.name : ""
        errorText = ""
        passwordText = ""
        confirmText = ""
    }

    function save() {
        errorText = ""
        if (!database || account.length === 0) {
            errorText = qsTr("数据库不可用，无法重置密码")
            return
        }
        if (passwordText.length < 6) {
            errorText = qsTr("新密码至少 6 位")
            return
        }
        if (passwordText !== confirmText) {
            errorText = qsTr("两次输入的密码不一致")
            return
        }

        const result = database.resetPassword(account, passwordText)
        if (!result.success) {
            errorText = result.message
            return
        }
        accepted()
    }

    readonly property int cardWidth: 486
    readonly property int cardHeight: 330

    DialogFrame {
        title: qsTr("重置密码")
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
            text: qsTr("为「%1（%2）」设置新密码").arg(root.displayName).arg(root.account)
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        PanelDivider { x: 7; y: 96; width: root.cardWidth - 14 }

        FormLabel { x: 26; y: 116; text: qsTr("新密码") }

        PasswordField {
            id: passwordField
            x: 128
            y: 107
            width: root.cardWidth - 154
            placeholder: qsTr("至少 6 位")
        }

        FormLabel { x: 26; y: 166; text: qsTr("确认密码") }

        PasswordField {
            id: confirmField
            x: 128
            y: 157
            width: root.cardWidth - 154
            placeholder: qsTr("再输入一次")
            onAccepted: root.save()
        }

        Text {
            x: 26
            y: 204
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
            text: qsTr("确认重置")
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
