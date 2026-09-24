import QtQuick
import QtQuick.Controls.Basic

ApplicationWindow {
    id: window

    width: 1280
    height: 720
    minimumWidth: 960
    minimumHeight: 540
    visible: true
    color: "#e7e7e7"
    title: qsTr("EEG-KSC 登录")

    signal loginRequested(string account, string password, bool rememberPassword)
    signal forgotPasswordRequested()

    readonly property real designWidth: 1920
    readonly property real designHeight: 1080
    readonly property real contentScale: Math.min(width / designWidth, height / designHeight)

    function submitLogin() {
        if (accountInput.text.trim().length === 0) {
            accountInput.forceActiveFocus()
            return
        }

        if (passwordInput.text.length === 0) {
            passwordInput.forceActiveFocus()
            return
        }

        loginRequested(accountInput.text.trim(), passwordInput.text, rememberPassword.checked)
    }

    Item {
        id: viewport
        anchors.centerIn: parent
        width: window.designWidth * window.contentScale
        height: window.designHeight * window.contentScale
        clip: true

        Item {
            id: designCanvas
            width: window.designWidth
            height: window.designHeight
            scale: window.contentScale
            transformOrigin: Item.TopLeft

            Image {
                id: backgroundImage
                x: -4
                y: -1
                width: 1928
                height: 1085
                source: "assets/login-background.jpg"
                fillMode: Image.Stretch
                smooth: true
                mipmap: true
            }

            // Figma 中的三层脑电波形：后层、阴影层和主色层。
            Image {
                x: 785
                y: 334
                width: 997
                height: 476
                source: "assets/asset-03.svg"
                fillMode: Image.Stretch
                smooth: true
            }

            Image {
                x: 801
                y: 395
                width: 981
                height: 403
                source: "assets/asset-09.svg"
                fillMode: Image.Stretch
                smooth: true
            }

            Image {
                x: 661
                y: 449
                width: 1245
                height: 242
                source: "assets/asset-10.svg"
                fillMode: Image.Stretch
                smooth: true
            }

            Item {
                id: loginForm
                x: 282
                y: 276
                width: 346
                height: 460

                Text {
                    x: -3
                    y: 0
                    text: qsTr("Welcome.")
                    color: "#ff8d1a"
                    font.family: "Microsoft YaHei"
                    font.pixelSize: 60
                    font.weight: Font.Black
                    renderType: Text.NativeRendering
                }

                Text {
                    x: 0
                    y: 80
                    text: qsTr("登录 EEG -空山慈 脑电采集与分析平台")
                    color: "#ff8d1a"
                    font.family: "Microsoft YaHei"
                    font.pixelSize: 20
                    font.weight: Font.Medium
                    renderType: Text.NativeRendering
                }

                Text {
                    x: 0
                    y: 145
                    text: qsTr("手机号：")
                    color: "#262729"
                    font.family: "Microsoft YaHei"
                    font.pixelSize: 17
                    renderType: Text.NativeRendering
                }

                Rectangle {
                    id: accountField
                    x: 0
                    y: 179
                    width: 346
                    height: 51
                    radius: 10
                    color: "#12000000"
                    border.width: accountInput.activeFocus ? 1 : 0
                    border.color: "#7092ab"

                    TextInput {
                        id: accountInput
                        objectName: "accountInput"
                        anchors.fill: parent
                        anchors.leftMargin: 22
                        anchors.rightMargin: 22
                        color: "#3d3d3d"
                        selectionColor: "#7092ab"
                        selectedTextColor: "#ffffff"
                        font.family: "Microsoft YaHei"
                        font.pixelSize: 15
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        focus: true
                        clip: true
                        onAccepted: passwordInput.forceActiveFocus()

                        Text {
                            anchors.fill: parent
                            text: qsTr("账号")
                            color: "#3d3d3d"
                            opacity: 0.82
                            font: accountInput.font
                            verticalAlignment: Text.AlignVCenter
                            visible: accountInput.text.length === 0
                        }
                    }
                }

                Text {
                    x: 0
                    y: 251
                    text: qsTr("密码：")
                    color: "#262729"
                    font.family: "Microsoft YaHei"
                    font.pixelSize: 17
                    renderType: Text.NativeRendering
                }

                Rectangle {
                    id: passwordField
                    x: 0
                    y: 295
                    width: 346
                    height: 50
                    radius: 10
                    color: "#12000000"
                    border.width: passwordInput.activeFocus ? 1 : 0
                    border.color: "#7092ab"

                    TextInput {
                        id: passwordInput
                        objectName: "passwordInput"
                        anchors.fill: parent
                        anchors.leftMargin: 22
                        anchors.rightMargin: 22
                        color: "#3d3d3d"
                        selectionColor: "#7092ab"
                        selectedTextColor: "#ffffff"
                        font.family: "Microsoft YaHei"
                        font.pixelSize: 15
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        echoMode: TextInput.Password
                        passwordCharacter: "●"
                        clip: true
                        onAccepted: window.submitLogin()

                        Text {
                            anchors.fill: parent
                            text: qsTr("密码")
                            color: "#3d3d3d"
                            opacity: 0.82
                            font: passwordInput.font
                            verticalAlignment: Text.AlignVCenter
                            visible: passwordInput.text.length === 0
                        }
                    }
                }

                CheckBox {
                    id: rememberPassword
                    objectName: "rememberPassword"
                    x: 0
                    y: 354
                    width: 126
                    height: 28
                    checked: true
                    text: qsTr("记住密码")
                    activeFocusOnTab: true

                    indicator: Rectangle {
                        x: 2
                        y: 3
                        width: 19
                        height: 19
                        radius: 3
                        color: rememberPassword.checked ? "#ff8d1a" : "transparent"
                        border.width: 1
                        border.color: rememberPassword.checked ? "#ff8d1a" : "#9a9a9a"

                        Text {
                            anchors.centerIn: parent
                            y: -1
                            text: "✓"
                            color: "white"
                            font.family: "Microsoft YaHei"
                            font.pixelSize: 14
                            font.bold: true
                            visible: rememberPassword.checked
                        }
                    }

                    contentItem: Text {
                        leftPadding: 33
                        text: rememberPassword.text
                        color: "#262729"
                        font.family: "Microsoft YaHei"
                        font.pixelSize: 15
                        verticalAlignment: Text.AlignVCenter
                        renderType: Text.NativeRendering
                    }
                }

                Text {
                    id: forgotPassword
                    objectName: "forgotPassword"
                    x: 284
                    y: 360
                    text: qsTr("忘记密码")
                    color: forgotMouseArea.containsMouse ? "#ff8d1a" : "#7092ab"
                    font.family: "Microsoft YaHei"
                    font.pixelSize: 15
                    font.underline: true
                    renderType: Text.NativeRendering

                    MouseArea {
                        id: forgotMouseArea
                        anchors.fill: parent
                        anchors.margins: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: window.forgotPasswordRequested()
                    }
                }

                Button {
                    id: loginButton
                    objectName: "loginButton"
                    x: 0
                    y: 405
                    width: 346
                    height: 55
                    activeFocusOnTab: true
                    hoverEnabled: true
                    onClicked: window.submitLogin()

                    background: Rectangle {
                        radius: 12
                        color: loginButton.down ? "#64879f"
                                                : loginButton.hovered ? "#789ab2"
                                                                      : "#7092ab"
                    }

                    contentItem: Text {
                        text: qsTr("登    录")
                        color: "#ffffff"
                        font.family: "Microsoft YaHei"
                        font.pixelSize: 24
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        renderType: Text.NativeRendering
                    }
                }
            }
        }
    }
}
