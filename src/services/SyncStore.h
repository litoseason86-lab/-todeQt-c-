#ifndef SYNCSTORE_H
#define SYNCSTORE_H

#include "SyncRecord.h"

#include <QDateTime>
#include <QHash>
#include <QList>
#include <QSet>
#include <QSqlDatabase>
#include <QString>

// 设备间同步的本地数据层（050 阶段 2）：只和数据库打交道，不关心改动怎么在设备之间传递。
// 读出本机待发送的改动、确认已经发出，以及把对方的一批改动合并进本机库，都在这里。
//
// 合并规则（计划 050「合并规则」一节）：
// - 按字段比较版本，新的赢；两边改的是不同字段就都保留。
// - 删除优先：删除记录永远赢，之后收到的修改一律忽略并记日志。例外是例行的「收回」：
//   之后重新生成的实例可以取代它（见 SyncSchema 里 reclaim 的说明）。
// - 绝不因为一条数据让整批失败：每条记录各自一个保存点，失败只回滚这一条、记日志、继续下一条。
// - 引用的目标已被删除，按本机删除该目标时的做法处理（任务的科目置空并清掉科目名，专注记录的任务置空……）。
class SyncStore
{
public:
    // connectionName 为空时用应用主连接（DatabaseManager）；测试用它同时打开两台「设备」的库。
    explicit SyncStore(const QString& connectionName = QString());

    QString deviceId() const;
    qint64 epoch() const;

    // 本机待发送的改动，按表的依赖顺序（科目 → 例行 → 任务 → 专注 → 休息）、同表内按改动先后排列。
    SyncBatch collectPending() const;
    // 这批改动已经写进同步文件：队列里期间没再改过的记录出队，字段的「待发送」标记清掉。
    // 期间又改过的保留，并把 base 更新成刚发出的那一版（对方马上就会见到它）。
    bool acknowledge(const SyncBatch& batch);

    struct ApplyResult {
        bool ok = false;
        QString error;
        // 本批真的改动了哪些表，界面据此只刷新变了的模型，不整库重载。
        QSet<QString> changedTables;
        // 本机因远端删除而删掉的任务编号：提交成功后逐个发 taskDeleted，计时器据此解绑。
        QList<int> deletedTaskIds;
        // 本批改变了的设置项（键 → 新值），由调用方写回 AppSettings。
        QHash<QString, QString> changedSettings;
        int conflictsLogged = 0;
        int skippedRecords = 0;
    };
    // 在一个事务里应用对方的一批改动。纪元与本机不同的批次整批拒绝：
    // 纪元更高要走快照替换（全局回滚），更低的是回滚之前的旧改动，不能再合进来。
    ApplyResult applyRemote(const SyncBatch& batch);

    // 设置项（第一期只有 logic/dayStartHour；值本身由 AppSettings 存在 QSettings 里，这里只记同步看到的值与版本）。
    // 本机改了设置之后调用：值与上次记下的不同，就记一个新版本、等着发出。
    // isDefault 表示这是出厂默认值：第一次记下默认值时用最小版本，两台设备各自的默认值不会盖掉对方改过的设置。
    bool recordLocalSetting(const QString& key, const QString& value, bool isDefault);
    // 同步记下的值；从没记过时返回空的 QString。
    QString syncedSetting(const QString& key) const;

    // ── 全量快照：首次加入与全局回滚（计划 050「首次加入与恢复备份」） ──
    // 本机全部已发布的记录（带字段版本）、全部删除记录与全部设置。给新加入的设备起步用；
    // 本机恢复备份做全局回滚之后，另一台也靠它整体换成这份状态。
    SyncBatch exportSnapshot() const;
    // 快照已经写进同步文件：待发送队列里快照已经带上的改动出队（与 acknowledge 相同），并清掉「需要发布快照」标记。
    bool markSnapshotPublished(const SyncBatch& snapshot);
    // 用快照整体替换本机的同步数据，并采用快照的纪元：首次加入（你定了以 Mac 为准）、另一台做了全局回滚时用。
    // 快照里没有的记录按本机删除的做法删掉（预置科目例外，它们不能删）；快照里的记录原样落地，
    // 已有的保留本机编号，课表、知识缺口这些不同步的表里的引用不会断。本机进行中的专注不受影响。
    // 调用前由调用方先做自动备份：被换掉的本机数据只能从那份备份里找回。
    ApplyResult replaceWithSnapshot(const SyncBatch& snapshot);
    // 本机恢复了备份（全局回滚）之后调用：纪元在恢复前与备份里两者较大的基础上加一；设备标识改回恢复前的
    // （备份可能来自另一台设备，两台共用一个标识会把合并搅乱）；清空待发送；置「需要发布快照」。
    bool beginEpochAfterRestore(qint64 previousEpoch, const QString& previousDeviceId);
    bool needsSnapshot() const;

    // ── 传输记账（050 阶段 3）──
    // 云盘传输读到哪、写到哪，都记在 sync_state 里，和数据放在同一个库：恢复备份时它们跟着数据一起回到
    // 备份那一刻，「应用到对方第几批」就不会和库里实际有的数据对不上。传输层（SyncEngine）调用。
    // 每一步都只在对应的数据已经提交之后再记：先记后提交的话，中途失败就会漏掉一批；
    // 反过来最多是重读一批，而重复应用不改变任何东西。

    // 有没有等着发出的改动（待发送队列里的记录，或待发送的设置项）。
    bool hasPending() const;
    int pendingCount() const;
    // 本机加入的同步文件夹（标记文件里的文件夹身份）。没加入过时为空。
    QString folderId() const;
    bool setFolderId(const QString& folderId);
    // 本机已经应用到各台设备第几批。
    QHash<QString, SyncPosition> peerCursors() const;
    bool setPeerCursor(const QString& device, const SyncPosition& position);
    // 整体换掉：首次加入、采用了对方的新纪元之后，按快照里记的进度重新起步。
    bool replacePeerCursors(const QHash<QString, SyncPosition>& cursors);
    // 本机写到第几批改动。
    SyncPosition outboundPosition() const;
    bool setOutboundPosition(const SyncPosition& position);
    // 本机最近一份快照覆盖到第几批。只删它覆盖到的旧改动文件：之后才加入、或落后太久的设备还能从快照起步。
    SyncPosition snapshotPosition() const;
    bool setSnapshotPosition(const SyncPosition& position);
    // 本机请别的设备补一份至少覆盖到这一批的快照：读到它的坏文件，或者它的某一批一直没传到。
    QHash<QString, SyncPosition> snapshotRequests() const;
    bool setSnapshotRequest(const QString& device, const SyncPosition& position);
    bool clearSnapshotRequest(const QString& device);
    // 上一次完整同步完的时刻（给人看的状态）。从没同步过时无效。
    QDateTime lastSyncedAt() const;
    bool setLastSyncedAt(const QDateTime& time);
    // 文件层面的问题（坏文件、读不懂的新版本文件）记进同步日志，和冲突记录放在一起，设置页可以查。
    bool logFileProblem(const QString& device, const QString& file, const QString& detail);

private:
    QSqlDatabase database() const;

    QString m_connectionName;
};

#endif // SYNCSTORE_H
