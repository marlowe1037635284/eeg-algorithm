#include "bridge/bridgeimageproviders.h"

#include "bridge/acquisitionbridge.h"

WaveformImageProvider::WaveformImageProvider(AcquisitionBridge *bridge)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_bridge(bridge)
{
}

QImage WaveformImageProvider::requestImage(const QString &id, QSize *size,
                                           const QSize &requested_size)
{
    Q_UNUSED(id);
    Q_UNUSED(requested_size);

    // 返回深拷贝：Qt 不保证 provider 在哪个线程被调用，
    // 把内部那张图的引用交出去，就可能在另一个线程里被改写
    const QImage image = m_bridge != nullptr ? m_bridge->current_wave_image() : QImage();
    if (size != nullptr)
    {
        *size = image.size();
    }
    return image;
}

TopoMapImageProvider::TopoMapImageProvider(AcquisitionBridge *bridge)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_bridge(bridge)
{
}

QImage TopoMapImageProvider::requestImage(const QString &id, QSize *size,
                                          const QSize &requested_size)
{
    Q_UNUSED(id);
    Q_UNUSED(requested_size);

    const QImage image = m_bridge != nullptr ? m_bridge->current_topo_image() : QImage();
    if (size != nullptr)
    {
        *size = image.size();
    }
    return image;
}
