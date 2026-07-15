#include "LogicalDayService.h"

#include "AppSettings.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QCoreApplication>
#include <QEvent>
#include <QTimeZone>
#include <QTimer>

#include <algorithm>
#include <limits>

LogicalDayService* LogicalDayService::instance()
{
    static LogicalDayService service;
    return &service;
}

LogicalDayService::LogicalDayService(QObject* parent)
    : QObject(parent)
    , m_boundaryTimer(new QTimer(this))
    , m_clockWatchdog(new QTimer(this))
{
    // objectName 是测试观察私有定时器的稳定契约，不暴露测试专用生产 API。
    m_boundaryTimer->setObjectName(QStringLiteral("logicalDayBoundaryTimer"));
    m_boundaryTimer->setSingleShot(true);

    connect(m_boundaryTimer, &QTimer::timeout, this, &LogicalDayService::onInvalidate);
    connect(AppSettings::instance(), &AppSettings::dayStartHourChanged,
            this, &LogicalDayService::onInvalidate);

    m_clockWatchdog->setObjectName(QStringLiteral("logicalDayClockWatchdog"));
    m_clockWatchdog->setInterval(60000);
    m_clockWatchdog->setTimerType(Qt::VeryCoarseTimer);
    connect(m_clockWatchdog, &QTimer::timeout, this, &LogicalDayService::checkSystemClock);
    m_clockWatchdog->start();

    if (QCoreApplication::instance()) {
        QCoreApplication::instance()->installEventFilter(this);
    }

    // 构造时只排期不发信号；否则从不改设置的应用永远不会跨界刷新。
    m_lastLogicalDate = LogicalDay::today(AppSettings::instance()->dayStartHour());
    m_lastTimeZoneId = QTimeZone::systemTimeZoneId();
    scheduleNextBoundary();
}

bool LogicalDayService::eventFilter(QObject* watched, QEvent* event)
{
    Q_UNUSED(watched)
    if (event && event->type() == QEvent::ApplicationStateChange) {
        // 从休眠或后台回到前台时系统会派发状态变化；无论进入还是离开都重算一次成本很低。
        checkSystemClock();
    }
    return false;
}

void LogicalDayService::onInvalidate()
{
    m_lastLogicalDate = LogicalDay::today(AppSettings::instance()->dayStartHour());
    m_lastTimeZoneId = QTimeZone::systemTimeZoneId();
    emit changed();
    scheduleNextBoundary();
}

void LogicalDayService::checkSystemClock()
{
    const QDate logicalDate = LogicalDay::today(AppSettings::instance()->dayStartHour());
    const QByteArray timeZoneId = QTimeZone::systemTimeZoneId();
    const bool logicalContextChanged = logicalDate != m_lastLogicalDate
        || timeZoneId != m_lastTimeZoneId;

    m_lastLogicalDate = logicalDate;
    m_lastTimeZoneId = timeZoneId;
    // 即使逻辑日没变，也重排日界计时器，用来纠正用户手工改系统时间造成的旧延迟。
    scheduleNextBoundary();
    if (logicalContextChanged) {
        emit changed();
    }
}

void LogicalDayService::scheduleNextBoundary()
{
    const qint64 delay = LogicalDay::msUntilNextBoundary(
        QDateTime::currentDateTime(), AppSettings::instance()->dayStartHour());
    // 系统时钟跳变、无效时区边界或平台差异都可能让纯计算结果越界。
    // 至少 1ms 可避免 0/负间隔形成忙循环，上限使用 QTimer 能接收的 int 范围。
    const qint64 safeDelay = std::clamp(
        delay, qint64(1), qint64((std::numeric_limits<int>::max)()));
    m_boundaryTimer->start(static_cast<int>(safeDelay));
}
