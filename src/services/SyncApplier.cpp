// 单批远端记录的应用实现；从 SyncStore 拆出以分开存储入口与合并细节，函数体保持原样。
#include "SyncApplier.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "RoutineRules.h"
#include "SyncFiles.h"
#include "SyncSchema.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonDocument>
#include <QMap>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QTimeZone>

#include <algorithm>
#include <utility>

namespace SyncStoreDetail {

// 冲突日志只留最近这么多条：它是给人翻看的，不是审计档案，不能无限长。
constexpr int kConflictLogLimit = 500;
// 合并链（A 并进 B、B 又并进 C……）最多追这么多步。合并总是并向身份较小的一方，不会成环；
// 上限只防外部改坏的数据让这里死循环。
constexpr int kMaxMergeHops = 16;
// 正常设备时差在秒级；不跟随异常超前部分，因果顺序由被覆盖字段各自递增保证。
constexpr qint64 kMaxRemoteClockLeadMs = 10 * 60 * 1000;

const QString kKindDelete = QStringLiteral("delete");
const QString kKindReclaim = QStringLiteral("reclaim");
const QString kKindMerge = QStringLiteral("merge");
// 日志里的「已删除」：另一台删掉了一条备忘录，这台留一份删除前的内容，方便误删后找回。
// 它不是冲突：这台的内容早已发出去，无从知道对方删之前看没看到，所以不能说成「修改没有生效」。
const QString kKindRemoved = QStringLiteral("removed");

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

bool isStorageError(const QSqlError& error)
{
    bool parsed = false;
    const int code = error.nativeErrorCode().toInt(&parsed);
    if (!parsed) {
        return false;
    }
    // SQLite 扩展结果码的低 8 位是主码；只按原生码分类，不能依赖驱动错误文字或系统语言。
    switch (code & 0xff) {
    case 5:  // SQLITE_BUSY
    case 6:  // SQLITE_LOCKED
    case 7:  // SQLITE_NOMEM
    case 8:  // SQLITE_READONLY
    case 9:  // SQLITE_INTERRUPT
    case 10: // SQLITE_IOERR
    case 11: // SQLITE_CORRUPT
    case 13: // SQLITE_FULL
    case 14: // SQLITE_CANTOPEN
    case 15: // SQLITE_PROTOCOL
    case 17: // SQLITE_SCHEMA
    case 26: // SQLITE_NOTADB
        return true;
    default:
        return false;
    }
}

Applier::Applier(QSqlDatabase db, QString me, SyncStore::ApplyResult* result)
        : m_db(std::move(db)), m_me(std::move(me)), m_result(result)
    {
    }


void Applier::recordSqlError(const QSqlError& sqlError, QString* error)
{
    if (error) {
        *error = sqlError.text();
    }
    if (!m_storageFailure && isStorageError(sqlError)) {
        m_storageFailure = true;
        m_storageError = sqlError.text();
    }
}

bool Applier::takeStorageFailure(QString* error)
{
    if (!m_storageFailure) {
        return false;
    }
    *error = std::exchange(m_storageError, QString());
    m_storageFailure = false;
    return true;
}

bool Applier::exec(QSqlQuery& query, QString* error)
{
    if (query.exec()) {
        return true;
    }
    recordSqlError(query.lastError(), error);
    return false;
}

bool Applier::exec(QSqlQuery& query, const QString& sql, QString* error)
{
    if (query.exec(sql)) {
        return true;
    }
    recordSqlError(query.lastError(), error);
    return false;
}

bool Applier::prepare(QSqlQuery& query, const QString& sql)
{
    if (query.prepare(sql)) {
        return true;
    }
    // prepare 失败后 exec 可能只报告“语句未准备”，因此必须在原生错误被覆盖前记录。
    recordSqlError(query.lastError(), nullptr);
    return false;
}

bool Applier::next(QSqlQuery& query)
{
    if (query.next()) {
        return true;
    }
    // 无下一行是正常终止；只有驱动实际报告取行错误时才交给同一分类入口。
    if (query.lastError().isValid()) {
        recordSqlError(query.lastError(), nullptr);
    }
    return false;
}

bool Applier::readRow(const SyncSchema::Table& table, const QString& syncId, LocalRow* row, QString* error)
{
    const QStringList columns = columnsOf(table);
    QSqlQuery query(m_db);
    prepare(query, QStringLiteral("SELECT id, %1 FROM %2 WHERE sync_id = :id")
                      .arg(columns.join(QStringLiteral(", ")), table.name));
    query.bindValue(QStringLiteral(":id"), syncId);
    if (!exec(query, error)) {
        return false;
    }
    *row = LocalRow();
    if (next(query)) {
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
    prepare(query, QStringLiteral(
        "SELECT field, v_time, v_device, base_time, base_device, pending FROM sync_field_versions "
        "WHERE tbl = :tbl AND sync_id = :id"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    if (exec(query, nullptr)) {
        while (next(query)) {
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
    prepare(query, QStringLiteral(
        "SELECT v_time, v_device, kind, merged_into FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    if (exec(query, nullptr) && next(query)) {
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
    prepare(query, QStringLiteral("SELECT sync_id FROM %1 WHERE id = :id").arg(table));
    query.bindValue(QStringLiteral(":id"), localId);
    if (exec(query, nullptr) && next(query) && !query.value(0).toString().isEmpty()) {
        return query.value(0).toString();
    }
    // 本机编号指向的记录已经不在（例如专注记录里的科目快照，科目删掉后就是这样）：当作没有引用。
    return QVariant();
}

QVariant Applier::resolveLocal(const QString& table, const QVariant& syncId, bool* dangling, bool* permanentlyDeleted)
{
    *dangling = false;
    if (permanentlyDeleted) {
        *permanentlyDeleted = false;
    }
    if (!syncId.isValid() || syncId.isNull() || syncId.toString().isEmpty()) {
        return QVariant();
    }
    QString current = syncId.toString();
    for (int hop = 0; hop < kMaxMergeHops; ++hop) {
        QSqlQuery query(m_db);
        prepare(query, QStringLiteral("SELECT id FROM %1 WHERE sync_id = :id").arg(table));
        query.bindValue(QStringLiteral(":id"), current);
        if (exec(query, nullptr) && next(query)) {
            return query.value(0);
        }
        const Tombstone tombstone = readTombstone(table, current);
        if (tombstone.exists && tombstone.kind == kKindMerge && !tombstone.mergedInto.isEmpty()) {
            current = tombstone.mergedInto;
            continue;
        }
        if (permanentlyDeleted) {
            *permanentlyDeleted = tombstone.exists && tombstone.kind != kKindReclaim;
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
    prepare(query, QStringLiteral(
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
    prepare(query, QStringLiteral(
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

bool Applier::clearLocalSyncState(const QString& table, const QString& syncId, bool dequeue, QString* error)
{
    QSqlQuery versions(m_db);
    prepare(versions, QStringLiteral("DELETE FROM sync_field_versions WHERE tbl = :tbl AND sync_id = :id"));
    versions.bindValue(QStringLiteral(":tbl"), table);
    versions.bindValue(QStringLiteral(":id"), syncId);
    if (!exec(versions, error)) {
        return false;
    }
    if (!dequeue) {
        return true;
    }
    QSqlQuery outbox(m_db);
    prepare(outbox, QStringLiteral("DELETE FROM sync_outbox WHERE tbl = :tbl AND sync_id = :id"));
    outbox.bindValue(QStringLiteral(":tbl"), table);
    outbox.bindValue(QStringLiteral(":id"), syncId);
    return exec(outbox, error);
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
            prepare(touched, QStringLiteral(
                "SELECT 1 FROM tasks t WHERE t.id = :id AND (t.completed = 1 "
                "OR EXISTS (SELECT 1 FROM focus_sessions fs WHERE fs.task_id = t.id))"));
            touched.bindValue(QStringLiteral(":id"), row.id);
            if (!exec(touched, error)) {
                return false;
            }
            if (next(touched) || winner.version < latestLocalVersion(table.name, record.syncId)) {
                return republish(table.name, record.syncId, QStringLiteral("routine_generated"), winner.version.time, error);
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
            // 已发送不等于对方删之前见过：两台离线各改后，正文可能先写进文件、再收到删除。
            // 备忘录仍要保留这台设备写下的内容，不能因确认发送清掉 pending 就丢掉可找回的原文。
            const bool memoContent = table.name == QLatin1String("memos")
                && (it.key() == QLatin1String("title") || it.key() == QLatin1String("body"));
            if (!field || (!it.value().pending && !memoContent)
                || it.value().version.device != m_me) {
                continue;
            }
            // 备忘录的空标题、空正文没有可找回的东西，不记，免得日志里出现一条什么都没有的条目。
            // 要看原值：显示值会把空串写成「（空）」，拿它判断永远不为空。
            if (memoContent && row.values.value(field->column).toString().isEmpty()) {
                continue;
            }
            if (!it.value().pending) {
                // 已经发出去的内容：只留一份删除前的内容，记成「已删除」，不说成冲突。
                // 正常的删除（对方看过内容才删）也会走到这里，说「修改没有生效」就是错的。
                logConflict(kKindRemoved, table, record.syncId, label, field->column,
                            displayValue(*field, row.values.value(field->column)), QStringLiteral("（已删除）"),
                            m_me, winner.version.device,
                            QStringLiteral("另一台设备删除了这条备忘录，这里保留删除前的内容"));
                continue;
            }
            logConflict(winner.kind == kKindMerge ? kKindMerge : kKindDelete, table, record.syncId, label,
                        field->column, displayValue(*field, row.values.value(field->column)),
                        QStringLiteral("（已删除）"), m_me, winner.version.device,
                        winner.kind == kKindMerge ? QStringLiteral("这个科目已和另一台设备上的同名科目合并")
                                                  : QStringLiteral("另一台设备删除了这条记录"));
        }

        if (winner.kind == kKindReclaim && table.name == QLatin1String("tasks")
            && !notePendingRefsToReclaimed(record.syncId, row.id, error)) {
            return false;
        }
        if (!deleteLocalRow(table, row, winner, error)) {
            return false;
        }
        m_result->changedTables.insert(table.name);
    }

    const bool localWins = local.exists && winner.version == local.version && winner.kind == local.kind;
    if (!localWins && !writeTombstone(table.name, record.syncId, winner, error)) {
        return false;
    }
    // 本机的删除记录压过了对方发来的那条（用户删除压过收回，或同类里本机的更新）：对方手里还是较弱的那条，
    // 本机这条若还在待发送里，就得留着发出去。以前在这里一并出队，对方永远只有「收回」，
    // 它当天重新启用例行、生成回这条实例后，本机按删除优先忽略，两边从此一边有、一边没有。
    // 两条完全相同（对方本来就有这一条）时不必再发。
    const bool sameAsIncoming = winner.version == incoming.version && winner.kind == incoming.kind;
    return clearLocalSyncState(table.name, record.syncId, !(localWins && !sameAsIncoming), error);
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
            prepare(remove, QStringLiteral("DELETE FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
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
        if (table.name == QLatin1String("memos")) {
            // 删除先到、本机已经没有行时，也要保住对方后来发来的完整正文。
            // 普通记录级“（修改）”提示没有原文，无法兑现从日志找回内容的产品保证。
            for (const QString& column : {QStringLiteral("title"), QStringLiteral("body")}) {
                if (record.fields.contains(column)) {
                    const SyncSchema::Field* field = SyncSchema::field(table.name, column);
                    // 空的标题或正文没有可找回的内容，不记。看原值，显示值会把空串写成「（空）」。
                    if (record.fields.value(column).value.toString().isEmpty()) {
                        continue;
                    }
                    logConflict(kKindDelete, table, record.syncId, recordLabel(table, values), column,
                                displayValue(*field, record.fields.value(column).value), QStringLiteral("（已删除）"),
                                incomingLatest.device, local.version.device,
                                QStringLiteral("这条备忘录已被删除，另一台设备的修改没有生效"));
                }
            }
            return true;
        }
        logConflict(local.kind == kKindMerge ? kKindMerge : kKindDelete, table, record.syncId,
                    recordLabel(table, values), QString(), QStringLiteral("（修改）"), QStringLiteral("（已删除）"),
                    incomingLatest.device, local.version.device,
                    local.kind == kKindMerge ? QStringLiteral("这个科目已和同名科目合并，另一台设备对它的修改没有生效")
                                             : QStringLiteral("这条记录已被删除，另一台设备对它的修改没有生效"));
    }
    return true;
}

QString Applier::contentTimestamp(const SyncSchema::Table& table, const SyncRecord& record,
                                 const QHash<QString, LocalVersion>& local) const
{
    // 不同字段可以各自赢：取合并后的所有内容字段版本，避免接收顺序不同使时间倒退。
    qint64 latest = 0;
    for (const QString& field : table.versionStamp.fields) {
        const qint64 incoming = record.fields.value(field).version.time;
        latest = qMax(latest, qMax(incoming, local.value(field).version.time));
    }
    return QDateTime::fromMSecsSinceEpoch(latest, QTimeZone::UTC).toString(Qt::ISODateWithMs);
}

bool Applier::insertRow(const SyncSchema::Table& table, const SyncRecord& record, QString* error)
{
    QStringList columns{QStringLiteral("sync_id")};
    QVariantList values{record.syncId};
    bool categoryDangling = false;
    bool routineDeleted = false;
    QList<QPair<const SyncSchema::Field*, bool>> references;
    for (const SyncSchema::Field& field : table.fields) {
        if (!record.fields.contains(field.column)) {
            // 发送方没有这一列（更老的版本）：不写，落库时取表的默认值。
            continue;
        }
        QVariant value = record.fields.value(field.column).value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            bool permanentlyDeleted = false;
            value = resolveLocal(field.refTable, value, &dangling, &permanentlyDeleted);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDeleted = routineDeleted || (permanentlyDeleted && field.column == QLatin1String("routine_id"));
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
        // 乱序到达只暂时解除引用，生成标记仍是发送方的业务事实；只有永久删除才清零。
        // 接回时不能统一置1，否则合法的普通任务引用会被改成生成实例。
        const qsizetype generated = columns.indexOf(QStringLiteral("routine_generated"));
        if (routineDeleted && generated >= 0) {
            values[generated] = 0;
        }
    }
    // 只属于本机、不同步却不许为空的列（知识缺口、倒计时的 updated_at）：按本机此刻补上，和本机新建时一样。
    for (const QString& column : table.stampOnInsert) {
        columns.append(column);
        values.append(QDateTime::currentDateTime().toString(Qt::ISODate));
    }
    if (!table.versionStamp.column.isEmpty()) {
        columns.append(table.versionStamp.column);
        values.append(contentTimestamp(table, record));
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
    prepare(insert, QStringLiteral("INSERT INTO %1 (%2) VALUES (%3)")
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
    prepare(clear, QStringLiteral("DELETE FROM sync_pending_refs WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
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
    prepare(note, QStringLiteral(
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
    prepare(find, QStringLiteral(
        "SELECT tbl, sync_id, field, v_time, v_device FROM sync_pending_refs WHERE target_sync_id = :target"));
    find.bindValue(QStringLiteral(":target"), targetSyncId);
    if (!exec(find, error)) {
        return false;
    }
    while (next(find)) {
        pending.append({find.value(0).toString(), find.value(1).toString(), find.value(2).toString(),
                        {find.value(3).toLongLong(), find.value(4).toString()}});
    }
    find.finish();

    for (const Pending& item : pending) {
        const SyncSchema::Field* field = SyncSchema::field(item.table, item.field);
        QSqlQuery remove(m_db);
        prepare(remove, QStringLiteral(
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
        prepare(relink, QStringLiteral("UPDATE %1 SET %2 = :target WHERE sync_id = :id AND %2 IS NULL")
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

bool Applier::notePendingRefsToReclaimed(const QString& targetSyncId, qint64 localId, QString* error)
{
    // 按同步表清单找出所有指向任务的引用列（目前是知识缺口的来源任务、关联任务；专注过的实例不会被收回，
    // 所以专注记录不会走到这里，但照清单处理，以后加了引用任务的列也不会漏）。
    // 版本取这一列现在的版本：之后这一列再被改过（任何一边），就以后来的为准，不去接回。
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        for (const SyncSchema::Field& field : table.fields) {
            if (field.refTable != QLatin1String("tasks")) {
                continue;
            }
            QSqlQuery note(m_db);
            prepare(note, QStringLiteral(
                "INSERT INTO sync_pending_refs (tbl, sync_id, field, target_sync_id, v_time, v_device) "
                "SELECT '%1', r.sync_id, '%2', :target, COALESCE(v.v_time, 0), COALESCE(v.v_device, '') "
                "FROM %1 r LEFT JOIN sync_field_versions v "
                "ON v.tbl = '%1' AND v.sync_id = r.sync_id AND v.field = '%2' "
                "WHERE r.%2 = :id AND r.sync_id IS NOT NULL "
                "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET target_sync_id = excluded.target_sync_id, "
                "v_time = excluded.v_time, v_device = excluded.v_device")
                             .arg(table.name, field.column));
            note.bindValue(QStringLiteral(":target"), targetSyncId);
            note.bindValue(QStringLiteral(":id"), localId);
            if (!exec(note, error)) {
                return false;
            }
        }
    }
    return true;
}

bool Applier::resolveAllPendingRefs(QString* error)
{
    struct Pending {
        QString table;
        QString syncId;
        QString field;
        QString target;
        SyncVersion version;
    };
    QList<Pending> pending;
    QSqlQuery find(m_db);
    prepare(find, QStringLiteral(
        "SELECT tbl, sync_id, field, target_sync_id, v_time, v_device FROM sync_pending_refs"));
    if (!exec(find, error)) {
        return false;
    }
    while (next(find)) {
        pending.append({find.value(0).toString(), find.value(1).toString(), find.value(2).toString(),
                        find.value(3).toString(), {find.value(4).toLongLong(), find.value(5).toString()}});
    }
    find.finish();

    const auto forget = [this, error](const Pending& item) {
        QSqlQuery remove(m_db);
        prepare(remove, QStringLiteral(
            "DELETE FROM sync_pending_refs WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
        remove.bindValue(QStringLiteral(":tbl"), item.table);
        remove.bindValue(QStringLiteral(":id"), item.syncId);
        remove.bindValue(QStringLiteral(":field"), item.field);
        return exec(remove, error);
    };
    for (const Pending& item : pending) {
        const SyncSchema::Field* field = SyncSchema::field(item.table, item.field);
        if (!field || field->refTable.isEmpty()) {
            // 不是引用列（外部改过库）：留着也永远接不上。
            if (!forget(item)) {
                return false;
            }
            continue;
        }
        bool dangling = false;
        const QVariant target = resolveLocal(field->refTable, item.target, &dangling);
        if (dangling) {
            // 目标还没有：被永久删除（用户删除、合并后追不到）的不用再等，置空就是最终结果；
            // 还没收到、或被收回、之后可能补回来的，接着等。
            const Tombstone tombstone = readTombstone(field->refTable, item.target);
            if (tombstone.exists && tombstone.kind != kKindReclaim) {
                // 暂缺期间保留的生成事实在例行永久删除后才失效；只处理仍等待同一版本的引用。
                if (item.table == QLatin1String("tasks") && item.field == QLatin1String("routine_id")
                    && fieldVersion(item.table, item.syncId, item.field) == item.version) {
                    QSqlQuery clearGenerated(m_db);
                    prepare(clearGenerated, QStringLiteral(
                        "UPDATE tasks SET routine_generated = 0 WHERE sync_id = :id AND routine_id IS NULL"));
                    clearGenerated.bindValue(QStringLiteral(":id"), item.syncId);
                    if (!exec(clearGenerated, error)) {
                        return false;
                    }
                    if (clearGenerated.numRowsAffected() > 0) {
                        m_result->changedTables.insert(item.table);
                    }
                }
                if (!forget(item)) {
                    return false;
                }
            }
            continue;
        }
        if (!forget(item)) {
            return false;
        }
        // 只接回「还是当初那次写入」的引用：这一列后来被改过，就以后来的为准。
        if (fieldVersion(item.table, item.syncId, item.field) != item.version) {
            continue;
        }
        QSqlQuery relink(m_db);
        prepare(relink, QStringLiteral("UPDATE %1 SET %2 = :target WHERE sync_id = :id AND %2 IS NULL")
                           .arg(item.table, item.field));
        relink.bindValue(QStringLiteral(":target"), target);
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
    SyncRecord acceptedContent;
    bool categoryDangling = false;
    bool routineDeleted = false;

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
        if (table.versionStamp.fields.contains(field.column)) {
            acceptedContent.fields.insert(field.column, incoming);
        }

        QVariant value = incoming.value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            bool permanentlyDeleted = false;
            value = resolveLocal(field.refTable, value, &dangling, &permanentlyDeleted);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDeleted = routineDeleted || (permanentlyDeleted && field.column == QLatin1String("routine_id"));
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
        if (routineDeleted) {
            assignments.append(QStringLiteral("routine_generated = ?"));
            assignedValues.append(0);
        }
    }

    // 只从真正胜出的内容版本派生时间。保留其它字段已有的较新时间，
    // 两台分别改标题和正文时才能显示一致；输掉的修改、单改排序都不推进更新时间。
    if (!acceptedContent.fields.isEmpty()) {
        assignments.append(table.versionStamp.column + QStringLiteral(" = ?"));
        assignedValues.append(contentTimestamp(table, acceptedContent, versions));
    }
    if (!assignments.isEmpty()) {
        QSqlQuery update(m_db);
        prepare(update, QStringLiteral("UPDATE %1 SET %2 WHERE id = ?")
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
    prepare(outbox, QStringLiteral(
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
        prepare(query, sql);
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
                        {target, row.id})
                || !run(QStringLiteral("UPDATE memos SET category_id = ? WHERE category_id = ?"),
                        {target, row.id})) {
                return false;
            }
            m_result->changedTables.insert(QStringLiteral("tasks"));
            m_result->changedTables.insert(QStringLiteral("routines"));
            // 课表、知识缺口第二期起也同步：两台设备收到同一条合并记录，改指得一样，不用当成本机改动再发。
            // 界面上显示的科目变了，照样要刷新。
            m_result->changedTables.insert(QStringLiteral("schedule_entries"));
            m_result->changedTables.insert(QStringLiteral("knowledge_gaps"));
            m_result->changedTables.insert(QStringLiteral("memos"));
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
            // 课表项、知识缺口的科目由外键置空：界面要刷新。
            m_result->changedTables.insert(QStringLiteral("schedule_entries"));
            m_result->changedTables.insert(QStringLiteral("knowledge_gaps"));
            m_result->changedTables.insert(QStringLiteral("memos"));
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
        m_result->changedTables.insert(QStringLiteral("knowledge_gaps"));
    }
    return run(QStringLiteral("DELETE FROM %1 WHERE id = ?").arg(table.name), {row.id});
}

namespace {
// 设置项在冲突日志里显示的名字与值。
}

bool Applier::applySetting(const SyncSettingRecord& incoming, QString* error)
{
    m_maxSeenTime = qMax(m_maxSeenTime, incoming.version.time);
    QSqlQuery query(m_db);
    prepare(query, QStringLiteral(
        "SELECT value, v_time, v_device, base_time, base_device FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), incoming.key);
    if (!exec(query, error)) {
        return false;
    }
    QSqlQuery write(m_db);
    if (!next(query)) {
        prepare(write, QStringLiteral(
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
                logConflict(QStringLiteral("edit"), settings, incoming.key, SyncSchema::settingLabel(incoming.key),
                            incoming.key, SyncSchema::settingDisplay(incoming.key, localValue),
                            SyncSchema::settingDisplay(incoming.key, incoming.value), m_me, incoming.version.device,
                            detail);
            }
        } else {
            if (!same && local.device == m_me && localBase != incoming.version && incoming.version.device != m_me
                && !incoming.version.isMinimal()) {
                logConflict(QStringLiteral("edit"), settings, incoming.key, SyncSchema::settingLabel(incoming.key),
                            incoming.key, SyncSchema::settingDisplay(incoming.key, incoming.value),
                            SyncSchema::settingDisplay(incoming.key, localValue), incoming.version.device, m_me,
                            detail);
            }
            return true;
        }
        if (same && incoming.version == local) {
            return true;
        }
        prepare(write, QStringLiteral(
            "UPDATE sync_settings SET value = :value, v_time = :t, v_device = :d, base_time = :bt, "
            "base_device = :bd, pending = 0 WHERE key = :key"));
        if (same) {
            // 值相同、只是版本更新：照抄版本，不算设置变了。
            write.bindValue(QStringLiteral(":key"), incoming.key);
            write.bindValue(QStringLiteral(":value"), nonNull(incoming.value));
            write.bindValue(QStringLiteral(":t"), incoming.version.time);
            write.bindValue(QStringLiteral(":d"), nonNull(incoming.version.device));
            write.bindValue(QStringLiteral(":bt"), incoming.base.time);
            write.bindValue(QStringLiteral(":bd"), nonNull(incoming.base.device));
            return exec(write, error);
        }
    }
    write.bindValue(QStringLiteral(":key"), incoming.key);
    write.bindValue(QStringLiteral(":value"), nonNull(incoming.value));
    write.bindValue(QStringLiteral(":t"), incoming.version.time);
    write.bindValue(QStringLiteral(":d"), nonNull(incoming.version.device));
    write.bindValue(QStringLiteral(":bt"), incoming.base.time);
    write.bindValue(QStringLiteral(":bd"), nonNull(incoming.base.device));
    if (!exec(write, error) || !markSettingWriteBack(incoming.key, QStringLiteral("set"), error)) {
        return false;
    }
    m_result->changedSettings.insert(incoming.key, incoming.value);
    return true;
}

bool Applier::markSettingWriteBack(const QString& key, const QString& kind, QString* error)
{
    // 和库里的新值在同一个事务里落盘：要么都在、要么都不在。之后写回本机之前被结束，下次启动据此先把它写回。
    QSqlQuery mark(m_db);
    prepare(mark, QStringLiteral("INSERT OR REPLACE INTO sync_state (key, value) VALUES (:key, :kind)"));
    mark.bindValue(QStringLiteral(":key"), QStringLiteral("writeback/") + key);
    mark.bindValue(QStringLiteral(":kind"), kind);
    return exec(mark, error);
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
        if (!exec(rows, QStringLiteral("SELECT sync_id FROM %1 r WHERE r.sync_id IS NOT NULL AND %2")
                           .arg(table.name, SyncSchema::publishConditionFor(table, QStringLiteral("r"))), nullptr)) {
            if (error) {
                *error = rows.lastError().text();
            }
            return false;
        }
        QStringList missing;
        while (next(rows)) {
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
        if (!exec(clear, QString::fromLatin1(sql), nullptr)) {
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
    bool routineDeleted = false;
    for (const SyncSchema::Field& field : table->fields) {
        if (!record.fields.contains(field.column)) {
            continue;
        }
        const SyncFieldValue incoming = record.fields.value(field.column);
        QVariant value = incoming.value;
        if (!field.refTable.isEmpty()) {
            bool dangling = false;
            bool permanentlyDeleted = false;
            value = resolveLocal(field.refTable, value, &dangling, &permanentlyDeleted);
            categoryDangling = categoryDangling || (dangling && field.column == QLatin1String("category_id"));
            routineDeleted = routineDeleted || (permanentlyDeleted && field.column == QLatin1String("routine_id"));
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
    if (!table->versionStamp.column.isEmpty()) {
        // 快照整体替换已有行也要更新派生时间，否则全局回滚后仍显示回滚前的“最后修改”。
        assignments.append(table->versionStamp.column + QStringLiteral(" = ?"));
        values.append(contentTimestamp(*table, record));
    }
    if (table->name == QLatin1String("tasks")) {
        if (categoryDangling) {
            assignments.append(QStringLiteral("category = ?"));
            values.append(QVariant());
        }
        if (routineDeleted) {
            assignments.append(QStringLiteral("routine_generated = ?"));
            values.append(0);
        }
    }
    if (!assignments.isEmpty()) {
        QSqlQuery update(m_db);
        prepare(update, QStringLiteral("UPDATE %1 SET %2 WHERE id = ?")
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
    if (!exec(read, QStringLiteral("SELECT key, value FROM sync_settings"), nullptr)) {
        if (error) {
            *error = read.lastError().text();
        }
        return false;
    }
    while (next(read)) {
        previous.insert(read.value(0).toString(), read.value(1).toString());
    }
    read.finish();
    QSqlQuery clear(m_db);
    if (!exec(clear, QStringLiteral("DELETE FROM sync_settings"), nullptr)) {
        if (error) {
            *error = clear.lastError().text();
        }
        return false;
    }
    for (const SyncSettingRecord& setting : settings) {
        m_maxSeenTime = qMax(m_maxSeenTime, setting.version.time);
        QSqlQuery insert(m_db);
        prepare(insert, QStringLiteral(
            "INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
            "VALUES (:key, :value, :t, :d, :bt, :bd, 0)"));
        insert.bindValue(QStringLiteral(":key"), setting.key);
        insert.bindValue(QStringLiteral(":value"), nonNull(setting.value));
        insert.bindValue(QStringLiteral(":t"), setting.version.time);
        insert.bindValue(QStringLiteral(":d"), nonNull(setting.version.device));
        insert.bindValue(QStringLiteral(":bt"), setting.base.time);
        insert.bindValue(QStringLiteral(":bd"), nonNull(setting.base.device));
        // 整体替换以快照为准：每一项都写回本机并记「待写回」，不只是和库里原来记的不同的那几项。
        // 本机设置与库里记的本来就可能不一致（本机改了没记上），只写「变了的」会把这种不一致留下来，
        // 下次启动时它会被当成本机改动，反过来盖掉快照的值。
        if (!exec(insert, error) || !markSettingWriteBack(setting.key, QStringLiteral("set"), error)) {
            return false;
        }
        m_result->changedSettings.insert(setting.key, setting.value);
        previous.remove(setting.key);
    }
    // 快照里没有的项也要让调用方知道：今日目标是按日期一项一项记的，快照里没有那一天，
    // 本机就该删掉那一天的目标；只从这张表里删、本机设置不动的话，下次启动它又会被当成本机改动发回去。
    // 同样记「待写回」：删之前被结束，下次启动先把它删掉。
    for (auto it = previous.cbegin(); it != previous.cend(); ++it) {
        if (!markSettingWriteBack(it.key(), QStringLiteral("remove"), error)) {
            return false;
        }
        m_result->removedSettings.insert(it.key());
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
    prepare(query, QStringLiteral("UPDATE sync_runtime SET applying = :applying WHERE singleton_id = 1"));
    query.bindValue(QStringLiteral(":applying"), applying ? 1 : 0);
    return exec(query, error);
}

bool Applier::mergeRemoteClock(QString* error)
{
    QSqlQuery query(m_db);
    if (!exec(query, QStringLiteral("SELECT (%1) + %2").arg(SyncSchema::sqlNowMs()).arg(kMaxRemoteClockLeadMs), error)
        || !next(query)) {
        return false;
    }
    const qint64 limit = query.value(0).toLongLong();
    query.finish();
    if (m_maxSeenTime > limit && !m_warnedFutureClock) {
        qWarning() << "远端同步时钟超前超过十分钟，限制本机逻辑时钟跟随：" << m_maxSeenTime << "上限：" << limit;
        m_warnedFutureClock = true;
    }
    // 只限制全局时钟，远端记录保留原版本；同批中途和收尾共用此口径，失败随事务回滚。
    prepare(query, QStringLiteral(
        "UPDATE sync_state SET value = CAST(MAX(CAST(value AS INTEGER), MIN(:seen, :limit)) AS TEXT) WHERE key = 'hlc'"));
    query.bindValue(QStringLiteral(":seen"), m_maxSeenTime);
    query.bindValue(QStringLiteral(":limit"), limit);
    return exec(query, error);
}

bool Applier::advanceClock(qint64 afterTime, SyncVersion* version, QString* error)
{
    // 应用对方改动的中途生成的本机版本（例如重新发布一条被收回、其实专注过的实例）是「看过这批之后」的改动，
    // 必须排在这批已经见过的版本之后，所以先把见过的时间（有上限地）并进时钟；超出上限的部分由 afterTime + 1 兜住。
    // 并进去的时间和这批数据在同一个事务里，失败时一起回滚。
    if (!mergeRemoteClock(error)) {
        return false;
    }
    QSqlQuery query(m_db);
    if (!exec(query, SyncSchema::sqlAdvanceClock(), nullptr)
        || !exec(query, QStringLiteral("SELECT %1, %2").arg(SyncSchema::sqlCurrentClock(), SyncSchema::sqlDeviceId()), nullptr)
        || !next(query)) {
        if (error) {
            *error = query.lastError().text();
        }
        return false;
    }
    // 中途补发、科目合并也须超过被覆盖版本；只提高这次本机版本，不把异常超前值写回全局 HLC。
    *version = {qMax(query.value(0).toLongLong(), afterTime + 1), query.value(1).toString()};
    return true;
}

bool Applier::republish(const QString& table, const QString& syncId, const QString& field, qint64 afterTime, QString* error)
{
    SyncVersion version;
    if (!advanceClock(qMax(afterTime, latestLocalVersion(table, syncId).time), &version, error)) {
        return false;
    }
    // 值不变，只给这一列一个本机的新版本：整条记录会带着它发出去，版本比对方手里的删除记录新。
    QSqlQuery stamp(m_db);
    prepare(stamp, QStringLiteral(
        "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
        "VALUES (:tbl, :id, :field, :t, :d, 0, '', 1) "
        "ON CONFLICT(tbl, sync_id, field) DO UPDATE SET "
        "base_time = CASE WHEN pending = 1 THEN base_time ELSE v_time END, "
        "base_device = CASE WHEN pending = 1 THEN base_device ELSE v_device END, "
        "v_time = MAX(excluded.v_time, sync_field_versions.v_time + 1), v_device = excluded.v_device, pending = 1"));
    stamp.bindValue(QStringLiteral(":tbl"), table);
    stamp.bindValue(QStringLiteral(":id"), syncId);
    stamp.bindValue(QStringLiteral(":field"), field);
    stamp.bindValue(QStringLiteral(":t"), version.time);
    stamp.bindValue(QStringLiteral(":d"), nonNull(version.device));
    QSqlQuery outbox(m_db);
    prepare(outbox, QStringLiteral(
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
        prepare(query, sql);
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
        || !run(QStringLiteral("UPDATE knowledge_gaps SET category_id = ? WHERE category_id = ?"), {winnerId, loserId})
        || !run(QStringLiteral("UPDATE memos SET category_id = ? WHERE category_id = ?"), {winnerId, loserId})) {
        return false;
    }

    // 合并本身必须发出去：对方可能没有撞名（例如对方同时把这个科目改成了别的名字），
    // 不告诉它，它会一直留着这个科目，两边从此不一致。
    SyncVersion version;
    if (!advanceClock(qMax(latestLocalVersion(QStringLiteral("categories"), loserSyncId).time,
                           readTombstone(QStringLiteral("categories"), loserSyncId).version.time), &version, error)) {
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
    for (const char* changed : {"categories", "tasks", "routines", "focus_sessions", "memos"}) {
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
        prepare(taken, QStringLiteral("SELECT 1 FROM categories WHERE name = :name"));
        taken.bindValue(QStringLiteral(":name"), candidate);
        if (!exec(taken, error)) {
            return false;
        }
        if (!next(taken)) {
            break;
        }
    }
    // 这是本机做出的改名，放开触发器让它照常记版本、入队：两台设备算出同一个名字，版本不同也会收敛。
    QSqlQuery rename(m_db);
    prepare(rename, QStringLiteral("UPDATE categories SET name = :name WHERE id = :id"));
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
        prepare(self, QStringLiteral("SELECT is_preset FROM categories WHERE id = :id"));
        self.bindValue(QStringLiteral(":id"), id);
        if (!exec(self, error)) {
            return false;
        }
        if (!next(self)) {
            // 前面一步已经把它当作撞名的一方合并掉了。
            continue;
        }
        const bool selfPreset = self.value(0).toInt() == 1;

        QSqlQuery holder(m_db);
        prepare(holder, QStringLiteral("SELECT id, sync_id, is_preset FROM categories WHERE name = :name AND id <> :id"));
        holder.bindValue(QStringLiteral(":name"), name);
        holder.bindValue(QStringLiteral(":id"), id);
        if (!exec(holder, error)) {
            return false;
        }
        QSqlQuery finalize(m_db);
        prepare(finalize, QStringLiteral("UPDATE categories SET name = :name WHERE id = :id"));
        finalize.bindValue(QStringLiteral(":name"), name);
        finalize.bindValue(QStringLiteral(":id"), id);
        if (!next(holder)) {
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
        prepare(check, QStringLiteral(
            "SELECT COUNT(*) - COUNT(DISTINCT display_order), MIN(display_order), COUNT(*) FROM tasks WHERE date = :date"));
        check.bindValue(QStringLiteral(":date"), date);
        if (!exec(check, error) || !next(check)) {
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
        prepare(renumber, QStringLiteral(
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

bool Applier::normalizeCountdownOrders(QString* error)
{
    // 只有这一批动过倒计时才查：重排要读整张表，不能每批都做一遍。
    if (!m_result->changedTables.contains(QStringLiteral("countdown_goals"))) {
        return true;
    }
    QSqlQuery check(m_db);
    if (!exec(check, QStringLiteral("SELECT COUNT(*) - COUNT(DISTINCT display_order) FROM countdown_goals"), nullptr)
        || !next(check)) {
        if (error) {
            *error = check.lastError().text();
        }
        return false;
    }
    const bool duplicated = check.value(0).toInt() > 0;
    check.finish();
    if (!duplicated) {
        return true;
    }
    // 重排是本机改动：放开触发器，让它们照常记版本、入队（与任务的同日重排同一个道理）。
    // 倒计时服务的排序号从 0 起；最后用 sync_id 打破平局——两台设备上它相同，本机编号却不同。只写真的变了的行。
    if (!setApplying(false, error)) {
        return false;
    }
    QSqlQuery renumber(m_db);
    if (!exec(renumber, QStringLiteral(
            "WITH ranked AS (SELECT id, ROW_NUMBER() OVER (ORDER BY display_order ASC, created_at ASC, sync_id ASC) - 1 AS n "
            "FROM countdown_goals) "
            "UPDATE countdown_goals SET display_order = (SELECT n FROM ranked WHERE ranked.id = countdown_goals.id) "
            "WHERE display_order <> (SELECT n FROM ranked WHERE ranked.id = countdown_goals.id)"), nullptr)) {
        if (error) {
            *error = renumber.lastError().text();
        }
        return false;
    }
    return setApplying(true, error);
}

bool Applier::normalizeMemoOrders(QString* error)
{
    if (!m_result->changedTables.contains(QStringLiteral("memos"))) {
        return true;
    }
    QSqlQuery check(m_db);
    // GROUP BY 将 NULL 单独分组，未分类同样要处理；用 = NULL 会漏掉整组。
    if (!exec(check, QStringLiteral("SELECT category_id FROM memos GROUP BY category_id "
                                   "HAVING COUNT(*) > COUNT(DISTINCT sort_order)"), nullptr)) {
        *error = check.lastError().text();
        return false;
    }
    QVariantList categories;
    while (next(check)) {
        categories.append(check.value(0));
    }
    check.finish();
    if (categories.isEmpty()) {
        return true;
    }
    // 与任务重排一样，这一步是本机改动。只动顺序列，内容更新时间保持原值。
    if (!setApplying(false, error)) {
        return false;
    }
    for (const QVariant& category : categories) {
        QSqlQuery renumber(m_db);
        prepare(renumber, QStringLiteral(
            "WITH ranked AS (SELECT id, ROW_NUMBER() OVER (ORDER BY sort_order, created_at, sync_id) AS n "
            "FROM memos WHERE category_id IS :category) "
            "UPDATE memos SET sort_order = (SELECT n FROM ranked WHERE ranked.id = memos.id) "
            "WHERE category_id IS :category2 AND sort_order <> (SELECT n FROM ranked WHERE ranked.id = memos.id)"));
        renumber.bindValue(QStringLiteral(":category"), category);
        renumber.bindValue(QStringLiteral(":category2"), category);
        if (!exec(renumber, error)) {
            return false;
        }
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
    // 废纸篓记录不写日志：它是删除那一刻的快照，不是谁的编辑。两台各写的同一条合成一份（字段取较新的一边）、
    // 晚到的一份被删除记录挡住，都是预期结果，没有丢掉任何修改，记下来只会让人以为出了冲突。
    // 只有应用失败被跳过（skipped）照常记：否则这一条记录静默消失，没人知道它没同步过来。
    if (table.name == QLatin1String("trash_items") && kind != QLatin1String("skipped")) {
        return;
    }
    // 空的 QString 绑定进去是 SQL 的 NULL，会撞上日志表的 NOT NULL；一律收敛成空串。
    const auto text = [](const QString& value) { return value.isNull() ? QStringLiteral("") : value; };
    QSqlQuery query(m_db);
    prepare(query, QStringLiteral(
        "INSERT INTO sync_conflict_log (logged_at, kind, tbl, sync_id, record_label, field, lost_value, "
        "kept_value, lost_device, kept_device, detail) "
        "VALUES (:at, :kind, :tbl, :id, :label, :field, :lost, :kept, :lostDevice, :keptDevice, :detail)"));
    query.bindValue(QStringLiteral(":at"), QDateTime::currentDateTime().toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":kind"), text(kind));
    query.bindValue(QStringLiteral(":tbl"), text(table.name));
    query.bindValue(QStringLiteral(":id"), text(syncId));
    query.bindValue(QStringLiteral(":label"), text(truncated(recordLabel)));
    query.bindValue(QStringLiteral(":field"), text(field));
    // 保存完整值供找回内容；摘要只在展示层缩短，数据库不能先截掉正文。
    query.bindValue(QStringLiteral(":lost"), text(lostValue));
    query.bindValue(QStringLiteral(":kept"), text(keptValue));
    query.bindValue(QStringLiteral(":lostDevice"), text(lostDevice));
    query.bindValue(QStringLiteral(":keptDevice"), text(keptDevice));
    query.bindValue(QStringLiteral(":detail"), text(detail));
    if (!exec(query, nullptr)) {
        // 非存储类日志错误仍不影响已确定的合并结果；存储错误已记录，由外层事务统一回滚重试。
        qWarning() << "Failed to write sync conflict log:" << query.lastError().text();
        return;
    }
    ++m_result->conflictsLogged;
    QSqlQuery prune(m_db);
    exec(prune, QStringLiteral("DELETE FROM sync_conflict_log WHERE id <= "
                              "(SELECT MAX(id) - %1 FROM sync_conflict_log)").arg(kConflictLogLimit), nullptr);
}

QString Applier::recordLabel(const SyncSchema::Table& table, const QHash<QString, QVariant>& values)
{
    if (table.name == QLatin1String("memos")) {
        const QString title = values.value(QStringLiteral("title")).toString();
        if (!title.trimmed().isEmpty()) {
            return title;
        }
        QString firstLine = values.value(QStringLiteral("body")).toString().section(QLatin1Char('\n'), 0, 0);
        if (firstLine.endsWith(QLatin1Char('\r'))) {
            firstLine.chop(1); // 与 MemoService 的列表标题一致，只去掉换行前的 CR。
        }
        return firstLine;
    }
    if (table.name == QLatin1String("categories")) {
        return values.value(QStringLiteral("name")).toString();
    }
    if (table.name == QLatin1String("routines") || table.name == QLatin1String("tasks")
        || table.name == QLatin1String("schedule_entries") || table.name == QLatin1String("knowledge_gaps")
        || table.name == QLatin1String("trash_items")) {
        return values.value(QStringLiteral("title")).toString();
    }
    if (table.name == QLatin1String("countdown_goals")) {
        return values.value(QStringLiteral("name")).toString();
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
    prepare(query, QStringLiteral("SELECT %1 FROM %2 WHERE id = :id")
                      .arg(table == QLatin1String("categories") ? QStringLiteral("name") : QStringLiteral("title"),
                           table));
    query.bindValue(QStringLiteral(":id"), localId);
    return exec(query, nullptr) && next(query) ? query.value(0).toString() : QString();
}

QString Applier::displayValue(const SyncSchema::Field& field, const QVariant& localValue)
{
    const QString column = field.column;
    if (column == QLatin1String("body")) {
        // 备忘录正文必须原样保存，包括空串、空格与换行，供复制找回。
        return localValue.toString();
    }
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
    // 第二期的几张表：课表的星期、时刻、周次、单双周，知识缺口的优先级与状态，换成界面上的说法。
    if (column == QLatin1String("weekday")) {
        static const QStringList names{QStringLiteral("周一"), QStringLiteral("周二"), QStringLiteral("周三"),
                                       QStringLiteral("周四"), QStringLiteral("周五"), QStringLiteral("周六"),
                                       QStringLiteral("周日")};
        const int day = localValue.toInt();
        return day >= 1 && day <= 7 ? names.at(day - 1) : localValue.toString();
    }
    if (column == QLatin1String("start_minutes") || column == QLatin1String("end_minutes")) {
        const int minutes = localValue.toInt();
        return QStringLiteral("%1:%2").arg(minutes / 60, 2, 10, QLatin1Char('0')).arg(minutes % 60, 2, 10, QLatin1Char('0'));
    }
    if (column == QLatin1String("week_start") || column == QLatin1String("week_end")) {
        return QStringLiteral("第 %1 周").arg(localValue.toInt());
    }
    if (column == QLatin1String("week_parity")) {
        const int parity = localValue.toInt();
        return parity == 1 ? QStringLiteral("单周") : parity == 2 ? QStringLiteral("双周") : QStringLiteral("每周");
    }
    if (column == QLatin1String("priority")) {
        const int priority = localValue.toInt();
        return priority == 2 ? QStringLiteral("高") : priority == 0 ? QStringLiteral("低") : QStringLiteral("中");
    }
    if (column == QLatin1String("status")) {
        const int status = localValue.toInt();
        return status == 2 ? QStringLiteral("已解决") : status == 1 ? QStringLiteral("已安排") : QStringLiteral("待处理");
    }
    const QString text = localValue.toString();
    return text.isEmpty() ? QStringLiteral("（空）") : text;
}

} // namespace SyncStoreDetail
