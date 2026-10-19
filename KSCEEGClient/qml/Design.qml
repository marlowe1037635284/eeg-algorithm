pragma Singleton

import QtQuick

// 设计稿（Figma「EEG-KSC」）的公共设计变量。
//
// 这里的所有数值都直接取自设计稿导出的规格文件，不是估出来的：
// 画板 1920×1080，各元素坐标即设计稿坐标。页面统一按 designScale 等比缩放，
// 所以只要这个文件里的数值对了，界面就和设计稿一致。
//
// 颜色注意：设计稿里的半透明色（如面板底的 #d9d9d9 a=0.35）是用 alpha 表达的，
// 落到 QML 就是 Qt.rgba()，直接叠在背景图上，效果与设计稿一致。
QtObject {
    id: design

    // ---------- 画布 ----------
    // 设计稿画板尺寸，也是所有坐标的基准
    readonly property int canvasWidth: 1920
    readonly property int canvasHeight: 1080

    // ---------- 资源 ----------
    // QML 按用途分了子目录，文件里的相对路径不再指向 assets/，
    // 所以统一走这个绝对前缀（模块资源固定在 qrc 的这个位置）。
    readonly property string assetRoot: "qrc:/qt/qml/KSCEEGClient/assets/"

    // 窗口底色。面板底 panelFill 是**半透明**色，屏幕上的实际观感是它叠在这层底色上的
    // 合成结果；截图（grabToImage）只渲染目标子树、画布初始为透明，脱离窗口后就会
    // 透成白底、与程序显示不一致。凡是要独立成像的地方，都得自己把这层底色补上
    readonly property color windowFill: "#eef2f5"

    // ---------- 主色 ----------
    readonly property color primary: "#7092ab"       // 主蓝灰：面板描边、按钮、主色文字
    readonly property color brand: "#ff8d1a"         // 品牌橙：Logo、登录页标题
    readonly property color primarySoft: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.10)   // 按钮/输入框底
    readonly property color sliderThumb: "#fea85d"   // 通道滑块当前档位
    // 「停止采集」按钮的底色。设计稿里它和滑块高亮、警告色是同一个橙，
    // 但语义完全不同，单独给个名字 —— 免得以后调滑块配色时把按钮一起改掉
    readonly property color stopButton: "#fea85d"
    // 波形页当前导联的高亮色（波形本体、通道名、±量程标注共用）。
    // 数值与状态色 bad 恰好相同，但语义无关，各留各的名字 —— 以后调警告色
    // 不该顺手把波形也改掉
    readonly property color waveCurrent: "#d65a5d"

    // ---------- 面板与文字 ----------
    readonly property color panelFill: Qt.rgba(0xd9 / 255, 0xd9 / 255, 0xd9 / 255, 0.35)     // 面板底
    readonly property color panelFillSoft: Qt.rgba(0xc4 / 255, 0xc4 / 255, 0xc4 / 255, 0.17) // 面板内的浅色块
    readonly property color divider: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)       // 分隔线
    // 面板/按钮的描边：设计稿里一律是主色 20% 透明，不是实色 —— 用实色会明显偏重
    readonly property color panelBorder: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.20)
    // 顶栏状态胶囊的描边是主色 50%
    readonly property color pillBorder: Qt.rgba(0x70 / 255, 0x92 / 255, 0xab / 255, 0.50)
    readonly property color textPrimary: "#212121"
    readonly property color textSecondary: "#636363"
    readonly property color textMuted: "#a3a3a3"
    readonly property color textOnDark: "#ffffff"

    // ---------- 状态色 ----------
    // 电极面板共四档，颜色与设计稿图例一致：良好=绿、一般=红、不良=橙、脱落=灰。
    readonly property color good: "#23af6e"
    readonly property color warning: "#fea85d"
    readonly property color bad: "#d65a5d"
    readonly property color badSoft: Qt.rgba(0xd6 / 255, 0x5a / 255, 0x5d / 255, 0.10)  // 危险按钮底
    readonly property color poor: "#da8e20"
    readonly property color offline: "#a3a3a3"

    // 阻抗等级 → 颜色（良好/一般/不良/脱落四档）
    function impedanceColor(level) {
        if (level === "良好")
            return good
        if (level === "一般")
            return bad
        if (level === "不良")
            return poor
        return offline
    }

    // 电极圆点的底色：设计稿里是「浅底色 + 同色描边」，底色比描边淡很多
    function electrodeFill(level) {
        if (level === "良好")
            return "#eaf2ee"
        if (level === "一般")
            return "#f5f0ef"
        if (level === "不良")
            return "#f7f1e6"
        return "#f4f4f4"
    }

    // 未激活电极位置的占位点颜色（浅蓝灰，取自设计稿）
    readonly property color electrodeIdle: "#ccd3dd"

    // 通道档位（4/8/16）下头型图上**激活**的电极名 —— 与 C++ 侧
    // eeg_montage::display_channel_indices 同源：那边给波形定泳道，这边给头型图
    // 定高亮点（8 档 Fp1 Fp2 F3 F4 C3 C4 P3 P4，4 档 F3 F4 P3 P4）。
    // 16 档返回空数组，表示「全部激活」；其余位置在头型图上画成浅灰占位点
    function activeElectrodes(channelCount) {
        if (channelCount === 4)
            return ["F3", "F4", "P3", "P4"]
        if (channelCount === 8)
            return ["Fp1", "Fp2", "F3", "F4", "C3", "C4", "P3", "P4"]
        return []
    }

    // ---------- 字体 ----------
    // 设计稿用「阿里巴巴普惠体 2.0」，随程序打包（加载见 main.cpp）。
    //
    // 关键：这四个字重在 Qt 里会**合并成一个家族** "Alibaba PuHuiTi 2.0"，
    // 只有 55/65/105 的扁平别名能用、而且取到的都是 Regular 字重，85 Bold 更是直接掉到别的字体。
    // 正确取法是「家族名 + font.styleName」，所以这里分别给家族名和各字重的样式名，
    // QML 里写成 font.family: Design.fontFamily + font.styleName: Design.styleMedium。
    readonly property string fontFamily: "Alibaba PuHuiTi 2.0"
    readonly property string styleRegular: "55 Regular"
    readonly property string styleMedium: "65 Medium"
    readonly property string styleBold: "85 Bold"
    readonly property string styleHeavy: "105 Heavy"

    // Logo 设计稿用的是「阿里妈妈书黑体」，本项目没有该字体文件，
    // 用普惠体最重的 105 Heavy 替代，字形接近。
    readonly property string styleLogo: styleHeavy

    // 顶栏头像里的字：设计稿里管理员显示 AD，其它用户取名字首字
    function avatarText(name) {
        if (name === "管理员" || name === "admin")
            return "AD"
        return name && name.length > 0 ? name.substring(0, 1) : "?"
    }

    // 顶栏那枚「电极贴合 N/16 状态」胶囊的文字与状态灯颜色。
    //
    // 扫描结果由调用方传进来而不是自己去读 Acq：Design 是纯数据单例，
    // 拿不到 main.cpp 注入的上下文属性。
    //
    // 规则按产品截图：
    //   全部连接且全部良好            → 16/16 良好，绿灯
    //   全部连接、但只要有一个「一般」  → 16/16 一般，橙灯
    //   全部连接、但只要有一个「不良」  → 16/16 不良，红灯
    //   只要有一个「脱落」            → 已连接数/16，灰灯
    //
    // 注意第一段是**已连接电极数**（良好/一般/不良都算连接），不是良好数；
    // 第二段是最差的那一档。所以「有一个一般」仍然是 16/16，只是灯变橙。
    //
    // 没扫过时**不能**再写设计稿那个 16/16 —— 那是示意值。一打开软件、
    // 一次阻抗都没扫，就顶着「16/16 良好」，用户会以为已经检过了；等真扫出
    // 14/16 反而像是变差了。没结果时统一显示「未扫描」+ 灰灯，与左侧电极
    // 贴合面板的默认态一致。扫过之后必须跟着真实结果走
    function electrodePillState(quality) {
        if (!quality || quality.length === 0)
            return { "text": qsTr("电极贴合  未扫描"), "color": offline }

        var fairCount = 0
        var poorCount = 0
        var detachedCount = 0
        for (var i = 0; i < quality.length; ++i) {
            var level = quality[i].level
            if (level === "脱落")
                ++detachedCount
            else if (level === "不良")
                ++poorCount
            else if (level === "一般")
                ++fairCount
        }

        var total = quality.length
        var connected = total - detachedCount
        var label = "良好"
        var tone = good
        // 取最差档位：脱落优先于不良，不良优先于一般
        if (detachedCount > 0) {
            label = "脱落"
            tone = offline
        } else if (poorCount > 0) {
            label = "不良"
            tone = bad
        } else if (fairCount > 0) {
            label = "一般"
            tone = poor
        }
        return { "text": qsTr("电极贴合  %1/%2 %3").arg(connected).arg(total).arg(label),
                 "color": tone }
    }

    // 只要「N/16 良好」那一段（采集前确认弹窗里那一格用）。
    // 取不到结果时返回空串，由调用方决定显示什么
    function electrodeQualityText(quality) {
        if (!quality || quality.length === 0)
            return ""

        var good = 0
        for (var i = 0; i < quality.length; ++i) {
            if (quality[i].level === "良好")
                ++good
        }
        return qsTr("%1/%2 良好").arg(good).arg(quality.length)
    }

    // ---------- 波形通道 ----------
    // 16 个通道各自的曲线颜色，下标对应通道序号，与 C++ 的
    // eeg_montage::channel_colors() 是同一套色值（两处必须一致）
    readonly property var channelColors: ["#8e44ad", "#c2185b", "#e2582a", "#f0a02e",
                                          "#e8c019", "#ef6f6c", "#96c93d", "#2fa85a",
                                          "#22b8d8", "#16a085", "#3f7bd8", "#2f56c8",
                                          "#6a5acd", "#a05fc0", "#4b3fa0", "#e64980"]
    readonly property var channelNames: ["Fp1", "Fp2", "F3", "F4", "C3", "C4", "P3", "P4"]
}
