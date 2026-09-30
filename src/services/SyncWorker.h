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
        // 这一轮最多读多少个文件：刚同步来的文件每个约 1 秒，读不完的留到紧接着的下一轮。
        int maxFiles = 30;
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
        // 从游标之后连续的一段，按序号排好。
        QList<IncomingFile> files;
        // 这一批还没到、它后面的倒先到了（iCloud 不保证按写出的顺序送到）。0 表示没在等。
        qint64 waitingFor = 0;
        // 读某个文件失败：停在它前面，下一轮再试。
        SyncFolder::Error readError;
    };
    struct ScanResult {
        SyncFolder::Error error;
        QList<PeerScan> peers;
        // 这一轮读满了上限，还有没读的。
        bool more = false;
    };
    ScanResult scan(const ScanRequest& request);

private:
    // 设备目录下最新的快照（纪元最大、同纪元序号最大）。没有时返回 false。
    bool latestSnapshot(const QString& device, SyncPosition* position, SyncFolder::Error* error);
    // 某台设备在某个纪元里已经写出的改动序号（升序）。目录不存在当作一批都没有。
    QList<qint64> changeSequences(const QString& device, qint64 epoch, SyncFolder::Error* error);
    // devices 下的设备（合法的设备标识，不含本机），按标识排序：所有设备以同样的顺序处理。
    QStringList peerDevices(const QString& me, SyncFolder::Error* error);

    std::unique_ptr<SyncFolder> m_folder;
};

#endif // SYNCWORKER_H
