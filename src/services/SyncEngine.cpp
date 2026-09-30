#include "SyncEngine.h"

#include "SyncNotifier.h"

#include <QDebug>
#include <QFutureWatcher>
#include <QThreadPool>
#include <QUuid>
#include <QtConcurrent/QtConcurrentRun>

#include <algorithm>
#include <utility>

namespace {

// 一轮里可能应用好几批改动，合成一个结果，界面只刷新一次。
void mergeResult(SyncStore::ApplyResult* total, const SyncStore::ApplyResult& part)
{
    total->ok = true;
    total->changedTables.unite(part.changedTables);
    for (const int taskId : part.deletedTaskIds) {
        if (!total->deletedTaskIds.contains(taskId)) {
            total->deletedTaskIds.append(taskId);
        }
    }
    // 同一个设置在后一批里又变了，以后一批为准。
    for (auto it = part.changedSettings.cbegin(); it != part.changedSettings.cend(); ++it) {
        total->changedSettings.insert(it.key(), it.value());
    }
    total->conflictsLogged += part.conflictsLogged;
    total->skippedRecords += part.skippedRecords;
}

bool hasVisibleChanges(const SyncStore::ApplyResult& result)
{
    return !result.changedTables.isEmpty() || !result.deletedTaskIds.isEmpty() || !result.changedSettings.isEmpty();
}

SyncEngine::Status statusFor(const SyncFolder::Error& error)
{
    switch (error.kind) {
    case SyncFolder::ErrorKind::Unavailable:
        return SyncEngine::Status::FolderUnavailable;
    case SyncFolder::ErrorKind::NoSpace:
        return SyncEngine::Status::NoSpace;
    default:
        return SyncEngine::Status::Error;
    }
}

// 同时有几个问题时显示哪一个：数字越小越要紧（越需要你去处理）。
int urgency(SyncEngine::Status status)
{
    switch (status) {
    case SyncEngine::Status::BackupFailed:
        return 0;
    case SyncEngine::Status::NewerVersion:
        return 1;
    case SyncEngine::Status::NoSpace:
        return 2;
    case SyncEngine::Status::UploadFailed:
        return 3;
    case SyncEngine::Status::FolderUnavailable:
        return 4;
    case SyncEngine::Status::Error:
        return 5;
    default:
        return 6;
    }
}

qint64 wallClockMs()
{
    return QDateTime::currentMSecsSinceEpoch();
}

// 只留纪元与当前相同的位置：旧纪元的进度对别的设备没有意义。
QHash<QString, SyncPosition> positionsInEpoch(const QHash<QString, SyncPosition>& positions, qint64 epoch)
{
    QHash<QString, SyncPosition> result;
    for (auto it = positions.cbegin(); it != positions.cend(); ++it) {
        if (it.value().epoch == epoch) {
            result.insert(it.key(), it.value());
        }
    }
    return result;
}

} // namespace

SyncEngine::SyncEngine(std::unique_ptr<SyncFolder> folder, const Options& options, const QString& connectionName,
                       QObject* parent)
    : QObject(parent)
    , m_options(options)
    , m_connection(connectionName)
    , m_worker(std::make_shared<SyncWorker>(std::move(folder)))
    , m_pool(std::make_shared<QThreadPool>())
{
    m_pool->setMaxThreadCount(1);
    // 线程一直留着，不随空闲回收：Mac 每 20 秒就要用一次。
    m_pool->setExpiryTimeout(-1);
    m_notifier = [](const SyncStore::ApplyResult& result) { SyncNotifier::publish(result); };
    m_clock.start();
    m_tick.setInterval(m_options.tickMs);
    connect(&m_tick, &QTimer::timeout, this, &SyncEngine::onTick);
    m_lastSyncedAt = store().lastSyncedAt();
}

SyncEngine::~SyncEngine()
{
    ++m_generation;
    m_tick.stop();
    m_worker->cancelPendingIo();
    // 工作线程可能正卡在等 iCloud 下载。最多等 5 秒，等不到就放手：进程马上要退出了，
    // 而线程池的析构会一直等到任务做完，退出就会卡住。所以故意留下一份引用，不让它析构。
    if (!m_pool->waitForDone(5000)) {
        qWarning() << "Sync worker is still busy at shutdown; leaving it behind";
        new std::shared_ptr<QThreadPool>(m_pool);
    }
}

void SyncEngine::setSafetyBackup(std::function<bool(QString* error)> backup)
{
    m_safetyBackup = std::move(backup);
}

void SyncEngine::setChangeNotifier(std::function<void(const SyncStore::ApplyResult&)> notifier)
{
    m_notifier = std::move(notifier);
}

void SyncEngine::setFolder(std::unique_ptr<SyncFolder> folder)
{
    // 旧文件夹上还在跑的操作照样跑完（排在同一个队里），结果按代数丢掉；新的一轮用新文件夹。
    ++m_generation;
    m_inCycle = false;
    m_worker->cancelPendingIo();
    m_worker = std::make_shared<SyncWorker>(std::move(folder));
    m_lastWrittenPath.clear();
    m_joinConfirmed = false;
    if (m_running) {
        m_retryAtMs = 0;
        m_retryDelayMs = 0;
        requestCycle();
    }
}

void SyncEngine::start()
{
    if (m_running) {
        return;
    }
    m_running = true;
    m_retryAtMs = 0;
    m_retryDelayMs = 0;
    m_status = Status::Starting;
    m_detail.clear();
    refreshPending();
    updateTimer();
    emit statusChanged();
    requestCycle();
}

void SyncEngine::stop()
{
    if (!m_running) {
        return;
    }
    m_running = false;
    ++m_generation;
    m_inCycle = false;
    m_cycleRequested = false;
    m_joinConfirmed = false;
    m_flushOnly = false;
    updateTimer();
    m_status = Status::Stopped;
    m_detail.clear();
    emit statusChanged();
}

void SyncEngine::confirmJoin()
{
    m_joinConfirmed = true;
    syncNow();
}

void SyncEngine::syncNow()
{
    if (!m_running) {
        return;
    }
    m_retryAtMs = 0;
    m_retryDelayMs = 0;
    m_flushRequested = true;
    requestCycle();
}

void SyncEngine::setForeground(bool foreground)
{
    if (m_foreground == foreground) {
        return;
    }
    m_foreground = foreground;
    updateTimer();
    if (!m_running) {
        return;
    }
    if (foreground) {
        m_flushOnly = false;
        m_retryAtMs = 0;
        m_retryDelayMs = 0;
    } else {
        // 进了后台时间有限（iPad 几秒后就会被挂起）：只写出攒下的改动，不读对方的。
        m_flushRequested = true;
        m_flushOnly = true;
    }
    requestCycle();
}

bool SyncEngine::flushBeforeExit(int timeoutMs)
{
    if (!m_running) {
        return true;
    }
    stop();
    SyncStore s = store();
    const QString folderId = s.folderId();
    if (folderId.isEmpty() || !s.hasPending()) {
        return true;
    }
    const SyncBatch batch = s.collectPending();
    if (batch.isEmpty()) {
        return true;
    }
    const SyncPosition outbound = s.outboundPosition();
    const qint64 lastSeq = outbound.epoch == batch.epoch ? outbound.seq : 0;
    const qint64 writtenAt = wallClockMs();
    const std::shared_ptr<SyncWorker> worker = m_worker;
    QFuture<SyncWorker::WriteResult> future = QtConcurrent::run(m_pool.get(), [worker, folderId, batch, lastSeq,
                                                                                writtenAt] {
        return worker->writeChangesIfFolderMatches(folderId, batch, lastSeq, writtenAt);
    });
    // 排在前面的操作（正在进行的那一轮）也要等它做完。等不到就算了：改动还留在本机，下次启动再写。
    if (!m_pool->waitForDone(timeoutMs)) {
        return false;
    }
    const SyncWorker::WriteResult result = future.result();
    if (!result.error.ok()) {
        qWarning() << "Failed to flush sync changes before exit:" << result.error.message;
        return false;
    }
    return s.setOutboundPosition(result.position) && s.acknowledge(batch);
}

QString SyncEngine::statusText() const
{
    switch (m_status) {
    case Status::Stopped:
        return QStringLiteral("同步已关闭");
    case Status::Starting:
        return QStringLiteral("正在连接同步文件夹…");
    case Status::UpToDate:
        return QStringLiteral("已同步");
    case Status::NeedsConfirmation:
        return QStringLiteral("这台设备第一次加入这个同步文件夹。确认后，本机现有的数据会先自动备份，"
                              "再换成同步文件夹里的数据。");
    case Status::WaitingForSnapshot:
        return QStringLiteral("正在等同步文件夹里的数据传过来…");
    case Status::FolderUnavailable:
        return QStringLiteral("暂时无法访问同步文件夹。请确认已登录 Apple ID 并打开了 iCloud 云盘。");
    case Status::WrongFolder:
        return m_detail.isEmpty() ? QStringLiteral("选中的不是番茄Todo 的同步文件夹。") : m_detail;
    case Status::FolderMissing:
        return QStringLiteral("同步文件夹不见了（标记文件被删除或移走），同步已暂停。");
    case Status::NoSpace:
        return QStringLiteral("存储空间不足，改动暂时写不出去，先留在这台设备上。");
    case Status::UploadFailed:
        return QStringLiteral("改动已写进同步文件夹，但上传到 iCloud 失败，可能是 iCloud 空间已满。");
    case Status::NewerVersion:
        return QStringLiteral("另一台设备用的是更新版本的番茄Todo，请先更新这台设备上的应用。");
    case Status::BackupFailed:
        return QStringLiteral("替换本机数据前的自动备份没有成功，暂不替换。");
    case Status::Error:
        return QStringLiteral("同步出错，稍后会自动重试。");
    }
    return QString();
}

template <typename Result, typename Job, typename Done>
void SyncEngine::runOnWorker(Job job, Done done)
{
    auto* watcher = new QFutureWatcher<Result>(this);
    const quint64 generation = m_generation;
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher, done, generation] {
        watcher->deleteLater();
        // 引擎停下、换了文件夹之后回来的旧结果：这一轮已经作废，丢掉。
        if (generation != m_generation) {
            return;
        }
        done(watcher->result());
    });
    const std::shared_ptr<SyncWorker> worker = m_worker;
    watcher->setFuture(QtConcurrent::run(m_pool.get(), [worker, job] { return job(*worker); }));
}

void SyncEngine::requestCycle()
{
    if (!m_running) {
        return;
    }
    if (m_inCycle) {
        m_cycleRequested = true;
        return;
    }
    startCycle();
}

void SyncEngine::startCycle()
{
    m_inCycle = true;
    m_cycleRequested = false;
    m_warnings.clear();
    emit statusChanged();
    const QString lastWritten = m_lastWrittenPath;
    runOnWorker<SyncWorker::OpenResult>(
        [lastWritten](SyncWorker& worker) { return worker.open(lastWritten); },
        [this](const SyncWorker::OpenResult& result) { afterOpen(result); });
}

void SyncEngine::afterOpen(const SyncWorker::OpenResult& result)
{
    if (!result.error.ok()) {
        return finishCycle(statusFor(result.error), result.error.message);
    }
    if (!result.uploadProblem.isEmpty()) {
        warn(Status::UploadFailed, result.uploadProblem);
    }
    SyncStore s = store();
    const QString joined = s.folderId();
    switch (result.markerState) {
    case SyncWorker::MarkerState::Newer:
        return finishCycle(Status::NewerVersion, result.markerError);
    case SyncWorker::MarkerState::Corrupt:
        return finishCycle(joined.isEmpty() ? Status::WrongFolder : Status::FolderMissing,
                           QStringLiteral("标记文件「%1」坏了：%2").arg(SyncFiles::markerFileName(), result.markerError));
    case SyncWorker::MarkerState::Missing:
        // 只在空文件夹里新建。已经加入过的文件夹不见了，不自动重建：重建就是另一个文件夹，
        // 别的设备还认着旧的，会各自以为自己是第一次加入。
        if (joined.isEmpty() && m_options.mayCreateFolder && result.folderEmpty) {
            return createFolder();
        }
        return finishCycle(joined.isEmpty() ? Status::WrongFolder : Status::FolderMissing,
                           joined.isEmpty() ? result.hint : QString());
    case SyncWorker::MarkerState::Present:
        break;
    }
    if (result.marker.folderId == joined) {
        return publishStep();
    }
    // 本机自己建的文件夹，只是库里没记下（例如恢复了建文件夹之前的备份）：本机本来就是它的源头，直接接上。
    if (result.marker.createdBy == s.deviceId()) {
        if (!s.setFolderId(result.marker.folderId)) {
            return finishCycle(Status::Error, QStringLiteral("记不下加入的同步文件夹"));
        }
        return publishStep();
    }
    // 第一次加入别人建的文件夹：本机数据要整体换成文件夹里的，必须先得到你的确认。
    if (!m_joinConfirmed) {
        return finishCycle(Status::NeedsConfirmation);
    }
    joinFolder(result.marker.folderId, result.marker.createdBy);
}

void SyncEngine::createFolder()
{
    SyncFiles::Marker marker;
    marker.folderId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    marker.createdBy = store().deviceId();
    marker.createdAt = QDateTime::currentDateTime().toString(Qt::ISODate);
    runOnWorker<SyncFolder::Error>(
        [marker](SyncWorker& worker) { return worker.createMarker(marker); },
        [this, marker](const SyncFolder::Error& error) {
            if (!error.ok()) {
                return finishCycle(statusFor(error), error.message);
            }
            SyncStore s = store();
            // 先记下要写快照、再记下加入了文件夹：中途被结束，下次启动时标记文件在、身份对得上，
            // 快照也照样会写出去；反过来就可能出现「文件夹建好了、却永远没有快照」，iPad 加入不了。
            if (!s.requestFullSnapshot() || !s.setFolderId(marker.folderId)) {
                return finishCycle(Status::Error, QStringLiteral("记不下新建的同步文件夹"));
            }
            publishStep();
        });
}

void SyncEngine::joinFolder(const QString& folderId, const QString& creator)
{
    const QString me = store().deviceId();
    runOnWorker<SyncWorker::SnapshotFetch>(
        [me, creator](SyncWorker& worker) { return worker.fetchJoinSnapshot(me, creator); },
        [this, folderId](const SyncWorker::SnapshotFetch& fetch) {
            if (!fetch.error.ok()) {
                return finishCycle(statusFor(fetch.error), fetch.error.message);
            }
            // Mac 刚建好文件夹时，快照可能还在上传。
            if (!fetch.found) {
                return finishCycle(Status::WaitingForSnapshot);
            }
            if (fetch.status == SyncFiles::ParseStatus::NewerFormat) {
                return finishCycle(Status::NewerVersion, fetch.parseError);
            }
            if (fetch.status != SyncFiles::ParseStatus::Ok) {
                return finishCycle(Status::WaitingForSnapshot,
                                   QStringLiteral("起步用的快照读不出来：%1").arg(fetch.parseError));
            }
            Status failure = Status::Error;
            QString error;
            if (!replaceFromSnapshot(fetch.device, fetch.snapshot, &failure, &error)) {
                return finishCycle(failure, error);
            }
            if (!store().setFolderId(folderId)) {
                return finishCycle(Status::Error, QStringLiteral("记不下加入的同步文件夹"));
            }
            m_joinConfirmed = false;
            publishStep();
        });
}

bool SyncEngine::replaceFromSnapshot(const QString& source, const SyncFiles::SnapshotFile& snapshot,
                                     Status* failure, QString* error)
{
    // 被换掉的本机数据只能从这份备份里找回，所以备份不成功就不替换。
    if (m_safetyBackup) {
        QString backupError;
        if (!m_safetyBackup(&backupError)) {
            *failure = Status::BackupFailed;
            *error = backupError;
            return false;
        }
    }
    SyncStore s = store();
    const QString me = s.deviceId();
    const SyncStore::ApplyResult result = s.replaceWithSnapshot(snapshot.batch);
    if (!result.ok) {
        *failure = Status::Error;
        *error = result.error;
        return false;
    }
    // 游标重新起步：快照的来源读到它自己的第 coveredSeq 批；别的设备按快照里记的进度接着读，
    // 不用把它们从头再读一遍。进度记完之前被结束也不要紧，下次从头读，重复应用不改变任何东西。
    QHash<QString, SyncPosition> cursors = positionsInEpoch(snapshot.applied, snapshot.batch.epoch);
    cursors.remove(me);
    cursors.insert(source, {snapshot.batch.epoch, snapshot.coveredSeq});
    bool ok = s.replacePeerCursors(cursors);
    const QHash<QString, SyncPosition> requests = s.snapshotRequests();
    for (auto it = requests.cbegin(); ok && it != requests.cend(); ++it) {
        ok = s.clearSnapshotRequest(it.key());
    }
    m_cursorDirty = true;
    notify(result);
    if (!ok) {
        *failure = Status::Error;
        *error = QStringLiteral("记不下新的读取进度");
    }
    return ok;
}

void SyncEngine::publishStep()
{
    SyncStore s = store();
    if (s.needsSnapshot()) {
        return publishFullSnapshot();
    }
    const qint64 now = nowMs();
    const bool due = m_flushRequested || m_lastPublishMs < 0 || now - m_lastPublishMs >= m_options.publishIntervalMs;
    if (due && s.hasPending()) {
        return publishChanges();
    }
    if (m_flushOnly) {
        return finishCycle();
    }
    scanStep();
}

void SyncEngine::publishFullSnapshot()
{
    SyncStore s = store();
    SyncFiles::SnapshotFile file;
    file.batch = s.exportSnapshot();
    const SyncPosition outbound = s.outboundPosition();
    file.coveredSeq = outbound.epoch == file.batch.epoch ? outbound.seq : 0;
    file.writtenAtMs = wallClockMs();
    file.applied = positionsInEpoch(s.peerCursors(), file.batch.epoch);
    runOnWorker<SyncWorker::WriteResult>(
        [file](SyncWorker& worker) { return worker.writeSnapshot(file); },
        [this, file](const SyncWorker::WriteResult& written) {
            if (!written.error.ok()) {
                return finishCycle(statusFor(written.error), written.error.message);
            }
            SyncStore s = store();
            // 这份快照是给所有设备的（新建的文件夹、恢复备份后的新纪元）：别的设备都会整份采用它，
            // 所以它已经带上的待发送改动不必再单独发一遍。
            if (!s.markSnapshotPublished(file.batch) || !s.setSnapshotPosition(written.position)) {
                return finishCycle(Status::Error, QStringLiteral("记不下已经写出的快照"));
            }
            m_lastWrittenPath = written.path;
            m_lastPublishMs = nowMs();
            if (m_flushOnly) {
                return finishCycle();
            }
            scanStep();
        });
}

void SyncEngine::publishChanges()
{
    SyncStore s = store();
    const SyncBatch batch = s.collectPending();
    // 队列里只剩读不出来的记录（外部改过库），没有东西可写。
    if (batch.isEmpty()) {
        return m_flushOnly ? finishCycle() : scanStep();
    }
    const SyncPosition outbound = s.outboundPosition();
    const qint64 lastSeq = outbound.epoch == batch.epoch ? outbound.seq : 0;
    const qint64 writtenAt = wallClockMs();
    runOnWorker<SyncWorker::WriteResult>(
        [batch, lastSeq, writtenAt](SyncWorker& worker) { return worker.writeChanges(batch, lastSeq, writtenAt); },
        [this, batch](const SyncWorker::WriteResult& written) {
            if (!written.error.ok()) {
                return finishCycle(statusFor(written.error), written.error.message);
            }
            SyncStore s = store();
            // 文件已经写出去了：记下序号、确认这批。确认失败时这批下次会再写一遍，重复应用不改变任何东西；
            // 序号没记下也不要紧，下次写之前会看目录里已有的最大序号。
            if (!s.setOutboundPosition(written.position) || !s.acknowledge(batch)) {
                return finishCycle(Status::Error, QStringLiteral("改动已写出，但记不下发送进度"));
            }
            m_lastWrittenPath = written.path;
            m_lastPublishMs = nowMs();
            m_flushRequested = false;
            if (m_flushOnly) {
                return finishCycle();
            }
            scanStep();
        });
}

void SyncEngine::scanStep()
{
    SyncStore s = store();
    SyncWorker::ScanRequest request;
    request.me = s.deviceId();
    request.epoch = s.epoch();
    request.cursors = s.peerCursors();
    request.maxFiles = m_options.maxFilesPerScan;
    runOnWorker<SyncWorker::ScanResult>(
        [request](SyncWorker& worker) { return worker.scan(request); },
        [this](const SyncWorker::ScanResult& result) { afterScan(result); });
}

void SyncEngine::afterScan(const SyncWorker::ScanResult& result)
{
    m_lastScanMs = nowMs();
    if (!result.error.ok()) {
        return finishCycle(statusFor(result.error), result.error.message);
    }
    SyncStore s = store();
    const qint64 epoch = s.epoch();
    SyncStore::ApplyResult total;
    for (const SyncWorker::PeerScan& peer : result.peers) {
        for (const SyncWorker::IncomingFile& file : peer.files) {
            if (file.kind == SyncWorker::IncomingFile::Kind::Newer) {
                warn(Status::NewerVersion, file.error);
                break;
            }
            if (file.kind == SyncWorker::IncomingFile::Kind::Corrupt) {
                warn(Status::Error, QStringLiteral("%1 读不懂：%2").arg(file.path, file.error));
                break;
            }
            // 每批一个事务；提交之后才记「读到了第几批」。先记后提交的话，中途失败就会漏掉这一批。
            const SyncStore::ApplyResult applied = s.applyRemote(file.batch);
            if (!applied.ok) {
                warn(Status::Error, applied.error);
                break;
            }
            mergeResult(&total, applied);
            if (!s.setPeerCursor(peer.device, {epoch, file.seq})) {
                warn(Status::Error, QStringLiteral("记不下读取进度"));
                break;
            }
            m_cursorDirty = true;
        }
        if (!peer.readError.ok()) {
            warn(statusFor(peer.readError), peer.readError.message);
        }
    }
    if (total.ok && hasVisibleChanges(total)) {
        notify(total);
    }
    // 这一轮读满了上限：紧接着再来一轮，不等下一个扫描间隔。
    if (result.more) {
        m_cycleRequested = true;
    }
    writeCursorStep();
}

void SyncEngine::writeCursorStep()
{
    if (!m_cursorDirty) {
        return finishCycle();
    }
    SyncStore s = store();
    SyncFiles::CursorFile cursor;
    cursor.device = s.deviceId();
    cursor.epoch = s.epoch();
    cursor.writtenAtMs = wallClockMs();
    cursor.applied = positionsInEpoch(s.peerCursors(), cursor.epoch);
    cursor.snapshotRequests = positionsInEpoch(s.snapshotRequests(), cursor.epoch);
    runOnWorker<SyncFolder::Error>(
        [cursor](SyncWorker& worker) { return worker.writeCursor(cursor); },
        [this](const SyncFolder::Error& error) {
            if (!error.ok()) {
                return finishCycle(statusFor(error), error.message);
            }
            m_cursorDirty = false;
            finishCycle();
        });
}

void SyncEngine::finishCycle(Status failure, const QString& detail)
{
    m_inCycle = false;
    m_flushOnly = false;
    Status status = failure;
    QString text = detail;
    const bool completed = failure == Status::UpToDate;
    if (completed && !m_warnings.isEmpty()) {
        const auto mostUrgent = std::min_element(m_warnings.cbegin(), m_warnings.cend(),
                                                 [](const auto& a, const auto& b) {
                                                     return urgency(a.first) < urgency(b.first);
                                                 });
        status = mostUrgent->first;
        text = mostUrgent->second;
    }
    if (completed) {
        // 整轮走完（哪怕有不致命的问题）：按正常节拍继续。
        m_retryDelayMs = 0;
        m_retryAtMs = 0;
        m_lastSyncedAt = QDateTime::currentDateTime();
        const qint64 now = nowMs();
        if (m_lastSyncedSavedMs < 0 || now - m_lastSyncedSavedMs >= 60 * 1000) {
            store().setLastSyncedAt(m_lastSyncedAt);
            m_lastSyncedSavedMs = now;
        }
    } else {
        // 中途失败：隔一段再试，间隔逐次翻倍。文件夹不可用时每 5 秒试一次没有意义。
        m_retryDelayMs = m_retryDelayMs == 0 ? m_options.retryMinMs
                                             : std::min(m_retryDelayMs * 2, m_options.retryMaxMs);
        m_retryAtMs = nowMs() + m_retryDelayMs;
    }
    if (status != Status::UpToDate && status != Status::NeedsConfirmation) {
        qWarning() << "Sync cycle finished with problem" << status << text;
    }
    m_status = status;
    m_detail = text;
    m_pendingCount = store().pendingCount();
    emit statusChanged();
    emit cycleFinished();
    if (m_cycleRequested && m_running) {
        // 放到事件循环里再开始，不在这一层调用栈里层层递归。
        QTimer::singleShot(0, this, &SyncEngine::requestCycle);
    }
}

void SyncEngine::notify(const SyncStore::ApplyResult& result)
{
    if (m_notifier) {
        m_notifier(result);
    }
}

void SyncEngine::warn(Status status, const QString& detail)
{
    m_warnings.append({status, detail});
}

void SyncEngine::onTick()
{
    if (!m_running || m_inCycle) {
        return;
    }
    const qint64 now = nowMs();
    if (now < m_retryAtMs) {
        return;
    }
    refreshPending();
    const bool scanDue = m_lastScanMs < 0 || now - m_lastScanMs >= m_options.scanIntervalMs;
    const bool publishDue = m_pendingCount > 0
        && (m_lastPublishMs < 0 || now - m_lastPublishMs >= m_options.publishIntervalMs);
    if (scanDue || publishDue) {
        requestCycle();
    }
}

void SyncEngine::updateTimer()
{
    const bool active = m_running && (m_foreground || m_options.runInBackground);
    if (active && !m_tick.isActive()) {
        m_tick.start();
    } else if (!active) {
        m_tick.stop();
    }
}

void SyncEngine::refreshPending()
{
    const int count = store().pendingCount();
    if (count != m_pendingCount) {
        m_pendingCount = count;
        emit statusChanged();
    }
}
