#include "StatisticsPeriod.h"

#include "ScheduleWeeks.h"

namespace StatisticsPeriod {

bool parseRange(const QString& text, Range* range)
{
    if (text == QLatin1String("day")) *range = Range::Day;
    else if (text == QLatin1String("week")) *range = Range::Week;
    else if (text == QLatin1String("month")) *range = Range::Month;
    else return false;
    return true;
}

Period forAnchor(const QDate& anchor, Range range, int shift, const QDate& logicalToday)
{
    if (!anchor.isValid() || !logicalToday.isValid()) return {};
    Period period;
    // currentStart 是逻辑今日所在周期的起点；三个标志都拿所选起点和它比，不比结束日。
    QDate currentStart = logicalToday;
    switch (range) {
    case Range::Day:
        period.start = anchor.addDays(shift);
        period.end = period.start;
        break;
    case Range::Week:
        // 周一归位与课表周次共用同一实现：周日退回本周一，不推到下一周。
        period.start = ScheduleWeeks::mondayOf(anchor).addDays(qint64(shift) * 7);
        period.end = period.start.addDays(6);
        currentStart = ScheduleWeeks::mondayOf(logicalToday);
        break;
    case Range::Month:
        period.start = QDate(anchor.year(), anchor.month(), 1).addMonths(shift);
        period.end = period.start.addMonths(1).addDays(-1);
        currentStart = QDate(logicalToday.year(), logicalToday.month(), 1);
        break;
    }
    if (!period.isValid()) return {};
    // 月份用 年*12+月 算距离，跨年时「1 月比上月」不会算错；日与周按日历天整除，不用毫秒，夏令时不偏。
    period.comparisonDistance = range == Range::Month
        ? (currentStart.year() - period.start.year()) * 12 + currentStart.month() - period.start.month() + 1
        : int(period.start.daysTo(currentStart) / (range == Range::Week ? 7 : 1)) + 1;
    period.current = period.start == currentStart;
    period.canAdvance = period.start < currentStart;
    return period;
}

} // namespace StatisticsPeriod
