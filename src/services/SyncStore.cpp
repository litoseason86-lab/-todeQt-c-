#include "SyncStore.h"
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

using namespace SyncStoreDetail;

namespace {

static_assert(SyncFiles::kSoftChangesBytes == 4 * 1024 * 1024, "默认拆分软上限需与 SyncFiles 保持一致");
static_assert(SyncFiles::kMaxChangesBytes == 8 * 1024 * 1024, "默认改动文件硬上限需与 SyncFiles 保持一致");

std::function<quint32()> restoreEpochRandomSourceForTesting;

// sync_state 的键：传输层的进度都以文本存，「纪元:序号」这种写法读的时候再拆开。
const QString kFolderIdKey = QStringLiteral("folder_id");
const QString kOutboundKey = QStringLiteral("outbound");
const QString kSnapshotPositionKey = QStringLiteral("snapshot_position");
const QString kLastSyncedKey = QStringLiteral("last_synced_at");
const QString kCursorPrefix = QStringLiteral("cursor/");
const QString kRequestPrefix = QStringLiteral("request/");
const QString kPeerSeenPrefix = QStringLiteral("peer_seen/");

QString positionText(const SyncPosition& position)
{
    return QStringLiteral("%1:%2").arg(position.epoch).arg(position.seq);
}

bool parsePositionStrict(const QString& text, SyncPosition* out)
{
    const QStringList parts = text.split(QLatin1Char(':'));
    if (parts.size() != 2) {
        return false;
    }
    bool epochOk = false;
    bool seqOk = false;
    const qint64 epoch = parts.at(0).toLongLong(&epochOk);
    const qint64 seq = parts.at(1).toLongLong(&seqOk);
    if (!epochOk || !seqOk || epoch < 0 || seq < 0) {
        return false;
    }
    if (out) {
        *out = {epoch, seq};
    }
    return true;
}

// 拆不开的（外部改过库）按「一批都没有」处理：宁可多读一遍对方的文件，也不能跳过没读过的。
SyncPosition parsePosition(const QString& text)
{
    SyncPosition position;
    return parsePositionStrict(text, &position) ? position : SyncPosition{};
}

QString stateValue(QSqlDatabase db, const QString& key)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT value FROM sync_state WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

bool setStateValue(QSqlDatabase db, const QString& key, const QString& value)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral("INSERT OR REPLACE INTO sync_state (key, value) VALUES (:key, :value)"));
    query.bindValue(QStringLiteral(":key"), key);
    query.bindValue(QStringLiteral(":value"), nonNull(value));
    if (!query.exec()) {
        qWarning() << "Failed to write sync state" << key << query.lastError().text();
        return false;
    }
    return true;
}

bool removeStateValue(QSqlDatabase db, const QString& key)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM sync_state WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    return query.exec();
}

bool removeStatePrefix(QSqlDatabase db, const QString& prefix)
{
    QSqlQuery clear(db);
    clear.prepare(QStringLiteral("DELETE FROM sync_state WHERE substr(key, 1, :length) = :prefix"));
    clear.bindValue(QStringLiteral(":length"), prefix.size());
    clear.bindValue(QStringLiteral(":prefix"), prefix);
    return clear.exec();
}

// 某个前缀下的全部位置（设备 → 位置）。键里带设备标识，前缀之后的部分就是设备。
QHash<QString, SyncPosition> statePositions(QSqlDatabase db, const QString& prefix)
{
    QHash<QString, SyncPosition> positions;
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT key, value FROM sync_state WHERE substr(key, 1, :length) = :prefix"));
    query.bindValue(QStringLiteral(":length"), prefix.size());
    query.bindValue(QStringLiteral(":prefix"), prefix);
    if (query.exec()) {
        while (query.next()) {
            positions.insert(query.value(0).toString().mid(prefix.size()), parsePosition(query.value(1).toString()));
        }
    }
    return positions;
}

// 在活跃只读/写事务内校验并读取 sync_state 的 device_id 与 epoch；
// 严禁调用失败时静默回退默认值的 getter，防止缺行或查询异常时输出空设备或错误纪元的批次/快照。
bool readSyncIdentity(QSqlDatabase db, QString* deviceId, qint64* epoch, QString* error)
{
    const auto fail = [error](const QString& message) {
        if (error) {
            *error = message;
        }
        return false;
    };
    QSqlQuery stateQuery(db);
    if (!stateQuery.exec(QStringLiteral("SELECT key, value FROM sync_state WHERE key IN ('device_id', 'epoch')"))) {
        return fail(QStringLiteral("读取同步状态身份失败: %1").arg(stateQuery.lastError().text()));
    }
    QString stateDeviceId;
    bool hasDeviceId = false;
    QString stateEpochStr;
    bool hasEpoch = false;
    while (stateQuery.next()) {
        const QString key = stateQuery.value(0).toString();
        const QString val = stateQuery.value(1).toString();
        if (key == QLatin1String("device_id")) {
            stateDeviceId = val;
            hasDeviceId = true;
        } else if (key == QLatin1String("epoch")) {
            stateEpochStr = val;
            hasEpoch = true;
        }
    }
    if (stateQuery.lastError().isValid()) {
        return fail(QStringLiteral("迭代同步状态身份失败: %1").arg(stateQuery.lastError().text()));
    }
    if (!hasDeviceId || !hasEpoch) {
        return fail(QStringLiteral("同步状态缺少必要键 device_id 或 epoch"));
    }
    if (!SyncFiles::isDeviceId(stateDeviceId)) {
        return fail(QStringLiteral("同步状态中的设备标识格式非法: %1").arg(stateDeviceId));
    }
    static const QRegularExpression epochPattern(QStringLiteral("^[0-9]+$"));
    if (!epochPattern.match(stateEpochStr).hasMatch()) {
        return fail(QStringLiteral("同步状态中的 epoch 格式非法: %1").arg(stateEpochStr));
    }
    bool epochOk = false;
    const qint64 stateEpoch = stateEpochStr.toLongLong(&epochOk);
    if (!epochOk || stateEpoch < 0) {
        return fail(QStringLiteral("同步状态中的 epoch 无法转换为非负整数: %1").arg(stateEpochStr));
    }
    *deviceId = stateDeviceId;
    *epoch = stateEpoch;
    return true;
}

enum class ReadRecordStatus {
    Found,
    Missing,
    SqlError,
};

// 按身份读出一条完整的同步记录：行还在（且满足发布条件）就读全部字段与版本，不在就读删除记录。
// 必须严格区分正常空结果（Missing）与 SQL 失败（SqlError）：
// 1. 正常空结果（如外键指向的目标记录已物理删除、或当前并未排队待接回引用）是合法的业务数据状态；
// 2. SQL 执行失败、准备失败或游标遍历出错代表底层数据库异常或元数据表损坏，必须返回 SqlError 向上阻断，
//    严禁将 SQL 错误静默吞掉冒充“未找到”，否则会漏发记录或输出残缺数据。
ReadRecordStatus readRecord(QSqlDatabase db, const SyncSchema::Table& table, const QString& syncId,
                            SyncRecord* record, QString* error = nullptr)
{
    const auto sqlFail = [error](const QString& detail) {
        if (error) {
            *error = detail;
        }
        return ReadRecordStatus::SqlError;
    };

    record->table = table.name;
    record->syncId = syncId;

    const QStringList columns = columnsOf(table);
    QSqlQuery row(db);
    row.prepare(QStringLiteral("SELECT %1 FROM %2 r WHERE r.sync_id = :id AND %3")
                    .arg(columns.join(QStringLiteral(", ")), table.name,
                         SyncSchema::publishConditionFor(table, QStringLiteral("r"))));
    row.bindValue(QStringLiteral(":id"), syncId);
    if (!row.exec()) {
        return sqlFail(QStringLiteral("读取表 %1 记录 %2 失败: %3").arg(table.name, syncId, row.lastError().text()));
    }
    if (row.next()) {
        QSqlQuery versions(db);
        versions.prepare(QStringLiteral(
            "SELECT field, v_time, v_device, base_time, base_device FROM sync_field_versions "
            "WHERE tbl = :tbl AND sync_id = :id"));
        versions.bindValue(QStringLiteral(":tbl"), table.name);
        versions.bindValue(QStringLiteral(":id"), syncId);
        if (!versions.exec()) {
            return sqlFail(QStringLiteral("读取表 %1 字段版本失败: %2").arg(table.name, versions.lastError().text()));
        }
        QHash<QString, QPair<SyncVersion, SyncVersion>> known;
        while (versions.next()) {
            known.insert(versions.value(0).toString(),
                         {{versions.value(1).toLongLong(), versions.value(2).toString()},
                          {versions.value(3).toLongLong(), versions.value(4).toString()}});
        }
        if (versions.lastError().isValid()) {
            return sqlFail(QStringLiteral("迭代表 %1 字段版本失败: %2").arg(table.name, versions.lastError().text()));
        }
        for (int index = 0; index < table.fields.size(); ++index) {
            const SyncSchema::Field& field = table.fields.at(index);
            SyncFieldValue value;
            value.value = row.value(index);
            // 没有版本行的列（查询成功但表中无该字段行，例如旧数据兼容或缺列）按最小版本发，保留原兼容语义；
            // 但上面已断言 versions.exec() 与 versions.lastError()，查询失败绝不进入此处。
            const auto version = known.value(field.column);
            value.version = version.first;
            value.base = version.second;
            if (!field.refTable.isEmpty() && !value.value.isNull()) {
                // 引用列换成对方能认的 sync_id；本机编号指向的记录已经不在时发空值。
                QSqlQuery ref(db);
                ref.prepare(QStringLiteral("SELECT sync_id FROM %1 WHERE id = :id").arg(field.refTable));
                ref.bindValue(QStringLiteral(":id"), value.value);
                if (!ref.exec()) {
                    return sqlFail(QStringLiteral("解析引用表 %1 失败: %2").arg(field.refTable, ref.lastError().text()));
                }
                if (ref.next()) {
                    value.value = ref.value(0);
                } else {
                    if (ref.lastError().isValid()) {
                        return sqlFail(
                            QStringLiteral("迭代引用表 %1 失败: %2").arg(field.refTable, ref.lastError().text()));
                    }
                    value.value = QVariant();
                }
            } else if (!field.refTable.isEmpty()) {
                // 本机暂时置空、等着接回的引用：发出去的是它本来指向的身份，而不是本机推出来的空值。
                QSqlQuery pending(db);
                pending.prepare(QStringLiteral(
                    "SELECT target_sync_id FROM sync_pending_refs WHERE tbl = :tbl AND sync_id = :id "
                    "AND field = :field AND v_time = :t AND v_device = :d"));
                pending.bindValue(QStringLiteral(":tbl"), table.name);
                pending.bindValue(QStringLiteral(":id"), syncId);
                pending.bindValue(QStringLiteral(":field"), field.column);
                pending.bindValue(QStringLiteral(":t"), value.version.time);
                pending.bindValue(QStringLiteral(":d"), nonNull(value.version.device));
                if (!pending.exec()) {
                    return sqlFail(QStringLiteral("读取待接回引用失败: %1").arg(pending.lastError().text()));
                }
                if (pending.next()) {
                    value.value = pending.value(0).toString();
                } else if (pending.lastError().isValid()) {
                    return sqlFail(QStringLiteral("迭代待接回引用失败: %1").arg(pending.lastError().text()));
                }
            }
            record->fields.insert(field.column, value);
        }
        return ReadRecordStatus::Found;
    }

    if (row.lastError().isValid()) {
        return sqlFail(QStringLiteral("迭代表 %1 记录 %2 失败: %3").arg(table.name, syncId, row.lastError().text()));
    }

    // 仅在主行正常无行时才尝试墓碑查询
    QSqlQuery tombstone(db);
    tombstone.prepare(QStringLiteral(
        "SELECT v_time, v_device, kind, merged_into FROM sync_tombstones WHERE tbl = :tbl AND sync_id = :id"));
    tombstone.bindValue(QStringLiteral(":tbl"), table.name);
    tombstone.bindValue(QStringLiteral(":id"), syncId);
    if (!tombstone.exec()) {
        return sqlFail(QStringLiteral("读取墓碑记录失败: %1").arg(tombstone.lastError().text()));
    }
    if (tombstone.next()) {
        record->deleted = true;
        record->deleteVersion = {tombstone.value(0).toLongLong(), tombstone.value(1).toString()};
        record->deleteKind = tombstone.value(2).toString();
        record->mergedInto = tombstone.value(3).toString();
        return ReadRecordStatus::Found;
    }
    if (tombstone.lastError().isValid()) {
        return sqlFail(QStringLiteral("迭代墓碑记录失败: %1").arg(tombstone.lastError().text()));
    }
    return ReadRecordStatus::Missing;
}

QString pendingRefMapKey(const QString& table, const QString& syncId, const QString& field,
                         const SyncVersion& version)
{
    constexpr QChar sep(0x001F);
    return table + sep + syncId + sep + field + sep + QString::number(version.time) + sep + version.device;
}

QString recordKey(const QString& table, const QString& syncId)
{
    return table + QChar(0x001F) + syncId;
}

// 在调用方已开启的事务内确认一批改动已发出：
// 预编译单条合并 UPDATE 语句并按 pending = 1 过滤，同时允许快照确认时跳过非待发送记录，
// 将全量快照确认从 O(总字段数) 降为 O(实际待发送字段数)。
bool acknowledgeInTransaction(QSqlDatabase db, const SyncBatch& batch, bool filterNonPending)
{
    QSet<QString> pendingRecords;
    QSet<QString> pendingSettings;
    if (filterNonPending) {
        QSqlQuery outboxIds(db);
        outboxIds.setForwardOnly(true);
        if (!outboxIds.exec(QStringLiteral("SELECT tbl, sync_id FROM sync_outbox"))) {
            return false;
        }
        while (outboxIds.next()) {
            pendingRecords.insert(recordKey(outboxIds.value(0).toString(), outboxIds.value(1).toString()));
        }
        if (outboxIds.lastError().isValid()) {
            return false;
        }
        QSqlQuery pendingFieldIds(db);
        pendingFieldIds.setForwardOnly(true);
        if (!pendingFieldIds.exec(
                QStringLiteral("SELECT DISTINCT tbl, sync_id FROM sync_field_versions WHERE pending = 1"))) {
            return false;
        }
        while (pendingFieldIds.next()) {
            pendingRecords.insert(recordKey(pendingFieldIds.value(0).toString(), pendingFieldIds.value(1).toString()));
        }
        if (pendingFieldIds.lastError().isValid()) {
            return false;
        }
        QSqlQuery pendingSettingKeys(db);
        pendingSettingKeys.setForwardOnly(true);
        if (!pendingSettingKeys.exec(QStringLiteral("SELECT key FROM sync_settings WHERE pending = 1"))) {
            return false;
        }
        while (pendingSettingKeys.next()) {
            pendingSettings.insert(pendingSettingKeys.value(0).toString());
        }
        if (pendingSettingKeys.lastError().isValid()) {
            return false;
        }
    }

    QSqlQuery outbox(db);
    if (!outbox.prepare(QStringLiteral(
            "DELETE FROM sync_outbox WHERE tbl = :tbl AND sync_id = :id AND change_time = :change"))) {
        return false;
    }
    // 单条 UPDATE 同时完成「匹配已发版本则清 pending=0」与「期间被再次改写则重算 base 为刚发出的版本」，
    // 语义与原双条 UPDATE 完全等价但仅触发一次索引查找。
    QSqlQuery fieldUpdate(db);
    if (!fieldUpdate.prepare(QStringLiteral(
            "UPDATE sync_field_versions "
            "SET pending = CASE WHEN v_time = :t AND v_device = :d THEN 0 ELSE pending END, "
            "    base_time = CASE WHEN v_time = :t2 AND v_device = :d2 THEN base_time ELSE :t3 END, "
            "    base_device = CASE WHEN v_time = :t4 AND v_device = :d4 THEN base_device ELSE :d3 END "
            "WHERE tbl = :tbl AND sync_id = :id AND field = :field AND pending = 1"))) {
        return false;
    }
    QSqlQuery settingUpdate(db);
    if (!settingUpdate.prepare(QStringLiteral(
            "UPDATE sync_settings "
            "SET pending = CASE WHEN v_time = :t AND v_device = :d THEN 0 ELSE pending END, "
            "    base_time = CASE WHEN v_time = :t2 AND v_device = :d2 THEN base_time ELSE :t3 END, "
            "    base_device = CASE WHEN v_time = :t4 AND v_device = :d4 THEN base_device ELSE :d3 END "
            "WHERE key = :key AND pending = 1"))) {
        return false;
    }

    for (const SyncRecord& record : batch.records) {
        if (filterNonPending && !pendingRecords.contains(recordKey(record.table, record.syncId))) {
            continue;
        }
        outbox.bindValue(QStringLiteral(":tbl"), record.table);
        outbox.bindValue(QStringLiteral(":id"), record.syncId);
        outbox.bindValue(QStringLiteral(":change"), record.changeTime);
        if (!outbox.exec()) {
            return false;
        }
        if (record.deleted) {
            continue;
        }
        for (auto it = record.fields.cbegin(); it != record.fields.cend(); ++it) {
            const qint64 versionTime = it.value().version.time;
            const QString versionDevice = nonNull(it.value().version.device);
            fieldUpdate.bindValue(QStringLiteral(":tbl"), record.table);
            fieldUpdate.bindValue(QStringLiteral(":id"), record.syncId);
            fieldUpdate.bindValue(QStringLiteral(":field"), it.key());
            fieldUpdate.bindValue(QStringLiteral(":t"), versionTime);
            fieldUpdate.bindValue(QStringLiteral(":d"), versionDevice);
            fieldUpdate.bindValue(QStringLiteral(":t2"), versionTime);
            fieldUpdate.bindValue(QStringLiteral(":d2"), versionDevice);
            fieldUpdate.bindValue(QStringLiteral(":t3"), versionTime);
            fieldUpdate.bindValue(QStringLiteral(":d3"), versionDevice);
            fieldUpdate.bindValue(QStringLiteral(":t4"), versionTime);
            fieldUpdate.bindValue(QStringLiteral(":d4"), versionDevice);
            if (!fieldUpdate.exec()) {
                return false;
            }
        }
    }

    for (const SyncSettingRecord& setting : batch.settings) {
        if (filterNonPending && !pendingSettings.contains(setting.key)) {
            continue;
        }
        const qint64 versionTime = setting.version.time;
        const QString versionDevice = nonNull(setting.version.device);
        settingUpdate.bindValue(QStringLiteral(":key"), setting.key);
        settingUpdate.bindValue(QStringLiteral(":t"), versionTime);
        settingUpdate.bindValue(QStringLiteral(":d"), versionDevice);
        settingUpdate.bindValue(QStringLiteral(":t2"), versionTime);
        settingUpdate.bindValue(QStringLiteral(":d2"), versionDevice);
        settingUpdate.bindValue(QStringLiteral(":t3"), versionTime);
        settingUpdate.bindValue(QStringLiteral(":d3"), versionDevice);
        settingUpdate.bindValue(QStringLiteral(":t4"), versionTime);
        settingUpdate.bindValue(QStringLiteral(":d4"), versionDevice);
        if (!settingUpdate.exec()) {
            return false;
        }
    }
    return true;
}

SyncStore::PendingChunkResult collectPendingImpl(QSqlDatabase db, bool bounded, qint64 softMaxBytes,
                                                 qint64 hardMaxBytes)
{
    SyncStore::PendingChunkResult result;
    const auto fail = [&result](const QString& message) {
        result = SyncStore::PendingChunkResult{};
        result.error = message;
        return result;
    };

    if (bounded && (softMaxBytes <= 0 || hardMaxBytes <= 0)) {
        return fail(QStringLiteral("待发送改动分批字节预算必须大于 0"));
    }
    const qint64 effectiveHard = hardMaxBytes;
    const qint64 effectiveSoft = qMin(softMaxBytes, effectiveHard);

    // 在单一只读事务中读取身份、待发送队列、记录内容与待发送设置，避免跨查询期间并发写入导致半批错位。
    if (!db.transaction()) {
        return fail(QStringLiteral("开启读取待发送改动事务失败: %1").arg(db.lastError().text()));
    }
    const auto failAndRollback = [&db, &fail](const QString& message) {
        db.rollback();
        return fail(message);
    };

    SyncBatch batch;
    QString identityError;
    if (!readSyncIdentity(db, &batch.device, &batch.epoch, &identityError)) {
        return failAndRollback(identityError);
    }

    struct Pending {
        QString table;
        QString syncId;
        qint64 changeTime = 0;
    };
    QList<Pending> pending;
    QSqlQuery outbox(db);
    outbox.setForwardOnly(true);
    if (!outbox.exec(QStringLiteral("SELECT tbl, sync_id, change_time FROM sync_outbox"))) {
        return failAndRollback(QStringLiteral("读取待发送队列失败: %1").arg(outbox.lastError().text()));
    }
    while (outbox.next()) {
        pending.append({outbox.value(0).toString(), outbox.value(1).toString(), outbox.value(2).toLongLong()});
    }
    if (outbox.lastError().isValid()) {
        return failAndRollback(QStringLiteral("迭代待发送队列失败: %1").arg(outbox.lastError().text()));
    }
    // 按表的依赖顺序、同表内按改动先后排列，确保拆批后仍优先发出被引用父表（科目 → 例行 → 任务 → 专注）。
    std::stable_sort(pending.begin(), pending.end(), [](const Pending& a, const Pending& b) {
        const qsizetype orderA = tableOrder(a.table);
        const qsizetype orderB = tableOrder(b.table);
        return orderA != orderB ? orderA < orderB : a.changeTime < b.changeTime;
    });

    QList<SyncSettingRecord> pendingSettings;
    QSqlQuery settings(db);
    settings.setForwardOnly(true);
    if (!settings.exec(QStringLiteral(
            "SELECT key, value, v_time, v_device, base_time, base_device FROM sync_settings WHERE pending = 1 "
            "ORDER BY key"))) {
        return failAndRollback(QStringLiteral("读取待发送设置失败: %1").arg(settings.lastError().text()));
    }
    while (settings.next()) {
        SyncSettingRecord setting;
        setting.key = settings.value(0).toString();
        setting.value = settings.value(1).toString();
        setting.version = {settings.value(2).toLongLong(), settings.value(3).toString()};
        setting.base = {settings.value(4).toLongLong(), settings.value(5).toString()};
        pendingSettings.append(setting);
    }
    if (settings.lastError().isValid()) {
        return failAndRollback(QStringLiteral("迭代待发送设置失败: %1").arg(settings.lastError().text()));
    }

    qint64 currentBytes = bounded ? SyncFiles::changesEnvelopeMaxBytes(batch.device, batch.epoch) : 0;

    for (const Pending& item : pending) {
        const SyncSchema::Table* table = SyncSchema::table(item.table);
        if (!table) {
            continue;
        }
        SyncRecord record;
        record.changeTime = item.changeTime;
        QString readError;
        const ReadRecordStatus status = readRecord(db, *table, item.syncId, &record, &readError);
        if (status == ReadRecordStatus::SqlError) {
            return failAndRollback(readError);
        }
        if (status == ReadRecordStatus::Missing) {
            // 既没有行也没有删除记录：只可能是外部改过库。不发，确认时也不会出队，留着等人排查。
            continue;
        }
        if (bounded) {
            const qint64 addedBytes = (batch.records.isEmpty() ? 0 : 1) + SyncJson::compactJsonBytes(record);
            if (!batch.isEmpty() && currentBytes + addedBytes > effectiveSoft) {
                result.hasMore = true;
                break;
            }
            if (batch.isEmpty() && currentBytes + addedBytes > effectiveHard) {
                if (!db.commit()) {
                    return failAndRollback(QStringLiteral("提交待发送读取事务失败: %1").arg(db.lastError().text()));
                }
                result.ok = true;
                result.oversizeSingleRecord = true;
                result.oversizeDetail = QStringLiteral(
                    "单条同步记录过大（约 %1 KB），超出单文件上限（%2 KB），无法发送；请精简对应内容后重试")
                    .arg((currentBytes + addedBytes + 1023) / 1024)
                    .arg(effectiveHard / 1024);
                return result;
            }
            currentBytes += addedBytes;
        }
        batch.records.append(std::move(record));
    }

    if (!result.hasMore) {
        for (const SyncSettingRecord& setting : pendingSettings) {
            if (bounded) {
                const qint64 addedBytes = (batch.settings.isEmpty() ? 0 : 1) + SyncJson::compactJsonBytes(setting);
                if (!batch.isEmpty() && currentBytes + addedBytes > effectiveSoft) {
                    result.hasMore = true;
                    break;
                }
                if (batch.isEmpty() && currentBytes + addedBytes > effectiveHard) {
                    if (!db.commit()) {
                        return failAndRollback(
                            QStringLiteral("提交待发送读取事务失败: %1").arg(db.lastError().text()));
                    }
                    result.ok = true;
                    result.oversizeSingleRecord = true;
                    result.oversizeDetail = QStringLiteral(
                        "单条同步设置过大（约 %1 KB），超出单文件上限（%2 KB），无法发送")
                        .arg((currentBytes + addedBytes + 1023) / 1024)
                        .arg(effectiveHard / 1024);
                    return result;
                }
                currentBytes += addedBytes;
            }
            batch.settings.append(setting);
        }
    }

    if (!db.commit()) {
        return failAndRollback(QStringLiteral("提交待发送读取事务失败: %1").arg(db.lastError().text()));
    }
    result.ok = true;
    result.batch = std::move(batch);
    return result;
}

} // namespace

SyncStore::SyncStore(const QString& connectionName)
    : m_connectionName(connectionName)
{
}

void SyncStore::setRestoreEpochRandomSourceForTesting(std::function<quint32()> source)
{
    restoreEpochRandomSourceForTesting = std::move(source);
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
    const PendingChunkResult result = collectPendingImpl(database(), false, 0, 0);
    if (!result.ok) {
        qWarning() << "Failed to collect pending sync changes:" << result.error;
        SyncBatch empty;
        empty.device = deviceId();
        empty.epoch = epoch();
        return empty;
    }
    return result.batch;
}

SyncStore::PendingChunkResult SyncStore::collectPendingChunk(qint64 softMaxBytes, qint64 hardMaxBytes) const
{
    return collectPendingImpl(database(), true, softMaxBytes, hardMaxBytes);
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
    if (query.lastError().isValid()) {
        db.rollback();
        return false;
    }
    query.finish();
    if (exists && oldValue == value) {
        // 本机与库里的值已经相同，无须产生新版本。
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
    // 设置项同样只提升被覆盖项的版本，设备归本机；base 仍保留对端可能已见过的版本。
    QSqlQuery write(db);
    write.prepare(exists
        ? QStringLiteral("UPDATE sync_settings SET "
                         "base_time = CASE WHEN pending = 1 THEN base_time ELSE v_time END, "
                         "base_device = CASE WHEN pending = 1 THEN base_device ELSE v_device END, "
                         "value = :value, v_time = MAX(:t, v_time + 1), v_device = :d, pending = 1 WHERE key = :key")
        : QStringLiteral("INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
                         "VALUES (:key, :value, :t, :d, 0, '', 1)"));
    write.bindValue(QStringLiteral(":key"), key);
    // 空值（昵称没填、学期起始日没设）多半是空的 QString，直接绑定会写成 NULL、撞上非空约束，这一项就永远记不下来。
    write.bindValue(QStringLiteral(":value"), nonNull(value));
    write.bindValue(QStringLiteral(":t"), version.time);
    write.bindValue(QStringLiteral(":d"), nonNull(version.device));
    // 确认本机编辑和撤掉旧的远端写回标记必须同事务提交，重启时不再尝试写入已被取代的值。
    if (!write.exec() || !finishSettingWriteBack(key) || !db.commit()) {
        qWarning() << "Failed to record local sync setting:" << write.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

QHash<QString, QString> SyncStore::syncedSettings(bool* ok) const
{
    if (ok) {
        *ok = false;
    }
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        return {};
    }
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("SELECT key, value FROM sync_settings"))) {
        return {};
    }
    QHash<QString, QString> settings;
    while (query.next()) {
        settings.insert(query.value(0).toString(), query.value(1).toString());
    }
    if (query.lastError().isValid()) {
        return {};
    }
    if (ok) {
        *ok = true;
    }
    return settings;
}

QHash<QString, QString> SyncStore::pendingSettingWriteBacks(bool* ok) const
{
    if (ok) {
        *ok = false;
    }
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        return {};
    }
    const QString prefix = QStringLiteral("writeback/");
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT key, value FROM sync_state WHERE substr(key, 1, :length) = :prefix"));
    query.bindValue(QStringLiteral(":length"), prefix.size());
    query.bindValue(QStringLiteral(":prefix"), prefix);
    if (!query.exec()) {
        return {};
    }
    QHash<QString, QString> pending;
    while (query.next()) {
        pending.insert(query.value(0).toString().mid(prefix.size()), query.value(1).toString());
    }
    if (query.lastError().isValid()) {
        return {};
    }
    if (ok) {
        *ok = true;
    }
    return pending;
}

bool SyncStore::finishSettingWriteBack(const QString& key)
{
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM sync_state WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), QStringLiteral("writeback/") + key);
    return query.exec();
}

QString SyncStore::syncedSetting(const QString& key) const
{
    QSqlQuery query(database());
    query.prepare(QStringLiteral("SELECT value FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

SyncBatch SyncStore::exportSnapshot(bool* ok, QString* errorOut) const
{
    const auto fail = [ok, errorOut](const QString& message) -> SyncBatch {
        if (ok) {
            *ok = false;
        }
        if (errorOut) {
            *errorOut = message;
        }
        return SyncBatch{};
    };

    QSqlDatabase db = database();
    // 使用同一连接只读事务覆盖身份、outbox、待接回引用、外键映射、所有同步表、墓碑与设置，
    // 按表批量装载消除 N+1 逐行查询，同时防止并发写入导致快照视图分裂。
    if (!db.transaction()) {
        return fail(QStringLiteral("开启快照只读事务失败: %1").arg(db.lastError().text()));
    }
    const auto failAndRollback = [&db, &fail](const QString& message) -> SyncBatch {
        db.rollback();
        return fail(message);
    };

    SyncBatch snapshot;
    QString identityError;
    if (!readSyncIdentity(db, &snapshot.device, &snapshot.epoch, &identityError)) {
        return failAndRollback(identityError);
    }

    // 快照里的记录如果也在待发送队列里，带上队列里的 change_time：快照写出后按它确认，
    // 快照已经带上的改动不必再单独发一遍。
    QHash<QString, qint64> queued;
    QSqlQuery outbox(db);
    outbox.setForwardOnly(true);
    if (!outbox.exec(QStringLiteral("SELECT tbl, sync_id, change_time FROM sync_outbox"))) {
        return failAndRollback(QStringLiteral("读取待发送队列失败: %1").arg(outbox.lastError().text()));
    }
    while (outbox.next()) {
        queued.insert(recordKey(outbox.value(0).toString(), outbox.value(1).toString()),
                      outbox.value(2).toLongLong());
    }
    if (outbox.lastError().isValid()) {
        return failAndRollback(QStringLiteral("迭代待发送队列失败: %1").arg(outbox.lastError().text()));
    }

    const auto changeTimeOf = [&queued](const QString& table, const QString& syncId) {
        return queued.value(recordKey(table, syncId), 0);
    };

    // 预加载全部待接回引用（sync_pending_refs）：仅查询一次即可供全库引用列 O(1) 查表，
    // 同时保持该元数据表异常时立即原子回滚失败的语义。
    QHash<QString, QString> pendingRefs;
    {
        QSqlQuery pendingQuery(db);
        pendingQuery.setForwardOnly(true);
        if (!pendingQuery.exec(QStringLiteral(
                "SELECT tbl, sync_id, field, v_time, v_device, target_sync_id FROM sync_pending_refs"))) {
            return failAndRollback(QStringLiteral("读取待接回引用失败: %1").arg(pendingQuery.lastError().text()));
        }
        while (pendingQuery.next()) {
            const SyncVersion version{pendingQuery.value(3).toLongLong(), pendingQuery.value(4).toString()};
            pendingRefs.insert(pendingRefMapKey(pendingQuery.value(0).toString(), pendingQuery.value(1).toString(),
                                                pendingQuery.value(2).toString(), version),
                               pendingQuery.value(5).toString());
        }
        if (pendingQuery.lastError().isValid()) {
            return failAndRollback(QStringLiteral("迭代待接回引用失败: %1").arg(pendingQuery.lastError().text()));
        }
    }

    // 预加载所有被引用表的 id → sync_id 映射（categories / routines / tasks 等）。
    QHash<QString, QHash<qint64, QVariant>> refMaps;
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        for (const SyncSchema::Field& field : table.fields) {
            if (field.refTable.isEmpty() || refMaps.contains(field.refTable)) {
                continue;
            }
            QHash<qint64, QVariant> idToSyncId;
            QSqlQuery refQuery(db);
            refQuery.setForwardOnly(true);
            if (!refQuery.exec(QStringLiteral("SELECT id, sync_id FROM %1").arg(field.refTable))) {
                return failAndRollback(
                    QStringLiteral("读取引用表 %1 映射失败: %2").arg(field.refTable, refQuery.lastError().text()));
            }
            while (refQuery.next()) {
                idToSyncId.insert(refQuery.value(0).toLongLong(), refQuery.value(1));
            }
            if (refQuery.lastError().isValid()) {
                return failAndRollback(
                    QStringLiteral("迭代引用表 %1 映射失败: %2").arg(field.refTable, refQuery.lastError().text()));
            }
            refMaps.insert(field.refTable, std::move(idToSyncId));
        }
    }

    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        // 每张表仅查询一次字段版本表与一次业务表，避免对每行每列重复执行子查询。
        QHash<QString, QHash<QString, QPair<SyncVersion, SyncVersion>>> tableVersions;
        {
            QSqlQuery versionsQuery(db);
            versionsQuery.setForwardOnly(true);
            versionsQuery.prepare(QStringLiteral(
                "SELECT sync_id, field, v_time, v_device, base_time, base_device "
                "FROM sync_field_versions WHERE tbl = :tbl"));
            versionsQuery.bindValue(QStringLiteral(":tbl"), table.name);
            if (!versionsQuery.exec()) {
                return failAndRollback(
                    QStringLiteral("读取表 %1 字段版本失败: %2").arg(table.name, versionsQuery.lastError().text()));
            }
            while (versionsQuery.next()) {
                tableVersions[versionsQuery.value(0).toString()].insert(
                    versionsQuery.value(1).toString(),
                    {{versionsQuery.value(2).toLongLong(), versionsQuery.value(3).toString()},
                     {versionsQuery.value(4).toLongLong(), versionsQuery.value(5).toString()}});
            }
            if (versionsQuery.lastError().isValid()) {
                return failAndRollback(
                    QStringLiteral("迭代表 %1 字段版本失败: %2").arg(table.name, versionsQuery.lastError().text()));
            }
        }

        const QStringList columns = columnsOf(table);
        QSqlQuery rows(db);
        rows.setForwardOnly(true);
        if (!rows.exec(QStringLiteral("SELECT r.sync_id, %1 FROM %2 r WHERE r.sync_id IS NOT NULL AND %3 ORDER BY r.id")
                           .arg(columns.join(QStringLiteral(", ")), table.name,
                                SyncSchema::publishConditionFor(table, QStringLiteral("r"))))) {
            return failAndRollback(QStringLiteral("读取表 %1 失败: %2").arg(table.name, rows.lastError().text()));
        }
        while (rows.next()) {
            const QString syncId = rows.value(0).toString();
            SyncRecord record;
            record.table = table.name;
            record.syncId = syncId;
            record.changeTime = changeTimeOf(table.name, syncId);
            const auto knownIt = tableVersions.constFind(syncId);
            for (int index = 0; index < table.fields.size(); ++index) {
                const SyncSchema::Field& field = table.fields.at(index);
                SyncFieldValue value;
                value.value = rows.value(index + 1);
                if (knownIt != tableVersions.cend()) {
                    const auto version = knownIt.value().value(field.column);
                    value.version = version.first;
                    value.base = version.second;
                }
                if (!field.refTable.isEmpty() && !value.value.isNull()) {
                    const auto refMapIt = refMaps.constFind(field.refTable);
                    if (refMapIt != refMaps.cend()) {
                        const auto targetIt = refMapIt.value().constFind(value.value.toLongLong());
                        value.value = targetIt != refMapIt.value().cend() ? targetIt.value() : QVariant();
                    } else {
                        value.value = QVariant();
                    }
                } else if (!field.refTable.isEmpty()) {
                    const auto pendingIt = pendingRefs.constFind(
                        pendingRefMapKey(table.name, syncId, field.column, value.version));
                    if (pendingIt != pendingRefs.cend()) {
                        value.value = pendingIt.value();
                    }
                }
                record.fields.insert(field.column, std::move(value));
            }
            snapshot.records.append(std::move(record));
        }
        if (rows.lastError().isValid()) {
            return failAndRollback(QStringLiteral("迭代表 %1 失败: %2").arg(table.name, rows.lastError().text()));
        }
    }

    // 删除记录也要带上：没有它们，对方拿不到「删除优先」的依据，离线设备晚到的旧修改会把删掉的记录带回来。
    QSqlQuery tombstones(db);
    tombstones.setForwardOnly(true);
    if (!tombstones.exec(QStringLiteral(
            "SELECT tbl, sync_id, v_time, v_device, kind, merged_into FROM sync_tombstones ORDER BY tbl, sync_id"))) {
        return failAndRollback(QStringLiteral("读取墓碑记录失败: %1").arg(tombstones.lastError().text()));
    }
    while (tombstones.next()) {
        SyncRecord record;
        record.table = tombstones.value(0).toString();
        record.syncId = tombstones.value(1).toString();
        record.deleted = true;
        record.deleteVersion = {tombstones.value(2).toLongLong(), tombstones.value(3).toString()};
        record.deleteKind = tombstones.value(4).toString();
        record.mergedInto = tombstones.value(5).toString();
        record.changeTime = changeTimeOf(record.table, record.syncId);
        snapshot.records.append(std::move(record));
    }
    if (tombstones.lastError().isValid()) {
        return failAndRollback(QStringLiteral("迭代墓碑记录失败: %1").arg(tombstones.lastError().text()));
    }

    QSqlQuery settings(db);
    settings.setForwardOnly(true);
    if (!settings.exec(QStringLiteral(
            "SELECT key, value, v_time, v_device, base_time, base_device FROM sync_settings ORDER BY key"))) {
        return failAndRollback(QStringLiteral("读取同步设置失败: %1").arg(settings.lastError().text()));
    }
    while (settings.next()) {
        SyncSettingRecord setting;
        setting.key = settings.value(0).toString();
        setting.value = settings.value(1).toString();
        setting.version = {settings.value(2).toLongLong(), settings.value(3).toString()};
        setting.base = {settings.value(4).toLongLong(), settings.value(5).toString()};
        snapshot.settings.append(std::move(setting));
    }
    if (settings.lastError().isValid()) {
        return failAndRollback(QStringLiteral("迭代同步设置失败: %1").arg(settings.lastError().text()));
    }

    if (!db.commit()) {
        return failAndRollback(QStringLiteral("提交快照导出只读事务失败: %1").arg(db.lastError().text()));
    }

    if (ok) {
        *ok = true;
    }
    if (errorOut) {
        errorOut->clear();
    }
    return snapshot;
}

bool SyncStore::markSnapshotPublished(const SyncBatch& snapshot)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        qWarning() << "Failed to start markSnapshotPublished transaction:" << db.lastError().text();
        return false;
    }
    QSqlQuery clearFlag(db);
    if (!acknowledgeInTransaction(db, snapshot, true)
        || !clearFlag.exec(QStringLiteral("DELETE FROM sync_state WHERE key = 'snapshot_needed'"))
        || !db.commit()) {
        qWarning() << "Failed to mark snapshot published:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

bool SyncStore::markSnapshotPublished(const SyncBatch& snapshot, const SyncPosition& position)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        qWarning() << "Failed to start markSnapshotPublished transaction:" << db.lastError().text();
        return false;
    }
    QSqlQuery clearFlag(db);
    if (!acknowledgeInTransaction(db, snapshot, true)
        || !clearFlag.exec(QStringLiteral("DELETE FROM sync_state WHERE key = 'snapshot_needed'"))
        || !setStateValue(db, kSnapshotPositionKey, positionText(position))
        || !db.commit()) {
        qWarning() << "Failed to mark snapshot published with position:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

SyncStore::ApplyResult SyncStore::replaceWithSnapshot(const SyncBatch& snapshot)
{
    return replaceWithSnapshot(snapshot, SnapshotReplaceOptions{});
}

SyncStore::ApplyResult SyncStore::replaceWithSnapshot(const SyncBatch& snapshot, const SnapshotReplaceOptions& options)
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
        // 坏记录只跳过自身，避免毒丸让快照永远无法落地；存储错误不是数据坏了，整份回滚后重试。
        if (!query.exec(QStringLiteral("SAVEPOINT sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        QString recordError;
        const bool applied = applier.overwriteFromSnapshot(record, &recordError);
        QString storageError;
        if (applier.takeStorageFailure(&storageError)) {
            return fail(storageError);
        }
        if (!applied && !query.exec(QStringLiteral("ROLLBACK TO sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        if (!query.exec(QStringLiteral("RELEASE sync_snapshot_record"))) {
            return fail(query.lastError().text());
        }
        if (!applied) {
            applier.logSkipped(record, recordError);
            if (applier.takeStorageFailure(&storageError)) {
                return fail(storageError);
            }
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
    QString clockError;
    if (!applier.mergeRemoteClock(&clockError)) {
        return fail(clockError);
    }
    if (!applier.finalizeCategoryNames(&error) || !applier.resolveAllPendingRefs(&error)
        || !applier.normalizeTaskOrders(&error) || !applier.normalizeCountdownOrders(&error)
        || !applier.normalizeMemoOrders(&error)) {
        return fail(error);
    }
    if (!query.exec(QStringLiteral("DELETE FROM sync_state WHERE key = 'snapshot_needed'"))) {
        return fail(query.lastError().text());
    }
    // 将首次加入/换纪元相关的 folder_id、对端游标、补快照请求与旧文件夹传输记账纳入同一事务：
    // 任何一项写入失败均原子回滚整个换库，杜绝“业务库已覆盖但 folder_id 未落地”造成的二次换库丢数据。
    if (!options.folderIdToSet.isEmpty() && !setStateValue(db, kFolderIdKey, options.folderIdToSet)) {
        return fail(QStringLiteral("写入同步文件夹身份失败"));
    }
    if (options.resetFolderTransportState) {
        if (!removeStateValue(db, kOutboundKey) || !removeStateValue(db, kSnapshotPositionKey)
            || !removeStatePrefix(db, kPeerSeenPrefix)) {
            return fail(QStringLiteral("重置旧同步文件夹传输记账失败"));
        }
    }
    if (options.peerCursors.has_value()) {
        if (!removeStatePrefix(db, kCursorPrefix)) {
            return fail(QStringLiteral("清空旧对端读取游标失败"));
        }
        for (auto it = options.peerCursors->cbegin(); it != options.peerCursors->cend(); ++it) {
            if (!setStateValue(db, kCursorPrefix + it.key(), positionText(it.value()))) {
                return fail(QStringLiteral("写入对端读取游标失败"));
            }
        }
    }
    if (options.clearSnapshotRequests && !removeStatePrefix(db, kRequestPrefix)) {
        return fail(QStringLiteral("清空补快照请求失败"));
    }
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    QString storageError;
    if (applier.takeStorageFailure(&storageError)) {
        return fail(storageError);
    }
    if (!db.commit()) {
        return fail(db.lastError().text());
    }
    // 整体替换：每张同步表都可能变了，界面全部刷新一次（这种事很少发生）。
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        result.changedTables.insert(table.name);
    }
    result.replacedSnapshot = true;
    result.ok = true;
    return result;
}

bool SyncStore::attachOwnFolder(const QString& folderId, bool resetTransportState)
{
    if (folderId.isEmpty()) {
        return false;
    }
    QSqlDatabase db = database();
    if (!db.transaction()) {
        return false;
    }
    QSqlQuery flag(db);
    bool ok = flag.exec(QStringLiteral("INSERT OR REPLACE INTO sync_state (key, value) VALUES ('snapshot_needed', '1')"))
        && setStateValue(db, kFolderIdKey, folderId);
    if (ok && resetTransportState) {
        ok = removeStateValue(db, kOutboundKey) && removeStateValue(db, kSnapshotPositionKey)
            && removeStatePrefix(db, kCursorPrefix) && removeStatePrefix(db, kRequestPrefix)
            && removeStatePrefix(db, kPeerSeenPrefix);
    }
    if (!ok || !db.commit()) {
        qWarning() << "Failed to attach own sync folder:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

bool SyncStore::beginEpochAfterRestore(qint64 previousEpoch, const QString& previousDeviceId,
                                      const QString& restoreOperationId)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        return false;
    }

    // 1. 若提供了非空 restoreOperationId，先检查是否已由同一恢复操作成功执行过（本地幂等恢复事务）。
    // local_restore_operation_id 仅用于本机恢复重试时的幂等保护，既不导出到同步批次/快照，也不修改网络同步协议。
    if (!restoreOperationId.isEmpty()) {
        QSqlQuery tokenQuery(db);
        tokenQuery.prepare(QStringLiteral("SELECT value FROM sync_state WHERE key = :key"));
        tokenQuery.bindValue(QStringLiteral(":key"), QStringLiteral("local_restore_operation_id"));
        if (!tokenQuery.exec()) {
            qWarning() << "Failed to query local_restore_operation_id:" << tokenQuery.lastError().text();
            db.rollback();
            return false;
        }
        if (tokenQuery.next()) {
            const QString recordedId = tokenQuery.value(0).toString();
            tokenQuery.finish();
            if (recordedId == restoreOperationId) {
                // 2. 查到已成功执行过相同恢复操作：只读提交，保持幂等；不递增 epoch，不改设备 id，不清空队列，不标记快照。
                if (!db.commit()) {
                    db.rollback();
                    return false;
                }
                return true;
            }
        } else if (tokenQuery.lastError().isValid()) {
            qWarning() << "Error reading local_restore_operation_id:" << tokenQuery.lastError().text();
            tokenQuery.finish();
            db.rollback();
            return false;
        } else {
            tokenQuery.finish();
        }
    }

    // 独立离线恢复不能总从 N 走到相同的 N+1：系统随机源均匀取低 20 位，额外增量为 [0, 2^20)。
    // 同一起点的两次恢复仍有约百万分之一的撞号概率，碰撞时保留原有同纪元合并行为；否则高纪元快照胜出。
    // 沿用文件名最多 18 位和 JSON 精确整数上限 2^53 的兼容边界，单次最多推进 2^20，不改变文件格式。
    // 取随机数须在令牌检查之后：同一恢复操作的幂等重入既不推进纪元，也不消费新的随机数。
    constexpr quint32 kRestoreEpochRandomMask = (1U << 20) - 1;
    const quint32 random = (restoreEpochRandomSourceForTesting ? restoreEpochRandomSourceForTesting()
                                                             : QRandomGenerator::system()->generate())
        & kRestoreEpochRandomMask;

    // 递增与恢复令牌在同一事务中提交；状态行必须存在，防止缺行时虚假成功。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE sync_state SET value = CAST(MAX(CAST(value AS INTEGER), :previous) + 1 + :random AS TEXT) WHERE key = 'epoch'"));
    query.bindValue(QStringLiteral(":previous"), previousEpoch);
    query.bindValue(QStringLiteral(":random"), qint64(random));
    if (!query.exec() || query.numRowsAffected() != 1) {
        qWarning() << "Failed to update epoch state row:" << query.lastError().text();
        db.rollback();
        return false;
    }

    if (!previousDeviceId.isEmpty()) {
        query.prepare(QStringLiteral("UPDATE sync_state SET value = :device WHERE key = 'device_id'"));
        query.bindValue(QStringLiteral(":device"), previousDeviceId);
        if (!query.exec() || query.numRowsAffected() != 1) {
            qWarning() << "Failed to update device_id state row:" << query.lastError().text();
            db.rollback();
            return false;
        }
    }

    // 回滚之后整份状态会作为快照发出，旧的待发送、待解析引用都不再有意义。
    bool ok = true;
    for (const char* sql : {"DELETE FROM sync_outbox", "DELETE FROM sync_pending_refs",
                            "UPDATE sync_field_versions SET pending = 0", "UPDATE sync_settings SET pending = 0",
                            "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('snapshot_needed', '1')"}) {
        ok = ok && query.exec(QString::fromLatin1(sql));
    }
    if (!ok) {
        qWarning() << "Failed to reset sync queue/snapshot state:" << query.lastError().text();
        db.rollback();
        return false;
    }

    // 在同一事务中记录 restoreOperationId token（若非空）
    if (!restoreOperationId.isEmpty()) {
        query.prepare(QStringLiteral(
            "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('local_restore_operation_id', :id)"));
        query.bindValue(QStringLiteral(":id"), restoreOperationId);
        if (!query.exec()) {
            qWarning() << "Failed to record local_restore_operation_id:" << query.lastError().text();
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit beginEpochAfterRestore transaction:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

bool SyncStore::requestFullSnapshot()
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("INSERT OR REPLACE INTO sync_state (key, value) VALUES ('snapshot_needed', '1')"));
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
    if (!acknowledgeInTransaction(db, batch, false) || !db.commit()) {
        qWarning() << "Failed to acknowledge sync batch:" << db.lastError().text();
        db.rollback();
        return false;
    }
    return true;
}

bool SyncStore::acknowledgeOutbound(const SyncBatch& batch, const SyncPosition& position)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        qWarning() << "Failed to start sync acknowledgeOutbound:" << db.lastError().text();
        return false;
    }
    if (!setStateValue(db, kOutboundKey, positionText(position))
        || !acknowledgeInTransaction(db, batch, false)
        || !db.commit()) {
        qWarning() << "Failed to acknowledge outbound sync batch:" << db.lastError().text();
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
        // 每条记录一个保存点：坏数据只撤掉这一条，避免毒丸（反复重试都失败的数据）卡死同步。
        // 存储/环境错误必须整批回滚，使 SyncEngine 不推进读取游标，环境恢复后同一批可完整重试。
        if (!query.exec(QStringLiteral("SAVEPOINT sync_record"))) {
            return fail(query.lastError().text());
        }
        QString error;
        const bool applied = applier.apply(record, &error);
        QString storageError;
        // 即使辅助查询或日志吞掉返回值，首次存储错误也必须优先于保存点处理和成功结果。
        if (applier.takeStorageFailure(&storageError)) {
            return fail(storageError);
        }
        if (applied) {
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
        if (applier.takeStorageFailure(&storageError)) {
            return fail(storageError);
        }
    }
    for (const SyncSettingRecord& setting : batch.settings) {
        if (!query.exec(QStringLiteral("SAVEPOINT sync_setting"))) {
            return fail(query.lastError().text());
        }
        QString error;
        const bool applied = applier.applySetting(setting, &error);
        QString storageError;
        if (applier.takeStorageFailure(&storageError)) {
            return fail(storageError);
        }
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

    // 收尾的合并、重排也是本机改动；先有限跟随远端时钟，异常超前由字段因果递增处理。
    QString clockError;
    if (!applier.mergeRemoteClock(&clockError)) {
        return fail(clockError);
    }
    // 收尾失败只可能是数据库本身出错（磁盘满之类），整批回滚，下次再试；不会因为某条数据卡住。
    // 接回引用要在重排之前：重排会临时放开触发器，而接回不是本机改动，不能被记成新版本。
    QString finishError;
    if (!applier.finalizeCategoryNames(&finishError) || !applier.resolveAllPendingRefs(&finishError)
        || !applier.normalizeTaskOrders(&finishError) || !applier.normalizeCountdownOrders(&finishError)
        || !applier.normalizeMemoOrders(&finishError)) {
        return fail(finishError);
    }
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    QString storageError;
    if (applier.takeStorageFailure(&storageError)) {
        return fail(storageError);
    }
    if (!db.commit()) {
        return fail(db.lastError().text());
    }
    result.ok = true;
    return result;
}

SyncStore::ApplyResult SyncStore::resolvePendingReferences()
{
    ApplyResult result;
    QSqlDatabase db = database();
    if (!db.isOpen()) {
        result.error = QStringLiteral("数据库未打开");
        return result;
    }
    // 平时没有待接回的引用：先看一眼，免得每一轮都开一个写事务。
    {
        QSqlQuery any(db);
        if (!any.exec(QStringLiteral("SELECT EXISTS (SELECT 1 FROM sync_pending_refs)")) || !any.next()) {
            result.error = any.lastError().text();
            return result;
        }
        if (any.value(0).toInt() == 0) {
            result.ok = true;
            return result;
        }
    }
    if (!db.transaction()) {
        result.error = db.lastError().text();
        return result;
    }
    const auto fail = [&db, &result](const QString& error) {
        db.rollback();
        ApplyResult failed;
        failed.error = error;
        qWarning() << "Failed to resolve pending sync references:" << error;
        result = failed;
        return result;
    };
    // 接回不是本机改动：和应用远端改动一样，期间让触发器跳过，复位也在同一个事务里。
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    Applier applier(db, deviceId(), &result);
    QString error;
    if (!applier.resolveAllPendingRefs(&error)) {
        return fail(error);
    }
    if (!query.exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1"))) {
        return fail(query.lastError().text());
    }
    QString storageError;
    if (applier.takeStorageFailure(&storageError)) {
        return fail(storageError);
    }
    if (!db.commit()) {
        return fail(db.lastError().text());
    }
    result.ok = true;
    return result;
}

// ── 传输记账 ──

bool SyncStore::hasPending() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT EXISTS (SELECT 1 FROM sync_outbox) "
                                     "OR EXISTS (SELECT 1 FROM sync_settings WHERE pending = 1)"))
        && query.next() && query.value(0).toInt() != 0;
}

int SyncStore::pendingCount() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT (SELECT COUNT(*) FROM sync_outbox) "
                                     "+ (SELECT COUNT(*) FROM sync_settings WHERE pending = 1)"))
            && query.next()
        ? query.value(0).toInt() : 0;
}

QString SyncStore::folderId() const
{
    return stateValue(database(), kFolderIdKey);
}

bool SyncStore::setFolderId(const QString& folderId)
{
    return folderId.isEmpty() ? removeStateValue(database(), kFolderIdKey)
                              : setStateValue(database(), kFolderIdKey, folderId);
}

QHash<QString, SyncPosition> SyncStore::peerCursors() const
{
    return statePositions(database(), kCursorPrefix);
}

bool SyncStore::setPeerCursor(const QString& device, const SyncPosition& position)
{
    return setStateValue(database(), kCursorPrefix + device, positionText(position));
}

bool SyncStore::replacePeerCursors(const QHash<QString, SyncPosition>& cursors)
{
    QSqlDatabase db = database();
    if (!db.transaction()) {
        return false;
    }
    QSqlQuery clear(db);
    clear.prepare(QStringLiteral("DELETE FROM sync_state WHERE substr(key, 1, :length) = :prefix"));
    clear.bindValue(QStringLiteral(":length"), kCursorPrefix.size());
    clear.bindValue(QStringLiteral(":prefix"), kCursorPrefix);
    bool ok = clear.exec();
    for (auto it = cursors.cbegin(); ok && it != cursors.cend(); ++it) {
        ok = setStateValue(db, kCursorPrefix + it.key(), positionText(it.value()));
    }
    if (!ok || !db.commit()) {
        db.rollback();
        return false;
    }
    return true;
}

std::optional<SyncStore::PeerObservation> SyncStore::peerObservation(const QString& device) const
{
    const QByteArray bytes = stateValue(database(), kPeerSeenPrefix + device).toUtf8();
    const QJsonDocument document = QJsonDocument::fromJson(bytes);
    if (!document.isObject()) {
        return std::nullopt;
    }
    const QJsonObject object = document.object();
    PeerObservation observation;
    // 观察记录会影响文件删除；缺字段、类型错误或负数一律重新保守观察，不把默认零值当作可信旧记录。
    const auto readInteger = [&object](const char* key, qint64* value) {
        const QJsonValue field = object.value(QLatin1String(key));
        if (!field.isDouble()) return false;
        *value = field.toInteger(-1);
        return *value >= 0 && field.toDouble() == double(*value);
    };
    if (!readInteger("epoch", &observation.epoch) || observation.epoch != epoch()
        || !object.value(QStringLiteral("fingerprint")).isString()
        || !readInteger("observed_at_ms", &observation.observedAtMs)
        || !readInteger("read_epoch", &observation.readPosition.epoch)
        || !readInteger("read_seq", &observation.readPosition.seq)) {
        return std::nullopt;
    }
    observation.fingerprint = object.value(QStringLiteral("fingerprint")).toString();
    return observation;
}

bool SyncStore::setPeerObservation(const QString& device, const PeerObservation& observation)
{
    // 现有键值表中的本机元数据，不进入同步文件；整条 JSON 一次写入，时间和进度不能只更新一半。
    const QJsonObject object{{QStringLiteral("epoch"), observation.epoch},
                             {QStringLiteral("fingerprint"), observation.fingerprint},
                             {QStringLiteral("observed_at_ms"), observation.observedAtMs},
                             {QStringLiteral("read_epoch"), observation.readPosition.epoch},
                             {QStringLiteral("read_seq"), observation.readPosition.seq}};
    return setStateValue(database(), kPeerSeenPrefix + device,
                         QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact)));
}

SyncPosition SyncStore::outboundPosition() const
{
    return parsePosition(stateValue(database(), kOutboundKey));
}

bool SyncStore::setOutboundPosition(const SyncPosition& position)
{
    return setStateValue(database(), kOutboundKey, positionText(position));
}

bool SyncStore::hasSnapshotPosition() const
{
    return parsePositionStrict(stateValue(database(), kSnapshotPositionKey), nullptr);
}

SyncPosition SyncStore::snapshotPosition() const
{
    return parsePosition(stateValue(database(), kSnapshotPositionKey));
}

bool SyncStore::setSnapshotPosition(const SyncPosition& position)
{
    return setStateValue(database(), kSnapshotPositionKey, positionText(position));
}

QHash<QString, SyncPosition> SyncStore::snapshotRequests() const
{
    return statePositions(database(), kRequestPrefix);
}

bool SyncStore::setSnapshotRequest(const QString& device, const SyncPosition& position)
{
    return setStateValue(database(), kRequestPrefix + device, positionText(position));
}

bool SyncStore::clearSnapshotRequest(const QString& device)
{
    return removeStateValue(database(), kRequestPrefix + device);
}

QDateTime SyncStore::lastSyncedAt() const
{
    return QDateTime::fromString(stateValue(database(), kLastSyncedKey), Qt::ISODateWithMs);
}

bool SyncStore::setLastSyncedAt(const QDateTime& time)
{
    return setStateValue(database(), kLastSyncedKey, time.toString(Qt::ISODateWithMs));
}

bool SyncStore::logFileProblem(const QString& device, const QString& file, const QString& detail)
{
    QSqlDatabase db = database();
    QSqlQuery query(db);
    // 表名留空、身份一栏放文件路径：这条记的是一个文件，不是某一条数据。
    query.prepare(QStringLiteral(
        "INSERT INTO sync_conflict_log (logged_at, kind, tbl, sync_id, record_label, lost_device, detail) "
        "VALUES (:at, 'file', '', :file, :label, :device, :detail)"));
    query.bindValue(QStringLiteral(":at"), QDateTime::currentDateTime().toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":file"), nonNull(file));
    query.bindValue(QStringLiteral(":label"), nonNull(file.section(QLatin1Char('/'), -1)));
    query.bindValue(QStringLiteral(":device"), nonNull(device));
    query.bindValue(QStringLiteral(":detail"), nonNull(truncated(detail)));
    if (!query.exec()) {
        qWarning() << "Failed to log sync file problem:" << query.lastError().text();
        return false;
    }
    QSqlQuery prune(db);
    prune.exec(QStringLiteral("DELETE FROM sync_conflict_log WHERE id <= "
                              "(SELECT MAX(id) - %1 FROM sync_conflict_log)").arg(kConflictLogLimit));
    return true;
}

QList<SyncStore::LogEntry> SyncStore::syncLog(int limit) const
{
    return readSyncLog(limit).value;
}

ServiceReadResult<QList<SyncStore::LogEntry>> SyncStore::readSyncLog(int limit) const
{
    ServiceReadResult<QList<LogEntry>> result;
    QList<LogEntry>& entries = result.value;
    QSqlQuery query(database());
    query.prepare(QStringLiteral(
        "SELECT id, logged_at, kind, tbl, record_label, field, lost_value, kept_value, lost_device, kept_device, "
        "detail FROM sync_conflict_log ORDER BY id DESC LIMIT :limit"));
    query.bindValue(QStringLiteral(":limit"), qMax(0, limit));
    if (!query.exec()) {
        qWarning() << "Failed to read sync log:" << query.lastError().text();
        result.error = ServiceReadError::Database;
        return result;
    }
    const QString me = deviceId();
    while (query.next()) {
        LogEntry entry;
        entry.id = query.value(0).toLongLong();
        entry.loggedAt = QDateTime::fromString(query.value(1).toString(), Qt::ISODate);
        entry.kind = query.value(2).toString();
        const QString table = query.value(3).toString();
        entry.recordLabel = query.value(4).toString();
        const QString field = query.value(5).toString();
        entry.lostValue = query.value(6).toString();
        entry.keptValue = query.value(7).toString();
        const QString lostDevice = query.value(8).toString();
        const QString keptDevice = query.value(9).toString();
        entry.detail = query.value(10).toString();
        entry.table = table;
        entry.field = field;
        // 表名、字段名换成给人看的名字。设置项不在同步表里：它的「字段」就是设置键。
        if (table == QLatin1String("settings")) {
            entry.tableLabel = QStringLiteral("设置");
            entry.fieldLabel = SyncSchema::settingLabel(field);
        } else if (const SyncSchema::Table* spec = SyncSchema::table(table)) {
            entry.tableLabel = spec->label;
            const SyncSchema::Field* column = SyncSchema::field(table, field);
            entry.fieldLabel = column ? column->label : field;
        }
        entry.lostHere = !lostDevice.isEmpty() && lostDevice == me;
        entry.keptHere = !keptDevice.isEmpty() && keptDevice == me;
        entries.append(entry);
    }
    return result;
}

int SyncStore::syncLogCount() const
{
    return readSyncLogCount().value;
}

ServiceReadResult<int> SyncStore::readSyncLogCount() const
{
    ServiceReadResult<int> result;
    QSqlQuery query(database());
    if (query.exec(QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log")) && query.next()) {
        result.value = query.value(0).toInt();
    } else {
        result.error = ServiceReadError::Database;
    }
    return result;
}

qint64 SyncStore::latestSyncLogId() const
{
    QSqlQuery query(database());
    return query.exec(QStringLiteral("SELECT COALESCE(MAX(id), 0) FROM sync_conflict_log")) && query.next()
        ? query.value(0).toLongLong() : 0;
}
