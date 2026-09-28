import QtQuick
import KSCEEGClient

// 设计稿里那两个大椭圆装饰（圆形 9 / 圆形 10）都带 272px 的高斯模糊：
// 中心浓、往外柔和淡出。直接画实心椭圆会变成一块硬边「色板」，所以这里做近似。
//
// 做法：真做大半径模糊（MultiEffect blurMax≈272）每帧开销太大，
// 改成「同心椭圆叠加」——把模糊当成把核心椭圆往外扩 272px，
// 于是每一层就是「核心 + 2r」的椭圆；各层用很小的 alpha 叠起来，
// 中心叠满等于目标浓度，越往外被覆盖的层越少、自然淡出。
Item {
    id: blob

    property color tint: "#7092ab"
    property real peakAlpha: 0.19
    // 未模糊时的椭圆尺寸与模糊半径（都取自设计稿）
    property real coreWidth: 1247
    property real coreHeight: 280
    property real blurRadius: 272

    readonly property int layers: 12
    // 每层用这个 alpha，叠满 layers 层正好等于 peakAlpha
    readonly property real layerAlpha: 1 - Math.pow(1 - peakAlpha, 1 / layers)

    width: coreWidth + 2 * blurRadius
    height: coreHeight + 2 * blurRadius

    Repeater {
        model: blob.layers

        delegate: Rectangle {
            required property int index

            readonly property real spread: blob.blurRadius * (1 - index / blob.layers)
            width: blob.coreWidth + 2 * spread
            height: blob.coreHeight + 2 * spread
            x: (blob.width - width) / 2
            y: (blob.height - height) / 2
            radius: height / 2
            color: Qt.rgba(blob.tint.r, blob.tint.g, blob.tint.b, blob.layerAlpha)
        }
    }
}
