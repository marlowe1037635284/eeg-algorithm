import QtQuick
import KSCEEGClient

// 「数据分析与后处理」· 通道页。
//
// 一张 16 行的统计表。数值全部由 C++ 算好并**格式化成字符串**再送过来
// （见 PostProcess::compute 的第 9 步）—— 表格里的列宽是按定长小数设计的，
// 交给 QML 去 toFixed 只会让每列的小数位随数据漂移
Item {
    id: root

    readonly property int headerHeight: 46
    readonly property int rowHeight: 45
    // 表头起点。**必须让开右上角那个「导出统计CSV」按钮**（它在内容区 y=74 起、
    // 高 30），否则第一行数据会和按钮叠在一起
    readonly property int tableTop: 54

    // 列位置按宽度比例给。设计稿里的列是从左往右排的固定坐标，
    // 但那一版没考虑「优势频带」比其它列宽，末列会顶到边框上
    readonly property var columns: [
        { key: "name",      ratio: 0.04, label: qsTr("通道") },
        { key: "mean",      ratio: 0.16, label: qsTr("均值μV") },
        { key: "std",       ratio: 0.26, label: qsTr("标准差") },
        { key: "rms",       ratio: 0.35, label: qsTr("RMS") },
        { key: "peak",      ratio: 0.44, label: qsTr("峰值μV") },
        { key: "min",       ratio: 0.55, label: qsTr("最小") },
        { key: "max",       ratio: 0.63, label: qsTr("最大") },
        { key: "zeroCross", ratio: 0.71, label: qsTr("零交叉/s") },
        { key: "skewness",  ratio: 0.80, label: qsTr("偏度") },
        { key: "kurtosis",  ratio: 0.87, label: qsTr("峰度") },
        { key: "band",      ratio: 0.94, label: qsTr("优势频带") }
    ]

    Rectangle {
        x: 0
        y: root.tableTop
        width: parent.width
        height: root.headerHeight
        color: Design.primarySoft

        Repeater {
            model: root.columns

            delegate: Text {
                required property var modelData

                x: root.width * modelData.ratio
                y: 0
                height: root.headerHeight
                verticalAlignment: Text.AlignVCenter
                text: modelData.label
                color: Design.textPrimary
                font.family: Design.fontFamily
                font.styleName: Design.styleRegular
                font.pixelSize: 15
            }
        }
    }

    Flickable {
        x: 0
        y: root.tableTop + root.headerHeight
        width: parent.width
        height: parent.height - root.tableTop - root.headerHeight
        contentWidth: width
        contentHeight: Analysis.channelStats.length * root.rowHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Repeater {
            model: Analysis.channelStats

            delegate: Item {
                id: rowDelegate

                required property var modelData
                required property int index

                // 内层 Repeater 的 modelData 是「哪一列」，外层的在它里面会被遮住。
                // 存成另一个名字，内层按 id 取，两层的 modelData 才不会打架
                readonly property var rowData: modelData

                width: root.width
                height: root.rowHeight
                y: index * root.rowHeight

                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: (index % 2) === 0
                }

                // 通道名用该路的配色，与波形、地形图是同一套颜色 ——
                // 表格里第一个也要能一眼对上是哪一路
                Text {
                    x: root.width * 0.04
                    y: 0
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: rowDelegate.rowData.name
                    color: rowDelegate.rowData.color
                    font.family: Design.fontFamily
                    font.styleName: Design.styleMedium
                    font.pixelSize: 15
                }

                Repeater {
                    model: root.columns.slice(1)

                    delegate: Text {
                        required property var modelData

                        readonly property var cell:
                            rowDelegate.rowData[modelData.key]

                        x: root.width * modelData.ratio
                        y: 0
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        text: cell === undefined ? "—" : cell
                        // 「优势频带」那一列是「δ Delta」这种写法，需希腊字母兜底
                            color: Design.textSecondary
                        font.family: Design.fontFamily
                        font.styleName: Design.styleRegular
                        font.pixelSize: 15
                    }
                }

                Rectangle {
                    y: parent.height - 1
                    width: parent.width
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.08)
                }
            }
        }
    }

    // 空态：还没算出结果时说明白，而不是留一片空白
    Text {
        x: 0
        y: root.tableTop
        width: parent.width
        height: parent.height - root.tableTop
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        visible: Analysis.channelStats.length === 0
        text: Analysis.busy ? qsTr("正在计算…") : qsTr("没有可显示的通道统计")
        color: Design.textMuted
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 15
    }
}
