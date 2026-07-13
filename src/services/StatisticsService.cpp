#include "StatisticsService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDebug>
#include <QDateTime>
#include <QtMath>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

namespace {
void reportStatisticsFailure(const QString& detail)
{
    emit StatisticsService::instance()->operationFailed(
        detail.isEmpty() ? QStringLiteral("统计数据加载失败")
                         : QStringLiteral("统计数据加载失败: %1").arg(detail));
}

QVariantMap noComparisonData()
{
    QVariantMap result;
    result.insert(QStringLiteral("hasData"), false);
    result.insert(QStringLiteral("currentValue"), 0);
    result.insert(QStringLiteral("previousValue"), 0);
    result.insert(QStringLiteral("changePercent"), 0);
    result.insert(QStringLiteral("trend"), 0);
    result.insert(QStringLiteral("displayText"), QString());
    return result;
}

QDate normalizeDate(const QVariant& value)
{
    // 公共 API 兼容 QML Date、ISO 字符串和 C++ QDate 调用。
    if (value.canConvert<QDate>()) {
        const QDate date = value.toDate();
        if (date.isValid()) {
            return date;
        }
    }

    if (value.canConvert<QDateTime>()) {
        const QDateTime dateTime = value.toDateTime();
        if (dateTime.isValid()) {
            return dateTime.date();
        }
    }

    const QString text = value.toString().trimmed();
    if (!text.isEmpty()) {
        const QDate isoDate = QDate::fromString(text, Qt::ISODate);
        if (isoDate.isValid()) {
            return isoDate;
        }

        const QDateTime isoDateTime = QDateTime::fromString(text, Qt::ISODate);
        if (isoDateTime.isValid()) {
            return isoDateTime.date();
        }
    }

    return QDate();
}

QVariantMap emptyCategoryStats()
{
    QVariantMap result;
    result.insert(QStringLiteral("categories"), QVariantList());
    result.insert(QStringLiteral("totalDuration"), 0);
    return result;
}

QVariantMap emptyDayStats()
{
    QVariantMap result;
    result.insert(QStringLiteral("totalDuration"), 0);
    result.insert(QStringLiteral("completedTasks"), 0);
    result.insert(QStringLiteral("totalTasks"), 0);
    result.insert(QStringLiteral("completionRate"), 0.0);
    result.insert(QStringLiteral("sessionCount"), 0);
    return result;
}

QVariantMap emptyMonthStats()
{
    QVariantMap result;
    result.insert(QStringLiteral("totalDuration"), 0);
    result.insert(QStringLiteral("effectiveDays"), 0);
    result.insert(QStringLiteral("sessionCount"), 0);
    result.insert(QStringLiteral("completedTasks"), 0);
    result.insert(QStringLiteral("totalTasks"), 0);
    return result;
}

bool isValidStatsYearMonth(int year, int month, const QString& context)
{
    // 统计页的年月来自 QML 状态；限制业务年份可以把明显传错的值挡在 SQL 查询前。
    if (year < 2000 || year > 2100) {
        qWarning() << context << "invalid year:" << year;
        return false;
    }

    if (month < 1 || month > 12) {
        qWarning() << context << "invalid month:" << month;
        return false;
    }

    return true;
}

int queryTotalDurationForRange(const QDate& startDate, const QDate& endDate, const QString& context)
{
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to calculate total duration:" << context << "invalid date range";
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to calculate total duration:" << context << "database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COALESCE(SUM(duration), 0) FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to calculate total duration:" << context << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    return query.value(0).toInt();
}
}

StatisticsService::StatisticsService(QObject* parent)
    : QObject(parent)
{
}

StatisticsService* StatisticsService::instance()
{
    static StatisticsService service;
    return &service;
}

QVariantMap StatisticsService::getDayStats(const QDate& date) const
{
    QVariantMap stats = emptyDayStats();
    if (!date.isValid()) {
        qWarning() << "Failed to get day stats: invalid date" << date;
        return stats;
    }

    const int totalDuration = calculateTotalDuration(date);
    const int completedTasks = countCompletedTasks(date);
    const int totalTasks = countTotalTasks(date);

    stats.insert(QStringLiteral("totalDuration"), totalDuration);
    stats.insert(QStringLiteral("completedTasks"), completedTasks);
    stats.insert(QStringLiteral("totalTasks"), totalTasks);
    stats.insert(QStringLiteral("completionRate"), totalTasks > 0 ? static_cast<double>(completedTasks) / totalTasks : 0.0);
    stats.insert(QStringLiteral("sessionCount"), getFocusSessionCount(date, date));
    return stats;
}

QVariantMap StatisticsService::getTodayStats() const
{
    return getDayStats(LogicalDay::today(AppSettings::instance()->dayStartHour()));
}

QVariantMap StatisticsService::buildComparisonResult(int currentValue, int previousValue, const QString& label) const
{
    if (currentValue == 0 && previousValue == 0) {
        return noComparisonData();
    }

    QVariantMap result;
    result.insert(QStringLiteral("currentValue"), currentValue);
    result.insert(QStringLiteral("previousValue"), previousValue);
    result.insert(QStringLiteral("hasData"), true);

    // 前一周期为 0 时不能计算百分比；这里单独区分首次记录和两个周期都无数据。
    if (previousValue == 0) {
        result.insert(QStringLiteral("changePercent"), 0);
        result.insert(QStringLiteral("trend"), currentValue > 0 ? 1 : 0);
        result.insert(QStringLiteral("displayText"),
                      currentValue > 0 ? QStringLiteral("首次记录")
                                       : QStringLiteral("→ 0% vs %1").arg(label));
        return result;
    }

    const double changeRatio = static_cast<double>(currentValue - previousValue) / previousValue;
    const int changePercent = qRound(changeRatio * 100.0);

    result.insert(QStringLiteral("changePercent"), changePercent);
    result.insert(QStringLiteral("trend"), changePercent > 0 ? 1 : (changePercent < 0 ? -1 : 0));

    const QString arrow = changePercent > 0 ? QStringLiteral("↗")
                           : changePercent < 0 ? QStringLiteral("↘")
                                               : QStringLiteral("→");
    const QString sign = changePercent > 0 ? QStringLiteral("+") : QString();
    result.insert(QStringLiteral("displayText"),
                  QStringLiteral("%1 %2%3% vs %4")
                      .arg(arrow)
                      .arg(sign)
                      .arg(changePercent)
                      .arg(label));
    return result;
}

QVariantList StatisticsService::getWeekStats(const QDate& weekStart) const
{
    QVariantList weekStats;
    if (!weekStart.isValid()) {
        qWarning() << "Failed to get week stats: invalid weekStart date" << weekStart;
        return weekStats;
    }

    if (weekStart.dayOfWeek() != Qt::Monday) {
        qWarning() << "Failed to get week stats: weekStart is not Monday" << weekStart;
        return weekStats;
    }

    for (int offset = 0; offset < 7; ++offset) {
        const QDate date = weekStart.addDays(offset);
        QVariantMap dayStats;
        dayStats.insert(QStringLiteral("date"), date);
        dayStats.insert(QStringLiteral("duration"), calculateTotalDuration(date));
        dayStats.insert(QStringLiteral("tasks"), countTotalTasks(date));
        dayStats.insert(QStringLiteral("completedTasks"), countCompletedTasks(date));
        weekStats.append(dayStats);
    }

    return weekStats;
}

QVariantList StatisticsService::getWeekStats() const
{
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return getWeekStats(today.addDays(1 - today.dayOfWeek()));
}

QVariantMap StatisticsService::getDayComparison(const QDate& date) const
{
    if (!date.isValid()) {
        QVariantMap result;
        result.insert(QStringLiteral("hasData"), false);
        result.insert(QStringLiteral("duration"), noComparisonData());
        result.insert(QStringLiteral("sessionCount"), noComparisonData());
        result.insert(QStringLiteral("taskCompletion"), noComparisonData());
        return result;
    }

    const QDate previousDate = date.addDays(-1);

    QVariantMap result;
    result.insert(QStringLiteral("duration"),
                  buildComparisonResult(calculateTotalDuration(date),
                                        calculateTotalDuration(previousDate),
                                        QStringLiteral("昨天")));
    result.insert(QStringLiteral("sessionCount"),
                  buildComparisonResult(getFocusSessionCount(date, date),
                                        getFocusSessionCount(previousDate, previousDate),
                                        QStringLiteral("昨天")));
    result.insert(QStringLiteral("taskCompletion"),
                  buildComparisonResult(countCompletedTasks(date),
                                        countCompletedTasks(previousDate),
                                        QStringLiteral("昨天")));
    return result;
}

QVariantMap StatisticsService::getWeekComparison(const QDate& weekStart) const
{
    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday) {
        QVariantMap result;
        result.insert(QStringLiteral("hasData"), false);
        return result;
    }

    int currentDuration = 0;
    int previousDuration = 0;
    for (int offset = 0; offset < 7; ++offset) {
        currentDuration += calculateTotalDuration(weekStart.addDays(offset));
        previousDuration += calculateTotalDuration(weekStart.addDays(offset - 7));
    }

    const QDate weekEnd = weekStart.addDays(6);
    const QDate previousWeekStart = weekStart.addDays(-7);
    const QDate previousWeekEnd = weekStart.addDays(-1);

    QVariantMap result;
    result.insert(QStringLiteral("duration"),
                  buildComparisonResult(currentDuration, previousDuration, QStringLiteral("上周")));
    result.insert(QStringLiteral("effectiveDays"),
                  buildComparisonResult(getEffectiveDays(weekStart, weekEnd),
                                        getEffectiveDays(previousWeekStart, previousWeekEnd),
                                        QStringLiteral("上周")));
    result.insert(QStringLiteral("sessionCount"),
                  buildComparisonResult(getFocusSessionCount(weekStart, weekEnd),
                                        getFocusSessionCount(previousWeekStart, previousWeekEnd),
                                        QStringLiteral("上周")));
    return result;
}

QVariantMap StatisticsService::getCategoryStats(const QVariant& startDateValue, const QVariant& endDateValue) const
{
    const QDate startDate = normalizeDate(startDateValue);
    const QDate endDate = normalizeDate(endDateValue);
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to get category stats: invalid date range";
        return emptyCategoryStats();
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get category stats: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return emptyCategoryStats();
    }

    // 优先使用标准化科目，其次使用迁移出的旧科目，最后回退到任务旧文本。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT "
        "COALESCE(NULLIF(c.name, ''), NULLIF(legacy.name, ''), NULLIF(t.category, '')) AS category_name, "
        "COALESCE(NULLIF(c.color, ''), NULLIF(legacy.color, ''), '#d4a574') AS category_color, "
        "SUM(f.duration) AS total_duration "
        "FROM focus_sessions f "
        "JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
        "WHERE date(f.start_time, :dayShift) >= :startDate "
        "AND date(f.start_time, :dayShift) <= :endDate "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration "
        "AND trim(COALESCE(c.name, legacy.name, t.category, '')) != '' "
        "GROUP BY category_name, category_color "
        "ORDER BY total_duration DESC, category_name ASC"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    QVariantList categories;
    int totalDuration = 0;

    if (!query.exec()) {
        qWarning() << "Failed to get category stats:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return emptyCategoryStats();
    }

    while (query.next()) {
        const int duration = query.value(2).toInt();
        QVariantMap category;
        category.insert(QStringLiteral("name"), query.value(0).toString());
        category.insert(QStringLiteral("color"), query.value(1).toString());
        category.insert(QStringLiteral("duration"), duration);
        categories.append(category);
        totalDuration += duration;
    }

    // 百分比依赖总时长，必须等所有行累计完之后再计算。
    for (int index = 0; index < categories.size(); ++index) {
        QVariantMap category = categories.at(index).toMap();
        const int duration = category.value(QStringLiteral("duration")).toInt();
        category.insert(QStringLiteral("percentage"),
                        totalDuration > 0 ? static_cast<double>(duration) * 100.0 / totalDuration : 0.0);
        categories[index] = category;
    }

    QVariantMap result;
    result.insert(QStringLiteral("categories"), categories);
    result.insert(QStringLiteral("totalDuration"), totalDuration);
    return result;
}

QVariantMap StatisticsService::getMonthStats(int year, int month) const
{
    QVariantMap result = emptyMonthStats();
    if (!isValidStatsYearMonth(year, month, QStringLiteral("Failed to get month stats:"))) {
        return result;
    }

    const QDate firstDay(year, month, 1);
    const QDate lastDay(year, month, firstDay.daysInMonth());
    result.insert(QStringLiteral("totalDuration"),
                  queryTotalDurationForRange(firstDay, lastDay, QStringLiteral("month stats")));
    result.insert(QStringLiteral("effectiveDays"), getEffectiveDays(firstDay, lastDay));
    result.insert(QStringLiteral("sessionCount"), getFocusSessionCount(firstDay, lastDay));

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get month stats: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return result;
    }

    QSqlQuery query(db);
    // 任务的业务日期是 tasks.date，不是创建时间；补录或跨天创建时必须按用户选择的日期归属统计。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) AS total, "
        "COALESCE(SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END), 0) AS completed "
        "FROM tasks "
        "WHERE date >= :firstDay "
        "AND date <= :lastDay"));
    query.bindValue(QStringLiteral(":firstDay"), firstDay.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":lastDay"), lastDay.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to get month task stats:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return result;
    }

    result.insert(QStringLiteral("totalTasks"), query.value(QStringLiteral("total")).toInt());
    result.insert(QStringLiteral("completedTasks"), query.value(QStringLiteral("completed")).toInt());
    return result;
}

QVariantMap StatisticsService::getMonthStats() const
{
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return getMonthStats(today.year(), today.month());
}

QVariantMap StatisticsService::getMonthComparison(int year, int month) const
{
    if (!isValidStatsYearMonth(year, month, QStringLiteral("Failed to get month comparison:"))) {
        QVariantMap result;
        result.insert(QStringLiteral("hasData"), false);
        return result;
    }

    int previousYear = year;
    int previousMonth = month - 1;
    if (previousMonth < 1) {
        // 1 月的上月属于上一年，不能把 month=0 传给月统计接口。
        previousMonth = 12;
        --previousYear;
    }

    const QVariantMap currentStats = getMonthStats(year, month);
    const QVariantMap previousStats = getMonthStats(previousYear, previousMonth);

    QVariantMap result;
    result.insert(QStringLiteral("duration"),
                  buildComparisonResult(currentStats.value(QStringLiteral("totalDuration")).toInt(),
                                        previousStats.value(QStringLiteral("totalDuration")).toInt(),
                                        QStringLiteral("上月")));
    result.insert(QStringLiteral("effectiveDays"),
                  buildComparisonResult(currentStats.value(QStringLiteral("effectiveDays")).toInt(),
                                        previousStats.value(QStringLiteral("effectiveDays")).toInt(),
                                        QStringLiteral("上月")));
    result.insert(QStringLiteral("sessionCount"),
                  buildComparisonResult(currentStats.value(QStringLiteral("sessionCount")).toInt(),
                                        previousStats.value(QStringLiteral("sessionCount")).toInt(),
                                        QStringLiteral("上月")));
    return result;
}

int StatisticsService::getEffectiveDays(const QDate& startDate, const QDate& endDate) const
{
    return getUniqueFocusDates(startDate, endDate).size();
}

int StatisticsService::getFocusSessionCount(const QDate& startDate, const QDate& endDate) const
{
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to count focus sessions: invalid date range";
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count focus sessions: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count focus sessions:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    return query.value(0).toInt();
}

QVariantList StatisticsService::getMonthWeeklySummary(int year, int month) const
{
    QVariantList result;
    if (!isValidStatsYearMonth(year, month, QStringLiteral("Failed to get month weekly summary:"))) {
        return result;
    }

    const QDate firstDay(year, month, 1);
    const QDate lastDay(year, month, firstDay.daysInMonth());

    QDate weekStart = firstDay;
    int weekNumber = 1;
    while (weekStart <= lastDay) {
        const QDate naturalWeekStart = weekStart.addDays(1 - weekStart.dayOfWeek());
        const QPair<QDate, QDate> naturalWeekRange = getWeekRange(naturalWeekStart);
        QDate weekEnd = naturalWeekRange.second;
        if (weekEnd > lastDay) {
            weekEnd = lastDay;
        }

        QVariantMap week;
        week.insert(QStringLiteral("label"), QStringLiteral("第%1周").arg(weekNumber));
        week.insert(QStringLiteral("duration"),
                    queryTotalDurationForRange(weekStart, weekEnd, QStringLiteral("month weekly summary")));
        week.insert(QStringLiteral("startDate"), weekStart.toString(Qt::ISODate));
        week.insert(QStringLiteral("endDate"), weekEnd.toString(Qt::ISODate));
        result.append(week);

        weekStart = weekEnd.addDays(1);
        ++weekNumber;
    }

    return result;
}

QVariantList StatisticsService::getMonthWeeklySummary() const
{
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return getMonthWeeklySummary(today.year(), today.month());
}

int StatisticsService::calculateTotalDuration(const QDate& date) const
{
    if (!date.isValid()) {
        return 0;
    }

    return queryTotalDurationForRange(date, date, QStringLiteral("single day"));
}

int StatisticsService::countCompletedTasks(const QDate& date) const
{
    if (!date.isValid()) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count completed tasks: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE date = :date AND completed = 1"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count completed tasks:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    return query.value(0).toInt();
}

int StatisticsService::countTotalTasks(const QDate& date) const
{
    if (!date.isValid()) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count total tasks: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE date = :date"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count total tasks:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    return query.value(0).toInt();
}

int StatisticsService::getTotalFocusDuration() const
{
    // 全量累计不带日期条件：逻辑日只影响“归到哪一天”，不影响历史总量。
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get total focus duration: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COALESCE(SUM(duration), 0) FROM focus_sessions "
        "WHERE end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration"));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to get total focus duration:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    return query.value(0).toInt();
}

int StatisticsService::getStreakDays() const
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get streak days: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    // 只取“有有效专注的唯一逻辑日”倒序，在内存里从今天往回数连续段；
    // 天数级数据量很小，避免在 SQL 里写递归连击查询。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT DISTINCT date(start_time, :dayShift) AS focus_date "
        "FROM focus_sessions "
        "WHERE end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration "
        "ORDER BY focus_date DESC"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        qWarning() << "Failed to get streak days:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return 0;
    }

    int streak = 0;
    QDate expected = LogicalDay::today(AppSettings::instance()->dayStartHour());
    while (query.next()) {
        const QDate date = QDate::fromString(query.value(0).toString(), Qt::ISODate);
        if (!date.isValid() || date > expected) {
            // 晚于今天的记录只可能来自时钟回拨等异常数据，跳过不参与连击。
            continue;
        }

        if (date == expected) {
            ++streak;
            expected = expected.addDays(-1);
            continue;
        }

        if (streak == 0 && date == expected.addDays(-1)) {
            // 今天还没专注不算断（这一天尚未结束），连击从昨天开始回溯。
            ++streak;
            expected = date.addDays(-1);
            continue;
        }

        // 日期出现断档，连击到此为止。
        break;
    }

    return streak;
}

QList<QDate> StatisticsService::getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const
{
    QList<QDate> dates;
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to get unique focus dates: invalid date range";
        return dates;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get unique focus dates: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return dates;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT DISTINCT date(start_time, :dayShift) AS focus_date "
        "FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration "
        "ORDER BY focus_date ASC"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        qWarning() << "Failed to get unique focus dates:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return dates;
    }

    while (query.next()) {
        const QDate date = QDate::fromString(query.value(0).toString(), Qt::ISODate);
        if (date.isValid()) {
            dates.append(date);
        }
    }

    return dates;
}

QPair<QDate, QDate> StatisticsService::getWeekRange(const QDate& mondayOfWeek) const
{
    return qMakePair(mondayOfWeek, mondayOfWeek.addDays(6));
}
