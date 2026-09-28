import QtQuick
import QtQuick.Controls.Basic

// 登录页。按设计稿「登录」画板 1:1 还原：
// 所有坐标、尺寸、字号、颜色都取自设计稿规格（画板 1920×1080）。
// 整页按 contentScale 等比缩放，保证任何窗口尺寸下比例与设计稿一致。
Item {
    id: loginPage

    signal loginRequested(string account, string password, bool rememberPassword)
    signal forgotPasswordRequested()
    property string errorMessage: ""
    property alias accountText: accountInput.text
    property alias passwordText: passwordInput.text
    property alias rememberChecked: rememberPassword.checked

    function clearPassword() { passwordInput.text = "" }

    readonly property real designWidth: Design.canvasWidth
    readonly property real designHeight: Design.canvasHeight
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

    DesignCanvas {
        anchors.fill: parent


    // 背景：设计稿是一张 4000×2250 的图，在画板里摆在 (-4,-1)、1928×1085
    Image {
        x: -4
        y: -1
        width: 1928
        height: 1085
        source: "assets/login-background.jpg"
        fillMode: Image.Stretch
        smooth: true
        mipmap: true
    }

    // 右侧脑电波形装饰：设计稿里分成三层（浅影、深影、主色），位置尺寸照抄
    Image {
        x: 785.08
        y: 333.65
        width: 996.85
        height: 475.5
        source: "assets/asset-03.svg"
        fillMode: Image.Stretch
        smooth: true
    }

    Image {
        x: 800.87
        y: 394.96
        width: 981.05
        height: 403.38
        source: "assets/asset-09.svg"
        fillMode: Image.Stretch
        smooth: true
    }

    Image {
        x: 661
        y: 448.58
        width: 1245
        height: 242.25
        source: "assets/asset-10.svg"
        fillMode: Image.Stretch
        smooth: true
    }

    // ---------- 左侧登录表单 ----------
    // 设计稿里表单没有容器，元素直接摆在画板上，这里也照做
    Item {
        id: loginForm
        x: 279
        y: 308
        width: 336
        height: 428

        // 「Welcome.」的 y 特意写成 -43（即画板上的 265），不是设计稿存的 308。
        // 设计稿里这个节点是自动高度 + 文本尾部带换行（"Welcome.\n"），
        // .fig 里存的 y 与它实际渲染出来的位置对不上：按 308 摆会和下面一行
        // 副标题叠在一起。这里以设计稿的渲染图为准对齐。
        Text {
            x: 0
            y: -43
            text: qsTr("Welcome.")
            color: Design.brand
            font.family: Design.fontHeavy
            font.pixelSize: 60
            renderType: Text.NativeRendering
        }

        Text {
            x: 3
            y: 51
            text: qsTr("登录 EEG -空山慈 脑电采集与分析平台")
            color: Design.brand
            font.family: Design.fontMedium
            font.pixelSize: 20
            renderType: Text.NativeRendering
        }

        Text {
            x: 3
            y: 117
            text: qsTr("手机号：")
            color: "#262729"
            font.family: Design.fontRegular
            font.pixelSize: 17
            renderType: Text.NativeRendering
        }

        // 账号输入框：7% 黑底 + 1px 主色描边 + 圆角 10
        Rectangle {
            id: accountField
            x: 3
            y: 147
            width: 346
            height: 50
            radius: 10
            color: Qt.rgba(0, 0, 0, 0.07)
            border.width: 1
            border.color: Design.primary

            TextInput {
                id: accountInput
                objectName: "accountInput"
                anchors.fill: parent
                anchors.leftMargin: 22
                anchors.rightMargin: 22
                text: "admin"
                color: "#3d3d3d"
                selectionColor: Design.primary
                selectedTextColor: "#ffffff"
                font.family: Design.fontRegular
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
                    font: accountInput.font
                    verticalAlignment: Text.AlignVCenter
                    visible: accountInput.text.length === 0
                }
            }
        }

        Text {
            x: 3
            y: 223
            text: qsTr("密码：")
            color: "#262729"
            font.family: Design.fontRegular
            font.pixelSize: 17
            renderType: Text.NativeRendering
        }

        // 密码输入框：设计稿里这个框画成了直角（账号框是圆角），
        // 应是设计疏漏，这里按账号框统一成圆角 10。
        Rectangle {
            id: passwordField
            x: 3
            y: 263
            width: 346
            height: 50
            radius: 10
            color: Qt.rgba(0, 0, 0, 0.07)

            TextInput {
                id: passwordInput
                objectName: "passwordInput"
                anchors.fill: parent
                anchors.leftMargin: 22
                anchors.rightMargin: 22
                text: "admin123456"
                color: "#3d3d3d"
                selectionColor: Design.primary
                selectedTextColor: "#ffffff"
                font.family: Design.fontRegular
                font.pixelSize: 15
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                activeFocusOnTab: true
                echoMode: TextInput.Password
                passwordCharacter: "●"
                clip: true
                onAccepted: loginPage.submitLogin()

                Text {
                    anchors.fill: parent
                    text: qsTr("密码")
                    color: "#3d3d3d"
                    font: passwordInput.font
                    verticalAlignment: Text.AlignVCenter
                    visible: passwordInput.text.length === 0
                }
            }
        }

        // 记住密码：19×19 橙色圆角方块 + 白色对勾。
        // 方块用 CheckBox 只为保住 Tab 焦点和空格切换，视觉自己画；
        // 文案另起一个 Text 精确摆放 —— CheckBox 内部会额外留 padding，
        // 靠 leftPadding 对不齐设计稿的 x。
        Item {
            x: 5
            y: 328
            width: 150
            height: 21

            CheckBox {
                id: rememberPassword
                objectName: "rememberPassword"
                x: 0
                y: 1
                width: 19
                height: 19
                checked: true
                activeFocusOnTab: true

                indicator: Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: rememberPassword.checked ? Design.brand : "transparent"
                    border.width: 1
                    border.color: rememberPassword.checked ? Design.brand : "#9a9a9a"

                    Image {
                        x: 6
                        y: 7
                        width: 8
                        height: 6
                        source: "assets/icons/icon-check.svg"
                        visible: rememberPassword.checked
                    }
                }
                contentItem: Item { }
            }

            Text {
                x: 31
                y: 0
                text: qsTr("记住密码")
                color: "#262729"
                font.family: Design.fontRegular
                font.pixelSize: 15
                renderType: Text.NativeRendering
            }

            // 点这一行的空白处也能切换
            MouseArea {
                anchors.fill: parent
                z: -1
                cursorShape: Qt.PointingHandCursor
                onClicked: rememberPassword.toggle()
            }
        }

        Text {
            id: forgotPassword
            objectName: "forgotPassword"
            x: 287
            y: 328
            text: qsTr("忘记密码")
            color: forgotMouseArea.containsMouse ? Design.brand : Design.primary
            font.family: Design.fontRegular
            font.pixelSize: 15
            renderType: Text.NativeRendering

            MouseArea {
                id: forgotMouseArea
                anchors.fill: parent
                anchors.margins: -8
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: loginPage.forgotPasswordRequested()
            }
        }

        // 登录按钮
        Rectangle {
            id: loginButton
            objectName: "loginButton"
            x: 3
            y: 373
            width: 346
            height: 55
            radius: 12
            color: loginMouseArea.pressed ? "#64879f"
                                          : loginMouseArea.containsMouse ? "#789ab2" : Design.primary

            Text {
                anchors.centerIn: parent
                text: qsTr("登    录")
                color: "#ffffff"
                font.family: Design.fontMedium
                font.pixelSize: 24
                font.letterSpacing: -0.27
                renderType: Text.NativeRendering
            }

            MouseArea {
                id: loginMouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: loginPage.submitLogin()
            }
        }

        // 设计稿里没有错误提示，放在按钮下方空白处，不挤占任何设计元素
        Text {
            x: 3
            y: 440
            width: 346
            text: loginPage.errorMessage
            color: Design.bad
            font.family: Design.fontRegular
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            visible: text.length > 0
        }
    }
    }
}
