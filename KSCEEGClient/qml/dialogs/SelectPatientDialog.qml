import QtQuick
import KSCEEGClient

// 「选择/登记患者」弹窗（施工图 dialog-选择患者.txt）。
//
// 坐标：外部会把 root 撑成设计稿画板尺寸 1920×1080；
// 遮罩、白卡、标题、关闭叉都在 DialogFrame 里，正文用画板绝对坐标。
//
Item {
    id: root

    signal dismissed()      // 关闭 / 取消
    signal accepted()       // 确定选择

    // 档案列表占位数据（施工图里 5 行内容完全相同，高亮行是第 3 行）。
    // y 是施工图里的画板绝对坐标，不是行距算出来的。
    readonly property var archiveRows: [
        { y: 472, no: "P-0001", name: "黎明", desc: "男·45岁·神经内科·1次记录", selected: false },
        { y: 505, no: "P-0001", name: "黎明", desc: "男·45岁·神经内科·1次记录", selected: false },
        { y: 539, no: "P-0001", name: "黎明", desc: "男·45岁·神经内科·1次记录", selected: true },
        { y: 573, no: "P-0001", name: "黎明", desc: "男·45岁·神经内科·1次记录", selected: false },
        { y: 607, no: "P-0001", name: "黎明", desc: "男·45岁·神经内科·1次记录", selected: false }
    ]

    // 行分隔线的 y（施工图 直线 10/49/50/51，最后一行下面不画）
    readonly property var archiveDividerY: [503, 536, 570, 604]

    DialogFrame {
        title: qsTr("选择/登记患者")
        cardX: 657
        cardY: 298
        cardWidth: 606
        cardHeight: 468
        contentInCanvasCoords: true
        dismissOnBackdrop: true
        onDismissed: root.dismissed()


        // 直线 47：标题下方的渐隐分隔线
        PanelDivider {
            x: 664
            y: 364
            width: 592
        }

        // ---------- 当前选中的患者（施工图 矩形 49 + 三个文本）----------
        Rectangle {
            x: 681
            y: 380
            width: 557
            height: 45
            radius: 10
            color: Design.primarySoft
        }

        Text {
            x: 704
            y: 386
            text: qsTr("张文涛")
            color: "#000000"
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        // 姓名与年龄之间设计稿留了两个空格，照抄
        Text {
            x: 775
            y: 392
            text: qsTr("男  45岁")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: 955
            y: 392
            text: qsTr("P-0001·神经内科·偏头痛·采集记录1次")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // ---------- 档案列表 ----------
        Text {
            x: 683
            y: 433
            text: qsTr("从档案中选择")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        // 列表底（施工图 Rectangle 223）
        Rectangle {
            x: 681
            y: 466
            width: 557
            height: 172
            radius: 7
            color: Design.panelFillSoft
        }

        // 行分隔线（施工图是主色 30%，按约定统一用设计系统的主色 20%）
        Repeater {
            model: root.archiveDividerY

            delegate: Rectangle {
                required property var modelData

                x: 690
                y: modelData
                width: 539
                height: 1
                color: Design.panelBorder
            }
        }

        Repeater {
            model: root.archiveRows

            delegate: Item {
                required property var modelData

                // 选中行的高亮条（施工图 矩形 50，直角、无描边）
                Rectangle {
                    x: 681
                    y: 536
                    width: 557
                    height: 34
                    color: Design.primarySoft
                    visible: modelData.selected
                }

                // 选中行的绿色对号（施工图 对号 @1213,546 13×13，勾本身 10.43×7.25）
                // 用两段带圆头的细线拼出来：左短脚 (0,1.6)→(3.2,7.25)，右长脚 (3.2,7.25)→(10.43,0)
                Item {
                    x: 1214.28
                    y: 548.88
                    width: 10.43
                    height: 7.25
                    visible: modelData.selected

                    Rectangle {
                        x: 0
                        y: 0.7
                        width: 6.49
                        height: 1.8
                        radius: 0.9
                        color: Design.good
                        transformOrigin: Item.Left
                        rotation: 60.5
                    }

                    Rectangle {
                        x: 3.2
                        y: 6.35
                        width: 10.24
                        height: 1.8
                        radius: 0.9
                        color: Design.good
                        transformOrigin: Item.Left
                        rotation: -45.1
                    }
                }

                Text {
                    x: 699
                    y: modelData.y
                    text: modelData.no
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 778
                    y: modelData.y
                    text: modelData.name
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 839
                    y: modelData.y
                    text: modelData.desc
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }

        // ---------- 登记新患者（施工图 矩形 25 底 + 矩形 24 描边）----------
        // 设计稿里点它会切到「新增患者」表单；本组件只做外观还原，没有额外约定信号，
        // 需要接交互的话由调用方在这块矩形上再叠一个 MouseArea。
        Rectangle {
            x: 681
            y: 649
            width: 557
            height: 43
            radius: 12
            color: Design.primarySoft
            border.width: 1
            border.color: Design.panelBorder
        }

        // 「+」图标（施工图 加 @903,663 15×15，笔画 12.72 长、2 粗）
        Rectangle {
            x: 904.12
            y: 669.51
            width: 12.72
            height: 2
            color: Design.textPrimary
        }

        Rectangle {
            x: 909.48
            y: 664.15
            width: 2
            height: 12.72
            color: Design.textPrimary
        }

        Text {
            x: 927
            y: 657
            text: qsTr("登记新患者")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 18
        }

        // 直线 48：底部按钮上方的渐隐分隔线
        PanelDivider {
            x: 664
            y: 706
            width: 592
        }

        // ---------- 底部按钮 ----------
        // 次要按钮：取消（施工图 矩形备份 84，主色 50% 描边、无填充）
        Rectangle {
            x: 985
            y: 720
            width: 121
            height: 35
            radius: 12
            color: "transparent"
            border.width: 1
            border.color: Design.pillBorder

            Text {
                anchors.centerIn: parent
                text: qsTr("取消")
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

        // 主按钮：确定选择（施工图 矩形备份 85，实心主色）
        Rectangle {
            x: 1117
            y: 720
            width: 121
            height: 35
            radius: 12
            color: confirmMouse.pressed ? "#64879f" : Design.primary

            Text {
                anchors.centerIn: parent
                text: qsTr("确定选择")
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
