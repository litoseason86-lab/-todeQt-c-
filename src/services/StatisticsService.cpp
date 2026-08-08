#include "StatisticsService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDebug>
#include <QDateTime>
#include <QHash>
#include <QtMath>
#include <QMap>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTime>
#include <QVariant>

#include <algorithm>

namespace {
// 科目要进入「投入明显低于计划」的判定，至少得有这么多计划用时。
// 单位随 v10 从「番茄个数」改为「分钟」，取 60 分钟以保持与原来 3 个番茄相当的量级。
constexpr int kReviewMinimumSubjectPlan = 60;
constexpr double kReviewSubjectGapPoints = 20.0;
constexpr double kReviewStableRateMinimum = 85.0;
constexpr double kReviewStableRateMaximum = 115.0;
constexpr double kReviewOverplannedRate = 60.0;
constexpr double kReviewUnderplannedRate = 120.0;

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

QVariantMap emptyTaskStats()
{
    QVariantMap result;
    result.insert(QStringLiteral("tasks"), QVariantList());
    result.insert(QStringLiteral("totalDuration"), 0);
    result.insert(QStringLiteral("taskCount"), 0);
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
    result.insert(QStringLiteral("pomodoroCount"), 0);
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

// 一次查出区间内每个逻辑日的专注总时长。谓词与 queryTotalDurationForRange 逐字相同，
// 只是把「按天调 N 次」换成「一次扫描 + GROUP BY」——行集与过滤条件不变，数字必然一致。
//
// 为什么值得这么做：谓词里的 date(start_time, shift) 包住了索引列，
// idx_sessions_start 用不上（实测 EXPLAIN QUERY PLAN 为 SCAN），
// 所以每多调一次就多一次全表扫描。实测 11000 行时 40 次逐日查询 82ms、合成后 1ms。
//
// 刻意不去动 date() 谓词本身：改成裸范围比较还能再快一个量级，但要把逻辑日边界
// 从 SQL 挪进 C++、牵涉夏令时，而收益只剩 0.8ms，不值当。
QHash<QString, int> queryDurationsByLogicalDay(const QDate& startDate,
                                               const QDate& endDate,
                                               const QString& context)
{
    QHash<QString, int> durations;
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to calculate daily durations:" << context << "invalid date range";
        return durations;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to calculate daily durations:" << context << "database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return durations;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT date(start_time, :dayShift) AS logical_day, COALESCE(SUM(duration), 0) "
        "FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration "
        "GROUP BY logical_day"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        qWarning() << "Failed to calculate daily durations:" << context << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return durations;
    }

    while (query.next()) {
        durations.insert(query.value(0).toString(), query.value(1).toInt());
    }
    return durations;
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
    stats.insert(QStringLiteral("pomodoroCount"), getValidPomodoroCount(date, date));
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

    // 专注时长一次查完：原本按天调 7 次，每次都是一遍全表扫描。
    // 任务计数保持逐日查询——tasks.date 是普通日期列且有 idx_tasks_date，
    // 那是走索引的等值查询，成本可忽略，为它再加一套解析代码不划算。
    const QHash<QString, int> durations = queryDurationsByLogicalDay(
        weekStart, weekStart.addDays(6), QStringLiteral("week stats"));

    for (int offset = 0; offset < 7; ++offset) {
        const QDate date = weekStart.addDays(offset);
        QVariantMap dayStats;
        dayStats.insert(QStringLiteral("date"), date);
        // 没有会话的日子不会出现在 GROUP BY 结果里，缺失即 0——与原来逐日查询返回 0 一致。
        dayStats.insert(QStringLiteral("duration"),
                        durations.value(date.toString(Qt::ISODate), 0));
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

    const QDate weekEnd = weekStart.addDays(6);
    const QDate previousWeekStart = weekStart.addDays(-7);
    const QDate previousWeekEnd = weekStart.addDays(-1);

    // 这里原本按天循环调 14 次单日查询。每次查询的谓词都是
    // `date(start_time, shift) BETWEEN ...`，`date()` 包住索引列会让 idx_sessions_start
    // 失效（实测 EXPLAIN QUERY PLAN 为 SCAN），于是一次周对比要全表扫描 14 遍。
    //
    // 改成两次区间查询是可证明等价的：每条会话只属于一个逻辑日，区间谓词两端闭合，
    // 「7 天各自求和」与「同一区间求和」的行集和过滤条件完全相同。
    // 实测（11000 行、重度用户三年量级）：40 次逐日查询 82ms，合成后 1ms。
    //
    // 注意这里刻意不去动 `date()` 谓词本身。改成裸范围比较还能再快一个量级，
    // 但那要把逻辑日边界从 SQL 挪进 C++，牵涉夏令时，而收益只有 0.8ms——不值当。
    const int currentDuration =
        queryTotalDurationForRange(weekStart, weekEnd, QStringLiteral("week comparison"));
    const int previousDuration = queryTotalDurationForRange(
        previousWeekStart, previousWeekEnd, QStringLiteral("previous week comparison"));

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

    // 会话快照优先；对迁移前的旧记录才回退到当前任务科目。
    // 因此删任务或删科目只会解除当前对象，不会把历史专注重写成“未关联任务”。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT "
        "COALESCE(NULLIF(snapshot_category.name, ''), NULLIF(f.category_name_snapshot, ''), "
        "NULLIF(c.name, ''), NULLIF(legacy.name, ''), NULLIF(t.category, ''), "
        "CASE WHEN t.id IS NULL THEN '未关联任务' ELSE '未分类' END) AS category_name, "
        "COALESCE(NULLIF(snapshot_category.color, ''), NULLIF(f.category_color_snapshot, ''), "
        "NULLIF(c.color, ''), NULLIF(legacy.color, ''), '#d4a574') AS category_color, "
        "SUM(f.duration) AS total_duration "
        "FROM focus_sessions f "
        "LEFT JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories snapshot_category ON f.category_id_snapshot = snapshot_category.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
        "WHERE date(f.start_time, :dayShift) >= :startDate "
        "AND date(f.start_time, :dayShift) <= :endDate "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration "
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

QVariantMap StatisticsService::getDayTaskStats(const QDate& date) const
{
    if (!date.isValid()) {
        qWarning() << "Failed to get day task stats: invalid date";
        return emptyTaskStats();
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get day task stats: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return emptyTaskStats();
    }

    // 按 task_id 分组：同一任务当天的多段专注累加成一行。GROUP BY f.task_id 会把所有
    // task_id 为空的自由计时会话归入同一组，天然得到「未关联专注」单行。
    // 专注时长对 mode 不敏感(番茄段+自由段都算)，番茄数走 FocusSessionRules 唯一口径。
    // 科目名/色沿用 getCategoryStats 的快照优先 COALESCE 链，保证与饼图一致。
    QSqlQuery query(db);
    const QString sql = QStringLiteral(
        "SELECT "
        "f.task_id AS task_id, "
        "t.title AS task_title, "
        "COALESCE(t.completed, 0) AS task_completed, "
        "COALESCE(NULLIF(snapshot_category.name, ''), NULLIF(f.category_name_snapshot, ''), "
        "NULLIF(c.name, ''), NULLIF(legacy.name, ''), NULLIF(t.category, ''), '') AS category_name, "
        "COALESCE(NULLIF(snapshot_category.color, ''), NULLIF(f.category_color_snapshot, ''), "
        "NULLIF(c.color, ''), NULLIF(legacy.color, ''), '#d4a574') AS category_color, "
        "SUM(f.duration) AS focused_seconds, "
        "%1 AS pomodoros "
        "FROM focus_sessions f "
        "LEFT JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories snapshot_category ON f.category_id_snapshot = snapshot_category.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
        "WHERE date(f.start_time, :dayShift) = :date "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration "
        "GROUP BY f.task_id "
        "ORDER BY focused_seconds DESC, task_title ASC")
        .arg(FocusSessionRules::validPomodoroCountExpr(QStringLiteral("f")));
    query.prepare(sql);
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        qWarning() << "Failed to get day task stats:" << query.lastError().text();
        reportStatisticsFailure(query.lastError().text());
        return emptyTaskStats();
    }

    QVariantList tasks;
    int totalDuration = 0;
    while (query.next()) {
        const bool unassigned = query.value(0).isNull();
        const int focusedSeconds = query.value(5).toInt();

        QVariantMap task;
        task.insert(QStringLiteral("taskId"), unassigned ? -1 : query.value(0).toInt());
        task.insert(QStringLiteral("title"), query.value(1).toString());
        task.insert(QStringLiteral("completed"), query.value(2).toInt() != 0);
        task.insert(QStringLiteral("categoryName"), query.value(3).toString());
        task.insert(QStringLiteral("color"), query.value(4).toString());
        task.insert(QStringLiteral("focusedSeconds"), focusedSeconds);
        task.insert(QStringLiteral("pomodoros"), query.value(6).toInt());
        task.insert(QStringLiteral("unassigned"), unassigned);
        tasks.append(task);
        totalDuration += focusedSeconds;
    }

    QVariantMap result;
    result.insert(QStringLiteral("tasks"), tasks);
    result.insert(QStringLiteral("totalDuration"), totalDuration);
    result.insert(QStringLiteral("taskCount"), tasks.size());
    return result;
}

QVariantMap StatisticsService::getTodayTaskStats() const
{
    return getDayTaskStats(LogicalDay::today(AppSettings::instance()->dayStartHour()));
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

int StatisticsService::getValidPomodoroCount(const QDate& startDate, const QDate& endDate) const
{
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to count valid pomodoros: invalid date range";
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count valid pomodoros: database is not open";
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return 0;
    }

    QSqlQuery query(db);
    // 与会话数使用完全相同的逻辑日窗口；差异只是番茄还必须满足唯一事实源的模式与自然到点条件。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions fs "
        "WHERE date(fs.start_time, :dayShift) >= :startDate "
        "AND date(fs.start_time, :dayShift) <= :endDate "
        "AND fs.end_time IS NOT NULL "
        "AND fs.duration IS NOT NULL "
        "AND %1")
                      .arg(FocusSessionRules::validPomodoroPredicate(QStringLiteral("fs"))));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count valid pomodoros:" << query.lastError().text();
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

QVariantMap StatisticsService::weeklyAggregates(const QDate& weekStart, const QDate& weekEnd) const
{
    QVariantMap result;
    result.insert(QStringLiteral("plannedTotal"), 0);
    result.insert(QStringLiteral("completedTotal"), 0);
    result.insert(QStringLiteral("focusedSeconds"), 0);
    result.insert(QStringLiteral("activeDays"), 0);
    result.insert(QStringLiteral("subjects"), QVariantList());

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        reportStatisticsFailure(QStringLiteral("数据库未打开"));
        return result;
    }

    const int dayStartHour = AppSettings::instance()->dayStartHour();
    const QString dayShift = LogicalDay::sqlShift(dayStartHour);
    const QString startIso = weekStart.toString(Qt::ISODate);
    const QString endIso = weekEnd.toString(Qt::ISODate);
    // start_time 以 ISO 日期时间存储；使用真实半开边界让 idx_sessions_start 可用于范围扫描。
    // 边界不带时区后缀，兼容历史无偏移字符串和当前带偏移字符串的共同日期时间前缀。
    const QString startAt =
        QDateTime(weekStart, QTime(dayStartHour, 0)).toString(
            QStringLiteral("yyyy-MM-ddTHH:mm:ss"));
    const QString endAt =
        QDateTime(weekEnd.addDays(1), QTime(dayStartHour, 0)).toString(
            QStringLiteral("yyyy-MM-ddTHH:mm:ss"));

    // 按科目名合并计划与实际；科目名的解析口径与 getCategoryStats 一致，保证两侧能对齐。
    QMap<QString, QVariantMap> subjects;
    auto ensureSubject = [&subjects](const QString& name, const QString& color) -> QVariantMap& {
        if (!subjects.contains(name)) {
            QVariantMap entry;
            entry.insert(QStringLiteral("name"), name);
            entry.insert(QStringLiteral("color"), color);
            entry.insert(QStringLiteral("planned"), 0);
            entry.insert(QStringLiteral("actual"), 0);
            entry.insert(QStringLiteral("focusedSeconds"), 0);
            subjects.insert(name, entry);
        }
        return subjects[name];
    };

    int plannedTotal = 0;
    // 计划番茄：按任务的计划日期归入本周（tasks.date 为 yyyy-MM-dd，字典序即日期序）。
    {
        QSqlQuery query(db);
        // 别名避开真实列名 color/name，否则 GROUP BY 会因 categories 联表出现歧义列而报错。
        query.prepare(QStringLiteral(
            "SELECT COALESCE(NULLIF(c.name,''), NULLIF(legacy.name,''), NULLIF(t.category,''), '未分类') AS subject_name, "
            "COALESCE(NULLIF(c.color,''), NULLIF(legacy.color,''), '#d4a574') AS subject_color, "
            "SUM(t.estimated_minutes) AS planned "
            "FROM tasks t "
            "LEFT JOIN categories c ON t.category_id = c.id "
            "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
            "WHERE t.date >= :startDate AND t.date <= :endDate AND t.estimated_minutes > 0 "
            "GROUP BY subject_name, subject_color"));
        query.bindValue(QStringLiteral(":startDate"), startIso);
        query.bindValue(QStringLiteral(":endDate"), endIso);
        if (!query.exec()) {
            reportStatisticsFailure(query.lastError().text());
            return result;
        }
        while (query.next()) {
            const int planned = query.value(2).toInt();
            QVariantMap& entry = ensureSubject(query.value(0).toString(), query.value(1).toString());
            entry[QStringLiteral("planned")] = entry.value(QStringLiteral("planned")).toInt() + planned;
            plannedTotal += planned;
        }
    }

    int completedTotal = 0;
    int focusedSeconds = 0;
    // 实际番茄：只计自然到点的有效番茄工作段；专注秒数含两种模式的有效会话。
    // 有效口径复用 kMinimumValidDurationSeconds，与任务实际番茄聚合完全一致。
    {
        QSqlQuery query(db);
        query.prepare(QStringLiteral(R"SQL(
            WITH filtered AS (
                SELECT task_id, mode, pomodoro_completed, duration,
                       category_id_snapshot, category_name_snapshot, category_color_snapshot,
                       date(start_time, :dayShift) AS logical_date
                FROM focus_sessions
                WHERE start_time >= :startAt AND start_time < :endAt
                  AND end_time IS NOT NULL
                  AND duration IS NOT NULL
                  AND duration >= :minDuration
            ),
            grouped AS (
                SELECT COALESCE(NULLIF(snapshot_category.name,''),
                                NULLIF(f.category_name_snapshot,''), NULLIF(c.name,''),
                                NULLIF(legacy.name,''), NULLIF(t.category,''),
                                CASE WHEN t.id IS NULL THEN '未关联任务'
                                     ELSE '未分类' END) AS subject_name,
                       COALESCE(NULLIF(snapshot_category.color,''),
                                NULLIF(f.category_color_snapshot,''), NULLIF(c.color,''),
                                NULLIF(legacy.color,''), '#d4a574')
                           AS subject_color,
                       SUM(CASE WHEN %1
                                THEN 1 ELSE 0 END) AS actual_pomodoros,
                       SUM(f.duration) AS focused_seconds
                FROM filtered f
                LEFT JOIN tasks t ON f.task_id = t.id
                LEFT JOIN categories snapshot_category
                       ON f.category_id_snapshot = snapshot_category.id
                LEFT JOIN categories c ON t.category_id = c.id
                LEFT JOIN categories legacy
                       ON t.category_id IS NULL AND legacy.name = t.category
                GROUP BY subject_name, subject_color
            )
            SELECT 0 AS row_kind, subject_name, subject_color,
                   actual_pomodoros, focused_seconds, 0 AS active_days
            FROM grouped
            UNION ALL
            SELECT 1, '', '', 0, 0, COUNT(DISTINCT logical_date)
            FROM filtered
        )SQL").arg(FocusSessionRules::validPomodoroPredicate(QStringLiteral("f"))));
        query.bindValue(QStringLiteral(":dayShift"), dayShift);
        query.bindValue(QStringLiteral(":startAt"), startAt);
        query.bindValue(QStringLiteral(":endAt"), endAt);
        query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);
        if (!query.exec()) {
            reportStatisticsFailure(query.lastError().text());
            return result;
        }
        while (query.next()) {
            if (query.value(0).toInt() == 1) {
                result[QStringLiteral("activeDays")] = query.value(5).toInt();
                continue;
            }
            const int actual = query.value(3).toInt();
            const int focused = query.value(4).toInt();
            QVariantMap& entry =
                ensureSubject(query.value(1).toString(), query.value(2).toString());
            entry[QStringLiteral("actual")] = entry.value(QStringLiteral("actual")).toInt() + actual;
            entry[QStringLiteral("focusedSeconds")] =
                entry.value(QStringLiteral("focusedSeconds")).toInt() + focused;
            completedTotal += actual;
            focusedSeconds += focused;
        }
    }

    QVariantList subjectList;
    for (auto it = subjects.constBegin(); it != subjects.constEnd(); ++it) {
        QVariantMap entry = it.value();
        const int planned = entry.value(QStringLiteral("planned")).toInt();
        const int actual = entry.value(QStringLiteral("actual")).toInt();
        // 计划单位已改为「预计用时（分钟）」，完成率必须拿同单位的实际投入去比，
        // 否则是「分钟 ÷ 番茄个数」这种没有意义的数。
        const int focusedMinutes = entry.value(QStringLiteral("focusedSeconds")).toInt() / 60;
        entry.insert(QStringLiteral("focusedMinutes"), focusedMinutes);
        // 只有实际没计划标记“未计划投入”；只有计划没实际则完成率 0%。
        entry.insert(QStringLiteral("unplanned"), planned == 0 && (actual > 0 || focusedMinutes > 0));
        entry.insert(QStringLiteral("rate"),
                     planned > 0 ? static_cast<double>(focusedMinutes) * 100.0 / planned : 0.0);
        subjectList.append(entry);
    }
    // 计划多的科目排前，便于对账阅读。
    std::sort(subjectList.begin(), subjectList.end(), [](const QVariant& a, const QVariant& b) {
        const QVariantMap ma = a.toMap();
        const QVariantMap mb = b.toMap();
        if (ma.value(QStringLiteral("planned")).toInt() != mb.value(QStringLiteral("planned")).toInt()) {
            return ma.value(QStringLiteral("planned")).toInt() > mb.value(QStringLiteral("planned")).toInt();
        }
        if (ma.value(QStringLiteral("actual")).toInt()
            != mb.value(QStringLiteral("actual")).toInt()) {
            return ma.value(QStringLiteral("actual")).toInt()
                > mb.value(QStringLiteral("actual")).toInt();
        }
        return ma.value(QStringLiteral("name")).toString()
            < mb.value(QStringLiteral("name")).toString();
    });

    result[QStringLiteral("plannedTotal")] = plannedTotal;
    result[QStringLiteral("completedTotal")] = completedTotal;
    result[QStringLiteral("focusedSeconds")] = focusedSeconds;
    result[QStringLiteral("subjects")] = subjectList;
    return result;
}

QVariantMap StatisticsService::getWeeklyReview(const QDate& weekStart) const
{
    QVariantMap result;
    result.insert(QStringLiteral("hasData"), false);
    result.insert(QStringLiteral("subjects"), QVariantList());
    result.insert(QStringLiteral("factText"), QString());
    result.insert(QStringLiteral("suggestionText"), QString());

    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday) {
        qWarning() << "Failed to build weekly review: weekStart is not Monday" << weekStart;
        return result;
    }

    const QDate weekEnd = weekStart.addDays(6);
    const QVariantMap current = weeklyAggregates(weekStart, weekEnd);
    const QVariantMap previous = weeklyAggregates(weekStart.addDays(-7), weekStart.addDays(-1));

    const int planned = current.value(QStringLiteral("plannedTotal")).toInt();
    const int completed = current.value(QStringLiteral("completedTotal")).toInt();
    const int focusedSeconds = current.value(QStringLiteral("focusedSeconds")).toInt();
    const QVariantList subjects = current.value(QStringLiteral("subjects")).toList();
    const int focusedMinutes = focusedSeconds / 60;
    // 计划单位已是分钟，完成率 = 实际专注分钟 / 计划用时分钟。
    // 计划为 0 时不除零：完成率视为无（0），由 UI 与结论规则单独处理“未计划”。
    const double rate = planned > 0 ? static_cast<double>(focusedMinutes) * 100.0 / planned : 0.0;

    result[QStringLiteral("weekStart")] = weekStart.toString(Qt::ISODate);
    result[QStringLiteral("weekEnd")] = weekEnd.toString(Qt::ISODate);
    result[QStringLiteral("plannedMinutes")] = planned;
    result[QStringLiteral("completedPomodoros")] = completed;
    result[QStringLiteral("completionRate")] = rate;
    result[QStringLiteral("focusedMinutes")] = focusedMinutes;
    result[QStringLiteral("activeDays")] = current.value(QStringLiteral("activeDays")).toInt();
    result[QStringLiteral("previousCompletedPomodoros")] = previous.value(QStringLiteral("completedTotal")).toInt();
    result[QStringLiteral("previousFocusedMinutes")] = previous.value(QStringLiteral("focusedSeconds")).toInt() / 60;
    result[QStringLiteral("previousActiveDays")] = previous.value(QStringLiteral("activeDays")).toInt();
    result[QStringLiteral("subjects")] = subjects;

    // 确定性结论：最多一条事实 + 一条建议。用词只陈述事实、不评价人格。
    QString factText;
    QString suggestionText;

    // 规则一：找出计划≥3 且完成率比总体低至少 20 个百分点、最低的那个科目。
    double worstGap = -1.0;
    QString worstSubject;
    for (const QVariant& value : subjects) {
        const QVariantMap subject = value.toMap();
        const int subjectPlanned = subject.value(QStringLiteral("planned")).toInt();
        if (subjectPlanned < kReviewMinimumSubjectPlan) {
            continue;
        }
        const double subjectRate = subject.value(QStringLiteral("rate")).toDouble();
        if (subjectRate <= rate - kReviewSubjectGapPoints) {
            const double gap = rate - subjectRate;
            if (gap > worstGap) {
                worstGap = gap;
                worstSubject = subject.value(QStringLiteral("name")).toString();
            }
        }
    }

    if (!worstSubject.isEmpty()) {
        factText = worstSubject + QStringLiteral("的实际投入明显低于计划。");
    } else if (planned > 0
               && rate >= kReviewStableRateMinimum
               && rate <= kReviewStableRateMaximum) {
        // 规则四：计划基本准确。
        factText = QStringLiteral("本周计划与实际基本一致，当前估算较稳定。");
    }

    if (planned == 0 && completed > 0) {
        suggestionText = QStringLiteral("为任务设置预计用时后，这里能给出计划完成率与偏差分析。");
    } else if (planned > 0 && rate < kReviewOverplannedRate) {
        // 规则二：总体高估。
        suggestionText = QStringLiteral("下周总计划量可以先下调 15%～25%，避免继续累积无法完成的任务。");
    } else if (planned > 0 && rate > kReviewUnderplannedRate) {
        // 规则三：总体低估。
        suggestionText = QStringLiteral("本周实际投入明显高于预估，可以适当提高下周计划量，或重新校准任务预估。");
    }

    result[QStringLiteral("factText")] = factText;
    result[QStringLiteral("suggestionText")] = suggestionText;
    result[QStringLiteral("hasData")] = planned > 0 || completed > 0;
    return result;
}

QVariantMap StatisticsService::getWeeklyReview() const
{
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return getWeeklyReview(today.addDays(1 - today.dayOfWeek()));
}
