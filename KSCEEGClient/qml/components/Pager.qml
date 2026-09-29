import QtQuick
import KSCEEGClient

// 列表页底部的分页条（患者管理 / 历史记录 / 用户管理三页共用）。
//
// 设计稿里这一段是「共 N 条记录（当前显示 M 条）」+ 上一页 / 1/1 / 下一页，
// 原来三页都把它写成了静态文字、按钮没有点击区 —— 页脚说「共 6 条」，
// 而表格里其实只画了 6 行硬编码数据，翻页也无从谈起。
//
// 用法：调用方自己持有 currentPage，按 firstIndex/pageSize 给列表切片；
// 页码越界由调用方在过滤条件变化时重置（改搜索词后回到第 1 页）。
Item {
    id: root

    // 过滤**前**的总条数（页脚第一句）
    property int totalCount: 0
    // 过滤**后**的条数（「当前显示 M 条」）。没有搜索/筛选时等于 totalCount
    property int filteredCount: 0
    property int pageSize: 15
    property int currentPage: 1

    // 页脚文案里「N 条记录」量的是什么。设计稿三页都写「条记录」，
    // 只有历史记录页量的是记录数
    property string countUnit: qsTr("条记录")

    readonly property int pageCount:
        Math.max(1, Math.ceil(Math.max(0, filteredCount) / Math.max(1, pageSize)))
    // 本页第一条在过滤结果里的下标，列表按它切片
    readonly property int firstIndex: (currentPage - 1) * pageSize
    // 过滤结果为空时显示 0 而不是负数
    readonly property int visibleCount:
        Math.max(0, Math.min(pageSize, filteredCount - firstIndex))
    readonly property bool canPrev: currentPage > 1
    readonly property bool canNext: currentPage < pageCount

    signal pageRequested(int page)

    function goTo(page) {
        const target = Math.max(1, Math.min(pageCount, page))
        if (target !== currentPage)
            root.pageRequested(target)
    }

    implicitWidth: 1702
    implicitHeight: 34

    // 共 N 条记录（当前显示 M 条）
    Text {
        x: 19
        y: 1
        text: qsTr("共 %1 %2（当前显示 %3 条）")
              .arg(root.totalCount).arg(root.countUnit).arg(root.filteredCount)
        color: Design.textSecondary
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    PagerButton {
        x: 1531
        text: qsTr("上一页")
        enabled: root.canPrev
        onClicked: root.goTo(root.currentPage - 1)
    }

    Text {
        x: 1596
        y: 4
        text: root.currentPage + "/" + root.pageCount
        color: "#000000"
        font.family: Design.fontFamily
        font.styleName: Design.styleRegular
        font.pixelSize: 14
    }

    PagerButton {
        x: 1631
        text: qsTr("下一页")
        enabled: root.canNext
        onClicked: root.goTo(root.currentPage + 1)
    }

    // 上一页 / 下一页：53×29、圆角 6，与设计稿一致。
    // 到头时压暗并去掉点击，否则点了没反应也看不出是「已经到头了」
    component PagerButton: Rectangle {
        id: pagerButton

        property string text: ""
        signal clicked()

        y: -4            // 按钮顶边在设计稿里比这一段文字基线高 4
        width: 53
        height: 29
        radius: 6
        color: Design.primarySoft
        border.width: 1
        border.color: Design.panelBorder
        opacity: enabled ? 1.0 : 0.45

        Text {
            anchors.centerIn: parent
            text: pagerButton.text
            color: "#3b3b3b"
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 14
        }

        MouseArea {
            anchors.fill: parent
            enabled: pagerButton.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pagerButton.clicked()
        }
    }
}
