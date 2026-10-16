#include "SyncWorker.h"

#include <algorithm>
#include <functional>
#include <utility>

namespace {

bool isMissing(const SyncFolder::Error& error)
{
    return error.kind == SyncFolder::ErrorKind::NotFound;
}

QString joinPath(const QString& directory, const QString& name)
{
    return directory + QLatin1Char('/') + name;
}

// 发送与接收共用同一字节预算；先拒绝超限内容，避免本机确认发布后对端却一律拒读。
SyncFolder::Error writeWithinBudget(SyncFolder& folder, const QString& path, const QByteArray& bytes)
{
    const qint64 maxBytes = SyncFiles::maxBudgetForPath(path);
    if (maxBytes <= 0) {
        return {SyncFolder::ErrorKind::Io, QStringLiteral("不支持的同步文件路径：%1").arg(path)};
    }
    if (bytes.size() > maxBytes) {
        return {SyncFolder::ErrorKind::Io,
                QStringLiteral("同步文件大小超出预算上限，未写出：%1（%2 > %3 字节）")
                    .arg(path).arg(bytes.size()).arg(maxBytes)};
    }
    SyncFolder::Error error;
    if (!folder.write(path, bytes, &error) && error.ok()) {
        return {SyncFolder::ErrorKind::Io, QStringLiteral("写入同步文件失败：%1").arg(path)};
    }
    return error;
}

// 包在真正的文件夹外面，每做完一次文件操作（不论成败）就把计数加一。
// 同步引擎在主线程里看这个数有没有在涨，来区分「慢，但一直在做」和「卡住了」。
class ProgressFolder final : public SyncFolder
{
public:
    ProgressFolder(std::unique_ptr<SyncFolder> inner, std::shared_ptr<std::atomic<quint64>> progress)
        : m_inner(std::move(inner)), m_progress(std::move(progress))
    {
    }

    bool open(Error* error) override { return counted(m_inner->open(error)); }
    QString name() const override { return m_inner->name(); }
    QString displayPath() const override { return m_inner->displayPath(); }
    QStringList list(const QString& relativeDir, Error* error) override
    {
        QStringList names = m_inner->list(relativeDir, error);
        ++*m_progress;
        return names;
    }
    bool read(const QString& relativePath, QByteArray* data, Error* error) override
    {
        return counted(m_inner->read(relativePath, data, error));
    }
    bool write(const QString& relativePath, const QByteArray& data, Error* error) override
    {
        return counted(m_inner->write(relativePath, data, error));
    }
    bool remove(const QString& relativePath, Error* error) override
    {
        return counted(m_inner->remove(relativePath, error));
    }
    QString uploadProblem(const QString& relativePath) override
    {
        QString problem = m_inner->uploadProblem(relativePath);
        ++*m_progress;
        return problem;
    }
    void cancelPendingIo() override { m_inner->cancelPendingIo(); }

private:
    bool counted(bool result)
    {
        ++*m_progress;
        return result;
    }

    std::unique_ptr<SyncFolder> m_inner;
    std::shared_ptr<std::atomic<quint64>> m_progress;
};

} // namespace

SyncWorker::SyncWorker(std::unique_ptr<SyncFolder> folder)
    : m_progress(std::make_shared<std::atomic<quint64>>(0))
    , m_folder(std::make_unique<ProgressFolder>(std::move(folder), m_progress))
{
}

void SyncWorker::cancelPendingIo()
{
    m_folder->cancelPendingIo();
}

quint64 SyncWorker::progress() const
{
    return m_progress->load();
}

SyncWorker::OpenResult SyncWorker::open(const QString& lastWrittenPath)
{
    OpenResult result;
    if (!m_folder->open(&result.error)) {
        return result;
    }
    QByteArray bytes;
    SyncFolder::Error readError;
    if (m_folder->read(SyncFiles::markerFileName(), &bytes, &readError)) {
        if (bytes.size() > SyncFiles::kMaxMarkerBytes) {
            result.markerState = MarkerState::Corrupt;
            result.markerError = QStringLiteral("标记文件大小超出预算上限");
        } else {
            const SyncFiles::ParseStatus status = SyncFiles::decodeMarker(bytes, &result.marker, &result.markerError);
            result.markerState = status == SyncFiles::ParseStatus::Ok            ? MarkerState::Present
                               : status == SyncFiles::ParseStatus::NewerFormat ? MarkerState::Newer
                                                                                 : MarkerState::Corrupt;
        }
    } else if (isMissing(readError)) {
        result.markerState = MarkerState::Missing;
        // 根目录本身不存在（Mac 还没建过）也走这里：列出来是空的，可以新建。
        SyncFolder::Error listError;
        const QStringList entries = m_folder->list(QString(), &listError);
        if (!listError.ok() && !isMissing(listError)) {
            result.error = listError;
            return result;
        }
        result.folderEmpty = SyncFiles::isEffectivelyEmpty(entries);
        result.hint = SyncFiles::wrongFolderHint(m_folder->name(), entries);
    } else {
        result.error = readError;
        return result;
    }
    if (!lastWrittenPath.isEmpty()) {
        result.uploadProblem = m_folder->uploadProblem(lastWrittenPath);
    }
    return result;
}

SyncFolder::Error SyncWorker::createMarker(const SyncFiles::Marker& marker)
{
    return writeWithinBudget(*m_folder, SyncFiles::markerFileName(), SyncFiles::encodeMarker(marker));
}

SyncWorker::WriteResult SyncWorker::writeChanges(const SyncBatch& batch, qint64 lastSeq, qint64 writtenAtMs)
{
    WriteResult result;
    const QList<qint64> existing = changeSequences(batch.device, batch.epoch, &result.error);
    if (!result.error.ok()) {
        return result;
    }
    const qint64 seq = std::max(lastSeq, existing.isEmpty() ? 0 : existing.last()) + 1;
    result.position = {batch.epoch, seq};
    result.path = joinPath(SyncFiles::changesDirectory(batch.device), SyncFiles::changeFileName(result.position));
    result.error = writeWithinBudget(*m_folder, result.path, SyncFiles::encodeChanges({seq, writtenAtMs, batch}));
    return result;
}

SyncWorker::WriteResult SyncWorker::writeChangesIfFolderMatches(const QString& folderId, const SyncBatch& batch,
                                                                qint64 lastSeq, qint64 writtenAtMs)
{
    const OpenResult opened = open(QString());
    if (!opened.error.ok()) {
        return {opened.error, {}, {}};
    }
    if (opened.markerState != MarkerState::Present || opened.marker.folderId != folderId) {
        return {{SyncFolder::ErrorKind::Unavailable, QStringLiteral("同步文件夹不是本机加入的那一个")}, {}, {}};
    }
    return writeChanges(batch, lastSeq, writtenAtMs);
}

SyncWorker::WriteResult SyncWorker::writeSnapshot(const SyncFiles::SnapshotFile& snapshot)
{
    WriteResult result;
    result.position = {snapshot.batch.epoch, snapshot.coveredSeq};
    result.path = joinPath(SyncFiles::deviceDirectory(snapshot.batch.device), SyncFiles::snapshotFileName(result.position));
    result.error = writeWithinBudget(*m_folder, result.path, SyncFiles::encodeSnapshot(snapshot));
    return result;
}

SyncFolder::Error SyncWorker::writeCursor(const SyncFiles::CursorFile& cursor)
{
    return writeWithinBudget(*m_folder, joinPath(SyncFiles::deviceDirectory(cursor.device), SyncFiles::cursorFileName()),
                             SyncFiles::encodeCursor(cursor));
}

SyncWorker::SnapshotFetch SyncWorker::fetchJoinSnapshot(const QString& me, const QString& preferredDevice)
{
    SnapshotFetch fetch;
    const QStringList devices = peerDevices(me, &fetch.error);
    if (!fetch.error.ok()) {
        return fetch;
    }
    // 先按纪元挑：纪元最高的那份才是所有设备当前共同的状态（低纪元的是有人恢复备份之前的旧状态）。
    QString chosen;
    SyncPosition chosenPosition;
    for (const QString& device : devices) {
        SyncPosition position;
        SyncFolder::Error error;
        if (!latestSnapshot(device, &position, &error)) {
            if (!error.ok() && !isMissing(error)) {
                fetch.error = error;
                return fetch;
            }
            continue;
        }
        const bool better = chosen.isEmpty() || position.epoch > chosenPosition.epoch
            || (position.epoch == chosenPosition.epoch && device == preferredDevice);
        if (better) {
            chosen = device;
            chosenPosition = position;
        }
    }
    if (chosen.isEmpty()) {
        return fetch;
    }
    fetch.found = true;
    fetch.device = chosen;
    fetch.position = chosenPosition;
    fetch.status = readSnapshot(chosen, chosenPosition, &fetch.snapshot, &fetch.parseError, &fetch.error);
    return fetch;
}

SyncWorker::ScanResult SyncWorker::scan(const ScanRequest& request)
{
    ScanResult result;
    const QStringList devices = peerDevices(request.me, &result.error);
    if (!result.error.ok()) {
        return result;
    }
    // 先把每台设备有哪些文件看一遍（只列目录，不下载），再决定读什么。
    QHash<QString, DeviceFiles> files;
    QHash<QString, SyncFolder::Error> listErrors;
    for (const QString& device : devices) {
        SyncFolder::Error error;
        files.insert(device, inspect(device, &error));
        if (!error.ok()) {
            listErrors.insert(device, error);
        }
    }

    // 有设备到了更高的纪元：它恢复了备份。本机要整体换成那个纪元的快照，这一轮别的都不读了。
    // 挑纪元最高的；同一纪元里有快照的设备都行（都是回滚之后的状态），按设备标识取第一个，所有设备挑出同一份。
    qint64 highest = request.epoch;
    for (const QString& device : devices) {
        highest = std::max(highest, files.value(device).latestEpoch);
    }
    if (highest > request.epoch) {
        result.adoption.needed = true;
        struct Candidate {
            QString device;
            SyncPosition position;
        };
        QList<Candidate> candidates;
        for (const QString& device : devices) {
            QList<SyncPosition> deviceSnapshots;
            for (const SyncPosition& snapshot : files.value(device).snapshots) {
                if (snapshot.epoch == highest) {
                    deviceSnapshots.append(snapshot);
                }
            }
            std::sort(deviceSnapshots.begin(), deviceSnapshots.end(), [](const SyncPosition& a, const SyncPosition& b) {
                return a.seq > b.seq;
            });
            for (const SyncPosition& snapshot : deviceSnapshots) {
                candidates.append({device, snapshot});
            }
        }
        if (candidates.isEmpty()) {
            // 新纪元的快照还在路上：从最高纪元的设备改动中选确定来源（按设备标识升序，取其最高改动序号），
            // 填入 adoption.device 和 adoption.position，由 adopt 写入请求，不能静默无请求。
            result.adoption.ready = false;
            result.adoption.status = SyncFiles::ParseStatus::Ok;
            for (const QString& device : devices) {
                qint64 maxSeq = -1;
                for (const SyncPosition& change : files.value(device).changes) {
                    if (change.epoch == highest && change.seq > maxSeq) {
                        maxSeq = change.seq;
                    }
                }
                if (maxSeq >= 0) {
                    result.adoption.device = device;
                    result.adoption.position = {highest, maxSeq};
                    break;
                }
            }
            return result;
        }

        struct CorruptInfo {
            QString device;
            SyncPosition position;
            QString error;
        };
        QList<CorruptInfo> corruptList;
        SyncFolder::Error lastIoError;

        for (const Candidate& cand : candidates) {
            SyncFiles::SnapshotFile snapshot;
            QString parseError;
            SyncFolder::Error readError;
            const SyncFiles::ParseStatus status = readSnapshot(cand.device, cand.position, &snapshot,
                                                               &parseError, &readError);
            if (readError.ok() && status == SyncFiles::ParseStatus::Ok) {
                // 合法候选立即采用
                result.adoption.ready = true;
                result.adoption.device = cand.device;
                result.adoption.position = cand.position;
                result.adoption.status = SyncFiles::ParseStatus::Ok;
                result.adoption.snapshot = std::move(snapshot);
                result.adoption.error.clear();
                return result;
            }
            if (status == SyncFiles::ParseStatus::NewerFormat) {
                // NewerFormat 仍返回 NewerVersion
                result.adoption.ready = false;
                result.adoption.device = cand.device;
                result.adoption.position = cand.position;
                result.adoption.status = SyncFiles::ParseStatus::NewerFormat;
                result.adoption.error = parseError;
                return result;
            }
            if (!readError.ok()) {
                lastIoError = readError;
            } else {
                // 损坏候选继续尝试同 epoch 其他设备
                corruptList.append({cand.device, cand.position, parseError});
            }
        }

        // 若全部候选均遭遇 I/O 读取错误（无明确损坏的格式内容），向上报告底层 I/O 错误
        if (corruptList.isEmpty() && !lastIoError.ok()) {
            result.error = lastIoError;
            return result;
        }

        // 全部候选均损坏（或至少有损坏候选）
        result.adoption.ready = false;
        result.adoption.status = SyncFiles::ParseStatus::Corrupt;
        if (!corruptList.isEmpty()) {
            result.adoption.device = corruptList.first().device;
            result.adoption.position = corruptList.first().position;
            result.adoption.error = corruptList.first().error;
            for (const auto& item : corruptList) {
                result.adoption.corruptedCandidates.append({item.device, item.position, item.error});
            }
        }
        return result;
    }

    int budget = request.maxFiles;
    for (const QString& device : devices) {
        PeerScan peer;
        peer.device = device;
        if (listErrors.contains(device)) {
            peer.readError = listErrors.value(device);
            result.peers.append(peer);
            continue;
        }
        const DeviceFiles& available = files.value(device);
        QList<qint64> sequences;
        for (const SyncPosition& change : available.changes) {
            if (change.epoch == request.epoch) {
                sequences.append(change.seq);
            }
        }
        std::sort(sequences.begin(), sequences.end());
        SyncPosition snapshot{-1, -1};
        for (const SyncPosition& candidate : available.snapshots) {
            if (candidate.epoch == request.epoch && candidate.seq > snapshot.seq) {
                snapshot = candidate;
            }
        }
        const SyncPosition cursor = request.cursors.value(device);
        const qint64 applied = cursor.epoch == request.epoch ? cursor.seq : 0;
        qint64 firstAvailable = 0;
        for (const qint64 seq : sequences) {
            if (seq > applied) {
                firstAvailable = seq;
                break;
            }
        }

        // 什么时候先合并对方的快照：
        // - 缺号：下一批已经被对方清理掉了（本机很久没同步），而快照覆盖得到；
        // - 落后太多：与其下载几十个改动文件（每个约 1 秒），不如下载一份快照；
        // - 本机请它补的快照到了（读到过它的坏文件，或者它的某一批一直没到）。
        const bool hasSnapshotHere = snapshot.epoch == request.epoch && snapshot.seq > applied;
        const bool gapCovered = hasSnapshotHere && (firstAvailable == 0 || firstAvailable > applied + 1)
            && snapshot.seq >= (firstAvailable == 0 ? applied + 1 : firstAvailable - 1);
        const bool farBehind = hasSnapshotHere && snapshot.seq - applied >= request.catchUpViaSnapshot;
        const SyncPosition requested = request.requests.value(device);
        const bool requestAnswered = snapshot.epoch == request.epoch && requested.epoch == request.epoch
            && snapshot.seq >= requested.seq && requested.seq > 0;
        qint64 expected = applied + 1;
        if (gapCovered || farBehind || requestAnswered) {
            if (budget <= 0) {
                result.more = true;
                result.peers.append(peer);
                continue;
            }
            --budget;
            // 位置先记下：读不出来时 SyncEngine 要据此记日志、请对方写一份新的。
            peer.snapshotPosition = snapshot;
            peer.snapshotStatus = readSnapshot(device, snapshot, &peer.snapshot, &peer.snapshotError, &peer.readError);
            if (!peer.readError.ok()) {
                result.peers.append(peer);
                continue;
            }
            if (peer.snapshotStatus == SyncFiles::ParseStatus::Ok) {
                peer.hasSnapshot = true;
                expected = std::max(applied, snapshot.seq) + 1;
            }
        }

        for (const qint64 seq : sequences) {
            if (seq < expected) {
                continue;
            }
            // 只按顺序应用：中间缺了一批就停在这里等它到。iCloud 不保证按写出的顺序送到，
            // 缺的那一批通常几秒后就来了；一直不来的，SyncEngine 会请对方补快照。
            if (seq != expected) {
                peer.waitingFor = expected;
                break;
            }
            if (budget <= 0) {
                result.more = true;
                break;
            }
            --budget;
            IncomingFile file;
            file.seq = seq;
            file.path = joinPath(SyncFiles::changesDirectory(device), SyncFiles::changeFileName({request.epoch, seq}));
            QByteArray bytes;
            if (!m_folder->read(file.path, &bytes, &peer.readError)) {
                break;
            }
            if (bytes.size() > SyncFiles::kMaxChangesBytes) {
                file.kind = IncomingFile::Kind::Corrupt;
                file.error = QStringLiteral("改动文件大小超出预算上限");
                peer.files.append(file);
                ++expected;
                continue;
            }
            SyncFiles::ChangeFile content;
            const SyncFiles::ParseStatus status =
                SyncFiles::decodeChanges(bytes, device, {request.epoch, seq}, &content, &file.error);
            if (status == SyncFiles::ParseStatus::Ok) {
                file.batch = content.batch;
            } else {
                file.kind = status == SyncFiles::ParseStatus::NewerFormat ? IncomingFile::Kind::Newer
                                                                          : IncomingFile::Kind::Corrupt;
            }
            peer.files.append(file);
            // 更新版本写的文件停在这里（跳过就丢了）；坏文件由 SyncEngine 跳过，接着读后面的批次。
            if (file.kind == IncomingFile::Kind::Newer) {
                break;
            }
            ++expected;
        }
        result.peers.append(peer);
    }
    return result;
}

SyncWorker::Survey SyncWorker::survey(const QString& me)
{
    Survey result;
    const QStringList devices = peerDevices(me, &result.error);
    if (!result.error.ok()) {
        return result;
    }
    for (const QString& device : devices) {
        PeerCursor peer;
        peer.device = device;
        QByteArray bytes;
        SyncFolder::Error error;
        const QString path = joinPath(SyncFiles::deviceDirectory(device), SyncFiles::cursorFileName());
        if (m_folder->read(path, &bytes, &error)) {
            peer.present = true;
            if (bytes.size() > SyncFiles::kMaxCursorBytes) {
                peer.status = SyncFiles::ParseStatus::Corrupt;
            } else {
                QString parseError;
                peer.status = SyncFiles::decodeCursor(bytes, device, &peer.cursor, &parseError);
            }
        } else if (!isMissing(error)) {
            result.error = error;
            return result;
        }
        result.peers.append(peer);
    }
    SyncFolder::Error error;
    const DeviceFiles own = inspect(me, &error);
    if (!error.ok()) {
        result.error = error;
        return result;
    }
    result.ownChanges = own.changes;
    result.ownSnapshots = own.snapshots;
    return result;
}

SyncWorker::CleanupResult SyncWorker::cleanup(const QString& me, qint64 epoch, qint64 deleteUpToSeq,
                                              const SyncPosition& keepSnapshot, bool keepAnySnapshot)
{
    CleanupResult result;
    const auto removeAll = [this, &result](const QString& directory, const std::function<bool(const QString&)>& doomed) {
        SyncFolder::Error listError;
        const QStringList names = m_folder->list(directory, &listError);
        if (!listError.ok() && !isMissing(listError)) {
            result.error = listError;
            return;
        }
        for (const QString& name : names) {
            if (!doomed(name)) {
                continue;
            }
            SyncFolder::Error error;
            if (m_folder->remove(joinPath(directory, name), &error)) {
                ++result.removed;
            } else if (result.error.ok()) {
                result.error = error;
            }
        }
    };
    removeAll(SyncFiles::changesDirectory(me), [epoch, deleteUpToSeq](const QString& name) {
        SyncPosition position;
        if (SyncFiles::parseChangeFileName(name, &position)) {
            // 旧纪元的改动谁都用不上了：别的设备要么已经换到新纪元，要么马上会从新纪元的快照起步。
            return position.epoch < epoch || (position.epoch == epoch && position.seq <= deleteUpToSeq);
        }
        return SyncFiles::isTemporaryFileName(name);
    });
    removeAll(SyncFiles::deviceDirectory(me), [keepSnapshot, keepAnySnapshot](const QString& name) {
        SyncPosition position;
        if (SyncFiles::parseSnapshotFileName(name, &position)) {
            return !keepAnySnapshot || position != keepSnapshot;
        }
        return SyncFiles::isTemporaryFileName(name);
    });
    return result;
}

SyncWorker::DeviceFiles SyncWorker::inspect(const QString& device, SyncFolder::Error* error)
{
    DeviceFiles files;
    SyncFolder::Error listError;
    const QStringList changes = m_folder->list(SyncFiles::changesDirectory(device), &listError);
    if (!listError.ok() && !isMissing(listError)) {
        *error = listError;
        return files;
    }
    for (const QString& name : changes) {
        SyncPosition position;
        if (SyncFiles::parseChangeFileName(name, &position)) {
            files.changes.append(position);
            files.latestEpoch = std::max(files.latestEpoch, position.epoch);
        }
    }
    listError = {};
    const QStringList names = m_folder->list(SyncFiles::deviceDirectory(device), &listError);
    if (!listError.ok() && !isMissing(listError)) {
        *error = listError;
        return files;
    }
    for (const QString& name : names) {
        SyncPosition position;
        if (SyncFiles::parseSnapshotFileName(name, &position)) {
            files.snapshots.append(position);
            files.latestEpoch = std::max(files.latestEpoch, position.epoch);
        }
    }
    return files;
}

SyncFiles::ParseStatus SyncWorker::readSnapshot(const QString& device, const SyncPosition& position,
                                                SyncFiles::SnapshotFile* snapshot, QString* parseError,
                                                SyncFolder::Error* error)
{
    QByteArray bytes;
    const QString path = joinPath(SyncFiles::deviceDirectory(device), SyncFiles::snapshotFileName(position));
    if (!m_folder->read(path, &bytes, error)) {
        return SyncFiles::ParseStatus::Corrupt;
    }
    if (bytes.size() > SyncFiles::kMaxSnapshotBytes) {
        if (parseError) {
            *parseError = QStringLiteral("快照文件大小超出预算上限");
        }
        return SyncFiles::ParseStatus::Corrupt;
    }
    return SyncFiles::decodeSnapshot(bytes, device, position, snapshot, parseError);
}

bool SyncWorker::latestSnapshot(const QString& device, SyncPosition* position, SyncFolder::Error* error)
{
    const QStringList names = m_folder->list(SyncFiles::deviceDirectory(device), error);
    bool found = false;
    for (const QString& name : names) {
        SyncPosition candidate;
        if (!SyncFiles::parseSnapshotFileName(name, &candidate)) {
            continue;
        }
        if (!found || candidate.epoch > position->epoch
            || (candidate.epoch == position->epoch && candidate.seq > position->seq)) {
            *position = candidate;
            found = true;
        }
    }
    return found;
}

QList<qint64> SyncWorker::changeSequences(const QString& device, qint64 epoch, SyncFolder::Error* error)
{
    SyncFolder::Error listError;
    const QStringList names = m_folder->list(SyncFiles::changesDirectory(device), &listError);
    if (!listError.ok() && !isMissing(listError)) {
        *error = listError;
        return {};
    }
    QList<qint64> sequences;
    for (const QString& name : names) {
        SyncPosition position;
        if (SyncFiles::parseChangeFileName(name, &position) && position.epoch == epoch) {
            sequences.append(position.seq);
        }
    }
    std::sort(sequences.begin(), sequences.end());
    return sequences;
}

QStringList SyncWorker::peerDevices(const QString& me, SyncFolder::Error* error)
{
    SyncFolder::Error listError;
    const QStringList names = m_folder->list(SyncFiles::devicesDirectory(), &listError);
    if (!listError.ok() && !isMissing(listError)) {
        *error = listError;
        return {};
    }
    QStringList devices;
    for (const QString& name : names) {
        if (name != me && SyncFiles::isDeviceId(name)) {
            devices.append(name);
        }
    }
    devices.sort();
    return devices;
}
