import QtQuick

// 「采集前确认」弹窗（施工图 dialog-采集前确认.txt）。
//
// 坐标：外部会把 root 撑成设计稿画板尺寸 1920×1080，所以下面所有的 x/y 都是施工图里的
// 画板绝对坐标，直接照抄、不做换算。卡片 @657,298 606×484。
//
// 卡片和内容是平级声明的（卡片在前、内容在后），靠声明顺序保证内容画在卡片之上；
// 卡片自己的 MouseArea 吃掉卡片范围内的空白点击，内容里的按钮声明得更晚，不会被它挡住。
Item {
    id: root

    signal dismissed()      // 关闭 / 取消
    signal accepted()       // 确认

    // ---------- 整屏遮罩 ----------
    // 施工图是整屏 #dbdde0 60%。这里选「点遮罩也发 dismissed」，卡片自己的 MouseArea
    // 会把卡片上的点击吞掉，所以点卡片空白处不会误关。
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0xdb / 255, 0xdd / 255, 0xe0 / 255, 0.60)

        MouseArea {
            anchors.fill: parent
            onClicked: root.dismissed()
        }
    }

    // ---------- 白色卡片（施工图 Rectangle 233）----------
    Rectangle {
        x: 657
        y: 298
        width: 606
        height: 484
        radius: 16
        color: "#ffffff"

        MouseArea {
            anchors.fill: parent
        }
    }

    // ---------- 标题 ----------
    Text {
        x: 683
        y: 321
        text: qsTr("开始采集前确认")
        color: Design.textPrimary
        font.family: Design.fontBold
        font.pixelSize: 24
    }

    Text {
        x: 683
        y: 358
        text: qsTr("确认对象与关键采集参数，防止数据关联错误")
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    // 直线 47：标题下方的渐隐分隔线
    PanelDivider {
        x: 664
        y: 398
        width: 592
    }

    // ---------- 待确认的患者（施工图 矩形 49 + 三个文本）----------
    Rectangle {
        x: 681
        y: 409
        width: 557
        height: 45
        radius: 10
        color: Design.primarySoft
    }

    Text {
        x: 704
        y: 415
        text: qsTr("张文涛")
        color: "#000000"
        font.family: Design.fontMedium
        font.pixelSize: 20
    }

    // 姓名与年龄之间设计稿留了两个空格，照抄
    Text {
        x: 775
        y: 421
        text: qsTr("男  45岁")
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 16
    }

    Text {
        x: 1032
        y: 421
        text: qsTr("P-0001·神经内科·记录1次")
        color: Design.textSecondary
        font.family: Design.fontRegular
        font.pixelSize: 16
    }

    // ---------- 采集参数（3 列 × 2 行小块）----------
    Repeater {
        model: [
            { x: 682,  y: 473, label: qsTr("设备"),     value: qsTr("Neurolink  16") },
            { x: 869,  y: 473, label: qsTr("连接"),     value: qsTr("稳定"), valueColor: Design.good },
            { x: 1056, y: 473, label: qsTr("通道"),     value: qsTr("16通道") },
            { x: 682,  y: 559, label: qsTr("采样率"),   value: qsTr("256Hz") },
            { x: 869,  y: 559, label: qsTr("电极质量"), value: qsTr("14/16 良好") },
            { x: 1056, y: 559, label: qsTr("原始数据"), value: qsTr("不过滤保存") }
        ]

        delegate: Item {
            required property var modelData

            Rectangle {
                x: modelData.x
                y: modelData.y
                width: 182
                height: 80
                radius: 7
                color: Design.panelFillSoft
            }

            Text {
                x: modelData.x + 18
                y: modelData.y + 13
                text: modelData.label
                color: Design.textSecondary
                font.family: Design.fontRegular
                font.pixelSize: 16
            }

            Text {
                x: modelData.x + 18
                y: modelData.y + 44
                text: modelData.value
                // 只有「连接」的值是绿色，其余是深灰
                color: modelData.valueColor !== undefined ? modelData.valueColor : "#333333"
                font.family: Design.fontMedium
                font.pixelSize: 16
            }
        }
    }

    // ---------- 提示条（施工图 矩形 50）----------
    Rectangle {
        x: 681
        y: 656
        width: 557
        height: 45
        radius: 10
        color: Qt.rgba(0xff / 255, 0x8d / 255, 0x1a / 255, 0.10)
    }

    // 提示图标：施工图是 20×20 的橙色圈 + 感叹号（不是实心圆）
    Rectangle {
        x: 699
        y: 669
        width: 20
        height: 20
        radius: 10
        color: "transparent"
        border.width: 2
        border.color: Design.brand

        Text {
            anchors.centerIn: parent
            text: "!"
            color: Design.brand
            font.family: Design.fontBold
            font.pixelSize: 15
        }
    }

    Text {
        x: 732
        y: 668
        text: qsTr("采集开始后，受试者、通道数将锁定；显示幅度、时集和滤波仍可调整。")
        color: Design.brand
        font.family: Design.fontRegular
        font.pixelSize: 14
    }

    // 直线 48：底部按钮上方的渐隐分隔线
    PanelDivider {
        x: 664
        y: 719
        width: 592
    }

    // ---------- 底部按钮 ----------
    // 次要按钮：返回检查（施工图 矩形备份 84，主色 50% 描边、无填充）
    Rectangle {
        x: 985
        y: 733
        width: 121
        height: 35
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: Design.pillBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("返回检查")
            color: "#4f4f4f"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismissed()
        }
    }

    // 主按钮：确认并开始（施工图 矩形备份 85，实心主色）+ 右侧播放三角
    Rectangle {
        x: 1117
        y: 733
        width: 121
        height: 35
        radius: 12
        color: confirmMouse.pressed ? "#64879f" : Design.primary

        // 三角 + 文字整体居中：施工图里三角 @1145,747（相对本按钮 19.5,13.5 未旋转、
        // 旋转后视觉范围 1136~1145）、文字 @1153,741（相对 36,8）。
        // 导出的 icon-play.svg 朝上，施工图节点是 rot=90（朝右），所以这里转 90°。
        Image {
            x: 19.5
            y: 13.5
            width: 8
            height: 9
            rotation: 90
            source: "assets/icons/icon-play.svg"
        }

        Text {
            x: 36
            y: 8
            text: qsTr("确认并开始")
            color: "#ffffff"
            font.family: Design.fontRegular
            font.pixelSize: 14
        }

        MouseArea {
            id: confirmMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.accepted()
        }
    }

    // ---------- 关闭叉（施工图 14.12×14.12 的实心 VECTOR）----------
    Image {
        x: 1220.44
        y: 330.44
        width: 14.12
        height: 14.12
        source: "assets/icons/icon-close.svg"

        MouseArea {
            anchors.fill: parent
            anchors.margins: -8     // 图标只有 14px 见方，向外放大点击热区
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismissed()
        }
    }
}
