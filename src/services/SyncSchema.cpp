#include "SyncSchema.h"

#include <QDate>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QUuid>

namespace SyncSchema {

namespace {

Field makeField(const char* column, const char* label, const char* refTable = "")
{
    return {QString::fromUtf8(column), QString::fromUtf8(label), QString::fromUtf8(refTable)};
}

QList<Table> buildTables()
{
    // 列清单只收用户数据。下面这些列刻意不同步：
    // - routines.last_generated_date：「今天生成过没有」只对本机有意义，两台设备各自记；
    // - 各表的 id：本机自增编号，跨设备靠 sync_id 对应。
    // tasks.category 是旧版留下的科目名文本，界面在 category_id 为空时靠它显示，所以照样同步。
    return {
        {QStringLiteral("categories"), QStringLiteral("科目"),
         {makeField("name", "名称"), makeField("color", "颜色"), makeField("is_preset", "预置科目"),
          makeField("display_order", "排序"), makeField("created_at", "创建时间")},
         QString()},
        {QStringLiteral("routines"), QStringLiteral("每日例行"),
         {makeField("title", "标题"), makeField("category_id", "科目", "categories"),
          makeField("active", "启用"), makeField("display_order", "排序"),
          makeField("weekdays", "重复日"), makeField("created_at", "创建时间")},
         QString()},
        {QStringLiteral("tasks"), QStringLiteral("任务"),
         {makeField("title", "标题"), makeField("category", "科目名称"),
          makeField("category_id", "科目", "categories"), makeField("routine_id", "所属例行", "routines"),
          makeField("routine_generated", "由例行生成"), makeField("estimated_minutes", "预计用时"),
          makeField("notes", "备注"), makeField("display_order", "排序"), makeField("date", "日期"),
          makeField("completed", "完成状态"), makeField("created_at", "创建时间"),
          makeField("completion_note", "完成记录")},
         QString()},
        // 专注行在「开始专注」时就落库，结束时才写结束时刻和时长。进行中的那一行只属于本机的计时器：
        // FocusTimer 启动时会删掉没被本机计时状态引用的未结束行（cleanupOrphanedSessions）。
        // 把它同步过去，对方会当孤儿删掉，删除再传回来就会连带删掉本机正在进行的计时。
        // 所以只有结束了的记录才发布；结束那一刻由 focus_sessions_sync_publish 触发器补发整条。
        {QStringLiteral("focus_sessions"), QStringLiteral("专注记录"),
         {makeField("task_id", "任务", "tasks"), makeField("start_time", "开始时间"),
          makeField("end_time", "结束时间"), makeField("duration", "时长"), makeField("mode", "计时方式"),
          makeField("pomodoro_completed", "完整番茄"),
          makeField("category_id_snapshot", "科目", "categories"),
          makeField("category_name_snapshot", "科目名称"),
          makeField("category_color_snapshot", "科目颜色")},
         QStringLiteral("%1.end_time IS NOT NULL")},
        {QStringLiteral("rest_sessions"), QStringLiteral("休息记录"),
         {makeField("start_time", "开始时间"), makeField("end_time", "结束时间"),
          makeField("duration", "时长"), makeField("manual", "主动休息")},
         QString()},
        // 第二期（计划 051）：课表、知识缺口、目标倒计时，引用科目与任务，所以排在它们后面。
        // updated_at 刻意不同步：它只是本机的记账，界面和排序都不用它；同步它的话，两台设备改了同一条的
        // 不同地方，也会在同步日志里多出一条「更新时间」的冲突。对方新建的行插进本机时由 stampOnInsert 补上。
        // 课表节次不在这里：改节次是整表删掉再按时间重新编号写回，按条目同步会被「删除优先」打乱，
        // 它整张表作为一个设置项同步（见 SyncedSettings）。
        {QStringLiteral("schedule_entries"), QStringLiteral("课表"),
         {makeField("title", "课程"), makeField("location", "地点"), makeField("weekday", "星期"),
          makeField("start_minutes", "开始时间"), makeField("end_minutes", "结束时间"),
          makeField("week_start", "起始周"), makeField("week_end", "结束周"), makeField("week_parity", "单双周"),
          makeField("category_id", "科目", "categories"), makeField("created_at", "创建时间")},
         QString()},
        {QStringLiteral("knowledge_gaps"), QStringLiteral("知识缺口"),
         {makeField("title", "标题"), makeField("detail", "详情"), makeField("category_id", "科目", "categories"),
          makeField("source_task_id", "来源任务", "tasks"), makeField("source_task_title", "来源任务名称"),
          makeField("priority", "优先级"), makeField("status", "状态"), makeField("due_date", "计划日期"),
          makeField("resolution", "结论"), makeField("linked_task_id", "关联任务", "tasks"),
          makeField("created_at", "创建时间"), makeField("resolved_at", "解决时间")},
         QString(), {QStringLiteral("updated_at")}},
        {QStringLiteral("countdown_goals"), QStringLiteral("倒计时"),
         {makeField("name", "名称"), makeField("target_date", "目标日期"), makeField("display_order", "排序"),
          makeField("created_at", "创建时间")},
         QString(), {QStringLiteral("updated_at")}},
    };
}

// 用 {名字} 占位再逐个替换，而不用 QString::arg：代入的 SQL 片段里本身带 %1 这类文本时，
// 后续的 arg 会把它当占位符再换一次，生成出错位的语句。
QString fill(QString sql, const QList<QPair<QString, QString>>& tokens)
{
    for (const auto& token : tokens) {
        sql.replace(token.first, token.second);
    }
    return sql;
}

QString columnList(const Table& table)
{
    QStringList columns;
    for (const Field& field : table.fields) {
        columns.append(field.column);
    }
    return columns.join(QStringLiteral(", "));
}

// 新行的 sync_id。服务写入时不带它，由插入触发器补上；应用远端改动时已经带着，触发器也不会运行。
QString newSyncIdExpression(const Table& table)
{
    const QString random = QStringLiteral("lower(hex(randomblob(16)))");
    if (table.name == QLatin1String("categories")) {
        // 预置科目按位置取固定身份；这个身份已被占用（外部改过库）时退回随机，宁可多一条也不能插入失败。
        return QStringLiteral(
                   "CASE WHEN NEW.is_preset = 1 AND NOT EXISTS (SELECT 1 FROM categories x "
                   "WHERE x.sync_id = 'preset-' || NEW.display_order) "
                   "THEN 'preset-' || NEW.display_order ELSE %1 END")
            .arg(random);
    }
    if (table.name == QLatin1String("tasks")) {
        // 例行生成的实例用「例行 sync_id + 日期」。已有同身份的任务时退回随机：materializeToday
        // 会先查重，走到这里只可能是外部写入，不能让插入因唯一索引失败。
        const QString instance = routineInstanceSyncIdSql(QStringLiteral("r.sync_id"),
                                                          QStringLiteral("NEW.date"));
        return fill(QStringLiteral(
                        "COALESCE(CASE WHEN NEW.routine_generated = 1 AND NEW.routine_id IS NOT NULL THEN "
                        "(SELECT {INSTANCE} FROM routines r WHERE r.id = NEW.routine_id AND r.sync_id IS NOT NULL "
                        "AND NOT EXISTS (SELECT 1 FROM tasks x WHERE x.sync_id = {INSTANCE})) END, {RANDOM})"),
                    {{QStringLiteral("{INSTANCE}"), instance}, {QStringLiteral("{RANDOM}"), random}});
    }
    return random;
}

// 新行的字段版本是否取最小值 (0, '')：取最小值的版本输给任何一次真实修改。
// - 预置科目：两台设备建库时各自插入同一组默认值，谁也不该覆盖对方改过的名字和颜色；
// - 例行生成的实例：两台设备各自生成同一天的同一条，晚生成的一份不能盖掉另一台上已经完成的状态。
//   但如果这个身份有过「收回」记录（停用后又启用），重新生成的这份要用真实版本，
//   才能在对方那里取代那条收回记录，让对方也把实例补回来。
QString minimalVersionCondition(const Table& table)
{
    if (table.name == QLatin1String("categories")) {
        return QStringLiteral("r.is_preset = 1");
    }
    if (table.name == QLatin1String("tasks")) {
        return fill(QStringLiteral(
                        "(r.routine_generated = 1 AND r.routine_id IS NOT NULL "
                        "AND r.sync_id = (SELECT {INSTANCE} FROM routines rr WHERE rr.id = r.routine_id) "
                        "AND NOT EXISTS (SELECT 1 FROM sync_tombstones z WHERE z.tbl = 'tasks' "
                        "AND z.sync_id = r.sync_id))"),
                    {{QStringLiteral("{INSTANCE}"),
                      routineInstanceSyncIdSql(QStringLiteral("rr.sync_id"), QStringLiteral("r.date"))}});
    }
    return QStringLiteral("0");
}

QPair<QString, QString> insertTrigger(const Table& table)
{
    const QString name = table.name + QStringLiteral("_sync_ai");
    // 重新生成的例行实例落地之后，那条「收回」记录就被它取代了，留着会让下次应用远端改动时误删它。
    const QString clearReclaim = table.name == QLatin1String("tasks")
        ? QStringLiteral("DELETE FROM sync_tombstones WHERE tbl = 'tasks' AND kind = 'reclaim' "
                         "AND sync_id = (SELECT sync_id FROM tasks WHERE id = NEW.id); ")
        : QString();
    const QString sql = fill(QStringLiteral(
        "CREATE TRIGGER {NAME} AFTER INSERT ON {TBL} WHEN {NOT_APPLYING} BEGIN "
        "{ADVANCE} "
        "UPDATE {TBL} SET sync_id = {NEW_ID} WHERE id = NEW.id AND (sync_id IS NULL OR sync_id = ''); "
        "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
        "SELECT '{TBL}', r.sync_id, f.column1, CASE WHEN {MINIMAL} THEN 0 ELSE {CLOCK} END, "
        "CASE WHEN {MINIMAL} THEN '' ELSE {DEVICE} END, 0, '', 1 "
        "FROM {TBL} r, {FIELDS} f WHERE r.id = NEW.id AND r.sync_id IS NOT NULL AND {PUBLISH} "
        "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET v_time = excluded.v_time, "
        "v_device = excluded.v_device, base_time = 0, base_device = '', pending = 1; "
        "INSERT INTO sync_outbox (tbl, sync_id, change_time) "
        "SELECT '{TBL}', r.sync_id, {CLOCK} FROM {TBL} r "
        "WHERE r.id = NEW.id AND r.sync_id IS NOT NULL AND {PUBLISH} "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time; "
        "{CLEAR_RECLAIM}"
        "END"),
        {{QStringLiteral("{NAME}"), name},
         {QStringLiteral("{TBL}"), table.name},
         {QStringLiteral("{NOT_APPLYING}"), sqlNotApplyingRemote()},
         {QStringLiteral("{ADVANCE}"), sqlAdvanceClock()},
         {QStringLiteral("{NEW_ID}"), newSyncIdExpression(table)},
         {QStringLiteral("{MINIMAL}"), minimalVersionCondition(table)},
         {QStringLiteral("{CLOCK}"), sqlCurrentClock()},
         {QStringLiteral("{DEVICE}"), sqlDeviceId()},
         {QStringLiteral("{FIELDS}"), fieldValuesSql(table)},
         {QStringLiteral("{PUBLISH}"), publishConditionFor(table, QStringLiteral("r"))},
         {QStringLiteral("{CLEAR_RECLAIM}"), clearReclaim}});
    return {name, sql};
}

QPair<QString, QString> updateTrigger(const Table& table)
{
    const QString name = table.name + QStringLiteral("_sync_au");
    QStringList changed;
    QStringList perField;
    for (const Field& field : table.fields) {
        changed.append(QStringLiteral("OLD.%1 IS NOT NEW.%1").arg(field.column));
        // 只给真的变了的列记新版本。base 记「对方可能已经见过的那一版」：这一列上一次改动还没发出去时，
        // 对方见过的仍是更早那一版，所以保留原 base 不动。冲突日志靠它区分「先后修改」和「同时修改」。
        perField.append(fill(QStringLiteral(
            "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
            "SELECT '{TBL}', NEW.sync_id, '{COL}', {CLOCK}, {DEVICE}, 0, '', 1 WHERE OLD.{COL} IS NOT NEW.{COL} "
            "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET "
            "base_time = CASE WHEN pending = 1 THEN base_time ELSE v_time END, "
            "base_device = CASE WHEN pending = 1 THEN base_device ELSE v_device END, "
            "v_time = excluded.v_time, v_device = excluded.v_device, pending = 1;"),
            {{QStringLiteral("{TBL}"), table.name},
             {QStringLiteral("{COL}"), field.column},
             {QStringLiteral("{CLOCK}"), sqlCurrentClock()},
             {QStringLiteral("{DEVICE}"), sqlDeviceId()}}));
    }
    const QString sql = fill(QStringLiteral(
        "CREATE TRIGGER {NAME} AFTER UPDATE OF {COLUMNS} ON {TBL} "
        "WHEN {NOT_APPLYING} AND NEW.sync_id IS NOT NULL AND {PUBLISH_OLD} AND {PUBLISH_NEW} "
        "AND ({CHANGED}) BEGIN "
        "{ADVANCE} "
        "{PER_FIELD} "
        "INSERT INTO sync_outbox (tbl, sync_id, change_time) VALUES ('{TBL}', NEW.sync_id, {CLOCK}) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time; "
        "END"),
        {{QStringLiteral("{NAME}"), name},
         {QStringLiteral("{COLUMNS}"), columnList(table)},
         {QStringLiteral("{TBL}"), table.name},
         {QStringLiteral("{NOT_APPLYING}"), sqlNotApplyingRemote()},
         {QStringLiteral("{PUBLISH_OLD}"), publishConditionFor(table, QStringLiteral("OLD"))},
         {QStringLiteral("{PUBLISH_NEW}"), publishConditionFor(table, QStringLiteral("NEW"))},
         {QStringLiteral("{CHANGED}"), changed.join(QStringLiteral(" OR "))},
         {QStringLiteral("{ADVANCE}"), sqlAdvanceClock()},
         {QStringLiteral("{PER_FIELD}"), perField.join(QLatin1Char(' '))},
         {QStringLiteral("{CLOCK}"), sqlCurrentClock()}});
    return {name, sql};
}

// 行从「不发布」变成「发布」（专注记录结束那一刻）：此前没有记过任何字段版本，整条补发。
QPair<QString, QString> publishTrigger(const Table& table)
{
    const QString name = table.name + QStringLiteral("_sync_publish");
    const QString sql = fill(QStringLiteral(
        "CREATE TRIGGER {NAME} AFTER UPDATE OF {COLUMNS} ON {TBL} "
        "WHEN {NOT_APPLYING} AND NEW.sync_id IS NOT NULL AND NOT ({PUBLISH_OLD}) AND {PUBLISH_NEW} BEGIN "
        "{ADVANCE} "
        "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
        "SELECT '{TBL}', NEW.sync_id, f.column1, {CLOCK}, {DEVICE}, 0, '', 1 FROM {FIELDS} f WHERE 1 "
        "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET v_time = excluded.v_time, "
        "v_device = excluded.v_device, base_time = 0, base_device = '', pending = 1; "
        "INSERT INTO sync_outbox (tbl, sync_id, change_time) VALUES ('{TBL}', NEW.sync_id, {CLOCK}) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time; "
        "END"),
        {{QStringLiteral("{NAME}"), name},
         {QStringLiteral("{COLUMNS}"), columnList(table)},
         {QStringLiteral("{TBL}"), table.name},
         {QStringLiteral("{NOT_APPLYING}"), sqlNotApplyingRemote()},
         {QStringLiteral("{PUBLISH_OLD}"), publishConditionFor(table, QStringLiteral("OLD"))},
         {QStringLiteral("{PUBLISH_NEW}"), publishConditionFor(table, QStringLiteral("NEW"))},
         {QStringLiteral("{ADVANCE}"), sqlAdvanceClock()},
         {QStringLiteral("{CLOCK}"), sqlCurrentClock()},
         {QStringLiteral("{DEVICE}"), sqlDeviceId()},
         {QStringLiteral("{FIELDS}"), fieldValuesSql(table)}});
    return {name, sql};
}

QPair<QString, QString> deleteTrigger(const Table& table)
{
    const QString name = table.name + QStringLiteral("_sync_ad");
    // 任务的删除分两种：用户删掉的（删除优先，永不复活），和例行「收回」的当日实例
    // （之后重新启用时可以再生成）。RoutineManager 收回前在同一事务里把 sync_runtime.delete_kind
    // 置成 'reclaim'，删完立刻复位。其余表只有普通删除。
    const QString kind = table.name == QLatin1String("tasks")
        ? QStringLiteral("COALESCE((SELECT delete_kind FROM sync_runtime WHERE singleton_id = 1), 'delete')")
        : QStringLiteral("'delete'");
    const QString sql = fill(QStringLiteral(
        "CREATE TRIGGER {NAME} AFTER DELETE ON {TBL} "
        "WHEN {NOT_APPLYING} AND OLD.sync_id IS NOT NULL AND {PUBLISH_OLD} BEGIN "
        "{ADVANCE} "
        "INSERT INTO sync_tombstones (tbl, sync_id, v_time, v_device, kind, merged_into, deleted_at) "
        "VALUES ('{TBL}', OLD.sync_id, {CLOCK}, {DEVICE}, {KIND}, NULL, {NOW}) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET v_time = excluded.v_time, v_device = excluded.v_device, "
        "kind = excluded.kind, merged_into = NULL, deleted_at = excluded.deleted_at; "
        "DELETE FROM sync_field_versions WHERE tbl = '{TBL}' AND sync_id = OLD.sync_id; "
        "INSERT INTO sync_outbox (tbl, sync_id, change_time) VALUES ('{TBL}', OLD.sync_id, {CLOCK}) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time; "
        "END"),
        {{QStringLiteral("{NAME}"), name},
         {QStringLiteral("{TBL}"), table.name},
         {QStringLiteral("{NOT_APPLYING}"), sqlNotApplyingRemote()},
         {QStringLiteral("{PUBLISH_OLD}"), publishConditionFor(table, QStringLiteral("OLD"))},
         {QStringLiteral("{ADVANCE}"), sqlAdvanceClock()},
         {QStringLiteral("{CLOCK}"), sqlCurrentClock()},
         {QStringLiteral("{DEVICE}"), sqlDeviceId()},
         {QStringLiteral("{KIND}"), kind},
         {QStringLiteral("{NOW}"), sqlNowMs()}});
    return {name, sql};
}

QHash<QString, QString> computeCanonicalTriggerSql()
{
    QHash<QString, QString> result;
    const QString connection = QStringLiteral("sync-schema-canonical-%1")
                                   .arg(QUuid::createUuid().toString(QUuid::Id128));
    {
        QSqlDatabase memory = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        memory.setDatabaseName(QStringLiteral(":memory:"));
        if (memory.open()) {
            QSqlQuery query(memory);
            // 触发器挂在业务表上，体里引用同步附属表。这里建出最小结构：业务表只需列名对得上，
            // 附属表直接用真实的建表语句。
            QStringList scaffold;
            for (const Table& table : tables()) {
                scaffold.append(QStringLiteral("CREATE TABLE %1 (id INTEGER PRIMARY KEY, sync_id, %2)")
                                    .arg(table.name, columnList(table)));
            }
            bool ok = true;
            for (const QString& sql : scaffold + tableStatements()) {
                ok = ok && query.exec(sql);
            }
            for (const auto& trigger : triggers()) {
                ok = ok && query.exec(trigger.second);
            }
            if (ok && query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"))) {
                while (query.next()) {
                    result.insert(query.value(0).toString(), query.value(1).toString());
                }
            }
            query.finish();
            memory.close();
        }
    }
    QSqlDatabase::removeDatabase(connection);
    return result;
}

} // namespace

const QList<Table>& tables()
{
    static const QList<Table> cached = buildTables();
    return cached;
}

const Table* table(const QString& name)
{
    for (const Table& candidate : tables()) {
        if (candidate.name == name) {
            return &candidate;
        }
    }
    return nullptr;
}

const Field* field(const QString& tableName, const QString& column)
{
    const Table* spec = table(tableName);
    if (!spec) {
        return nullptr;
    }
    for (const Field& candidate : spec->fields) {
        if (candidate.column == column) {
            return &candidate;
        }
    }
    return nullptr;
}

QString publishConditionFor(const Table& table, const QString& row)
{
    if (table.publishCondition.isEmpty()) {
        return QStringLiteral("1");
    }
    QString condition = table.publishCondition;
    condition.replace(QStringLiteral("%1"), row);
    return QStringLiteral("(%1)").arg(condition);
}

QString fieldValuesSql(const Table& table)
{
    QStringList rows;
    for (const Field& field : table.fields) {
        rows.append(QStringLiteral("('%1')").arg(field.column));
    }
    return QStringLiteral("(VALUES %1)").arg(rows.join(QStringLiteral(", ")));
}

QStringList infrastructureTableNames()
{
    return {QStringLiteral("sync_state"), QStringLiteral("sync_runtime"),
            QStringLiteral("sync_field_versions"), QStringLiteral("sync_outbox"),
            QStringLiteral("sync_tombstones"), QStringLiteral("sync_settings"),
            QStringLiteral("sync_conflict_log"), QStringLiteral("sync_pending_refs")};
}

QStringList tableStatements()
{
    return {
        // 同步状态：device_id（本设备标识）、hlc（最近一次发出的逻辑时间）、epoch（同步纪元，
        // 恢复备份做全局回滚时加一）。值一律存文本，读时再转换。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_state ("
                       "key TEXT PRIMARY KEY, value TEXT NOT NULL)"),
        // 只有一行的运行标记，全部在事务里置位、复位：
        //   applying     正在应用远端改动，触发器全部跳过；
        //   delete_kind  这次删除的类别（例行收回时为 'reclaim'），为空即普通删除；
        //   test_now_ms  测试注入的时钟，正式运行恒为 NULL。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_runtime ("
                       "singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1), "
                       "applying INTEGER NOT NULL DEFAULT 0 CHECK(applying IN (0, 1)), "
                       "delete_kind TEXT, "
                       "test_now_ms INTEGER)"),
        // 字段版本：每条记录的每个同步列一行。pending = 1 表示这一列有本机改动还没发出去；
        // base 是改动前、对方可能已经见过的那一版，冲突日志据此判断是不是「同时修改」。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_field_versions ("
                       "tbl TEXT NOT NULL, sync_id TEXT NOT NULL, field TEXT NOT NULL, "
                       "v_time INTEGER NOT NULL, v_device TEXT NOT NULL, "
                       "base_time INTEGER NOT NULL DEFAULT 0, base_device TEXT NOT NULL DEFAULT '', "
                       "pending INTEGER NOT NULL DEFAULT 0 CHECK(pending IN (0, 1)), "
                       "PRIMARY KEY (tbl, sync_id, field)) WITHOUT ROWID"),
        // 待发送队列：每条记录至多一行。change_time 是最近一次本机改动的逻辑时间；
        // 确认已写进同步文件时，只删 change_time 没变的行，期间又改过的留到下一批。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_outbox ("
                       "tbl TEXT NOT NULL, sync_id TEXT NOT NULL, change_time INTEGER NOT NULL, "
                       "PRIMARY KEY (tbl, sync_id)) WITHOUT ROWID"),
        // 删除记录：kind 为 delete（用户删除，删除优先）、reclaim（例行收回，可被重新生成取代）
        // 或 merge（同名科目合并掉的一方，merged_into 指向留下的那个，引用据此改指过去）。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_tombstones ("
                       "tbl TEXT NOT NULL, sync_id TEXT NOT NULL, "
                       "v_time INTEGER NOT NULL, v_device TEXT NOT NULL, "
                       "kind TEXT NOT NULL DEFAULT 'delete' CHECK(kind IN ('delete', 'reclaim', 'merge')), "
                       "merged_into TEXT, deleted_at INTEGER NOT NULL, "
                       "PRIMARY KEY (tbl, sync_id)) WITHOUT ROWID"),
        // 同步的设置项（第一期只有 logic/dayStartHour）。值本身存在 QSettings，这里只记版本和同步看到的值。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_settings ("
                       "key TEXT PRIMARY KEY, value TEXT NOT NULL, "
                       "v_time INTEGER NOT NULL, v_device TEXT NOT NULL, "
                       "base_time INTEGER NOT NULL DEFAULT 0, base_device TEXT NOT NULL DEFAULT '', "
                       "pending INTEGER NOT NULL DEFAULT 0 CHECK(pending IN (0, 1)))"),
        // 待解析的引用：收到的记录指向一条本机暂时没有的记录（还没收到，或被例行「收回」、之后可能补回来），
        // 引用列先落空值，并在这里记下目标。目标落地时按这里把引用接回去；记下时的版本对不上
        // （这一列后来又被改过）就作废，不去覆盖更新的值。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_pending_refs ("
                       "tbl TEXT NOT NULL, sync_id TEXT NOT NULL, field TEXT NOT NULL, "
                       "target_sync_id TEXT NOT NULL, v_time INTEGER NOT NULL, v_device TEXT NOT NULL, "
                       "PRIMARY KEY (tbl, sync_id, field)) WITHOUT ROWID"),
        // 冲突日志：自动处理掉的冲突留一笔，设置页可以查。只存给人看的文字，不存原始编码。
        QStringLiteral("CREATE TABLE IF NOT EXISTS sync_conflict_log ("
                       "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                       "logged_at TEXT NOT NULL, kind TEXT NOT NULL, "
                       "tbl TEXT NOT NULL, sync_id TEXT NOT NULL, record_label TEXT NOT NULL DEFAULT '', "
                       "field TEXT NOT NULL DEFAULT '', "
                       "lost_value TEXT NOT NULL DEFAULT '', kept_value TEXT NOT NULL DEFAULT '', "
                       "lost_device TEXT NOT NULL DEFAULT '', kept_device TEXT NOT NULL DEFAULT '', "
                       "detail TEXT NOT NULL DEFAULT '')"),
    };
}

QStringList indexStatements()
{
    QStringList statements;
    for (const Table& table : tables()) {
        statements.append(QStringLiteral("CREATE UNIQUE INDEX IF NOT EXISTS idx_%1_sync_id ON %1(sync_id)")
                              .arg(table.name));
    }
    return statements;
}

QStringList seedStatements()
{
    // 顺序有讲究：时钟表达式要读 sync_runtime，所以先种运行标记这一行。
    return {
        QStringLiteral("INSERT OR IGNORE INTO sync_runtime (singleton_id, applying) VALUES (1, 0)"),
        QStringLiteral("INSERT OR IGNORE INTO sync_state (key, value) "
                       "VALUES ('device_id', lower(hex(randomblob(16))))"),
        QStringLiteral("INSERT OR IGNORE INTO sync_state (key, value) VALUES ('hlc', CAST(%1 AS TEXT))")
            .arg(sqlNowMs()),
        QStringLiteral("INSERT OR IGNORE INTO sync_state (key, value) VALUES ('epoch', '0')"),
    };
}

QList<QPair<QString, QString>> triggers()
{
    QList<QPair<QString, QString>> result;
    for (const Table& table : tables()) {
        result.append(insertTrigger(table));
        result.append(updateTrigger(table));
        if (!table.publishCondition.isEmpty()) {
            result.append(publishTrigger(table));
        }
        result.append(deleteTrigger(table));
    }
    return result;
}

QHash<QString, QString> canonicalTriggerSql()
{
    // 函数内静态变量的初始化是线程安全的；备份检查可能在工作线程里第一次调用。
    static const QHash<QString, QString> cached = computeCanonicalTriggerSql();
    return cached;
}

bool isSyncTriggerName(const QString& name)
{
    for (const Table& table : tables()) {
        if (name.startsWith(table.name + QStringLiteral("_sync_"))) {
            return true;
        }
    }
    return false;
}

QString sqlNowMs()
{
    // julianday('now') 精确到毫秒；2440587.5 是 1970-01-01 的儒略日。
    return QStringLiteral(
        "COALESCE((SELECT test_now_ms FROM sync_runtime WHERE singleton_id = 1), "
        "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER))");
}

QString sqlAdvanceClock()
{
    // 新的逻辑时间 = max(此刻, 上一次 + 1)，严格递增，和数据写入在同一个事务里，崩溃也不会倒退。
    return QStringLiteral("UPDATE sync_state SET value = CAST(MAX(%1, CAST(value AS INTEGER) + 1) AS TEXT) "
                          "WHERE key = 'hlc';")
        .arg(sqlNowMs());
}

QString sqlCurrentClock()
{
    // 状态行缺失（外部改过库）时退回此刻，不能让版本写成 NULL 撞上约束，把用户的写入一起挡掉。
    return QStringLiteral("COALESCE((SELECT CAST(value AS INTEGER) FROM sync_state WHERE key = 'hlc'), %1)")
        .arg(sqlNowMs());
}

QString sqlDeviceId()
{
    return QStringLiteral("COALESCE((SELECT value FROM sync_state WHERE key = 'device_id'), '')");
}

QString sqlNotApplyingRemote()
{
    // 标记行缺失时按「不是在应用远端改动」处理：宁可多记一笔本机改动，也不能静默漏记。
    return QStringLiteral("COALESCE((SELECT applying FROM sync_runtime WHERE singleton_id = 1), 0) = 0");
}

namespace {

const auto kDailyGoalPrefix = QStringLiteral("focus/dailyGoalHistory/");

QString clockText(int minutes)
{
    return QStringLiteral("%1:%2").arg(minutes / 60, 2, 10, QLatin1Char('0')).arg(minutes % 60, 2, 10, QLatin1Char('0'));
}

} // namespace

QStringList syncedSettingKeys()
{
    return {
        QStringLiteral("logic/dayStartHour"),
        QStringLiteral("focus/workMinutes"),
        QStringLiteral("focus/breakMinutes"),
        QStringLiteral("focus/longBreakEnabled"),
        QStringLiteral("focus/longBreakMinutes"),
        QStringLiteral("focus/longBreakInterval"),
        QStringLiteral("focus/freeTimerWarningHours"),
        QStringLiteral("profile/nickname"),
        QStringLiteral("schedule/semesterStartDate"),
        QStringLiteral("schedule/semesterWeeks"),
        QStringLiteral("schedule/periods"),
    };
}

QString dailyGoalSettingKey(const QString& isoDate)
{
    return kDailyGoalPrefix + isoDate;
}

QString dailyGoalDateOf(const QString& key)
{
    if (!key.startsWith(kDailyGoalPrefix)) {
        return QString();
    }
    const QString date = key.mid(kDailyGoalPrefix.size());
    return QDate::fromString(date, Qt::ISODate).isValid() && date.size() == 10 ? date : QString();
}

bool isSyncedSettingKey(const QString& key)
{
    return syncedSettingKeys().contains(key) || !dailyGoalDateOf(key).isEmpty();
}

QString settingLabel(const QString& key)
{
    static const QHash<QString, QString> labels{
        {QStringLiteral("logic/dayStartHour"), QStringLiteral("逻辑日起点")},
        {QStringLiteral("focus/workMinutes"), QStringLiteral("番茄时长")},
        {QStringLiteral("focus/breakMinutes"), QStringLiteral("休息时长")},
        {QStringLiteral("focus/longBreakEnabled"), QStringLiteral("长休息")},
        {QStringLiteral("focus/longBreakMinutes"), QStringLiteral("长休息时长")},
        {QStringLiteral("focus/longBreakInterval"), QStringLiteral("长休息间隔")},
        {QStringLiteral("focus/freeTimerWarningHours"), QStringLiteral("超长计时提醒")},
        {QStringLiteral("profile/nickname"), QStringLiteral("昵称")},
        {QStringLiteral("schedule/semesterStartDate"), QStringLiteral("学期起始日")},
        {QStringLiteral("schedule/semesterWeeks"), QStringLiteral("学期周数")},
        {QStringLiteral("schedule/periods"), QStringLiteral("课表节次")},
    };
    const QString date = dailyGoalDateOf(key);
    if (!date.isEmpty()) {
        return QStringLiteral("今日目标（%1）").arg(QDate::fromString(date, Qt::ISODate).toString(QStringLiteral("M月d日")));
    }
    return labels.value(key, key);
}

QString settingDisplay(const QString& key, const QString& value)
{
    if (key == QLatin1String("logic/dayStartHour")) {
        return QStringLiteral("%1 点").arg(value);
    }
    if (key == QLatin1String("focus/workMinutes") || key == QLatin1String("focus/breakMinutes")
        || key == QLatin1String("focus/longBreakMinutes") || !dailyGoalDateOf(key).isEmpty()) {
        return QStringLiteral("%1 分钟").arg(value);
    }
    if (key == QLatin1String("focus/longBreakEnabled")) {
        return value == QLatin1String("1") ? QStringLiteral("开") : QStringLiteral("关");
    }
    if (key == QLatin1String("focus/longBreakInterval")) {
        return QStringLiteral("每 %1 个番茄").arg(value);
    }
    if (key == QLatin1String("focus/freeTimerWarningHours")) {
        return QStringLiteral("%1 小时").arg(value);
    }
    if (key == QLatin1String("schedule/semesterWeeks")) {
        return QStringLiteral("%1 周").arg(value);
    }
    if (key == QLatin1String("schedule/semesterStartDate")) {
        return value.isEmpty() ? QStringLiteral("（未设置）") : value;
    }
    if (key == QLatin1String("schedule/periods")) {
        // 整张节次表：写出共几节、从几点到几点，够你认出是哪一份。
        const QJsonArray periods = QJsonDocument::fromJson(value.toUtf8()).array();
        if (periods.isEmpty()) {
            return QStringLiteral("（空）");
        }
        const int first = periods.first().toArray().at(0).toInt();
        const int last = periods.last().toArray().at(1).toInt();
        return QStringLiteral("%1 节，%2–%3").arg(periods.size()).arg(clockText(first), clockText(last));
    }
    return value.isEmpty() ? QStringLiteral("（空）") : value;
}

QString presetCategorySyncId(int slot)
{
    return QStringLiteral("preset-%1").arg(slot);
}

QString routineInstanceSyncId(const QString& routineSyncId, const QString& isoDate)
{
    return QStringLiteral("rt-%1-%2").arg(routineSyncId, isoDate);
}

QString routineInstanceSyncIdSql(const QString& routineSyncIdExpr, const QString& dateExpr)
{
    return QStringLiteral("('rt-' || %1 || '-' || %2)").arg(routineSyncIdExpr, dateExpr);
}

} // namespace SyncSchema
