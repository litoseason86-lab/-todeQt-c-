#include "SyncWorker.h"

#include <algorithm>
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
    QByteArray bytes;
    const QString path = joinPath(SyncFiles::deviceDirectory(chosen), SyncFiles::snapshotFileName(chosenPosition));
    if (!m_folder->read(path, &bytes, &fetch.error)) {
        return fetch;
    }
    fetch.status = SyncFiles::decodeSnapshot(bytes, chosen, chosenPosition, &fetch.snapshot, &fetch.parseError);
    return fetch;
}

SyncWorker::ScanResult SyncWorker::scan(const ScanRequest& request)
{
    ScanResult result;
    const QStringList devices = peerDevices(request.me, &result.error);
    if (!result.error.ok()) {
        return result;
    }
    int budget = request.maxFiles;
    for (const QString& device : devices) {
        PeerScan peer;
        peer.device = device;
        const QList<qint64> sequences = changeSequences(device, request.epoch, &peer.readError);
        if (!peer.readError.ok()) {
            result.peers.append(peer);
            continue;
        }
        const SyncPosition cursor = request.cursors.value(device);
        const qint64 applied = cursor.epoch == request.epoch ? cursor.seq : 0;
        qint64 expected = applied + 1;
        for (const qint64 seq : sequences) {
            if (seq < expected) {
                continue;
            }
            // 只按顺序应用：中间缺了一批就停在这里等它到。iCloud 不保证按写出的顺序送到，
            // 缺的那一批通常几秒后就来了。
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
