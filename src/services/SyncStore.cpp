#include "SyncStore.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "RoutineRules.h"
#include "SyncSchema.h"

#include <QDateTime>
#include <QDebug>
#include <QMap>
#include <QSqlError>
#include <QSqlQuery>

#include <algorithm>
#include <utility>

namespace {

// 冲突日志只留最近这么多条：它是给人翻看的，不是审计档案，不能无限长。
constexpr int kConflictLogLimit = 500;
// 合并链（A 并进 B、B 又并进 C……）最多追这么多步。合并总是并向身份较小的一方，不会成环；
// 上限只防外部改坏的数据让这里死循环。
constexpr int kMaxMergeHops = 16;

const QString kKindDelete = QStringLiteral("delete");
const QString kKindReclaim = QStringLiteral("reclaim");
const QString kKindMerge = QStringLiteral("merge");

struct LocalRow {
    bool exists = false;
    qint64 id = -1;
    // 列名 → 本机的值（引用列是本机编号）。
    QHash<QString, QVariant> values;
};

struct LocalVersion {
    SyncVersion version;
    SyncVersion base;
    bool pending = false;
};

struct Tombstone {
    bool exists = false;
    SyncVersion version;
    QString kind;
    QString mergedInto;
};

qsizetype tableOrder(const QString& table)
{
    const QList<SyncSchema::Table>& tables = SyncSchema::tables();
    for (qsizetype index = 0; index < tables.size(); ++index) {
        if (tables.at(index).name == table) {
            return index;
        }
    }
    return tables.size();
}

QStringList columnsOf(const SyncSchema::Table& table)
{
    QStringList columns;
    for (const SyncSchema::Field& field : table.fields) {
        columns.append(field.column);
    }
    return columns;
}

QString truncated(const QString& text)
{
    constexpr int kLimit = 200;
    return text.size() > kLimit ? text.left(kLimit) + QStringLiteral("…") : text;
}

// 空的 QString 绑定进 SQLite 是 NULL。版本里的设备标识可以是空串（最小版本），但列是 NOT NULL，
// 从 JSON 读回、或默认构造的版本里它可能是「空的 QString」，写库前一律收敛成空串。
QString nonNull(const QString& text)
{
    return text.isNull() ? QStringLiteral("") : text;
}

// 应用一批远端改动的全部状态。只活在 applyRemote 的一个事务里。
class Applier
{
public:
    Applier(QSqlDatabase db, QString me, SyncStore::ApplyResult* result)
        : m_db(std::move(db)), m_me(std::move(me)), m_result(result)
    {
    }

    // 应用一条记录。返回 false 表示这一条失败（error 里是原因），调用方回滚它的保存点、记日志、继续下一条。
    bool apply(const SyncRecord& record, QString* error);
    // 应用一个设置项：版本新的赢；变了的交给调用方写回 AppSettings。
    bool applySetting(const SyncSettingRecord& setting, QString* error);

    // 用快照整体替换（见 SyncStore::replaceWithSnapshot）。第一步删掉快照里没有的本机记录、清空同步状态；
    // 之后逐条调用 overwriteFromSnapshot 落地快照记录（调用方给每条套保存点）。
    bool dropRecordsMissingFrom(const SyncBatch& snapshot, QString* error);
    bool overwriteFromSnapshot(const SyncRecord& record, QString* error);
    bool replaceSettings(const QList<SyncSettingRecord>& settings, QString* error);
    qint64 maxSeenTime() const { return m_maxSeenTime; }
    bool logSkipped(const SyncRecord& record, const QString& reason);

    // 全部记录应用完之后的两步收尾，都在同一个事务里：
    // 1. 科目落最终名。应用时改名的科目先用临时名，等整批落地再逐个换回，这样两个科目互换名字时
    //    不会在中途被误判成撞名；真撞了名，就按确定规则合并（或给预置科目加后缀）。
    bool finalizeCategoryNames(QString* error);
    // 2. 本批动过的日期如果出现重复或非正的任务排序号，按确定规则重排。重排作为本机改动照常发出，
    //    不走 v12 迁移那条修复路径——那条路径每次都会生成一份迁移快照（sol6 审查第 7 条）。
    bool normalizeTaskOrders(QString* error);

private:
    bool applyDeletion(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row,
                       const Tombstone& local, QString* error);
    bool applyToDeleted(const SyncSchema::Table& table, const SyncRecord& record, const Tombstone& local,
                        bool* resurrected, QString* error);
    bool insertRow(const SyncSchema::Table& table, const SyncRecord& record, QString* error);
    bool mergeRow(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row, QString* error);
    bool deleteLocalRow(const SyncSchema::Table& table, const LocalRow& row, const Tombstone& tombstone,
                        QString* error);

    // 读本机现状。
    bool readRow(const SyncSchema::Table& table, const QString& syncId, LocalRow* row, QString* error);
    QHash<QString, LocalVersion> readVersions(const QString& table, const QString& syncId);
    Tombstone readTombstone(const QString& table, const QString& syncId);
    SyncVersion latestLocalVersion(const QString& table, const QString& syncId);

    // 引用：本机编号 ↔ sync_id。
    QVariant syncIdOfLocal(const QString& table, const QVariant& localId);
    // 按 sync_id 找本机编号，沿合并记录追到留下的那一条。找不到（已删除或从没见过）返回空，并置 dangling。
    QVariant resolveLocal(const QString& table, const QVariant& syncId, bool* dangling);
    // 待解析的引用（见 SyncSchema 里 sync_pending_refs 的说明）。收下一个引用列之后调用：
    // 目标找不到、又不是被永久删除（用户删除或合并）的，记下来；找得到或已永久删除的，清掉旧记录。
    bool noteReference(const QString& table, const QString& syncId, const SyncSchema::Field& field,
                       const SyncFieldValue& incoming, bool dangling, QString* error);
    // 一条记录落地之后调用：之前指向它、只能先置空的引用，现在接回来。
    bool resolvePendingRefsTo(const QString& targetTable, const QString& targetSyncId, qint64 localId,
                              QString* error);

    bool writeTombstone(const QString& table, const QString& syncId, const Tombstone& tombstone, QString* error);
    bool writeVersion(const QString& table, const QString& syncId, const QString& field,
                      const SyncFieldValue& value, QString* error);
    bool clearLocalSyncState(const QString& table, const QString& syncId, QString* error);
    bool exec(QSqlQuery& query, QString* error);

    // 冲突日志。
    void logConflict(const QString& kind, const SyncSchema::Table& table, const QString& syncId,
                     const QString& recordLabel, const QString& field, const QString& lostValue,
                     const QString& keptValue, const QString& lostDevice, const QString& keptDevice,
                     const QString& detail);
    QString recordLabel(const SyncSchema::Table& table, const QHash<QString, QVariant>& values);
    QString displayValue(const SyncSchema::Field& field, const QVariant& localValue);
    QString nameOf(const QString& table, const QVariant& localId);

    void touchTaskDate(const QVariant& date);

    // 科目撞名的处理。
    static QString temporaryCategoryName(const QString& syncId);
    bool mergeCategory(qint64 loserId, const QString& loserSyncId, qint64 winnerId, const QString& winnerSyncId,
                       const QString& name, QString* error);
    bool renameWithSuffix(qint64 id, const QString& name, QString* error);
    SyncVersion fieldVersion(const QString& table, const QString& syncId, const QString& field);

    // 以本机改动的身份发出：推进逻辑时钟，给这一列记新版本并入队。用于合并、收回被拒后补发。
    bool advanceClock(SyncVersion* version, QString* error);
    bool republish(const QString& table, const QString& syncId, const QString& field, QString* error);
    // 临时放开触发器：排序归一、预置科目加后缀是本机改动，要由触发器照常记版本、入队。
    bool setApplying(bool applying, QString* error);

    QSqlDatabase m_db;
    QString m_me;
    SyncStore::ApplyResult* m_result;
    qint64 m_maxSeenTime = 0;
    // 待落最终名的科目：sync_id → (本机编号, 最终名)。按 sync_id 排序处理，所有设备的处理顺序一致。
    QMap<QString, QPair<qint64, QString>> m_pendingCategoryNames;
    // 本批动过的任务日期（改前与改后），收尾时检查这些日期的排序号不变量。
    QSet<QString> m_touchedTaskDates;
};

bool Applier::exec(QSqlQuery& query, QString* error)
{
    if (query.exec()) {
        return true;
    }
    if (error) {
        *error = query.lastError().text();
    }
    return false;
}

bool Applier::readRow(const SyncSchema::Table& table, const QString& syncId, LocalRow* row, QString* error)
{
    const QStringList columns = columnsOf(table);
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT id, %1 FROM %2 WHERE sync_id = :id")
                      .arg(columns.join(QStringLiteral(", ")), table.name));
    query.bindValue(QStringLiteral(":id"), syncId);
    if (!exec(query, error)) {
        return false;
    }
    *row = LocalRow();
    if (query.next()) {
        row->exists = true;
        row->id = query.value(0).toLongLong();
        for (int index = 0; index < columns.size(); ++index) {
            row->values.insert(columns.at(index), query.value(index + 1));
        }
    }
    return true;
}

QHash<QString, LocalVersion> Applier::readVersions(const QString& table, const QString& syncId)
{
    QHash<QString, LocalVersion> versions;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "SELECT field, v_time, v_device, base_time, base_device, pending FROM sync_field_versions "
        "WHERE tbl = :tbl AND sync_id = :id"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    if (query.exec()) {
        while (query.next()) {
            LocalVersion version;
            version.version = {query.value(1).toLongLong(), query.value(2).toString()};
            version.base = {query.value(3).toLongLong(), query.value(4).toString()};
            version.pending = query.value(5).toInt() == 1;
            versions.insert(query.value(0).toString(), version);
        }
    }
    return versions;
}

Tombstone Applier::readTombstone(const QString& table, const QString& syncId)
{
    Tombstone tombstone;
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "SELECT v_time, v_device, kind, merged_into FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    if (query.exec() && query.next()) {
        tombstone.exists = true;
        tombstone.version = {query.value(0).toLongLong(), query.value(1).toString()};
        tombstone.kind = query.value(2).toString();
        tombstone.mergedInto = query.value(3).toString();
    }
    return tombstone;
}

SyncVersion Applier::latestLocalVersion(const QString& table, const QString& syncId)
{
    SyncVersion latest;
    for (const LocalVersion& version : readVersions(table, syncId)) {
        if (latest < version.version) {
            latest = version.version;
        }
    }
    return latest;
}

QVariant Applier::syncIdOfLocal(const QString& table, const QVariant& localId)
{
    if (!localId.isValid() || localId.isNull()) {
        return QVariant();
    }
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT sync_id FROM %1 WHERE id = :id").arg(table));
    query.bindValue(QStringLiteral(":id"), localId);
    if (query.exec() && query.next() && !query.value(0).toString().isEmpty()) {
        return query.value(0).toString();
    }
    // 本机编号指向的记录已经不在（例如专注记录里的科目快照，科目删掉后就是这样）：当作没有引用。
    return QVariant();
}

QVariant Applier::resolveLocal(const QString& table, const QVariant& syncId, bool* dangling)
{
    *dangling = false;
    if (!syncId.isValid() || syncId.isNull() || syncId.toString().isEmpty()) {
        return QVariant();
    }
    QString current = syncId.toString();
    for (int hop = 0; hop < kMaxMergeHops; ++hop) {
        QSqlQuery query(m_db);
        query.prepare(QStringLiteral("SELECT id FROM %1 WHERE sync_id = :id").arg(table));
        query.bindValue(QStringLiteral(":id"), current);
        if (query.exec() && query.next()) {
            return query.value(0);
        }
        const Tombstone tombstone = readTombstone(table, current);
        if (tombstone.exists && tombstone.kind == kKindMerge && !tombstone.mergedInto.isEmpty()) {
            current = tombstone.mergedInto;
            continue;
        }
        break;
    }
    *dangling = true;
    return QVariant();
}

bool Applier::writeTombstone(const QString& table, const QString& syncId, const Tombstone& tombstone,
                             QString* error)
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "INSERT INTO sync_tombstones (tbl, sync_id, v_time, v_device, kind, merged_into, deleted_at) "
        "VALUES (:tbl, :id, :t, :d, :kind, :into, :now) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET v_time = excluded.v_time, v_device = excluded.v_device, "
        "kind = excluded.kind, merged_into = excluded.merged_into, deleted_at = excluded.deleted_at"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    query.bindValue(QStringLiteral(":t"), tombstone.version.time);
    query.bindValue(QStringLiteral(":d"), nonNull(tombstone.version.device));
    query.bindValue(QStringLiteral(":kind"), tombstone.kind.isEmpty() ? kKindDelete : tombstone.kind);
    query.bindValue(QStringLiteral(":into"),
                    tombstone.mergedInto.isEmpty() ? QVariant() : QVariant(tombstone.mergedInto));
    query.bindValue(QStringLiteral(":now"), QDateTime::currentMSecsSinceEpoch());
    return exec(query, error);
}

bool Applier::writeVersion(const QString& table, const QString& syncId, const QString& field,
                           const SyncFieldValue& value, QString* error)
{
    // 收下的是对方的值：版本照抄对方，不再待发送。
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
        "VALUES (:tbl, :id, :field, :t, :d, :bt, :bd, 0) "
        "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET v_time = excluded.v_time, "
        "v_device = excluded.v_device, base_time = excluded.base_time, "
        "base_device = excluded.base_device, pending = 0"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    query.bindValue(QStringLiteral(":field"), field);
    query.bindValue(QStringLiteral(":t"), value.version.time);
    query.bindValue(QStringLiteral(":d"), nonNull(value.version.device));
    query.bindValue(QStringLiteral(":bt"), value.base.time);
    query.bindValue(QStringLiteral(":bd"), nonNull(value.base.device));
    return exec(query, error);
}

bool Applier::clearLocalSyncState(const QString& table, const QString& syncId, QString* error)
{
    QSqlQuery versions(m_db);
    versions.prepare(QStringLiteral("DELETE FROM sync_field_versions WHERE tbl = :tbl AND sync_id = :id"));
    versions.bindValue(QStringLiteral(":tbl"), table);
    versions.bindValue(QStringLiteral(":id"), syncId);
    QSqlQuery outbox(m_db);
    outbox.prepare(QStringLiteral("DELETE FROM sync_outbox WHERE tbl = :tbl AND sync_id = :id"));
    outbox.bindValue(QStringLiteral(":tbl"), table);
    outbox.bindValue(QStringLiteral(":id"), syncId);
    return exec(versions, error) && exec(outbox, error);
}

void Applier::touchTaskDate(const QVariant& date)
{
    if (date.isValid() && !date.isNull()) {
        m_touchedTaskDates.insert(date.toString());
    }
}

bool Applier::apply(const SyncRecord& record, QString* error)
{
    const SyncSchema::Table* table = SyncSchema::table(record.table);
    if (!table) {
        // 更新的版本多同步了一张表：这一版不认识，跳过，不影响其余记录。
        *error = QStringLiteral("不认识的数据表：%1").arg(record.table);
        return false;
    }
    m_maxSeenTime = qMax(m_maxSeenTime, record.latestVersion().time);

    LocalRow row;
    if (!readRow(*table, record.syncId, &row, error)) {
        return false;
    }
    const Tombstone local = readTombstone(table->name, record.syncId);

    if (record.deleted) {
        return applyDeletion(*table, record, row, local, error);
    }
    if (local.exists && !row.exists) {
        bool resurrected = false;
        if (!applyToDeleted(*table, record, local, &resurrected, error)) {
            return false;
        }
        if (!resurrected) {
            return true;
        }
    }
    return row.exists ? mergeRow(*table, record, row, error) : insertRow(*table, record, error);
}

bool Applier::applyDeletion(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row,
                            const Tombstone& local, QString* error)
{
    Tombstone incoming;
    incoming.exists = true;
    incoming.version = record.deleteVersion;
    incoming.kind = record.deleteKind.isEmpty() ? kKindDelete : record.deleteKind;
    incoming.mergedInto = record.mergedInto;

    // 两边都有删除记录时取一个：普通删除与合并都压过「收回」；同类的按版本取新的。
    // 所有设备按同一规则取，最后留下的删除记录一致。
    Tombstone winner = incoming;
    if (local.exists) {
        const bool localReclaim = local.kind == kKindReclaim;
        const bool incomingReclaim = incoming.kind == kKindReclaim;
        if (localReclaim != incomingReclaim) {
            winner = incomingReclaim ? local : incoming;
        } else {
            winner = local.version < incoming.version ? incoming : local;
        }
    }

    if (row.exists) {
        if (winner.kind == kKindReclaim && table.name == QLatin1String("tasks")) {
            // 收回只针对「没动过」的实例：本机已经完成、专注过，或本机之后又改过（版本更新），就留着。
            // 留着还不够：对方已经删了它，而本机这条若没有新改动就不会再发出，两边会一直不一致
            // （本机的专注记录挂在它上面，对方那边却没有这条任务）。所以用新版本把它重新发出去，
            // 新版本比那条收回记录新，对方收到就会把实例补回来。
            QSqlQuery touched(m_db);
            touched.prepare(QStringLiteral(
                "SELECT 1 FROM tasks t WHERE t.id = :id AND (t.completed = 1 "
                "OR EXISTS (SELECT 1 FROM focus_sessions fs WHERE fs.task_id = t.id))"));
            touched.bindValue(QStringLiteral(":id"), row.id);
            if (!exec(touched, error)) {
                return false;
            }
            if (touched.next() || winner.version < latestLocalVersion(table.name, record.syncId)) {
                return republish(table.name, record.syncId, QStringLiteral("routine_generated"), error);
            }
        }
        if (table.name == QLatin1String("categories") && row.values.value(QStringLiteral("is_preset")).toInt() == 1) {
            // 预置科目不能删除，任何设备都不会发出它的删除。收到了就是数据有问题，不照做。
            *error = QStringLiteral("收到删除预置科目的记录，已忽略");
            return false;
        }

        // 本机还没发出去的修改随删除作废，逐列记下来，你能在冲突日志里看到丢了什么。
        const QString label = recordLabel(table, row.values);
        const QHash<QString, LocalVersion> versions = readVersions(table.name, record.syncId);
        for (auto it = versions.cbegin(); it != versions.cend(); ++it) {
            const SyncSchema::Field* field = SyncSchema::field(table.name, it.key());
            if (!field || !it.value().pending || it.value().version.device != m_me) {
                continue;
            }
            logConflict(winner.kind == kKindMerge ? kKindMerge : kKindDelete, table, record.syncId, label,
                        field->column, displayValue(*field, row.values.value(field->column)),
                        QStringLiteral("（已删除）"), m_me, winner.version.device,
                        winner.kind == kKindMerge ? QStringLiteral("这个科目已和另一台设备上的同名科目合并")
                                                  : QStringLiteral("另一台设备删除了这条记录"));
        }

        if (!deleteLocalRow(table, row, winner, error)) {
            return false;
        }
        m_result->changedTables.insert(table.name);
    }

    if ((!local.exists || !(winner.version == local.version && winner.kind == local.kind))
        && !writeTombstone(table.name, record.syncId, winner, error)) {
        return false;
    }
    return clearLocalSyncState(table.name, record.syncId, error);
}

bool Applier::applyToDeleted(const SyncSchema::Table& table, const SyncRecord& record, const Tombstone& local,
                             bool* resurrected, QString* error)
{
    *resurrected = false;
    const SyncVersion incomingLatest = record.latestVersion();
    if (local.kind == kKindReclaim) {
        // 收回的实例可以被取代：对方完成过它，或对方在收回之后又生成、修改过它（版本更新）。
        const bool completed = record.fields.value(QStringLiteral("completed")).value.toInt() == 1;
        if (completed || local.version < incomingLatest) {
            QSqlQuery remove(m_db);
            remove.prepare(QStringLiteral("DELETE FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
            remove.bindValue(QStringLiteral(":tbl"), table.name);
            remove.bindValue(QStringLiteral(":id"), record.syncId);
            if (!exec(remove, error)) {
                return false;
            }
            *resurrected = true;
        }
        return true;
    }

    // 删除优先：已经删掉的记录收到修改，一律忽略。修改来自另一台设备、又不是两边各自生成的默认值时，
    // 就是和删除同时发生的修改，记一笔。
    if (local.version.device != incomingLatest.device && !incomingLatest.isMinimal()) {
        QHash<QString, QVariant> values;
        for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
            const SyncSchema::Field* field = SyncSchema::field(table.name, it.key());
            if (field && field->refTable.isEmpty()) {
                values.insert(it.key(), it.value().value);
            }
        }
        logConflict(local.kind == kKindMerge ? kKindMerge : kKindDelete, table, record.syncId,
                    recordLabel(table, values), QString(), QStringLiteral("（修改）"), QStringLiteral("（已删除）"),
                    incomingLatest.device, local.version.device,
                    local.kind == kKindMerge ? QStringLiteral("这个科目已和同名科目合并，另一台设备对它的修改没有生效")
                                             : QStringLiteral("这条记录已被删除，另一台设备对它的修改没有生效"));
    }
    return true;
}

bool Applier::insertRow(const SyncSchema::Table& table, const SyncRecord& record, QString* error)
{
    QStringList columns{QStringLiteral("sync_id")};
    QVariantList values{record.syncId};
    bool categoryDangling = false;
    bool routineDangling = false;
    QList<QPair<const SyncSchema::Field*, bool>> references;
    for (const SyncSchema::Field& field : table.fields) {
        if (!record.fields.contains(field.column)) {
            // 发送方没有这一列（更老的版本）：不写，落库时取表的默认值。
            continue;
        }
        QVariant value = record.fields.value(field.column).value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            value = resolveLocal(field.refTable, value, &dangling);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDangling = routineDangling || (dangling && field.column == QLatin1String("routine_id"));
            references.append({&field, dangling});
        }
        columns.append(field.column);
        values.append(value);
    }
    // 引用的目标已经删除：按本机删除它时的做法落地。
    if (table.name == QLatin1String("tasks")) {
        const qsizetype categoryText = columns.indexOf(QStringLiteral("category"));
        if (categoryDangling && categoryText >= 0) {
            values[categoryText] = QVariant();
        }
        const qsizetype generated = columns.indexOf(QStringLiteral("routine_generated"));
        if (routineDangling && generated >= 0) {
            values[generated] = 0;
        }
    }
    // 科目名先落临时名，整批应用完再换成最终名（见 finalizeCategoryNames）。
    const qsizetype nameColumn = table.name == QLatin1String("categories") ? columns.indexOf(QStringLiteral("name")) : -1;
    const QString finalName = nameColumn >= 0 ? values.at(nameColumn).toString() : QString();
    if (nameColumn >= 0) {
        values[nameColumn] = temporaryCategoryName(record.syncId);
    }

    QStringList placeholders;
    for (int index = 0; index < columns.size(); ++index) {
        placeholders.append(QStringLiteral("?"));
    }
    QSqlQuery insert(m_db);
    insert.prepare(QStringLiteral("INSERT INTO %1 (%2) VALUES (%3)")
                       .arg(table.name, columns.join(QStringLiteral(", ")), placeholders.join(QStringLiteral(", "))));
    for (const QVariant& value : values) {
        insert.addBindValue(value);
    }
    if (!exec(insert, error)) {
        return false;
    }
    const qint64 insertedId = insert.lastInsertId().toLongLong();
    if (nameColumn >= 0) {
        m_pendingCategoryNames.insert(record.syncId, {insertedId, finalName});
    }

    for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
        if (SyncSchema::field(table.name, it.key()) && !writeVersion(table.name, record.syncId, it.key(), it.value(), error)) {
            return false;
        }
    }
    for (const auto& reference : references) {
        if (!noteReference(table.name, record.syncId, *reference.first,
                           record.fields.value(reference.first->column), reference.second, error)) {
            return false;
        }
    }
    // 这条记录可能正是别人等着的引用目标（先到的专注记录指向它，而它是被收回后又补回来的）。
    if (!resolvePendingRefsTo(table.name, record.syncId, insertedId, error)) {
        return false;
    }
    if (table.name == QLatin1String("tasks")) {
        touchTaskDate(record.fields.value(QStringLiteral("date")).value);
    }
    m_result->changedTables.insert(table.name);
    return true;
}

bool Applier::noteReference(const QString& table, const QString& syncId, const SyncSchema::Field& field,
                            const SyncFieldValue& incoming, bool dangling, QString* error)
{
    QSqlQuery clear(m_db);
    clear.prepare(QStringLiteral("DELETE FROM sync_pending_refs WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
    clear.bindValue(QStringLiteral(":tbl"), table);
    clear.bindValue(QStringLiteral(":id"), syncId);
    clear.bindValue(QStringLiteral(":field"), field.column);
    if (!exec(clear, error)) {
        return false;
    }
    const QString target = incoming.value.toString();
    if (!dangling || incoming.value.isNull() || target.isEmpty()) {
        return true;
    }
    // 目标被用户删除（或合并后又追不到）是永久的：置空就是最终结果，与本机删除它时一样，不用等。
    const Tombstone tombstone = readTombstone(field.refTable, target);
    if (tombstone.exists && tombstone.kind != kKindReclaim) {
        return true;
    }
    QSqlQuery note(m_db);
    note.prepare(QStringLiteral(
        "INSERT INTO sync_pending_refs (tbl, sync_id, field, target_sync_id, v_time, v_device) "
        "VALUES (:tbl, :id, :field, :target, :t, :d)"));
    note.bindValue(QStringLiteral(":tbl"), table);
    note.bindValue(QStringLiteral(":id"), syncId);
    note.bindValue(QStringLiteral(":field"), field.column);
    note.bindValue(QStringLiteral(":target"), target);
    note.bindValue(QStringLiteral(":t"), incoming.version.time);
    note.bindValue(QStringLiteral(":d"), nonNull(incoming.version.device));
    return exec(note, error);
}

bool Applier::resolvePendingRefsTo(const QString& targetTable, const QString& targetSyncId, qint64 localId,
                                   QString* error)
{
    struct Pending {
        QString table;
        QString syncId;
        QString field;
        SyncVersion version;
    };
    QList<Pending> pending;
    QSqlQuery find(m_db);
    find.prepare(QStringLiteral(
        "SELECT tbl, sync_id, field, v_time, v_device FROM sync_pending_refs WHERE target_sync_id = :target"));
    find.bindValue(QStringLiteral(":target"), targetSyncId);
    if (!exec(find, error)) {
        return false;
    }
    while (find.next()) {
        pending.append({find.value(0).toString(), find.value(1).toString(), find.value(2).toString(),
                        {find.value(3).toLongLong(), find.value(4).toString()}});
    }
    find.finish();

    for (const Pending& item : pending) {
        const SyncSchema::Field* field = SyncSchema::field(item.table, item.field);
        QSqlQuery remove(m_db);
        remove.prepare(QStringLiteral(
            "DELETE FROM sync_pending_refs WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
        remove.bindValue(QStringLiteral(":tbl"), item.table);
        remove.bindValue(QStringLiteral(":id"), item.syncId);
        remove.bindValue(QStringLiteral(":field"), item.field);
        if (!exec(remove, error)) {
            return false;
        }
        // 只接回「还是当初那次写入」的引用：这一列后来被改过（本机改了，或对方发来更新的值），就以后来的为准。
        if (!field || field->refTable != targetTable || fieldVersion(item.table, item.syncId, item.field) != item.version) {
            continue;
        }
        QSqlQuery relink(m_db);
        relink.prepare(QStringLiteral("UPDATE %1 SET %2 = :target WHERE sync_id = :id AND %2 IS NULL")
                           .arg(item.table, item.field));
        relink.bindValue(QStringLiteral(":target"), localId);
        relink.bindValue(QStringLiteral(":id"), item.syncId);
        if (!exec(relink, error)) {
            return false;
        }
        if (relink.numRowsAffected() > 0) {
            m_result->changedTables.insert(item.table);
        }
    }
    return true;
}

bool Applier::mergeRow(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row,
                       QString* error)
{
    const QHash<QString, LocalVersion> versions = readVersions(table.name, record.syncId);
    const QString label = recordLabel(table, row.values);
    QStringList assignments;
    QVariantList assignedValues;
    QList<QPair<QString, SyncFieldValue>> newVersions;
    bool categoryDangling = false;
    bool routineDangling = false;

    for (const SyncSchema::Field& field : table.fields) {
        if (!record.fields.contains(field.column)) {
            continue;
        }
        const SyncFieldValue incoming = record.fields.value(field.column);
        const LocalVersion local = versions.value(field.column);
        const QVariant localValue = row.values.value(field.column);
        // 比较一律用「同步里的表示」：引用列比较的是 sync_id，本机编号在两台设备上本来就不同。
        const QVariant localSyncValue = field.refTable.isEmpty() ? localValue
                                                                 : syncIdOfLocal(field.refTable, localValue);
        const bool sameValue = SyncJson::canonicalValue(localSyncValue) == SyncJson::canonicalValue(incoming.value);

        bool takeIncoming = false;
        if (incoming.version == local.version) {
            // 版本相同而值不同有两种来源：
            // - 两台设备各自生成的默认值（最小版本）：取规范文本较小的那个，两台设备算出同一个结果，不记日志；
            // - 本机按规则推出来的值（引用的目标已删除而置空、合并后改指）：版本还是对方那一版，值却是本机推的。
            //   这种各留各的——对方收到同一个删除或合并记录后会推出同样的值；反过来要是按大小取，
            //   本机推出的空值会被发回去，把对方还正常的引用也清掉。
            takeIncoming = !sameValue && incoming.version.isMinimal()
                && SyncJson::canonicalValue(incoming.value) < SyncJson::canonicalValue(localSyncValue);
        } else if (local.version < incoming.version) {
            takeIncoming = true;
            // 本机自己的修改被对方更新的修改覆盖，且对方改的时候没见过本机这一版：同时修改，记下丢掉的本机值。
            if (!sameValue && local.version.device == m_me && !local.version.isMinimal()
                && incoming.base != local.version) {
                bool dangling = false;
                const QVariant incomingLocal = field.refTable.isEmpty()
                    ? incoming.value : resolveLocal(field.refTable, incoming.value, &dangling);
                logConflict(QStringLiteral("edit"), table, record.syncId, label, field.column,
                            displayValue(field, localValue), displayValue(field, incomingLocal), m_me,
                            incoming.version.device, QStringLiteral("两台设备同时改了这一项，以较晚的修改为准"));
            }
        } else if (!sameValue && local.version.device == m_me && local.base != incoming.version
                   && incoming.version.device != m_me && !incoming.version.isMinimal()) {
            // 本机的修改更新，对方同时改的值作废。对方的值要先换成本机能显示的样子再记。
            bool dangling = false;
            const QVariant incomingLocal = field.refTable.isEmpty()
                ? incoming.value : resolveLocal(field.refTable, incoming.value, &dangling);
            logConflict(QStringLiteral("edit"), table, record.syncId, label, field.column,
                        displayValue(field, incomingLocal), displayValue(field, localValue),
                        incoming.version.device, m_me,
                        QStringLiteral("两台设备同时改了这一项，以较晚的修改为准"));
        }
        if (!takeIncoming) {
            continue;
        }

        QVariant value = incoming.value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            value = resolveLocal(field.refTable, value, &dangling);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDangling = routineDangling || (dangling && field.column == QLatin1String("routine_id"));
            if (!noteReference(table.name, record.syncId, field, incoming, dangling, error)) {
                return false;
            }
        }
        if (table.name == QLatin1String("tasks")
            && (field.column == QLatin1String("date") || field.column == QLatin1String("display_order")
                || field.column == QLatin1String("completed"))) {
            touchTaskDate(row.values.value(QStringLiteral("date")));
            if (field.column == QLatin1String("date")) {
                touchTaskDate(value);
            }
        }
        if (table.name == QLatin1String("categories") && field.column == QLatin1String("name")) {
            // 科目改名先落临时名，整批应用完再换成最终名（见 finalizeCategoryNames）。
            m_pendingCategoryNames.insert(record.syncId, {row.id, value.toString()});
            value = temporaryCategoryName(record.syncId);
        }
        assignments.append(field.column + QStringLiteral(" = ?"));
        assignedValues.append(value);
        // 版本相同的默认值取舍不改版本；其余照抄对方的版本。
        if (incoming.version != local.version) {
            newVersions.append({field.column, incoming});
        }
    }

    if (table.name == QLatin1String("tasks")) {
        // 新引用的科目或例行在本机已经删除：按本机删除它们时的做法补齐关联列。
        if (categoryDangling) {
            assignments.append(QStringLiteral("category = ?"));
            assignedValues.append(QVariant());
        }
        if (routineDangling) {
            assignments.append(QStringLiteral("routine_generated = ?"));
            assignedValues.append(0);
        }
    }

    if (!assignments.isEmpty()) {
        QSqlQuery update(m_db);
        update.prepare(QStringLiteral("UPDATE %1 SET %2 WHERE id = ?")
                           .arg(table.name, assignments.join(QStringLiteral(", "))));
        for (const QVariant& value : assignedValues) {
            update.addBindValue(value);
        }
        update.addBindValue(row.id);
        if (!exec(update, error)) {
            return false;
        }
        m_result->changedTables.insert(table.name);
    }
    for (const auto& version : newVersions) {
        if (!writeVersion(table.name, record.syncId, version.first, version.second, error)) {
            return false;
        }
    }

    // 本机待发送的修改全被对方覆盖了，这条就不用再发。
    QSqlQuery outbox(m_db);
    outbox.prepare(QStringLiteral(
        "DELETE FROM sync_outbox WHERE tbl = :tbl AND sync_id = :id AND NOT EXISTS ("
        "SELECT 1 FROM sync_field_versions v WHERE v.tbl = :tbl2 AND v.sync_id = :id2 AND v.pending = 1)"));
    outbox.bindValue(QStringLiteral(":tbl"), table.name);
    outbox.bindValue(QStringLiteral(":id"), record.syncId);
    outbox.bindValue(QStringLiteral(":tbl2"), table.name);
    outbox.bindValue(QStringLiteral(":id2"), record.syncId);
    return exec(outbox, error);
}

bool Applier::deleteLocalRow(const SyncSchema::Table& table, const LocalRow& row, const Tombstone& tombstone,
                             QString* error)
{
    const auto run = [this, error](const QString& sql, const QVariantList& values) {
        QSqlQuery query(m_db);
        query.prepare(sql);
        for (const QVariant& value : values) {
            query.addBindValue(value);
        }
        return exec(query, error);
    };

    if (table.name == QLatin1String("categories")) {
        bool dangling = false;
        const QVariant target = tombstone.kind == kKindMerge
            ? resolveLocal(QStringLiteral("categories"), tombstone.mergedInto, &dangling) : QVariant();
        if (target.isValid() && !target.isNull() && target.toLongLong() != row.id) {
            // 合并：凡是指向被合并掉的科目的，都改指向留下的那个（本机不同步的课表、知识缺口也一样）。
            const QVariant targetName = nameOf(QStringLiteral("categories"), target);
            if (!run(QStringLiteral("UPDATE tasks SET category_id = ?, category = ? WHERE category_id = ?"),
                     {target, targetName, row.id})
                || !run(QStringLiteral("UPDATE routines SET category_id = ? WHERE category_id = ?"), {target, row.id})
                || !run(QStringLiteral("UPDATE focus_sessions SET category_id_snapshot = ? "
                                       "WHERE category_id_snapshot = ?"), {target, row.id})
                || !run(QStringLiteral("UPDATE schedule_entries SET category_id = ? WHERE category_id = ?"),
                        {target, row.id})
                || !run(QStringLiteral("UPDATE knowledge_gaps SET category_id = ? WHERE category_id = ?"),
                        {target, row.id})) {
                return false;
            }
            m_result->changedTables.insert(QStringLiteral("tasks"));
            m_result->changedTables.insert(QStringLiteral("routines"));
        } else {
            // 与 CategoryManager::deleteCategory 一致：任务不删，外键和旧的科目名文本一起清空，变成未分类。
            // 例行、课表、知识缺口的外键是 ON DELETE SET NULL，删行时自动置空。
            if (!run(QStringLiteral("UPDATE tasks SET category_id = NULL, category = NULL "
                                    "WHERE category_id = ? OR (category_id IS NULL AND trim(category) = ?)"),
                     {row.id, row.values.value(QStringLiteral("name"))})) {
                return false;
            }
            m_result->changedTables.insert(QStringLiteral("tasks"));
            m_result->changedTables.insert(QStringLiteral("routines"));
        }
    } else if (table.name == QLatin1String("routines")) {
        // 与 RoutineManager::deleteRoutine 一致：历史任务退化成普通任务，生成标记一起清掉。
        // 今天那条没动过的实例由对方的「收回」删除记录处理，这里不自己收回：对方和本机对「今天」可能不同。
        if (!run(QStringLiteral("UPDATE tasks SET routine_id = NULL, routine_generated = 0 WHERE routine_id = ?"),
                 {row.id})) {
            return false;
        }
        m_result->changedTables.insert(QStringLiteral("tasks"));
    } else if (table.name == QLatin1String("tasks")) {
        // 专注记录、知识缺口、正在计时的状态对它的引用由外键置空，与本机删除任务的效果一致。
        m_result->deletedTaskIds.append(int(row.id));
        touchTaskDate(row.values.value(QStringLiteral("date")));
        m_result->changedTables.insert(QStringLiteral("focus_sessions"));
    }
    return run(QStringLiteral("DELETE FROM %1 WHERE id = ?").arg(table.name), {row.id});
}

namespace {
// 设置项在冲突日志里显示的名字与值。
QString settingLabel(const QString& key)
{
    return key == QLatin1String("logic/dayStartHour") ? QStringLiteral("逻辑日起点") : key;
}

QString settingDisplay(const QString& key, const QString& value)
{
    return key == QLatin1String("logic/dayStartHour") ? QStringLiteral("%1 点").arg(value) : value;
}
}

bool Applier::applySetting(const SyncSettingRecord& incoming, QString* error)
{
    m_maxSeenTime = qMax(m_maxSeenTime, incoming.version.time);
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "SELECT value, v_time, v_device, base_time, base_device FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), incoming.key);
    if (!exec(query, error)) {
        return false;
    }
    QSqlQuery write(m_db);
    if (!query.next()) {
        write.prepare(QStringLiteral(
            "INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
            "VALUES (:key, :value, :t, :d, :bt, :bd, 0)"));
    } else {
        const QString localValue = query.value(0).toString();
        const SyncVersion local{query.value(1).toLongLong(), query.value(2).toString()};
        const SyncVersion localBase{query.value(3).toLongLong(), query.value(4).toString()};
        query.finish();
        const bool same = localValue == incoming.value;
        const SyncSchema::Table settings{QStringLiteral("settings"), QStringLiteral("设置"), {}, QString()};
        const QString detail = QStringLiteral("两台设备同时改了这一项，以较晚的修改为准");
        if (incoming.version == local) {
            // 两台设备各自记下的默认值（最小版本）碰巧不同：取较小的那个，两边算出同一个结果。
            if (same || !incoming.version.isMinimal() || !(incoming.value < localValue)) {
                return true;
            }
        } else if (local < incoming.version) {
            if (!same && local.device == m_me && !local.isMinimal() && incoming.base != local) {
                logConflict(QStringLiteral("edit"), settings, incoming.key, settingLabel(incoming.key), incoming.key,
                            settingDisplay(incoming.key, localValue), settingDisplay(incoming.key, incoming.value),
                            m_me, incoming.version.device, detail);
            }
        } else {
            if (!same && local.device == m_me && localBase != incoming.version && incoming.version.device != m_me
                && !incoming.version.isMinimal()) {
                logConflict(QStringLiteral("edit"), settings, incoming.key, settingLabel(incoming.key), incoming.key,
                            settingDisplay(incoming.key, incoming.value), settingDisplay(incoming.key, localValue),
                            incoming.version.device, m_me, detail);
            }
            return true;
        }
        if (same && incoming.version == local) {
            return true;
        }
        write.prepare(QStringLiteral(
            "UPDATE sync_settings SET value = :value, v_time = :t, v_device = :d, base_time = :bt, "
            "base_device = :bd, pending = 0 WHERE key = :key"));
        if (same) {
            // 值相同、只是版本更新：照抄版本，不算设置变了。
            write.bindValue(QStringLiteral(":key"), incoming.key);
            write.bindValue(QStringLiteral(":value"), incoming.value);
            write.bindValue(QStringLiteral(":t"), incoming.version.time);
            write.bindValue(QStringLiteral(":d"), nonNull(incoming.version.device));
            write.bindValue(QStringLiteral(":bt"), incoming.base.time);
            write.bindValue(QStringLiteral(":bd"), nonNull(incoming.base.device));
            return exec(write, error);
        }
    }
    write.bindValue(QStringLiteral(":key"), incoming.key);
    write.bindValue(QStringLiteral(":value"), incoming.value);
    write.bindValue(QStringLiteral(":t"), incoming.version.time);
    write.bindValue(QStringLiteral(":d"), nonNull(incoming.version.device));
    write.bindValue(QStringLiteral(":bt"), incoming.base.time);
    write.bindValue(QStringLiteral(":bd"), nonNull(incoming.base.device));
    if (!exec(write, error)) {
        return false;
    }
    m_result->changedSettings.insert(incoming.key, incoming.value);
    return true;
}

bool Applier::dropRecordsMissingFrom(const SyncBatch& snapshot, QString* error)
{
    QHash<QString, QSet<QString>> live;
    for (const SyncRecord& record : snapshot.records) {
        if (!record.deleted) {
            live[record.table].insert(record.syncId);
        }
    }
    // 从被引用最少的表删起（休息、专注、任务，再例行、科目）：先删科目会先把一批任务解绑，
    // 而那些任务如果也不在快照里，紧接着就要被删，白做一遍。
    const QList<SyncSchema::Table>& tables = SyncSchema::tables();
    for (qsizetype index = tables.size() - 1; index >= 0; --index) {
        const SyncSchema::Table& table = tables.at(index);
        // 只看已发布的行：进行中的专注只属于本机的计时器，快照里本来就没有它，不能删。
        QSqlQuery rows(m_db);
        if (!rows.exec(QStringLiteral("SELECT sync_id FROM %1 r WHERE r.sync_id IS NOT NULL AND %2")
                           .arg(table.name, SyncSchema::publishConditionFor(table, QStringLiteral("r"))))) {
            if (error) {
                *error = rows.lastError().text();
            }
            return false;
        }
        QStringList missing;
        while (rows.next()) {
            if (!live.value(table.name).contains(rows.value(0).toString())) {
                missing.append(rows.value(0).toString());
            }
        }
        rows.finish();
        for (const QString& syncId : missing) {
            LocalRow row;
            if (!readRow(table, syncId, &row, error)) {
                return false;
            }
            if (!row.exists
                || (table.name == QLatin1String("categories")
                    && row.values.value(QStringLiteral("is_preset")).toInt() == 1)) {
                continue;
            }
            Tombstone gone;
            gone.exists = true;
            gone.kind = kKindDelete;
            if (!deleteLocalRow(table, row, gone, error)) {
                return false;
            }
            m_result->changedTables.insert(table.name);
        }
    }
    // 同步状态整体换成快照的：本机旧的版本、删除记录、待发送、待解析引用都作废。
    for (const char* sql : {"DELETE FROM sync_field_versions", "DELETE FROM sync_tombstones",
                            "DELETE FROM sync_outbox", "DELETE FROM sync_pending_refs"}) {
        QSqlQuery clear(m_db);
        if (!clear.exec(QString::fromLatin1(sql))) {
            if (error) {
                *error = clear.lastError().text();
            }
            return false;
        }
    }
    return true;
}

bool Applier::overwriteFromSnapshot(const SyncRecord& record, QString* error)
{
    const SyncSchema::Table* table = SyncSchema::table(record.table);
    if (!table) {
        *error = QStringLiteral("不认识的数据表：%1").arg(record.table);
        return false;
    }
    m_maxSeenTime = qMax(m_maxSeenTime, record.latestVersion().time);
    if (record.deleted) {
        Tombstone tombstone;
        tombstone.exists = true;
        tombstone.version = record.deleteVersion;
        tombstone.kind = record.deleteKind.isEmpty() ? kKindDelete : record.deleteKind;
        tombstone.mergedInto = record.mergedInto;
        return writeTombstone(table->name, record.syncId, tombstone, error);
    }

    LocalRow row;
    if (!readRow(*table, record.syncId, &row, error)) {
        return false;
    }
    if (!row.exists) {
        return insertRow(*table, record, error);
    }

    // 本机已有这条：以快照为准逐列照抄，版本也照抄快照的；本机编号不变。
    QStringList assignments;
    QVariantList values;
    bool categoryDangling = false;
    bool routineDangling = false;
    for (const SyncSchema::Field& field : table->fields) {
        if (!record.fields.contains(field.column)) {
            continue;
        }
        const SyncFieldValue incoming = record.fields.value(field.column);
        QVariant value = incoming.value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            value = resolveLocal(field.refTable, value, &dangling);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDangling = routineDangling || (dangling && field.column == QLatin1String("routine_id"));
            if (!noteReference(table->name, record.syncId, field, incoming, dangling, error)) {
                return false;
            }
        }
        if (table->name == QLatin1String("categories") && field.column == QLatin1String("name")) {
            m_pendingCategoryNames.insert(record.syncId, {row.id, value.toString()});
            value = temporaryCategoryName(record.syncId);
        }
        assignments.append(field.column + QStringLiteral(" = ?"));
        values.append(value);
    }
    if (table->name == QLatin1String("tasks")) {
        if (categoryDangling) {
            assignments.append(QStringLiteral("category = ?"));
            values.append(QVariant());
        }
        if (routineDangling) {
            assignments.append(QStringLiteral("routine_generated = ?"));
            values.append(0);
        }
    }
    if (!assignments.isEmpty()) {
        QSqlQuery update(m_db);
        update.prepare(QStringLiteral("UPDATE %1 SET %2 WHERE id = ?")
                           .arg(table->name, assignments.join(QStringLiteral(", "))));
        for (const QVariant& value : values) {
            update.addBindValue(value);
        }
        update.addBindValue(row.id);
        if (!exec(update, error)) {
            return false;
        }
    }
    for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
        if (SyncSchema::field(table->name, it.key())
            && !writeVersion(table->name, record.syncId, it.key(), it.value(), error)) {
            return false;
        }
    }
    m_result->changedTables.insert(table->name);
    return true;
}

bool Applier::replaceSettings(const QList<SyncSettingRecord>& settings, QString* error)
{
    QHash<QString, QString> previous;
    QSqlQuery read(m_db);
    if (!read.exec(QStringLiteral("SELECT key, value FROM sync_settings"))) {
        if (error) {
            *error = read.lastError().text();
        }
        return false;
    }
    while (read.next()) {
        previous.insert(read.value(0).toString(), read.value(1).toString());
    }
    read.finish();
    QSqlQuery clear(m_db);
    if (!clear.exec(QStringLiteral("DELETE FROM sync_settings"))) {
        if (error) {
            *error = clear.lastError().text();
        }
        return false;
    }
    for (const SyncSettingRecord& setting : settings) {
        m_maxSeenTime = qMax(m_maxSeenTime, setting.version.time);
        QSqlQuery insert(m_db);
        insert.prepare(QStringLiteral(
            "INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
            "VALUES (:key, :value, :t, :d, :bt, :bd, 0)"));
        insert.bindValue(QStringLiteral(":key"), setting.key);
        insert.bindValue(QStringLiteral(":value"), setting.value);
        insert.bindValue(QStringLiteral(":t"), setting.version.time);
        insert.bindValue(QStringLiteral(":d"), nonNull(setting.version.device));
        insert.bindValue(QStringLiteral(":bt"), setting.base.time);
        insert.bindValue(QStringLiteral(":bd"), nonNull(setting.base.device));
        if (!exec(insert, error)) {
            return false;
        }
        if (previous.value(setting.key) != setting.value) {
            m_result->changedSettings.insert(setting.key, setting.value);
        }
    }
    return true;
}

QString Applier::temporaryCategoryName(const QString& syncId)
{
    // 名字里带上身份，保证临时名互不相同，也不会和任何正常的科目名撞上（正常名字里不会有控制字符）。
    return QStringLiteral("\u0001sync-") + syncId;
}

SyncVersion Applier::fieldVersion(const QString& table, const QString& syncId, const QString& field)
{
    return readVersions(table, syncId).value(field).version;
}

bool Applier::setApplying(bool applying, QString* error)
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("UPDATE sync_runtime SET applying = :applying WHERE singleton_id = 1"));
    query.bindValue(QStringLiteral(":applying"), applying ? 1 : 0);
    return exec(query, error);
}

bool Applier::advanceClock(SyncVersion* version, QString* error)
{
    QSqlQuery query(m_db);
    if (!query.exec(SyncSchema::sqlAdvanceClock())
        || !query.exec(QStringLiteral("SELECT %1, %2").arg(SyncSchema::sqlCurrentClock(), SyncSchema::sqlDeviceId()))
        || !query.next()) {
        if (error) {
            *error = query.lastError().text();
        }
        return false;
    }
    *version = {query.value(0).toLongLong(), query.value(1).toString()};
    return true;
}

bool Applier::republish(const QString& table, const QString& syncId, const QString& field, QString* error)
{
    SyncVersion version;
    if (!advanceClock(&version, error)) {
        return false;
    }
    // 值不变，只给这一列一个本机的新版本：整条记录会带着它发出去，版本比对方手里的删除记录新。
    QSqlQuery stamp(m_db);
    stamp.prepare(QStringLiteral(
        "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
        "VALUES (:tbl, :id, :field, :t, :d, 0, '', 1) "
        "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET "
        "base_time = CASE WHEN pending = 1 THEN base_time ELSE v_time END, "
        "base_device = CASE WHEN pending = 1 THEN base_device ELSE v_device END, "
        "v_time = excluded.v_time, v_device = excluded.v_device, pending = 1"));
    stamp.bindValue(QStringLiteral(":tbl"), table);
    stamp.bindValue(QStringLiteral(":id"), syncId);
    stamp.bindValue(QStringLiteral(":field"), field);
    stamp.bindValue(QStringLiteral(":t"), version.time);
    stamp.bindValue(QStringLiteral(":d"), nonNull(version.device));
    QSqlQuery outbox(m_db);
    outbox.prepare(QStringLiteral(
        "INSERT INTO sync_outbox (tbl, sync_id, change_time) VALUES (:tbl, :id, :t) "
        "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time"));
    outbox.bindValue(QStringLiteral(":tbl"), table);
    outbox.bindValue(QStringLiteral(":id"), syncId);
    outbox.bindValue(QStringLiteral(":t"), version.time);
    return exec(stamp, error) && exec(outbox, error);
}

bool Applier::mergeCategory(qint64 loserId, const QString& loserSyncId, qint64 winnerId, const QString& winnerSyncId,
                            const QString& name, QString* error)
{
    const auto run = [this, error](const QString& sql, const QVariantList& values) {
        QSqlQuery query(m_db);
        query.prepare(sql);
        for (const QVariant& value : values) {
            query.addBindValue(value);
        }
        return exec(query, error);
    };
    // 凡是指向被合并掉的科目的，都改指向留下的那个，本机不同步的课表、知识缺口也一样。
    // 这些改指不记版本：收到这条合并记录的设备会自己做同样的改指，结果一致。
    if (!run(QStringLiteral("UPDATE tasks SET category_id = ?, category = ? WHERE category_id = ?"),
             {winnerId, name, loserId})
        || !run(QStringLiteral("UPDATE routines SET category_id = ? WHERE category_id = ?"), {winnerId, loserId})
        || !run(QStringLiteral("UPDATE focus_sessions SET category_id_snapshot = ? WHERE category_id_snapshot = ?"),
                {winnerId, loserId})
        || !run(QStringLiteral("UPDATE schedule_entries SET category_id = ? WHERE category_id = ?"), {winnerId, loserId})
        || !run(QStringLiteral("UPDATE knowledge_gaps SET category_id = ? WHERE category_id = ?"), {winnerId, loserId})) {
        return false;
    }

    // 合并本身必须发出去：对方可能没有撞名（例如对方同时把这个科目改成了别的名字），
    // 不告诉它，它会一直留着这个科目，两边从此不一致。
    SyncVersion version;
    if (!advanceClock(&version, error)) {
        return false;
    }
    Tombstone tombstone;
    tombstone.exists = true;
    tombstone.version = version;
    tombstone.kind = kKindMerge;
    tombstone.mergedInto = winnerSyncId;
    if (!writeTombstone(QStringLiteral("categories"), loserSyncId, tombstone, error)
        || !run(QStringLiteral("DELETE FROM sync_field_versions WHERE tbl = 'categories' AND sync_id = ?"),
                {loserSyncId})
        || !run(QStringLiteral("INSERT INTO sync_outbox (tbl, sync_id, change_time) VALUES ('categories', ?, ?) "
                               "ON CONFLICT(tbl, sync_id) DO UPDATE SET change_time = excluded.change_time"),
                {loserSyncId, version.time})
        || !run(QStringLiteral("DELETE FROM categories WHERE id = ?"), {loserId})) {
        return false;
    }

    const SyncSchema::Table* categories = SyncSchema::table(QStringLiteral("categories"));
    logConflict(kKindMerge, *categories, loserSyncId, name, QString(), QString(), QString(), QString(), QString(),
                QStringLiteral("两台设备上各有一个「%1」，已合并成一个").arg(name));
    for (const char* changed : {"categories", "tasks", "routines", "focus_sessions"}) {
        m_result->changedTables.insert(QString::fromLatin1(changed));
    }
    return true;
}

bool Applier::renameWithSuffix(qint64 id, const QString& name, QString* error)
{
    // 找一个没人用的名字：「名字（2）」「名字（3）」……
    QString candidate;
    for (int suffix = 2;; ++suffix) {
        // 一次替换两个参数：用户起的名字里可能本来就有「%2」这样的文字，分两次 arg 会把它也换掉。
        candidate = QStringLiteral("%1（%2）").arg(name, QString::number(suffix));
        QSqlQuery taken(m_db);
        taken.prepare(QStringLiteral("SELECT 1 FROM categories WHERE name = :name"));
        taken.bindValue(QStringLiteral(":name"), candidate);
        if (!exec(taken, error)) {
            return false;
        }
        if (!taken.next()) {
            break;
        }
    }
    // 这是本机做出的改名，放开触发器让它照常记版本、入队：两台设备算出同一个名字，版本不同也会收敛。
    QSqlQuery rename(m_db);
    rename.prepare(QStringLiteral("UPDATE categories SET name = :name WHERE id = :id"));
    rename.bindValue(QStringLiteral(":name"), candidate);
    rename.bindValue(QStringLiteral(":id"), id);
    if (!setApplying(false, error) || !exec(rename, error) || !setApplying(true, error)) {
        return false;
    }
    const SyncSchema::Table* categories = SyncSchema::table(QStringLiteral("categories"));
    logConflict(QStringLiteral("edit"), *categories, syncIdOfLocal(QStringLiteral("categories"), id).toString(),
                candidate, QStringLiteral("name"), name, candidate, QString(), QString(),
                QStringLiteral("两个预置科目被改成了同一个名字，这一个加了后缀"));
    m_result->changedTables.insert(QStringLiteral("categories"));
    return true;
}

bool Applier::finalizeCategoryNames(QString* error)
{
    for (auto it = m_pendingCategoryNames.cbegin(); it != m_pendingCategoryNames.cend(); ++it) {
        const QString syncId = it.key();
        const qint64 id = it.value().first;
        const QString name = it.value().second;

        QSqlQuery self(m_db);
        self.prepare(QStringLiteral("SELECT is_preset FROM categories WHERE id = :id"));
        self.bindValue(QStringLiteral(":id"), id);
        if (!exec(self, error)) {
            return false;
        }
        if (!self.next()) {
            // 前面一步已经把它当作撞名的一方合并掉了。
            continue;
        }
        const bool selfPreset = self.value(0).toInt() == 1;

        QSqlQuery holder(m_db);
        holder.prepare(QStringLiteral("SELECT id, sync_id, is_preset FROM categories WHERE name = :name AND id <> :id"));
        holder.bindValue(QStringLiteral(":name"), name);
        holder.bindValue(QStringLiteral(":id"), id);
        if (!exec(holder, error)) {
            return false;
        }
        QSqlQuery finalize(m_db);
        finalize.prepare(QStringLiteral("UPDATE categories SET name = :name WHERE id = :id"));
        finalize.bindValue(QStringLiteral(":name"), name);
        finalize.bindValue(QStringLiteral(":id"), id);
        if (!holder.next()) {
            if (!exec(finalize, error)) {
                return false;
            }
            continue;
        }

        const qint64 holderId = holder.value(0).toLongLong();
        const QString holderSyncId = holder.value(1).toString();
        const bool holderPreset = holder.value(2).toInt() == 1;
        holder.finish();
        if (selfPreset && holderPreset) {
            // 两个预置科目撞名：预置科目不能删，也就不能合并。名字的版本新的留下这个名字，另一个加后缀。
            const bool selfWins = fieldVersion(QStringLiteral("categories"), holderSyncId, QStringLiteral("name"))
                < fieldVersion(QStringLiteral("categories"), syncId, QStringLiteral("name"));
            if (selfWins) {
                if (!renameWithSuffix(holderId, name, error) || !exec(finalize, error)) {
                    return false;
                }
            } else if (!renameWithSuffix(id, name, error)) {
                return false;
            }
            continue;
        }
        // 预置科目总是留下（它不能被删）；都是自定义的，留身份较小的那个。两台设备算出同一个结果。
        const bool selfWins = selfPreset || (!holderPreset && syncId < holderSyncId);
        if (selfWins) {
            if (!mergeCategory(holderId, holderSyncId, id, syncId, name, error) || !exec(finalize, error)) {
                return false;
            }
        } else if (!mergeCategory(id, syncId, holderId, holderSyncId, name, error)) {
            return false;
        }
    }
    m_pendingCategoryNames.clear();
    return true;
}

bool Applier::normalizeTaskOrders(QString* error)
{
    if (m_touchedTaskDates.isEmpty()) {
        return true;
    }
    QStringList dates(m_touchedTaskDates.cbegin(), m_touchedTaskDates.cend());
    std::sort(dates.begin(), dates.end());
    // 重排是本机改动：放开触发器，让它们照常记版本、入队。两台设备拿到同样的任务集合后算出同样的顺序，
    // 版本不同也会收敛到同一个结果。
    if (!setApplying(false, error)) {
        return false;
    }
    for (const QString& date : dates) {
        QSqlQuery check(m_db);
        check.prepare(QStringLiteral(
            "SELECT COUNT(*) - COUNT(DISTINCT display_order), MIN(display_order), COUNT(*) FROM tasks WHERE date = :date"));
        check.bindValue(QStringLiteral(":date"), date);
        if (!exec(check, error) || !check.next()) {
            return false;
        }
        const bool broken = check.value(2).toInt() > 0
            && (check.value(0).toInt() > 0 || check.value(1).toInt() <= 0);
        check.finish();
        if (!broken) {
            continue;
        }
        // 排序键：完成状态、排序号（非正的排到后面）、创建时间、sync_id。前几项和界面的显示顺序一致，
        // 最后用 sync_id 打破平局——两台设备上它相同，本机编号却不同。只写真的变了的行。
        QSqlQuery renumber(m_db);
        renumber.prepare(QStringLiteral(
            "WITH ranked AS (SELECT id, ROW_NUMBER() OVER (ORDER BY completed ASC, "
            "CASE WHEN display_order <= 0 THEN 1 ELSE 0 END ASC, display_order ASC, created_at ASC, sync_id ASC) AS n "
            "FROM tasks WHERE date = :date) "
            "UPDATE tasks SET display_order = (SELECT n FROM ranked WHERE ranked.id = tasks.id) "
            "WHERE date = :date2 AND display_order <> (SELECT n FROM ranked WHERE ranked.id = tasks.id)"));
        renumber.bindValue(QStringLiteral(":date"), date);
        renumber.bindValue(QStringLiteral(":date2"), date);
        if (!exec(renumber, error)) {
            return false;
        }
        m_result->changedTables.insert(QStringLiteral("tasks"));
    }
    return setApplying(true, error);
}

bool Applier::logSkipped(const SyncRecord& record, const QString& reason)
{
    const SyncSchema::Table* table = SyncSchema::table(record.table);
    QHash<QString, QVariant> values;
    for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
        values.insert(it.key(), it.value().value);
    }
    const SyncSchema::Table fallback{record.table, record.table, {}, QString()};
    const SyncSchema::Table& spec = table ? *table : fallback;
    qWarning() << "Skipped sync record" << record.table << record.syncId << reason;
    logConflict(QStringLiteral("skipped"), spec, record.syncId, table ? recordLabel(spec, values) : QString(),
                QString(), QString(), QString(), record.latestVersion().device, m_me,
                QStringLiteral("这条记录没能应用，已跳过：%1").arg(reason));
    ++m_result->skippedRecords;
    return true;
}

void Applier::logConflict(const QString& kind, const SyncSchema::Table& table, const QString& syncId,
                          const QString& recordLabel, const QString& field, const QString& lostValue,
                          const QString& keptValue, const QString& lostDevice, const QString& keptDevice,
                          const QString& detail)
{
    // 空的 QString 绑定进去是 SQL 的 NULL，会撞上日志表的 NOT NULL；一律收敛成空串。
    const auto text = [](const QString& value) { return value.isNull() ? QStringLiteral("") : value; };
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "INSERT INTO sync_conflict_log (logged_at, kind, tbl, sync_id, record_label, field, lost_value, "
        "kept_value, lost_device, kept_device, detail) "
        "VALUES (:at, :kind, :tbl, :id, :label, :field, :lost, :kept, :lostDevice, :keptDevice, :detail)"));
    query.bindValue(QStringLiteral(":at"), QDateTime::currentDateTime().toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":kind"), text(kind));
    query.bindValue(QStringLiteral(":tbl"), text(table.name));
    query.bindValue(QStringLiteral(":id"), text(syncId));
    query.bindValue(QStringLiteral(":label"), text(truncated(recordLabel)));
    query.bindValue(QStringLiteral(":field"), text(field));
    query.bindValue(QStringLiteral(":lost"), text(truncated(lostValue)));
    query.bindValue(QStringLiteral(":kept"), text(truncated(keptValue)));
    query.bindValue(QStringLiteral(":lostDevice"), text(lostDevice));
    query.bindValue(QStringLiteral(":keptDevice"), text(keptDevice));
    query.bindValue(QStringLiteral(":detail"), text(detail));
    if (!query.exec()) {
        // 日志写不进去不影响合并本身：日志是给人看的，合并结果已经确定。
        qWarning() << "Failed to write sync conflict log:" << query.lastError().text();
        return;
    }
    ++m_result->conflictsLogged;
    QSqlQuery prune(m_db);
    prune.exec(QStringLiteral("DELETE FROM sync_conflict_log WHERE id <= "
                              "(SELECT MAX(id) - %1 FROM sync_conflict_log)").arg(kConflictLogLimit));
}

QString Applier::recordLabel(const SyncSchema::Table& table, const QHash<QString, QVariant>& values)
{
    if (table.name == QLatin1String("categories")) {
        return values.value(QStringLiteral("name")).toString();
    }
    if (table.name == QLatin1String("routines") || table.name == QLatin1String("tasks")) {
        return values.value(QStringLiteral("title")).toString();
    }
    // 专注和休息没有标题：用「几月几日几点、多长」让人认出是哪一条。
    const QDateTime start = QDateTime::fromString(values.value(QStringLiteral("start_time")).toString(), Qt::ISODate);
    const int minutes = values.value(QStringLiteral("duration")).toInt() / 60;
    const QString when = start.isValid() ? start.toString(QStringLiteral("MM-dd HH:mm")) : QStringLiteral("？");
    return QStringLiteral("%1 %2（%3 分钟）")
        .arg(table.name == QLatin1String("rest_sessions") ? QStringLiteral("休息") : QStringLiteral("专注"), when)
        .arg(minutes);
}

QString Applier::nameOf(const QString& table, const QVariant& localId)
{
    if (!localId.isValid() || localId.isNull()) {
        return QString();
    }
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT %1 FROM %2 WHERE id = :id")
                      .arg(table == QLatin1String("categories") ? QStringLiteral("name") : QStringLiteral("title"),
                           table));
    query.bindValue(QStringLiteral(":id"), localId);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

QString Applier::displayValue(const SyncSchema::Field& field, const QVariant& localValue)
{
    const QString column = field.column;
    if (!field.refTable.isEmpty()) {
        const QString name = nameOf(field.refTable, localValue);
        if (!name.isEmpty()) {
            return name;
        }
        return localValue.isNull() ? QStringLiteral("（无）") : QStringLiteral("（已删除）");
    }
    if (localValue.isNull()) {
        return QStringLiteral("（空）");
    }
    if (column == QLatin1String("completed")) {
        return localValue.toInt() == 1 ? QStringLiteral("已完成") : QStringLiteral("未完成");
    }
    if (column == QLatin1String("active")) {
        return localValue.toInt() == 1 ? QStringLiteral("启用") : QStringLiteral("停用");
    }
    if (column == QLatin1String("is_preset") || column == QLatin1String("routine_generated")
        || column == QLatin1String("pomodoro_completed") || column == QLatin1String("manual")) {
        return localValue.toInt() == 1 ? QStringLiteral("是") : QStringLiteral("否");
    }
    if (column == QLatin1String("duration")) {
        return QStringLiteral("%1 分钟").arg(localValue.toInt() / 60);
    }
    if (column == QLatin1String("estimated_minutes")) {
        return QStringLiteral("%1 分钟").arg(localValue.toInt());
    }
    if (column == QLatin1String("mode")) {
        return localValue.toInt() == FocusSessionRules::kPomodoroMode ? QStringLiteral("番茄")
                                                                      : QStringLiteral("自由计时");
    }
    if (column == QLatin1String("weekdays")) {
        const int mask = localValue.toInt();
        if (mask == RoutineRules::kEveryDayMask) {
            return QStringLiteral("每天");
        }
        static const QStringList names{QStringLiteral("周一"), QStringLiteral("周二"), QStringLiteral("周三"),
                                       QStringLiteral("周四"), QStringLiteral("周五"), QStringLiteral("周六"),
                                       QStringLiteral("周日")};
        QStringList days;
        for (int day = 1; day <= 7; ++day) {
            if (mask & RoutineRules::maskForDayOfWeek(day)) {
                days.append(names.at(day - 1));
            }
        }
        return days.join(QStringLiteral("、"));
    }
    const QString text = localValue.toString();
    return text.isEmpty() ? QStringLiteral("（空）") : text;
}

// 按身份读出一条完整的同步记录：行还在（且满足发布条件）就读全部字段与版本，不在就读删除记录。
// 两样都没有时返回 false。发待发送改动和导出全量快照共用它。
bool readRecord(QSqlDatabase db, const SyncSchema::Table& table, const QString& syncId, SyncRecord* record)
{
    record->table = table.name;
    record->syncId = syncId;

    const QStringList columns = columnsOf(table);
    QSqlQuery row(db);
    row.prepare(QStringLiteral("SELECT %1 FROM %2 r WHERE r.sync_id = :id AND %3")
                    .arg(columns.join(QStringLiteral(", ")), table.name,
                         SyncSchema::publishConditionFor(table, QStringLiteral("r"))));
    row.bindValue(QStringLiteral(":id"), syncId);
    if (row.exec() && row.next()) {
        QSqlQuery versions(db);
        versions.prepare(QStringLiteral(
            "SELECT field, v_time, v_device, base_time, base_device FROM sync_field_versions "
            "WHERE tbl = :tbl AND sync_id = :id"));
        versions.bindValue(QStringLiteral(":tbl"), table.name);
        versions.bindValue(QStringLiteral(":id"), syncId);
        QHash<QString, QPair<SyncVersion, SyncVersion>> known;
        if (versions.exec()) {
            while (versions.next()) {
                known.insert(versions.value(0).toString(),
                             {{versions.value(1).toLongLong(), versions.value(2).toString()},
                              {versions.value(3).toLongLong(), versions.value(4).toString()}});
            }
        }
        for (int index = 0; index < table.fields.size(); ++index) {
            const SyncSchema::Field& field = table.fields.at(index);
            SyncFieldValue value;
            value.value = row.value(index);
            if (!field.refTable.isEmpty() && !value.value.isNull()) {
                // 引用列换成对方能认的 sync_id；本机编号指向的记录已经不在时发空值。
                QSqlQuery ref(db);
                ref.prepare(QStringLiteral("SELECT sync_id FROM %1 WHERE id = :id").arg(field.refTable));
                ref.bindValue(QStringLiteral(":id"), value.value);
                value.value = ref.exec() && ref.next() ? ref.value(0) : QVariant();
            }
            // 没有版本行的列（理论上不会有）按最小版本发，谁有真实修改都会赢过它。
            const auto version = known.value(field.column);
            value.version = version.first;
            value.base = version.second;
            record->fields.insert(field.column, value);
        }
        return true;
    }

    QSqlQuery tombstone(db);
    tombstone.prepare(QStringLiteral(
        "SELECT v_time, v_device, kind, merged_into FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
    tombstone.bindValue(QStringLiteral(":tbl"), table.name);
    tombstone.bindValue(QStringLiteral(":id"), syncId);
    if (tombstone.exec() && tombstone.next()) {
        record->deleted = true;
        record->deleteVersion = {tombstone.value(0).toLongLong(), tombstone.value(1).toString()};
        record->deleteKind = tombstone.value(2).toString();
        record->mergedInto = tombstone.value(3).toString();
        return true;
    }
    return false;
}

} // namespace

SyncStore::SyncStore(const QString& connectionName)
    : m_connectionName(connectionName)
{
}

QSqlDatabase SyncStore::database() const
{
    return m_connectionName.isEmpty() ? DatabaseManager::instance()->database()
                                      : QSqlDatabase::database(m_connectionName);
}

QString SyncStore::deviceId() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT value FROM sync_state WHERE key = 'device_id'")) && query.next()
        ? query.value(0).toString() : QString();
}

qint64 SyncStore::epoch() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT CAST(value AS INTEGER) FROM sync_state WHERE key = 'epoch'"))
            && query.next()
        ? query.value(0).toLongLong() : 0;
}

SyncBatch SyncStore::collectPending() const
{
    QSqlDatabase db = database();
    SyncBatch batch;
    batch.device = deviceId();
    batch.epoch = epoch();

    struct Pending {
        QString table;
        QString syncId;
        qint64 changeTime = 0;
    };
    QList<Pending> pending;
    QSqlQuery outbox(db);
    if (!outbox.exec(QStringLiteral("SELECT tbl, sync_id, change_time FROM sync_outbox"))) {
        qWarning() << "Failed to read sync outbox:" << outbox.lastError().text();
        return batch;
    }
    while (outbox.next()) {
        pending.append({outbox.value(0).toString(), outbox.value(1).toString(), outbox.value(2).toLongLong()});
    }
    // 按表的依赖顺序、同表内按改动先后。对方反正也会按依赖顺序应用，这里排好只是让文件读起来顺。
    std::stable_sort(pending.begin(), pending.end(), [](const Pending& a, const Pending& b) {
        const qsizetype orderA = tableOrder(a.table);
        const qsizetype orderB = tableOrder(b.table);
        return orderA != orderB ? orderA < orderB : a.changeTime < b.changeTime;
    });

    for (const Pending& item : pending) {
        const SyncSchema::Table* table = SyncSchema::table(item.table);
        SyncRecord record;
        record.changeTime = item.changeTime;
        // 既没有行也没有删除记录：只可能是外部改过库。不发，确认时也不会出队，留着等人排查。
        if (table && readRecord(db, *table, item.syncId, &record)) {
            batch.records.append(record);
        }
    }

    QSqlQuery settings(db);
    if (settings.exec(QStringLiteral(
            "SELECT key, value, v_time, v_device, base_time, base_device FROM sync_settings WHERE pending = 1 "
            "ORDER BY key"))) {
        while (settings.next()) {
            SyncSettingRecord setting;
            setting.key = settings.value(0).toString();
            setting.value = settings.value(1).toString();
            setting.version = {settings.value(2).toLongLong(), settings.value(3).toString()};
            setting.base = {settings.value(4).toLongLong(), settings.value(5).toString()};
            batch.settings.append(setting);
        }
    }
    return batch;
}

bool SyncStore::recordLocalSetting(const QString& key, const QString& value, bool isDefault)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT value FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    if (!query.exec()) {
        db.rollback();
        return false;
    }
    const bool exists = query.next();
    const QString oldValue = exists ? query.value(0).toString() : QString();
    query.finish();
    if (exists && oldValue == value) {
        // 值没变（例如同步写回 AppSettings 之后它又发出变更信号）：不是本机改动，什么都不记。
        return db.commit();
    }

    SyncVersion version;
    if (exists || !isDefault) {
        if (!query.exec(SyncSchema::sqlAdvanceClock())
            || !query.exec(QStringLiteral("SELECT %1, %2").arg(SyncSchema::sqlCurrentClock(), SyncSchema::sqlDeviceId()))
            || !query.next()) {
            db.rollback();
            return false;
        }
        version = {query.value(0).toLongLong(), query.value(1).toString()};
        query.finish();
    }
    QSqlQuery write(db);
    write.prepare(exists
        ? QStringLiteral("UPDATE sync_settings SET "
                         "base_time = CASE WHEN pending = 1 THEN base_time ELSE v_time END, "
                         "base_device = CASE WHEN pending = 1 THEN base_device ELSE v_device END, "
                         "value = :value, v_time = :t, v_device = :d, pending = 1 WHERE key = :key")
        : QStringLiteral("INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
                         "VALUES (:key, :value, :t, :d, 0, '', 1)"));
    write.bindValue(QStringLiteral(":key"), key);
    write.bindValue(QStringLiteral(":value"), value);
    write.bindValue(QStringLiteral(":t"), version.time);
    write.bindValue(QStringLiteral(":d"), nonNull(version.device));
    if (!write.exec() || !db.commit()) {
        qWarning() << "Failed to record local sync setting:" << write.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

QString SyncStore::syncedSetting(const QString& key) const
{
    QSqlQuery query(database());
    query.prepare(QStringLiteral("SELECT value FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

SyncBatch SyncStore::exportSnapshot() const
{
    QSqlDatabase db = database();
    SyncBatch snapshot;
    snapshot.device = deviceId();
    snapshot.epoch = epoch();

    // 快照里的记录如果也在待发送队列里，带上队列里的 change_time：快照写出后按它确认，
    // 快照已经带上的改动不必再单独发一遍。
    QHash<QString, qint64> queued;
    QSqlQuery outbox(db);
    if (outbox.exec(QStringLiteral("SELECT tbl, sync_id, change_time FROM sync_outbox"))) {
        while (outbox.next()) {
            queued.insert(outbox.value(0).toString() + QLatin1Char('/') + outbox.value(1).toString(),
                          outbox.value(2).toLongLong());
        }
    }
    const auto changeTimeOf = [&queued](const QString& table, const QString& syncId) {
        return queued.value(table + QLatin1Char('/') + syncId, 0);
    };

    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QStringList ids;
        QSqlQuery rows(db);
        if (rows.exec(QStringLiteral("SELECT sync_id FROM %1 r WHERE r.sync_id IS NOT NULL AND %2 ORDER BY r.id")
                          .arg(table.name, SyncSchema::publishConditionFor(table, QStringLiteral("r"))))) {
            while (rows.next()) {
                ids.append(rows.value(0).toString());
            }
        }
        for (const QString& syncId : ids) {
            SyncRecord record;
            record.changeTime = changeTimeOf(table.name, syncId);
            if (readRecord(db, table, syncId, &record)) {
                snapshot.records.append(record);
            }
        }
    }
    // 删除记录也要带上：没有它们，对方拿不到「删除优先」的依据，离线设备晚到的旧修改会把删掉的记录带回来。
    QSqlQuery tombstones(db);
    if (tombstones.exec(QStringLiteral(
            "SELECT tbl, sync_id, v_time, v_device, kind, merged_into FROM sync_tombstones ORDER BY tbl, sync_id"))) {
        while (tombstones.next()) {
            SyncRecord record;
            record.table = tombstones.value(0).toString();
            record.syncId = tombstones.value(1).toString();
            record.deleted = true;
            record.deleteVersion = {tombstones.value(2).toLongLong(), tombstones.value(3).toString()};
            record.deleteKind = tombstones.value(4).toString();
            record.mergedInto = tombstones.value(5).toString();
            record.changeTime = changeTimeOf(record.table, record.syncId);
            snapshot.records.append(record);
        }
    }
    QSqlQuery settings(db);
    if (settings.exec(QStringLiteral(
            "SELECT key, value, v_time, v_device, base_time, base_device FROM sync_settings ORDER BY key"))) {
        while (settings.next()) {
            SyncSettingRecord setting;
            setting.key = settings.value(0).toString();
            setting.value = settings.value(1).toString();
            setting.version = {settings.value(2).toLongLong(), settings.value(3).toString()};
            setting.base = {settings.value(4).toLongLong(), settings.value(5).toString()};
            snapshot.settings.append(setting);
        }
    }
    return snapshot;
}

bool SyncStore::markSnapshotPublished(const SyncBatch& snapshot)
{
    if (!acknowledge(snapshot)) {
        return false;
    }
    QSqlQuery query(database());
    return query.exec(QStringLiteral("DELETE FROM sync_state WHERE key = 'snapshot_needed'"));
}

SyncStore::ApplyResult SyncStore::replaceWithSnapshot(const SyncBatch& snapshot)
{
    ApplyResult result;
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        result.error = QStringLiteral("数据库未打开");
        return result;
    }
    const QString me = deviceId();
    if (snapshot.device.isEmpty() || snapshot.device == me) {
        result.error = QStringLiteral("快照的设备标识与本机相同，已拒绝");
        return result;
    }
    if (!db.transaction()) {
        result.error = db.lastError().text();
        return result;
    }
    const auto fail = [&db, &result](const QString& error) {
        db.rollback();
        ApplyResult failed;
        failed.error = error;
        qWarning() << "Failed to replace with sync snapshot:" << error;
        result = failed;
        return result;
    };

    QSqlQuery query(db);
    // 整个替换期间触发器全部跳过：这些都是照抄快照，不是本机改动，不能再发回去。
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    Applier applier(db, me, &result);
    QString error;
    if (!applier.dropRecordsMissingFrom(snapshot, &error)) {
        return fail(error);
    }
    QList<SyncRecord> records = snapshot.records;
    std::stable_sort(records.begin(), records.end(), [](const SyncRecord& a, const SyncRecord& b) {
        return tableOrder(a.table) < tableOrder(b.table);
    });
    for (const SyncRecord& record : records) {
        // 与应用一批改动一样：一条坏记录只跳过它自己，不让整份快照都落不了地。
        if (!query.exec(QStringLiteral("SAVEPOINT sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        QString recordError;
        const bool applied = applier.overwriteFromSnapshot(record, &recordError);
        if (!applied && !query.exec(QStringLiteral("ROLLBACK TO sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        if (!query.exec(QStringLiteral("RELEASE sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        if (!applied) {
            applier.logSkipped(record, recordError);
        }
    }
    if (!applier.replaceSettings(snapshot.settings, &error)) {
        return fail(error);
    }

    query.prepare(QStringLiteral("UPDATE sync_state SET value = CAST(:epoch AS TEXT) WHERE key = 'epoch'"));
    query.bindValue(QStringLiteral(":epoch"), snapshot.epoch);
    if (!query.exec()) {
        return fail(query.lastError().text());
    }
    query.prepare(QStringLiteral(
        "UPDATE sync_state SET value = CAST(MAX(CAST(value AS INTEGER), :seen) AS TEXT) WHERE key = 'hlc'"));
    query.bindValue(QStringLiteral(":seen"), applier.maxSeenTime());
    if (!query.exec()) {
        return fail(query.lastError().text());
    }
    if (!applier.finalizeCategoryNames(&error)) {
        return fail(error);
    }
    if (!query.exec(QStringLiteral("DELETE FROM sync_state WHERE key = 'snapshot_needed'"))
        || !query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    if (!db.commit()) {
        return fail(db.lastError().text());
    }
    // 整体替换：每张同步表都可能变了，界面全部刷新一次（这种事很少发生）。
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        result.changedTables.insert(table.name);
    }
    result.ok = true;
    return result;
}

bool SyncStore::beginEpochAfterRestore(qint64 previousEpoch, const QString& previousDeviceId)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE sync_state SET value = CAST(MAX(CAST(value AS INTEGER), :previous) + 1 AS TEXT) WHERE key = 'epoch'"));
    query.bindValue(QStringLiteral(":previous"), previousEpoch);
    bool ok = query.exec();
    if (ok && !previousDeviceId.isEmpty()) {
        query.prepare(QStringLiteral("UPDATE sync_state SET value = :device WHERE key = 'device_id'"));
        query.bindValue(QStringLiteral(":device"), previousDeviceId);
        ok = query.exec();
    }
    // 回滚之后整份状态会作为快照发出，旧的待发送、待解析引用都不再有意义。
    for (const char* sql : {"DELETE FROM sync_outbox", "DELETE FROM sync_pending_refs",
                            "UPDATE sync_field_versions SET pending = 0", "UPDATE sync_settings SET pending = 0",
                            "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('snapshot_needed', '1')"}) {
        ok = ok && query.exec(QString::fromLatin1(sql));
    }
    if (!ok || !db.commit()) {
        qWarning() << "Failed to begin sync epoch after restore:" << query.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

bool SyncStore::needsSnapshot() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT value FROM sync_state WHERE key = 'snapshot_needed'")) && query.next()
        && query.value(0).toString() == QLatin1String("1");
}

bool SyncStore::acknowledge(const SyncBatch& batch)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        qWarning() << "Failed to start sync acknowledge:" << db.lastError().text();
        return false;
    }
    bool ok = true;
    for (const SyncRecord& record : batch.records) {
        QSqlQuery outbox(db);
        outbox.prepare(QStringLiteral(
            "DELETE FROM sync_outbox WHERE tbl = :tbl AND sync_id = :id AND change_time = :change"));
        outbox.bindValue(QStringLiteral(":tbl"), record.table);
        outbox.bindValue(QStringLiteral(":id"), record.syncId);
        outbox.bindValue(QStringLiteral(":change"), record.changeTime);
        ok = ok && outbox.exec();
        if (record.deleted) {
            continue;
        }
        for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
            // 发出去的这一版不再待发送；期间又改过的列仍待发送，但对方马上会见到刚发出的这一版，
            // 所以把它的 base 改成这一版，冲突日志才能把之后的修改认成「先后修改」。
            QSqlQuery sent(db);
            sent.prepare(QStringLiteral(
                "UPDATE sync_field_versions SET pending = 0 WHERE tbl = :tbl AND sync_id = :id AND field = :field "
                "AND v_time = :t AND v_device = :d"));
            QSqlQuery rebase(db);
            rebase.prepare(QStringLiteral(
                "UPDATE sync_field_versions SET base_time = :t, base_device = :d "
                "WHERE tbl = :tbl AND sync_id = :id AND field = :field AND pending = 1 "
                "AND NOT (v_time = :t2 AND v_device = :d2)"));
            for (QSqlQuery* query : {&sent, &rebase}) {
                query->bindValue(QStringLiteral(":tbl"), record.table);
                query->bindValue(QStringLiteral(":id"), record.syncId);
                query->bindValue(QStringLiteral(":field"), it.key());
                query->bindValue(QStringLiteral(":t"), it.value().version.time);
                query->bindValue(QStringLiteral(":d"), nonNull(it.value().version.device));
            }
            rebase.bindValue(QStringLiteral(":t2"), it.value().version.time);
            rebase.bindValue(QStringLiteral(":d2"), nonNull(it.value().version.device));
            ok = ok && sent.exec() && rebase.exec();
        }
    }
    for (const SyncSettingRecord& setting : batch.settings) {
        // 与字段同理：发出的这一版不再待发送；期间又改过的，base 改成刚发出的这一版。
        QSqlQuery sent(db);
        sent.prepare(QStringLiteral(
            "UPDATE sync_settings SET pending = 0 WHERE key = :key AND v_time = :t AND v_device = :d"));
        QSqlQuery rebase(db);
        rebase.prepare(QStringLiteral(
            "UPDATE sync_settings SET base_time = :t, base_device = :d WHERE key = :key AND pending = 1 "
            "AND NOT (v_time = :t2 AND v_device = :d2)"));
        for (QSqlQuery* query : {&sent, &rebase}) {
            query->bindValue(QStringLiteral(":key"), setting.key);
            query->bindValue(QStringLiteral(":t"), setting.version.time);
            query->bindValue(QStringLiteral(":d"), nonNull(setting.version.device));
        }
        rebase.bindValue(QStringLiteral(":t2"), setting.version.time);
        rebase.bindValue(QStringLiteral(":d2"), nonNull(setting.version.device));
        ok = ok && sent.exec() && rebase.exec();
    }
    if (!ok || !db.commit()) {
        qWarning() << "Failed to acknowledge sync batch:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

SyncStore::ApplyResult SyncStore::applyRemote(const SyncBatch& batch)
{
    ApplyResult result;
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        result.error = QStringLiteral("数据库未打开");
        return result;
    }
    const QString me = deviceId();
    if (batch.device.isEmpty() || batch.device == me) {
        // 自己写的文件不该读回来；设备标识相同更可能是两台设备恢复了同一份备份，合并会把两边搅乱。
        result.error = QStringLiteral("这批改动的设备标识与本机相同，已拒绝");
        return result;
    }
    if (batch.epoch != epoch()) {
        result.error = QStringLiteral("这批改动属于另一个同步纪元，不能直接合并");
        return result;
    }

    if (!db.transaction()) {
        result.error = db.lastError().text();
        return result;
    }
    const auto fail = [&db, &result](const QString& error) {
        db.rollback();
        ApplyResult failed;
        failed.error = error;
        qWarning() << "Failed to apply remote sync batch:" << error;
        result = failed;
        return result;
    };

    QSqlQuery query(db);
    // 置位「正在应用远端改动」：同一事务里所有同步触发器都跳过，收到的改动不会被当成本机修改再发回去。
    // 复位也在事务里；中途失败回滚时标记随之回到 0，不会把触发器永久关掉。
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }

    // 按表的依赖顺序应用：先有科目，任务才能指向它。同一张表内保持对方写出的顺序。
    QList<SyncRecord> records = batch.records;
    std::stable_sort(records.begin(), records.end(), [](const SyncRecord& a, const SyncRecord& b) {
        return tableOrder(a.table) < tableOrder(b.table);
    });

    Applier applier(db, me, &result);
    for (const SyncRecord& record : records) {
        // 每条记录一个保存点：失败只撤掉这一条，整批照常提交。sol6 的方案一条记录撞上外键就整批失败、
        // 每次重试都一样失败，同步从此卡死；这里绝不能这样。
        if (!query.exec(QStringLiteral("SAVEPOINT sync_record"))) {
            return fail(query.lastError().text());
        }
        QString error;
        if (applier.apply(record, &error)) {
            if (!query.exec(QStringLiteral("RELEASE sync_record"))) {
                return fail(query.lastError().text());
            }
            continue;
        }
        if (!query.exec(QStringLiteral("ROLLBACK TO sync_record"))
            || !query.exec(QStringLiteral("RELEASE sync_record"))) {
            return fail(query.lastError().text());
        }
        applier.logSkipped(record, error);
    }
    for (const SyncSettingRecord& setting : batch.settings) {
        if (!query.exec(QStringLiteral("SAVEPOINT sync_setting"))) {
            return fail(query.lastError().text());
        }
        QString error;
        const bool applied = applier.applySetting(setting, &error);
        if (!applied && !query.exec(QStringLiteral("ROLLBACK TO sync_setting"))) {
            return fail(query.lastError().text());
        }
        if (!query.exec(QStringLiteral("RELEASE sync_setting"))) {
            return fail(query.lastError().text());
        }
        if (!applied) {
            qWarning() << "Skipped sync setting" << setting.key << error;
            ++result.skippedRecords;
        }
    }

    // 把见过的最大逻辑时间并入本机时钟：之后本机再改这些记录，新版本一定排在它们后面。
    // 要在收尾之前做：收尾里的合并、重排是「看过这批之后」的本机改动，版本必须比这批里的都新。
    query.prepare(QStringLiteral(
        "UPDATE sync_state SET value = CAST(MAX(CAST(value AS INTEGER), :seen) AS TEXT) WHERE key = 'hlc'"));
    query.bindValue(QStringLiteral(":seen"), applier.maxSeenTime());
    if (!query.exec()) {
        return fail(query.lastError().text());
    }
    // 收尾失败只可能是数据库本身出错（磁盘满之类），整批回滚，下次再试；不会因为某条数据卡住。
    QString finishError;
    if (!applier.finalizeCategoryNames(&finishError) || !applier.normalizeTaskOrders(&finishError)) {
        return fail(finishError);
    }
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    if (!db.commit()) {
        return fail(db.lastError().text());
    }
    result.ok = true;
    return result;
}
