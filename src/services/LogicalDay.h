#ifndef LOGICALDAY_H
#define LOGICALDAY_H

#include <QDate>
#include <QDateTime>
#include <QString>
#include <QTime>

// 逻辑日把 dayStartHour 前的凌晨时间归入前一天。全部函数保持纯计算，
// dayStartHour 由 AppSettings 先归一化，避免模型层和 SQL 层读取全局单例。
namespace LogicalDay {

inline QDate dateOf(const QDateTime& timestamp, int dayStartHour)
{
    return timestamp.addSecs(-dayStartHour * 3600).date();
}

inline QDate today(int dayStartHour)
{
    return dateOf(QDateTime::currentDateTime(), dayStartHour);
}

inline qint64 msUntilNextBoundary(const QDateTime& now, int dayStartHour)
{
    QDateTime boundary(now.date(), QTime(dayStartHour, 0));
    if (now >= boundary) {
        boundary = boundary.addDays(1);
    }
    return now.msecsTo(boundary);
}

inline QString sqlShift(int dayStartHour)
{
    return QStringLiteral("-%1 hours").arg(dayStartHour);
}

} // namespace LogicalDay

#endif // LOGICALDAY_H
