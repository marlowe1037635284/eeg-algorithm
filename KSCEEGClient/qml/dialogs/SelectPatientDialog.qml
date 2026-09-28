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
    // 点「登记新患者」→ 外层关掉本弹窗、打开新增患者弹窗
    signal newPatientRequested()

    // 应用数据库，由外层注入
    property var database

    // 档案列表来自 patients 表。Q_INVOKABLE 没有变更通知，所以用一个 revision
    // 显式触发重算：打开弹窗、或外面新增了患者之后调 reload()
    property int revision: 0
    property int selectedIndex: -1
    function reload() {
        revision++
        // 默认落在第一位：设计稿里也有一行是高亮的，全不高亮会让人以为「必须先点一下」。
        // 同时兜住重算之后下标越界的情况（患者被删了）
        if (selectedIndex < 0 || selectedIndex >= archiveRows.length)
            selectedIndex = archiveRows.length > 0 ? 0 : -1
    }

    readonly property var archiveRows: {
        revision   // 绑定依赖，改它就会重算
        return database ? database.patients() : []
    }

    // 施工图里 5 行的 y 是 472/505/539/573/607（画布绝对坐标），行距约 34 ——
    // 多于 5 位患者时按这个行距往下排，由下面的裁剪区负责截断与滚动。
    //
    // 下面这两个函数返回的是**相对裁剪容器**的 y（容器在画布 y=466）：
    // 472-466=6、503-466=37。原先返回的是画布绝对坐标，而行的父项已经换成了
    // 那个容器，等于把整张列表又往下推了 466 —— 表现就是「档案列表是空的」
    readonly property var rowStep: 33.75
    readonly property int listTop: 466
    readonly property int listHeight: 172
    readonly property int listOriginY: 466
    readonly property int listOriginX: 681
    // 列表可滚动的范围。比可视区高就滚得动
    readonly property real maxScroll: Math.max(0, archiveRows.length * rowStep - 2 - listHeight)
    property real scroll: 0
    function rowY(index) { return 472 - listOriginY + Math.round(index * rowStep) - scroll }
    function dividerY(index) { return 503 - listOriginY + Math.round(index * rowStep) - scroll }
    // 行描述：性别·年龄·科室·N 次记录
    function rowDesc(row) {
        return row.gender + "·" + row.age + "岁·" + row.dept + "·" + row.count
    }

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

        // 卡片里显示**当前高亮**的那位患者；一位都没有时说明该去哪儿登记。
        // 原来这里写死「张文涛」，与下面的档案列表其实是两份互不相干的数据
        Text {
            x: 704
            y: 386
            text: {
                if (root.selectedIndex >= 0 && root.selectedIndex < root.archiveRows.length)
                    return root.archiveRows[root.selectedIndex].name
                return root.archiveRows.length > 0 ? qsTr("请选择患者") : qsTr("暂无患者档案")
            }
            // 空态用次要色：它不是某个人的名字
            color: root.selectedIndex >= 0 ? "#000000" : Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        // 姓名与年龄之间设计稿留了两个空格，照抄
        Text {
            x: 775
            y: 392
            visible: root.selectedIndex >= 0 && root.selectedIndex < root.archiveRows.length
            text: {
                const row = root.archiveRows[root.selectedIndex]
                return row.gender + "  " + row.age + qsTr("岁")
            }
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: 955
            y: 392
            visible: root.selectedIndex >= 0 && root.selectedIndex < root.archiveRows.length
            text: {
                const row = root.archiveRows[root.selectedIndex]
                return row.no + "·" + row.dept + "·" + row.diag + qsTr("·采集记录") + row.count
            }
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 一位患者都没有时，把「下一步该干什么」说清楚
        Text {
            x: 775
            y: 392
            visible: root.archiveRows.length === 0
            text: qsTr("点下方「登记新患者」新增一位")
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

        // 裁剪区：患者多于 5 位时超出部分不画出来（设计稿只画了 5 行）。
        // 滚轮可滚 —— 不裁剪的话多出来的行会盖到下面的「登记新患者」按钮上
        Item {
            x: 681
            y: 466
            width: 557
            height: 172
            clip: true

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton      // 只收滚轮，不抢点击
                onWheel: (wheel) => {
                    var next = root.scroll - wheel.angleDelta.y / 6
                    root.scroll = Math.max(0, Math.min(root.maxScroll, next))
                }
            }

            // 行分隔线（施工图是主色 30%，按约定统一用设计系统的主色 20%）。
            // 最后一行下面不画
            Repeater {
                model: Math.max(0, root.archiveRows.length - 1)

                delegate: Rectangle {
                    required property int index

                    x: 9
                    y: root.dividerY(index)
                    width: 539
                    height: 1
                    color: Design.panelBorder
                }
            }

            Repeater {
                model: root.archiveRows

                delegate: Item {
                    required property var modelData
                    required property int index

                    // 选中行的高亮条（施工图 矩形 50，直角、无描边）。
                    // 施工图里高亮行 y=539、高亮条 y=536，往上偏 3
                    Rectangle {
                        x: 0
                        y: root.rowY(index) - 3
                        width: 557
                        height: 34
                        color: Design.primarySoft
                        visible: root.selectedIndex === index
                    }

                    // 整行可点：点哪儿都选中这一行
                    MouseArea {
                        x: 0
                        y: root.rowY(index) - 3
                        width: 557
                        height: 34
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedIndex = index
                    }

                // 选中行的绿色对号（施工图 对号 @1213,546 13×13，勾本身 10.43×7.25）
                // 用两段带圆头的细线拼出来：左短脚 (0,1.6)→(3.2,7.25)，右长脚 (3.2,7.25)→(10.43,0)
                Item {
                    x: 533.28
                    y: root.rowY(index) + 9.88
                    width: 10.43
                    height: 7.25
                    visible: root.selectedIndex === index

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
                    x: 18
                    y: root.rowY(index)
                    text: modelData.no
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 97
                    y: root.rowY(index)
                    text: modelData.name
                    color: Design.textPrimary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }

                Text {
                    x: 158
                    y: root.rowY(index)
                    text: root.rowDesc(modelData)
                    color: Design.textSecondary
                    font.family: Design.fontFamily
                    font.styleName: Design.styleRegular
                    font.pixelSize: 14
                }
            }
        }
        }   // 档案列表裁剪区

        // ---------- 登记新患者（施工图 矩形 25 底 + 矩形 24 描边）----------
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

        // 整条都可点：点它交给外层去开「新增患者」弹窗
        MouseArea {
            x: 681
            y: 649
            width: 557
            height: 43
            cursorShape: Qt.PointingHandCursor
            onClicked: root.newPatientRequested()
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
