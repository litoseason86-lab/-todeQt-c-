#include "StatisticsService.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"

#include <QDebug>
#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

namespace {
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

QVariantMap StatisticsService::getTodayStats() const
{
    const QDate today = QDate::currentDate();
    const int totalDuration = calculateTotalDuration(today);
    const int completedTasks = countCompletedTasks(today);
    const int totalTasks = countTotalTasks(today);

    QVariantMap stats;
    stats.insert(QStringLiteral("totalDuration"), totalDuration);
    stats.insert(QStringLiteral("completedTasks"), completedTasks);
    stats.insert(QStringLiteral("totalTasks"), totalTasks);
    stats.insert(QStringLiteral("completionRate"), totalTasks > 0 ? static_cast<double>(completedTasks) / totalTasks : 0.0);
    return stats;
}

QVariantList StatisticsService::getWeekStats() const
{
    QVariantList weekStats;
    const QDate today = QDate::currentDate();
    const QDate weekStart = today.addDays(1 - today.dayOfWeek());

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
        "WHERE date(f.start_time) >= :startDate "
        "AND date(f.start_time) <= :endDate "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= :minDuration "
        "AND trim(COALESCE(c.name, legacy.name, t.category, '')) != '' "
        "GROUP BY category_name, category_color "
        "ORDER BY total_duration DESC, category_name ASC"));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    QVariantList categories;
    int totalDuration = 0;

    if (!query.exec()) {
        qWarning() << "Failed to get category stats:" << query.lastError().text();
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

int StatisticsService::calculateTotalDuration(const QDate& date) const
{
    if (!date.isValid()) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to calculate total duration: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COALESCE(SUM(duration), 0) FROM focus_sessions "
        "WHERE date(start_time) = :date "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to calculate total duration:" << query.lastError().text();
        return 0;
    }

    return query.value(0).toInt();
}

int StatisticsService::countCompletedTasks(const QDate& date) const
{
    if (!date.isValid()) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count completed tasks: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE date = :date AND completed = 1"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count completed tasks:" << query.lastError().text();
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
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE date = :date"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count total tasks:" << query.lastError().text();
        return 0;
    }

    return query.value(0).toInt();
}
