#include "FocusHistoryService.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>
#include <QVariantMap>

namespace {
bool isValidHistoryYear(int year)
{
    return year >= 2000 && year <= 2100;
}
}

FocusHistoryService::FocusHistoryService(QObject* parent)
    : QObject(parent)
{
}

FocusHistoryService* FocusHistoryService::instance()
{
    static FocusHistoryService service;
    return &service;
}

QVariantList FocusHistoryService::getMonthSessions(int year, int month) const
{
    if (!isValidHistoryYear(year) || month < 1 || month > 12) {
        m_lastError = QStringLiteral("日期范围无效");
        qWarning() << "Failed to get month focus sessions: invalid year/month" << year << month;
        return QVariantList();
    }

    const QDate startDate(year, month, 1);
    if (!startDate.isValid()) {
        m_lastError = QStringLiteral("日期范围无效");
        qWarning() << "Failed to get month focus sessions: invalid date" << year << month;
        return QVariantList();
    }

    // 使用左闭右开区间：[当月第一天, 下月第一天)。跨年由 QDate 处理，避免手写 12 月边界。
    const QDate nextMonthStart = startDate.addMonths(1);
    return querySessions(QStringLiteral("date(fs.start_time) >= ? AND date(fs.start_time) < ?"),
                         QVariantList{startDate.toString(Qt::ISODate), nextMonthStart.toString(Qt::ISODate)});
}

QVariantList FocusHistoryService::getDaySessions(const QDate& date) const
{
    if (!date.isValid()) {
        m_lastError = QStringLiteral("日期无效");
        qWarning() << "Failed to get day focus sessions: invalid date";
        return QVariantList();
    }

    return querySessions(QStringLiteral("date(fs.start_time) = ?"),
                         QVariantList{date.toString(Qt::ISODate)});
}

int FocusHistoryService::getDayTotalDuration(const QDate& date) const
{
    if (!date.isValid()) {
        m_lastError = QStringLiteral("日期无效");
        qWarning() << "Failed to get day focus duration: invalid date";
        return 0;
    }

    int totalDuration = 0;
    const QVariantList sessions = getDaySessions(date);
    for (const QVariant& sessionValue : sessions) {
        // 这里复用返回给 QML 的 durationSeconds 字段，避免日统计和明细查询出现口径分裂。
        totalDuration += sessionValue.toMap().value(QStringLiteral("durationSeconds")).toInt();
    }

    return totalDuration;
}

QString FocusHistoryService::formatDuration(int seconds) const
{
    if (seconds < 60) {
        return QStringLiteral("0分钟");
    }

    const int minutes = seconds / 60;
    if (minutes < 60) {
        return QStringLiteral("%1分钟").arg(minutes);
    }

    const int hours = minutes / 60;
    const int remainMinutes = minutes % 60;
    if (remainMinutes == 0) {
        return QStringLiteral("%1小时").arg(hours);
    }

    return QStringLiteral("%1小时%2分").arg(hours).arg(remainMinutes);
}

QString FocusHistoryService::lastError() const
{
    return m_lastError;
}

int FocusHistoryService::invalidSessionCount() const
{
    m_lastError.clear();

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        qWarning() << "Failed to count invalid focus sessions: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions "
        "WHERE end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration < :minDuration"));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec() || !query.next()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to count invalid focus sessions:" << query.lastError().text();
        return 0;
    }

    return query.value(0).toInt();
}

int FocusHistoryService::cleanupInvalidSessions()
{
    m_lastError.clear();

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        qWarning() << "Failed to cleanup invalid focus sessions: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    // 只删除已经结束但低于有效门槛的记录；正在进行的 NULL duration 会话不能碰，否则会中断当前计时。
    query.prepare(QStringLiteral(
        "DELETE FROM focus_sessions "
        "WHERE end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration < :minDuration"));
    query.bindValue(QStringLiteral(":minDuration"), FocusSessionRules::kMinimumValidDurationSeconds);

    if (!query.exec()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to cleanup invalid focus sessions:" << query.lastError().text();
        return 0;
    }

    return query.numRowsAffected();
}

QVariantList FocusHistoryService::querySessions(const QString& whereClause, const QVariantList& bindValues) const
{
    m_lastError.clear();
    QVariantList sessions;

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        qWarning() << "Failed to query focus history: database is not open";
        return sessions;
    }

    QString sql = QStringLiteral(
        "SELECT "
        "fs.id AS id, "
        "fs.task_id AS task_id, "
        "COALESCE(NULLIF(t.title, ''), '未知任务') AS task_title, "
        "fs.start_time AS start_time, "
        "fs.end_time AS end_time, "
        "fs.duration AS duration_seconds, "
        "date(fs.start_time) AS session_date "
        "FROM focus_sessions fs "
        "LEFT JOIN tasks t ON fs.task_id = t.id ");

    // 历史页只展示“已经结束且达到有效门槛”的记录，0~2 分钟的误触记录不参与任何历史口径。
    sql += QStringLiteral(
        "WHERE fs.end_time IS NOT NULL "
        "AND fs.duration IS NOT NULL "
        "AND fs.duration >= %1 ")
               .arg(FocusSessionRules::kMinimumValidDurationSeconds);

    const QString normalizedWhereClause = whereClause.trimmed();
    if (!normalizedWhereClause.isEmpty()) {
        sql += QStringLiteral("AND (");
        sql += whereClause;
        sql += QStringLiteral(") ");
    }

    sql += QStringLiteral("ORDER BY fs.start_time ASC, fs.id ASC");

    QSqlQuery query(db);
    query.prepare(sql);

    for (int index = 0; index < bindValues.size(); ++index) {
        query.bindValue(index, bindValues.at(index));
    }

    if (!query.exec()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to query focus history:" << query.lastError().text();
        return sessions;
    }

    while (query.next()) {
        QVariantMap session;
        session.insert(QStringLiteral("id"), query.value(QStringLiteral("id")).toInt());

        // 删除任务后 task_id 会被置为 NULL。QML 需要能区分“无任务”和真正的数字编号。
        const QVariant taskId = query.value(QStringLiteral("task_id"));
        session.insert(QStringLiteral("taskId"), taskId.isNull() ? QVariant() : taskId.toInt());

        // taskTitle 是界面直接展示的文案，LEFT JOIN 查不到任务时统一回退到“未知任务”。
        session.insert(QStringLiteral("taskTitle"), query.value(QStringLiteral("task_title")).toString());
        session.insert(QStringLiteral("startTime"), query.value(QStringLiteral("start_time")).toString());
        session.insert(QStringLiteral("endTime"), query.value(QStringLiteral("end_time")).toString());
        session.insert(QStringLiteral("durationSeconds"), query.value(QStringLiteral("duration_seconds")).toInt());
        session.insert(QStringLiteral("date"), query.value(QStringLiteral("session_date")).toString());
        sessions.append(session);
    }

    return sessions;
}
