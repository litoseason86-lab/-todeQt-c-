#ifndef SYNCWORKER_H
#define SYNCWORKER_H

#include "SyncFiles.h"
#include "SyncFolder.h"

#include <QHash>
#include <QList>
#include <QString>

#include <memory>

// 同步文件夹上的文件操作（050 阶段 3），在同步的工作线程里执行。
// 只管文件：列目录、读写、解析，不碰数据库。SQLite 的连接不跨线程，库只在主线程里用：
// SyncEngine 先在主线程把要写的东西从库里取出来交给这里，这里读到、解析好的改动再交回主线程去应用。
// SyncEngine 把操作排成一队，同一时刻只有一个在跑，这里不加锁。
class SyncWorker
{
public:
    // folder 的构造要轻（只记下路径或书签），真正取得访问权在 open() 里、在工作线程做。
    explicit SyncWorker(std::unique_ptr<SyncFolder> folder);

    // 放弃正在等待的读写。可以从别的线程调用：退出时工作线程可能正卡在等 iCloud 下载。
    void cancelPendingIo();

    // ── 每一轮开始：打开文件夹、读标记文件 ──
    enum class MarkerState {
        Present,
        // 没有标记文件：还没建过同步文件夹，或者选错了文件夹。
        Missing,
        Corrupt,
        // 更新版本的应用建的文件夹，本机读不懂。
        Newer,
    };
    struct OpenResult {
        SyncFolder::Error error;
        MarkerState markerState = MarkerState::Missing;
        SyncFiles::Marker marker;
        QString markerError;
        // 根目录不存在或者只有隐藏文件：Mac 可以在这里新建同步文件夹，不会覆盖别人的东西。
        bool folderEmpty = false;
        // 没有标记文件时给人看的提示：选错了哪一层、下一步怎么做。
        QString hint;
        // 上一轮写出的文件往 iCloud 上传时出的错（例如 iCloud 空间已满）。
        QString uploadProblem;
    };
    OpenResult open(const QString& lastWrittenPath);
    SyncFolder::Error createMarker(const SyncFiles::Marker& marker);

    // ── 写 ──
    struct WriteResult {
        SyncFolder::Error error;
        SyncPosition position;
        QString path;
    };
    // 写一批改动。序号取「本机记的最后一批」与「目录里已有的最大一批」中较大的再加一：
    // 应用在写完文件、还没来得及记下序号时被结束，下次也不会重用这个号去覆盖对方可能已经读过的文件。
    WriteResult writeChanges(const SyncBatch& batch, qint64 lastSeq, qint64 writtenAtMs);
    // 退出前最后写一批：先确认标记文件还在、还是同一个文件夹，免得往被删掉的文件夹里写出一个没有标记的空壳。
    WriteResult writeChangesIfFolderMatches(const QString& folderId, const SyncBatch& batch, qint64 lastSeq,
                                            qint64 writtenAtMs);
    WriteResult writeSnapshot(const SyncFiles::SnapshotFile& snapshot);
    SyncFolder::Error writeCursor(const SyncFiles::CursorFile& cursor);

    // ── 首次加入：找起步用的快照 ──
    struct SnapshotFetch {
        SyncFolder::Error error;
        bool found = false;
        QString device;
        SyncPosition position;
        SyncFiles::ParseStatus status = SyncFiles::ParseStatus::Ok;
        QString parseError;
        SyncFiles::SnapshotFile snapshot;
    };
    // 纪元最高的快照为准；纪元相同时优先建文件夹的设备（你定了首次加入以 Mac 为准），再按设备标识排，
    // 所有设备挑出同一份。
    SnapshotFetch fetchJoinSnapshot(const QString& me, const QString& preferredDevice);

    // ── 扫描对方写来的改动 ──
    struct ScanRequest {
        QString me;
        qint64 epoch = 0;
        // 本机已经应用到各台设备第几批（只有纪元与本机相同的才算数）。
        QHash<QString, SyncPosition> cursors;
        // 本机请各台设备补的快照（至少覆盖到哪一批）。对方的快照覆盖到了，就读来合并。
        QHash<QString, SyncPosition> requests;
        // 这一轮最多读多少个文件：刚同步来的文件每个约 1 秒，读不完的留到紧接着的下一轮。
        int maxFiles = 30;
        // 落后对方这么多批、而它的快照正好覆盖得到时，合并快照，不再一个个下载改动文件。
        int catchUpViaSnapshot = 30;
    };
    struct IncomingFile {
        enum class Kind {
            Batch,
            // 内容坏了（见 SyncFiles::ParseStatus::Corrupt）。
            Corrupt,
            // 更新版本写的，本机读不懂。
            Newer,
        };
        Kind kind = Kind::Batch;
        qint64 seq = 0;
        QString path;
        QString error;
        SyncBatch batch;
    };
    struct PeerScan {
        QString device;
        // 要先合并的快照：对方的旧改动已经清理掉了（本机落后太久）、本机落后太多批，
        // 或者本机请它补的快照到了。合并快照和逐批应用结果相同：记录都带着字段版本，重复的不改变任何东西。
        bool hasSnapshot = false;
        // 读了哪一份快照（读成功与否都记下）。
        SyncPosition snapshotPosition;
        SyncFiles::SnapshotFile snapshot;
        // 需要快照却读不出来（坏了、版本更新）。
        SyncFiles::ParseStatus snapshotStatus = SyncFiles::ParseStatus::Ok;
        QString snapshotError;
        // 从游标（或快照）之后连续的一段，按序号排好。
        QList<IncomingFile> files;
        // 这一批还没到、它后面的倒先到了（iCloud 不保证按写出的顺序送到）。0 表示没在等。
        qint64 waitingFor = 0;
        // 读某个文件失败：停在它前面，下一轮再试。
        SyncFolder::Error readError;
    };
    // 有设备的纪元比本机高：它恢复了备份（全局回滚），本机要整体换成它的快照。
    struct Adoption {
        bool needed = false;
        // 新纪元的快照已经到了、读出来了。还没到时等着，这一轮什么都不应用。
        bool ready = false;
        QString device;
        SyncPosition position;
        SyncFiles::ParseStatus status = SyncFiles::ParseStatus::Ok;
        QString error;
        SyncFiles::SnapshotFile snapshot;
    };
    struct ScanResult {
        SyncFolder::Error error;
        QList<PeerScan> peers;
        Adoption adoption;
        // 这一轮读满了上限，还有没读的。
        bool more = false;
    };
    ScanResult scan(const ScanRequest& request);

    // ── 维护：看各设备读到了哪里，决定写不写快照、删哪些旧文件 ──
    struct PeerCursor {
        QString device;
        bool present = false;
        SyncFiles::ParseStatus status = SyncFiles::ParseStatus::Ok;
        SyncFiles::CursorFile cursor;
    };
    struct Survey {
        SyncFolder::Error error;
        QList<PeerCursor> peers;
        // 本机目录里现有的改动文件与快照（所有纪元）。
        QList<SyncPosition> ownChanges;
        QList<SyncPosition> ownSnapshots;
    };
    Survey survey(const QString& me);
    struct CleanupResult {
        SyncFolder::Error error;
        int removed = 0;
    };
    // 只动本机自己的目录：删掉旧纪元的全部文件、本纪元里序号不超过 deleteUpToSeq 的改动文件、
    // keepSnapshot 以外的快照，以及写到一半留下的临时文件。别的设备的文件由它自己清理。
    CleanupResult cleanup(const QString& me, qint64 epoch, qint64 deleteUpToSeq, const SyncPosition& keepSnapshot,
                          bool keepAnySnapshot);

private:
    // 一台设备目录里现有的改动文件与快照（所有纪元）。目录不存在当作什么都没有。
    struct DeviceFiles {
        QList<SyncPosition> changes;
        QList<SyncPosition> snapshots;
        // 所有文件里最高的纪元；什么都没有时为 -1。
        qint64 latestEpoch = -1;
    };
    DeviceFiles inspect(const QString& device, SyncFolder::Error* error);
    // 设备目录下最新的快照（纪元最大、同纪元序号最大）。没有时返回 false。
    bool latestSnapshot(const QString& device, SyncPosition* position, SyncFolder::Error* error);
    // 读一份快照并解析。
    SyncFiles::ParseStatus readSnapshot(const QString& device, const SyncPosition& position,
                                        SyncFiles::SnapshotFile* snapshot, QString* parseError,
                                        SyncFolder::Error* error);
    // 某台设备在某个纪元里已经写出的改动序号（升序）。目录不存在当作一批都没有。
    QList<qint64> changeSequences(const QString& device, qint64 epoch, SyncFolder::Error* error);
    // devices 下的设备（合法的设备标识，不含本机），按标识排序：所有设备以同样的顺序处理。
    QStringList peerDevices(const QString& me, SyncFolder::Error* error);

    std::unique_ptr<SyncFolder> m_folder;
};

#endif // SYNCWORKER_H
