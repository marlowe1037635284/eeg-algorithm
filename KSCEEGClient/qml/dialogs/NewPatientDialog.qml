import QtQuick
import KSCEEGClient

// 「新增患者」弹窗（施工图 dialog-新增患者.txt）。
//
// 坐标：外部会把 root 撑成设计稿画板尺寸 1920×1080；
// 遮罩、白卡、标题、关闭叉都在 DialogFrame 里，正文用画板绝对坐标。
//
// 导出文件里混进了「选择患者」弹窗的节点（那两张卡片在画板上有重叠，导出按范围过滤时
// 带了进来：档案列表底、列表 5 行、登记新患者按钮、以及位置在 327 的关闭叉等），
// 那些不属于本弹窗，这里只实现 新增患者 卡片自己的内容。
//
Item {
    id: root

    signal dismissed()      // 关闭 / 取消
    signal accepted()       // 保存

    // 应用数据库。由外层注入（Main.qml），保存时往 patients 表写一条
    property var database
    // 保存失败的原因。设计稿没有错误栏，出错时显示在表单与按钮之间那条空白里
    property string errorText
    // 保存成功后的病历号，外层拿它去选中这位患者
    property string savedPatientNo

    // 表单字段（施工图里的 矩形 21~27 + 标签 + 提示/取值）。
    // 所有坐标都是画板绝对坐标：标签 y = 字段 y + 8，文字 y = 字段 y + 11，都是施工图里的值。
    //
    // 下标即字段顺序，save() 按这个顺序取值：
    //   0 病历号 1 姓名 2 性别 3 年龄 4 科室 5 诊断 6 备注
    // 带 choices 的是下拉（点击循环取值），其余是可输入的文本框
    readonly property var formFields: [
        { label: qsTr("病历号"), labelX: 683, fieldX: 746,  fieldY: 418, fieldW: 204, placeholder: qsTr("留空自动生成") },
        { label: qsTr("姓名*"),  labelX: 978, fieldX: 1029, fieldY: 418, fieldW: 204, placeholder: qsTr("患者姓名") },
        { label: qsTr("性别"),   labelX: 683, fieldX: 746,  fieldY: 483, fieldW: 204, choices: [qsTr("男"), qsTr("女")] },
        // 施工图这一格写的提示是「如：李四」—— 那是姓名不是年龄，明显是导出时抄错了。
        // 按语义改成年龄的例子
        { label: qsTr("年龄"),   labelX: 978, fieldX: 1029, fieldY: 483, fieldW: 204, placeholder: qsTr("如：45"), numeric: true },
        { label: qsTr("科室"),   labelX: 683, fieldX: 746,  fieldY: 548, fieldW: 204,
          choices: [qsTr("神经内科"), qsTr("神经外科"), qsTr("康复科"), qsTr("其他")] },
        { label: qsTr("诊断"),   labelX: 978, fieldX: 1029, fieldY: 548, fieldW: 204, placeholder: qsTr("如：癫痫") },
        { label: qsTr("备注"),   labelX: 683, fieldX: 746,  fieldY: 613, fieldW: 487, placeholder: qsTr("选填") }
    ]

    // 按字段下标取控件当前值
    function fieldValue(index) {
        var item = fieldRepeater.itemAt(index)
        return item !== null && item !== undefined ? item.value : ""
    }

    // 保存到数据库。失败时把原因留在界面上 —— 「点了没反应」是表单最糟的反馈
    function save() {
        errorText = ""
        if (!database) {
            errorText = qsTr("数据库不可用，无法保存")
            return
        }

        var age = Number(fieldValue(3))
        if (isNaN(age))
            age = 0

        var result = database.addPatient(fieldValue(0), fieldValue(1), fieldValue(2), age,
                                         fieldValue(4), fieldValue(5), fieldValue(6))
        if (!result.success) {
            errorText = result.message
            return
        }

        savedPatientNo = result.no
        accepted()
    }

    DialogFrame {
        title: qsTr("新增患者")
        cardX: 657
        cardY: 339
        cardWidth: 606
        cardHeight: 402
        contentInCanvasCoords: true
        dismissOnBackdrop: true
        onDismissed: root.dismissed()


        // 直线 47：标题下方的渐隐分隔线
        PanelDivider {
            x: 664
            y: 405
            width: 592
        }

        // ---------- 表单 ----------
        Repeater {
            id: fieldRepeater
            model: root.formFields

            delegate: Item {
                required property var modelData

                // 下拉字段：只读，点一下切到下一个选项
                readonly property bool isChoice: modelData.choices !== undefined
                // 控件当前值。save() 通过 Repeater.itemAt(index).value 取值，
                // 这样控件本身是什么不影响取值口
                property alias value: field.text

                // 下拉字段的底与箭头由 ChoiceField 自己画，这里不重复
                Rectangle {
                    x: modelData.fieldX
                    y: modelData.fieldY
                    width: modelData.fieldW
                    height: 43
                    radius: 12
                    color: Design.primarySoft
                    visible: !parent.isChoice
                }

                Text {
                    x: modelData.labelX
                    y: modelData.fieldY + 8
                    text: modelData.label
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 18
                }

                // 下拉：点开一个列表来选

                ChoiceField {
                    id: choiceControl
                    x: modelData.fieldX
                    y: modelData.fieldY
                    width: modelData.fieldW
                    height: 43
                    visible: parent.isChoice
                    choices: parent.isChoice ? modelData.choices : []
                    // 值也要能从这里取到（save() 走 Repeater.itemAt(i).value）
                    onActivated: (index) => parent.choiceValue = modelData.choices[index]
                    Component.onCompleted: {
                        // 下拉给个初值，否则框里是空的、看着像没填
                        if (parent.isChoice)
                            parent.choiceValue = modelData.choices[0]
                    }
                }

                TextInput {
                    id: field
                    x: modelData.fieldX + 13
                    y: modelData.fieldY + 11
                    width: modelData.fieldW - 26
                    height: 22
                    visible: !parent.isChoice
                    color: "#3b3b3b"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                    selectionColor: Design.primary
                    selectedTextColor: "#ffffff"
                    clip: true
                    selectByMouse: true
                    // 年龄只收整数。上限给 150 —— 不设上限的话 99999 也能存进库
                    validator: modelData.numeric === true ? ageValidator : null

                    IntValidator {
                        id: ageValidator
                        bottom: 0
                        top: 150
                    }
                }

                // 占位文字。#3b3b3b 30%（和患者管理页搜索框同一套）
                Text {
                    x: modelData.fieldX + 13
                    y: modelData.fieldY + 11
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    visible: field.text.length === 0
                    text: modelData.placeholder !== undefined ? modelData.placeholder : ""
                    color: Qt.rgba(0x3b / 255, 0x3b / 255, 0x3b / 255, 0.30)
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }


            }
        }

        // ---------- 保存失败的原因 ----------
        // 设计稿没有错误栏；出错时显示在表单与按钮之间那条空白里。
        // 表单最糟的反馈就是「点了没反应」，所以原因必须落到界面上
        Text {
            x: 683
            y: 658
            width: 500
            height: 22
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            visible: root.errorText.length > 0
            text: root.errorText
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
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
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
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
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 14
            }

            MouseArea {
                id: confirmMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // 真的写库；成功才 accepted()
                onClicked: root.save()
            }
        }

        // ---------- 关闭叉（施工图 14.12×14.12 的实心 VECTOR，位置比另外两个弹窗低 38）----------
    }
}
