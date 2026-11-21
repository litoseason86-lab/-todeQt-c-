#include "SyncEngine.h"

#include <QDebug>
#include <QFutureWatcher>
#include <QPointer>
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
        total->removedSettings.remove(it.key());
    }
    // 后一批删掉了前一批改过的项：以后一批为准。
    for (const QString& key : part.removedSettings) {
        total->changedSettings.remove(key);
        total->removedSettings.insert(key);
    }
    total->conflictsLogged += part.conflictsLogged;
    total->skippedRecords += part.skippedRecords;
}

bool hasVisibleChanges(const SyncStore::ApplyResult& result)
{
    return !result.changedTables.isEmpty() || !result.deletedTaskIds.isEmpty() || !result.changedSettings.isEmpty()
        || !result.removedSettings.isEmpty();
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

// 统一构造待写出的游标文件：applied 只保留本纪元，snapshotRequests 保留不低于本纪元的请求，
// 以支持在滞留旧纪元时向高纪元对端发出补快照请求。
SyncFiles::CursorFile buildCursorFile(const SyncStore& s, qint64 wallNow)
{
    SyncFiles::CursorFile cursor;
    cursor.device = s.deviceId();
    cursor.epoch = s.epoch();
    cursor.writtenAtMs = wallNow;
    cursor.applied = positionsInEpoch(s.peerCursors(), cursor.epoch);
    const QHash<QString, SyncPosition> allRequests = s.snapshotRequests();
    for (auto it = allRequests.cbegin(); it != allRequests.cend(); ++it) {
        if (it.value().epoch >= cursor.epoch) {
            cursor.snapshotRequests.insert(it.key(), it.value());
        }
    }
    return cursor;
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
    m_clock.start();
    m_tick.setInterval(m_options.tickMs);
    connect(&m_tick, &QTimer::timeout, this, &SyncEngine::onTick);
    m_stallTimer.setSingleShot(true);
    connect(&m_stallTimer, &QTimer::timeout, this, &SyncEngine::onStallCheck);
    m_lastSyncedAt = store().lastSyncedAt();
}

SyncEngine::~SyncEngine()
{
    ++m_generation;
    m_tick.stop();
    endBackgroundTask();
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

void SyncEngine::setBackgroundTaskProvider(std::function<std::function<void()>()> provider)
{
    m_backgroundTaskProvider = std::move(provider);
}

void SyncEngine::setFolder(std::unique_ptr<SyncFolder> folder)
{
    // 旧文件夹上还在跑的操作照样跑完（排在同一个队里），结果按代数丢掉；新的一轮用新文件夹。
    ++m_generation;
    m_inCycle = false;
    m_cycleRequested = false;
    m_continueRequested = false;
    m_stallTimer.stop();
    m_stallWorker.reset();
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
    m_stallTimer.stop();
    m_stallWorker.reset();
    // 与析构和切换目录保持一致：立即打断正在阻塞的工作线程请求，避免停机或切换传输时傻等超时。
    m_worker->cancelPendingIo();
    m_cycleRequested = false;
    m_continueRequested = false;
    m_joinConfirmed = false;
    m_cycleFlushOnly = false;
    m_backgroundFlushPending = false;
    endBackgroundTask();
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
        // 回到前台：不再怕被挂起，后台任务可以还给系统了。
        m_backgroundFlushPending = false;
        endBackgroundTask();
        m_retryAtMs = 0;
        m_retryDelayMs = 0;
    } else {
        // 进了后台时间有限（iPad 几秒后就会被挂起）：只写出攒下的改动，不读对方的；
        // 先向系统要一点时间，免得写到一半被挂起。
        m_flushRequested = true;
        m_backgroundFlushPending = true;
        if (m_backgroundTaskProvider && !m_endBackgroundTask) {
            m_endBackgroundTask = m_backgroundTaskProvider();
        }
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
    // 刚恢复备份或刚建空间尚未发布首份基线快照时，禁止退出前单独冲刷无基线支撑的孤儿增量批次，留待下次启动完整发布快照。
    if (folderId.isEmpty() || s.needsSnapshot() || !s.hasPending()) {
        return true;
    }
    QElapsedTimer budget;
    budget.start();
    const std::shared_ptr<SyncWorker> worker = m_worker;
    while (true) {
        const SyncStore::PendingChunkResult chunk =
            s.collectPendingChunk(SyncFiles::kSoftChangesBytes, SyncFiles::kMaxChangesBytes);
        if (!chunk.ok) {
            qWarning() << "Failed to collect pending sync changes before exit:" << chunk.error;
            return false;
        }
        if (chunk.oversizeSingleRecord) {
            qWarning() << "Oversize sync record cannot be flushed before exit:" << chunk.oversizeDetail;
            return false;
        }
        if (chunk.batch.isEmpty()) {
            return true;
        }
        const int remainingMs = timeoutMs <= 0 ? 0 : qMax(0, timeoutMs - int(budget.elapsed()));
        if (remainingMs <= 0) {
            return false;
        }
        const SyncBatch batch = chunk.batch;
        const SyncPosition outbound = s.outboundPosition();
        const qint64 lastSeq = outbound.epoch == batch.epoch ? outbound.seq : 0;
        const qint64 writtenAt = wallClockMs();
        QFuture<SyncWorker::WriteResult> future = QtConcurrent::run(
            m_pool.get(), [worker, folderId, batch, lastSeq, writtenAt] {
                return worker->writeChangesIfFolderMatches(folderId, batch, lastSeq, writtenAt);
            });
        // 排在前面的操作（正在进行的那一轮）也要等它做完；超时则立刻取消阻塞 I/O，未发改动留在本机下次再写。
        if (!m_pool->waitForDone(remainingMs)) {
            worker->cancelPendingIo();
            return false;
        }
        const SyncWorker::WriteResult result = future.result();
        if (!result.error.ok()) {
            qWarning() << "Failed to flush sync changes before exit:" << result.error.message;
            return false;
        }
        if (!s.acknowledgeOutbound(batch, result.position)) {
            return false;
        }
        if (!chunk.hasMore) {
            return true;
        }
    }
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
        // 引擎停下、换了文件夹、或者看门狗判定卡住而放弃之后回来的旧结果：这一轮已经作废，丢掉。
        // 这时也不能动看门狗：它可能已经在看守新的一轮。
        if (generation != m_generation) {
            return;
        }
        // 这一步做完了，先撤掉看门狗；done 里交出下一步时会重新开始看守。
        m_stallTimer.stop();
        m_stallWorker.reset();
        done(watcher->result());
    });
    const std::shared_ptr<SyncWorker> worker = m_worker;
    // 看守这一步：记下交出去时的进展计数，到点时还没变就是卡住了。
    m_stallWorker = worker;
    m_stallGeneration = generation;
    m_stallMark = worker->progress();
    m_stallTimer.start(m_options.stallTimeoutMs);
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
    m_continueRequested = false;
    m_cycleFlushOnly = m_backgroundFlushPending && !m_foreground;
    m_backgroundFlushPending = false;
    m_warnings.clear();
    // 每一轮开始先把目标已经在本机的「待接回引用」接上：目标可能是本机自己生成回来的
    // （例行实例收回后当天又启用），这时不一定等得到对方的批次。只动本机库，与同步文件夹无关。
    const SyncStore::ApplyResult relinked = store().resolvePendingReferences();
    if (relinked.ok && hasVisibleChanges(relinked)) {
        notify(relinked);
    }
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
    // 本机自己建的文件夹，只是库里没记下（例如建完标记文件后立即崩溃、或恢复了建文件夹之前的备份）：
    // 同一事务内绑定 folder_id、重置旧文件夹传输记账并置位 snapshot_needed，确保必发首份基线快照供对端加入。
    if (result.marker.createdBy == s.deviceId()) {
        if (!s.attachOwnFolder(result.marker.folderId, true)) {
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
    SyncStore pre = store();
    // 先于写标记文件落盘 snapshot_needed：即使标记文件已写出后进程立刻中断，下次启动也会补发首份基线快照。
    if (!pre.requestFullSnapshot()) {
        return finishCycle(Status::Error, QStringLiteral("记不下新建同步文件夹的初始快照标记"));
    }
    SyncFiles::Marker marker;
    marker.folderId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    marker.createdBy = pre.deviceId();
    marker.createdAt = QDateTime::currentDateTime().toString(Qt::ISODate);
    runOnWorker<SyncFolder::Error>(
        [marker](SyncWorker& worker) { return worker.createMarker(marker); },
        [this, marker](const SyncFolder::Error& error) {
            if (!error.ok()) {
                return finishCycle(statusFor(error), error.message);
            }
            // 在同一事务内绑定 folder_id、重置可能残留的旧文件夹传输记账并保持 snapshot_needed。
            if (!store().attachOwnFolder(marker.folderId, true)) {
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
                SyncStore s = store();
                QList<SyncWorker::CorruptedSnapshot> bads = fetch.corruptedCandidates;
                if (bads.isEmpty() && !fetch.device.isEmpty()) {
                    bads.append({fetch.device, fetch.position, fetch.parseError});
                }
                const QString detail = QStringLiteral("起步用的快照读不出来：%1").arg(fetch.parseError);
                if (bads.isEmpty()) {
                    return finishCycle(Status::WaitingForSnapshot, detail);
                }
                // 首次加入时若起步快照全部损坏：不持久化 folder_id 且保留 m_joinConfirmed，
                // 主动写出带 snapshotRequests 的游标文件请对方在下次维护时重写快照，避免死等。
                const qint64 wallNow = wallClockMs();
                SyncFiles::CursorFile cursor;
                cursor.device = s.deviceId();
                cursor.epoch = s.epoch();
                cursor.writtenAtMs = wallNow;
                for (const auto& bad : bads) {
                    const QString path = SyncFiles::deviceDirectory(bad.device) + QLatin1Char('/')
                        + SyncFiles::snapshotFileName(bad.position);
                    if (!m_loggedBadFiles.contains(path) && s.logFileProblem(bad.device, path, bad.error)) {
                        m_loggedBadFiles.insert(path);
                    }
                    const auto existing = cursor.snapshotRequests.constFind(bad.device);
                    if (existing == cursor.snapshotRequests.cend()
                        || bad.position.epoch > existing->epoch
                        || (bad.position.epoch == existing->epoch && bad.position.seq > existing->seq)) {
                        cursor.snapshotRequests.insert(bad.device, bad.position);
                    }
                }
                runOnWorker<SyncFolder::Error>(
                    [cursor](SyncWorker& worker) { return worker.writeCursor(cursor); },
                    [this, detail, wallNow](const SyncFolder::Error& error) {
                        if (!error.ok()) {
                            return finishCycle(statusFor(error), error.message);
                        }
                        m_lastCursorWrittenMs = wallNow;
                        finishCycle(Status::WaitingForSnapshot, detail);
                    });
                return;
            }
            Status failure = Status::Error;
            QString error;
            const QPointer<SyncEngine> self(this);
            const quint64 generation = m_generation;
            const bool replaced = replaceFromSnapshot(fetch.device, fetch.snapshot, folderId, true, &failure, &error);
            if (!self || m_generation != generation) {
                return;
            }
            if (!replaced) {
                // 安全备份或换库事务失败时整笔回滚，本机数据原样保留；这次确认随之作废。
                // 否则退避重试会在用户看到报错、以为没加入并继续记新内容之后，不再询问就拿文件夹数据覆盖本机。
                // 只作废这一路：快照还没到（WaitingForSnapshot）时仍按「确认一次就够」等它到达。
                m_joinConfirmed = false;
                return finishCycle(failure, error);
            }
            publishStep();
        });
}

bool SyncEngine::replaceFromSnapshot(const QString& source, const SyncFiles::SnapshotFile& snapshot,
                                     const QString& folderIdToSet, bool resetFolderTransportState,
                                     Status* failure, QString* error)
{
    const QPointer<SyncEngine> self(this);
    const quint64 generation = m_generation;
    // 草稿保存和安全备份可能同步发出界面信号，回调期间停机或换目录即中止本次替换。
    if (const auto backup = m_safetyBackup) {
        QString backupError;
        const bool saved = backup(&backupError);
        if (!self || m_generation != generation) {
            return false;
        }
        if (!saved) {
            *failure = Status::BackupFailed;
            *error = backupError;
            return false;
        }
    }
    SyncStore s = store();
    const QString me = s.deviceId();
    // 游标重新起步：快照的来源读到它自己的第 coveredSeq 批；别的设备按快照里记的进度接着读。
    // 连同 folder_id、清旧补发请求与旧文件夹传输记账放入同一事务，杜绝换库成功但记账失败导致重复换库。
    QHash<QString, SyncPosition> cursors = positionsInEpoch(snapshot.applied, snapshot.batch.epoch);
    cursors.remove(me);
    cursors.insert(source, {snapshot.batch.epoch, snapshot.coveredSeq});
    SyncStore::SnapshotReplaceOptions options;
    options.folderIdToSet = folderIdToSet;
    options.peerCursors = std::move(cursors);
    options.clearSnapshotRequests = true;
    options.resetFolderTransportState = resetFolderTransportState;

    const SyncStore::ApplyResult result = s.replaceWithSnapshot(snapshot.batch, options);
    if (!result.ok) {
        *failure = Status::Error;
        *error = result.error;
        return false;
    }
    // 事务已提交：首次加入确认立即消费，避免后续槽函数或下一轮误判仍处于待确认加入状态。
    if (!folderIdToSet.isEmpty()) {
        m_joinConfirmed = false;
    }
    m_cursorDirty = true;
    // 本机旧纪元的文件、旧快照都用不上了，这一轮就清掉。
    m_maintenanceDue = true;
    m_gapSinceMs.clear();
    // 先让界面与外部写入会话丢弃旧库身份，再通知具体模型刷新。
    emit snapshotReplaced();
    if (!self) {
        return false;
    }
    notify(result);
    return m_generation == generation;
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
    // 要求立即写、但没有东西可写：标记清掉，免得之后某一轮绕过攒批间隔提前写。
    m_flushRequested = false;
    if (m_cycleFlushOnly) {
        return finishCycle();
    }
    scanStep();
}

void SyncEngine::publishFullSnapshot()
{
    SyncStore s = store();
    bool ok = false;
    QString exportError;
    const SyncBatch snapshotBatch = s.exportSnapshot(&ok, &exportError);
    if (!ok) {
        return finishCycle(Status::Error,
                           exportError.isEmpty() ? QStringLiteral("导出全量快照失败") : exportError);
    }
    SyncFiles::SnapshotFile file;
    file.batch = snapshotBatch;
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
            // 所以它已经带上的待发送改动不必再单独发一遍；与 snapshot_position 在同一事务内原子落地。
            if (!s.markSnapshotPublished(file.batch, written.position)) {
                return finishCycle(Status::Error, QStringLiteral("记不下已经写出的快照"));
            }
            m_lastWrittenPath = written.path;
            m_lastPublishMs = nowMs();
            if (m_cycleFlushOnly) {
                return finishCycle();
            }
            scanStep();
        });
}

void SyncEngine::publishChanges()
{
    SyncStore s = store();
    const SyncStore::PendingChunkResult chunk =
        s.collectPendingChunk(SyncFiles::kSoftChangesBytes, SyncFiles::kMaxChangesBytes);
    if (!chunk.ok) {
        return finishCycle(Status::Error,
                           chunk.error.isEmpty() ? QStringLiteral("读取待发送改动失败") : chunk.error);
    }
    if (chunk.oversizeSingleRecord) {
        // 单条记录本身超过 8 MiB 硬上限无法拆入合法文件：报警提示但不阻断本轮继续拉取远端小改动。
        m_flushRequested = false;
        warn(Status::Error, chunk.oversizeDetail);
        return m_cycleFlushOnly ? finishCycle() : scanStep();
    }
    // 队列里只剩读不出来的记录（外部改过库），没有东西可写。
    if (chunk.batch.isEmpty()) {
        m_flushRequested = false;
        return m_cycleFlushOnly ? finishCycle() : scanStep();
    }
    const SyncBatch batch = chunk.batch;
    const bool hasMore = chunk.hasMore;
    const SyncPosition outbound = s.outboundPosition();
    const qint64 lastSeq = outbound.epoch == batch.epoch ? outbound.seq : 0;
    const qint64 writtenAt = wallClockMs();
    runOnWorker<SyncWorker::WriteResult>(
        [batch, lastSeq, writtenAt](SyncWorker& worker) { return worker.writeChanges(batch, lastSeq, writtenAt); },
        [this, batch, hasMore](const SyncWorker::WriteResult& written) {
            if (!written.error.ok()) {
                return finishCycle(statusFor(written.error), written.error.message);
            }
            SyncStore s = store();
            // 文件已经写出去了：在同一事务内原子推进序号并确认本批出队。
            if (!s.acknowledgeOutbound(batch, written.position)) {
                return finishCycle(Status::Error, QStringLiteral("改动已写出，但记不下发送进度"));
            }
            m_lastWrittenPath = written.path;
            m_lastPublishMs = nowMs();
            if (hasMore) {
                // 还有剩余积压待发：后台「只写不读」在有限窗口内连续冲刷；
                // 前台正常轮次先进入 scanStep 拉取对方小改动，本轮收尾后再通过 m_continueRequested 续发下一批。
                m_flushRequested = true;
                if (m_cycleFlushOnly) {
                    return publishChanges();
                }
                m_continueRequested = true;
            } else {
                m_flushRequested = false;
            }
            if (m_cycleFlushOnly) {
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
    request.requests = s.snapshotRequests();
    request.maxFiles = m_options.maxFilesPerScan;
    request.catchUpViaSnapshot = m_options.catchUpViaSnapshot;
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
    if (result.adoption.needed) {
        return adopt(result.adoption);
    }
    SyncStore s = store();
    const qint64 epoch = s.epoch();
    const qint64 now = nowMs();
    QHash<QString, SyncPosition> requests = s.snapshotRequests();
    const QHash<QString, SyncPosition> cursors = s.peerCursors();
    // 请对方补一份至少覆盖到 seq 的快照。只往后推、不往前退：覆盖得更远的快照也覆盖了前面的。
    const auto requestSnapshot = [&](const QString& device, qint64 seq) -> bool {
        const SyncPosition current = requests.value(device);
        if (current.epoch == epoch && current.seq >= seq) {
            return true;
        }
        // 请求必须先落盘，游标文件才发得出去；否则跳过坏批次后会永久丢掉补发意图。
        if (!s.setSnapshotRequest(device, {epoch, seq})) {
            return false;
        }
        requests.insert(device, {epoch, seq});
        m_cursorDirty = true;
        return true;
    };
    SyncStore::ApplyResult total;
    for (const SyncWorker::PeerScan& peer : result.peers) {
        const SyncPosition cursor = cursors.value(peer.device);
        qint64 applied = cursor.epoch == epoch ? cursor.seq : 0;
        if (peer.snapshotStatus == SyncFiles::ParseStatus::NewerFormat) {
            warn(Status::NewerVersion, peer.snapshotError);
        } else if (peer.snapshotStatus == SyncFiles::ParseStatus::Corrupt && peer.readError.ok()) {
            // 需要的快照坏了：请求重写它本身覆盖的位置；对方没有新批次时，N+1 根本不存在，无法响应。
            const QString path = SyncFiles::deviceDirectory(peer.device) + QLatin1Char('/')
                + SyncFiles::snapshotFileName(peer.snapshotPosition);
            if (!m_loggedBadFiles.contains(path)) {
                m_loggedBadFiles.insert(path);
                s.logFileProblem(peer.device, path, peer.snapshotError);
                // 即使缺号时已经请求过同一位置，也要刷新游标指纹，让发送端知道刚补的快照仍不可读。
                m_cursorDirty = true;
            }
            if (!requestSnapshot(peer.device, peer.snapshotPosition.seq)) {
                warn(Status::Error, QStringLiteral("记不下快照补发请求，下一轮重试"));
            }
            warn(Status::Error, QStringLiteral("%1 读不懂：%2").arg(path, peer.snapshotError));
        }
        bool stopped = false;
        if (peer.hasSnapshot) {
            // 合并快照和逐批应用结果相同：记录都带着字段版本，本机已经有的不会被改动。
            const SyncStore::ApplyResult merged = s.applyRemote(peer.snapshot.batch);
            if (!merged.ok) {
                warn(Status::Error, merged.error);
                stopped = true;
            } else {
                mergeResult(&total, merged);
                applied = std::max(applied, peer.snapshotPosition.seq);
                stopped = !s.setPeerCursor(peer.device, {epoch, applied});
                m_cursorDirty = true;
                const SyncPosition request = requests.value(peer.device);
                if (request.epoch != epoch || request.seq <= peer.snapshotPosition.seq) {
                    requests.remove(peer.device);
                    s.clearSnapshotRequest(peer.device);
                }
            }
        }
        for (const SyncWorker::IncomingFile& file : peer.files) {
            if (stopped) {
                break;
            }
            if (file.kind == SyncWorker::IncomingFile::Kind::Newer) {
                warn(Status::NewerVersion, file.error);
                break;
            }
            if (file.kind == SyncWorker::IncomingFile::Kind::Corrupt) {
                // 坏文件：写完整了还是坏的，重读也不会变好。跳过它、记进同步日志，并请对方补一份
                // 覆盖到这一批的快照，把这批里的改动带回来。停在这里等的话，一个坏文件就会让同步永远卡住。
                s.logFileProblem(peer.device, file.path, file.error);
                if (!requestSnapshot(peer.device, file.seq)) {
                    warn(Status::Error, QStringLiteral("记不下补发请求，停在这一批，下一轮重试"));
                    break;
                }
                if (!s.setPeerCursor(peer.device, {epoch, file.seq})) {
                    warn(Status::Error, QStringLiteral("记不下读取进度"));
                    break;
                }
                m_cursorDirty = true;
                warn(Status::Error, QStringLiteral("%1 读不懂，已跳过并请对方补发：%2").arg(file.path, file.error));
                continue;
            }
            // 每批一个事务；提交之后才记「读到了第几批」。先记后提交的话，中途失败就会漏掉这一批。
            const SyncStore::ApplyResult appliedBatch = s.applyRemote(file.batch);
            if (!appliedBatch.ok) {
                warn(Status::Error, appliedBatch.error);
                break;
            }
            mergeResult(&total, appliedBatch);
            if (!s.setPeerCursor(peer.device, {epoch, file.seq})) {
                warn(Status::Error, QStringLiteral("记不下读取进度"));
                break;
            }
            m_cursorDirty = true;
        }
        if (!peer.readError.ok()) {
            warn(statusFor(peer.readError), peer.readError.message);
        }
        // 某一批迟迟不到（它后面的已经到了）：多半是 iCloud 还在送，等一会儿；
        // 等太久就请对方补一份快照，免得一个丢了的文件让同步永远停在这里。
        if (peer.waitingFor > 0) {
            const qint64 since = m_gapSinceMs.value(peer.device, now);
            m_gapSinceMs.insert(peer.device, since);
            if (now - since >= m_options.gapRequestAfterMs) {
                if (!requestSnapshot(peer.device, peer.waitingFor)) {
                    warn(Status::Error, QStringLiteral("记不下缺号补发请求，下一轮重试"));
                }
            }
        } else {
            m_gapSinceMs.remove(peer.device);
        }
    }
    if (total.ok && hasVisibleChanges(total)) {
        notify(total);
    }
    // 这一轮读满了上限：本轮若成功收尾则紧接着再来一轮，不等下一个扫描间隔；若中途失败则清零遵守退避。
    if (result.more) {
        m_continueRequested = true;
    }
    writeCursorStep();
}

void SyncEngine::adopt(const SyncWorker::Adoption& adoption)
{
    if (!adoption.ready) {
        if (adoption.status == SyncFiles::ParseStatus::NewerFormat) {
            return finishCycle(Status::NewerVersion, adoption.error);
        }
        if (adoption.status == SyncFiles::ParseStatus::Corrupt && !adoption.device.isEmpty()) {
            SyncStore s = store();
            QList<SyncWorker::Adoption::CorruptedCandidate> bads = adoption.corruptedCandidates;
            if (bads.isEmpty()) {
                bads.append({adoption.device, adoption.position, adoption.error});
            }
            QHash<QString, SyncPosition> highestPerDevice;
            for (const auto& bad : bads) {
                const QString path = SyncFiles::deviceDirectory(bad.device) + QLatin1Char('/')
                    + SyncFiles::snapshotFileName(bad.position);
                if (!m_loggedBadFiles.contains(path)) {
                    if (s.logFileProblem(bad.device, path, bad.error)) {
                        m_loggedBadFiles.insert(path);
                    }
                }
                const auto existing = highestPerDevice.constFind(bad.device);
                if (existing == highestPerDevice.cend()
                    || bad.position.epoch > existing->epoch
                    || (bad.position.epoch == existing->epoch && bad.position.seq > existing->seq)) {
                    highestPerDevice.insert(bad.device, bad.position);
                }
            }
            for (auto it = highestPerDevice.cbegin(); it != highestPerDevice.cend(); ++it) {
                if (!s.setSnapshotRequest(it.key(), it.value())) {
                    return finishCycle(Status::Error, QStringLiteral("无法记录快照请求"));
                }
            }
            m_cursorDirty = true;
            const QString firstPath = SyncFiles::deviceDirectory(adoption.device) + QLatin1Char('/')
                + SyncFiles::snapshotFileName(adoption.position);
            const QString errDetail = QStringLiteral("%1 读不懂：%2").arg(firstPath, adoption.error);

            // 写出覆盖高 epoch 的 snapshot request（writeCursor 不能把这个高 epoch 请求按本机旧 epoch 过滤掉）
            const qint64 wallNow = wallClockMs();
            const SyncFiles::CursorFile cursor = buildCursorFile(s, wallNow);

            runOnWorker<SyncFolder::Error>(
                [cursor](SyncWorker& worker) { return worker.writeCursor(cursor); },
                [this, errDetail, wallNow](const SyncFolder::Error& error) {
                    if (!error.ok()) {
                        return finishCycle(statusFor(error), error.message);
                    }
                    m_cursorDirty = false;
                    m_lastCursorWrittenMs = wallNow;
                    finishCycle(Status::Error, errDetail);
                });
            return;
        }
        if (!adoption.device.isEmpty() && adoption.position.epoch > store().epoch()) {
            SyncStore s = store();
            if (!s.setSnapshotRequest(adoption.device, adoption.position)) {
                return finishCycle(Status::Error, QStringLiteral("无法记录快照请求"));
            }
            m_cursorDirty = true;
            const qint64 wallNow = wallClockMs();
            const SyncFiles::CursorFile cursor = buildCursorFile(s, wallNow);

            runOnWorker<SyncFolder::Error>(
                [cursor](SyncWorker& worker) { return worker.writeCursor(cursor); },
                [this, wallNow](const SyncFolder::Error& error) {
                    if (!error.ok()) {
                        return finishCycle(statusFor(error), error.message);
                    }
                    m_cursorDirty = false;
                    m_lastCursorWrittenMs = wallNow;
                    finishCycle(Status::WaitingForSnapshot,
                                QStringLiteral("另一台设备恢复了备份，正在等它的数据传过来"));
                });
            return;
        }
        // 对方恢复了备份、新纪元的改动先到了，快照还在路上：这一轮什么都不应用，等快照。
        return finishCycle(Status::WaitingForSnapshot,
                           QStringLiteral("另一台设备恢复了备份，正在等它的数据传过来"));
    }
    Status failure = Status::Error;
    QString error;
    const QPointer<SyncEngine> self(this);
    const quint64 generation = m_generation;
    const bool replaced = replaceFromSnapshot(adoption.device, adoption.snapshot, QString(), false, &failure, &error);
    if (!self || m_generation != generation) {
        return;
    }
    if (!replaced) {
        return finishCycle(failure, error);
    }
    // 换到新纪元之后，本机的游标文件、旧文件都要跟着更新：紧接着再来一轮。
    m_continueRequested = true;
    finishCycle();
}

void SyncEngine::writeCursorStep()
{
    const qint64 wallNow = wallClockMs();
    // 没有变化也每天写一次：对方看游标文件多久没更新，来判断本机是不是已经不用了。
    const bool refresh = m_lastCursorWrittenMs < 0 || wallNow - m_lastCursorWrittenMs >= 24LL * 60 * 60 * 1000;
    if (!m_cursorDirty && !refresh) {
        return maintenanceStep();
    }
    const SyncFiles::CursorFile cursor = buildCursorFile(store(), wallNow);
    runOnWorker<SyncFolder::Error>(
        [cursor](SyncWorker& worker) { return worker.writeCursor(cursor); },
        [this, wallNow](const SyncFolder::Error& error) {
            if (!error.ok()) {
                return finishCycle(statusFor(error), error.message);
            }
            m_cursorDirty = false;
            m_lastCursorWrittenMs = wallNow;
            maintenanceStep();
        });
}

void SyncEngine::maintenanceStep()
{
    const qint64 now = nowMs();
    const bool due = m_maintenanceDue || m_lastMaintenanceMs < 0
        || now - m_lastMaintenanceMs >= m_options.maintenanceIntervalMs;
    if (!due) {
        return finishCycle();
    }
    const QString me = store().deviceId();
    runOnWorker<SyncWorker::Survey>([me](SyncWorker& worker) { return worker.survey(me); },
                                    [this](const SyncWorker::Survey& survey) { afterSurvey(survey); });
}

void SyncEngine::afterSurvey(const SyncWorker::Survey& survey)
{
    if (!survey.error.ok()) {
        return finishCycle(statusFor(survey.error), survey.error.message);
    }
    SyncStore s = store();
    const QString me = s.deviceId();
    const qint64 epoch = s.epoch();
    const SyncPosition outbound = s.outboundPosition();
    const qint64 written = outbound.epoch == epoch ? outbound.seq : 0;
    const SyncPosition snapshot = s.snapshotPosition();
    // 区分「尚未写过任何快照」与「纪元 0 第 0 批」，并核对目录里确实存在该快照文件，
    // 避免未写过快照或远端快照缺失时 covered 误判为 0 而漏响应对端补快照请求。
    const bool snapshotPresent = s.hasSnapshotPosition() && snapshot.epoch == epoch
        && survey.ownSnapshots.contains(snapshot);
    const qint64 covered = snapshotPresent ? snapshot.seq : -1;

    // 要不要写一份新快照：
    // - 有设备请本机补（读到了本机的坏文件，或者本机的某一批它一直没收到）；
    // - 自上一份快照以来又写了很多批：有了新快照，这些旧改动文件才能删。
    bool needed = false;
    QHash<QString, ServedRequestFingerprint> pendingFingerprints;
    for (const SyncWorker::PeerCursor& peer : survey.peers) {
        if (!peer.present || peer.status != SyncFiles::ParseStatus::Ok
            || !peer.cursor.snapshotRequests.contains(me)) {
            continue;
        }
        const SyncPosition request = peer.cursor.snapshotRequests.value(me);
        if (request.epoch != epoch) {
            continue;
        }
        if (peer.cursor.epoch == epoch) {
            const ServedRequestFingerprint fp{peer.cursor.writtenAtMs, request};
            // 普通缺号请求仍要求序号已经写过；服务成功也要记指纹，因为请求在对方收到快照前还会保留。
            if (request.seq > covered && request.seq <= written) {
                needed = true;
                pendingFingerprints.insert(peer.device, fp);
            } else if (covered >= 0 && request.seq == covered && request.seq <= written
                       && m_servedSnapshotRequests.value(peer.device) != fp) {
                // 请求现有快照的位置表示它读不了这份快照；不能用尚未存在的 N+1 表示重写。
                // 同一指纹只补一次，普通缺号分支也登记指纹，避免刚补成后又因覆盖位置相等而多写一次。
                needed = true;
                pendingFingerprints.insert(peer.device, fp);
            }
        } else if (peer.cursor.epoch < epoch) {
            // 单独允许 peer.cursor.epoch < 本机 epoch、request.epoch 等于本机 epoch、
            // request.seq 在本机已写出范围内的恢复请求，即使 seq <= covered 也重写。
            // 用内存记录每个 peer 已成功服务的请求指纹（cursor.writtenAtMs 和 request 位置），相同指纹不重复重写。
            if (request.seq >= 0 && request.seq <= written) {
                const ServedRequestFingerprint fp{peer.cursor.writtenAtMs, request};
                if (m_servedSnapshotRequests.value(peer.device) != fp) {
                    needed = true;
                    pendingFingerprints.insert(peer.device, fp);
                }
            }
        }
    }
    int sinceSnapshot = 0;
    for (const SyncPosition& change : survey.ownChanges) {
        if (change.epoch == epoch && change.seq > covered) {
            ++sinceSnapshot;
        }
    }
    if (sinceSnapshot >= m_options.compactAfterFiles) {
        needed = true;
    }
    if (!needed) {
        return cleanupStep(survey);
    }

    bool ok = false;
    QString exportError;
    const SyncBatch snapshotBatch = s.exportSnapshot(&ok, &exportError);
    if (!ok) {
        return finishCycle(Status::Error,
                           exportError.isEmpty() ? QStringLiteral("导出追赶快照失败") : exportError);
    }

    SyncFiles::SnapshotFile file;
    file.batch = snapshotBatch;
    file.coveredSeq = written;
    file.writtenAtMs = wallClockMs();
    file.applied = positionsInEpoch(s.peerCursors(), epoch);
    runOnWorker<SyncWorker::WriteResult>(
        [file](SyncWorker& worker) { return worker.writeSnapshot(file); },
        [this, survey, pendingFingerprints](const SyncWorker::WriteResult& result) {
            if (!result.error.ok()) {
                return finishCycle(statusFor(result.error), result.error.message);
            }
            // 只在 writeSnapshot 成功后记录已成功服务的请求指纹
            for (auto it = pendingFingerprints.cbegin(); it != pendingFingerprints.cend(); ++it) {
                m_servedSnapshotRequests.insert(it.key(), it.value());
            }
            // 这份快照只是给落后的设备追赶、给旧文件兜底用的，不确认待发送的改动：
            // 已经跟上的设备不会读它，那些改动仍要照常写成改动文件发给它们。
            if (!store().setSnapshotPosition(result.position)) {
                return finishCycle(Status::Error, QStringLiteral("记不下已经写出的快照"));
            }
            m_lastWrittenPath = result.path;
            cleanupStep(survey);
        });
}

void SyncEngine::cleanupStep(const SyncWorker::Survey& survey)
{
    SyncStore s = store();
    const QString me = s.deviceId();
    const qint64 epoch = s.epoch();
    const SyncPosition snapshot = s.snapshotPosition();
    const bool haveSnapshot = s.hasSnapshotPosition() && snapshot.epoch == epoch;
    // 删到哪一批：必须有快照兜底（快照覆盖到的才删），还要所有还在用的设备都已经读过。
    // 对端时钟可能快慢不一，只比较本机观察同一游标指纹经过的时间；过期设备回来时从快照追上。
    const qint64 staleMs = qint64(m_options.peerStaleDays) * 24 * 60 * 60 * 1000;
    const qint64 wallNow = m_options.localWallClockMs ? m_options.localWallClockMs() : wallClockMs();
    qint64 deleteUpTo = haveSnapshot ? snapshot.seq : 0;
    for (const SyncWorker::PeerCursor& peer : survey.peers) {
        if (!peer.present) {
            // 文件确实不存在仍不等待：设备再次加入或回来缺号时有快照兜底，沿用已有清理语义。
            continue;
        }
        auto previous = s.peerObservation(peer.device);
        bool changed = !previous.has_value();
        SyncStore::PeerObservation observation = previous.value_or(
            SyncStore::PeerObservation{epoch, QStringLiteral(""), wallNow, {}});
        if (peer.status == SyncFiles::ParseStatus::Ok) {
            const SyncPosition reportedRead = peer.cursor.applied.value(me);
            // 时间戳只参与识别内容变化，不拿它减本机时间；读取位置变化也能重新开始观察。
            const QString fingerprint = QStringLiteral("%1:%2:%3:%4")
                .arg(peer.cursor.writtenAtMs).arg(peer.cursor.epoch).arg(reportedRead.epoch).arg(reportedRead.seq);
            if (observation.fingerprint != fingerprint) {
                observation.fingerprint = fingerprint;
                observation.observedAtMs = wallNow;
                // 旧纪元游标的进度不能许可删除本纪元的改动文件。
                observation.readPosition = peer.cursor.epoch == epoch ? reportedRead : SyncPosition{};
                changed = true;
            }
        }
        // 文件存在但解析失败时，沿用最后成功读取的位置；从未读到过则从位置零保守等待。
        // 本机时钟回拨时重置观察起点，不能因负时间间隔误判为过期。
        if (wallNow < observation.observedAtMs) {
            observation.observedAtMs = wallNow;
            changed = true;
        }
        if (changed && !s.setPeerObservation(peer.device, observation)) {
            deleteUpTo = 0;
            warn(Status::Error, QStringLiteral("无法保存对端观察记录，本轮保留旧改动文件"));
            break;
        }
        if (wallNow - observation.observedAtMs >= staleMs) {
            continue;
        }
        const SyncPosition read = observation.readPosition;
        deleteUpTo = std::min(deleteUpTo, read.epoch == epoch ? read.seq : 0);
    }
    runOnWorker<SyncWorker::CleanupResult>(
        [me, epoch, deleteUpTo, snapshot, haveSnapshot](SyncWorker& worker) {
            return worker.cleanup(me, epoch, deleteUpTo, snapshot, haveSnapshot);
        },
        [this](const SyncWorker::CleanupResult& result) {
            m_lastMaintenanceMs = nowMs();
            m_maintenanceDue = false;
            // 删不掉旧文件不影响同步本身，下次维护再删。
            if (!result.error.ok()) {
                warn(statusFor(result.error), result.error.message);
            }
            finishCycle();
        });
}

void SyncEngine::finishCycle(Status failure, const QString& detail)
{
    m_inCycle = false;
    // 后台那一轮写完了（成不成都一样，失败的改动还留在本机）：把后台时间还给系统。
    if (m_cycleFlushOnly) {
        endBackgroundTask();
    }
    m_cycleFlushOnly = false;
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
        // 中途失败：清除内部续跑标记（分页/拆批），严格按指数退避等待重试，防止 0ms 热自旋。
        m_continueRequested = false;
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
    // 信号回调（如传输方式切换的 waitForOneSyncThen）可能同步销毁当前引擎，
    // 每次发射信号后先核实对象仍存活，避免在已释放堆块上继续发信号或读取成员。
    const QPointer<SyncEngine> self(this);
    emit statusChanged();
    if (!self) {
        return;
    }
    emit cycleFinished();
    if (!self) {
        return;
    }
    if (m_running && (m_cycleRequested || (completed && m_continueRequested))) {
        // 放到事件循环里再开始，不在这一层调用栈里层层递归。
        QTimer::singleShot(0, this, &SyncEngine::requestCycle);
    }
}

void SyncEngine::notify(const SyncStore::ApplyResult& result)
{
    if (const auto notifier = m_notifier) {
        notifier(result);
    }
}

void SyncEngine::warn(Status status, const QString& detail)
{
    m_warnings.append({status, detail});
}

void SyncEngine::endBackgroundTask()
{
    if (m_endBackgroundTask) {
        const std::function<void()> end = std::move(m_endBackgroundTask);
        m_endBackgroundTask = nullptr;
        end();
    }
}

void SyncEngine::onStallCheck()
{
    // 已经不是交出这一步的那一轮（停下了、换了文件夹）：与这一轮无关。
    if (!m_inCycle || !m_stallWorker || m_stallGeneration != m_generation) {
        return;
    }
    const quint64 progress = m_stallWorker->progress();
    if (progress != m_stallMark) {
        // 慢，但一直在做（例如一轮要读几十个刚同步来的文件，每个约 1 秒）：接着等，从现在重新计时。
        // 只看总时长的话，慢网络下读满一轮要超时，每一轮都被放弃，就永远读不完。
        m_stallMark = progress;
        m_stallTimer.start(m_options.stallTimeoutMs);
        return;
    }
    // 卡住了：取消正在等的读写（iPad 的文件协调可以取消；Mac 上取消不了的，那一步做完时结果按代数丢掉），
    // 放弃这一轮，显示出错，按出错的间隔重试。下一轮的文件操作排在卡住的那一步后面：它要是还没回来，
    // 下一轮同样会被判定卡住、继续显示出错，而不是悄悄停住、界面还显示上次的「已同步」。
    const std::shared_ptr<SyncWorker> stuck = std::move(m_stallWorker);
    m_stallWorker.reset();
    stuck->cancelPendingIo();
    ++m_generation;
    finishCycle(Status::Error, QStringLiteral("读写同步文件夹超过 %1 秒没有进展（可能在等 iCloud 下载，或者网络不通），"
                                              "这一轮已放弃，稍后自动重试。")
                                   .arg(qMax(1, m_options.stallTimeoutMs / 1000)));
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
        && (m_flushRequested || m_lastPublishMs < 0 || now - m_lastPublishMs >= m_options.publishIntervalMs);
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
