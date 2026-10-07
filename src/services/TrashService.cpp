#include "TrashService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusHistoryService.h"
#include "LogicalDay.h"
#include "RoutineManager.h"
#include "SyncNotifier.h"
#include "TaskManager.h"
#include "TrashStore.h"

#include <QDate>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>

#include <limits>

namespace {
const QString kGone = QStringLiteral("这一项已经不在废纸篓里了");
const QString kNeedsUpdate = QStringLiteral("这一项需要更新应用后才能恢复");
const QString kCorrupted = QStringLiteral("这一项的内容已损坏，无法恢复");

QString str(const QJsonObject& o, const char* key)
{
    const QJsonValue v = o.value(QLatin1String(key));
    // 默认构造的 QString 绑定成 SQL NULL，会撞上 NOT NULL 文本列：缺失或为 null 时必须给真正的空串。
    return v.isString() ? v.toString() : QStringLiteral("");
}

// 可空列：JSON null、缺失一律写成 SQL NULL（无效 QVariant 绑定为 NULL）。
QVariant nullableStr(const QJsonObject& o, const char* key)
{
    const QJsonValue v = o.value(QLatin1String(key));
    return v.isString() ? QVariant(v.toString()) : QVariant();
}

QVariant nullableInt(const QJsonObject& o, const char* key)
{
    const QJsonValue v = o.value(QLatin1String(key));
    return v.isDouble() ? QVariant(static_cast<qlonglong>(v.toDouble())) : QVariant();
}

int integer(const QJsonObject& o, const char* key, int fallback = 0)
{
    const QJsonValue v = o.value(QLatin1String(key));
    return v.isDouble() ? static_cast<int>(v.toDouble()) : fallback;
}

QStringList stringList(const QJsonObject& o, const char* key)
{
    QStringList result;
    for (const QJsonValue& v : o.value(QLatin1String(key)).toArray()) {
        if (v.isString() && !v.toString().isEmpty()) {
            result.append(v.toString());
        }
    }
    return result;
}

QString isoNow()
{
    return QDateTime::currentDateTime().toString(Qt::ISODate);
}

struct RestoreOutcome
{
    bool ok = false;
    QString error;
    QString conflict;
    QSet<QString> changedTables;
    // 仅恢复任务时有值：新任务的本地编号，以及这次接回到它名下的专注记录编号。
    int restoredTaskId = -1;
    QList<int> reattachedSessionIds;
};

bool fail(RestoreOutcome* out, const QString& message)
{
    out->error = message;
    return false;
}

bool fail(RestoreOutcome* out, const QString& prefix, const QSqlQuery& query)
{
    out->error = prefix + query.lastError().text();
    return false;
}

// 按 sync_id 解析引用。查询本身失败时 out->error 非空（调用方在用到结果前检查）：
// 不能把查询失败当成「找不到」，否则科目或任务关联会被悄悄丢掉。
QVariant resolveRef(QSqlDatabase& db, const QString& table, const QString& syncId, RestoreOutcome* out)
{
    bool ok = true;
    const QVariant id = TrashStore::resolveSyncId(db, table, syncId, &ok);
    if (!ok) {
        fail(out, QStringLiteral("恢复失败：读取关联内容出错"));
    }
    return id;
}

QVariant categoryLocalId(QSqlDatabase& db, const QJsonObject& payload, RestoreOutcome* out)
{
    return resolveRef(db, QStringLiteral("categories"), str(payload, "category_sync_id"), out);
}

// 各类型的恢复。都在调用方事务内执行，失败时只写 out->error，由调用方回滚；
// 这里的 QSqlQuery 都是局部变量，返回时已释放，回滚前不会留着未结束的语句。
bool restoreTask(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    // 日期无效（payload 损坏）时不能插出一条空日期的任务。
    if (!QDate::fromString(str(p, "date"), Qt::ISODate).isValid()) {
        return fail(out, kCorrupted);
    }
    const QVariant categoryId = categoryLocalId(db, p, out);
    if (!out->error.isEmpty()) {
        return false;
    }
    QVariant categoryName;
    if (categoryId.isValid()) {
        QSqlQuery nameQuery(db);
        nameQuery.prepare(QStringLiteral("SELECT name FROM categories WHERE id = :id"));
        nameQuery.bindValue(QStringLiteral(":id"), categoryId);
        if (!nameQuery.exec()) {
            return fail(out, QStringLiteral("恢复失败："), nameQuery);
        }
        if (nameQuery.next()) {
            categoryName = nameQuery.value(0).toString();
        }
    }
    // 科目找不到时 category_id 与 category 文本都置空（同删科目的做法），不留下指向不存在科目的文本。
    const QVariant resolvedCategoryId = categoryName.isValid() ? categoryId : QVariant();

    const QString date = str(p, "date");
    QSqlQuery insert(db);
    // 排在原日期最后（当天最大值 +1），不插回原位置：原位置的序号可能已被别的任务占用。
    // routine_id 置空、routine_generated 置 0：例行实例恢复成普通任务（原身份已被删除记录占住）。
    // 子查询里的日期单独取名：SQLite 下同名具名占位符只会绑上第一处。
    insert.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, routine_id, routine_generated, estimated_minutes, "
        "notes, display_order, date, completed, created_at, completion_note) "
        "VALUES (:title, :category, :categoryId, NULL, 0, :estimated, :notes, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate), "
        ":date, :completed, :createdAt, :completionNote)"));
    insert.bindValue(QStringLiteral(":title"), str(p, "title"));
    insert.bindValue(QStringLiteral(":category"), categoryName);
    insert.bindValue(QStringLiteral(":categoryId"), resolvedCategoryId);
    insert.bindValue(QStringLiteral(":estimated"), integer(p, "estimated_minutes"));
    insert.bindValue(QStringLiteral(":notes"), str(p, "notes"));
    insert.bindValue(QStringLiteral(":orderDate"), date);
    insert.bindValue(QStringLiteral(":date"), date);
    insert.bindValue(QStringLiteral(":completed"), integer(p, "completed"));
    const QString createdAt = str(p, "created_at");
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? isoNow() : createdAt);
    insert.bindValue(QStringLiteral(":completionNote"), str(p, "completion_note"));
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    const QVariant newId = insert.lastInsertId();
    insert.finish();
    out->changedTables.insert(QStringLiteral("tasks"));
    out->restoredTaskId = newId.toInt();

    // 接回关联：只接回仍然没有归属的。删除之后它们可能被用户改挂到了别的任务，那些不动。
    struct Link { const char* key; const char* table; const char* column; const char* tableName; };
    const Link links[] = {
        {"focus_session_sync_ids", "focus_sessions", "task_id", "focus_sessions"},
        {"gap_source_sync_ids", "knowledge_gaps", "source_task_id", "knowledge_gaps"},
        {"gap_linked_sync_ids", "knowledge_gaps", "linked_task_id", "knowledge_gaps"},
    };
    for (const Link& link : links) {
        for (const QString& syncId : stringList(p, link.key)) {
            QSqlQuery relink(db);
            relink.prepare(QStringLiteral("UPDATE %1 SET %2 = :task WHERE sync_id = :sid AND %2 IS NULL")
                               .arg(QLatin1String(link.table), QLatin1String(link.column)));
            relink.bindValue(QStringLiteral(":task"), newId);
            relink.bindValue(QStringLiteral(":sid"), syncId);
            if (!relink.exec()) {
                return fail(out, QStringLiteral("恢复失败："), relink);
            }
            if (relink.numRowsAffected() > 0) {
                out->changedTables.insert(QLatin1String(link.tableName));
            }
        }
    }

    // 查出接回的专注记录供计时器重新挂上。新任务刚建，名下的专注记录都是上面这次接回的，
    // 所以直接按 task_id 查，不必再逐条核对。
    QSqlQuery attached(db);
    attached.prepare(QStringLiteral("SELECT id FROM focus_sessions WHERE task_id = :task"));
    attached.bindValue(QStringLiteral(":task"), newId);
    if (!attached.exec()) {
        return fail(out, QStringLiteral("恢复失败："), attached);
    }
    while (attached.next()) {
        out->reattachedSessionIds.append(attached.value(0).toInt());
    }
    attached.finish();
    return true;
}

// 专注与休息共用：检查重叠。拒绝时写 conflict 与原因。
bool checkNoOverlap(QSqlDatabase& db, const QDateTime& start, const QDateTime& end, RestoreOutcome* out)
{
    QString dbError;
    switch (FocusHistoryService::findTimelineOverlap(db, start, end, -1, -1, &dbError)) {
    case FocusHistoryService::TimelineOverlap::None:
        return true;
    case FocusHistoryService::TimelineOverlap::Focus:
        out->conflict = QStringLiteral("focus");
        return fail(out, QStringLiteral("这段时间已有别的专注记录"));
    case FocusHistoryService::TimelineOverlap::Rest:
        out->conflict = QStringLiteral("rest");
        return fail(out, QStringLiteral("这段时间已有休息记录"));
    case FocusHistoryService::TimelineOverlap::ActiveRest:
        out->conflict = QStringLiteral("rest");
        return fail(out, QStringLiteral("这段时间有正在进行的休息"));
    case FocusHistoryService::TimelineOverlap::Error:
        break;
    }
    return fail(out, QStringLiteral("检查时间冲突失败：%1").arg(dbError));
}

bool restoreFocusSession(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QString startText = str(p, "start_time");
    const QString endText = str(p, "end_time");
    const QDateTime start = QDateTime::fromString(startText, Qt::ISODateWithMs);
    const QDateTime end = QDateTime::fromString(endText, Qt::ISODateWithMs);
    if (!start.isValid() || !end.isValid()) {
        return fail(out, kCorrupted);
    }
    // 只查区间冲突：不再查 3 分钟门槛和「不晚于现在」，恢复的是原来就有的记录。
    if (!checkNoOverlap(db, start, end, out)) {
        return false;
    }
    // 任务与科目快照按 sync_id 解析，解析不到置空（不关联）；名称、颜色快照照原文本。
    const QVariant taskId = resolveRef(db, QStringLiteral("tasks"), str(p, "task_sync_id"), out);
    const QVariant categoryId = categoryLocalId(db, p, out);
    if (!out->error.isEmpty()) {
        return false;
    }
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, pomodoro_completed, "
        "category_id_snapshot, category_name_snapshot, category_color_snapshot) "
        "VALUES (:task, :start, :end, :duration, :mode, :completed, :category, :name, :color)"));
    insert.bindValue(QStringLiteral(":task"), taskId);
    // 时间字符串原样写回，不重新格式化，保证与删除前逐字一致。
    insert.bindValue(QStringLiteral(":start"), startText);
    insert.bindValue(QStringLiteral(":end"), endText);
    insert.bindValue(QStringLiteral(":duration"), nullableInt(p, "duration"));
    insert.bindValue(QStringLiteral(":mode"), integer(p, "mode", 1));
    insert.bindValue(QStringLiteral(":completed"), integer(p, "pomodoro_completed"));
    insert.bindValue(QStringLiteral(":category"), categoryId);
    insert.bindValue(QStringLiteral(":name"), str(p, "category_name_snapshot"));
    insert.bindValue(QStringLiteral(":color"), str(p, "category_color_snapshot"));
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("focus_sessions"));
    return true;
}

bool restoreRestSession(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QString startText = str(p, "start_time");
    const QString endText = str(p, "end_time");
    const QDateTime start = QDateTime::fromString(startText, Qt::ISODateWithMs);
    const int duration = integer(p, "duration");
    if (!start.isValid() || duration <= 0 || !QDateTime::fromString(endText, Qt::ISODateWithMs).isValid()) {
        return fail(out, kCorrupted);
    }
    // 休息按「起点 + 实际时长」占用时间（end_time 可能含暂停），候选区间也这样取，
    // 与重叠检查对既有休息的算法一致。
    if (!checkNoOverlap(db, start, start.addSecs(duration), out)) {
        return false;
    }
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
        "VALUES (:start, :end, :duration, :manual)"));
    insert.bindValue(QStringLiteral(":start"), startText);
    insert.bindValue(QStringLiteral(":end"), endText);
    insert.bindValue(QStringLiteral(":duration"), duration);
    insert.bindValue(QStringLiteral(":manual"), integer(p, "manual"));
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("rest_sessions"));
    return true;
}

bool restoreKnowledgeGap(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QVariant category = categoryLocalId(db, p, out);
    const QVariant source = resolveRef(db, QStringLiteral("tasks"), str(p, "source_task_sync_id"), out);
    const QVariant linked = resolveRef(db, QStringLiteral("tasks"), str(p, "linked_task_sync_id"), out);
    if (!out->error.isEmpty()) {
        return false;
    }
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO knowledge_gaps (title, detail, category_id, source_task_id, source_task_title, priority, "
        "status, due_date, resolution, linked_task_id, created_at, updated_at, resolved_at) "
        "VALUES (:title, :detail, :category, :source, :sourceTitle, :priority, :status, :due, :resolution, "
        ":linked, :createdAt, :updatedAt, :resolvedAt)"));
    insert.bindValue(QStringLiteral(":title"), str(p, "title"));
    // 三个 NOT NULL 文本列：JSON 里是 null 时收敛成空串（str 对非字符串返回空串）。
    insert.bindValue(QStringLiteral(":detail"), str(p, "detail"));
    insert.bindValue(QStringLiteral(":category"), category);
    insert.bindValue(QStringLiteral(":source"), source);
    insert.bindValue(QStringLiteral(":sourceTitle"), str(p, "source_task_title"));
    insert.bindValue(QStringLiteral(":priority"), integer(p, "priority", 1));
    insert.bindValue(QStringLiteral(":status"), integer(p, "status"));
    insert.bindValue(QStringLiteral(":due"), nullableStr(p, "due_date"));
    insert.bindValue(QStringLiteral(":resolution"), str(p, "resolution"));
    insert.bindValue(QStringLiteral(":linked"), linked);
    const QString createdAt = str(p, "created_at");
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? isoNow() : createdAt);
    // 写法同 KnowledgeGapService 新建：本地时间 ISODate。恢复算一次修改。
    insert.bindValue(QStringLiteral(":updatedAt"), isoNow());
    insert.bindValue(QStringLiteral(":resolvedAt"), nullableStr(p, "resolved_at"));
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("knowledge_gaps"));
    return true;
}

bool restoreMemo(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    // 科目找不到进未分类（NULL）。排在该科目最后；越界检查同 MemoService::nextSortOrder。
    const QVariant categoryId = categoryLocalId(db, p, out);
    if (!out->error.isEmpty()) {
        return false;
    }
    QSqlQuery maxQuery(db);
    maxQuery.prepare(QStringLiteral("SELECT COALESCE(MAX(sort_order), 0) FROM memos WHERE category_id IS :category"));
    maxQuery.bindValue(QStringLiteral(":category"), categoryId);
    if (!maxQuery.exec() || !maxQuery.next()) {
        return fail(out, QStringLiteral("恢复失败："), maxQuery);
    }
    const qlonglong maximum = maxQuery.value(0).toLongLong();
    maxQuery.finish();
    if (maximum >= std::numeric_limits<int>::max()) {
        return fail(out, QStringLiteral("备忘录顺序已超出范围，请先重新排序"));
    }
    // 更新时间是恢复的此刻（恢复也算一次修改，两台显示一致），写法同 MemoService：UTC 毫秒。
    const QString nowText = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
    const QString createdAt = str(p, "created_at");
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
        "VALUES (:title, :body, :category, :order, :createdAt, :updatedAt)"));
    insert.bindValue(QStringLiteral(":title"), str(p, "title"));
    insert.bindValue(QStringLiteral(":body"), str(p, "body"));
    insert.bindValue(QStringLiteral(":category"), categoryId);
    insert.bindValue(QStringLiteral(":order"), static_cast<int>(maximum) + 1);
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? nowText : createdAt);
    insert.bindValue(QStringLiteral(":updatedAt"), nowText);
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("memos"));
    return true;
}

bool restoreRoutine(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QVariant category = categoryLocalId(db, p, out);
    if (!out->error.isEmpty()) {
        return false;
    }
    const QString createdAt = str(p, "created_at");
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id, active, display_order, last_generated_date, created_at, "
        "weekdays) VALUES (:title, :category, :active, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM routines), :stamp, :createdAt, :weekdays)"));
    insert.bindValue(QStringLiteral(":title"), str(p, "title"));
    insert.bindValue(QStringLiteral(":category"), category);
    insert.bindValue(QStringLiteral(":active"), integer(p, "active", 1));
    // 生成戳照 payload：删除时收回过当日实例的存的是空（恢复后当天补生成），其余是原值（不重复生成）。
    insert.bindValue(QStringLiteral(":stamp"), nullableStr(p, "last_generated_date"));
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? isoNow() : createdAt);
    insert.bindValue(QStringLiteral(":weekdays"), integer(p, "weekdays", 127));
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    // 例行恢复后立即生成当日实例，会写 tasks；刷新信号要带上任务列表。
    out->changedTables.insert(QStringLiteral("routines"));
    out->changedTables.insert(QStringLiteral("tasks"));
    return true;
}

bool restoreScheduleEntry(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QVariant category = categoryLocalId(db, p, out);
    if (!out->error.isEmpty()) {
        return false;
    }
    const QString createdAt = str(p, "created_at");
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO schedule_entries (title, location, weekday, start_minutes, end_minutes, week_start, "
        "week_end, week_parity, category_id, created_at) "
        "VALUES (:title, :location, :weekday, :start, :end, :weekStart, :weekEnd, :parity, :category, "
        ":createdAt)"));
    insert.bindValue(QStringLiteral(":title"), str(p, "title"));
    insert.bindValue(QStringLiteral(":location"), str(p, "location"));
    insert.bindValue(QStringLiteral(":weekday"), integer(p, "weekday"));
    insert.bindValue(QStringLiteral(":start"), integer(p, "start_minutes"));
    insert.bindValue(QStringLiteral(":end"), integer(p, "end_minutes"));
    insert.bindValue(QStringLiteral(":weekStart"), integer(p, "week_start", 1));
    insert.bindValue(QStringLiteral(":weekEnd"), integer(p, "week_end", 30));
    insert.bindValue(QStringLiteral(":parity"), integer(p, "week_parity"));
    insert.bindValue(QStringLiteral(":category"), category);
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? isoNow() : createdAt);
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("schedule_entries"));
    return true;
}

bool restoreCountdownGoal(QSqlDatabase& db, const QJsonObject& p, RestoreOutcome* out)
{
    const QString createdAt = str(p, "created_at");
    const QString nowText = isoNow(); // 写法同 CountdownService 新建：本地时间 ISODate
    QSqlQuery insert(db);
    insert.prepare(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES (:name, :target, (SELECT COALESCE(MAX(display_order), -1) + 1 FROM countdown_goals), "
        ":createdAt, :updatedAt)"));
    insert.bindValue(QStringLiteral(":name"), str(p, "name"));
    insert.bindValue(QStringLiteral(":target"), str(p, "target_date"));
    insert.bindValue(QStringLiteral(":createdAt"), createdAt.isEmpty() ? nowText : createdAt);
    insert.bindValue(QStringLiteral(":updatedAt"), nowText);
    if (!insert.exec()) {
        return fail(out, QStringLiteral("恢复失败："), insert);
    }
    out->changedTables.insert(QStringLiteral("countdown_goals"));
    return true;
}

// 不查库就能做的可恢复判定，列表（readItems）与恢复（restoreItem）共用，保证两处说法一致。
// 先判内容损坏，再判类型与版本：损坏的内容读出来是空对象、v=0，顺序反了会被说成「需要更新应用」。
// 返回空串表示可以继续恢复，否则是 "corrupted" 或 "needsUpdate"；payload 输出解析出的对象。
QString payloadProblem(const QString& kind, const QString& payloadText, QJsonObject* payload)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(payloadText.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return QStringLiteral("corrupted");
    }
    *payload = document.object();
    const bool known = kind == TrashStore::kKindTask || kind == TrashStore::kKindFocusSession
        || kind == TrashStore::kKindRestSession || kind == TrashStore::kKindKnowledgeGap
        || kind == TrashStore::kKindMemo || kind == TrashStore::kKindRoutine
        || kind == TrashStore::kKindScheduleEntry || kind == TrashStore::kKindCountdownGoal;
    // 更新版本新增的类型、或更高的内容格式：旧版读得到但不会恢复，提示更新。
    if (!known || payload->value(QStringLiteral("v")).toInt() != TrashStore::kPayloadVersion) {
        return QStringLiteral("needsUpdate");
    }
    return QString();
}

QVariantMap failureMap(const QString& error)
{
    return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), error}};
}

// 这一项已经不在废纸篓里（另一台刚恢复或删掉了它）。带结构化的 code，页面据此重读列表，
// 不靠逐字比较提示文案：文案以后改了，判断也不会悄悄失效。
QVariantMap goneMap()
{
    QVariantMap map = failureMap(kGone);
    map.insert(QStringLiteral("code"), QStringLiteral("gone"));
    return map;
}

// 删掉 id 这一行，以及 origin_sync_id 非空且相同的全部行（两台同时删了同一条各写一条）。返回删除条数，失败 -1。
int deleteRowAndTwins(QSqlDatabase& db, int trashId, const QString& origin)
{
    QSqlQuery remove(db);
    remove.prepare(QStringLiteral(
        "DELETE FROM trash_items WHERE id = :id OR (:origin <> '' AND origin_sync_id = :origin2)"));
    remove.bindValue(QStringLiteral(":id"), trashId);
    remove.bindValue(QStringLiteral(":origin"), origin);
    remove.bindValue(QStringLiteral(":origin2"), origin);
    if (!remove.exec()) {
        qWarning() << "Failed to delete trash item:" << remove.lastError().text();
        return -1;
    }
    return remove.numRowsAffected();
}
} // namespace

TrashService::TrashService(QObject* parent)
    : QObject(parent)
{
    // 各服务提交删除后发 TrashNotifier::changed（它们不能依赖本类，否则成环），这里转成对外的 trashChanged。
    connect(TrashNotifier::instance(), &TrashNotifier::changed, this, &TrashService::trashChanged);
}

TrashService* TrashService::instance()
{
    static TrashService service;
    return &service;
}

QDateTime TrashService::now() const
{
    return m_nowForTesting.isValid() ? m_nowForTesting : QDateTime::currentDateTime();
}

QVariantMap TrashService::readItems() const
{
    if (!DatabaseManager::instance()->isOpen()) {
        return {{QStringLiteral("ok"), false}, {QStringLiteral("items"), QVariantList()},
                {QStringLiteral("error"), QStringLiteral("数据库未打开，无法读取废纸篓")}};
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    // 同一时刻删的按编号大到小，保证排序稳定；deleted_at 是同格式的 UTC 文本，按文本排即按时间排。
    if (!query.exec(QStringLiteral("SELECT id, kind, origin_sync_id, title, payload, deleted_at FROM trash_items "
                                   "ORDER BY deleted_at DESC, id DESC"))) {
        return {{QStringLiteral("ok"), false}, {QStringLiteral("items"), QVariantList()},
                {QStringLiteral("error"), QStringLiteral("读取废纸篓失败：%1").arg(query.lastError().text())}};
    }
    struct Row { int id; QString kind, origin, title, payload, deletedAt; };
    QList<Row> rows;
    while (query.next()) {
        rows.append({query.value(0).toInt(), query.value(1).toString(), query.value(2).toString(),
                     query.value(3).toString(), query.value(4).toString(), query.value(5).toString()});
    }
    if (query.lastError().isValid()) {
        return {{QStringLiteral("ok"), false}, {QStringLiteral("items"), QVariantList()},
                {QStringLiteral("error"), QStringLiteral("读取废纸篓失败：%1").arg(query.lastError().text())}};
    }
    query.finish();

    const int dayStartHour = AppSettings::instance()->dayStartHour();
    const QDate today = LogicalDay::dateOf(now().toLocalTime(), dayStartHour);

    QVariantList items;
    QSet<QString> seenOrigins;
    for (const Row& row : rows) {
        // 两台同时删了同一条会各写一条：只列最新的一条（rows 已按新到旧排）。
        if (!row.origin.isEmpty()) {
            if (seenOrigins.contains(row.origin)) {
                continue;
            }
            seenOrigins.insert(row.origin);
        }
        // 内容损坏时 payload 留空对象：标题、删除时间照常列出，要点为空，用户仍可彻底删除它。
        QJsonObject payload;
        const QString problem = payloadProblem(row.kind, row.payload, &payload);
        const QDateTime deletedAt = QDateTime::fromString(row.deletedAt, Qt::ISODateWithMs);
        // 逻辑删除日：凌晨日界前算前一天。时间文本无法解析时给空串、按未到期处理，不让坏行被悄悄清掉。
        QString deletedDate;
        int remaining = kRetentionDays;
        if (deletedAt.isValid()) {
            const QDate day = LogicalDay::dateOf(deletedAt.toLocalTime(), dayStartHour);
            deletedDate = day.toString(Qt::ISODate);
            remaining = kRetentionDays - static_cast<int>(day.daysTo(today));
        }

        // 已到期、还没被清理掉的行不列出（清理在启动和逻辑日变化时才跑）；剩余天数夹到保留期上限：
        // 另一台设备时钟偏快写出「未来」的删除时刻时，不能显示「还剩 31 天」。
        if (remaining <= 0) {
            continue;
        }
        remaining = qMin(remaining, kRetentionDays);

        QVariantMap details;
        QString categoryName;
        QString categoryColor;
        if (row.kind == TrashStore::kKindTask) {
            details = {{QStringLiteral("date"), str(payload, "date")},
                       {QStringLiteral("completed"), integer(payload, "completed") != 0},
                       {QStringLiteral("estimatedMinutes"), integer(payload, "estimated_minutes")}};
        } else if (row.kind == TrashStore::kKindFocusSession) {
            details = {{QStringLiteral("startTime"), str(payload, "start_time")},
                       {QStringLiteral("endTime"), str(payload, "end_time")},
                       {QStringLiteral("durationSeconds"), integer(payload, "duration")},
                       {QStringLiteral("mode"), integer(payload, "mode")},
                       {QStringLiteral("taskTitle"), str(payload, "task_title")}};
            categoryName = str(payload, "category_name_snapshot");
            categoryColor = str(payload, "category_color_snapshot");
        } else if (row.kind == TrashStore::kKindRestSession) {
            details = {{QStringLiteral("startTime"), str(payload, "start_time")},
                       {QStringLiteral("endTime"), str(payload, "end_time")},
                       {QStringLiteral("durationSeconds"), integer(payload, "duration")},
                       {QStringLiteral("manual"), integer(payload, "manual") != 0}};
        } else if (row.kind == TrashStore::kKindKnowledgeGap) {
            details = {{QStringLiteral("dueDate"), str(payload, "due_date")},
                       {QStringLiteral("status"), integer(payload, "status")}};
        } else if (row.kind == TrashStore::kKindRoutine) {
            details = {{QStringLiteral("weekdays"), integer(payload, "weekdays")},
                       {QStringLiteral("active"), integer(payload, "active") != 0}};
        } else if (row.kind == TrashStore::kKindScheduleEntry) {
            details = {{QStringLiteral("weekday"), integer(payload, "weekday")},
                       {QStringLiteral("startMinutes"), integer(payload, "start_minutes")},
                       {QStringLiteral("endMinutes"), integer(payload, "end_minutes")},
                       {QStringLiteral("weekStart"), integer(payload, "week_start")},
                       {QStringLiteral("weekEnd"), integer(payload, "week_end")},
                       {QStringLiteral("weekParity"), integer(payload, "week_parity")},
                       {QStringLiteral("location"), str(payload, "location")}};
        } else if (row.kind == TrashStore::kKindCountdownGoal) {
            details = {{QStringLiteral("targetDate"), str(payload, "target_date")}};
        }

        // 科目按 sync_id 查本机现在的科目（含被合并后留下的那个）；查不到时只有专注记录退回当时的快照。
        const QVariant categoryId = TrashStore::resolveSyncId(db, QStringLiteral("categories"),
                                                              str(payload, "category_sync_id"));
        if (categoryId.isValid()) {
            QSqlQuery categoryQuery(db);
            categoryQuery.prepare(QStringLiteral("SELECT name, color FROM categories WHERE id = :id"));
            categoryQuery.bindValue(QStringLiteral(":id"), categoryId);
            if (categoryQuery.exec() && categoryQuery.next()) {
                categoryName = categoryQuery.value(0).toString();
                categoryColor = categoryQuery.value(1).toString();
            }
        }

        items.append(QVariantMap{
            {QStringLiteral("id"), row.id},
            {QStringLiteral("kind"), row.kind},
            {QStringLiteral("title"), row.title},
            {QStringLiteral("deletedAt"), row.deletedAt},
            {QStringLiteral("deletedDate"), deletedDate},
            {QStringLiteral("remainingDays"), remaining},
            {QStringLiteral("originSyncId"), row.origin},
            {QStringLiteral("categoryName"), categoryName},
            {QStringLiteral("categoryColor"), categoryColor},
            {QStringLiteral("restorable"), problem.isEmpty()},
            {QStringLiteral("blockedReason"), problem},
            {QStringLiteral("details"), details}});
    }
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()},
            {QStringLiteral("today"), today.toString(Qt::ISODate)}, {QStringLiteral("items"), items}};
}

int TrashService::purgeExpired()
{
    if (!DatabaseManager::instance()->isOpen()) {
        return -1;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    // 到期按逻辑日在 C++ 里算（日界点是用户设置，SQL 里换算本地时区容易出错），先选出编号再一次性删除。
    // 选和删放在同一事务里，两步之间没有别的写入插进来。
    if (!db.transaction()) {
        qWarning() << "Failed to start trash purge:" << db.lastError().text();
        return -1;
    }
    const int dayStartHour = AppSettings::instance()->dayStartHour();
    const QDate today = LogicalDay::dateOf(now().toLocalTime(), dayStartHour);
    QList<int> expired;
    {
        QSqlQuery query(db);
        if (!query.exec(QStringLiteral("SELECT id, deleted_at FROM trash_items"))) {
            const QString reason = query.lastError().text();
            query.finish();
            db.rollback();
            qWarning() << "Failed to read trash for purge:" << reason;
            return -1;
        }
        while (query.next()) {
            const QDateTime deletedAt = QDateTime::fromString(query.value(1).toString(), Qt::ISODateWithMs);
            if (!deletedAt.isValid()) {
                continue; // 无法解析时间的坏行不自动清，用户仍可手动删除。
            }
            const QDate day = LogicalDay::dateOf(deletedAt.toLocalTime(), dayStartHour);
            if (kRetentionDays - day.daysTo(today) <= 0) {
                expired.append(query.value(0).toInt());
            }
        }
    }
    for (const int id : expired) {
        QSqlQuery remove(db);
        remove.prepare(QStringLiteral("DELETE FROM trash_items WHERE id = :id"));
        remove.bindValue(QStringLiteral(":id"), id);
        if (!remove.exec()) {
            const QString reason = remove.lastError().text();
            remove.finish();
            db.rollback();
            qWarning() << "Failed to purge trash item:" << reason;
            return -1;
        }
    }
    if (!db.commit()) {
        qWarning() << "Failed to commit trash purge:" << db.lastError().text();
        db.rollback();
        return -1;
    }
    if (!expired.isEmpty()) {
        emit trashChanged();
    }
    return static_cast<int>(expired.size());
}

QVariantMap TrashService::deleteItem(int trashId)
{
    if (!DatabaseManager::instance()->isOpen()) {
        return failureMap(QStringLiteral("数据库未打开，无法删除"));
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        return failureMap(QStringLiteral("删除失败：%1").arg(db.lastError().text()));
    }
    QString origin;
    {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("SELECT origin_sync_id FROM trash_items WHERE id = :id"));
        query.bindValue(QStringLiteral(":id"), trashId);
        if (!query.exec()) {
            const QString reason = query.lastError().text();
            query.finish();
            db.rollback();
            return failureMap(QStringLiteral("删除失败：%1").arg(reason));
        }
        if (!query.next()) {
            query.finish();
            db.rollback();
            return goneMap(); // 另一台可能刚恢复或删掉了它
        }
        origin = query.value(0).toString();
    }
    const int removed = deleteRowAndTwins(db, trashId, origin);
    if (removed < 0 || !db.commit()) {
        db.rollback();
        return failureMap(QStringLiteral("删除失败"));
    }
    emit trashChanged();
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()}};
}

QVariantMap TrashService::emptyTrash(const QVariantList& trashIds)
{
    if (!DatabaseManager::instance()->isOpen()) {
        return failureMap(QStringLiteral("数据库未打开，无法清空"));
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        return failureMap(QStringLiteral("清空失败：%1").arg(db.lastError().text()));
    }
    // 一个事务里逐项处理：任何一步 SQL 失败整体回滚，不留下清了一半的废纸篓。
    int count = 0;
    for (const QVariant& element : trashIds) {
        bool isInt = false;
        const int id = element.toInt(&isInt);
        if (!isInt) {
            continue;
        }
        QString origin;
        {
            QSqlQuery query(db);
            query.prepare(QStringLiteral("SELECT origin_sync_id FROM trash_items WHERE id = :id"));
            query.bindValue(QStringLiteral(":id"), id);
            if (!query.exec()) {
                const QString reason = query.lastError().text();
                query.finish();
                db.rollback();
                return failureMap(QStringLiteral("清空失败：%1").arg(reason));
            }
            if (!query.next()) {
                query.finish();
                continue; // 已被另一台恢复或删掉，或已随前面某项的同源行一起删了
            }
            origin = query.value(0).toString();
            query.finish();
        }
        const int removed = deleteRowAndTwins(db, id, origin);
        if (removed < 0) {
            db.rollback();
            return failureMap(QStringLiteral("清空失败"));
        }
        count += removed;
    }
    if (!db.commit()) {
        db.rollback();
        return failureMap(QStringLiteral("清空失败"));
    }
    if (count > 0) {
        emit trashChanged();
    }
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()}, {QStringLiteral("count"), count}};
}

QVariantMap TrashService::restoreItem(int trashId)
{
    if (!DatabaseManager::instance()->isOpen()) {
        return failureMap(QStringLiteral("数据库未打开，无法恢复"));
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    // 一律在一个事务里：重读这一行、新建记录、接回关联、删掉同一原记录的全部废纸篓行。
    // 重读放在事务里，是因为另一台可能刚把这一项恢复或删掉，不在了就如实说，不能再恢复出第二份。
    if (!db.transaction()) {
        return failureMap(QStringLiteral("恢复失败：%1").arg(db.lastError().text()));
    }
    QString kind;
    QString title;
    QString origin;
    QString payloadText;
    {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("SELECT kind, title, origin_sync_id, payload FROM trash_items WHERE id = :id"));
        query.bindValue(QStringLiteral(":id"), trashId);
        if (!query.exec()) {
            const QString reason = query.lastError().text();
            query.finish();
            db.rollback();
            return failureMap(QStringLiteral("恢复失败：%1").arg(reason));
        }
        if (!query.next()) {
            query.finish();
            db.rollback();
            return goneMap();
        }
        kind = query.value(0).toString();
        title = query.value(1).toString();
        origin = query.value(2).toString();
        payloadText = query.value(3).toString();
    }

    auto failed = [&](const QString& error, const QString& conflict = QString()) {
        db.rollback();
        QVariantMap map = failureMap(error);
        map.insert(QStringLiteral("kind"), kind);
        map.insert(QStringLiteral("title"), title);
        map.insert(QStringLiteral("conflict"), conflict);
        return map;
    };

    QJsonObject payload;
    const QString problem = payloadProblem(kind, payloadText, &payload);
    if (!problem.isEmpty()) {
        return failed(problem == QLatin1String("corrupted") ? kCorrupted : kNeedsUpdate);
    }

    RestoreOutcome outcome;
    bool restored = false;
    if (kind == TrashStore::kKindTask) {
        restored = restoreTask(db, payload, &outcome);
    } else if (kind == TrashStore::kKindFocusSession) {
        restored = restoreFocusSession(db, payload, &outcome);
    } else if (kind == TrashStore::kKindRestSession) {
        restored = restoreRestSession(db, payload, &outcome);
    } else if (kind == TrashStore::kKindKnowledgeGap) {
        restored = restoreKnowledgeGap(db, payload, &outcome);
    } else if (kind == TrashStore::kKindMemo) {
        restored = restoreMemo(db, payload, &outcome);
    } else if (kind == TrashStore::kKindRoutine) {
        restored = restoreRoutine(db, payload, &outcome);
    } else if (kind == TrashStore::kKindScheduleEntry) {
        restored = restoreScheduleEntry(db, payload, &outcome);
    } else {
        restored = restoreCountdownGoal(db, payload, &outcome);
    }
    if (!restored) {
        return failed(outcome.error, outcome.conflict);
    }
    if (deleteRowAndTwins(db, trashId, origin) < 0 || !db.commit()) {
        return failed(QStringLiteral("恢复失败：%1").arg(db.lastError().text()));
    }

    // 以下是提交之后的跨层信号。顺序：先发废纸篓变化，例行要先补生成当日实例再统一刷新，
    // 这样列表只重读一次就能看到恢复出来的例行和它今天的任务。
    emit trashChanged();
    if (kind == TrashStore::kKindRoutine) {
        RoutineManager::instance()->materializeToday();
    }
    if (kind == TrashStore::kKindTask) {
        // 同 TaskManager::deleteTask：先发事实让计时器挂回，再发列表刷新（下面的 publishTableChanges），
        // 页面不会看到「任务回来了、计时器还没挂」的中间状态。
        emit TaskManager::instance()->taskRestored(outcome.restoredTaskId, outcome.reattachedSessionIds);
    }
    SyncNotifier::publishTableChanges(outcome.changedTables);
    return {{QStringLiteral("ok"), true}, {QStringLiteral("error"), QString()},
            {QStringLiteral("kind"), kind}, {QStringLiteral("title"), title},
            {QStringLiteral("conflict"), QString()}};
}
