import QtQuick
import KSCEEGClient

// 设备连接信息浮层。点采集工作台顶栏的设备状态胶囊，贴在胶囊正下方弹出，
// 把当前连着的这台放大器的铭牌信息摊开给人看。
//
// 与其它弹窗不同：它不压暗整屏、也不居中（showBackdrop / showClose 关掉），
// 就是挂在按钮下面的小卡片，点卡片以外的地方收起来。卡片坐标用的是设计画板
// 的绝对坐标，跟 WorkbenchPage 里那枚胶囊（x:1412 y:12 h:27）对齐。
//
// 型号 / 固件 / 序列号 / 共模抑制协议里读不到，作为常量写在这里；采样模式
// 跟设备协商的实时速率走，直接读 Acq.sample_rate()。
Item {
    id: root

    signal dismissed()

    readonly property int cardWidth: 372
    readonly property int cardHeight: 184
    // 两列的落点：左列贴左边距，右列从卡片宽约 46% 处起
    readonly property int leftX: 22
    readonly property int rightX: 172

    DialogFrame {
        title: qsTr("设备连接")
        // 贴在设备状态胶囊正下方（胶囊底边 y=39，留 12px 缝）
        cardX: 1412
        cardY: 51
        cardWidth: root.cardWidth
        cardHeight: root.cardHeight
        // 设计稿里这张浮层是浅灰底（rgb 220），不是白卡
        cardColor: "#DCDCDC"
        // 浮层：不压暗整屏、不画关闭叉，点外面收起
        showBackdrop: false
        showClose: false
        dismissOnBackdrop: true
        onDismissed: root.dismissed()

        // 第一行：型号（深色、略大） + 连接方式
        Text {
            x: root.leftX
            y: 66
            text: qsTr("NeuroLink-6016")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleMedium
            font.pixelSize: 20
        }

        Text {
            x: root.rightX
            y: 70
            text: qsTr("USB 2.0 · 16 通道放大器")
            color: Design.textSecondary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 15
        }

        // 第二行：固件版本 / 序列号
        Text {
            x: root.leftX
            y: 108
            text: qsTr("固件版本： v1.0.0")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: root.rightX
            y: 108
            text: qsTr("序列号:NL-24-1608")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        // 第三行：采样模式取设备当前协商的速率 / 共模抑制
        Text {
            x: root.leftX
            y: 150
            text: qsTr("采样模式： %1 Hz").arg(Acq.sample_rate())
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }

        Text {
            x: root.rightX
            y: 150
            text: qsTr("共模抑制:> 110 dB")
            color: Design.textPrimary
            font.family: Design.fontFamily
            font.styleName: Design.styleRegular
            font.pixelSize: 16
        }
    }
}
