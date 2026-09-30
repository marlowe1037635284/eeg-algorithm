#pragma once

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// 「采集记录预览」弹窗右上角那个「导出PDF」按钮干的事：把一条记录排成一份 A4 报告。
//
// 为什么不是把界面上那一屏截下来：预览弹窗只显示 5 秒窗口，而报告要的是**整段
// 记录的总览**，再加上患者信息、参数与事件标注 —— 这些在预览界面上根本不全。
// 截屏得到的是一张「像报告的东西」，缺什么、错什么全看不出来。
//
// 波形不自己重画一遍，而是复用 RecordingPreview：记录的读取、去直流、定标、
// 抽稀那套逻辑只留一份，报告与界面上的波形必然一致。
//
// 只在导出时用得到，不需要常驻在 QML 里，所以走 QML_ELEMENT 由 QML 自行实例化
// （与 AppDatabase 同款），C++ 侧不用在 main.cpp 注册
class RecordReport : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit RecordReport(QObject *parent = nullptr);

    // 把一条采集记录写成 PDF，放到 directory 下。session / events 直接取
    // AppDatabase::session() / sessionEvents() 的返回值（都是 QVariantMap/List，
    // 结构见 appdatabase.h 的注释）
    //
    // 返回 { success, message, path }。失败时 message 说明原因，path 为空
    Q_INVOKABLE QVariantMap exportPdf(const QVariantMap &session, const QVariantList &events,
                                      const QString &directory) const;
};
