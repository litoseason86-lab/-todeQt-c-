#include "LogicalDayService.h"

#include "AppSettings.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QTimer>

LogicalDayService* LogicalDayService::instance()
{
    static LogicalDayService service;
    return &service;
}

LogicalDayService::LogicalDayService(QObject* parent)
    : QObject(parent)
    , m_boundaryTimer(new QTimer(this))
{
    // objectName 是测试观察私有定时器的稳定契约，不暴露测试专用生产 API。
    m_boundaryTimer->setObjectName(QStringLiteral("logicalDayBoundaryTimer"));
    m_boundaryTimer->setSingleShot(true);

    connect(m_boundaryTimer, &QTimer::timeout, this, &LogicalDayService::onInvalidate);
    connect(AppSettings::instance(), &AppSettings::dayStartHourChanged,
            this, &LogicalDayService::onInvalidate);

    // 构造时只排期不发信号；否则从不改设置的应用永远不会跨界刷新。
    scheduleNextBoundary();
}

void LogicalDayService::onInvalidate()
{
    emit changed();
    scheduleNextBoundary();
}

void LogicalDayService::scheduleNextBoundary()
{
    const qint64 delay = LogicalDay::msUntilNextBoundary(
        QDateTime::currentDateTime(), AppSettings::instance()->dayStartHour());
    // 合法日界点的最长间隔是 24 小时，安全落在 QTimer 的 int 范围内。
    m_boundaryTimer->start(static_cast<int>(delay));
}
