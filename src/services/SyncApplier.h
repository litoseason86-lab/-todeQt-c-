// 同步应用的私有状态与声明；拆出后由 SyncStore 和应用实现共用，不暴露到其它层。
#ifndef SYNCAPPLIER_H
#define SYNCAPPLIER_H

#include "SyncStore.h"
#include "SyncSchema.h"

#include <QMap>
#include <QSet>

class QSqlError;
class QSqlQuery;

namespace SyncStoreDetail {

extern const int kConflictLogLimit;

qsizetype tableOrder(const QString& table);
QStringList columnsOf(const SyncSchema::Table& table);
QString truncated(const QString& text);
QString nonNull(const QString& text);

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

// 应用一批远端改动的全部状态。只活在一次增量应用或快照替换的事务里。
class Applier
{
public:
    Applier(QSqlDatabase db, QString me, SyncStore::ApplyResult* result);

    // 应用一条记录。坏数据只撤销当前保存点；存储失败须由调用方取出后放弃整批，留待重试。
    bool apply(const SyncRecord& record, QString* error);
    // 应用一个设置项：版本新的赢；变了的交给调用方写回 AppSettings。
    bool applySetting(const SyncSettingRecord& setting, QString* error);

    // 用快照整体替换（见 SyncStore::replaceWithSnapshot）。第一步删掉快照里没有的本机记录、清空同步状态；
    // 之后逐条调用 overwriteFromSnapshot 落地快照记录（调用方给每条套保存点）。
    bool dropRecordsMissingFrom(const SyncBatch& snapshot, QString* error);
    bool overwriteFromSnapshot(const SyncRecord& record, QString* error);
    bool replaceSettings(const QList<SyncSettingRecord>& settings, QString* error);
    bool mergeRemoteClock(QString* error);
    bool logSkipped(const SyncRecord& record, const QString& reason);
    bool takeStorageFailure(QString* error);

    // 全部记录应用完之后的两步收尾，都在同一个事务里：
    // 1. 科目落最终名。应用时改名的科目先用临时名，等整批落地再逐个换回，这样两个科目互换名字时
    //    不会在中途被误判成撞名；真撞了名，就按确定规则合并（或给预置科目加后缀）。
    bool finalizeCategoryNames(QString* error);
    // 2. 本批动过的日期如果出现重复或非正的任务排序号，按确定规则重排。重排作为本机改动照常发出，
    //    不走 v12 迁移那条修复路径——那条路径每次都会生成一份迁移快照（sol6 审查第 7 条）。
    bool normalizeTaskOrders(QString* error);
    // 3. 倒计时的排序号撞了（两台设备各自新建，都排在末尾）：按「排序号、创建时间、sync_id」重排，
    //    同样作为本机改动发出。两台设备拿到同样的倒计时集合后算出同样的顺序。
    bool normalizeCountdownOrders(QString* error);
    // 4. 备忘录只在同一科目内重排，未分类也是一组；内容时间与顺序号无关。
    bool normalizeMemoOrders(QString* error);

    // 把目标已经在本机的「待接回引用」全部接上（调用方保证触发器跳过：接回不是本机改动）。
    // 目标可能不是从同步收到的：例行实例被收回后，本机当天重新启用、自己又生成了同一个身份的实例；
    // 或者目标同步到达时本机已经有这一行（走的是合并而不是插入）。只靠「插入时接回」的话，
    // 这种引用会一直空着，而另一台挂着它，版本又相同，之后谁也不会纠正谁。
    bool resolveAllPendingRefs(QString* error);

private:
    bool applyDeletion(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row,
                       const Tombstone& local, QString* error);
    bool applyToDeleted(const SyncSchema::Table& table, const SyncRecord& record, const Tombstone& local,
                        bool* resurrected, QString* error);
    bool insertRow(const SyncSchema::Table& table, const SyncRecord& record, QString* error);
    bool mergeRow(const SyncSchema::Table& table, const SyncRecord& record, const LocalRow& row, QString* error);
    QString contentTimestamp(const SyncSchema::Table& table, const SyncRecord& record,
                             const QHash<QString, LocalVersion>& local = {}) const;
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
    QVariant resolveLocal(const QString& table, const QVariant& syncId, bool* dangling, bool* permanentlyDeleted = nullptr);
    // 待解析的引用（见 SyncSchema 里 sync_pending_refs 的说明）。收下一个引用列之后调用：
    // 目标找不到、又不是被永久删除（用户删除或合并）的，记下来；找得到或已永久删除的，清掉旧记录。
    bool noteReference(const QString& table, const QString& syncId, const SyncSchema::Field& field,
                       const SyncFieldValue& incoming, bool dangling, QString* error);
    // 一条记录落地之后调用：之前指向它、只能先置空的引用，现在接回来。
    bool resolvePendingRefsTo(const QString& targetTable, const QString& targetSyncId, qint64 localId,
                              QString* error);
    // 对方的设置值进库了、还没写回本机：在同一个事务里记下（见 SyncStore::pendingSettingWriteBacks）。
    bool markSettingWriteBack(const QString& key, const QString& kind, QString* error);
    // 对方「收回」了一条任务、本机删它之前调用：指向它的引用随后会被外键置空（应用远端改动时触发器跳过，
    // 不记版本），先把它们记成「待接回」。发起收回的那台对这些引用也是「待接回」（它收到时目标已经没了），
    // 两边记得一样，实例补回来时两边一起接上；只记一边的话，接回之后两边就一边挂着、一边空着。
    bool notePendingRefsToReclaimed(const QString& targetSyncId, qint64 localId, QString* error);

    bool writeTombstone(const QString& table, const QString& syncId, const Tombstone& tombstone, QString* error);
    bool writeVersion(const QString& table, const QString& syncId, const QString& field,
                      const SyncFieldValue& value, QString* error);
    // 记录已删除：清掉它的字段版本；dequeue 为真时连待发送也一并清掉（本机的删除记录不用再发的时候）。
    bool clearLocalSyncState(const QString& table, const QString& syncId, bool dequeue, QString* error);
    bool exec(QSqlQuery& query, QString* error);
    bool exec(QSqlQuery& query, const QString& sql, QString* error);
    bool prepare(QSqlQuery& query, const QString& sql);
    bool next(QSqlQuery& query);
    void recordSqlError(const QSqlError& sqlError, QString* error);

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
    bool advanceClock(qint64 afterTime, SyncVersion* version, QString* error);
    bool republish(const QString& table, const QString& syncId, const QString& field, qint64 afterTime, QString* error);
    // 临时放开触发器：排序归一、预置科目加后缀是本机改动，要由触发器照常记版本、入队。
    bool setApplying(bool applying, QString* error);

    QSqlDatabase m_db;
    QString m_me;
    SyncStore::ApplyResult* m_result;
    qint64 m_maxSeenTime = 0;
    bool m_warnedFutureClock = false;
    // 查询准备、执行、取行和辅助日志都可能先出错；后续 SQL 不得覆盖本条最初的存储错误。
    bool m_storageFailure = false;
    QString m_storageError;
    // 待落最终名的科目：sync_id → (本机编号, 最终名)。按 sync_id 排序处理，所有设备的处理顺序一致。
    QMap<QString, QPair<qint64, QString>> m_pendingCategoryNames;
    // 本批动过的任务日期（改前与改后），收尾时检查这些日期的排序号不变量。
    QSet<QString> m_touchedTaskDates;
};

} // namespace SyncStoreDetail

#endif // SYNCAPPLIER_H
