#include "SyncController.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "SyncFiles.h"
#include "ScheduleService.h"
#include "SyncSchema.h"
#include "SyncStore.h"
#include "SyncWorker.h"
#include "SyncedSettings.h"

#include <QCoreApplication>
#include <QDebug>
#include <QFutureWatcher>
#include <QPointer>
#include <QSettings>
#include <QTimer>
#include <QtConcurrent/QtConcurrentRun>

#include <utility>

namespace {

// 这一组不在备份范围内（见 AppSettings::ownedSettingGroups），恢复备份不会改掉同步开关和书签。
const auto kEnabledKey = QStringLiteral("sync/enabled");
const auto kBookmarkKey = QStringLiteral("sync/bookmark");
const auto kFolderPathKey = QStringLiteral("sync/folderPath");

bool isProblem(SyncEngine::Status status)
{
    switch (status) {
    case SyncEngine::Status::FolderUnavailable:
    case SyncEngine::Status::WrongFolder:
    case SyncEngine::Status::FolderMissing:
    case SyncEngine::Status::NoSpace:
    case SyncEngine::Status::UploadFailed:
    case SyncEngine::Status::NewerVersion:
    case SyncEngine::Status::BackupFailed:
    case SyncEngine::Status::Error:
        return true;
    default:
        return false;
    }
}

// 日志条目的种类，给人看的说法。
QString logKindLabel(const QString& kind)
{
    if (kind == QLatin1String("edit")) {
        return QStringLiteral("同时修改");
    }
    if (kind == QLatin1String("delete")) {
        return QStringLiteral("删除优先");
    }
    if (kind == QLatin1String("merge")) {
        return QStringLiteral("科目合并");
    }
    if (kind == QLatin1String("skipped")) {
        return QStringLiteral("没能应用");
    }
    if (kind == QLatin1String("file")) {
        return QStringLiteral("文件问题");
    }
    return kind;
}

// 选择器给的是完整路径（…/Mobile Documents/com~apple~CloudDocs/番茄Todo同步），设置页一行放不下，
// 截断之后看不出是哪个文件夹。iCloud 云盘里的换成「iCloud 云盘/…」，别处的原样显示。
QString friendlyFolderPath(const QString& path)
{
    const QString iCloudDrive = QStringLiteral("com~apple~CloudDocs");
    const qsizetype at = path.indexOf(iCloudDrive);
    return at < 0 ? path : QStringLiteral("iCloud 云盘") + path.mid(at + iCloudDrive.size());
}

QString deviceLabel(bool here)
{
    return here ? QStringLiteral("这台设备") : QStringLiteral("另一台设备");
}

// 「上次同步」的时刻：今天的只写几点几分，更早的带上日期。
QString syncedAtText(const QDateTime& time)
{
    if (!time.isValid()) {
        return QString();
    }
    return time.date() == QDate::currentDate() ? time.toString(QStringLiteral("HH:mm"))
                                                : time.toString(QStringLiteral("M月d日 HH:mm"));
}

} // namespace

SyncController::SyncController(Platform platform, QObject* parent)
    : QObject(parent)
    , m_platform(std::move(platform))
{
    m_enabled = QSettings().value(kEnabledKey, false).toBool();
    // 本机改了跟着同步的设置（SyncSchema::syncedSettingKeys 与每一天的今日目标），记进库等着发出。
    // 同步写回对方的改动时这些信号也会发出，那时值与库里记下的相同，不会再记一次。
    AppSettings* settings = AppSettings::instance();
    for (const auto signal : {&AppSettings::dayStartHourChanged, &AppSettings::workMinutesChanged,
                              &AppSettings::breakMinutesChanged, &AppSettings::longBreakEnabledChanged,
                              &AppSettings::longBreakMinutesChanged, &AppSettings::longBreakIntervalChanged,
                              &AppSettings::freeTimerWarningHoursChanged, &AppSettings::nicknameChanged,
                              &AppSettings::semesterStartDateChanged, &AppSettings::semesterWeeksChanged,
                              &AppSettings::dailyFocusGoalChanged}) {
        connect(settings, signal, this, &SyncController::recordSettings);
    }
    connect(ScheduleService::instance(), &ScheduleService::periodsChanged, this, &SyncController::recordSettings);
}

SyncController::~SyncController()
{
    // 引擎的析构会等工作线程把手头的文件操作做完（最多几秒）；先于其它成员析构，
    // 免得工作线程回调时控制器已经只剩一半。
    m_engine.reset();
}

void SyncController::setSafetyBackup(std::function<bool(QString* error)> backup)
{
    m_safetyBackup = std::move(backup);
}

void SyncController::initialize()
{
    m_initialized = true;
    reconcileSettings();
    refreshLog();
    SyncStore store;
    m_knownEpoch = store.epoch();
    m_knownFolderId = store.folderId();
    // 上次退出时开着同步：接着同步。iPad 还没选过文件夹时建不出引擎，等你去选。
    if (m_enabled) {
        startEngine();
    }
    emit statusChanged();
}

void SyncController::setForeground(bool foreground)
{
    if (m_engine) {
        m_engine->setForeground(foreground);
    }
}

void SyncController::setApplicationState(Qt::ApplicationState state)
{
    // 进了后台之后，系统随时可能把应用挂起：这时才立即写出攒下的改动、向系统要一点后台时间。
    // 从应用切换器里直接划掉也不会丢改动：它们留在本机的待发送里，下次启动照常写出。
    setForeground(state != Qt::ApplicationSuspended && state != Qt::ApplicationHidden);
}

void SyncController::prepareForRestore()
{
    // 同一次恢复只记一次：记下的必须是恢复之前的样子。
    if (m_restore.pending || !DatabaseManager::instance()->isOpen()) {
        return;
    }
    // 库马上要被整个换掉：先停下同步（还在路上的结果会被丢掉），并记下恢复前的纪元、设备标识和加入的文件夹。
    SyncStore store;
    m_restore.pending = true;
    m_restore.epoch = store.epoch();
    m_restore.deviceId = store.deviceId();
    m_restore.folderId = store.folderId();
    if (m_engine) {
        m_engine->stop();
    }
    emit statusChanged();
}

void SyncController::finishRestore(bool success)
{
    // 没经过 prepareForRestore 的结束（例如另一项备份正在进行、恢复根本没开始）：库没换，什么都不用做。
    if (!m_restore.pending) {
        return;
    }
    const RestoreState before = m_restore;
    m_restore = {};
    // 恢复失败时库已经回到恢复前的样子，照原样接着同步。
    if (success && DatabaseManager::instance()->isOpen()) {
        SyncStore store;
        // 恢复备份 = 全局回滚（计划 D1）：在恢复前与备份里两者较大的纪元上加一，清空待发送，
        // 下一轮给所有设备写一份全量快照，另一台读到更高的纪元就先自动备份、再整体换成这份。
        // 设备标识改回恢复前的：备份可能来自另一台设备，两台共用一个标识会把合并搅乱。
        if (!store.beginEpochAfterRestore(before.epoch, before.deviceId)) {
            qWarning() << "Failed to start a new sync epoch after restoring a backup";
        }
        // 加入的是哪个同步文件夹，也保留恢复前的：备份可能做于加入同步之前、或者另一个同步文件夹的时候。
        // 不改回来，iPad 会把它当成第一次加入，反过来用对方的数据把刚恢复的备份整个换掉；
        // 恢复前没加入过的设备也不会因为恢复了别人的备份，就不经确认直接进了那个文件夹。
        if (store.folderId() != before.folderId && !store.setFolderId(before.folderId)) {
            qWarning() << "Failed to keep the joined sync folder after restoring a backup";
        }
        // 恢复的若是更早版本的备份，库里没记过第二期的设置：把恢复出来的本机设置记进去，
        // 下一轮写出的全量快照才带得上它们。
        reconcileSettings();
        m_knownEpoch = store.epoch();
        m_knownFolderId = store.folderId();
    }
    // 同步日志跟着库回到了备份那一刻。
    refreshLog();
    startEngine();
    emit statusChanged();
}

void SyncController::shutdown(int timeoutMs)
{
    // flushBeforeExit 先停下引擎，再同步写出最后一批；写不完的改动还留在本机，下次启动再写。
    if (m_engine && !m_engine->flushBeforeExit(timeoutMs)) {
        qWarning() << "Sync changes were not all written before exit; they stay queued for next launch";
    }
}

QString SyncController::statusKey() const
{
    if (!m_engine) {
        return QStringLiteral("stopped");
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("stopped");
    case SyncEngine::Status::Starting:
        return QStringLiteral("starting");
    case SyncEngine::Status::UpToDate:
        return QStringLiteral("upToDate");
    case SyncEngine::Status::NeedsConfirmation:
        return QStringLiteral("needsConfirmation");
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("waitingForSnapshot");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("folderUnavailable");
    case SyncEngine::Status::WrongFolder:
        return QStringLiteral("wrongFolder");
    case SyncEngine::Status::FolderMissing:
        return QStringLiteral("folderMissing");
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("noSpace");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("uploadFailed");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("newerVersion");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("backupFailed");
    case SyncEngine::Status::Error:
        return QStringLiteral("error");
    }
    return QStringLiteral("error");
}

bool SyncController::hasProblem() const
{
    return m_engine && isProblem(m_engine->status());
}

QString SyncController::summaryText() const
{
    if (!m_enabled) {
        return QStringLiteral("已关闭");
    }
    if (!m_engine) {
        return choosesFolder() ? QStringLiteral("还没有选择同步文件夹") : QStringLiteral("已暂停");
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("已暂停");
    case SyncEngine::Status::Starting:
        return QStringLiteral("正在连接同步文件夹…");
    case SyncEngine::Status::UpToDate: {
        const QString at = syncedAtText(m_engine->lastSyncedAt());
        return at.isEmpty() ? QStringLiteral("已同步") : QStringLiteral("已同步 · %1").arg(at);
    }
    case SyncEngine::Status::NeedsConfirmation:
        return QStringLiteral("等你确认加入");
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("正在等同步文件夹里的数据");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("暂时无法访问同步文件夹");
    case SyncEngine::Status::WrongFolder:
        return QStringLiteral("选中的不是同步文件夹");
    case SyncEngine::Status::FolderMissing:
        return QStringLiteral("同步文件夹不见了，同步已暂停");
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("存储空间不足");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("上传到 iCloud 失败");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("需要更新这台设备上的应用");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("自动备份没有成功，暂不替换");
    case SyncEngine::Status::Error:
        return QStringLiteral("同步出错");
    }
    return QString();
}

QString SyncController::statusText() const
{
    // 设置行里已经有一句「发生了什么」（summaryText），这里只写为什么、下一步怎么办，不把同一句话再说一遍。
    if (!m_engine) {
        return QString();
    }
    switch (m_engine->status()) {
    case SyncEngine::Status::Stopped:
        return QStringLiteral("同步暂停中，改动先留在这台设备上。");
    case SyncEngine::Status::Starting:
        return QStringLiteral("正在连接同步文件夹…");
    case SyncEngine::Status::UpToDate:
        return QStringLiteral("两台设备的数据已经一致。");
    case SyncEngine::Status::NeedsConfirmation:
        return m_engine->statusText();
    case SyncEngine::Status::WaitingForSnapshot:
        return QStringLiteral("另一台设备写的数据还在从 iCloud 传过来，到了之后会自动接着同步。");
    case SyncEngine::Status::FolderUnavailable:
        return QStringLiteral("请确认这台设备已登录 Apple ID，并打开了 iCloud 云盘。恢复之后会自动接着同步，"
                              "这期间的改动先留在本机。");
    case SyncEngine::Status::WrongFolder:
        // Mac 不选文件夹，位置是固定的：引擎给的「选错了哪一层」是写给 iPad 选择器的，在 Mac 上会让人摸不着头脑。
        // Mac 出现这个状态只有一种可能：iCloud 云盘里已经有一个同名文件夹，却不是能接上的同步文件夹。
        if (!choosesFolder()) {
            return QStringLiteral("iCloud 云盘里已经有一个「%1」文件夹，但它不是这台 Mac 能接上的同步文件夹"
                                  "（可能是以前留下的）。请在访达里把它移到别处或删除，再点「立即同步」。")
                .arg(SyncFiles::defaultFolderName());
        }
        return m_engine->statusText();
    case SyncEngine::Status::FolderMissing:
        return choosesFolder()
            ? QStringLiteral("原来选的同步文件夹被删除或移走了。Mac 重新建了同步文件夹的话，请在这里重新选择它。")
            : QStringLiteral("iCloud 云盘里的「%1」被删除或移走了。已经加入过的文件夹不会自动重建："
                             "另一台设备还认着原来那个。")
                  .arg(SyncFiles::defaultFolderName());
    case SyncEngine::Status::NoSpace:
        return QStringLiteral("改动暂时写不出去，先留在这台设备上；空出空间之后会自动写出。");
    case SyncEngine::Status::UploadFailed:
        return QStringLiteral("改动已经写进同步文件夹，但没能上传到 iCloud，可能是 iCloud 空间已满。"
                              "上传成功之前，另一台设备看不到这些改动。");
    case SyncEngine::Status::NewerVersion:
        return QStringLiteral("另一台设备用的是更新版本的番茄Todo，它写的数据这台设备读不懂。"
                              "更新这台设备上的应用之后会自动接着同步，数据不会丢。");
    case SyncEngine::Status::BackupFailed:
        return QStringLiteral("换掉本机数据之前要先自动备份，这次备份没有成功，所以没有替换。稍后会自动重试。");
    case SyncEngine::Status::Error:
        return QStringLiteral("这一轮没有做完，稍后会自动重试。");
    }
    return QString();
}

QString SyncController::statusDetail() const
{
    // 选错文件夹时，引擎把「选错了哪一层」直接写进了状态说明，这里不再重复。
    if (!m_engine || m_engine->status() == SyncEngine::Status::WrongFolder) {
        return QString();
    }
    return m_engine->statusDetail();
}

int SyncController::pendingCount() const
{
    return m_engine ? m_engine->pendingCount() : 0;
}

QDateTime SyncController::lastSyncedAt() const
{
    if (m_engine) {
        return m_engine->lastSyncedAt();
    }
    return DatabaseManager::instance()->isOpen() ? SyncStore().lastSyncedAt() : QDateTime();
}

bool SyncController::isBusy() const
{
    return m_engine && m_engine->isBusy();
}

bool SyncController::choosesFolder() const
{
    return bool(m_platform.pickFolder);
}

bool SyncController::hasFolder() const
{
    return !choosesFolder() || !storedBookmark().isEmpty();
}

QString SyncController::folderDisplayPath() const
{
    return choosesFolder() ? friendlyFolderPath(QSettings().value(kFolderPathKey).toString())
                           : m_platform.fixedFolderDisplayPath;
}

int SyncController::logCount() const
{
    return DatabaseManager::instance()->isOpen() ? SyncStore().syncLogCount() : 0;
}

void SyncController::setEnabled(bool enabled)
{
    if (!enabled) {
        setEnabledState(false);
        if (m_engine) {
            m_engine->stop();
        }
        m_joinRequested = false;
        emit statusChanged();
        return;
    }
    // iPad 还没选过文件夹：先去选，选好、校验通过才算打开（见 acceptFolder）。
    if (choosesFolder() && storedBookmark().isEmpty()) {
        chooseFolder();
        return;
    }
    setEnabledState(true);
    startEngine();
    emit statusChanged();
}

void SyncController::confirmJoin()
{
    if (!m_engine) {
        return;
    }
    m_joinRequested = true;
    m_engine->confirmJoin();
}

void SyncController::syncNow()
{
    if (m_engine) {
        m_engine->syncNow();
    }
}

void SyncController::chooseFolder()
{
    if (!m_platform.pickFolder || m_choosingFolder) {
        return;
    }
    setChoosingFolder(true);
    const QPointer<SyncController> self(this);
    m_platform.pickFolder([self](const QByteArray& bookmark, const QString& message) {
        if (!self) {
            return;
        }
        // 取消（书签与说明都为空）不提示；选择器自己出错时说明原因。
        if (bookmark.isEmpty()) {
            self->setChoosingFolder(false, message);
            return;
        }
        self->checkChosenFolder(bookmark, message);
    });
}

void SyncController::rebuildFolder()
{
    // iPad 不能建同步文件夹，只能重新选 Mac 建好的那个。
    if (choosesFolder()) {
        chooseFolder();
        return;
    }
    // 只在「已加入的文件夹不见了」时有意义：别的状态下忘掉文件夹，会让本机再走一遍加入。
    if (!m_engine || m_engine->status() != SyncEngine::Status::FolderMissing
        || !DatabaseManager::instance()->isOpen()) {
        return;
    }
    // Mac：忘掉原来加入的文件夹，下一轮按「第一次开启」处理：原处是空的（整个被删了）就新建一个，
    // 文件夹身份是新的，iPad 要重新选它并确认加入；原处还留着东西，会提示你先把它移走。
    if (!SyncStore().setFolderId(QString())) {
        qWarning() << "Failed to forget the missing sync folder";
        return;
    }
    m_knownFolderId.clear();
    m_engine->syncNow();
}

QVariantList SyncController::syncLog(int limit) const
{
    QVariantList result;
    if (!DatabaseManager::instance()->isOpen()) {
        return result;
    }
    const QDate today = QDate::currentDate();
    for (const SyncStore::LogEntry& entry : SyncStore().syncLog(limit)) {
        QVariantMap item;
        item.insert(QStringLiteral("id"), entry.id);
        item.insert(QStringLiteral("kind"), entry.kind);
        item.insert(QStringLiteral("kindLabel"), logKindLabel(entry.kind));
        item.insert(QStringLiteral("time"), !entry.loggedAt.isValid() ? QString()
                                            : entry.loggedAt.date() == today
                                                ? entry.loggedAt.toString(QStringLiteral("今天 HH:mm"))
                                                : entry.loggedAt.toString(QStringLiteral("M月d日 HH:mm")));
        // 标题：哪一条数据（文件问题是哪个文件）。
        QString title;
        if (entry.kind == QLatin1String("file")) {
            title = QStringLiteral("文件「%1」").arg(entry.recordLabel);
        } else if (!entry.recordLabel.isEmpty()) {
            title = QStringLiteral("%1「%2」").arg(entry.tableLabel, entry.recordLabel);
        } else {
            title = entry.tableLabel;
        }
        item.insert(QStringLiteral("title"), title);
        // 一句话说清楚结果：留下了谁的、谁的没有生效。
        QString summary = entry.detail;
        if (entry.kind == QLatin1String("edit") && !entry.fieldLabel.isEmpty()) {
            summary = QStringLiteral("「%1」保留了%2的「%3」，%4的「%5」没有生效。")
                          .arg(entry.fieldLabel, deviceLabel(entry.keptHere), entry.keptValue,
                               deviceLabel(entry.lostHere), entry.lostValue);
        } else if (entry.kind == QLatin1String("delete") && !entry.fieldLabel.isEmpty()) {
            // 删除赢了本机还没发出去的修改：把被丢掉的那一项写出来，需要的话可以手动补回。
            summary = QStringLiteral("%1。%2对「%3」的修改「%4」没有生效。")
                          .arg(entry.detail, deviceLabel(entry.lostHere), entry.fieldLabel, entry.lostValue);
        }
        item.insert(QStringLiteral("summary"), summary);
        item.insert(QStringLiteral("detail"), entry.detail);
        result.append(item);
    }
    return result;
}

QString SyncController::restoreWarning() const
{
    // 判据是「加入过同步文件夹」而不是开关：恢复之后开新纪元、写全量快照，是在下次同步时发生的，
    // 开关只决定这件事是马上发生、还是等你下次打开同步。
    if (!DatabaseManager::instance()->isOpen() || SyncStore().folderId().isEmpty()) {
        return QString();
    }
    return m_enabled
        ? QStringLiteral("已开启设备间同步：恢复之后，另一台设备也会回到这份备份的状态。"
                         "它会先自动备份自己的数据，这之后才换掉。")
        : QStringLiteral("这台设备加入过设备间同步（现在关着）：恢复之后，下次打开同步时，"
                         "另一台设备也会回到这份备份的状态。它会先自动备份自己的数据，这之后才换掉。");
}

void SyncController::ensureEngine()
{
    if (m_engine) {
        return;
    }
    std::unique_ptr<SyncFolder> folder = makeFolder(storedBookmark());
    if (!folder) {
        return;
    }
    m_engine = std::make_unique<SyncEngine>(std::move(folder), m_platform.engine);
    if (m_safetyBackup) {
        m_engine->setSafetyBackup(m_safetyBackup);
    }
    if (m_platform.backgroundTask) {
        m_engine->setBackgroundTaskProvider(m_platform.backgroundTask);
    }
    connect(m_engine.get(), &SyncEngine::statusChanged, this, &SyncController::statusChanged);
    connect(m_engine.get(), &SyncEngine::cycleFinished, this, &SyncController::onCycleFinished);
}

void SyncController::startEngine()
{
    // 数据库还没打开（initialize 之前）不能开始：引擎一开始就要读库里的同步进度。
    // 恢复备份进行中也不开始：库马上要被整个换掉，等 finishRestore 再开。
    if (!m_initialized || m_restore.pending || !m_enabled) {
        return;
    }
    ensureEngine();
    if (m_engine) {
        m_engine->start();
    }
}

void SyncController::setEnabledState(bool enabled)
{
    if (m_enabled == enabled) {
        return;
    }
    m_enabled = enabled;
    QSettings settings;
    settings.setValue(kEnabledKey, enabled);
    settings.sync();
    emit enabledChanged();
}

void SyncController::setChoosingFolder(bool choosing, const QString& problem)
{
    if (m_choosingFolder != choosing || m_folderProblem != problem) {
        m_choosingFolder = choosing;
        m_folderProblem = problem;
        emit choosingFolderChanged();
    }
}

void SyncController::checkChosenFolder(const QByteArray& bookmark, const QString& displayPath)
{
    // 先校验标记文件，通过了才换掉原来的书签：选错一次不会把正在用的文件夹弄丢（049 里第一次就选成了子文件夹）。
    // 校验在线程池里做：iPad 读一个刚从云端同步来的文件要先下载，约 1 秒，不能卡住界面。
    // 用一个临时的访问对象，不碰引擎正在用的那个；它刷新出来的书签也不存（校验通过后存的是选择器给的这一份）。
    // 访问对象在主线程建好再交给线程池（构造很轻，只记下书签），和引擎的用法一样；建它的工厂只在主线程里调用。
    if (!m_platform.makeFolder) {
        setChoosingFolder(false, QStringLiteral("这台设备不支持选择同步文件夹"));
        return;
    }
    const auto worker = std::make_shared<SyncWorker>(m_platform.makeFolder(bookmark, [](const QByteArray&) {}));
    auto* watcher = new QFutureWatcher<SyncWorker::OpenResult>(this);
    const quint64 attempt = ++m_folderCheckAttempt;
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher, bookmark, displayPath, attempt] {
        watcher->deleteLater();
        // 超时作废之后才回来的结果：那一次已经告诉你没响应了，你可能已经重新选了别的，不再用它。
        if (attempt != m_folderCheckAttempt || !m_choosingFolder) {
            return;
        }
        const SyncWorker::OpenResult result = watcher->result();
        if (!result.error.ok()) {
            setChoosingFolder(false, QStringLiteral("打不开选中的文件夹：%1").arg(result.error.message));
            return;
        }
        switch (result.markerState) {
        case SyncWorker::MarkerState::Present:
            setChoosingFolder(false);
            acceptFolder(bookmark, displayPath);
            return;
        case SyncWorker::MarkerState::Missing:
            // 按里面有什么推测选错了哪一层，告诉你该选哪个。
            setChoosingFolder(false, result.hint);
            return;
        case SyncWorker::MarkerState::Corrupt:
            setChoosingFolder(false, QStringLiteral("选中文件夹里的标记文件「%1」坏了：%2")
                                         .arg(SyncFiles::markerFileName(), result.markerError));
            return;
        case SyncWorker::MarkerState::Newer:
            setChoosingFolder(false, QStringLiteral("这个同步文件夹是更新版本的番茄Todo 建的，请先更新这台设备上的应用。"));
            return;
        }
    });
    // 选中的文件夹迟迟读不出来（例如断网时在等 iCloud 下载标记文件）：不能让设置页一直停在「正在检查」、
    // 按钮也一直点不了。时限与同步引擎的看门狗相同；到点就取消正在等的读、作废这一次，请你稍后再选。
    const int timeoutMs = m_platform.engine.stallTimeoutMs;
    QTimer::singleShot(timeoutMs, this, [this, worker, attempt, timeoutMs] {
        if (attempt != m_folderCheckAttempt || !m_choosingFolder) {
            return;
        }
        ++m_folderCheckAttempt;
        worker->cancelPendingIo();
        setChoosingFolder(false, QStringLiteral("读选中的文件夹超过 %1 秒没有响应（可能在等 iCloud 下载，或者网络不通），"
                                                "请稍后再选一次。原来的文件夹照常使用。")
                                     .arg(qMax(1, timeoutMs / 1000)));
    });
    watcher->setFuture(QtConcurrent::run([worker] { return worker->open(QString()); }));
}

std::unique_ptr<SyncFolder> SyncController::makeFolder(const QByteArray& bookmark)
{
    if (!m_platform.makeFolder || (choosesFolder() && bookmark.isEmpty())) {
        return nullptr;
    }
    // 书签刷新的回调在同步的工作线程里执行。带上这个文件夹是第几代，回到主线程再判断它还是不是现在用的：
    // 换了文件夹之后，排在队里的旧操作照样会跑完，它刷新出来的旧书签不能把新选的盖掉。
    const quint64 generation = ++m_folderGeneration;
    const QPointer<SyncController> self(this);
    return m_platform.makeFolder(bookmark, [self, generation](const QByteArray& refreshed) {
        QCoreApplication* app = QCoreApplication::instance();
        if (!app) {
            return;
        }
        // 投递到主线程执行；控制器那时已经销毁的话，QPointer 为空，什么都不做。
        QMetaObject::invokeMethod(
            app,
            [self, generation, refreshed] {
                if (self) {
                    self->onBookmarkRefreshed(generation, refreshed);
                }
            },
            Qt::QueuedConnection);
    });
}

QByteArray SyncController::storedBookmark() const
{
    return QSettings().value(kBookmarkKey).toByteArray();
}

void SyncController::acceptFolder(const QByteArray& bookmark, const QString& displayPath)
{
    QSettings settings;
    settings.setValue(kBookmarkKey, bookmark);
    settings.setValue(kFolderPathKey, displayPath);
    settings.sync();
    // 引擎已经在用别的文件夹：换上新的，正在进行的一轮作废。选中的若是另一个同步文件夹，
    // 下一轮会停在「等你确认加入」；还是原来那个，就接着同步。还没有引擎的，打开同步时按新书签建。
    if (m_engine) {
        m_engine->setFolder(makeFolder(bookmark));
    }
    emit folderChanged();
    setEnabledState(true);
    startEngine();
    emit statusChanged();
}

void SyncController::onBookmarkRefreshed(quint64 folderGeneration, const QByteArray& bookmark)
{
    // 只存现在用的这个文件夹刷新出来的书签。换过文件夹以后，排在队里的旧操作刷新的是旧文件夹的书签。
    if (folderGeneration != m_folderGeneration || bookmark.isEmpty()) {
        return;
    }
    QSettings settings;
    settings.setValue(kBookmarkKey, bookmark);
    settings.sync();
}

void SyncController::onCycleFinished()
{
    SyncStore store;
    const qint64 epoch = store.epoch();
    const QString folderId = store.folderId();
    if (m_joinRequested && !folderId.isEmpty() && folderId != m_knownFolderId) {
        m_joinRequested = false;
        emit notice(QStringLiteral("已加入同步：本机数据已换成同步文件夹里的，原来的数据已自动备份。"));
    } else if (m_knownFolderId.isEmpty() && !folderId.isEmpty() && !choosesFolder()) {
        emit notice(QStringLiteral("已在 iCloud 云盘建好「%1」文件夹。到 iPad 上选这个文件夹，就能加入同步。")
                        .arg(SyncFiles::defaultFolderName()));
    } else if (m_knownEpoch >= 0 && epoch != m_knownEpoch && folderId == m_knownFolderId) {
        // 纪元变了、文件夹没换：另一台设备恢复了备份，本机跟着整体换成了它的数据（换之前已自动备份）。
        emit notice(QStringLiteral("另一台设备恢复了备份，这台设备已跟着回到那份备份的状态（换之前已自动备份）。"));
    }
    m_knownEpoch = epoch;
    m_knownFolderId = folderId;
    refreshLog();
}

void SyncController::refreshLog()
{
    if (!DatabaseManager::instance()->isOpen()) {
        return;
    }
    // 只在有新记录（或者库被整个换掉、日志回到了别的样子）时通知界面重新读，不是每轮同步都刷。
    const qint64 latest = SyncStore().latestSyncLogId();
    if (latest != m_lastLogId) {
        m_lastLogId = latest;
        ++m_logRevision;
        emit logChanged();
    }
}

void SyncController::recordSettings()
{
    // 启动核对之前不记：initialize 会按库里记下的和本机设置一起核对一遍。
    // 同步正在把对方的值写回本机时也不记：那时的变更信号不是本机改动（见 SyncedSettings::WriteBackScope）。
    if (!m_initialized || SyncedSettings::isWritingBack() || !DatabaseManager::instance()->isOpen()) {
        return;
    }
    SyncStore store;
    const QHash<QString, QString> synced = store.syncedSettings();
    const QHash<QString, QString> local = SyncedSettings::currentValues();
    for (auto it = local.cbegin(); it != local.cend(); ++it) {
        // 先和库里的比：今日目标一天一项，每次都逐项开事务去比太浪费。值没变的不是本机改动。
        const auto known = synced.constFind(it.key());
        if (known != synced.constEnd() && known.value() == it.value()) {
            continue;
        }
        if (!store.recordLocalSetting(it.key(), it.value(), SyncedSettings::isFactoryDefault(it.key(), it.value()))) {
            qWarning() << "Failed to record a synced setting:" << it.key();
        }
    }
}

void SyncController::reconcileSettings()
{
    if (!DatabaseManager::instance()->isOpen()) {
        return;
    }
    SyncStore store;
    const QHash<QString, QString> synced = store.syncedSettings();
    const QHash<QString, QString> pending = store.pendingSettingWriteBacks();
    QHash<QString, QString> local = SyncedSettings::currentValues();
    const auto isRemoval = [](const QString& kind) { return kind == QLatin1String("remove"); };
    // 库里记的和本机设置不一致，有两种来由，靠「待写回」标记分辨（标记和对方的值在同一个事务里进库）：
    // - 有标记：对方的改动进了库、还没写回本机就被结束了。以库为准写回（「今天」是哪天、番茄多长才和另一台一致）。
    // - 没有标记：本机改了设置，却没记进库（记录失败：库被别的连接长时间占着而等待超时、磁盘满……）。
    //   这时以本机为准，下面补记一个新版本；以前一律以库为准，会把你的改动在下次启动时悄悄改回去。
    // 库里有、本机却没有的项（例如某一天的今日目标）没有本机的值可留，同样以库为准。
    {
        const SyncedSettings::WriteBackScope writingBack;
        for (auto it = pending.cbegin(); it != pending.cend(); ++it) {
            if (isRemoval(it.value())) {
                SyncedSettings::remove(it.key());
            } else if (synced.contains(it.key()) && local.value(it.key()) != synced.value(it.key())
                       && !SyncedSettings::apply(it.key(), synced.value(it.key()))) {
                qWarning() << "Failed to write back a synced setting:" << it.key();
            }
        }
        for (auto it = synced.cbegin(); it != synced.cend(); ++it) {
            if (!pending.contains(it.key()) && SyncSchema::isSyncedSettingKey(it.key()) && !local.contains(it.key())
                && !SyncedSettings::apply(it.key(), it.value())) {
                qWarning() << "Failed to write back a synced setting:" << it.key();
            }
        }
    }
    local = SyncedSettings::currentValues();
    // 写回真的成了的，清掉标记；没成的（取值写不回本机、偏好文件写不进去）留着，下次启动再试，
    // 也不拿本机的值去盖它——那多半是对方的取值本机认不得（例如更新版本的写法），不能反过来把它改掉。
    QSet<QString> unresolved;
    for (auto it = pending.cbegin(); it != pending.cend(); ++it) {
        const bool done = isRemoval(it.value())
            // 固定的几项不删（保留本机的值，下面按本机的记进库）；今日目标要确认真的删掉了。
            ? (SyncSchema::dailyGoalDateOf(it.key()).isEmpty() || !local.contains(it.key()))
            : (!synced.contains(it.key()) || local.value(it.key()) == synced.value(it.key()));
        if (done) {
            store.finishSettingWriteBack(it.key());
        } else {
            unresolved.insert(it.key());
        }
    }
    // 本机的值库里没记、或记的不一样（又不是在等写回的）：以本机为准记一个新版本、等着发出。
    // 库里还没有的（刚升级、新装、恢复了更早版本的备份）也走这里。还是出厂默认值的用最小版本，
    // 另一台设备改过的设置会盖过它，而不是反过来被这个默认值盖掉。
    for (auto it = local.cbegin(); it != local.cend(); ++it) {
        const auto known = synced.constFind(it.key());
        if (unresolved.contains(it.key()) || (known != synced.constEnd() && known.value() == it.value())) {
            continue;
        }
        if (!store.recordLocalSetting(it.key(), it.value(), SyncedSettings::isFactoryDefault(it.key(), it.value()))) {
            qWarning() << "Failed to record a synced setting:" << it.key();
        }
    }
}
