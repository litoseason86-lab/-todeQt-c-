#include "FocusHistoryService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <algorithm>

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

// 记录改挂到别的任务时，科目快照要换成新任务此刻的科目。
// 回退链与 FocusTimer、addManualSession 的写入路径保持一致：先看关联科目，再退回旧版文本科目。
struct CategorySnapshot
{
    QVariant id;
    QString name;
    QString color;
};

bool loadCategorySnapshot(QSqlDatabase& db, int taskId, CategorySnapshot* snapshot, QString* error)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT COALESCE(t.category_id, legacy.id), COALESCE(c.name, legacy.name, t.category, ''), "
        "COALESCE(c.color, legacy.color, '') FROM tasks t "
        "LEFT JOIN categories c ON c.id = t.category_id "
        "LEFT JOIN categories legacy ON t.category_id IS NULL AND legacy.name = t.category WHERE t.id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec() || !query.next()) {
        *error = QStringLiteral("任务不存在");
        return false;
    }
    snapshot->id = query.value(0);
    snapshot->name = query.value(1).toString();
    snapshot->color = query.value(2).toString();
    return true;
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

QVariantList FocusHistoryService::getDayTimeline(const QDate& date) const
{
    QVariantList sessions = getDaySessions(date);
    if (!m_lastError.isEmpty()) {
        return {};
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "SELECT id, start_time, end_time, duration, manual FROM rest_sessions "
        "WHERE date(start_time, :shift) = :date ORDER BY start_time, id"));
    query.bindValue(QStringLiteral(":shift"), LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    if (!query.exec()) {
        m_lastError = query.lastError().text();
        return {};
    }
    while (query.next()) {
        sessions.append(QVariantMap{
            {QStringLiteral("id"), query.value(0)},
            {QStringLiteral("isRest"), true},
            {QStringLiteral("taskTitle"), query.value(4).toBool() ? tr("休息") : tr("番茄休息")},
            {QStringLiteral("startTime"), query.value(1)},
            {QStringLiteral("endTime"), query.value(2)},
            {QStringLiteral("durationSeconds"), query.value(3)},
            {QStringLiteral("date"), date.toString(Qt::ISODate)}
        });
    }
    // 按真实时间比较，避免带毫秒与不带毫秒的旧记录在字符串排序时错位。
    std::stable_sort(sessions.begin(), sessions.end(), [](const QVariant& left, const QVariant& right) {
        return QDateTime::fromString(left.toMap().value(QStringLiteral("startTime")).toString(), Qt::ISODate)
            < QDateTime::fromString(right.toMap().value(QStringLiteral("startTime")).toString(), Qt::ISODate);
    });
    return sessions;
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
    if (durationMinutes < 0 || durationMinutes > 24 * 60) {
        m_lastError = QStringLiteral("单条记录时长应在 3 分钟到 24 小时之间");
        return false;
    }
    return validateSessionInterval(startTime, startTime.addSecs(durationMinutes * 60),
                                   durationMinutes * 60, excludeSessionId);
}

bool FocusHistoryService::validateSessionInterval(const QDateTime& startTime,
                                                  const QDateTime& endTime,
                                                  int durationSeconds,
                                                  int excludeSessionId, bool sourceRest, bool targetRest,
                                                  bool checkOverlap) const
{
    if (!startTime.isValid() || !endTime.isValid() || endTime <= startTime) {
        m_lastError = QStringLiteral("开始或结束时间无效");
        return false;
    }
    if (durationSeconds < (targetRest ? 1 : FocusSessionRules::kMinimumValidDurationSeconds)) {
        m_lastError = targetRest ? QStringLiteral("休息时长至少 1 秒") : QStringLiteral("时长至少 3 分钟");
        return false;
    }
    if (durationSeconds > 24 * 60 * 60) {
        m_lastError = QStringLiteral("单条记录不能超过 24 小时");
        return false;
    }
    if (endTime > QDateTime::currentDateTime()) {
        m_lastError = QStringLiteral("结束时间不能晚于现在");
        return false;
    }

    if (!checkOverlap) {
        // 只改归属或类型时区间没动过，再跑一次重叠校验只会被历史遗留的重叠挡住，
        // 让用户连纠正归属都做不到；此时这条记录占用的时间和校验前完全一致。
        return true;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    // 重叠判定：两段区间相交当且仅当 A.start < B.end 且 B.start < A.end。
    // 不拦的话，同一段时间被两条记录覆盖，统计凭空多出时长，而且事后无从察觉。
    //
    // **正在进行的会话（end_time IS NULL）同样占用时间**，用「现在」当它的结束点。
    // 这里最初写了 end_time IS NOT NULL——那是从"不许改动进行中的行"那条守卫抄来的，
    // 两者要求正好相反：不许改它，但必须承认它占着那段时间。漏掉的后果不是当场出错，
    // 而是等这次专注结束写入 end_time 之后，库里静静多出一对重叠记录。
    //
    // 「现在」由 C++ 绑入而不用 SQLite 的 datetime('now')：后者是 UTC，
    // 而 start_time 存的是本地时间，混用会在非零时区整体错开。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions "
        "WHERE id <> :excludeId "
        "AND julianday(start_time) < julianday(:endTime) "
        "AND julianday(COALESCE(end_time, :now)) > julianday(:startTime)"));
    query.bindValue(QStringLiteral(":excludeId"), sourceRest ? -1 : excludeSessionId);
    query.bindValue(QStringLiteral(":startTime"), startTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":now"), QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
    if (!query.exec() || !query.next()) {
        m_lastError = query.lastError().text();
        qWarning() << "Failed to check session overlap:" << query.lastError().text();
        return false;
    }
    if (query.value(0).toInt() > 0) {
        m_lastError = QStringLiteral("这段时间已有专注记录");
        return false;
    }
    // 两种记录占用同一条时间线，但 ID 来自不同表，必须分别排除被编辑的原记录。
    //
    // 休息的 end_time 可能包含暂停与关机时段（旧数据尤其如此），按它判定占用会让
    // 一次忘记结束的休息锁死整段时间；这里一律按「起点 + 实际时长」算有效占用。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM rest_sessions WHERE id <> :excludeId "
        "AND julianday(start_time) < julianday(:end) "
        "AND julianday(start_time) + duration / 86400.0 > julianday(:start)"));
    query.bindValue(QStringLiteral(":excludeId"), sourceRest ? excludeSessionId : -1);
    query.bindValue(QStringLiteral(":start"), startTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":end"), endTime.toString(Qt::ISODateWithMs));
    if (!query.exec() || !query.next()) {
        m_lastError = query.lastError().text();
        return false;
    }
    if (query.value(0).toInt() > 0) {
        m_lastError = QStringLiteral("这段时间已有休息记录，请先调整该记录或直接修改其类型");
        return false;
    }
    // 正在进行的休息同理按「起点 + 已计秒数」占用：暂停中的休息不该锁死它之后的整段时间。
    // 旧快照没有起点，用最后检查点倒推，占用区间退化为 [updated_at - elapsed, updated_at]。
    query.prepare(QStringLiteral(
        "SELECT COUNT(*) FROM active_focus_state WHERE phase IN (2, 3) "
        "AND COALESCE(julianday(start_time), julianday(updated_at) - elapsed_seconds / 86400.0) "
        "    < julianday(:end) "
        "AND COALESCE(julianday(start_time) + elapsed_seconds / 86400.0, julianday(updated_at)) "
        "    > julianday(:start)"));
    query.bindValue(QStringLiteral(":start"), startTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":end"), endTime.toString(Qt::ISODateWithMs));
    if (!query.exec() || !query.next()) {
        m_lastError = query.lastError().text();
        return false;
    }
    if (query.value(0).toInt() > 0) {
        m_lastError = QStringLiteral("这段时间有正在进行的休息，请先结束休息");
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
    // 与重叠校验使用同样的毫秒精度；落库时截秒会把相邻记录变成重叠。
    query.bindValue(QStringLiteral(":startTime"), startTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODateWithMs));
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
    if (durationMinutes < 0 || durationMinutes > 24 * 60) {
        m_lastError = QStringLiteral("单条记录时长应在 3 分钟到 24 小时之间");
        return false;
    }
    return updateSessionFields(sessionId, {
        {QStringLiteral("startTime"), startDateTimeValue},
        {QStringLiteral("durationSeconds"), durationMinutes * 60}
    });
}

bool FocusHistoryService::updateSessionFields(int sessionId, const QVariantMap& changes)
{
    return updateTimelineRecord(sessionId, false, changes);
}

bool FocusHistoryService::updateRestSessionFields(int sessionId, const QVariantMap& changes)
{
    return updateTimelineRecord(sessionId, true, changes);
}

QVariantList FocusHistoryService::getTaskOptions(const QVariant& dateValue) const
{
    m_lastError.clear();
    const QDate date = dateValue.toDate();
    QSqlQuery query(DatabaseManager::instance()->database());
    // 按与所选日期的距离排序并截断：补录哪天就先列哪天的任务。
    // 不能无上限地返回整库任务——下拉没有搜索，用久了要翻上千条才能找到当天的任务。
    query.prepare(QStringLiteral(
        "SELECT id, title, date FROM tasks "
        "ORDER BY ABS(julianday(date) - julianday(:date)) ASC, date DESC, display_order, id "
        "LIMIT :limit"));
    query.bindValue(QStringLiteral(":date"),
                    (date.isValid() ? date : LogicalDay::today(AppSettings::instance()->dayStartHour()))
                        .toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":limit"), kTaskOptionLimit);
    if (!query.exec()) {
        m_lastError = query.lastError().text();
        return {};
    }
    QVariantList result;
    while (query.next()) {
        result.append(QVariantMap{{QStringLiteral("id"), query.value(0)},
            {QStringLiteral("title"), query.value(1).toString() + QStringLiteral(" · ") + query.value(2).toString()}});
    }
    return result;
}

bool FocusHistoryService::updateTimelineRecord(int sessionId, bool sourceRest, const QVariantMap& changes)
{
    m_lastError.clear();
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        return false;
    }
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        if (it.key() != QStringLiteral("startTime") && it.key() != QStringLiteral("durationSeconds")
            && it.key() != QStringLiteral("taskId") && it.key() != QStringLiteral("isRest")) {
            m_lastError = QStringLiteral("不支持的记录字段");
            return false;
        }
    }
    // 表名完全由内部布尔值决定，外部输入只能通过绑定传入，不能成为 SQL 结构。
    const QString sourceTable = sourceRest ? QStringLiteral("rest_sessions") : QStringLiteral("focus_sessions");
    QSqlQuery original(db);
    original.prepare(QStringLiteral("SELECT * FROM %1 WHERE id = :id AND end_time IS NOT NULL").arg(sourceTable));
    original.bindValue(QStringLiteral(":id"), sessionId);
    if (!original.exec() || !original.next()) {
        m_lastError = QStringLiteral("记录不存在或正在进行中");
        return false;
    }
    if (changes.isEmpty())
        return true;
    const bool targetRest = changes.contains(QStringLiteral("isRest"))
        ? changes.value(QStringLiteral("isRest")).toBool() : sourceRest;
    const QDateTime oldStart = QDateTime::fromString(original.value("start_time").toString(), Qt::ISODate);
    const QDateTime oldEnd = QDateTime::fromString(original.value("end_time").toString(), Qt::ISODate);
    const QDateTime start = changes.contains(QStringLiteral("startTime"))
        ? changes.value(QStringLiteral("startTime")).toDateTime() : oldStart;
    bool durationOk = true;
    const int duration = changes.contains(QStringLiteral("durationSeconds"))
        ? changes.value(QStringLiteral("durationSeconds")).toInt(&durationOk) : original.value("duration").toInt();
    const QDateTime end = changes.contains(QStringLiteral("durationSeconds"))
        ? start.addSecs(duration) : oldEnd.addMSecs(oldStart.msecsTo(start));
    // 仅改归属或类型时也保留精度和暂停跨度；类型转换与原记录删除必须一起提交。
    const bool intervalChanged = changes.contains(QStringLiteral("startTime"))
        || changes.contains(QStringLiteral("durationSeconds"));
    // 休息转专注会把占用从「起点 + 时长」放大到整段区间（含暂停跨度），仍必须重新校验重叠。
    const bool needsOverlapCheck = intervalChanged || (sourceRest && !targetRest);
    if (!durationOk || !validateSessionInterval(start, end, duration, sessionId, sourceRest, targetRest,
                                                needsOverlapCheck)) {
        if (m_lastError.isEmpty()) m_lastError = QStringLiteral("时长无效");
        return false;
    }
    QVariant taskId = sourceRest ? QVariant() : original.value("task_id");
    CategorySnapshot snapshot{sourceRest ? QVariant() : original.value("category_id_snapshot"),
                              sourceRest ? QStringLiteral("") : original.value("category_name_snapshot").toString(),
                              sourceRest ? QStringLiteral("") : original.value("category_color_snapshot").toString()};
    if (!targetRest && changes.contains(QStringLiteral("taskId"))) {
        const int selectedId = changes.value(QStringLiteral("taskId")).toInt();
        taskId = selectedId > 0 ? QVariant(selectedId) : QVariant();
        snapshot = CategorySnapshot{};
        if (selectedId > 0 && !loadCategorySnapshot(db, selectedId, &snapshot, &m_lastError)) {
            return false;
        }
    }
    if (!db.transaction()) {
        m_lastError = db.lastError().text();
        return false;
    }
    QSqlQuery write(db);
    QStringList columns{QStringLiteral("start_time"), QStringLiteral("end_time"), QStringLiteral("duration")};
    QVariantList values{
        changes.contains(QStringLiteral("startTime")) ? start.toString(Qt::ISODateWithMs) : original.value("start_time"),
        changes.contains(QStringLiteral("startTime")) || changes.contains(QStringLiteral("durationSeconds"))
            ? end.toString(Qt::ISODateWithMs) : original.value("end_time"), duration};
    if (targetRest) {
        columns << QStringLiteral("manual");
        values << (sourceRest ? original.value("manual") : QVariant(1));
    } else {
        columns << QStringLiteral("task_id") << QStringLiteral("category_id_snapshot")
                << QStringLiteral("category_name_snapshot") << QStringLiteral("category_color_snapshot")
                << QStringLiteral("mode") << QStringLiteral("pomodoro_completed");
        // 修正原专注归属保留完成事实；从休息转为专注只能算自由补录，不能凭空产生番茄。
        values << taskId << snapshot.id << snapshot.name << snapshot.color
               << (sourceRest ? QVariant(0) : original.value("mode"))
               << (sourceRest ? QVariant(0) : original.value("pomodoro_completed"));
    }
    const QString targetTable = targetRest ? QStringLiteral("rest_sessions") : QStringLiteral("focus_sessions");
    QStringList fragments;
    for (const QString& column : columns)
        fragments << (sourceRest == targetRest ? column + QStringLiteral(" = ?") : QStringLiteral("?"));
    write.prepare(sourceRest == targetRest
        ? QStringLiteral("UPDATE %1 SET %2 WHERE id = ? AND end_time IS NOT NULL").arg(targetTable, fragments.join(", "))
        : QStringLiteral("INSERT INTO %1 (%2) VALUES (%3)").arg(targetTable, columns.join(", "), fragments.join(", ")));
    for (const QVariant& value : values) write.addBindValue(value);
    if (sourceRest == targetRest) write.addBindValue(sessionId);
    bool ok = write.exec() && write.numRowsAffected() == 1;
    if (!ok) m_lastError = write.lastError().text();
    if (ok && sourceRest != targetRest) {
        QSqlQuery remove(db);
        remove.prepare(QStringLiteral("DELETE FROM %1 WHERE id = :id").arg(sourceTable));
        remove.bindValue(QStringLiteral(":id"), sessionId);
        ok = remove.exec() && remove.numRowsAffected() == 1;
        if (!ok) m_lastError = remove.lastError().text();
    }
    if (!ok || !db.commit()) {
        db.rollback();
        if (m_lastError.isEmpty()) m_lastError = QStringLiteral("保存记录失败");
        return false;
    }
    emit historyChanged();
    return true;
}

bool FocusHistoryService::deleteSession(int sessionId)
{
    return deleteTimelineRecord(sessionId, false);
}

bool FocusHistoryService::deleteRestSession(int sessionId)
{
    return deleteTimelineRecord(sessionId, true);
}

bool FocusHistoryService::deleteTimelineRecord(int sessionId, bool isRest)
{
    m_lastError.clear();
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        m_lastError = QStringLiteral("数据库未打开");
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM %1 WHERE id = :id AND end_time IS NOT NULL")
                  .arg(isRest ? QStringLiteral("rest_sessions") : QStringLiteral("focus_sessions")));
    query.bindValue(QStringLiteral(":id"), sessionId);
    if (!query.exec() || query.numRowsAffected() != 1) {
        m_lastError = QStringLiteral("记录不存在、正在进行中或删除失败");
        return false;
    }
    emit historyChanged();
    return true;
}
