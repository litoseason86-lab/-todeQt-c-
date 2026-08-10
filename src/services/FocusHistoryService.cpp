#include "FocusHistoryService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDateTime>
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
    return querySessions(QStringLiteral("date(fs.start_time, :shift) >= :startDate "
                                        "AND date(fs.start_time, :shift) < :endDate"),
                         QVariantMap{{QStringLiteral(":startDate"), startDate.toString(Qt::ISODate)},
                                     {QStringLiteral(":endDate"), nextMonthStart.toString(Qt::ISODate)}});
}

QVariantList FocusHistoryService::getDaySessions(const QDate& date) const
{
    if (!date.isValid()) {
        m_lastError = QStringLiteral("日期无效");
        qWarning() << "Failed to get day focus sessions: invalid date";
        return QVariantList();
    }

    return querySessions(QStringLiteral("date(fs.start_time, :shift) = :date"),
                         QVariantMap{{QStringLiteral(":date"), date.toString(Qt::ISODate)}});
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

QVariantList FocusHistoryService::querySessions(const QString& whereClause,
                                                const QVariantMap& namedBinds) const
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
        "date(fs.start_time, :shift) AS session_date "
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

    query.bindValue(QStringLiteral(":shift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    for (auto it = namedBinds.constBegin(); it != namedBinds.constEnd(); ++it) {
        query.bindValue(it.key(), it.value());
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

// ── 手工补录 / 修改 / 删除 ──

bool FocusHistoryService::validateManualSession(const QDateTime& startTime,
                                                int durationMinutes,
                                                int excludeSessionId) const
{
    if (!startTime.isValid()) {
        m_lastError = QStringLiteral("开始时间无效");
        return false;
    }
    // 低于有效门槛的记录本来就不计入统计，存进去只是噪音，还会被"清理无效记录"顺手删掉。
    const int minimumMinutes = FocusSessionRules::kMinimumValidDurationSeconds / 60;
    if (durationMinutes < minimumMinutes) {
        m_lastError = QStringLiteral("时长至少 %1 分钟").arg(minimumMinutes);
        return false;
    }
    if (durationMinutes > 24 * 60) {
        m_lastError = QStringLiteral("单条记录不能超过 24 小时");
        return false;
    }

    const QDateTime endTime = startTime.addSecs(durationMinutes * 60);
    if (endTime > QDateTime::currentDateTime()) {
        m_lastError = QStringLiteral("结束时间不能晚于现在");
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    // 重叠判定：两段区间相交当且仅当 A.start < B.end 且 B.start < A.end。
    // 不拦的话，同一段时间被两条记录覆盖，统计凭空多出时长，而且事后无从察觉。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions "
        "WHERE id <> :excludeId "
        "AND end_time IS NOT NULL "
        "AND datetime(start_time) < datetime(:endTime) "
        "AND datetime(end_time) > datetime(:startTime)"));
    query.bindValue(QStringLiteral(":excludeId"), excludeSessionId);
    query.bindValue(QStringLiteral(":startTime"), startTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODate));
    if (!query.exec() || !query.next()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to check session overlap:" << query.lastError().text();
        return false;
    }
    if (query.value(0).toInt() > 0) {
        m_lastError = QStringLiteral("这段时间已有专注记录");
        return false;
    }
    return true;
}

int FocusHistoryService::addManualSession(int taskId,
                                          const QVariant& startDateTimeValue,
                                          int durationMinutes)
{
    m_lastError.clear();

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        return -1;
    }

    const QDateTime startTime = startDateTimeValue.toDateTime();
    if (!validateManualSession(startTime, durationMinutes, -1)) {
        return -1;
    }

    const QDateTime endTime = startTime.addSecs(durationMinutes * 60);
    QSqlQuery query(db);
    if (taskId > 0) {
        // 科目快照与 FocusTimer 的写入路径取同一套回退链：任务后来改科目或被删除，
        // 都不能改写这条记录的历史归属。
        query.prepare(QStringLiteral(R"SQL(
            INSERT INTO focus_sessions (
                task_id, start_time, end_time, duration, mode, pomodoro_completed,
                category_id_snapshot, category_name_snapshot, category_color_snapshot
            )
            SELECT :taskId, :startTime, :endTime, :duration, 0, 0,
                   COALESCE(t.category_id, legacy_category.id),
                   COALESCE(current_category.name, legacy_category.name, t.category, ''),
                   COALESCE(current_category.color, legacy_category.color, '')
            FROM tasks t
            LEFT JOIN categories current_category ON t.category_id = current_category.id
            LEFT JOIN categories legacy_category
                   ON t.category_id IS NULL AND legacy_category.name = t.category
            WHERE t.id = :taskId
        )SQL"));
        query.bindValue(QStringLiteral(":taskId"), taskId);
    } else {
        query.prepare(QStringLiteral(
            "INSERT INTO focus_sessions "
            "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
            "VALUES (NULL, :startTime, :endTime, :duration, 0, 0)"));
    }
    query.bindValue(QStringLiteral(":startTime"), startTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":duration"), durationMinutes * 60);

    if (!query.exec()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to add manual focus session:" << query.lastError().text();
        return -1;
    }
    if (query.numRowsAffected() <= 0) {
        // taskId 指向不存在的任务时 SELECT 没有行，INSERT 什么也没写。
        m_lastError = QStringLiteral("任务不存在");
        return -1;
    }

    const int newId = query.lastInsertId().toInt();
    emit historyChanged();
    return newId;
}

bool FocusHistoryService::updateSession(int sessionId,
                                        const QVariant& startDateTimeValue,
                                        int durationMinutes)
{
    m_lastError.clear();

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        return false;
    }
    if (sessionId <= 0) {
        m_lastError = QStringLiteral("记录编号无效");
        return false;
    }

    const QDateTime startTime = startDateTimeValue.toDateTime();
    if (!validateManualSession(startTime, durationMinutes, sessionId)) {
        return false;
    }

    QSqlQuery query(db);
    // 只改时间与时长，不动 mode/pomodoro_completed：一条原本自然到点的番茄被改过
    // 时长后仍然是那次番茄，不该因为"被编辑过"就降级；反之补录出来的自由计时
    // 也不会因为改了时长就升级成番茄。
    // end_time IS NOT NULL 挡住正在进行的会话——改它会让当前计时对不上。
    query.prepare(QStringLiteral(
        "UPDATE focus_sessions SET start_time = :startTime, end_time = :endTime, "
        "duration = :duration "
        "WHERE id = :id AND end_time IS NOT NULL"));
    query.bindValue(QStringLiteral(":id"), sessionId);
    query.bindValue(QStringLiteral(":startTime"), startTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endTime"),
                    startTime.addSecs(durationMinutes * 60).toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":duration"), durationMinutes * 60);

    if (!query.exec()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to update focus session:" << query.lastError().text();
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        m_lastError = QStringLiteral("记录不存在或正在进行中");
        return false;
    }

    emit historyChanged();
    return true;
}

bool FocusHistoryService::deleteSession(int sessionId)
{
    m_lastError.clear();

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        return false;
    }
    if (sessionId <= 0) {
        m_lastError = QStringLiteral("记录编号无效");
        return false;
    }

    QSqlQuery query(db);
    // 同样挡住正在进行的会话：删掉它会让 FocusTimer 结束时找不到自己的行。
    query.prepare(QStringLiteral(
        "DELETE FROM focus_sessions WHERE id = :id AND end_time IS NOT NULL"));
    query.bindValue(QStringLiteral(":id"), sessionId);

    if (!query.exec()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to delete focus session:" << query.lastError().text();
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        m_lastError = QStringLiteral("记录不存在或正在进行中");
        return false;
    }

    emit historyChanged();
    return true;
}
