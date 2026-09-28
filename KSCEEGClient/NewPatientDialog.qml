import QtQuick

// 「新增患者」弹窗（施工图 dialog-新增患者.txt）。
//
// 坐标：外部会把 root 撑成设计稿画板尺寸 1920×1080，所以下面所有的 x/y 都是施工图里的
// 画板绝对坐标，直接照抄、不做换算。卡片 @657,339 606×402。
//
// 导出文件里混进了「选择患者」弹窗的节点（那两张卡片在画板上有重叠，导出按范围过滤时
// 带了进来：档案列表底、列表 5 行、登记新患者按钮、以及位置在 327 的关闭叉等），
// 那些不属于本弹窗，这里只实现 新增患者 卡片自己的内容。
//
// 卡片和内容是平级声明的（卡片在前、内容在后），靠声明顺序保证内容画在卡片之上；
// 卡片自己的 MouseArea 吃掉卡片范围内的空白点击，内容里的按钮声明得更晚，不会被它挡住。
Item {
    id: root

    signal dismissed()      // 关闭 / 取消
    signal accepted()       // 保存

    // 表单字段（施工图里的 矩形 21~27 + 标签 + 提示/取值）。
    // 所有坐标都是画板绝对坐标：标签 y = 字段 y + 8，文字 y = 字段 y + 11，都是施工图里的值。
    readonly property var formFields: [
        { label: qsTr("病历号"), labelX: 683, fieldX: 746,  fieldY: 418, fieldW: 204, text: qsTr("留空自动生成"), placeholder: true },
        { label: qsTr("姓名*"),  labelX: 978, fieldX: 1029, fieldY: 418, fieldW: 204, text: qsTr("患者姓名"),     placeholder: true },
        { label: qsTr("性别"),   labelX: 683, fieldX: 746,  fieldY: 483, fieldW: 204, text: qsTr("男"),           placeholder: false, arrow: true },
        { label: qsTr("年龄"),   labelX: 978, fieldX: 1029, fieldY: 483, fieldW: 204, text: qsTr("如：李四"),     placeholder: true },
        { label: qsTr("科室"),   labelX: 683, fieldX: 746,  fieldY: 548, fieldW: 204, text: qsTr("神经内科"),     placeholder: false, arrow: true },
        { label: qsTr("诊断"),   labelX: 978, fieldX: 1029, fieldY: 548, fieldW: 204, text: qsTr("如：癫痫"),     placeholder: true },
        { label: qsTr("备注"),   labelX: 683, fieldX: 746,  fieldY: 613, fieldW: 487, text: qsTr("选填"),         placeholder: true }
    ]

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
        y: 339
        width: 606
        height: 402
        radius: 16
        color: "#ffffff"

        MouseArea {
            anchors.fill: parent
        }
    }

    // ---------- 标题 ----------
    Text {
        x: 683
        y: 362
        text: qsTr("新增患者")
        color: Design.textPrimary
        font.family: Design.fontBold
        font.pixelSize: 24
    }

    // 直线 47：标题下方的渐隐分隔线
    PanelDivider {
        x: 664
        y: 405
        width: 592
    }

    // ---------- 表单 ----------
    // 字段只做外形还原（施工图画的是一排空输入框），所以用 Text 静态画出提示/取值，
    // 没有接 TextInput；要能输入的话由调用方在这里换成输入控件。
    Repeater {
        model: root.formFields

        delegate: Item {
            required property var modelData

            Rectangle {
                x: modelData.fieldX
                y: modelData.fieldY
                width: modelData.fieldW
                height: 43
                radius: 12
                color: Design.primarySoft
            }

            Text {
                x: modelData.labelX
                y: modelData.fieldY + 8
                text: modelData.label
                color: Design.textPrimary
                font.family: Design.fontRegular
                font.pixelSize: 18
            }

            Text {
                x: modelData.fieldX + 13
                y: modelData.fieldY + 11
                text: modelData.text
                // 占位文字是 #3b3b3b 30%（和患者管理页搜索框同一套），已选的取值是实色
                color: modelData.placeholder ? Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30) : "#3b3b3b"
                font.family: Design.fontRegular
                font.pixelSize: 16
            }

            // 下拉箭头（施工图 路径 @935,499 10×8 rot=90，性别/科室两个字段各一个）。
            // 施工图节点带 rot=90，Figma 插件给出的 x 是旋转前的左上角，渲染图实测箭头
            // 落在 925~935（= 935 − 宽 10），这里按渲染图取 925；导出的 svg 本身就是
            // 设计稿里那个朝向，不用再转。
            Image {
                x: 925
                y: modelData.fieldY + 16
                width: 10
                height: 8
                visible: modelData.arrow !== undefined
                source: "assets/icons/icon-arrow-down.svg"
            }
        }
    }

    // 直线 48：底部按钮上方的渐隐分隔线
    PanelDivider {
        x: 664
        y: 678
        width: 592
    }

    // ---------- 底部按钮 ----------
    // 次要按钮：返回检查（施工图 矩形备份 84，主色 50% 描边、无填充）
    Rectangle {
        x: 985
        y: 692
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

    // 主按钮：保存（施工图 矩形备份 85，实心主色）
    Rectangle {
        x: 1117
        y: 692
        width: 121
        height: 35
        radius: 12
        color: confirmMouse.pressed ? "#64879f" : Design.primary

        Text {
            anchors.centerIn: parent
            text: qsTr("保存")
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

    // ---------- 关闭叉（施工图 14.12×14.12 的实心 VECTOR，位置比另外两个弹窗低 38）----------
    Image {
        x: 1217.44
        y: 368.44
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
