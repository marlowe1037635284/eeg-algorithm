#ifndef TOPOMAPIMAGEPROVIDER_H
#define TOPOMAPIMAGEPROVIDER_H

#include <QQuickImageProvider>

class AcquisitionBridge;

// 把当前这帧脑电地形图交给 QML 的 Image 元素（source: "image://topography/render/<revision>"）。
//
// 为什么走 image provider 而不是把网格数据丢给 QML 自己画：
// 把 64×64 的 float 变成 256×256 的带透明度热力图，是每帧一次的色彩映射与
// 逐像素写入，交给 QML 的 Canvas 做要慢一个量级，而且色标还得多处维护一份。
//
// URL 里的 revision 只用来制造新 URL —— 否则 Image 会按 URL 缓存，图永远不会变。
// provider 的 id 参数本身不用
class TopoMapImageProvider : public QQuickImageProvider
{
public:
    explicit TopoMapImageProvider(AcquisitionBridge *bridge);

    QImage requestImage(const QString &id, QSize *size, const QSize &requested_size) override;

private:
    // 非拥有：provider 由 QML 引擎持有，bridge 由 main.cpp 持有，
    // 而 main 里 bridge 声明在 engine 之前，析构顺序保证 provider 先用完再轮到 bridge
    AcquisitionBridge *m_bridge = nullptr;
};

#endif // TOPOMAPIMAGEPROVIDER_H
