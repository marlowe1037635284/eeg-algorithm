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
            x: 704
            y: 415
            text: qsTr("张文涛")
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        // 姓名与年龄之间设计稿留了两个空格，照抄
        Text {
            x: 775
            y: 421
            text: qsTr("男  45岁")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: 1032
            y: 421
            text: qsTr("P-0001·神经内科·记录1次")
            color: Design.textSecondary
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
                // 电极质量**没有数据源**：协议一次只给 4 路不带电极名的阻抗值
                //（见 serialprotocol.h），推不出「N/16 良好」。与其编一个数字，
                // 不如写明拿不到
                { x: 869,  y: 559, label: qsTr("电极质量"), value: qsTr("—") },
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
