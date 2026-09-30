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

} // namespace

SyncWorker::SyncWorker(std::unique_ptr<SyncFolder> folder)
    : m_folder(std::move(folder))
{
}

void SyncWorker::cancelPendingIo()
{
    m_folder->cancelPendingIo();
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
        const SyncFiles::ParseStatus status = SyncFiles::decodeMarker(bytes, &result.marker, &result.markerError);
        result.markerState = status == SyncFiles::ParseStatus::Ok            ? MarkerState::Present
                           : status == SyncFiles::ParseStatus::NewerFormat ? MarkerState::Newer
                                                                             : MarkerState::Corrupt;
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
    SyncFolder::Error error;
    m_folder->write(SyncFiles::markerFileName(), SyncFiles::encodeMarker(marker), &error);
    return error;
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
    m_folder->write(result.path, SyncFiles::encodeChanges({seq, writtenAtMs, batch}), &result.error);
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
    m_folder->write(result.path, SyncFiles::encodeSnapshot(snapshot), &result.error);
    return result;
}

SyncFolder::Error SyncWorker::writeCursor(const SyncFiles::CursorFile& cursor)
{
    SyncFolder::Error error;
    m_folder->write(joinPath(SyncFiles::deviceDirectory(cursor.device), SyncFiles::cursorFileName()),
                    SyncFiles::encodeCursor(cursor), &error);
    return error;
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
        for (const QString& device : devices) {
            SyncPosition best{-1, -1};
            for (const SyncPosition& snapshot : files.value(device).snapshots) {
                if (snapshot.epoch == highest && snapshot.seq > best.seq) {
                    best = snapshot;
                }
            }
            if (best.epoch != highest) {
                continue;
            }
            result.adoption.device = device;
            result.adoption.position = best;
            result.adoption.status = readSnapshot(device, best, &result.adoption.snapshot, &result.adoption.error,
                                                  &result.error);
            result.adoption.ready = result.error.ok() && result.adoption.status == SyncFiles::ParseStatus::Ok;
            break;
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
            peer.snapshotStatus = readSnapshot(device, snapshot, &peer.snapshot, &peer.snapshotError, &peer.readError);
            if (!peer.readError.ok()) {
                result.peers.append(peer);
                continue;
            }
            if (peer.snapshotStatus == SyncFiles::ParseStatus::Ok) {
                peer.hasSnapshot = true;
                peer.snapshotPosition = snapshot;
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
            if (file.kind != IncomingFile::Kind::Batch) {
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
            QString parseError;
            peer.status = SyncFiles::decodeCursor(bytes, device, &peer.cursor, &parseError);
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
