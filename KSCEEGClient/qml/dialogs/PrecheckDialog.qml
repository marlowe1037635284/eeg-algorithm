import QtQuick
import KSCEEGClient

// 「采集前确认」弹窗（施工图 dialog-采集前确认.txt）。
//
// 坐标：外部会把 root 撑成设计稿画板尺寸 1920×1080；
// 遮罩、白卡、标题、关闭叉都在 DialogFrame 里，正文用画板绝对坐标。
//
Item {
    id: root

    signal dismissed()      // 关闭 / 取消
    signal accepted()       // 确认

    // 待确认的患者。由外层从工作台当前状态带进来，**不在这里写死**：
    // 这一屏的副标题就是「确认对象与关键采集参数，防止数据关联错误」，
    // 对象都还没选就挂着一个写死的人名，正是它最不该犯的错
    property bool hasPatient: false
    property string patientName: ""
    property string patientGenderAge: ""
    property string patientMeta: ""

    DialogFrame {
        title: qsTr("开始采集前确认")
        cardX: 657
        cardY: 298
        cardWidth: 606
        cardHeight: 484
        contentInCanvasCoords: true
        dismissOnBackdrop: true
        onDismissed: root.dismissed()

        Text {
            x: 683
            y: 358
            text: qsTr("确认对象与关键采集参数，防止数据关联错误")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
            id: patientNameText
            x: 704
            y: 415
            text: root.hasPatient ? root.patientName : qsTr("未选择患者")
            // 空态用次要色：它不是一个名字，只是一个「还没有」的状态
            color: root.hasPatient ? "#000000" : Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        // 姓名与年龄之间设计稿留了两个空格，照抄。
        // 位置取设计稿的 775 与「姓名右边缘 + 空隙」中较大的那个：
        // 三个字的名字落在设计稿的位置上，更长时才往右让
        Text {
            id: genderAgeText
            x: Math.max(775, patientNameText.x + patientNameText.width + 10)
            y: 421
            visible: root.hasPatient
            text: root.patientGenderAge
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 同理；科室与诊断由用户填写、长度没边，所以给右边界，
        // 长了就省略而不是顶出卡片
        Text {
            x: Math.max(1032, genderAgeText.x + genderAgeText.width + 16)
            y: 421
            width: Math.max(0, 1238 - x)
            elide: Text.ElideRight
            visible: root.hasPatient
            text: root.patientMeta
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 没有患者时，紧挨姓名右侧说清该怎么办 —— 比只留一个「未选择患者」有用。
        // 位置挂在姓名的实际宽度之后，不能写死 x：「未选择患者」比设计稿的
        // 「张文涛」宽，写死 775 会两个文本叠在一起
        Text {
            x: patientNameText.x + patientNameText.width + 16
            y: 421
            visible: !root.hasPatient
            text: qsTr("请先返回工作台选择或登记患者")
            color: Design.bad
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 采集参数（3 列 × 2 行小块）----------
        // 值全部改成读真实状态。原来这几个都是写死的（采样率 256Hz、电极 14/16 良好），
        // 而工作台实际跑的是 1000Hz —— 确认框是用户点「开始采集」前最后看到的一屏，
        // 上面写着与实际不符的数字比不显示更糟
        Repeater {
            model: [
                { x: 682,  y: 473, label: qsTr("设备"),   value: qsTr("Neurolink  16") },
                { x: 869,  y: 473, label: qsTr("连接"),
                  value: Acq.portOpen ? qsTr("已连接") : qsTr("未连接"),
                  valueColor: Acq.portOpen ? Design.good : Design.bad },
                { x: 1056, y: 473, label: qsTr("通道"),   value: Acq.channelCount + qsTr("通道") },
                { x: 682,  y: 559, label: qsTr("采样率"), value: Acq.sample_rate() + "Hz" },
                // 电极质量取工作台那次「阻抗扫描」的结果（由信号估计，见
                // ElectrodePanel 的说明）。没扫过就写「未扫描」——
                // 这里原来写的是「—」，看着像扫了但没结果
                { x: 869,  y: 559, label: qsTr("电极质量"),
                  value: Acq.electrodeScanValid
                         ? Design.electrodeQualityText(Acq.electrodeQuality)
                         : qsTr("未扫描") },
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
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 16
                }

                Text {
                    x: modelData.x + 18
                    y: modelData.y + 44
                    text: modelData.value
                    // 只有「连接」的值是绿色，其余是深灰
                    color: modelData.valueColor !== undefined ? modelData.valueColor : "#333333"
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
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
                font.family: Design.fontFamily
                font.styleName: Design.styleBold
                font.pixelSize: 15
            }
        }

        Text {
            x: 732
            y: 668
            text: qsTr("采集开始后，受试者、通道数将锁定；显示幅度、时集和滤波仍可调整。")
            color: Design.brand
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
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
                source: Design.assetRoot + "icons/icon-play.svg"
            }

            Text {
                x: 36
                y: 8
                text: qsTr("确认并开始")
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
                onClicked: root.accepted()
            }
        }

    }
}
