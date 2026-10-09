#include "ScheduleWeeks.h"

#include <QRegularExpression>

namespace ScheduleWeeks {
QDate mondayOf(const QDate& date)
{
    // 周日回退六天，不能落到下一周；无效日期保持无效。
    return date.isValid() ? date.addDays(1 - date.dayOfWeek()) : QDate();
}

QDate parseSemesterStart(const QString& isoText)
{
    static const QRegularExpression pattern(QStringLiteral("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"));
    const QString text = isoText.trimmed();
    if (!pattern.match(text).hasMatch()) return {};
    const QDate date = QDate::fromString(text, Qt::ISODate);
    // 旧 JS 的年份构造把 0..99 当成 1900..1999，回读校验会拒绝；迁移保持该边界。
    return date.year() >= 100 ? mondayOf(date) : QDate();
}

int weekIndexForDate(const QString& semesterStartIso, const QDate& date)
{
    const QDate start = parseSemesterStart(semesterStartIso);
    const QDate target = mondayOf(date);
    if (!start.isValid() || !target.isValid()) return 0;
    // 两端都是周一，日历天差必为七的倍数；不以毫秒相减，夏令时不会偏移周次。
    return static_cast<int>(start.daysTo(target) / 7) + 1;
}

QDate mondayOfWeek(const QString& semesterStartIso, int weekIndex)
{
    // 先扩大整数再相减，避免极端周次溢出；零与负周次允许查询学期之前。
    return parseSemesterStart(semesterStartIso).addDays((qint64(weekIndex) - 1) * 7);
}

QDate dateOfWeekday(const QString& semesterStartIso, int weekIndex, int weekday)
{
    return mondayOfWeek(semesterStartIso, weekIndex).addDays(qint64(weekday) - 1);
}

bool overlaps(double aStart, double aEnd, double bStart, double bEnd)
{
    // 半开区间在课表里表示占用时间，结束点等于另一段开始点时不相交。
    return aStart < bEnd && aEnd > bStart;
}
}
