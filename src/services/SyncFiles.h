#ifndef SYNCFILES_H
#define SYNCFILES_H

#include "SyncRecord.h"

#include <QByteArray>
#include <QHash>
#include <QString>
#include <QStringList>

// 云盘同步文件夹里的文件：放在哪、叫什么、里面写什么（050 阶段 3）。
// 这里只做「文件名 ↔ 位置」「字节 ↔ 结构」的互转，不碰磁盘：读写在 SyncWorker，什么时候写在 SyncEngine。
//
// 文件夹布局。每台设备只写自己的子目录，所以不会有两台设备同时改同一个文件，iCloud 也就不会生成「冲突副本」：
//   番茄Todo同步/
//     番茄Todo同步.json                      标记文件：格式版本、文件夹身份、哪台设备建的
//     devices/<设备标识>/
//       changes/<纪元>-<序号>.json            一批改动。只新增、不改写
//       snapshot-<纪元>-<序号>.json           全量快照，含这台设备写到第 <序号> 批为止的全部改动
//       cursor.json                           这台设备已经应用到别人第几批；别人据此删掉双方都用过的旧文件
//
// 纪元和序号写进文件名，是为了不下载就能判断要不要读：049 实测，刚从云端同步来的文件每读一个约要 1 秒。
namespace SyncFiles {

// 外层格式的版本（四种文件共用）。里面装的改动批次另有自己的版本（SyncJson::kFormatVersion）。
constexpr int kFormatVersion = 1;

enum class ParseStatus {
    Ok,
    // 内容坏了：不是 JSON、缺字段，或者内容和文件名、所在目录对不上。
    // 文件都是写完整后一次性换上去的，读完整了还是坏的，重读也不会变好：调用方跳过它、记日志，
    // 再请写它的设备补一份快照，把这批里的改动带回来。
    Corrupt,
    // 更新版本的应用写的，本机读不懂。对方的数据是好的，不能跳过（跳过就丢了），停在这里，等本机更新应用。
    NewerFormat,
};

// ── 名字与路径（相对同步文件夹的根） ──

QString defaultFolderName();
QString markerFileName();
QString devicesDirectory();
QString deviceDirectory(const QString& device);
QString changesDirectory(const QString& device);
QString cursorFileName();
QString changeFileName(const SyncPosition& position);
QString snapshotFileName(const SyncPosition& position);

// 从文件名读出位置。不是本应用写的名字一律返回 false：写到一半的临时文件、iCloud 的占位文件、
// 「冲突副本」（名字后面带「 2」）、系统的 .DS_Store 都会被这一步挡掉。
bool parseChangeFileName(const QString& name, SyncPosition* position);
bool parseSnapshotFileName(const QString& name, SyncPosition* position);
// 设备标识是 32 位小写十六进制（SyncSchema 建库时随机生成）。devices 下别的名字（用户放进去的东西、
// 系统文件）都不当成设备，也防止奇怪的名字拼进路径里。
bool isDeviceId(const QString& name);
// 本机写文件时留下的临时文件：QSaveFile 先在同一目录写「<文件名>.<6 位随机字符>」，写完再改名换上。
// 应用在这中间被结束，临时文件就留下来了，清理时只删本机自己目录里的这种文件。
bool isTemporaryFileName(const QString& name);
// 除了隐藏文件（.DS_Store 这类）之外什么都没有。Mac 只在这种文件夹里新建同步，免得覆盖别人的东西。
bool isEffectivelyEmpty(const QStringList& entries);
// 选中的文件夹里没有标记文件时，按里面有什么推测选错了哪一层，给出下一步该怎么做（049 里第一次就选成了子文件夹）。
QString wrongFolderHint(const QString& folderName, const QStringList& entries);

// ── 四种文件的内容 ──

// 标记文件。
struct Marker {
    // 文件夹身份：新建时生成。文件夹删掉重建后身份就变了，设备据此知道这是另一个文件夹，要重新加入。
    QString folderId;
    // 建文件夹的设备。第一次加入的设备以它的快照为准（你定了：首次加入完全以 Mac 为准）。
    QString createdBy;
    // 只给人看。
    QString createdAt;
};
QByteArray encodeMarker(const Marker& marker);
ParseStatus decodeMarker(const QByteArray& bytes, Marker* marker, QString* error);

// 一批改动。batch.device、batch.epoch 是写它的设备和纪元，必须和所在目录、文件名一致。
struct ChangeFile {
    qint64 seq = 0;
    // 写出时刻（UTC 毫秒），排查延迟用。
    qint64 writtenAtMs = 0;
    SyncBatch batch;
};
QByteArray encodeChanges(const ChangeFile& file);
// expectedDevice、expected 来自所在目录和文件名；内容对不上的按坏文件处理，不猜哪个是对的。
ParseStatus decodeChanges(const QByteArray& bytes, const QString& expectedDevice, const SyncPosition& expected,
                          ChangeFile* file, QString* error);

// 全量快照。
struct SnapshotFile {
    // 覆盖到写它的设备第几批改动：从这份快照起步的设备，接着读第 coveredSeq + 1 批。
    qint64 coveredSeq = 0;
    qint64 writtenAtMs = 0;
    // 写快照那一刻，写它的设备已经应用到别的设备第几批。从这份快照起步的设备据此接着读别人的改动，
    // 不用从头再读一遍。
    QHash<QString, SyncPosition> applied;
    SyncBatch batch;
};
QByteArray encodeSnapshot(const SnapshotFile& file);
ParseStatus decodeSnapshot(const QByteArray& bytes, const QString& expectedDevice, const SyncPosition& expected,
                           SnapshotFile* file, QString* error);

// 游标文件：这台设备读别人读到了哪里。
struct CursorFile {
    QString device;
    qint64 epoch = 0;
    // 写出时刻（UTC 毫秒）。很久没更新的设备当作不再使用，不再为它保留旧文件。
    qint64 writtenAtMs = 0;
    // 对方设备 → 已经应用到它第几批。
    QHash<QString, SyncPosition> applied;
    // 对方设备 → 请它写一份至少覆盖到这一批的快照：读到它的坏文件、或者它的某批文件一直没到时用。
    QHash<QString, SyncPosition> snapshotRequests;
};
QByteArray encodeCursor(const CursorFile& file);
ParseStatus decodeCursor(const QByteArray& bytes, const QString& expectedDevice, CursorFile* file, QString* error);

} // namespace SyncFiles

#endif // SYNCFILES_H
