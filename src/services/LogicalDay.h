#ifndef LOGICALDAY_H
#define LOGICALDAY_H

#include <QDate>
#include <QDateTime>
#include <QString>
#include <QTime>
#include <QTimeZone>

// 逻辑日把 dayStartHour 前的凌晨时间归入前一天。全部函数保持纯计算，
// dayStartHour 由 AppSettings 先归一化，避免模型层和 SQL 层读取全局单例。
namespace LogicalDay {

inline QDate dateOf(const QDateTime& timestamp, int dayStartHour)
{
    const QTime boundaryTime(dayStartHour, 0);
    return timestamp.time() < boundaryTime ? timestamp.date().addDays(-1) : timestamp.date();
}

inline QDate today(int dayStartHour)
{
    return dateOf(QDateTime::currentDateTime(), dayStartHour);
}

inline qint64 msUntilNextBoundary(const QDateTime& now, int dayStartHour)
{
    const QDate boundaryDate = now.time() < QTime(dayStartHour, 0)
        ? now.date() : now.date().addDays(1);
    // 使用调用方时区构造本地墙钟边界；DST 跳变交给 QDateTime 的时区转换规则处理。
    const QDateTime boundary(boundaryDate, QTime(dayStartHour, 0), now.timeZone(),
                             QDateTime::TransitionResolution::RelativeToBefore);
    return now.msecsTo(boundary);
}

inline QString sqlShift(int dayStartHour)
{
    return QStringLiteral("-%1 hours").arg(dayStartHour);
}

} // namespace LogicalDay

#endif // LOGICALDAY_H
