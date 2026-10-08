import QtQuick
import KSCEEGClient

// 「数据分析与后处理」· 报告页。
//
// 分节内容（记录信息 / 处理链 / 片段统计 / 频带分布 / 伪差检测 / 质检结果）
// 全部由 C++ 组装成 { title, rows, chips, note } 送来 —— 数值与判断都在算的那一侧
// 定好，页面只负责排版。让 QML 再算一遍（比如自己去挑主导节律）就会出现
//「报告页说 θ、统计页说 α」这种自相矛盾
Item {
    id: root

    // 「下载TXT报告」按钮在标题行右侧
    signal downloadRequested()

    Text {
        x: 0
        y: 0
        text: qsTr("分析报告")
        color: Design.textPrimary
        font.family: Design.fontFamily
        font.styleName: Design.styleMedium
        font.pixelSize: 17
    }

    Rectangle {
        id: downloadButton

        anchors.right: parent.right
        y: -4
        width: 118
        height: 30
        radius: 8
        color: downloadMouse.pressed ? Qt.rgba(0.44, 0.57, 0.67, 0.22) : Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder

        Text {
            anchors.centerIn: parent
            text: qsTr("下载TXT报告")
            color: Design.primary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 14
        }

        MouseArea {
            id: downloadMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.downloadRequested()
        }
    }

    Flickable {
        x: 0
        y: 38
        width: parent.width
        height: parent.height - 38
        contentWidth: width
        contentHeight: sections.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: sections

            width: parent.width
            spacing: 12

            Repeater {
                model: Analysis.reportSections

                delegate: Rectangle {
                    id: card

                    required property var modelData

                    width: sections.width
                    height: body.implicitHeight + 32
                    radius: 10
                    color: Design.panelFillSoft

                    Column {
                        id: body

                        x: 20
                        y: 16
                        width: parent.width - 40
                        spacing: 12

                        Text {
                            text: card.modelData.title !== undefined ? card.modelData.title : ""
                            color: Design.textPrimary
                            font.family: Design.fontFamily
                            font.styleName: Design.styleMedium
                            font.pixelSize: 16
                        }

                        // 键值行：三列铺开，标签在上、值在下（与设计稿同）
                        Grid {
                            id: rowsGrid

                            columns: 3
                            spacing: 8
                            visible: rowsRepeater.count > 0

                            readonly property real cellWidth: (body.width - spacing * 2) / 3

                            Repeater {
                                id: rowsRepeater

                                model: card.modelData.rows !== undefined
                                       ? card.modelData.rows : []

                                delegate: Item {
                                    required property var modelData

                                    // 用 id 而不是 parent：delegate 会被挂到 Repeater 的
                                    // 父项上，parent 在静态分析里指向 Repeater，
                                    // 从它身上读自定义属性拿不到值
                                    width: rowsGrid.cellWidth
                                    height: 42

                                    Text {
                                        x: 0
                                        y: 0
                                        text: modelData.label
                                        color: Design.textSecondary
                                        font.family: Design.fontFamily
                                        font.styleName: Design.styleRegular
                                        font.pixelSize: 14
                                    }

                                    Text {
                                        x: 0
                                        y: 20
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: modelData.value
                                        color: Design.textPrimary
                                        font.family: Design.fontFamily
                                        font.styleName: Design.styleMedium
                                        font.pixelSize: 15
                                    }
                                }
                            }
                        }

                        // 胶囊行：处理链的每一步、各频带的占比
                        Flow {
                            width: body.width
                            spacing: 10
                            visible: chipsRepeater.count > 0

                            Repeater {
                                id: chipsRepeater

                                model: card.modelData.chips !== undefined
                                       ? card.modelData.chips : []

                                delegate: Rectangle {
                                    required property var modelData

                                    readonly property color accent:
                                        modelData.color !== undefined
                                        && String(modelData.color).length > 0
                                        ? modelData.color : Design.primary

                                    width: chipLabel.implicitWidth + 26
                                    height: 30
                                    radius: 8
                                    color: Qt.rgba(accent.r, accent.g, accent.b, 0.16)

                                    Text {
                                        id: chipLabel
                                        anchors.centerIn: parent
                                        text: modelData.text
                                        // 频带胶囊的文字里有 δ θ α β γ，走带兜底的字体链
                                                            color: parent.accent
                                        font.family: Design.fontFamily
                                        font.styleName: Design.styleRegular
                                        font.pixelSize: 14
                                    }
                                }
                            }
                        }

                        Text {
                            width: body.width
                            visible: text.length > 0
                            text: card.modelData.note !== undefined ? card.modelData.note : ""
                            wrapMode: Text.WordWrap
                            color: Design.textSecondary
                            font.family: Design.fontFamily
                            font.styleName: Design.styleRegular
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 300
        visible: Analysis.reportSections.length === 0
        text: Analysis.busy ? qsTr("正在计算…") : qsTr("没有可显示的报告")
        color: Design.textMuted
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }
}
