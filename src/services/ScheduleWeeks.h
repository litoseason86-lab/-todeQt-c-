#pragma once

#include <QDate>
#include <QString>

// 课表的自然星期与学期周次，学期锚点显式传入，不读取设置或逻辑日。
namespace ScheduleWeeks {
QDate mondayOf(const QDate& date);
QDate parseSemesterStart(const QString& isoText);
int weekIndexForDate(const QString& semesterStartIso, const QDate& date);
QDate mondayOfWeek(const QString& semesterStartIso, int weekIndex);
QDate dateOfWeekday(const QString& semesterStartIso, int weekIndex, int weekday);
bool overlaps(double aStart, double aEnd, double bStart, double bEnd);
}
