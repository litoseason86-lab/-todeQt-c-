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
// —— 周复盘事实规则（046）——
// 阈值是首版展示默认值，集中定义在这里；真实数据回放只检查适用性，不据此宣称统计显著性。
// 判断一律用整数秒交叉相乘，不走浮点：浮点误差会让「刚好 60%」「刚好 10 个百分点」落到错误一侧。
// F1 目标差额：已结束的目标日里，实际 < 目标 × 60%。
constexpr qint64 kGoalShortfallPercent = 60;
// F2 科目变化：两周总投入各不少于 60 分钟，占比变化不少于 10 个百分点，且该科投入变化不少于 60 分钟。
// 最后一条防小样本：两周各一小时时，10 个百分点只对应 6 分钟，不值得下结论。
constexpr qint64 kShareChangeMinimumWeekSeconds = 60 * 60;
constexpr qint64 kShareChangeMinimumPoints = 10;
constexpr qint64 kShareChangeMinimumSubjectSeconds = 60 * 60;
// F3 预计用时差额：科目计划不少于 60 分钟，同一任务集合内的实际 < 计划 × 60%。
constexpr qint64 kEstimateMinimumPlanMinutes = 60;
constexpr qint64 kEstimateShortfallPercent = 60;
// F3 补充：没有科目差额时，集合总投入落在计划的 85%～115%（含端点）。
constexpr qint64 kEstimateOnTrackMinimumPercent = 85;
constexpr qint64 kEstimateOnTrackMaximumPercent = 115;

// 科目名兜底值，与下面各条 SQL 里的字面量保持一致。它们不是真实科目，不能成为 F2 的点名对象。
const auto kUnlinkedSubjectName = QStringLiteral("未关联任务");
const auto kUncategorizedSubjectName = QStringLiteral("未分类");

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

// 「逻辑今天」由页面按年、月、日拼成 yyyy-MM-dd 传入。只认严格的 ISO 日期：
// 2026-9-1 这类能被宽松解析的写法说明调用方拼错了，按参数错误处理，不替它猜。
QDate parseStrictIsoDate(const QString& text)
{
    const QDate date = QDate::fromString(text, Qt::ISODate);
    return date.isValid() && date.toString(Qt::ISODate) == text ? date : QDate();
}

// 周期状态只看逻辑日期：进入下周一逻辑日后本周才算结束。logicalToday 已经是
// 按 dayStartHour 换算过的日期，这里不能再减一次日界。
QString weekPeriodState(const QDate& weekStart, const QDate& logicalToday)
{
    if (logicalToday < weekStart) {
        return QStringLiteral("future");
    }
    if (logicalToday > weekStart.addDays(6)) {
        return QStringLiteral("ended");
    }
    return QStringLiteral("current");
}

// 复盘结果的固定形状。界面按 loadState 先分出错误态，再按各模块是否有内容决定显示，
// 所以即使没有数据，字段也都在，只是为空。
QVariantMap weeklyReviewSkeleton(const QDate& weekStart, const QString& logicalTodayIso)
{
    QVariantMap review;
    review.insert(QStringLiteral("weekStart"),
                  weekStart.isValid() ? weekStart.toString(Qt::ISODate) : QString());
    review.insert(QStringLiteral("weekEnd"),
                  weekStart.isValid() ? weekStart.addDays(6).toString(Qt::ISODate) : QString());
    review.insert(QStringLiteral("logicalTodayIso"), logicalTodayIso);
    review.insert(QStringLiteral("periodState"), QString());
    review.insert(QStringLiteral("loadState"), QStringLiteral("ready"));
    review.insert(QStringLiteral("errorMessage"), QString());
    review.insert(QStringLiteral("hasData"), false);
    review.insert(QStringLiteral("hasDisplayContent"), false);
    review.insert(QStringLiteral("goal"), QVariantMap());
    review.insert(QStringLiteral("todayGoal"), QVariantMap());
    review.insert(QStringLiteral("subjects"), QVariantList());
    review.insert(QStringLiteral("plannedTasks"), QVariantMap());
    review.insert(QStringLiteral("facts"), QVariantList());
    return review;
}

// 失败时整份复盘作废：只保留周期上下文与错误信息，统计模块一律清空，
// 不能让界面拿着半份统计去下结论。
QVariantMap weeklyReviewError(QVariantMap review, const QString& message)
{
    review.insert(QStringLiteral("loadState"), QStringLiteral("error"));
    review.insert(QStringLiteral("errorMessage"), message);
    review.insert(QStringLiteral("hasData"), false);
    review.insert(QStringLiteral("hasDisplayContent"), false);
    review.insert(QStringLiteral("goal"), QVariantMap());
    review.insert(QStringLiteral("todayGoal"), QVariantMap());
    review.insert(QStringLiteral("subjects"), QVariantList());
    review.insert(QStringLiteral("plannedTasks"), QVariantMap());
    review.insert(QStringLiteral("facts"), QVariantList());
    return review;
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
// 本函数是这条 SQL 的唯一定义，不发 operationFailed：周复盘的错误只通过返回值交给卡片，
// 趋势图等其他接口经 queryDurationsByLogicalDay 包装后照旧发信号。
// 复盘里某一天的投入与趋势图那一天的柱子因此是同一个数。
bool runDurationsByLogicalDay(const QDate& startDate,
                              const QDate& endDate,
                              QHash<QString, int>* durations,
                              QString* error)
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        *error = QStringLiteral("数据库未打开");
        return false;
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
        *error = query.lastError().text();
        return false;
    }

    while (query.next()) {
        durations->insert(query.value(0).toString(), query.value(1).toInt());
    }
    return true;
}

QHash<QString, int> queryDurationsByLogicalDay(const QDate& startDate,
                                               const QDate& endDate,
                                               const QString& context)
{
    QHash<QString, int> durations;
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        qWarning() << "Failed to calculate daily durations:" << context << "invalid date range";
        return durations;
    }

    QString error;
    if (!runDurationsByLogicalDay(startDate, endDate, &durations, &error)) {
        qWarning() << "Failed to calculate daily durations:" << context << error;
        reportStatisticsFailure(error);
        return QHash<QString, int>();
    }
    return durations;
}

// 科目时间分配的一行：会话快照优先归类，旧记录回退到任务当前科目。
struct SubjectDuration
{
    QString name;
    QString color;
    int seconds = 0;
};

// 科目归类 SQL 的唯一定义：统计页饼图（getCategoryStats）与周复盘的 F2 共用，
// 所以 F2 里某科的秒数与同周饼图该科的时长一定一致。本函数不发 operationFailed。
bool runCategoryDurations(const QDate& startDate,
                          const QDate& endDate,
                          QList<SubjectDuration>* rows,
                          QString* error)
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        *error = QStringLiteral("数据库未打开");
        return false;
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

    if (!query.exec()) {
        *error = query.lastError().text();
        return false;
    }

    while (query.next()) {
        SubjectDuration row;
        row.name = query.value(0).toString();
        row.color = query.value(1).toString();
        row.seconds = query.value(2).toInt();
        rows->append(row);
    }
    return true;
}

// 预计用时对账集合里的一条任务：所选周计划日期内、预计用时大于零。
struct PlannedTask
{
    int taskId = 0;
    int plannedMinutes = 0;
    QString subject;
    QString color;
};

// 对账集合只读 tasks，不碰专注记录；复盘先跑它，再跑专注查询。
// 科目按任务当前所属科目归组（与计划同源），不看会话快照，避免分子分母落在不同科目里。
bool runPlannedTasks(const QDate& weekStart,
                     const QDate& weekEnd,
                     QList<PlannedTask>* tasks,
                     QString* error)
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        *error = QStringLiteral("数据库未打开");
        return false;
    }

    // 别名避开真实列名 color/name：categories 联表两次，引用裸名会出现歧义列。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT t.id, t.estimated_minutes, "
        "COALESCE(NULLIF(c.name, ''), NULLIF(legacy.name, ''), NULLIF(t.category, ''), '未分类') "
        "AS subject_name, "
        "COALESCE(NULLIF(c.color, ''), NULLIF(legacy.color, ''), '#d4a574') AS subject_color "
        "FROM tasks t "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
        "WHERE t.date >= :startDate AND t.date <= :endDate AND t.estimated_minutes > 0"));
    query.bindValue(QStringLiteral(":startDate"), weekStart.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), weekEnd.toString(Qt::ISODate));

    if (!query.exec()) {
        *error = query.lastError().text();
        return false;
    }

    while (query.next()) {
        PlannedTask task;
        task.taskId = query.value(0).toInt();
        task.plannedMinutes = query.value(1).toInt();
        task.subject = query.value(2).toString();
        task.color = query.value(3).toString();
        tasks->append(task);
    }
    return true;
}

// 对账实际：只统计所选逻辑周内、挂在对账集合任务上的有效专注秒数。
// 没填预计用时的任务、计划日期在别的周的任务、未关联任务的会话都不进来。
// 集合按整周计划日期取；会话只取到 sessionEnd（当前周为逻辑今天），分母是整周计划、分子是已产生的投入。
bool runPlannedTaskSeconds(const QDate& weekStart,
                           const QDate& weekEnd,
                           const QDate& sessionEnd,
                           QHash<int, qint64>* seconds,
                           QString* error)
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        *error = QStringLiteral("数据库未打开");
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT f.task_id, SUM(f.duration) "
        "FROM focus_sessions f "
        "JOIN tasks t ON t.id = f.task_id "
        "WHERE t.date >= :startDate AND t.date <= :endDate AND t.estimated_minutes > 0 "
        "AND date(f.start_time, :dayShift) >= :startDate "
        "AND date(f.start_time, :dayShift) <= :sessionEnd "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration "
        "GROUP BY f.task_id"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":startDate"), weekStart.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), weekEnd.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":sessionEnd"), sessionEnd.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        *error = query.lastError().text();
        return false;
    }

    while (query.next()) {
        seconds->insert(query.value(0).toInt(), query.value(1).toLongLong());
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

QVariantMap StatisticsService::getWeekComparison(const QDate& weekStart,
                                                 const QString& logicalTodayIso) const
{
    const QDate logicalToday = parseStrictIsoDate(logicalTodayIso);
    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday || !logicalToday.isValid()) {
        QVariantMap result;
        result.insert(QStringLiteral("hasData"), false);
        result.insert(QStringLiteral("periodState"), QString());
        return result;
    }

    const QString periodState = weekPeriodState(weekStart, logicalToday);
    if (periodState != QStringLiteral("ended")) {
        // 进行中的周拿去比上一整周，窗口不一致，周三看几乎总是「下跌」。
        // 当前周（以及界面到不了的未来周）不给涨跌，三项指标都按无数据返回。
        QVariantMap result;
        result.insert(QStringLiteral("periodState"), periodState);
        result.insert(QStringLiteral("duration"), noComparisonData());
        result.insert(QStringLiteral("effectiveDays"), noComparisonData());
        result.insert(QStringLiteral("sessionCount"), noComparisonData());
        return result;
    }

    QVariantMap result = getWeekComparison(weekStart);
    result.insert(QStringLiteral("periodState"), periodState);
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

    QList<SubjectDuration> rows;
    QString error;
    if (!runCategoryDurations(startDate, endDate, &rows, &error)) {
        qWarning() << "Failed to get category stats:" << error;
        reportStatisticsFailure(error);
        return emptyCategoryStats();
    }

    QVariantList categories;
    int totalDuration = 0;
    for (const SubjectDuration& row : std::as_const(rows)) {
        QVariantMap category;
        category.insert(QStringLiteral("name"), row.name);
        category.insert(QStringLiteral("color"), row.color);
        category.insert(QStringLiteral("duration"), row.seconds);
        categories.append(category);
        totalDuration += row.seconds;
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

    // 同一任务当天的多段专注累加成一行，task_id 为空的会话统一归入「未关联专注」。
    // 一行只能展示一种科目颜色，而同一任务当天可能先后换过科目，因此明确取最后一段
    // 有效专注的快照；同一时刻再按 id 取最后写入的一段。不能直接在 GROUP BY task_id 时
    // 读取 f 的普通列，SQLite 会任意挑一行，结果会随索引和查询计划变化。
    // 专注时长对 mode 不敏感（番茄段和自由段都算），番茄数走统一有效番茄口径。
    QSqlQuery query(db);
    const QString sql = QStringLiteral(
        "WITH valid_sessions AS ("
        "SELECT f.* FROM focus_sessions f "
        "WHERE date(f.start_time, :dayShift) = :date "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration"
        "), task_aggregates AS ("
        "SELECT f.task_id, SUM(f.duration) AS focused_seconds, %1 AS pomodoros "
        "FROM valid_sessions f GROUP BY f.task_id"
        "), latest_sessions AS ("
        "SELECT f.* FROM valid_sessions f "
        "WHERE f.id = ("
        "SELECT candidate.id FROM valid_sessions candidate "
        "WHERE candidate.task_id IS f.task_id "
        "ORDER BY candidate.start_time DESC, candidate.id DESC LIMIT 1"
        ")"
        ") "
        "SELECT "
        "totals.task_id AS task_id, "
        "t.title AS task_title, "
        "COALESCE(t.completed, 0) AS task_completed, "
        "COALESCE(NULLIF(snapshot_category.name, ''), NULLIF(latest.category_name_snapshot, ''), "
        "NULLIF(c.name, ''), NULLIF(legacy.name, ''), NULLIF(t.category, ''), '') AS category_name, "
        "COALESCE(NULLIF(snapshot_category.color, ''), NULLIF(latest.category_color_snapshot, ''), "
        "NULLIF(c.color, ''), NULLIF(legacy.color, ''), '#d4a574') AS category_color, "
        "totals.focused_seconds, "
        "totals.pomodoros "
        "FROM task_aggregates totals "
        "JOIN latest_sessions latest ON latest.task_id IS totals.task_id "
        "LEFT JOIN tasks t ON totals.task_id = t.id "
        "LEFT JOIN categories snapshot_category ON latest.category_id_snapshot = snapshot_category.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category "
        "ORDER BY totals.focused_seconds DESC, task_title ASC")
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
    return getMonthComparison(year, month, QVariantMap());
}

QVariantMap StatisticsService::getMonthComparison(int year, int month,
                                                  const QVariantMap& precomputedCurrent) const
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

    const QVariantMap currentStats = precomputedCurrent.isEmpty()
        ? getMonthStats(year, month) : precomputedCurrent;
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

QVariantMap StatisticsService::getWeeklyReview(const QDate& weekStart,
                                               const QString& logicalTodayIso) const
{
    QVariantMap review = weeklyReviewSkeleton(weekStart, logicalTodayIso);
    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday) {
        return weeklyReviewError(review, QStringLiteral("周起始日无效"));
    }
    const QDate logicalToday = parseStrictIsoDate(logicalTodayIso);
    if (!logicalToday.isValid()) {
        return weeklyReviewError(review, QStringLiteral("逻辑日期无效"));
    }

    const QString periodState = weekPeriodState(weekStart, logicalToday);
    review.insert(QStringLiteral("periodState"), periodState);
    if (periodState == QStringLiteral("future")) {
        // 页面导航到不了未来周，这里按空周返回，不查询。
        return review;
    }

    const bool ended = periodState == QStringLiteral("ended");
    const QDate weekEnd = weekStart.addDays(6);
    // 当前周只汇总已经产生的记录：专注查询截到逻辑今天。正常情况下今天之后本来就没有记录，
    // 但系统时钟被往前拨过时会留下「未来」的会话，不能让它们混进进行中的周。
    const QDate sessionEnd = ended ? weekEnd : logicalToday;
    QString error;

    // 查询顺序固定：先只读 tasks 的对账集合，再读专注记录。任何一步失败，整份复盘作废，
    // 不能拿前面已经查到的半份统计去组装结果。
    QList<PlannedTask> plannedTasks;
    if (!runPlannedTasks(weekStart, weekEnd, &plannedTasks, &error)) {
        return weeklyReviewError(review, error);
    }
    QHash<int, qint64> plannedTaskSeconds;
    if (!plannedTasks.isEmpty()
        && !runPlannedTaskSeconds(weekStart, weekEnd, sessionEnd, &plannedTaskSeconds, &error)) {
        return weeklyReviewError(review, error);
    }
    QHash<QString, int> dailySeconds;
    if (!runDurationsByLogicalDay(weekStart, sessionEnd, &dailySeconds, &error)) {
        return weeklyReviewError(review, error);
    }
    QList<SubjectDuration> currentSubjectRows;
    if (!runCategoryDurations(weekStart, sessionEnd, &currentSubjectRows, &error)) {
        return weeklyReviewError(review, error);
    }
    // 前一周只在已结束周需要：当前周不做任何周际比较。
    QList<SubjectDuration> previousSubjectRows;
    if (ended
        && !runCategoryDurations(weekStart.addDays(-7), weekStart.addDays(-1),
                                 &previousSubjectRows, &error)) {
        return weeklyReviewError(review, error);
    }

    const QMap<QDate, int> goals = AppSettings::instance()->dailyFocusGoalsBetween(weekStart, weekEnd);

    // —— 目标：只统计已经结束、且有有效目标的逻辑日 ——
    // 今天无论是否达标都不进 K、N 与两项合计：进行中的一天算不上达标或未达标，单独给进度。
    const QDate lastEndedDay = ended ? weekEnd : logicalToday.addDays(-1);
    qint64 goalDays = 0;
    qint64 metDays = 0;
    qint64 goalMinutesTotal = 0;
    qint64 goalActualSecondsTotal = 0;
    QVariantList goalDayList;
    // F1 候选：比例最低的一天；比例相同保留较早日期（按日期升序遍历，只在严格更低时替换）。
    QDate shortfallDate;
    qint64 shortfallGoalMinutes = 0;
    qint64 shortfallActualSeconds = 0;
    for (auto it = goals.constBegin(); it != goals.constEnd(); ++it) {
        if (it.key() > lastEndedDay) {
            break;
        }
        const qint64 goalMinutes = it.value();
        const qint64 actualSeconds = dailySeconds.value(it.key().toString(Qt::ISODate), 0);
        // 用原始秒数与目标分钟 × 60 比较，展示时的分钟取整不能改变达标判断。
        const bool met = actualSeconds >= goalMinutes * 60;
        ++goalDays;
        metDays += met ? 1 : 0;
        goalMinutesTotal += goalMinutes;
        goalActualSecondsTotal += actualSeconds;

        QVariantMap day;
        day.insert(QStringLiteral("date"), it.key().toString(Qt::ISODate));
        day.insert(QStringLiteral("goalMinutes"), goalMinutes);
        day.insert(QStringLiteral("actualSeconds"), actualSeconds);
        day.insert(QStringLiteral("met"), met);
        goalDayList.append(day);

        const bool belowThreshold = actualSeconds * 100 < goalMinutes * 60 * kGoalShortfallPercent;
        // actual / goal 更低 ⇔ actual × 已选目标 < 已选实际 × goal（都是正整数，交叉相乘不失真）。
        if (belowThreshold
            && (!shortfallDate.isValid()
                || actualSeconds * shortfallGoalMinutes < shortfallActualSeconds * goalMinutes)) {
            shortfallDate = it.key();
            shortfallGoalMinutes = goalMinutes;
            shortfallActualSeconds = actualSeconds;
        }
    }
    QVariantMap goal;
    goal.insert(QStringLiteral("goalDays"), goalDays);
    goal.insert(QStringLiteral("metDays"), metDays);
    goal.insert(QStringLiteral("goalMinutesTotal"), goalMinutesTotal);
    goal.insert(QStringLiteral("actualSecondsTotal"), goalActualSecondsTotal);
    goal.insert(QStringLiteral("days"), goalDayList);
    review.insert(QStringLiteral("goal"), goal);

    QVariantMap todayGoal;
    if (!ended) {
        const qint64 goalMinutes = goals.value(logicalToday, 0);
        if (goalMinutes > 0) {
            const qint64 actualSeconds = dailySeconds.value(logicalTodayIso, 0);
            todayGoal.insert(QStringLiteral("date"), logicalTodayIso);
            todayGoal.insert(QStringLiteral("goalMinutes"), goalMinutes);
            todayGoal.insert(QStringLiteral("actualSeconds"), actualSeconds);
            todayGoal.insert(QStringLiteral("progressPercent"),
                             static_cast<double>(actualSeconds) * 100.0 / (goalMinutes * 60));
        }
    }
    review.insert(QStringLiteral("todayGoal"), todayGoal);

    // —— 整体科目（供 F2）：同名科目可能因快照颜色不同分成多行，按名称合并 ——
    struct SubjectTotal
    {
        QString color;
        qint64 seconds = 0;
        qint64 colorSeconds = -1;
    };
    auto mergeSubjects = [](const QList<SubjectDuration>& rows, qint64* total) {
        QMap<QString, SubjectTotal> merged;
        *total = 0;
        for (const SubjectDuration& row : rows) {
            SubjectTotal& entry = merged[row.name];
            entry.seconds += row.seconds;
            // 颜色取该科里投入最多的那一行。
            if (row.seconds > entry.colorSeconds) {
                entry.color = row.color;
                entry.colorSeconds = row.seconds;
            }
            *total += row.seconds;
        }
        return merged;
    };
    qint64 currentTotalSeconds = 0;
    qint64 previousTotalSeconds = 0;
    const QMap<QString, SubjectTotal> currentSubjects =
        mergeSubjects(currentSubjectRows, &currentTotalSeconds);
    const QMap<QString, SubjectTotal> previousSubjects =
        mergeSubjects(previousSubjectRows, &previousTotalSeconds);
    // 两周都有投入才谈得上占比变化；当前周不做周际比较。
    const bool sharesComparable = ended && currentTotalSeconds > 0 && previousTotalSeconds > 0;

    QStringList subjectNames = currentSubjects.keys();
    for (const QString& name : previousSubjects.keys()) {
        if (!currentSubjects.contains(name)) {
            subjectNames.append(name);
        }
    }
    // 展示顺序：本周投入多的在前，同投入按名称（QString 比较与系统区域设置无关）。
    std::sort(subjectNames.begin(), subjectNames.end(),
              [&currentSubjects](const QString& a, const QString& b) {
                  const qint64 sa = currentSubjects.value(a).seconds;
                  const qint64 sb = currentSubjects.value(b).seconds;
                  if (sa != sb) {
                      return sa > sb;
                  }
                  return a < b;
              });

    QVariantList subjectList;
    QString shareChangeSubject;
    qint64 shareChangeNumerator = -1;
    for (const QString& name : std::as_const(subjectNames)) {
        const qint64 current = currentSubjects.value(name).seconds;
        const qint64 previous = previousSubjects.value(name).seconds;
        const QString color = currentSubjects.contains(name) ? currentSubjects.value(name).color
                                                             : previousSubjects.value(name).color;
        const bool pseudoSubject = name == kUnlinkedSubjectName || name == kUncategorizedSubjectName;

        QVariantMap subject;
        subject.insert(QStringLiteral("name"), name);
        subject.insert(QStringLiteral("color"), color);
        subject.insert(QStringLiteral("currentSeconds"), current);
        subject.insert(QStringLiteral("currentSharePercent"),
                       currentTotalSeconds > 0
                           ? static_cast<double>(current) * 100.0 / currentTotalSeconds : 0.0);
        subject.insert(QStringLiteral("pseudoSubject"), pseudoSubject);
        if (ended) {
            subject.insert(QStringLiteral("previousSeconds"), previous);
            subject.insert(QStringLiteral("deltaSeconds"), current - previous);
        } else {
            subject.insert(QStringLiteral("previousSeconds"), QVariant());
            subject.insert(QStringLiteral("deltaSeconds"), QVariant());
        }
        if (sharesComparable) {
            const double currentShare = static_cast<double>(current) * 100.0 / currentTotalSeconds;
            const double previousShare = static_cast<double>(previous) * 100.0 / previousTotalSeconds;
            subject.insert(QStringLiteral("previousSharePercent"), previousShare);
            subject.insert(QStringLiteral("deltaPoints"), currentShare - previousShare);
        } else {
            subject.insert(QStringLiteral("previousSharePercent"), QVariant());
            subject.insert(QStringLiteral("deltaPoints"), QVariant());
        }
        subjectList.append(subject);

        // F2：占比差 = (本周 × 前周总 − 前周 × 本周总) / (本周总 × 前周总)。
        // 所有候选分母相同，比较分子绝对值即可；门槛同样交叉相乘，不经过浮点。
        if (!sharesComparable || pseudoSubject
            || currentTotalSeconds < kShareChangeMinimumWeekSeconds
            || previousTotalSeconds < kShareChangeMinimumWeekSeconds) {
            continue;
        }
        const qint64 numerator =
            qAbs(current * previousTotalSeconds - previous * currentTotalSeconds);
        const bool enoughPoints = numerator * 100
            >= kShareChangeMinimumPoints * currentTotalSeconds * previousTotalSeconds;
        const bool enoughSeconds = qAbs(current - previous) >= kShareChangeMinimumSubjectSeconds;
        if (!enoughPoints || !enoughSeconds) {
            continue;
        }
        if (numerator > shareChangeNumerator
            || (numerator == shareChangeNumerator && name < shareChangeSubject)) {
            shareChangeNumerator = numerator;
            shareChangeSubject = name;
        }
    }
    review.insert(QStringLiteral("subjects"), subjectList);

    // —— 预计用时对账：同一任务集合，按任务当前科目归组 ——
    struct ReconciliationRow
    {
        QString subject;
        QString color;
        qint64 plannedMinutes = 0;
        qint64 actualSeconds = 0;
        qint64 actualDisplayMinutes = 0;
    };
    QMap<QString, ReconciliationRow> rowsBySubject;
    for (const PlannedTask& task : std::as_const(plannedTasks)) {
        ReconciliationRow& row = rowsBySubject[task.subject];
        row.subject = task.subject;
        if (row.color.isEmpty()) {
            row.color = task.color;
        }
        row.plannedMinutes += task.plannedMinutes;
        row.actualSeconds += plannedTaskSeconds.value(task.taskId, 0);
    }
    // QMap 已按名称升序；下面的排序都用稳定排序，名称就是并列时的次序。
    QList<ReconciliationRow> rows = rowsBySubject.values();

    // 展示分钟：各行先向下取整，再把「合计向下取整 − 各行之和」的差额按余秒从大到小逐行补 1 分钟，
    // 保证各行之和等于合计展示分钟。比例与规则判断始终用原始秒数。
    qint64 totalPlannedMinutes = 0;
    qint64 totalActualSeconds = 0;
    qint64 flooredSum = 0;
    for (ReconciliationRow& row : rows) {
        row.actualDisplayMinutes = row.actualSeconds / 60;
        flooredSum += row.actualDisplayMinutes;
        totalPlannedMinutes += row.plannedMinutes;
        totalActualSeconds += row.actualSeconds;
    }
    const qint64 totalActualDisplayMinutes = totalActualSeconds / 60;
    QList<qsizetype> remainderOrder;
    for (qsizetype i = 0; i < rows.size(); ++i) {
        remainderOrder.append(i);
    }
    std::stable_sort(remainderOrder.begin(), remainderOrder.end(), [&rows](qsizetype a, qsizetype b) {
        return rows.at(a).actualSeconds % 60 > rows.at(b).actualSeconds % 60;
    });
    for (qint64 i = 0; i < totalActualDisplayMinutes - flooredSum && i < remainderOrder.size(); ++i) {
        rows[remainderOrder.at(i)].actualDisplayMinutes += 1;
    }
    std::stable_sort(rows.begin(), rows.end(), [](const ReconciliationRow& a, const ReconciliationRow& b) {
        return a.plannedMinutes > b.plannedMinutes;
    });

    QVariantList rowList;
    QString estimateShortfallSubject;
    qint64 estimateShortfallSeconds = -1;
    qint64 estimateShortfallPlanned = 0;
    qint64 estimateShortfallDisplayActual = 0;
    for (const ReconciliationRow& row : std::as_const(rows)) {
        QVariantMap item;
        item.insert(QStringLiteral("subject"), row.subject);
        item.insert(QStringLiteral("color"), row.color);
        item.insert(QStringLiteral("plannedMinutes"), row.plannedMinutes);
        item.insert(QStringLiteral("actualSeconds"), row.actualSeconds);
        item.insert(QStringLiteral("actualDisplayMinutes"), row.actualDisplayMinutes);
        item.insert(QStringLiteral("differenceDisplayMinutes"),
                    row.actualDisplayMinutes - row.plannedMinutes);
        // 投入／计划比，允许超过 100%，不代表任务完成率。
        item.insert(QStringLiteral("investmentRatioPercent"),
                    static_cast<double>(row.actualSeconds) * 100.0 / (row.plannedMinutes * 60));
        rowList.append(item);

        // F3：计划够量、且实际低于自身计划的 60%；取短缺秒数最多的科目，同短缺按名称。
        if (row.plannedMinutes < kEstimateMinimumPlanMinutes
            || row.actualSeconds * 100 >= row.plannedMinutes * 60 * kEstimateShortfallPercent) {
            continue;
        }
        const qint64 shortfall = row.plannedMinutes * 60 - row.actualSeconds;
        if (shortfall > estimateShortfallSeconds
            || (shortfall == estimateShortfallSeconds && row.subject < estimateShortfallSubject)) {
            estimateShortfallSeconds = shortfall;
            estimateShortfallSubject = row.subject;
            estimateShortfallPlanned = row.plannedMinutes;
            estimateShortfallDisplayActual = row.actualDisplayMinutes;
        }
    }
    QVariantMap planned;
    planned.insert(QStringLiteral("rows"), rowList);
    planned.insert(QStringLiteral("inProgress"), !ended);
    planned.insert(QStringLiteral("totalPlannedMinutes"), totalPlannedMinutes);
    planned.insert(QStringLiteral("totalActualSeconds"), totalActualSeconds);
    planned.insert(QStringLiteral("totalActualDisplayMinutes"), totalActualDisplayMinutes);
    planned.insert(QStringLiteral("totalDifferenceDisplayMinutes"),
                   totalActualDisplayMinutes - totalPlannedMinutes);
    // 计划为零时比例为空，不伪造 0%。
    planned.insert(QStringLiteral("totalInvestmentRatioPercent"),
                   totalPlannedMinutes > 0
                       ? QVariant(static_cast<double>(totalActualSeconds) * 100.0
                                  / (totalPlannedMinutes * 60))
                       : QVariant());
    review.insert(QStringLiteral("plannedTasks"), planned);

    // —— 事实：只给已结束周，按 F1 → F2 → F3 取前两条，每类最多一句，不给建议 ——
    QVariantList facts;
    if (ended) {
        if (shortfallDate.isValid()) {
            QVariantMap fact;
            fact.insert(QStringLiteral("type"), QStringLiteral("goalShortfall"));
            fact.insert(QStringLiteral("date"), shortfallDate.toString(Qt::ISODate));
            fact.insert(QStringLiteral("goalMinutes"), shortfallGoalMinutes);
            fact.insert(QStringLiteral("actualSeconds"), shortfallActualSeconds);
            fact.insert(QStringLiteral("ratioPercent"),
                        static_cast<double>(shortfallActualSeconds) * 100.0
                            / (shortfallGoalMinutes * 60));
            facts.append(fact);
        }
        if (!shareChangeSubject.isEmpty()) {
            const qint64 current = currentSubjects.value(shareChangeSubject).seconds;
            const qint64 previous = previousSubjects.value(shareChangeSubject).seconds;
            const double currentShare = static_cast<double>(current) * 100.0 / currentTotalSeconds;
            const double previousShare = static_cast<double>(previous) * 100.0 / previousTotalSeconds;
            QVariantMap fact;
            fact.insert(QStringLiteral("type"), QStringLiteral("subjectShareChange"));
            fact.insert(QStringLiteral("subject"), shareChangeSubject);
            // 用原始秒数：界面按秒向下取整显示，与同页饼图逐项取整的数值一致。
            fact.insert(QStringLiteral("currentSeconds"), current);
            fact.insert(QStringLiteral("previousSeconds"), previous);
            fact.insert(QStringLiteral("currentSharePercent"), currentShare);
            fact.insert(QStringLiteral("deltaPoints"), currentShare - previousShare);
            facts.append(fact);
        }
        if (!estimateShortfallSubject.isEmpty()) {
            QVariantMap fact;
            fact.insert(QStringLiteral("type"), QStringLiteral("estimateShortfall"));
            fact.insert(QStringLiteral("subject"), estimateShortfallSubject);
            fact.insert(QStringLiteral("plannedMinutes"), estimateShortfallPlanned);
            fact.insert(QStringLiteral("actualDisplayMinutes"), estimateShortfallDisplayActual);
            // 用展示分钟相减，句子里「计划 = 实际 + 差」按显示的数也成立。
            fact.insert(QStringLiteral("shortfallDisplayMinutes"),
                        estimateShortfallPlanned - estimateShortfallDisplayActual);
            facts.append(fact);
        } else if (totalPlannedMinutes > 0
                   && totalActualSeconds * 100
                          >= totalPlannedMinutes * 60 * kEstimateOnTrackMinimumPercent
                   && totalActualSeconds * 100
                          <= totalPlannedMinutes * 60 * kEstimateOnTrackMaximumPercent) {
            QVariantMap fact;
            fact.insert(QStringLiteral("type"), QStringLiteral("estimateOnTrack"));
            fact.insert(QStringLiteral("ratioPercent"),
                        static_cast<double>(totalActualSeconds) * 100.0 / (totalPlannedMinutes * 60));
            facts.append(fact);
        }
        while (facts.size() > 2) {
            facts.removeLast();
        }
    }
    review.insert(QStringLiteral("facts"), facts);

    qint64 weekSeconds = 0;
    for (auto it = dailySeconds.constBegin(); it != dailySeconds.constEnd(); ++it) {
        weekSeconds += it.value();
    }
    // hasData：本周有有效专注、有效目标或计划。目标只看已结束的日子与今天，未来日期的目标不算。
    review.insert(QStringLiteral("hasData"),
                  weekSeconds > 0 || goalDays > 0 || !todayGoal.isEmpty() || !plannedTasks.isEmpty());
    // hasDisplayContent 由可展示块决定：只有专注记录而没有目标、计划、事实时，卡片没有可说的。
    review.insert(QStringLiteral("hasDisplayContent"),
                  goalDays > 0 || !todayGoal.isEmpty() || !rowList.isEmpty() || !facts.isEmpty());
    return review;
}

QVariantMap StatisticsService::getWeeklyReview() const
{
    // 便捷入口：只取一次逻辑今天，同一个日期既定周、又判断周期。
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return getWeeklyReview(today.addDays(1 - today.dayOfWeek()), today.toString(Qt::ISODate));
}
