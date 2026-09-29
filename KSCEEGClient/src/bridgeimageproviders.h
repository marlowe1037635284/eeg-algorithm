#ifndef BRIDGEIMAGEPROVIDERS_H
#define BRIDGEIMAGEPROVIDERS_H

#include <QQuickImageProvider>

class AcquisitionBridge;

// 把 C++ 画好的图交给 QML 的 Image 元素。
//
// 为什么波形不留在 QML 的 Canvas 里画：实测一帧要 76~120 ms，其中约 104 ms 花在
// Canvas 上（16 路 × 每列两个点共三万个 lineTo，走的是 JS 侧的软件光栅化），
// 另外约 14 ms 花在把三万个 QVariant 跨语言搬进 JS 数组。GUI 线程因此只能跑到
// 十几帧，表现就是波形一卡一卡。同样的内容用 QPainter 在 C++ 里画是毫秒级 ——
// 参考实现（pybindwithqt）正是这么做的，也正因如此它才顺。
//
// 两个 provider 分开而不是合成一个：刷新节奏不同（波形约 30 FPS，地形图 1.2 秒一次），
// 各持各的锁，互不遮挡。
//
// URL 里的 revision 只用来制造新 URL —— 否则 Image 会按 URL 缓存，图永远不会变。
// provider 的 id 参数本身不用
class WaveformImageProvider : public QQuickImageProvider
{
public:
    explicit WaveformImageProvider(AcquisitionBridge *bridge);

    QImage requestImage(const QString &id, QSize *size, const QSize &requested_size) override;

private:
    // 非拥有：provider 由 QML 引擎持有，bridge 由 main.cpp 持有，
    // 而 main 里 bridge 声明在 engine 之前，析构顺序保证 provider 先用完再轮到 bridge
    AcquisitionBridge *m_bridge = nullptr;
};

class TopoMapImageProvider : public QQuickImageProvider
{
public:
    explicit TopoMapImageProvider(AcquisitionBridge *bridge);

    QImage requestImage(const QString &id, QSize *size, const QSize &requested_size) override;

private:
    AcquisitionBridge *m_bridge = nullptr;
};

#endif // BRIDGEIMAGEPROVIDERS_H
