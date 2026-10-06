#include "TrashStore.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlError>
#include <QSqlQuery>

namespace {
constexpr int kMaxMergeHops = 8;

QJsonValue jsonValue(const QVariant& value)
{
    if (!value.isValid() || value.isNull()) {
        return QJsonValue::Null;
    }
    switch (value.typeId()) {
    case QMetaType::QString:
        return value.toString();
    case QMetaType::Double:
    case QMetaType::Float:
        return value.toDouble();
    default:
        return static_cast<qint64>(value.toLongLong());
    }
}

QString failure(const QSqlQuery& query)
{
    return query.lastError().text();
}

// 对别的表的引用一律存 sync_id（本机编号两台不一样）。目标不存在存空串；
// 查询本身失败时写 error（调用方据此让整个 capture 失败，不能悄悄丢掉关联信息）。
QString syncIdOfLocal(QSqlDatabase& db, const QString& table, const QVariant& localId, QString* error)
{
    if (!localId.isValid() || localId.isNull()) {
        return QString();
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT sync_id FROM %1 WHERE id = :id").arg(table));
    query.bindValue(QStringLiteral(":id"), localId);
    if (!query.exec()) {
        *error = failure(query);
        return QString();
    }
    return query.next() ? query.value(0).toString() : QString();
}

QStringList syncIdsWhere(QSqlDatabase& db, const QString& table, const QString& column, int id, QString* error)
{
    QStringList result;
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT sync_id FROM %1 WHERE %2 = :id ORDER BY id").arg(table, column));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        *error = failure(query);
        return result;
    }
    while (query.next()) {
        const QString value = query.value(0).toString();
        if (!value.isEmpty()) {
            result.append(value);
        }
    }
    return result;
}

QJsonArray toArray(const QStringList& values)
{
    QJsonArray array;
    for (const QString& value : values) {
        array.append(value);
    }
    return array;
}

// 废纸篓的写入：时间用 UTC 带毫秒，两台设备时区不同也能排序和换算；
// 本地时间与逻辑日在读出时再算。
bool insertTrashRow(QSqlDatabase& db, const QString& kind, const QString& originSyncId, const QString& title,
                    QJsonObject payload, QString* error)
{
    payload.insert(QStringLiteral("v"), TrashStore::kPayloadVersion);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
        "VALUES (:kind, :origin, :title, :payload, :deletedAt)"));
    query.bindValue(QStringLiteral(":kind"), kind);
    query.bindValue(QStringLiteral(":origin"), originSyncId);
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":payload"),
                    QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact)));
    query.bindValue(QStringLiteral(":deletedAt"),
                    QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!query.exec()) {
        if (error) *error = failure(query);
        return false;
    }
    return true;
}

// 读一行；不存在返回 false 并写 error。调用方用完先 finish 再做别的写入。
bool selectRow(QSqlQuery& query, const QString& sql, int id, QString* error)
{
    query.prepare(sql);
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        if (error) *error = failure(query);
        return false;
    }
    if (!query.next()) {
        if (error) *error = TrashStore::kMissingRecord;
        return false;
    }
    return true;
}
} // namespace

namespace TrashStore {

QVariant resolveSyncId(QSqlDatabase& db, const QString& table, const QString& syncId, bool* ok)
{
    if (ok) *ok = true;
    QString current = syncId;
    for (int hop = 0; hop < kMaxMergeHops && !current.isEmpty(); ++hop) {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("SELECT id FROM %1 WHERE sync_id = :id").arg(table));
        query.bindValue(QStringLiteral(":id"), current);
        if (!query.exec()) {
            // 查询失败不等于「找不到」：恢复路径要据此整体失败，不能把科目或任务关联悄悄当成没有。
            if (ok) *ok = false;
            return QVariant();
        }
        if (query.next()) {
            return query.value(0);
        }
        query.finish();
        QSqlQuery merged(db);
        merged.prepare(QStringLiteral(
            "SELECT merged_into FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id AND kind = 'merge'"));
        merged.bindValue(QStringLiteral(":tbl"), table);
        merged.bindValue(QStringLiteral(":id"), current);
        if (!merged.exec()) {
            if (ok) *ok = false;
            return QVariant();
        }
        if (merged.next() && !merged.value(0).toString().isEmpty()) {
            current = merged.value(0).toString();
            continue;
        }
        break;
    }
    return QVariant();
}

bool captureTask(QSqlDatabase& db, int taskId, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT t.sync_id, t.title, t.category, t.category_id, c.name, "
                                  "t.estimated_minutes, t.notes, t.date, t.completed, t.completion_note, "
                                  "t.created_at, t.routine_generated FROM tasks t "
                                  "LEFT JOIN categories c ON c.id = t.category_id WHERE t.id = :id"),
                   taskId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QString title = query.value(1).toString();
    const QVariant categoryId = query.value(3);
    QJsonObject payload;
    payload.insert(QStringLiteral("title"), title);
    // 科目名取科目现名；没有科目关联时退回 tasks.category 的文本（旧版遗留的文本科目）。
    payload.insert(QStringLiteral("category_name"),
                   query.value(4).isNull() ? query.value(2).toString() : query.value(4).toString());
    payload.insert(QStringLiteral("estimated_minutes"), jsonValue(query.value(5)));
    payload.insert(QStringLiteral("notes"), query.value(6).toString());
    payload.insert(QStringLiteral("date"), query.value(7).toString());
    payload.insert(QStringLiteral("completed"), jsonValue(query.value(8)));
    payload.insert(QStringLiteral("completion_note"), query.value(9).toString());
    payload.insert(QStringLiteral("created_at"), query.value(10).toString());
    payload.insert(QStringLiteral("routine_generated"), jsonValue(query.value(11)));
    query.finish();
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), categoryId, &lookupError));
    // 删除时挂在它上面的关联：恢复时只接回仍然没有归属的。必须在调用方解除关联之前读，
    // 解除之后就查不到了。专注记录包含进行中的那条。
    payload.insert(QStringLiteral("focus_session_sync_ids"),
                   toArray(syncIdsWhere(db, QStringLiteral("focus_sessions"), QStringLiteral("task_id"), taskId, &lookupError)));
    payload.insert(QStringLiteral("gap_source_sync_ids"),
                   toArray(syncIdsWhere(db, QStringLiteral("knowledge_gaps"), QStringLiteral("source_task_id"),
                                        taskId, &lookupError)));
    payload.insert(QStringLiteral("gap_linked_sync_ids"),
                   toArray(syncIdsWhere(db, QStringLiteral("knowledge_gaps"), QStringLiteral("linked_task_id"),
                                        taskId, &lookupError)));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    return insertTrashRow(db, kKindTask, originSyncId, title, payload, error);
}

bool captureFocusSession(QSqlDatabase& db, int sessionId, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT s.sync_id, s.task_id, t.title, s.start_time, s.end_time, s.duration, "
                                  "s.mode, s.pomodoro_completed, s.category_id_snapshot, "
                                  "s.category_name_snapshot, s.category_color_snapshot FROM focus_sessions s "
                                  "LEFT JOIN tasks t ON t.id = s.task_id "
                                  "WHERE s.id = :id AND s.end_time IS NOT NULL"),
                   sessionId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QVariant taskId = query.value(1);
    const QString taskTitle = query.value(2).toString();
    const QVariant snapshotCategoryId = query.value(8);
    QJsonObject payload;
    payload.insert(QStringLiteral("task_title"), taskTitle);
    payload.insert(QStringLiteral("start_time"), query.value(3).toString());
    payload.insert(QStringLiteral("end_time"), query.value(4).toString());
    payload.insert(QStringLiteral("duration"), jsonValue(query.value(5)));
    payload.insert(QStringLiteral("mode"), jsonValue(query.value(6)));
    payload.insert(QStringLiteral("pomodoro_completed"), jsonValue(query.value(7)));
    payload.insert(QStringLiteral("category_name_snapshot"), query.value(9).toString());
    payload.insert(QStringLiteral("category_color_snapshot"), query.value(10).toString());
    query.finish();
    payload.insert(QStringLiteral("task_sync_id"), syncIdOfLocal(db, QStringLiteral("tasks"), taskId, &lookupError));
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), snapshotCategoryId, &lookupError));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    // 标题回退与时间轴一致（FocusTimeline.qml）：未关联或任务标题为空时显示「未知任务」。
    return insertTrashRow(db, kKindFocusSession, originSyncId,
                          taskTitle.isEmpty() ? QStringLiteral("未知任务") : taskTitle, payload, error);
}

bool captureRestSession(QSqlDatabase& db, int sessionId, QString* error)
{
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, start_time, end_time, duration, manual FROM rest_sessions "
                                  "WHERE id = :id AND end_time IS NOT NULL"),
                   sessionId, error)) {
        return false;
    }
    QJsonObject payload;
    payload.insert(QStringLiteral("start_time"), query.value(1).toString());
    payload.insert(QStringLiteral("end_time"), query.value(2).toString());
    payload.insert(QStringLiteral("duration"), jsonValue(query.value(3)));
    payload.insert(QStringLiteral("manual"), jsonValue(query.value(4)));
    // 标题与时间轴（FocusHistoryService）一致：主动休息叫「休息」，番茄钟自动休息叫「番茄休息」。
    const QString title = query.value(4).toInt() != 0 ? QStringLiteral("休息") : QStringLiteral("番茄休息");
    return insertTrashRow(db, kKindRestSession, query.value(0).toString(), title, payload, error);
}

bool captureKnowledgeGap(QSqlDatabase& db, int gapId, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, title, detail, category_id, source_task_id, source_task_title, "
                                  "priority, status, due_date, resolution, linked_task_id, created_at, "
                                  "resolved_at FROM knowledge_gaps WHERE id = :id"),
                   gapId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QString title = query.value(1).toString();
    const QVariant categoryId = query.value(3);
    const QVariant sourceTaskId = query.value(4);
    const QVariant linkedTaskId = query.value(10);
    QJsonObject payload;
    payload.insert(QStringLiteral("title"), title);
    payload.insert(QStringLiteral("detail"), query.value(2).toString());
    payload.insert(QStringLiteral("source_task_title"), query.value(5).toString());
    payload.insert(QStringLiteral("priority"), jsonValue(query.value(6)));
    payload.insert(QStringLiteral("status"), jsonValue(query.value(7)));
    payload.insert(QStringLiteral("due_date"), jsonValue(query.value(8)));
    payload.insert(QStringLiteral("resolution"), query.value(9).toString());
    payload.insert(QStringLiteral("created_at"), query.value(11).toString());
    payload.insert(QStringLiteral("resolved_at"), jsonValue(query.value(12)));
    query.finish();
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), categoryId, &lookupError));
    payload.insert(QStringLiteral("source_task_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("tasks"), sourceTaskId, &lookupError));
    payload.insert(QStringLiteral("linked_task_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("tasks"), linkedTaskId, &lookupError));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    return insertTrashRow(db, kKindKnowledgeGap, originSyncId, title, payload, error);
}

bool captureMemo(QSqlDatabase& db, int memoId, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, title, body, category_id, created_at FROM memos WHERE id = :id"),
                   memoId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QString title = query.value(1).toString();
    const QString body = query.value(2).toString();
    const QVariant categoryId = query.value(3);
    const QString createdAt = query.value(4).toString();
    query.finish();
    // 完全空白的备忘（新建后没写就删）没有可找回的内容，不占废纸篓。
    if (title.trimmed().isEmpty() && body.trimmed().isEmpty()) {
        return true;
    }
    // 显示标题规则同 MemoService::memoFromQuery：标题空白时严格取正文第一行。
    QString firstLine = body.section(QLatin1Char('\n'), 0, 0);
    if (firstLine.endsWith(QLatin1Char('\r'))) {
        firstLine.chop(1);
    }
    QJsonObject payload;
    payload.insert(QStringLiteral("title"), title);
    payload.insert(QStringLiteral("body"), body);
    payload.insert(QStringLiteral("created_at"), createdAt);
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), categoryId, &lookupError));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    return insertTrashRow(db, kKindMemo, originSyncId, title.trimmed().isEmpty() ? firstLine : title, payload,
                          error);
}

bool captureRoutine(QSqlDatabase& db, int routineId, bool reclaimedToday, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, title, category_id, active, weekdays, created_at, "
                                  "last_generated_date FROM routines WHERE id = :id"),
                   routineId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QString title = query.value(1).toString();
    const QVariant categoryId = query.value(2);
    QJsonObject payload;
    payload.insert(QStringLiteral("title"), title);
    payload.insert(QStringLiteral("active"), jsonValue(query.value(3)));
    payload.insert(QStringLiteral("weekdays"), jsonValue(query.value(4)));
    payload.insert(QStringLiteral("created_at"), query.value(5).toString());
    // 收回过当日实例时，生成戳存 null：恢复后当天要补生成。否则戳仍是原值，
    // 恢复后不会重复生成（用户删过当天实例，或实例因做过而留下）。
    payload.insert(QStringLiteral("last_generated_date"),
                   reclaimedToday ? QJsonValue(QJsonValue::Null) : jsonValue(query.value(6)));
    query.finish();
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), categoryId, &lookupError));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    return insertTrashRow(db, kKindRoutine, originSyncId, title, payload, error);
}

bool captureScheduleEntry(QSqlDatabase& db, int entryId, QString* error)
{
    QString lookupError;
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, title, location, weekday, start_minutes, end_minutes, "
                                  "week_start, week_end, week_parity, category_id, created_at "
                                  "FROM schedule_entries WHERE id = :id"),
                   entryId, error)) {
        return false;
    }
    const QString originSyncId = query.value(0).toString();
    const QString title = query.value(1).toString();
    const QVariant categoryId = query.value(9);
    QJsonObject payload;
    payload.insert(QStringLiteral("title"), title);
    payload.insert(QStringLiteral("location"), query.value(2).toString());
    payload.insert(QStringLiteral("weekday"), jsonValue(query.value(3)));
    payload.insert(QStringLiteral("start_minutes"), jsonValue(query.value(4)));
    payload.insert(QStringLiteral("end_minutes"), jsonValue(query.value(5)));
    payload.insert(QStringLiteral("week_start"), jsonValue(query.value(6)));
    payload.insert(QStringLiteral("week_end"), jsonValue(query.value(7)));
    payload.insert(QStringLiteral("week_parity"), jsonValue(query.value(8)));
    payload.insert(QStringLiteral("created_at"), query.value(10).toString());
    query.finish();
    payload.insert(QStringLiteral("category_sync_id"),
                   syncIdOfLocal(db, QStringLiteral("categories"), categoryId, &lookupError));
    if (!lookupError.isEmpty()) {
        if (error) *error = lookupError;
        return false;
    }
    return insertTrashRow(db, kKindScheduleEntry, originSyncId, title, payload, error);
}

bool captureCountdownGoal(QSqlDatabase& db, int goalId, QString* error)
{
    QSqlQuery query(db);
    if (!selectRow(query,
                   QStringLiteral("SELECT sync_id, name, target_date, created_at FROM countdown_goals "
                                  "WHERE id = :id"),
                   goalId, error)) {
        return false;
    }
    const QString name = query.value(1).toString();
    QJsonObject payload;
    payload.insert(QStringLiteral("name"), name);
    payload.insert(QStringLiteral("target_date"), query.value(2).toString());
    payload.insert(QStringLiteral("created_at"), query.value(3).toString());
    return insertTrashRow(db, kKindCountdownGoal, query.value(0).toString(), name, payload, error);
}

} // namespace TrashStore

TrashNotifier::TrashNotifier(QObject* parent)
    : QObject(parent)
{
}

TrashNotifier* TrashNotifier::instance()
{
    static TrashNotifier notifier;
    return &notifier;
}
