#include <QDir>
#include <QFile>
#include <QMutex>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScopeGuard>
#include <QSettings>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>
#include <QWaitCondition>
#include <QtTest>

#include <functional>
#include <memory>
#include <cstdio>

#include "../src/services/AppSettings.h"
#include "../src/services/BackupService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/MemoService.h"
#include "../src/services/ScheduleService.h"
#include "../src/services/SyncController.h"
#include "../src/services/SyncEngine.h"
#include "../src/services/SyncFiles.h"
#include "../src/services/SyncNotifier.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/SyncStore.h"
#include "../src/services/TaskManager.h"

// 设备间同步接进应用（050 阶段 4）的测试：SyncController 怎么开关同步、怎么和恢复备份、逻辑日起点、
// 前后台、退出衔接，iPad 怎么选文件夹，同步日志怎么给人看。
//
// 「这台设备」用应用主连接（DatabaseManager），和正式运行时一样，SyncController 与各服务单例都读写它。
// 需要另一台设备时，另开一个真实结构的临时库和它自己的 SyncEngine。两台共用一个临时目录当同步文件夹：
// iCloud 的延迟与乱序由 SyncTransportTests 负责，这里只看接线。
// 引擎的定时器拨到一小时，一轮同步只在测试调用 syncNow 或引擎被要求同步时发生。
namespace {

const QString kTaskDate = QStringLiteral("2026-09-30");

void configurePreferences(const QString& directory)
{
    // 父进程与重启探针使用同一临时INI，避免Qt进程内缓存掩盖旧磁盘值。
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoSyncControllerTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SyncControllerTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, directory);
}

SyncEngine::Options testOptions()
{
    SyncEngine::Options options;
    // 定时器拨到一小时：一轮同步只在测试要求时发生，结果不受跑测试时的快慢影响。
    options.tickMs = 60 * 60 * 1000;
    options.publishIntervalMs = 0;
    options.scanIntervalMs = 0;
    options.retryMinMs = 0;
    options.retryMaxMs = 0;
    return options;
}

// Mac 的样子：文件夹位置固定、可以新建、后台照常同步。
SyncController::Platform macPlatform(const QString& folder)
{
    SyncController::Platform platform;
    platform.makeFolder = [folder](const QByteArray&, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<LocalSyncFolder>(folder));
    };
    platform.fixedFolderDisplayPath = QStringLiteral("iCloud 云盘/番茄Todo同步");
    platform.engine = testOptions();
    platform.engine.mayCreateFolder = true;
    return platform;
}

int restartProbe(const QStringList& arguments)
{
    // 独立进程按正常构造／初始化顺序读取临时库与偏好，不借用父进程的设置缓存。
    configurePreferences(arguments.at(2));
    if (!DatabaseManager::instance()->initialize(arguments.at(3))) return 21;
    SyncController controller(macPlatform(arguments.at(4)));
    controller.initialize();
    const QJsonObject state{
        {QStringLiteral("enabled"), controller.isEnabled()},
        {QStringLiteral("running"), controller.engine() && controller.engine()->isRunning()},
        {QStringLiteral("problem"), controller.hasProblem()}
    };
    std::puts(QJsonDocument(state).toJson(QJsonDocument::Compact).constData());
    return 0;
}

QJsonObject readRestartState(const QString& preferences, const QString& database,
                            const QString& folder, QString* error)
{
    QProcess process;
    const auto cleanup = qScopeGuard([&] {
        if (process.state() != QProcess::NotRunning) {
            process.kill();
            process.waitForFinished();
        }
    });
    process.start(QCoreApplication::applicationFilePath(),
                  {QStringLiteral("--sync-restart-probe"), preferences, database, folder});
    if (!process.waitForFinished(15000)) {
        *error = QStringLiteral("重启探针未结束：") + process.errorString();
        return {};
    }
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        *error = QString::fromUtf8(process.readAllStandardError());
        return {};
    }
    QJsonParseError parseError;
    const auto state = QJsonDocument::fromJson(process.readAllStandardOutput(), &parseError);
    if (!state.isObject() || parseError.error != QJsonParseError::NoError) {
        *error = parseError.errorString();
        return {};
    }
    return state.object();
}

// iPad 的样子：要自己选文件夹，只能加入 Mac 建好的，只在前台定时同步。
// 测试里的「书签」就是文件夹路径的字节；选择器由测试决定下一次选中什么。
struct FakePicker {
    QByteArray bookmark;
    QString message;
    int shown = 0;
};

SyncController::Platform ipadPlatform(FakePicker* picker,
                                      QList<std::function<void(const QByteArray&)>>* refreshers = nullptr)
{
    SyncController::Platform platform;
    platform.makeFolder = [refreshers](const QByteArray& bookmark, std::function<void(const QByteArray&)> refreshed) {
        if (refreshers) {
            refreshers->append(refreshed);
        }
        return std::unique_ptr<SyncFolder>(std::make_unique<LocalSyncFolder>(QString::fromUtf8(bookmark)));
    };
    // 和真的选择器一样，回调晚一点、在界面线程里到。
    platform.pickFolder = [picker](std::function<void(const QByteArray&, const QString&)> done) {
        ++picker->shown;
        const QByteArray bookmark = picker->bookmark;
        const QString message = picker->message;
        QTimer::singleShot(0, [done, bookmark, message] { done(bookmark, message); });
    };
    platform.engine = testOptions();
    platform.engine.mayCreateFolder = false;
    platform.engine.runInBackground = false;
    return platform;
}

// 读某些文件会一直卡住的文件夹（断网时在等 iCloud 下载）：放行或取消之前一直等着，取消后以错误返回。
// 与 SyncTransportTests 的同名替身同一个做法；设置由测试（主线程）改、工作线程读，所以加锁。
struct Stall {
    QMutex mutex;
    QWaitCondition changed;
    QSet<QString> hangingReads;
    bool cancelRequested = false;
    int cancels = 0;
};

class StallingFolder : public LocalSyncFolder
{
public:
    StallingFolder(const QString& root, std::shared_ptr<Stall> stall) : LocalSyncFolder(root), m_stall(std::move(stall)) {}

    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        {
            QMutexLocker locker(&m_stall->mutex);
            while (m_stall->hangingReads.contains(path)) {
                if (m_stall->cancelRequested) {
                    m_stall->cancelRequested = false;
                    *error = {ErrorKind::Io, QStringLiteral("读取已取消：%1").arg(path)};
                    return false;
                }
                m_stall->changed.wait(&m_stall->mutex);
            }
        }
        return LocalSyncFolder::read(path, data, error);
    }
    void cancelPendingIo() override
    {
        QMutexLocker locker(&m_stall->mutex);
        ++m_stall->cancels;
        m_stall->cancelRequested = true;
        m_stall->changed.wakeAll();
    }

private:
    std::shared_ptr<Stall> m_stall;
};

// 模拟「对方改的设置进了库、还没写回本机就被结束了」：走真实的应用路径（同一个事务里记下「待写回」标记），
// 只是不调用写回（SyncNotifier::publish）。直接改 sync_settings 不带标记，表示的是另一件事：本机改了没记上。
bool applyRemoteSettingsWithoutWritingBack(const QList<QPair<QString, QString>>& items, qint64 time)
{
    const QString remote = QStringLiteral("fedcba9876543210fedcba9876543210");
    SyncBatch batch;
    batch.device = remote;
    batch.epoch = SyncStore().epoch();
    for (const auto& item : items) {
        batch.settings.append({item.first, item.second, {time, remote}, {}});
    }
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    if (!result.ok) {
        qWarning() << result.error;
    }
    return result.ok;
}

bool waitIdle(SyncEngine* engine, int timeoutMs = 10000)
{
    if (!engine) {
        return false;
    }
    QElapsedTimer timer;
    timer.start();
    while (!engine->isIdle()) {
        if (timer.elapsed() > timeoutMs) {
            return false;
        }
        QTest::qWait(1);
    }
    return true;
}

QStringList taskTitles(const QSqlDatabase& database)
{
    QStringList titles;
    QSqlQuery query(database);
    query.exec(QStringLiteral("SELECT title FROM tasks ORDER BY title"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    return titles;
}

// 在应用主连接上新建一条任务（排在当天末尾，与服务层一致），返回它的 sync_id。触发器照常把它放进待发送。
QString addTask(const QString& title)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES (:title, :date, 0, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), kTaskDate);
    query.bindValue(QStringLiteral(":orderDate"), kTaskDate);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    QSqlQuery syncId(DatabaseManager::instance()->database());
    syncId.prepare(QStringLiteral("SELECT sync_id FROM tasks WHERE id = :id"));
    syncId.bindValue(QStringLiteral(":id"), query.lastInsertId());
    return syncId.exec() && syncId.next() ? syncId.value(0).toString() : QString();
}

QVariant scalar(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(sql) || !query.next()) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.value(0);
}

// 把应用主库原样存一份（相当于一份备份里的库）。VACUUM INTO 读的是一致的快照，不怕还有没落盘的日志。
bool copyDatabaseTo(const QString& path)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("VACUUM INTO '%1'").arg(path))) {
        qWarning() << query.lastError().text();
        return false;
    }
    return true;
}

// 模拟 BackupService 的恢复：关库、换上备份里的库文件、重新打开（打开时照常迁移与补建同步结构）。
bool replaceDatabaseWith(const QString& backupPath)
{
    const QString path = DatabaseManager::instance()->database().databaseName();
    DatabaseManager::instance()->close();
    for (const QString& suffix : {QString(), QStringLiteral("-wal"), QStringLiteral("-shm")}) {
        QFile::remove(path + suffix);
    }
    return QFile::copy(backupPath, path) && DatabaseManager::instance()->initialize(path);
}

// 某台设备在同步文件夹里写过的改动文件（文件名，升序）。
QStringList changeFiles(const QString& folder, const QString& device)
{
    return QDir(folder + QLatin1Char('/') + SyncFiles::changesDirectory(device)).entryList(QDir::Files, QDir::Name);
}

QStringList snapshotFiles(const QString& folder, const QString& device)
{
    return QDir(folder + QLatin1Char('/') + SyncFiles::deviceDirectory(device))
        .entryList({QStringLiteral("snapshot-*.json")}, QDir::Files, QDir::Name);
}

} // namespace

class SyncControllerTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    // 4a：开关与装配
    void syncIsOffUntilEnabledAndRemembersTheSwitch();
    void enablingBeforeInitializeWaitsForTheDatabase();
    void startupCreatedEnginePublishesRemoteTaskChanges();
    void enabledAfterStartupCreatedEnginePublishesRemoteTaskChanges();
    void shutdownWritesPendingChangesBeforeTheDatabaseCloses();
    void leavingTheForegroundWritesRightAway();
    void inactiveWindowIsNotTreatedAsBackground();

    // 4b：与恢复备份、逻辑日起点的衔接
    void restoringStartsANewEpochAndKeepsThisDevicesIdentity();
    void restoringAnotherDevicesBackupKeepsThisDevicesMembership();
    void failedRestoreResumesWithoutANewEpoch();
    void restoreWarningCoversAJoinedDeviceEvenWithSyncOff();
    void dayStartHourIsRecordedOnceAsDefaultThenAsChanges();
    void startupTrustsTheSyncedDayStartHour();
    void startupKeepsALocalChangeThatWasNeverRecorded();
    void interruptedSnapshotRemovalFinishesAtStartup();

    // 4c：iPad 选文件夹、Mac 重新建立
    void iPadJoinsOnlyAfterPickingTheRightFolderAndConfirming();
    void pickingAWrongFolderKeepsTheCurrentOne();
    void hangingFolderCheckGivesUpAndExplains();
    void cancellingThePickerChangesNothing();
    void refreshedBookmarkIsSavedOnlyForTheFolderInUse();
    void macRebuildsAMissingFolder();
    void followingTheOtherDevicesRollbackBacksUpAndSaysSo();
    void rebuildDoesNothingWhileTheJoinedFolderIsFine();

    // 4d：同步日志
    void copyLostValueEmitsCompleteText();
    void syncLogReadsAsPlainSentencesNewestFirst();
    void syncLogReadSeparatesEmptyFromFailure();
    void logChangesAreAnnouncedOnlyWhenSomethingWasLogged();
    void longMemoConflictsHaveShortSummariesAndCopyableOriginals();
    void memoDeletedElsewhereShowsCopyNotConflict();

    // 051 阶段 2：设置
    void contentSettingsAreRecordedButDeviceSettingsAreNot();
    void remoteSettingsAreWrittenBackAndSnapshotGapsRemoved();
    void invalidRemoteSettingsAreNotWrittenBack();
    void startupWritesBackSeveralSettingsWithoutReRecordingThem();

    // 058 阶段 1：恢复后 epoch / 文件夹处理失败必须 fail-closed
    void epochFailureAfterRestoreHaltsSyncAndAllowsRetry();
    void folderFailureAfterRestoreHaltsSyncAndAllowsRetryWithoutEpochBumping();
    void restoreEpochFailureBlocksNewController();
    void failedSecondRestoreKeepsOriginalRecoveryBlock();
    void secondSuccessfulRestorePreservesOriginalDeviceAndFolder();
    void epochTransactionRollsBackWhenDeviceUpdateFails();

    // 058 阶段 1 B2：恢复日志持久化与启动校验
    void preparedJournalOnRestartBlocksSyncAndAllowsFreshRestore();
    void installedJournalOnRestartCompletesPendingStepsIdempotently();
    void corruptOrOversizedJournalBlocksSyncWithoutDeletingUnknownFiles();
    void cleanJournalRemovesOnlyValidJournalFile();
    void journalDeleteFailureBlocksSyncAndRetryDoesNotBumpEpoch();
    void actualDbCloseReopenWithInstalledJournalResumesWithSameToken();
    void corruptFieldsAndDanglingSymlinkBlockSync();
    void prepareForRestoreWriteFailureBlocksSyncAndTogglingCannotBypass();
    void corruptedJournalPathResolvedAllowsFreshRestore();
    void finishRestoreFalseWhenJournalDeleteFailsPreservesContextAndAllowsRetry();
    void finishRestoreTrueWhenDbClosedRetainsContextAndBlocksSync();
    void finishRestoreTrueDbClosedSyncNowRequiresInstalledJournalWriteBeforeEpoch();
    void secondRestoreFailureWithOldInstalledJournalWriteBackFailureResumesOnRetry();
    void installedJournalWithProductionUuidFolderResumesSuccessfully();
    void finishRestoreSafetyClassificationKeepsPreparedJournalOnRollbackFailure();

    // 058 阶段 1 B3：设置整理错误传播
    void restoreFinalizeSyncSettingsReadFailureBlocksSyncAndResumesWhenHealthy();
    void restoreFinalizeIsolatedWritebackQueryFailureSkipsCompletedStepsAndResumes();
    void restoreFinalizeWriteBackMarkerClearFailurePreservesMarkersAndJournal();
    void restoreFinalizeLocalRecordFailureBlocksSyncAndPreservesJournal();
    void restoreFinalizeQSettingsWriteBackFailureBlocksSyncAndPreservesJournal();

    // 058 阶段 2：同步开关与iPad文件夹持久化
    void settingsAccessErrorOnDisableStopsEngineAndRecoversOnRetry();
    void failedDisableSurvivesProcessRestart_data();
    void failedDisableSurvivesProcessRestart();
    void disableIntentBlocksUnsafeStartup_data();
    void disableIntentBlocksUnsafeStartup();
    void disableIntentRemovalFailureKeepsSyncStopped();
    void bothDisableStoresFailExposesRestartRisk();
    void restoredDatabaseKeepsIndependentDisableIntent();
    void disableNotificationCannotReenableBeforeCommit();
    void settingsAccessErrorOnEnableBlocksEngineAndRecoversOnRetry();
    void settingsAccessErrorOnAcceptFolderPreservesExistingEngineAndRecovers();
    void settingsAccessErrorOnBookmarkRefreshPreservesEngineAndExposesError();

private:
    QString cloudFolder() const { return m_data->filePath(QStringLiteral("cloud/番茄Todo同步")); }

    // 另一台设备（Mac）：真实结构的临时库、自己的连接和引擎，与被测的控制器共用同一个同步文件夹。
    struct Peer {
        QString connection;
        std::unique_ptr<SyncEngine> engine;
        QSqlDatabase database() const { return QSqlDatabase::database(connection); }
    };
    std::unique_ptr<Peer> openMacPeer();

    QTemporaryDir m_preferences;
    std::unique_ptr<QTemporaryDir> m_data;
    QStringList m_connections;
};

void SyncControllerTests::initTestCase()
{
    QVERIFY(m_preferences.isValid());
    // 偏好只落到临时 INI：同步开关、书签、逻辑日起点都不能碰真实偏好。
    configurePreferences(m_preferences.path());
}

void SyncControllerTests::init()
{
    m_data = std::make_unique<QTemporaryDir>();
    QVERIFY(m_data->isValid());
    // 每条测试从「没开过同步」、全部设置都是出厂值开始：清掉上一条留下的开关、书签、番茄时长、今日目标……
    // reload 让设置单例重新读这份空的偏好文件。
    QSettings settings;
    settings.clear();
    settings.sync();
    AppSettings::instance()->reload();
    QVERIFY(DatabaseManager::instance()->initialize(m_data->filePath(QStringLiteral("this.sqlite"))));
    // 同步文件夹的上一级（相当于 iCloud 云盘）要先在；同步文件夹本身由 Mac 第一次开启同步时建。
    QVERIFY(QDir().mkpath(m_data->filePath(QStringLiteral("cloud"))));
}

void SyncControllerTests::cleanup()
{
    DatabaseManager::instance()->close();
    for (const QString& connection : std::as_const(m_connections)) {
        {
            QSqlDatabase database = QSqlDatabase::database(connection, false);
            database.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }
    m_connections.clear();
    m_data.reset();
}

std::unique_ptr<SyncControllerTests::Peer> SyncControllerTests::openMacPeer()
{
    // 用应用自己的初始化建库（与正式运行同一套建表与迁移），建好后换回被测设备的主库。
    const QString mainPath = DatabaseManager::instance()->database().databaseName();
    const QString path = m_data->filePath(QStringLiteral("mac.sqlite"));
    DatabaseManager::instance()->close();
    if (!DatabaseManager::instance()->initialize(path)) {
        qWarning() << "initialize failed" << path;
    }
    DatabaseManager::instance()->close();
    if (!DatabaseManager::instance()->initialize(mainPath)) {
        qWarning() << "reopen failed" << mainPath;
    }
    auto peer = std::make_unique<Peer>();
    peer->connection = QStringLiteral("mac-peer");
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), peer->connection);
        database.setDatabaseName(path);
        database.open();
        QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
        QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    }
    m_connections.append(peer->connection);
    SyncEngine::Options options = testOptions();
    options.mayCreateFolder = true;
    peer->engine = std::make_unique<SyncEngine>(std::make_unique<LocalSyncFolder>(cloudFolder()), options,
                                                peer->connection);
    // 它的库不是应用主库：改动提交后不去通知应用里的服务单例。
    peer->engine->setChangeNotifier([](const SyncStore::ApplyResult&) {});
    return peer;
}

void SyncControllerTests::syncIsOffUntilEnabledAndRemembersTheSwitch()
{
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        // 默认关闭：不建引擎，不碰同步文件夹。
        QVERIFY(!controller.isEnabled());
        QVERIFY(!controller.engine());
        QCOMPARE(controller.statusKey(), QStringLiteral("stopped"));
        QCOMPARE(controller.summaryText(), QStringLiteral("已关闭"));
        QVERIFY(!QFileInfo::exists(cloudFolder()));
        // Mac 的位置固定，不用选。
        QVERIFY(!controller.choosesFolder());
        QVERIFY(controller.hasFolder());
        QCOMPARE(controller.folderDisplayPath(), QStringLiteral("iCloud 云盘/番茄Todo同步"));

        // 打开：记进 sync/ 组，Mac 在空位置新建同步文件夹，并提示你到 iPad 上去选它。
        QSignalSpy enabled(&controller, &SyncController::enabledChanged);
        QSignalSpy notices(&controller, &SyncController::notice);
        controller.setEnabled(true);
        QVERIFY(controller.isEnabled());
        QCOMPARE(enabled.size(), 1);
        QVERIFY(QSettings().value(QStringLiteral("sync/enabled")).toBool());
        QVERIFY(waitIdle(controller.engine()));
        QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
        QVERIFY(!controller.hasProblem());
        QVERIFY(controller.summaryText().startsWith(QStringLiteral("已同步 · ")));
        QVERIFY(QFileInfo::exists(cloudFolder() + QLatin1Char('/') + SyncFiles::markerFileName()));
        QVERIFY(!SyncStore().folderId().isEmpty());
        QCOMPARE(notices.size(), 1);
        QVERIFY(notices.first().first().toString().contains(QStringLiteral("到 iPad 上选这个文件夹")));

        // 关闭：引擎停下，开关记下来。
        controller.setEnabled(false);
        QVERIFY(!controller.isEnabled());
        QCOMPARE(controller.statusKey(), QStringLiteral("stopped"));
        QVERIFY(!QSettings().value(QStringLiteral("sync/enabled")).toBool());
        controller.setEnabled(true);
        QVERIFY(waitIdle(controller.engine()));
    }

    // 重开应用：上次开着同步，就接着同步，不用再开一次；也不会把已经加入的文件夹当成新的再提示一遍。
    const QString folderId = SyncStore().folderId();
    SyncController relaunched(macPlatform(cloudFolder()));
    QSignalSpy notices(&relaunched, &SyncController::notice);
    QVERIFY(relaunched.isEnabled());
    relaunched.initialize();
    QVERIFY(relaunched.engine());
    QVERIFY(relaunched.engine()->isRunning());
    QVERIFY(waitIdle(relaunched.engine()));
    QCOMPARE(relaunched.statusKey(), QStringLiteral("upToDate"));
    QCOMPARE(SyncStore().folderId(), folderId);
    QVERIFY(notices.isEmpty());
}

void SyncControllerTests::enablingBeforeInitializeWaitsForTheDatabase()
{
    // 装配时界面还没加载、库也可能还没核对完：initialize 之前打开，只记下开关，不开始同步。
    SyncController controller(macPlatform(cloudFolder()));
    controller.setEnabled(true);
    QVERIFY(controller.isEnabled());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    controller.initialize();
    QVERIFY(controller.engine());
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::startupCreatedEnginePublishesRemoteTaskChanges()
{
    // 生产启动路径收到远端删除和修改后，必须在提交后先通知任务删除，再刷新任务列表。
    std::unique_ptr<Peer> peer = openMacPeer();
    peer->engine->start();
    QVERIFY(waitIdle(peer->engine.get()));

    QSettings().setValue(QStringLiteral("sync/enabled"), true);
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    QVERIFY(controller.engine());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("needsConfirmation"));
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));

    QSqlQuery insert(peer->database());
    QVERIFY(insert.exec(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES ('远端任务', '2026-09-30', 0, 1)")));
    QVERIFY(insert.exec(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES ('远端待删除', '2026-09-30', 0, 2)")));
    peer->engine->syncNow();
    QVERIFY(waitIdle(peer->engine.get()));
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()),
             (QStringList{QStringLiteral("远端任务"), QStringLiteral("远端待删除")}));

    QSqlQuery localId(DatabaseManager::instance()->database());
    QVERIFY(localId.exec(QStringLiteral("SELECT id FROM tasks WHERE title = '远端待删除'")));
    QVERIFY(localId.next());
    const int deletedTaskId = localId.value(0).toInt();
    localId.finish();
    QSqlQuery update(peer->database());
    QVERIFY(update.exec(QStringLiteral("UPDATE tasks SET title = '远端任务已修改' WHERE title = '远端任务'")));
    QCOMPARE(update.numRowsAffected(), 1);
    QSqlQuery remove(peer->database());
    QVERIFY(remove.exec(QStringLiteral("DELETE FROM tasks WHERE title = '远端待删除'")));
    QCOMPARE(remove.numRowsAffected(), 1);
    peer->engine->syncNow();
    QVERIFY(waitIdle(peer->engine.get()));

    QSignalSpy changed(TaskManager::instance(), &TaskManager::tasksChanged);
    QSignalSpy deleted(TaskManager::instance(), &TaskManager::taskDeleted);
    // 独立只读连接在信号发出的当场读库：主连接能看到自己的未提交写入，不能证明提交边界。
    const QString readerName = QStringLiteral("startup-notification-reader");
    QSqlDatabase reader = QSqlDatabase::cloneDatabase(DatabaseManager::instance()->database(), readerName);
    m_connections.append(readerName);
    reader.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
    QVERIFY2(reader.open(), qPrintable(reader.lastError().text()));
    QCOMPARE(taskTitles(reader),
             (QStringList{QStringLiteral("远端任务"), QStringLiteral("远端待删除")}));
    QStringList signalOrder;
    QList<QStringList> titlesAtSignals;
    // 此对象先于捕获的局部变量销毁，断言提前返回时也会自动断开单例发出的信号。
    QObject notificationObserver;
    connect(TaskManager::instance(), &TaskManager::taskDeleted, &notificationObserver, [&](int) {
        signalOrder.append(QStringLiteral("taskDeleted"));
        titlesAtSignals.append(taskTitles(reader));
    });
    connect(TaskManager::instance(), &TaskManager::tasksChanged, &notificationObserver, [&] {
        signalOrder.append(QStringLiteral("tasksChanged"));
        titlesAtSignals.append(taskTitles(reader));
    });
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!changed.isEmpty());
    QCOMPARE(deleted.count(), 1);
    QCOMPARE(deleted.first().first().toInt(), deletedTaskId);
    QVERIFY(signalOrder.indexOf(QStringLiteral("taskDeleted")) < signalOrder.indexOf(QStringLiteral("tasksChanged")));
    QCOMPARE(titlesAtSignals.size(), changed.size() + deleted.size());
    for (const QStringList& titles : std::as_const(titlesAtSignals)) {
        QCOMPARE(titles, QStringList{QStringLiteral("远端任务已修改")});
    }
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("远端任务已修改")});
}

void SyncControllerTests::enabledAfterStartupCreatedEnginePublishesRemoteTaskChanges()
{
    // 启动后开启同步收到远端删除和修改时，也必须在提交后先通知任务删除，再刷新任务列表。
    std::unique_ptr<Peer> peer = openMacPeer();
    peer->engine->start();
    QVERIFY(waitIdle(peer->engine.get()));

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine());
    controller.setEnabled(true);
    QVERIFY(controller.engine());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("needsConfirmation"));
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));

    QSqlQuery insert(peer->database());
    QVERIFY(insert.exec(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES ('待修改任务', '2026-09-30', 0, 1)")));
    QVERIFY(insert.exec(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES ('待删除任务', '2026-09-30', 0, 2)")));
    peer->engine->syncNow();
    QVERIFY(waitIdle(peer->engine.get()));
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()),
             (QStringList{QStringLiteral("待修改任务"), QStringLiteral("待删除任务")}));

    QSqlQuery idQuery(DatabaseManager::instance()->database());
    QVERIFY(idQuery.exec(QStringLiteral("SELECT id FROM tasks WHERE title = '待删除任务'")));
    QVERIFY(idQuery.next());
    const int taskId = idQuery.value(0).toInt();
    idQuery.finish();
    QSqlQuery update(peer->database());
    QVERIFY(update.exec(QStringLiteral("UPDATE tasks SET title = '已修改任务' WHERE title = '待修改任务'")));
    QCOMPARE(update.numRowsAffected(), 1);
    QSqlQuery remove(peer->database());
    QVERIFY(remove.exec(QStringLiteral("DELETE FROM tasks WHERE title = '待删除任务'")));
    QCOMPARE(remove.numRowsAffected(), 1);
    peer->engine->syncNow();
    QVERIFY(waitIdle(peer->engine.get()));

    QSignalSpy deleted(TaskManager::instance(), &TaskManager::taskDeleted);
    QSignalSpy changed(TaskManager::instance(), &TaskManager::tasksChanged);
    // 用另一条只读连接观察提交后的内容，避免同一连接的未提交视图掩盖过早发信号。
    const QString readerName = QStringLiteral("enabled-notification-reader");
    QSqlDatabase reader = QSqlDatabase::cloneDatabase(DatabaseManager::instance()->database(), readerName);
    m_connections.append(readerName);
    reader.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
    QVERIFY2(reader.open(), qPrintable(reader.lastError().text()));
    QCOMPARE(taskTitles(reader),
             (QStringList{QStringLiteral("待修改任务"), QStringLiteral("待删除任务")}));
    QStringList signalOrder;
    QList<QStringList> titlesAtSignals;
    // 局部接收对象负责断连，失败提前返回后不会留下捕获栈变量的单例连接。
    QObject notificationObserver;
    connect(TaskManager::instance(), &TaskManager::taskDeleted, &notificationObserver, [&](int) {
        signalOrder.append(QStringLiteral("taskDeleted"));
        titlesAtSignals.append(taskTitles(reader));
    });
    connect(TaskManager::instance(), &TaskManager::tasksChanged, &notificationObserver, [&] {
        signalOrder.append(QStringLiteral("tasksChanged"));
        titlesAtSignals.append(taskTitles(reader));
    });
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(deleted.count(), 1);
    QVERIFY(!changed.isEmpty());
    QCOMPARE(deleted.first().first().toInt(), taskId);
    QVERIFY(signalOrder.indexOf(QStringLiteral("taskDeleted")) < signalOrder.indexOf(QStringLiteral("tasksChanged")));
    QCOMPARE(titlesAtSignals.size(), changed.size() + deleted.size());
    for (const QStringList& titles : std::as_const(titlesAtSignals)) {
        QCOMPARE(titles, QStringList{QStringLiteral("已修改任务")});
    }
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("已修改任务")});
}

void SyncControllerTests::shutdownWritesPendingChangesBeforeTheDatabaseCloses()
{
    SyncController::Platform platform = macPlatform(cloudFolder());
    // 攒批间隔拉长：不退出的话，这批改动要等半小时才写。
    platform.engine.publishIntervalMs = 30 * 60 * 1000;
    SyncController controller(std::move(platform));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString me = SyncStore().deviceId();
    QVERIFY(changeFiles(cloudFolder(), me).isEmpty());

    QVERIFY(!addTask(QStringLiteral("退出前记下的")).isEmpty());
    QVERIFY(SyncStore().hasPending());
    // 应用退出时（aboutToQuit，排在关库之前）：同步写出这一批，并确认它已经发出。
    controller.shutdown(5000);
    QCOMPARE(changeFiles(cloudFolder(), me).size(), 1);
    QVERIFY(!SyncStore().hasPending());
    QVERIFY(!controller.engine()->isRunning());
}

void SyncControllerTests::leavingTheForegroundWritesRightAway()
{
    // iPad 的样子：只在前台定时同步，切到后台时向系统要一点时间，把攒下的改动立即写出去。
    SyncController::Platform platform = macPlatform(cloudFolder());
    platform.engine.runInBackground = false;
    platform.engine.publishIntervalMs = 30 * 60 * 1000;
    int begun = 0;
    int ended = 0;
    platform.backgroundTask = [&begun, &ended] {
        ++begun;
        return std::function<void()>([&ended] { ++ended; });
    };
    SyncController controller(std::move(platform));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString me = SyncStore().deviceId();

    QVERIFY(!addTask(QStringLiteral("切到后台前记下的")).isEmpty());
    controller.setForeground(false);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(changeFiles(cloudFolder(), me).size(), 1);
    QVERIFY(!SyncStore().hasPending());
    // 后台时间要到了，写完就还给系统。
    QCOMPARE(begun, 1);
    QCOMPARE(ended, 1);
    controller.setForeground(true);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::inactiveWindowIsNotTreatedAsBackground()
{
    // 审查（10-01）指出：iPad 的「非活动」是窗口仍然可见、只是不在最前面（台前调度里点了别的窗口、
    // 下拉控制中心）。以前把它当成后台，每切一下就单独写一批小文件、要一次后台时间。只有真的进了后台才这样做。
    SyncController::Platform platform = macPlatform(cloudFolder());
    platform.engine.runInBackground = false;
    platform.engine.publishIntervalMs = 30 * 60 * 1000;
    int begun = 0;
    platform.backgroundTask = [&begun] {
        ++begun;
        return std::function<void()>([] {});
    };
    SyncController controller(std::move(platform));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString me = SyncStore().deviceId();
    const qsizetype filesBefore = changeFiles(cloudFolder(), me).size();
    QVERIFY(!addTask(QStringLiteral("切窗口之前记下的")).isEmpty());

    controller.setApplicationState(Qt::ApplicationInactive);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(begun, 0);
    QCOMPARE(changeFiles(cloudFolder(), me).size(), filesBefore);
    QVERIFY(SyncStore().hasPending());
    controller.setApplicationState(Qt::ApplicationActive);
    QVERIFY(waitIdle(controller.engine()));

    // 真的进了后台：立即写出，并向系统要一点后台时间。
    controller.setApplicationState(Qt::ApplicationSuspended);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(begun, 1);
    QCOMPARE(changeFiles(cloudFolder(), me).size(), filesBefore + 1);
    QVERIFY(!SyncStore().hasPending());
    controller.setApplicationState(Qt::ApplicationActive);
    QVERIFY(waitIdle(controller.engine()));
}

void SyncControllerTests::restoringStartsANewEpochAndKeepsThisDevicesIdentity()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!addTask(QStringLiteral("备份之前就有")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    const QString backup = m_data->filePath(QStringLiteral("backup.sqlite"));
    QVERIFY(copyDatabaseTo(backup));
    QVERIFY(!addTask(QStringLiteral("备份之后加的")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    SyncStore before;
    const qint64 epoch = before.epoch();
    const QString device = before.deviceId();
    const QString folder = before.folderId();
    // 恢复开始：先停下同步，库马上要被整个换掉。
    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    // 恢复进行中你又去点「立即同步」或开关：都不会在换库的中途开始。
    controller.setEnabled(true);
    controller.syncNow();
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(replaceDatabaseWith(backup));
    QSignalSpy notices(&controller, &SyncController::notice);
    controller.finishRestore(true);

    // 全局回滚：纪元加一，设备标识不变，还在原来的文件夹里；接着同步，给所有设备写一份新纪元的全量快照。
    SyncStore after;
    QCOMPARE(after.epoch(), epoch + 1);
    QCOMPARE(after.deviceId(), device);
    QCOMPARE(after.folderId(), folder);
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QVERIFY(!after.needsSnapshot());
    QVERIFY(snapshotFiles(cloudFolder(), device).contains(SyncFiles::snapshotFileName({epoch + 1, 0})));
    // 回滚是本机做的：不把它说成「另一台设备恢复了备份」。
    QVERIFY(notices.isEmpty());
}

void SyncControllerTests::restoringAnotherDevicesBackupKeepsThisDevicesMembership()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString device = SyncStore().deviceId();
    const QString folder = SyncStore().folderId();

    // 一份在别处做的备份：另一个设备标识、从没加入过同步（例如加入之前、或另一台设备上做的）。
    const QString otherPath = m_data->filePath(QStringLiteral("other.sqlite"));
    const QString current = DatabaseManager::instance()->database().databaseName();
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(otherPath));
    const QString otherDevice = SyncStore().deviceId();
    QVERIFY(otherDevice != device);
    QVERIFY(SyncStore().folderId().isEmpty());
    const QString backup = m_data->filePath(QStringLiteral("other-backup.sqlite"));
    QVERIFY(copyDatabaseTo(backup));
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(current));

    controller.prepareForRestore();
    QVERIFY(replaceDatabaseWith(backup));
    controller.finishRestore(true);
    // 设备标识和加入的文件夹都保持恢复前的：这台设备还是它自己，还在原来的同步文件夹里，
    // 下一轮把恢复出来的数据作为新纪元推给所有设备，而不是被当成第一次加入、反被对方的数据换掉。
    QCOMPARE(SyncStore().deviceId(), device);
    QCOMPARE(SyncStore().folderId(), folder);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::failedRestoreResumesWithoutANewEpoch()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const qint64 epoch = SyncStore().epoch();

    // 恢复失败：库已经回到恢复前的样子，不开新纪元，照原样接着同步。
    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    controller.finishRestore(false);
    QCOMPARE(SyncStore().epoch(), epoch);
    QVERIFY(!SyncStore().needsSnapshot());
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));

    // 恢复根本没开始（另一项备份正在进行时直接报失败，不发开始信号）：什么都不动。
    controller.finishRestore(true);
    QCOMPARE(SyncStore().epoch(), epoch);
    // 关着同步时恢复成功：照样开新纪元（设备标识要改回来），但不会因此打开同步。
    controller.setEnabled(false);
    controller.prepareForRestore();
    controller.finishRestore(true);
    QCOMPARE(SyncStore().epoch(), epoch + 1);
    QVERIFY(!controller.engine()->isRunning());
    QCOMPARE(controller.statusKey(), QStringLiteral("stopped"));
}

void SyncControllerTests::restoreWarningCoversAJoinedDeviceEvenWithSyncOff()
{
    // 审查（10-01）复现：关着同步时恢复备份，照样开了新纪元；过几天打开同步，另一台被整体回滚，
    // 而恢复确认框只在开关打开时才提醒。判据改成「加入过同步文件夹」，关着的时候说清楚是下次打开同步时发生。
    {
        // 别的设备建了文件夹、这台还在等你确认加入：恢复只影响这台，不提醒。
        std::unique_ptr<Peer> other = openMacPeer();
        other->engine->start();
        QVERIFY(waitIdle(other->engine.get()));
        SyncController waiting(macPlatform(cloudFolder()));
        waiting.initialize();
        QVERIFY(waiting.restoreWarning().isEmpty());
        waiting.setEnabled(true);
        QVERIFY(waitIdle(waiting.engine()));
        QCOMPARE(waiting.statusKey(), QStringLiteral("needsConfirmation"));
        QVERIFY(waiting.restoreWarning().isEmpty());
        waiting.setEnabled(false);
    }

    // 这台在自己建的文件夹里：开着，另一台马上跟着回到备份；关掉之后照样提醒，说明是下次打开同步时。
    QVERIFY(QDir(cloudFolder()).removeRecursively());
    SyncController controller(macPlatform(m_data->filePath(QStringLiteral("cloud/另一个同步"))));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    const QString whileOn = controller.restoreWarning();
    QVERIFY2(whileOn.contains(QStringLiteral("另一台设备也会回到这份备份的状态")), qPrintable(whileOn));
    QVERIFY(!whileOn.contains(QStringLiteral("下次打开同步")));
    controller.setEnabled(false);
    const QString whileOff = controller.restoreWarning();
    QVERIFY2(whileOff.contains(QStringLiteral("下次打开同步时")), qPrintable(whileOff));
    QVERIFY(whileOff.contains(QStringLiteral("另一台设备也会回到这份备份的状态")));
}

void SyncControllerTests::dayStartHourIsRecordedOnceAsDefaultThenAsChanges()
{
    const QString key = QStringLiteral("logic/dayStartHour");
    SyncController controller(macPlatform(cloudFolder()));
    // 启动核对之前改的不记：initialize 会一起核对。
    QVERIFY(SyncStore().syncedSetting(key).isEmpty());
    controller.initialize();
    // 第一次记下的是出厂默认值：用最小版本，另一台设备改过的设置会盖过它。
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("4"));
    QCOMPARE(scalar(QStringLiteral("SELECT v_time FROM sync_settings WHERE key = 'logic/dayStartHour'")).toLongLong(),
             0);

    // 本机改了：记一个真正的版本，等着发出。
    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("5"));
    QVERIFY(scalar(QStringLiteral("SELECT v_time FROM sync_settings WHERE key = 'logic/dayStartHour'")).toLongLong()
            > 0);
    bool pending = false;
    for (const SyncSettingRecord& setting : SyncStore().collectPending().settings) {
        pending = pending || (setting.key == key && setting.value == QStringLiteral("5"));
    }
    QVERIFY(pending);

    // 改回默认值也是一次真正的修改（已经记过这一项了），不能退回最小版本、被对方的旧值盖回去。
    AppSettings::instance()->setDayStartHour(4);
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("4"));
    QVERIFY(scalar(QStringLiteral("SELECT v_time FROM sync_settings WHERE key = 'logic/dayStartHour'")).toLongLong()
            > 0);
}

void SyncControllerTests::startupTrustsTheSyncedDayStartHour()
{
    const QString key = QStringLiteral("logic/dayStartHour");
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
    }
    // 上次把另一台设备改成的 6 点写进了库，还没来得及写回设置就被结束了。
    QVERIFY(applyRemoteSettingsWithoutWritingBack({{key, QStringLiteral("6")}}, 1790000000000LL));
    QCOMPARE(AppSettings::instance()->dayStartHour(), 4);
    QCOMPARE(SyncStore().pendingSettingWriteBacks().value(key), QStringLiteral("set"));

    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    // 以库里记下的为准写回设置；这不是本机的新改动，不会当成本机修改再发回去（版本、待发送标记都不变）。
    QCOMPARE(AppSettings::instance()->dayStartHour(), 6);
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("6"));
    QCOMPARE(scalar(QStringLiteral("SELECT pending FROM sync_settings WHERE key = 'logic/dayStartHour'")).toInt(), 0);
    QCOMPARE(scalar(QStringLiteral("SELECT v_time FROM sync_settings WHERE key = 'logic/dayStartHour'")).toLongLong(),
             1790000000000LL);
    // 写回做完了，标记清掉。
    QVERIFY(SyncStore().pendingSettingWriteBacks().isEmpty());
}

void SyncControllerTests::iPadJoinsOnlyAfterPickingTheRightFolderAndConfirming()
{
    // Mac 先开启同步：建好文件夹、写好第一份快照。
    std::unique_ptr<Peer> mac = openMacPeer();
    QSqlQuery macTask(mac->database());
    QVERIFY(macTask.exec(QStringLiteral("INSERT INTO tasks (title, date, completed, display_order) "
                                        "VALUES ('Mac 的任务', '2026-09-30', 0, 1)")));
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);

    QVERIFY(!addTask(QStringLiteral("iPad 的测试任务")).isEmpty());
    FakePicker picker;
    SyncController controller(ipadPlatform(&picker));
    // 替换本机数据之前的自动备份：记下备份那一刻本机有哪些任务，确认它发生在替换之前。
    QList<QStringList> backups;
    controller.setSafetyBackup([&backups](QString*) {
        backups.append(taskTitles(DatabaseManager::instance()->database()));
        return true;
    });
    controller.initialize();
    QVERIFY(controller.choosesFolder());
    QVERIFY(!controller.hasFolder());
    QVERIFY(!controller.engine());

    // 打开同步 = 先去选文件夹。第一次选成了外面一层：不接受，告诉你该点进去选哪个，同步仍然关着。
    picker.bookmark = m_data->filePath(QStringLiteral("cloud")).toUtf8();
    picker.message = QStringLiteral("iCloud 云盘");
    controller.setEnabled(true);
    QCOMPARE(picker.shown, 1);
    QVERIFY(controller.isChoosingFolder());
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().contains(QStringLiteral("外面的一层")));
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.hasFolder());
    QVERIFY(!controller.engine());

    // 又选成了里面的子文件夹：同样不接受。
    picker.bookmark = (cloudFolder() + QLatin1Char('/') + SyncFiles::devicesDirectory()).toUtf8();
    picker.message = QStringLiteral("devices");
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().contains(QStringLiteral("子文件夹")));
    QVERIFY(!controller.isEnabled());

    // 选对了：记下书签和给人看的位置，打开同步。第一次加入别人建的文件夹，要你确认，确认前什么都不动。
    picker.bookmark = cloudFolder().toUtf8();
    picker.message = QStringLiteral("iCloud 云盘/番茄Todo同步");
    controller.chooseFolder();
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(controller.folderProblem().isEmpty());
    QVERIFY(controller.hasFolder());
    QCOMPARE(controller.folderDisplayPath(), QStringLiteral("iCloud 云盘/番茄Todo同步"));
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), cloudFolder().toUtf8());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("needsConfirmation"));
    QVERIFY(!controller.hasProblem());
    QVERIFY(!controller.statusText().isEmpty());
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("iPad 的测试任务")});
    QVERIFY(backups.isEmpty());

    // 确认：先备份（备份时本机数据还在），再整体换成 Mac 的，并告诉你已经加入。
    QSignalSpy notices(&controller, &SyncController::notice);
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QCOMPARE(backups.size(), 1);
    QCOMPARE(backups.first(), QStringList{QStringLiteral("iPad 的测试任务")});
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("Mac 的任务")});
    QCOMPARE(notices.size(), 1);
    QVERIFY(notices.first().first().toString().startsWith(QStringLiteral("已加入同步")));
}

void SyncControllerTests::pickingAWrongFolderKeepsTheCurrentOne()
{
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));
    FakePicker picker;
    picker.bookmark = cloudFolder().toUtf8();
    picker.message = QStringLiteral("iCloud 云盘/番茄Todo同步");
    SyncController controller(ipadPlatform(&picker));
    controller.initialize();
    controller.setEnabled(true);
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(waitIdle(controller.engine()));
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));

    // 想换个文件夹却选错了：原来的书签不动，同步照常。
    const QString empty = m_data->filePath(QStringLiteral("cloud/别的文件夹"));
    QVERIFY(QDir().mkpath(empty));
    picker.bookmark = empty.toUtf8();
    picker.message = QStringLiteral("别的文件夹");
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().contains(QStringLiteral("不是番茄Todo 的同步文件夹")));
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), cloudFolder().toUtf8());
    QCOMPARE(controller.folderDisplayPath(), QStringLiteral("iCloud 云盘/番茄Todo同步"));
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));

    // 选中的位置根本打不开（书签失效、iCloud 关了）：同样不换，并说明原因。
    picker.bookmark = m_data->filePath(QStringLiteral("不存在/番茄Todo同步")).toUtf8();
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().startsWith(QStringLiteral("打不开选中的文件夹")));
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), cloudFolder().toUtf8());

    // 再选回正确的文件夹：上一次的问题清掉，同一个文件夹直接接着同步，不用再确认加入。
    picker.bookmark = cloudFolder().toUtf8();
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().isEmpty());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::hangingFolderCheckGivesUpAndExplains()
{
    // iPad 选中文件夹后要先读它的标记文件；断网时这一步可能一直等着。以前设置页就一直停在「正在检查」、
    // 按钮也一直点不了；现在到点取消、作废这一次，就地说明，同步仍关着，可以再选一次。
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));
    auto stall = std::make_shared<Stall>();
    {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.insert(SyncFiles::markerFileName());
    }
    // 用例无论在哪一步失败都要放行卡住的读：那次检查跑在全局线程池里，不放行的话进程退出时会一直等它，
    // 功能退化时整个测试就卡死，而不是干净地报失败。
    const auto releaseOnExit = qScopeGuard([stall] {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.clear();
        stall->changed.wakeAll();
    });
    FakePicker picker;
    picker.bookmark = cloudFolder().toUtf8();
    picker.message = QStringLiteral("iCloud 云盘/番茄Todo同步");
    SyncController::Platform platform = ipadPlatform(&picker);
    platform.engine.stallTimeoutMs = 300;
    platform.makeFolder = [stall](const QByteArray& bookmark, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<StallingFolder>(QString::fromUtf8(bookmark), stall));
    };
    SyncController controller(platform);
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(controller.isChoosingFolder());
    QTRY_VERIFY_WITH_TIMEOUT(!controller.isChoosingFolder(), 5000);
    QVERIFY2(controller.folderProblem().contains(QStringLiteral("没有响应")), qPrintable(controller.folderProblem()));
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.hasFolder());
    {
        const QMutexLocker locker(&stall->mutex);
        QVERIFY(stall->cancels >= 1);
    }

    // 网络回来了，再选一次：照常校验通过、打开同步，停在「等你确认加入」。
    {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.clear();
        stall->changed.wakeAll();
    }
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.folderProblem().isEmpty());
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("needsConfirmation"));
}

void SyncControllerTests::cancellingThePickerChangesNothing()
{
    FakePicker picker;
    SyncController controller(ipadPlatform(&picker));
    controller.initialize();
    // 取消：书签和说明都为空，不提示、不打开。
    controller.setEnabled(true);
    QTRY_VERIFY(!controller.isChoosingFolder());
    QCOMPARE(picker.shown, 1);
    QVERIFY(controller.folderProblem().isEmpty());
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine());
    // 选择器自己出了错（例如找不到能弹出它的界面）：说明原因。
    picker.message = QStringLiteral("找不到可以弹出文件选择器的界面");
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QCOMPARE(controller.folderProblem(), QStringLiteral("找不到可以弹出文件选择器的界面"));
    QVERIFY(!controller.isEnabled());
}

void SyncControllerTests::refreshedBookmarkIsSavedOnlyForTheFolderInUse()
{
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));
    FakePicker picker;
    picker.bookmark = cloudFolder().toUtf8();
    QList<std::function<void(const QByteArray&)>> refreshers;
    SyncController controller(ipadPlatform(&picker, &refreshers));
    controller.initialize();
    controller.setEnabled(true);
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(waitIdle(controller.engine()));
    // 先建的是校验用的临时访问对象，最后建的才是引擎正在用的那个。
    QCOMPARE(refreshers.size(), 2);

    // 系统把书签标为过期、在工作线程里重新生成了一份：回到主线程存起来，替换旧的。
    std::function<void(const QByteArray&)> current = refreshers.last();
    QThread* thread = QThread::create([current] { current(QByteArrayLiteral("刷新后的书签")); });
    thread->start();
    QVERIFY(thread->wait(5000));
    delete thread;
    QTRY_COMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), QByteArrayLiteral("刷新后的书签"));

    // 换了文件夹之后，旧文件夹排在队里的操作刷新出来的书签不能盖掉新选的。
    const QString second = m_data->filePath(QStringLiteral("cloud2/番茄Todo同步"));
    QVERIFY(QDir().mkpath(second));
    QVERIFY(QFile::copy(cloudFolder() + QLatin1Char('/') + SyncFiles::markerFileName(),
                        second + QLatin1Char('/') + SyncFiles::markerFileName()));
    picker.bookmark = second.toUtf8();
    controller.chooseFolder();
    QTRY_COMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), second.toUtf8());
    current(QByteArrayLiteral("旧文件夹的书签"));
    // 回调把保存投递到主线程排队。再投一个哨兵：同一个对象上的投递按先后处理，哨兵执行时前面那次一定处理过了，
    // 不靠「等几毫秒」碰运气。
    bool processed = false;
    QMetaObject::invokeMethod(QCoreApplication::instance(), [&processed] { processed = true; }, Qt::QueuedConnection);
    QTRY_VERIFY(processed);
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), second.toUtf8());
}

void SyncControllerTests::macRebuildsAMissingFolder()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString oldFolderId = SyncStore().folderId();

    // 同步正常的时候点「重新建立」（界面不会给这个按钮，但不能指望界面）：什么都不动，不会忘掉已加入的文件夹。
    controller.rebuildFolder();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(SyncStore().folderId(), oldFolderId);
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));

    // 整个同步文件夹被删掉了：已经加入的文件夹不自动重建（另一台还认着旧的），停下来等你决定。
    QVERIFY(QDir(cloudFolder()).removeRecursively());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("folderMissing"));
    QVERIFY(controller.hasProblem());

    // 你点「重新建立」：在原处建一个新的（新的文件夹身份），并提示到 iPad 上重新选它。
    QSignalSpy notices(&controller, &SyncController::notice);
    controller.rebuildFolder();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QVERIFY(!SyncStore().folderId().isEmpty());
    QVERIFY(SyncStore().folderId() != oldFolderId);
    QVERIFY(QFileInfo::exists(cloudFolder() + QLatin1Char('/') + SyncFiles::markerFileName()));
    QCOMPARE(notices.size(), 1);

    // 只剩标记文件没了、里面还留着旧东西：不在别人的东西上面新建，提示你先把它移走（Mac 的说法，不是「选错了哪一层」）。
    QVERIFY(QFile::remove(cloudFolder() + QLatin1Char('/') + SyncFiles::markerFileName()));
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("folderMissing"));
    controller.rebuildFolder();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("wrongFolder"));
    QVERIFY(controller.statusText().contains(QStringLiteral("在访达里把它移到别处或删除")));
    QVERIFY(controller.statusDetail().isEmpty());
    // 「重新建立」只在文件夹不见了时起作用：这时再点，不会忘掉别的东西。
    QVERIFY(SyncStore().folderId().isEmpty());
    controller.rebuildFolder();
    QVERIFY(SyncStore().folderId().isEmpty());
}

void SyncControllerTests::followingTheOtherDevicesRollbackBacksUpAndSaysSo()
{
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));
    FakePicker picker;
    picker.bookmark = cloudFolder().toUtf8();
    SyncController controller(ipadPlatform(&picker));
    int backups = 0;
    controller.setSafetyBackup([&backups](QString*) {
        ++backups;
        return true;
    });
    controller.initialize();
    controller.setEnabled(true);
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(waitIdle(controller.engine()));
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(backups, 1);
    QVERIFY(!addTask(QStringLiteral("iPad 回滚之前记的")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    // Mac 恢复了备份（全局回滚）：开新纪元，给所有设备写一份全量快照。
    mac->engine->stop();
    SyncStore macStore(mac->connection);
    QVERIFY(macStore.beginEpochAfterRestore(macStore.epoch(), macStore.deviceId()));
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));

    // iPad 下一轮读到更高的纪元：先自动备份，再整体换成 Mac 的，并告诉你发生了什么。
    QSignalSpy notices(&controller, &SyncController::notice);
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(backups, 2);
    QCOMPARE(SyncStore().epoch(), macStore.epoch());
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList());
    QCOMPARE(notices.size(), 1);
    QVERIFY(notices.first().first().toString().startsWith(QStringLiteral("另一台设备恢复了备份")));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::rebuildDoesNothingWhileTheJoinedFolderIsFine()
{
    // 这台 Mac 加入的是另一台设备建的文件夹（例如重装之后）：忘掉它就得重新确认加入、再被整体替换一次。
    std::unique_ptr<Peer> other = openMacPeer();
    other->engine->start();
    QVERIFY(waitIdle(other->engine.get()));
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("needsConfirmation"));
    controller.confirmJoin();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    const QString folderId = SyncStore().folderId();

    // 文件夹好好的时候点「重新建立」：什么都不动。
    controller.rebuildFolder();
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(SyncStore().folderId(), folderId);
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

void SyncControllerTests::copyLostValueEmitsCompleteText()
{
    // 产品保证：日志复制传递完整原文，正文再长也不能复制摘要；测试不碰真实剪贴板。
    SyncController controller(macPlatform(cloudFolder()));
    QSignalSpy copied(&controller, &SyncController::copyRequested);
    const QString text = QStringLiteral("被覆盖的正文\n") + QString(9000, QChar(u'文')) + QStringLiteral("\n最后一行🙂");
    QVERIFY(text.size() > 9000);
    controller.copyLostValue(text);
    QCOMPARE(copied.count(), 1);
    QCOMPARE(copied.first().first().toString(), text);
}

// 保证：读同步日志时能分清「没有日志」和「读不出来」（iPad 设置页要分开显示）：没有日志是成功的空列表、计数 0；
// 有日志时新接口与旧接口给出同样的内容，limit 照样生效、新的在前；查询失败或数据库没开时报 Database，
// 而旧接口仍回落为空列表 / 0，Mac 设置页的行为不变。
void SyncControllerTests::syncLogReadSeparatesEmptyFromFailure()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    const ServiceReadResult<QVariantList> empty = controller.readSyncLog();
    QVERIFY(empty.ok());
    QVERIFY(empty.value.isEmpty());
    const ServiceReadResult<int> emptyCount = controller.readLogCount();
    QVERIFY(emptyCount.ok());
    QCOMPARE(emptyCount.value, 0);

    const QString other = QStringLiteral("fedcba9876543210fedcba9876543210");
    QVERIFY(SyncStore().logFileProblem(other, QStringLiteral("devices/%1/changes/0-1.json").arg(other),
                                       QStringLiteral("不是 JSON")));
    QVERIFY(SyncStore().logFileProblem(other, QStringLiteral("devices/%1/changes/0-2.json").arg(other),
                                       QStringLiteral("读不懂")));
    const ServiceReadResult<QVariantList> both = controller.readSyncLog();
    QVERIFY(both.ok());
    QCOMPARE(both.value.size(), 2);
    QCOMPARE(both.value, controller.syncLog());
    const ServiceReadResult<QVariantList> newest = controller.readSyncLog(1);
    QVERIFY(newest.ok());
    QCOMPARE(newest.value.size(), 1);
    QCOMPARE(newest.value.first().toMap().value(QStringLiteral("title")).toString(), QStringLiteral("文件「0-2.json」"));
    const ServiceReadResult<int> count = controller.readLogCount();
    QVERIFY(count.ok());
    QCOMPARE(count.value, 2);

    // 查询失败：把日志表挪开。先挪回来再断言，断言失败也不会把坏表留给后面的用例。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_conflict_log RENAME TO sync_conflict_log_hidden")));
    const ServiceReadResult<QVariantList> broken = controller.readSyncLog();
    const ServiceReadResult<int> brokenCount = controller.readLogCount();
    const QVariantList legacyLog = controller.syncLog();
    const int legacyCount = controller.logCount();
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_conflict_log_hidden RENAME TO sync_conflict_log")));
    QVERIFY(broken.error == ServiceReadError::Database);
    QVERIFY(broken.value.isEmpty());
    QVERIFY(brokenCount.error == ServiceReadError::Database);
    QVERIFY(legacyLog.isEmpty());
    QCOMPARE(legacyCount, 0);

    // 数据库没开：同样报 Database（cleanup 里再关一次是安全的）。
    DatabaseManager::instance()->close();
    QVERIFY(controller.readSyncLog().error == ServiceReadError::Database);
    QVERIFY(controller.readLogCount().error == ServiceReadError::Database);
}

void SyncControllerTests::syncLogReadsAsPlainSentencesNewestFirst()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    const QString me = SyncStore().deviceId();
    const QString other = QStringLiteral("fedcba9876543210fedcba9876543210");
    // 按数据层写日志时的样子铺几条（写日志本身由 SyncTests 覆盖，这里只看怎么给人看）。
    const auto log = [](const QString& kind, const QString& table, const QString& label, const QString& field,
                        const QString& lost, const QString& kept, const QString& lostDevice,
                        const QString& keptDevice, const QString& detail) {
        QSqlQuery query(DatabaseManager::instance()->database());
        query.prepare(QStringLiteral(
            "INSERT INTO sync_conflict_log (logged_at, kind, tbl, sync_id, record_label, field, lost_value, "
            "kept_value, lost_device, kept_device, detail) VALUES (:at, :kind, :tbl, 'x', :label, :field, :lost, "
            ":kept, :lostDevice, :keptDevice, :detail)"));
        query.bindValue(QStringLiteral(":at"), QDateTime::currentDateTime().toString(Qt::ISODate));
        query.bindValue(QStringLiteral(":kind"), kind);
        query.bindValue(QStringLiteral(":tbl"), table);
        query.bindValue(QStringLiteral(":label"), label);
        query.bindValue(QStringLiteral(":field"), field);
        query.bindValue(QStringLiteral(":lost"), lost);
        query.bindValue(QStringLiteral(":kept"), kept);
        query.bindValue(QStringLiteral(":lostDevice"), lostDevice);
        query.bindValue(QStringLiteral(":keptDevice"), keptDevice);
        query.bindValue(QStringLiteral(":detail"), detail);
        return query.exec();
    };
    QVERIFY(log(QStringLiteral("edit"), QStringLiteral("tasks"), QStringLiteral("背单词"), QStringLiteral("title"),
                QStringLiteral("背单词 30 个"), QStringLiteral("背单词 50 个"), me, other,
                QStringLiteral("两台设备同时改了这一项，以较晚的修改为准")));
    QVERIFY(log(QStringLiteral("edit"), QStringLiteral("settings"), QStringLiteral("逻辑日起点"),
                QStringLiteral("logic/dayStartHour"), QStringLiteral("3 点"), QStringLiteral("5 点"), other, me,
                QStringLiteral("两台设备同时改了这一项，以较晚的修改为准")));
    QVERIFY(log(QStringLiteral("delete"), QStringLiteral("tasks"), QStringLiteral("写作文"), QStringLiteral("notes"),
                QStringLiteral("先列提纲"), QStringLiteral("（已删除）"), me, other,
                QStringLiteral("另一台设备删除了这条记录")));
    QVERIFY(SyncStore().logFileProblem(other, QStringLiteral("devices/%1/changes/0-3.json").arg(other),
                                       QStringLiteral("不是 JSON")));

    QCOMPARE(controller.logCount(), 4);
    const QVariantList entries = controller.syncLog(10);
    QCOMPARE(entries.size(), 4);
    // 新的在前：最后记的文件问题排第一。
    const QVariantMap file = entries.at(0).toMap();
    QCOMPARE(file.value(QStringLiteral("kindLabel")).toString(), QStringLiteral("文件问题"));
    QCOMPARE(file.value(QStringLiteral("title")).toString(), QStringLiteral("文件「0-3.json」"));
    QCOMPARE(file.value(QStringLiteral("summary")).toString(), QStringLiteral("不是 JSON"));
    QVERIFY(file.value(QStringLiteral("time")).toString().startsWith(QStringLiteral("今天 ")));

    const QVariantMap deleted = entries.at(1).toMap();
    QCOMPARE(deleted.value(QStringLiteral("kindLabel")).toString(), QStringLiteral("删除优先"));
    QCOMPARE(deleted.value(QStringLiteral("title")).toString(), QStringLiteral("任务「写作文」"));
    QCOMPARE(deleted.value(QStringLiteral("summary")).toString(),
             QStringLiteral("另一台设备删除了这条记录。这台设备对「备注」的修改「先列提纲」没有生效。"));

    const QVariantMap setting = entries.at(2).toMap();
    QCOMPARE(setting.value(QStringLiteral("title")).toString(), QStringLiteral("设置「逻辑日起点」"));
    QCOMPARE(setting.value(QStringLiteral("summary")).toString(),
             QStringLiteral("「逻辑日起点」保留了这台设备的「5 点」，另一台设备的「3 点」没有生效。"));

    const QVariantMap edit = entries.at(3).toMap();
    QCOMPARE(edit.value(QStringLiteral("kindLabel")).toString(), QStringLiteral("同时修改"));
    QCOMPARE(edit.value(QStringLiteral("title")).toString(), QStringLiteral("任务「背单词」"));
    QCOMPARE(edit.value(QStringLiteral("summary")).toString(),
             QStringLiteral("「标题」保留了另一台设备的「背单词 50 个」，这台设备的「背单词 30 个」没有生效。"));

    // 只要最近几条时不多给。
    QCOMPARE(controller.syncLog(2).size(), 2);
}

void SyncControllerTests::logChangesAreAnnouncedOnlyWhenSomethingWasLogged()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QSignalSpy changed(&controller, &SyncController::logChanged);
    const int revision = controller.logRevision();

    // 平常的一轮同步不记日志，也就不让界面重新读。
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(changed.size(), 0);

    // 另一台设备写来一个读不懂的文件：跳过、记进日志，界面据此重新读一次。
    const QString other = QStringLiteral("fedcba9876543210fedcba9876543210");
    const QString changes = cloudFolder() + QLatin1Char('/') + SyncFiles::changesDirectory(other);
    QVERIFY(QDir().mkpath(changes));
    QFile broken(changes + QLatin1Char('/') + SyncFiles::changeFileName({0, 1}));
    QVERIFY(broken.open(QIODevice::WriteOnly));
    broken.write("不是 JSON");
    broken.close();
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(changed.size(), 1);
    QCOMPARE(controller.logRevision(), revision + 1);
    QCOMPARE(controller.logCount(), 1);
    QCOMPARE(controller.syncLog(1).first().toMap().value(QStringLiteral("kindLabel")).toString(),
             QStringLiteral("文件问题"));

    // 坏文件跳过之后不会每轮都再记一次。
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(changed.size(), 1);
}

namespace {

// 库里记下的某一项设置：值、版本时间、记它的设备、还待不待发送。
struct SettingRow {
    bool exists = false;
    QString value;
    qint64 time = 0;
    QString device;
    bool pending = false;
};

SettingRow settingRow(const QString& key)
{
    SettingRow row;
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT value, v_time, v_device, pending FROM sync_settings WHERE key = :key"));
    query.bindValue(QStringLiteral(":key"), key);
    if (query.exec() && query.next()) {
        row = {true, query.value(0).toString(), query.value(1).toLongLong(), query.value(2).toString(),
               query.value(3).toInt() != 0};
    }
    return row;
}

QStringList syncedKeysInDatabase()
{
    QStringList keys;
    QSqlQuery query(DatabaseManager::instance()->database());
    query.exec(QStringLiteral("SELECT key FROM sync_settings ORDER BY key"));
    while (query.next()) {
        keys.append(query.value(0).toString());
    }
    return keys;
}

} // namespace

void SyncControllerTests::contentSettingsAreRecordedButDeviceSettingsAreNot()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    // 启动时把每一项内容类设置都记下来（昵称、学期起始日这种空值也算）。全是出厂值，用最小版本：
    // 另一台设备改过的会盖过它们。
    QStringList expected = SyncSchema::syncedSettingKeys();
    expected.sort();
    QCOMPARE(syncedKeysInDatabase(), expected);
    for (const QString& key : expected) {
        QVERIFY2(settingRow(key).time == 0, qPrintable(key));
    }
    QCOMPARE(settingRow(QStringLiteral("profile/nickname")).value, QString());

    // 「这台设备怎么显示、怎么提醒」的设置改了，不记：外观、动效、自动开始、快速开始各台设备各自设。
    AppSettings::instance()->setReduceMotion(true);
    AppSettings::instance()->setBackgroundTheme(QStringLiteral("starry"));
    AppSettings::instance()->setAutoStartBreak(true);
    AppSettings::instance()->setQuickStartEnabled(true);
    QCOMPARE(syncedKeysInDatabase(), expected);

    // 内容类设置改了：记一个真正的版本，等着发出。今日目标按日期各是一项，整张节次表是一项。
    AppSettings::instance()->setWorkMinutes(50);
    QCOMPARE(settingRow(QStringLiteral("focus/workMinutes")).value, QStringLiteral("50"));
    QVERIFY(settingRow(QStringLiteral("focus/workMinutes")).time > 0);
    QVERIFY(settingRow(QStringLiteral("focus/workMinutes")).pending);
    AppSettings::instance()->setNickname(QStringLiteral("小番茄"));
    QCOMPARE(settingRow(QStringLiteral("profile/nickname")).value, QStringLiteral("小番茄"));
    QVERIFY(AppSettings::instance()->setDailyFocusGoal(QStringLiteral("2026-09-30"), 90));
    QCOMPARE(settingRow(SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-30"))).value, QStringLiteral("90"));
    QVERIFY(ScheduleService::instance()->setPeriods(
        {QVariantMap{{QStringLiteral("startMinutes"), 480}, {QStringLiteral("endMinutes"), 525}},
         QVariantMap{{QStringLiteral("startMinutes"), 535}, {QStringLiteral("endMinutes"), 580}}}));
    QCOMPARE(settingRow(QStringLiteral("schedule/periods")).value, QStringLiteral("[[480,525],[535,580]]"));
    QVERIFY(settingRow(QStringLiteral("schedule/periods")).time > 0);
}

void SyncControllerTests::remoteSettingsAreWrittenBackAndSnapshotGapsRemoved()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    const QString remote = QStringLiteral("fedcba9876543210fedcba9876543210");
    const SyncVersion version{1790000000000, remote};
    const QString goal = SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-29"));
    SyncBatch batch;
    batch.device = remote;
    batch.epoch = SyncStore().epoch();
    batch.settings = {
        {QStringLiteral("focus/workMinutes"), QStringLiteral("45"), version, {}},
        {QStringLiteral("focus/longBreakEnabled"), QStringLiteral("0"), version, {}},
        {QStringLiteral("profile/nickname"), QStringLiteral("小番茄"), version, {}},
        {goal, QStringLiteral("120"), version, {}},
        {QStringLiteral("schedule/periods"), QStringLiteral("[[480,525],[535,580]]"), version, {}},
    };
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    SyncNotifier::publish(result);

    // 写回本机：各自的设置页、计时器、课表照常读到新值。
    QCOMPARE(AppSettings::instance()->workMinutes(), 45);
    QVERIFY(!AppSettings::instance()->longBreakEnabled());
    QCOMPARE(AppSettings::instance()->nickname(), QStringLiteral("小番茄"));
    QCOMPARE(AppSettings::instance()->dailyFocusGoalMinutesForDate(QStringLiteral("2026-09-29")), 120);
    const QVariantList periods = ScheduleService::instance()->getPeriods();
    QCOMPARE(periods.size(), 2);
    QCOMPARE(periods.at(1).toMap().value(QStringLiteral("startMinutes")).toInt(), 535);
    // 写回不是本机改动：库里还是对方的版本，不待发送，不会再发回去。
    for (const SyncSettingRecord& setting : batch.settings) {
        QCOMPARE(settingRow(setting.key).device, remote);
        QVERIFY2(!settingRow(setting.key).pending, qPrintable(setting.key));
    }
    // 都写回成了：「待写回」标记全部清掉。
    QVERIFY(SyncStore().pendingSettingWriteBacks().isEmpty());

    // 另一台设备恢复了备份：本机整体换成它的快照，快照里没有 9 月 29 日的目标。以快照为准，本机删掉这一天，
    // 下次启动也不会把它当成本机改动再发出去。
    SyncBatch snapshot = SyncStore().exportSnapshot();
    snapshot.device = remote;
    snapshot.settings.erase(std::remove_if(snapshot.settings.begin(), snapshot.settings.end(),
                                           [&goal](const SyncSettingRecord& setting) { return setting.key == goal; }),
                            snapshot.settings.end());
    const SyncStore::ApplyResult replaced = SyncStore().replaceWithSnapshot(snapshot);
    QVERIFY2(replaced.ok, qPrintable(replaced.error));
    QVERIFY(replaced.removedSettings.contains(goal));
    SyncNotifier::publish(replaced);
    QCOMPARE(AppSettings::instance()->dailyFocusGoalMinutesForDate(QStringLiteral("2026-09-29")), 0);
    QVERIFY(SyncStore().pendingSettingWriteBacks().isEmpty());
    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    QVERIFY(!settingRow(goal).exists);
}

void SyncControllerTests::invalidRemoteSettingsAreNotWrittenBack()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    const QString remote = QStringLiteral("fedcba9876543210fedcba9876543210");
    const SyncVersion version{1790000000000, remote};
    SyncBatch batch;
    batch.device = remote;
    batch.epoch = SyncStore().epoch();
    // 外部改坏的、或更新版本才有的取值：写不回本机就不写，本机设置保持原样，也不崩。
    batch.settings = {
        {QStringLiteral("focus/workMinutes"), QStringLiteral("很长"), version, {}},
        {QStringLiteral("focus/longBreakEnabled"), QStringLiteral("也许"), version, {}},
        {QStringLiteral("schedule/periods"), QStringLiteral("不是节次表"), version, {}},
    };
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    SyncNotifier::publish(result);
    QCOMPARE(AppSettings::instance()->workMinutes(), AppSettings::kDefaultWorkMinutes);
    QVERIFY(AppSettings::instance()->longBreakEnabled());
    QCOMPARE(ScheduleService::instance()->getPeriods().size(), DatabaseManager::defaultSchedulePeriods().size());
    // 写不回本机的「待写回」留着：下次启动再试，也不拿本机的值去盖它（可能是更新版本的取值，本机认不得）。
    QCOMPARE(SyncStore().pendingSettingWriteBacks().size(), batch.settings.size());
    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    QCOMPARE(SyncStore().syncedSetting(QStringLiteral("focus/workMinutes")), QStringLiteral("很长"));
    QCOMPARE(SyncStore().pendingSettingWriteBacks().size(), batch.settings.size());
}

void SyncControllerTests::startupWritesBackSeveralSettingsWithoutReRecordingThem()
{
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
    }
    // 上次把对方改的几项写进了库，还没来得及写回设置就被结束了。
    const QString remote = QStringLiteral("fedcba9876543210fedcba9876543210");
    const QString goal = SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-29"));
    QVERIFY(applyRemoteSettingsWithoutWritingBack({{QStringLiteral("focus/workMinutes"), QStringLiteral("45")},
                                                   {QStringLiteral("profile/nickname"), QStringLiteral("小番茄")},
                                                   {goal, QStringLiteral("120")}},
                                                  1790000000000LL));
    QCOMPARE(SyncStore().pendingSettingWriteBacks().size(), 3);

    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    // 三项都以库里的为准写回；先写回的那一项发出的变更信号，不能让后面还没写回的被当成本机改动重记一遍。
    QCOMPARE(AppSettings::instance()->workMinutes(), 45);
    QCOMPARE(AppSettings::instance()->nickname(), QStringLiteral("小番茄"));
    QCOMPARE(AppSettings::instance()->dailyFocusGoalMinutesForDate(QStringLiteral("2026-09-29")), 120);
    for (const QString& key : {QStringLiteral("focus/workMinutes"), QStringLiteral("profile/nickname"), goal}) {
        QCOMPARE(settingRow(key).device, remote);
        QCOMPARE(settingRow(key).time, 1790000000000LL);
        QVERIFY2(!settingRow(key).pending, qPrintable(key));
    }
    QVERIFY(SyncStore().pendingSettingWriteBacks().isEmpty());
}

void SyncControllerTests::startupKeepsALocalChangeThatWasNeverRecorded()
{
    // 审查（10-01）指出：启动核对以前一律以库为准写回。本机改了设置却没记进库（记录失败：库被别的连接长时间
    // 占着而等待超时、磁盘满……）时，下次启动你的改动就被悄悄改回去。没有「待写回」标记的不一致，以本机为准。
    const QString key = QStringLiteral("focus/workMinutes");
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
    }
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("25"));
    // 这时没有控制器在记：相当于这次改动没能记进库。
    AppSettings::instance()->setWorkMinutes(50);
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("25"));

    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    QCOMPARE(AppSettings::instance()->workMinutes(), 50);
    QCOMPARE(SyncStore().syncedSetting(key), QStringLiteral("50"));
    // 补记成本机的新改动，等着发出去。
    QVERIFY(settingRow(key).pending);
    QCOMPARE(settingRow(key).device, SyncStore().deviceId());
}

void SyncControllerTests::interruptedSnapshotRemovalFinishesAtStartup()
{
    // 整体替换时快照里没有某一天的今日目标：以快照为准，本机要删掉这一天。进库之后、删掉之前被结束的话，
    // 以前下次启动会把本机还留着的这一天当成本机改动记回去、再发给另一台，把快照里没有的目标带回来。
    const QString goal = SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-20"));
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        QVERIFY(AppSettings::instance()->setDailyFocusGoal(QStringLiteral("2026-09-20"), 90));
        QCOMPARE(SyncStore().syncedSetting(goal), QStringLiteral("90"));
    }
    SyncBatch snapshot = SyncStore().exportSnapshot();
    snapshot.device = QStringLiteral("fedcba9876543210fedcba9876543210");
    snapshot.settings.erase(std::remove_if(snapshot.settings.begin(), snapshot.settings.end(),
                                           [&goal](const SyncSettingRecord& setting) { return setting.key == goal; }),
                            snapshot.settings.end());
    const SyncStore::ApplyResult replaced = SyncStore().replaceWithSnapshot(snapshot);
    QVERIFY2(replaced.ok, qPrintable(replaced.error));
    QVERIFY(replaced.removedSettings.contains(goal));
    // 没有写回（被结束了）：本机还留着这一天。
    QCOMPARE(AppSettings::instance()->dailyFocusGoalMinutesForDate(QStringLiteral("2026-09-20")), 90);

    SyncController relaunched(macPlatform(cloudFolder()));
    relaunched.initialize();
    QCOMPARE(AppSettings::instance()->dailyFocusGoalMinutesForDate(QStringLiteral("2026-09-20")), 0);
    QVERIFY(!settingRow(goal).exists);
    QVERIFY(SyncStore().pendingSettingWriteBacks().isEmpty());
}

void SyncControllerTests::longMemoConflictsHaveShortSummariesAndCopyableOriginals()
{
    // 产品保证：长正文冲突摘要有界，日志及复制数据保留完整输掉的一版；空标题用正文首行识别。
    // 第 40 个字符是占两个 UTF-16 单元的表情，摘要不能截掉半个字符。
    const QString emoji = QString::fromUcs4(U"🙂");
    const QString lost = QStringLiteral("正文首行\r\n") + QString(33, QChar(0x7532)) + emoji
        + QString(3000, QChar(0x7532)) + QStringLiteral("\n被覆盖的独有末尾");
    const QString kept = QStringLiteral("另一版\n") + QString(3100, QChar(0x4e59)) + QStringLiteral("\n保留的独有末尾");
    const int id = MemoService::instance()->createMemo(QString(), lost);
    QVERIFY(id > 0);
    SyncRecord record;
    for (const auto& candidate : SyncStore().collectPending().records) {
        if (candidate.table == QLatin1String("memos")) { record = candidate; }
    }
    QVERIFY(!record.syncId.isEmpty());
    const auto local = record.fields.value(QStringLiteral("body"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    QVERIFY(local.version.device != remote && local.value.toString() == lost && lost.size() > 200);
    record.fields.clear();
    record.fields.insert(QStringLiteral("body"), {kept, {local.version.time + 100, remote}, {}});
    SyncBatch incoming; incoming.device = remote; incoming.records = {record};
    const auto result = SyncStore().applyRemote(incoming);
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(result.conflictsLogged, 1);
    QCOMPARE(SyncStore().syncLog(10).first().lostValue, lost);
    SyncController controller(macPlatform(cloudFolder()));
    const QVariantList logs = controller.syncLog(10);
    QCOMPARE(logs.size(), 1);
    const QVariantMap log = logs.first().toMap();
    QCOMPARE(log.value(QStringLiteral("title")).toString(), QStringLiteral("备忘录「正文首行」"));
    QCOMPARE(log.value(QStringLiteral("fieldLabel")).toString(), QStringLiteral("正文"));
    QCOMPARE(log.value(QStringLiteral("lostValue")).toString(), lost);
    QCOMPARE(log.value(QStringLiteral("keptValue")).toString(), kept);
    QVERIFY(log.value(QStringLiteral("canCopyLostValue")).toBool());
    const QString summary = log.value(QStringLiteral("summary")).toString();
    QVERIFY(summary.size() < 200);
    QVERIFY(summary.contains(emoji));
    QVERIFY(summary.contains(QStringLiteral("…（共 %1 字）").arg(lost.toUcs4().size())));
    QVERIFY(!summary.contains(QStringLiteral("独有末尾")));
}

void SyncControllerTests::memoDeletedElsewhereShowsCopyNotConflict()
{
    // 产品保证：另一台删掉一条备忘录后，日志写的是「已删除」和删除前的内容，不说「修改没有生效」，
    // 并且可以复制找回；空的不出现。
    const int id = MemoService::instance()->createMemo(QStringLiteral("张宇 36 讲"), QStringLiteral("第 8 讲做完"));
    QVERIFY(id > 0);
    SyncStore store;
    const SyncBatch sent = store.collectPending();
    SyncRecord memo;
    for (const auto& candidate : sent.records) {
        if (candidate.table == QLatin1String("memos")) { memo = candidate; }
    }
    QVERIFY(!memo.syncId.isEmpty());
    // 内容已经发出去了：这正是「不知道对方删之前看没看到」的情形。
    QVERIFY(store.acknowledge(sent));
    QVERIFY(store.collectPending().records.isEmpty());

    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncRecord gone;
    gone.table = QStringLiteral("memos");
    gone.syncId = memo.syncId;
    gone.deleted = true;
    gone.deleteVersion = {memo.fields.value(QStringLiteral("body")).version.time + 100, remote};
    gone.deleteKind = QStringLiteral("delete");
    SyncBatch incoming; incoming.device = remote; incoming.records = {gone};
    const auto result = store.applyRemote(incoming);
    QVERIFY2(result.ok, qPrintable(result.error));

    SyncController controller(macPlatform(cloudFolder()));
    const QVariantList logs = controller.syncLog(10);
    QCOMPARE(logs.size(), 2);
    QStringList copied;
    for (const QVariant& value : logs) {
        const QVariantMap log = value.toMap();
        QCOMPARE(log.value(QStringLiteral("kindLabel")).toString(), QStringLiteral("已删除"));
        const QString summary = log.value(QStringLiteral("summary")).toString();
        QVERIFY2(summary.contains(QStringLiteral("删除前的「%1」").arg(log.value(QStringLiteral("fieldLabel")).toString())),
                 qPrintable(summary));
        QVERIFY2(!summary.contains(QStringLiteral("没有生效")), qPrintable(summary));
        QVERIFY(log.value(QStringLiteral("canCopyLostValue")).toBool());
        copied.append(log.value(QStringLiteral("lostValue")).toString());
    }
    copied.sort();
    QCOMPARE(copied, QStringList({QStringLiteral("张宇 36 讲"), QStringLiteral("第 8 讲做完")}));
}

void SyncControllerTests::epochFailureAfterRestoreHaltsSyncAndAllowsRetry()
{
    // 保证恢复后建立新纪元的事务失败时控制器不得启动同步引擎，保留本地恢复结果，暴露可观察错误并允许重试。
    // beginEpochAfterRestore() 是原子事务：任一失败整体回滚，device_id 保持备份值不变。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString thisDevice = SyncStore().deviceId();
    QVERIFY(!addTask(QStringLiteral("备份前任务")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    const QString backup = m_data->filePath(QStringLiteral("backup.sqlite"));
    QVERIFY(copyDatabaseTo(backup));

    // 修改备份中的 device_id 为异机标识，验证事务失败时原子回滚保持备份值
    const QString backupDevice = QStringLiteral("backup_device_identity_9876");
    {
        const QString tempConn = QStringLiteral("temp_backup_conn");
        {
            QSqlDatabase backupDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), tempConn);
            backupDb.setDatabaseName(backup);
            QVERIFY(backupDb.open());
            QSqlQuery update(backupDb);
            QVERIFY(update.exec(QStringLiteral("UPDATE sync_state SET value = '%1' WHERE key = 'device_id'").arg(backupDevice)));
            backupDb.close();
        }
        QSqlDatabase::removeDatabase(tempConn);
    }

    QVERIFY(!addTask(QStringLiteral("备份后任务")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(replaceDatabaseWith(backup));

    // 换库后确认库里的 device_id 是备份里的异机标识
    QCOMPARE(SyncStore().deviceId(), backupDevice);

    // 故障注入点：通过临时 SQLite 触发器让 sync_state 中 epoch 的 UPDATE 触发 ABORT，
    // 导致 beginEpochAfterRestore 中的事务失败并回滚。不依赖系统磁盘已满、真实 iCloud 或外部未定义状态。
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_epoch_abort BEFORE UPDATE OF value ON sync_state "
        "WHEN NEW.key = 'epoch' "
        "BEGIN SELECT RAISE(ABORT, 'injected epoch abort'); END;")));

    // 前置断言：验证注入点能稳定导致 beginEpochAfterRestore 失败且保持原纪元与设备标识不变
    SyncStore probeStore;
    const qint64 epochBefore = probeStore.epoch();
    QVERIFY(!probeStore.beginEpochAfterRestore(epochBefore, thisDevice));
    QCOMPARE(probeStore.epoch(), epochBefore);
    QCOMPARE(probeStore.deviceId(), backupDevice);

    QSignalSpy notices(&controller, &SyncController::notice);

    // 调用被测路径：执行 finishRestore(true)
    controller.finishRestore(true);

    // 阶段 1 核心保证 1：建立新纪元失败时，同步引擎严格禁止启动（fail-closed），防止在旧纪元或错误状态下同步
    QVERIFY(!controller.engine()->isRunning());

    // 阶段 1 核心保证 2：本地恢复出来的数据完整保留，不因纪元失败而损毁
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("备份前任务")});

    // 阶段 1 核心保证 3：事务整体回滚，device_id 保持备份中的值，未被部分更新
    QCOMPARE(SyncStore().deviceId(), backupDevice);

    // 阶段 1 核心保证 4：暴露可观察错误状态与通知
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusDetail(), QStringLiteral("恢复备份后建立同步新纪元失败，同步已暂停以保护数据。"));
    QCOMPARE(notices.count(), 1);

    // 阶段 1 核心保证 5：撤销注入后，提供可重试动作（调用 syncNow），新纪元成功建立，device_id 恢复为本机标识，并恢复正常同步
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_epoch_abort")));
    controller.syncNow();

    QCOMPARE(SyncStore().epoch(), epochBefore + 1);
    QCOMPARE(SyncStore().deviceId(), thisDevice);
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QVERIFY(!controller.hasProblem());
}

void SyncControllerTests::folderFailureAfterRestoreHaltsSyncAndAllowsRetryWithoutEpochBumping()
{
    // 保证在备份恢复后若仅保留同步文件夹步骤失败（epoch已建立成功），控制器保持停止（fail-closed），
    // 暴露错误状态；且在多次重试或最终成功重试过程中，绝不重复递增 epoch，严格保证一次恢复最多建立一个新 epoch。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    const QString thisFolder = SyncStore().folderId();
    const qint64 epochBefore = SyncStore().epoch();

    // 准备一份没有 folderId 的备份（模拟加入同步前的备份或异机备份）
    const QString otherPath = m_data->filePath(QStringLiteral("other_folder.sqlite"));
    const QString currentPath = DatabaseManager::instance()->database().databaseName();
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(otherPath));
    QVERIFY(!addTask(QStringLiteral("备份任务")).isEmpty());
    QVERIFY(SyncStore().folderId().isEmpty());
    const QString backupPath = m_data->filePath(QStringLiteral("folder_backup.sqlite"));
    QVERIFY(copyDatabaseTo(backupPath));
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(currentPath));

    // 进入恢复流程
    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(replaceDatabaseWith(backupPath));

    // 故障注入点：拦截 sync_state 中 folder_id 的写入（覆盖 INSERT 与 UPDATE），
    // 使得 beginEpochAfterRestore 成功，但随后的 setFolderId 失败。
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_folder_insert_abort BEFORE INSERT ON sync_state "
        "WHEN NEW.key = 'folder_id' "
        "BEGIN SELECT RAISE(ABORT, 'injected folder insert abort'); END;")));
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_folder_update_abort BEFORE UPDATE OF value ON sync_state "
        "WHEN NEW.key = 'folder_id' "
        "BEGIN SELECT RAISE(ABORT, 'injected folder update abort'); END;")));

    // 前置断言：验证注入生效，setFolderId 必失败
    QVERIFY(!SyncStore().setFolderId(thisFolder));

    QSignalSpy notices(&controller, &SyncController::notice);

    // 调用被测路径：执行 finishRestore(true)
    controller.finishRestore(true);

    // 核心保证 1：保留文件夹失败时，同步引擎严格禁止启动（fail-closed）
    QVERIFY(!controller.engine()->isRunning());

    // 核心保证 2：备份恢复的数据已落盘保留
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("备份任务")});

    // 核心保证 3：暴露可观察错误状态与通知
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusDetail(), QStringLiteral("恢复备份后保留同步文件夹失败，同步已暂停以保护数据。"));
    QCOMPARE(notices.count(), 1);

    // 核心保证 4：此时 epoch 已成功递增 1，但 folderId 仍为空
    QCOMPARE(SyncStore().epoch(), epochBefore + 1);
    QCOMPARE(SyncStore().folderId(), QString());

    // 核心保证 5：在未解除注入前调用 syncNow() 重试，不得重复递增 epoch！
    controller.syncNow();
    QVERIFY(!controller.engine()->isRunning());
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QCOMPARE(SyncStore().epoch(), epochBefore + 1); // 严格保持 epoch 不重复递增！

    // 核心保证 6：解除注入后调用 syncNow() 重试成功，folderId 成功保留，且 epoch 仍然为 epochBefore + 1
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_folder_insert_abort")));
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_folder_update_abort")));
    controller.syncNow();

    SyncStore after;
    QCOMPARE(after.folderId(), thisFolder);
    QCOMPARE(after.epoch(), epochBefore + 1); // 保证一次恢复最多建立一个新 epoch
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QVERIFY(!controller.hasProblem());
}

void SyncControllerTests::restoreEpochFailureBlocksNewController()
{
    // 保证恢复备份后建立新纪元失败时，即使旧控制器销毁并重新构造新实例，新控制器仍必须阻止引擎启动并暴露错误问题。
    const QString backup = m_data->filePath(QStringLiteral("backup_epoch_fail.sqlite"));
    {
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        controller.setEnabled(true);
        QVERIFY(waitIdle(controller.engine()));
        QVERIFY(!addTask(QStringLiteral("恢复前任务")).isEmpty());
        controller.syncNow();
        QVERIFY(waitIdle(controller.engine()));

        QVERIFY(copyDatabaseTo(backup));

        QVERIFY(!addTask(QStringLiteral("恢复后任务")).isEmpty());
        controller.syncNow();
        QVERIFY(waitIdle(controller.engine()));

        controller.prepareForRestore();
        QVERIFY(!controller.engine()->isRunning());
        QVERIFY(replaceDatabaseWith(backup));

        // 安装 BEFORE UPDATE epoch 的 ABORT 触发器
        QSqlQuery trigger(DatabaseManager::instance()->database());
        QVERIFY(trigger.exec(QStringLiteral(
            "CREATE TRIGGER test_inject_epoch_abort_new_ctrl BEFORE UPDATE OF value ON sync_state "
            "WHEN NEW.key = 'epoch' "
            "BEGIN SELECT RAISE(ABORT, 'injected epoch abort for new ctrl'); END;")));

        controller.finishRestore(true);
        // 断言旧 controller 停下
        QVERIFY(!controller.engine()->isRunning());
        QVERIFY(controller.hasProblem());
    }

    // 销毁旧 controller（保留数据库、隔离 INI 和触发器），构造新 controller 并 initialize
    SyncController newController(macPlatform(cloudFolder()));
    newController.initialize();

    // 严格断言：跨控制器实例仍必须阻断引擎运行并暴露问题
    QVERIFY(!newController.engine() || !newController.engine()->isRunning());
    QVERIFY(newController.hasProblem());

    // 补充验证：解除触发器，关闭并重新打开数据库，构造另一实例；重试利用同 token 幂等成功并安全删除日志
    {
        QSqlQuery trigger(DatabaseManager::instance()->database());
        QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_epoch_abort_new_ctrl")));
    }
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(dbPath));

    SyncController reloadedController(macPlatform(cloudFolder()));
    reloadedController.initialize();
    QVERIFY(reloadedController.hasProblem());
    QVERIFY(!reloadedController.engine() || !reloadedController.engine()->isRunning());

    reloadedController.syncNow();
    QVERIFY(reloadedController.engine() && reloadedController.engine()->isRunning());
    QVERIFY(!reloadedController.hasProblem());
    QVERIFY(!QFileInfo::exists(dbPath + QStringLiteral(".sync-restore.json")));
}

void SyncControllerTests::failedSecondRestoreKeepsOriginalRecoveryBlock()
{
    // 保证在首次恢复备份因新纪元建立失败而暂停同步后，后续一次取消或失败的恢复操作（finishRestore(false)）绝不能清除原有的恢复阻断，引擎必须继续保持停止且暴露问题。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!addTask(QStringLiteral("初次任务")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    const QString backup = m_data->filePath(QStringLiteral("backup_second_restore.sqlite"));
    QVERIFY(copyDatabaseTo(backup));

    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(replaceDatabaseWith(backup));

    // 安装 BEFORE UPDATE epoch 的 ABORT 触发器
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_epoch_abort_second_restore BEFORE UPDATE OF value ON sync_state "
        "WHEN NEW.key = 'epoch' "
        "BEGIN SELECT RAISE(ABORT, 'injected epoch abort for second restore'); END;")));

    controller.finishRestore(true);
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());

    // 不解除触发器，调用 prepareForRestore() 与 finishRestore(false)（模拟第二次恢复操作失败，库原样保留）
    controller.prepareForRestore();
    controller.finishRestore(false);

    // 严格断言：第二次恢复失败绝不能冲掉第一次的恢复阻断，引擎仍必须停止且具有错误问题（当前预计红灯失败）
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
}

void SyncControllerTests::secondSuccessfulRestorePreservesOriginalDeviceAndFolder()
{
    // 保证首次恢复异机备份因新纪元建立失败暂停后，再次执行恢复同一异机备份成功时，设备标识与加入文件夹仍还原为原本机身份，而不是残留的异机身份。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    const QString originalDevice = SyncStore().deviceId();
    const QString originalFolder = SyncStore().folderId();
    const qint64 originalEpoch = SyncStore().epoch();
    QVERIFY(!originalDevice.isEmpty());
    QVERIFY(!addTask(QStringLiteral("本机原任务")).isEmpty());
    controller.syncNow();
    QVERIFY(waitIdle(controller.engine()));

    // 准备一份异机备份：将备份库里的 device_id 改为异机标识
    const QString backup = m_data->filePath(QStringLiteral("backup_reentrant_other.sqlite"));
    QVERIFY(copyDatabaseTo(backup));
    const QString otherDevice = QStringLiteral("fedcba9876543210fedcba9876543210");
    QVERIFY(otherDevice != originalDevice);
    {
        const QString tempConn = QStringLiteral("temp_reentrant_conn");
        {
            QSqlDatabase backupDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), tempConn);
            backupDb.setDatabaseName(backup);
            QVERIFY(backupDb.open());
            QSqlQuery update(backupDb);
            QVERIFY(update.exec(QStringLiteral("UPDATE sync_state SET value = '%1' WHERE key = 'device_id'").arg(otherDevice)));
            backupDb.close();
        }
        QSqlDatabase::removeDatabase(tempConn);
    }

    // 第一次恢复：换入异机备份并注入 epoch 失败
    controller.prepareForRestore();
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(replaceDatabaseWith(backup));
    QCOMPARE(SyncStore().deviceId(), otherDevice);

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_epoch_abort_reentrant BEFORE UPDATE OF value ON sync_state "
        "WHEN NEW.key = 'epoch' "
        "BEGIN SELECT RAISE(ABORT, 'injected epoch abort reentrant'); END;")));

    controller.finishRestore(true);
    // 验证第一次恢复失败且阻断生效
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());

    // 解除注入
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_epoch_abort_reentrant")));

    // 再次调用 prepareForRestore()，重新换入同一异机备份，执行第二次恢复
    controller.prepareForRestore();
    QVERIFY(replaceDatabaseWith(backup));
    QCOMPARE(SyncStore().deviceId(), otherDevice);

    controller.finishRestore(true);

    // 核心保证：恢复的是原本机 device_id（不是第一次失败后留在库里的异机 id），folder 仍是原本机 folder
    QCOMPARE(SyncStore().deviceId(), originalDevice);
    QCOMPARE(SyncStore().folderId(), originalFolder);
    QCOMPARE(SyncStore().epoch(), originalEpoch + 1);
    QVERIFY(controller.engine()->isRunning());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
    QVERIFY(!controller.hasProblem());
    QCOMPARE(taskTitles(DatabaseManager::instance()->database()), QStringList{QStringLiteral("本机原任务")});
}

void SyncControllerTests::epochTransactionRollsBackWhenDeviceUpdateFails()
{
    // 保证 SyncStore::beginEpochAfterRestore 在更新 device_id 失败时将已递增的纪元与待发送队列完整原子回滚。
    // 产生本地待发送记录以验证 outbox 在事务回滚时未被误清空
    QVERIFY(!addTask(QStringLiteral("测试待发送任务")).isEmpty());

    SyncStore store;
    const qint64 epochBefore = store.epoch();
    const QString deviceBefore = store.deviceId();

    // 记录并断言前提：deviceBefore 非空，outbox 中有待发送记录
    QVERIFY(!deviceBefore.isEmpty());
    QSqlQuery countQuery(DatabaseManager::instance()->database());
    QVERIFY(countQuery.exec(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")));
    QVERIFY(countQuery.next());
    const int outboxCountBefore = countQuery.value(0).toInt();
    QVERIFY(outboxCountBefore > 0);

    const QString otherDevice = QStringLiteral("0123456789abcdef0123456789abcdef");
    QVERIFY(otherDevice != deviceBefore);

    // 安装 BEFORE UPDATE OF value ON sync_state WHEN NEW.key='device_id' 的 ABORT 触发器
    // beginEpochAfterRestore 先执行 UPDATE epoch 成功，再执行 UPDATE device_id 触发 ABORT，进而验证事务回滚
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER test_inject_device_abort_tx BEFORE UPDATE OF value ON sync_state "
        "WHEN NEW.key = 'device_id' "
        "BEGIN SELECT RAISE(ABORT, 'injected device abort for tx'); END;")));

    const bool success = store.beginEpochAfterRestore(epochBefore, otherDevice);
    QVERIFY(!success);

    // 断言事务回滚：epoch 恢复原值、device 原值不变、原 outbox 记录仍在
    QCOMPARE(store.epoch(), epochBefore);
    QCOMPARE(store.deviceId(), deviceBefore);

    QVERIFY(countQuery.exec(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")));
    QVERIFY(countQuery.next());
    QCOMPARE(countQuery.value(0).toInt(), outboxCountBefore);

    // 删除触发器再重试，确认 epoch 只加 1 且 device 改变
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER test_inject_device_abort_tx")));
    QVERIFY(store.beginEpochAfterRestore(epochBefore, otherDevice));

    QCOMPARE(store.epoch(), epochBefore + 1);
    QCOMPARE(store.deviceId(), otherDevice);
}


void SyncControllerTests::settingsAccessErrorOnDisableStopsEngineAndRecoversOnRetry()
{
    // 保证在偏好存储不可写时关闭同步能够停止当前引擎并将运行态置为关闭且暴露错误，故障解除后重试关闭可持久化成功并清除错误。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.isEnabled());
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());

    // 故障注入点：获取当前隔离 INI 文件路径，替换为同名目录导致 AccessError
    QSettings probeSettings;
    const QString iniPath = probeSettings.fileName();
    QVERIFY(!iniPath.isEmpty());
    QFile::remove(iniPath);
    QVERIFY(QDir().mkdir(iniPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(iniPath).isDir()) {
            QDir(iniPath).removeRecursively();
        }
        QFile emptyFile(iniPath);
        if (emptyFile.open(QIODevice::WriteOnly)) {
            emptyFile.close();
        }
    });

    // 动作前断言：底层偏好后端处于不可写状态
    {
        QSettings testProbe;
        testProbe.setValue(QStringLiteral("probe_key"), 1);
        testProbe.sync();
        QCOMPARE(testProbe.status(), QSettings::AccessError);
    }

    // 执行关闭同步
    controller.setEnabled(false);

    // 断言：运行态为关闭、引擎已停止、暴露设置错误
    QCOMPARE(controller.isEnabled(), false);
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(!controller.statusDetail().isEmpty());

    // 解除故障注入
    QVERIFY(QDir(iniPath).removeRecursively());
    {
        QFile emptyFile(iniPath);
        QVERIFY(emptyFile.open(QIODevice::WriteOnly));
        emptyFile.close();
    }
    cleanupGuard.dismiss();

    // 再次调用 setEnabled(false)：重试持久化成功，错误被清除
    controller.setEnabled(false);
    QCOMPARE(controller.isEnabled(), false);
    QVERIFY(!controller.hasProblem());
    QCOMPARE(controller.statusKey(), QStringLiteral("stopped"));

    // 单独检查持久化结果
    {
        QSettings readSettings;
        QCOMPARE(readSettings.value(QStringLiteral("sync/enabled")).toBool(), false);
    }
}

// 保证关闭设置落盘失败后，偏好仍只读或权限已经恢复的重启，都不会直接恢复旧的开启状态。
void SyncControllerTests::failedDisableSurvivesProcessRestart_data()
{
    QTest::addColumn<bool>("repairPermissions");
    QTest::newRow("preferences-still-read-only") << false;
    QTest::newRow("permissions-repaired-with-old-true") << true;
}

// 保证失败关闭的意图跨进程阻断同步；用户修复存储并明确重开后，正常自动启动仍然可用。
void SyncControllerTests::failedDisableSurvivesProcessRestart()
{
    QFETCH(bool, repairPermissions);
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.isEnabled());
    QVERIFY(controller.engine()->isRunning());

    QString iniPath;
    {
        QSettings settings;
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
        iniPath = settings.fileName();
    }
    const QString directory = QFileInfo(iniPath).absolutePath();
    const auto filePermissions = QFileInfo(iniPath).permissions();
    const auto directoryPermissions = QFileInfo(directory).permissions();
    const auto restorePermissions = qScopeGuard([&] {
        QFile::setPermissions(directory, directoryPermissions);
        QFile::setPermissions(iniPath, filePermissions);
    });
    // 保留真实的enabled=true磁盘文件，只剥夺写权限；用同名目录替换会抹掉这项关键前提。
    QVERIFY(QFile::setPermissions(iniPath, QFileDevice::ReadOwner));
    QVERIFY(QFile::setPermissions(directory, QFileDevice::ReadOwner | QFileDevice::ExeOwner));
    {
        QFile probe(iniPath);
        QVERIFY(!probe.open(QIODevice::WriteOnly | QIODevice::Append));
    }
    controller.setEnabled(false);
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    if (repairPermissions) {
        QVERIFY(QFile::setPermissions(directory, directoryPermissions));
        QVERIFY(QFile::setPermissions(iniPath, filePermissions));
    }
    {
        QFile disk(iniPath);
        QVERIFY(disk.open(QIODevice::ReadOnly));
        QVERIFY(disk.readAll().contains("enabled=true"));
    }
    QString error;
    const auto restarted = readRestartState(m_preferences.path(),
        m_data->filePath(QStringLiteral("this.sqlite")), cloudFolder(), &error);
    QVERIFY2(!restarted.isEmpty(), qPrintable(error));
    QCOMPARE(restarted.value(QStringLiteral("enabled")), QJsonValue(false));
    QCOMPARE(restarted.value(QStringLiteral("running")), QJsonValue(false));

    QVERIFY(QFile::setPermissions(directory, directoryPermissions));
    QVERIFY(QFile::setPermissions(iniPath, filePermissions));
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.isEnabled());
    QVERIFY(!controller.hasProblem());
    const auto reenabled = readRestartState(m_preferences.path(),
        m_data->filePath(QStringLiteral("this.sqlite")), cloudFolder(), &error);
    QVERIFY2(!reenabled.isEmpty(), qPrintable(error));
    QCOMPARE(reenabled.value(QStringLiteral("enabled")), QJsonValue(true));
    QCOMPARE(reenabled.value(QStringLiteral("running")), QJsonValue(true));
}

// 保证合法关闭记录及无法辨识的占位都阻断自动启动，未知文件不会被显式开启顺手覆盖或删除。
void SyncControllerTests::disableIntentBlocksUnsafeStartup_data()
{
    QTest::addColumn<QString>("kind");
    for (const char* kind : {"valid", "unknown", "oversized", "directory", "dangling-link"})
        QTest::newRow(kind) << QString::fromLatin1(kind);
}

// 保证旧偏好即使写着开启，关闭记录优先；未知记录保留原状，只有合法记录允许用户显式解除。
void SyncControllerTests::disableIntentBlocksUnsafeStartup()
{
    QFETCH(QString, kind);
    { QSettings settings; settings.setValue(QStringLiteral("sync/enabled"), true); settings.sync(); }
    const QString path = m_data->filePath(QStringLiteral("this.sqlite.sync-disabled"));
    const QByteArray content = kind == QStringLiteral("valid") ? QByteArray("sync-disabled-v1\n")
        : kind == QStringLiteral("oversized") ? QByteArray(65, 'x') : QByteArray("unknown-file");
    if (kind == QStringLiteral("directory")) QVERIFY(QDir().mkdir(path));
    else if (kind == QStringLiteral("dangling-link"))
        QVERIFY(QFile::link(m_data->filePath(QStringLiteral("absent-target")), path));
    else {
        QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write(content), qint64(content.size()));
    }
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    if (kind != QStringLiteral("valid")) {
        controller.setEnabled(true);
        QVERIFY(!controller.isEnabled());
        QVERIFY(controller.hasProblem());
        QVERIFY(QFileInfo(path).exists() || QFileInfo(path).isSymLink());
        if (kind == QStringLiteral("unknown") || kind == QStringLiteral("oversized")) {
            QFile file(path); QVERIFY(file.open(QIODevice::ReadOnly)); QCOMPARE(file.readAll(), content);
        }
    }
}

// 保证开启偏好已保存但关闭记录删除失败时，引擎仍停止且重启继续关闭，不伪报开启成功。
void SyncControllerTests::disableIntentRemovalFailureKeepsSyncStopped()
{
    const QString path = m_data->filePath(QStringLiteral("this.sqlite.sync-disabled"));
    { QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write("sync-disabled-v1\n"), qint64(17)); }
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    QVERIFY(!controller.isEnabled());
    const auto permissions = QFileInfo(m_data->path()).permissions();
    const auto restore = qScopeGuard([&] { QFile::setPermissions(m_data->path(), permissions); });
    QVERIFY(QFile::setPermissions(m_data->path(), QFileDevice::ReadOwner | QFileDevice::ExeOwner));
    controller.setEnabled(true);
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    QVERIFY(QFileInfo::exists(path));
    QVERIFY(QFile::setPermissions(m_data->path(), permissions));
    QString error;
    const auto state = readRestartState(m_preferences.path(), m_data->filePath(QStringLiteral("this.sqlite")), cloudFolder(), &error);
    QVERIFY2(!state.isEmpty(), qPrintable(error));
    QCOMPARE(state.value(QStringLiteral("enabled")), QJsonValue(false));
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.isEnabled());
    QVERIFY(!QFileInfo::exists(path));
}

// 保证两个关闭持久化通道都不可用时立即停同步，并明确告知重启风险，不能暗示已经保存。
void SyncControllerTests::bothDisableStoresFailExposesRestartRisk()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize(); controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.engine()->isRunning());
    const QString path = m_data->filePath(QStringLiteral("this.sqlite.sync-disabled"));
    QVERIFY(QDir().mkdir(path));
    const QString ini = QSettings().fileName();
    const auto filePermissions = QFileInfo(ini).permissions();
    const auto restore = qScopeGuard([&] { QFile::setPermissions(ini, filePermissions); });
    QVERIFY(QFile::setPermissions(ini, QFileDevice::ReadOwner));
    // 禁止原子替换也禁止直接写入，让偏好通道确实失败；关闭日志用目录占位独立阻断。
    const QString directory = QFileInfo(ini).absolutePath();
    const auto directoryPermissions = QFileInfo(directory).permissions();
    const auto restoreDirectory = qScopeGuard([&] { QFile::setPermissions(directory, directoryPermissions); });
    QVERIFY(QFile::setPermissions(directory, QFileDevice::ReadOwner | QFileDevice::ExeOwner));
    controller.setEnabled(false);
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    QVERIFY(controller.statusDetail().contains(QStringLiteral("重启")));
    QVERIFY(controller.statusDetail().contains(QStringLiteral("无法保证")));
}

// 保证恢复旧数据库不会抹掉本机关闭意图，恢复后旧开启配置也不能绕过独立记录。
void SyncControllerTests::restoredDatabaseKeepsIndependentDisableIntent()
{
    const QString database = m_data->filePath(QStringLiteral("this.sqlite"));
    BackupService backup;
    backup.configure(QSettings().fileName(), m_data->filePath(QStringLiteral("backups")));
    const QString snapshot = m_data->filePath(QStringLiteral("old.tomatobackup"));
    QVERIFY(backup.createBackup(snapshot));
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize(); controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    controller.setEnabled(false);
    QVERIFY(backup.restoreBackup(snapshot));
    // 人为保留旧true，确保断言依靠独立关闭记录而非备份或Qt缓存碰巧保持false。
    { QSettings settings; settings.setValue(QStringLiteral("sync/enabled"), true); settings.sync(); }
    QString error;
    const auto state = readRestartState(m_preferences.path(), database, cloudFolder(), &error);
    QVERIFY2(!state.isEmpty(), qPrintable(error));
    QCOMPARE(state.value(QStringLiteral("enabled")), QJsonValue(false));
    QCOMPARE(state.value(QStringLiteral("running")), QJsonValue(false));
}

// 保证关闭过程的同步属性通知不能重入开启，把内存和已提交的关闭意图撕成两个状态。
void SyncControllerTests::disableNotificationCannotReenableBeforeCommit()
{
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize(); controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    bool attempted = false;
    connect(&controller, &SyncController::enabledChanged, this, [&] {
        if (!controller.isEnabled() && !attempted) { attempted = true; controller.setEnabled(true); }
    });
    controller.setEnabled(false);
    QVERIFY(attempted);
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.engine()->isRunning());
    QCOMPARE(QSettings().value(QStringLiteral("sync/enabled")).toBool(), false);
}

void SyncControllerTests::settingsAccessErrorOnEnableBlocksEngineAndRecoversOnRetry()
{
    // 保证在偏好存储不可写时开启同步被阻断且不启动引擎，故障解除后再次开启可成功启动。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(false);
    QVERIFY(!controller.isEnabled());
    QVERIFY(!controller.hasProblem());

    // 故障注入点：替换 INI 为同名目录
    QSettings probeSettings;
    const QString iniPath = probeSettings.fileName();
    QVERIFY(!iniPath.isEmpty());
    QFile::remove(iniPath);
    QVERIFY(QDir().mkdir(iniPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(iniPath).isDir()) {
            QDir(iniPath).removeRecursively();
        }
        QFile emptyFile(iniPath);
        if (emptyFile.open(QIODevice::WriteOnly)) {
            emptyFile.close();
        }
    });

    // 动作前断言：偏好后端不可写
    {
        QSettings testProbe;
        testProbe.setValue(QStringLiteral("probe_key"), 1);
        testProbe.sync();
        QCOMPARE(testProbe.status(), QSettings::AccessError);
    }

    // 执行开启同步
    controller.setEnabled(true);

    // 断言：保持关闭、引擎未启动、暴露错误
    QCOMPARE(controller.isEnabled(), false);
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(!controller.statusDetail().isEmpty());

    // 解除故障注入
    QVERIFY(QDir(iniPath).removeRecursively());
    {
        QFile emptyFile(iniPath);
        QVERIFY(emptyFile.open(QIODevice::WriteOnly));
        emptyFile.close();
    }
    cleanupGuard.dismiss();

    // 恢复后再次开启同步：成功开启并启动引擎
    controller.setEnabled(true);
    QCOMPARE(controller.isEnabled(), true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
}

void SyncControllerTests::settingsAccessErrorOnAcceptFolderPreservesExistingEngineAndRecovers()
{
    // 保证更换同步文件夹持久化失败时保留现有引擎与旧文件夹运行态，故障解除后重新选择可成功切换。
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));

    const QString oldCloudFolder = cloudFolder();
    const QString newCloudFolder = m_data->filePath(QStringLiteral("cloud2/番茄Todo同步"));
    QVERIFY(QDir().mkpath(newCloudFolder));
    QVERIFY(QFile::copy(oldCloudFolder + QLatin1Char('/') + SyncFiles::markerFileName(),
                        newCloudFolder + QLatin1Char('/') + SyncFiles::markerFileName()));

    FakePicker picker;
    picker.bookmark = oldCloudFolder.toUtf8();
    picker.message = QStringLiteral("iCloud 云盘/番茄Todo同步");
    SyncController controller(ipadPlatform(&picker));
    controller.initialize();
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(controller.isEnabled());
    QVERIFY(controller.hasFolder());
    QVERIFY(waitIdle(controller.engine()));

    const QByteArray oldBookmark = QSettings().value(QStringLiteral("sync/bookmark")).toByteArray();
    SyncEngine* const oldEngine = controller.engine();
    QVERIFY(oldEngine != nullptr);

    // 故障注入点：替换 INI 为同名目录
    QSettings settings;
    const QString iniPath = settings.fileName();
    QVERIFY(!iniPath.isEmpty());
    QFile::remove(iniPath);
    QVERIFY(QDir().mkdir(iniPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(iniPath).isDir()) {
            QDir(iniPath).removeRecursively();
        }
        QFile emptyFile(iniPath);
        if (emptyFile.open(QIODevice::WriteOnly)) {
            emptyFile.close();
        }
    });

    // 动作前断言：偏好不可写
    {
        QSettings probe;
        probe.setValue(QStringLiteral("probe_key"), 1);
        probe.sync();
        QCOMPARE(probe.status(), QSettings::AccessError);
    }

    // 尝试选择新文件夹
    picker.bookmark = newCloudFolder.toUtf8();
    picker.message = QStringLiteral("新文件夹");
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());

    // 断言失败后：报错且暴露 hasProblem，但旧 engine、m_enabled 保持，并未切换到新文件夹
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QCOMPARE(controller.engine(), oldEngine);
    QCOMPARE(controller.isEnabled(), true);

    // 解除故障注入
    QVERIFY(QDir(iniPath).removeRecursively());
    {
        QFile emptyFile(iniPath);
        QVERIFY(emptyFile.open(QIODevice::WriteOnly));
        emptyFile.close();
    }
    cleanupGuard.dismiss();

    // 故障解除后重新选择新文件夹：成功切换
    controller.chooseFolder();
    QTRY_VERIFY(!controller.isChoosingFolder());
    QVERIFY(!controller.hasProblem());
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), newCloudFolder.toUtf8());
}

void SyncControllerTests::settingsAccessErrorOnBookmarkRefreshPreservesEngineAndExposesError()
{
    // 保证工作线程刷新书签写入持久化失败时暴露错误状态且不破坏当前引擎，解除故障后重试或恢复正常。
    std::unique_ptr<Peer> mac = openMacPeer();
    mac->engine->start();
    QVERIFY(waitIdle(mac->engine.get()));

    FakePicker picker;
    picker.bookmark = cloudFolder().toUtf8();
    QList<std::function<void(const QByteArray&)>> refreshers;
    SyncController controller(ipadPlatform(&picker, &refreshers));
    controller.initialize();
    controller.setEnabled(true);
    QTRY_VERIFY(controller.isEnabled());
    QVERIFY(waitIdle(controller.engine()));
    QCOMPARE(refreshers.size(), 2);

    std::function<void(const QByteArray&)> currentRefresher = refreshers.last();

    // 故障注入点：替换 INI 为同名目录
    QSettings settings;
    const QString iniPath = settings.fileName();
    QVERIFY(!iniPath.isEmpty());
    QFile::remove(iniPath);
    QVERIFY(QDir().mkdir(iniPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(iniPath).isDir()) {
            QDir(iniPath).removeRecursively();
        }
        QFile emptyFile(iniPath);
        if (emptyFile.open(QIODevice::WriteOnly)) {
            emptyFile.close();
        }
    });

    // 动作前断言：偏好不可写
    {
        QSettings probe;
        probe.setValue(QStringLiteral("probe_key"), 1);
        probe.sync();
        QCOMPARE(probe.status(), QSettings::AccessError);
    }

    // 在工作线程中调用刷新书签回调
    QThread* thread = QThread::create([currentRefresher] {
        currentRefresher(QByteArrayLiteral("刷新后的书签内容"));
    });
    thread->start();
    QVERIFY(thread->wait(5000));
    delete thread;

    // 投递一个主线程哨兵，等待 queued connection 在主线程中执行完毕
    bool processed = false;
    QMetaObject::invokeMethod(&controller, [&processed] { processed = true; }, Qt::QueuedConnection);
    QTRY_VERIFY(processed);

    // 断言错误状态：hasProblem 成立，statusKey 为 error，但当前引擎保持运行
    QVERIFY(controller.hasProblem());
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(controller.engine() && controller.engine()->isRunning());

    // 解除故障注入
    QVERIFY(QDir(iniPath).removeRecursively());
    {
        QFile emptyFile(iniPath);
        QVERIFY(emptyFile.open(QIODevice::WriteOnly));
        emptyFile.close();
    }
    cleanupGuard.dismiss();

    // 再次在工作线程中调用刷新回调：成功持久化并清除错误
    QThread* recoverThread = QThread::create([currentRefresher] {
        currentRefresher(QByteArrayLiteral("成功恢复的书签内容"));
    });
    recoverThread->start();
    QVERIFY(recoverThread->wait(5000));
    delete recoverThread;

    bool recoverProcessed = false;
    QMetaObject::invokeMethod(&controller, [&recoverProcessed] { recoverProcessed = true; }, Qt::QueuedConnection);
    QTRY_VERIFY(recoverProcessed);

    QVERIFY(!controller.hasProblem());
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(), QByteArrayLiteral("成功恢复的书签内容"));
}

void SyncControllerTests::preparedJournalOnRestartBlocksSyncAndAllowsFreshRestore()
{
    // 保证重启时遇到 prepared 恢复意图日志保持阻断，立即同步不启动引擎且不增加纪元，但允许发起新的合法恢复。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    // 写入处于 prepared 状态的恢复意图日志
    const QString prepOpId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString prepDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString prepFolder = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), prepOpId);
    obj.insert(QStringLiteral("epoch"), QStringLiteral("5"));
    obj.insert(QStringLiteral("deviceId"), prepDevice);
    obj.insert(QStringLiteral("folderId"), prepFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("prepared"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    // 模拟之前已开启同步，重启后保持开启配置
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    const qint64 initialEpoch = SyncStore().epoch();

    // 构造新控制器模拟进程重启启动
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    // 验证阻断：hasProblem 为 true，引擎未运行，说明为 prepared 未完成
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.statusDetail().contains(QStringLiteral("恢复意图")));

    // 点击立即同步：不得启动引擎，不得递增纪元
    controller.syncNow();
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(SyncStore().epoch(), initialEpoch);

    // 重新发起新的合法恢复
    QVERIFY(controller.prepareForRestore());
    controller.finishRestore(true);

    // 验证新恢复完成后成功启动引擎，恢复阻断解除，日志被安全清理
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::installedJournalOnRestartCompletesPendingStepsIdempotently()
{
    // 保证重启时遇到 installed 恢复日志加载待修复上下文，重试幂等执行未完成步骤，folder失败不重复增加纪元，全部成功后安全删除日志并启动。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString opId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 targetEpoch = 10;
    const QString targetDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString targetFolder = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();

    // 写入处于 installed 状态的恢复意图日志
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), opId);
    obj.insert(QStringLiteral("epoch"), QString::number(targetEpoch));
    obj.insert(QStringLiteral("deviceId"), targetDevice);
    obj.insert(QStringLiteral("folderId"), targetFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    // 模拟之前已开启同步，重启后保持开启配置
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    // 启动时必须保持阻断
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 动作前断言目标 folder 与现值不同
    QVERIFY(SyncStore().folderId() != targetFolder);

    // 注入 folder_id 写入失败（SQLite 的 INSERT OR REPLACE 触发 INSERT）
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER abort_folder_on_sync BEFORE INSERT ON sync_state "
        "WHEN NEW.key = 'folder_id' BEGIN SELECT RAISE(ABORT, 'injected folder failure'); END;")));

    // 点击立即同步：epoch 首次建立成功，但 folder 步骤失败，同步继续保持阻断
    controller.syncNow();
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);

    // 再次点击立即同步：因为 B1 operationId 幂等保护，绝不再次递增纪元
    controller.syncNow();
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 移除注入触发器
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER abort_folder_on_sync")));

    // 再次点击立即同步：完成剩余步骤，日志被安全删除，引擎启动
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QCOMPARE(SyncStore().folderId(), targetFolder);
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::corruptOrOversizedJournalBlocksSyncWithoutDeletingUnknownFiles()
{
    // 保证遇到损坏、超预算或同名目录占位的恢复日志时阻断同步并明确报错，绝不擅自删除或误删未知文件。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    // 子场景 1：损坏 JSON
    {
        QFile file(journalPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("{\"v\": 1, \"phase\": \"corrupted json without closing");
        file.close();

        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        QVERIFY(controller.hasProblem());
        QVERIFY(!controller.engine() || !controller.engine()->isRunning());
        // 损坏文件完好保留，未被擅自删除
        QVERIFY(QFileInfo::exists(journalPath));
        QVERIFY(QFile::remove(journalPath));
    }

    // 子场景 2：超预算文件 (>16KiB)，禁止用非法字符填充，需使用合法 JSON + 尾部合法 JSON 空白填至 17KiB
    {
        const QString validOpId = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const QString validDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
        const QString validFolder = QUuid::createUuid().toString(QUuid::WithoutBraces);
        QJsonObject validObj;
        validObj.insert(QStringLiteral("v"), 1);
        validObj.insert(QStringLiteral("operationId"), validOpId);
        validObj.insert(QStringLiteral("epoch"), QStringLiteral("1"));
        validObj.insert(QStringLiteral("deviceId"), validDevice);
        validObj.insert(QStringLiteral("folderId"), validFolder);
        validObj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
        validObj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());

        QByteArray content = QJsonDocument(validObj).toJson(QJsonDocument::Compact);
        const int targetSize = 17 * 1024;
        if (content.size() < targetSize) {
            content.append(QByteArray(targetSize - content.size(), ' '));
        }

        // 先通过 QJsonDocument::fromJson 断言其为合法 JSON（解析成功），且内容大小确已超限 (>16KiB)
        QJsonParseError parseErr;
        const QJsonDocument parsed = QJsonDocument::fromJson(content, &parseErr);
        QCOMPARE(parseErr.error, QJsonParseError::NoError);
        QVERIFY(!parsed.isNull());
        QVERIFY(content.size() > 16 * 1024);

        QFile file(journalPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(content);
        file.close();

        const qint64 initialEpoch = SyncStore().epoch();
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        QVERIFY(controller.hasProblem());
        QVERIFY(!controller.engine() || !controller.engine()->isRunning());
        QCOMPARE(controller.summaryText(), QStringLiteral("恢复日志损坏"));
        QVERIFY(controller.statusDetail().contains(QStringLiteral("16 KiB")));

        // 立即同步不能接受（纪元不推进，引擎不启动）
        controller.syncNow();
        QCOMPARE(SyncStore().epoch(), initialEpoch);
        QVERIFY(!controller.engine() || !controller.engine()->isRunning());
        QVERIFY(controller.hasProblem());

        // 重新 prepare 不能接受（返回 false 且报错明确含 16 KiB）
        QString prepErr;
        const bool prepOk = controller.prepareForRestore(&prepErr);
        QVERIFY(!prepOk);
        QVERIFY(!prepErr.isEmpty());
        QVERIFY(prepErr.contains(QStringLiteral("16 KiB")));

        // 超预算文件内容完整保留，未被擅自覆写或删除
        QFile checkFile(journalPath);
        QVERIFY(checkFile.open(QIODevice::ReadOnly));
        QCOMPARE(checkFile.readAll(), content);
        checkFile.close();

        QVERIFY(QFile::remove(journalPath));
    }

    // 子场景 3：同名目录占用
    {
        QVERIFY(QDir().mkdir(journalPath));

        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        QVERIFY(controller.hasProblem());
        QVERIFY(!controller.engine() || !controller.engine()->isRunning());
        // 目录完好保留，未被擅自删除
        QVERIFY(QFileInfo(journalPath).isDir());
        QVERIFY(QDir(journalPath).removeRecursively());
    }
}

void SyncControllerTests::cleanJournalRemovesOnlyValidJournalFile()
{
    // 保证恢复日志清理严格限定于与当前数据库绑定的普通恢复日志文件，绝不误删数据库或其它文件。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString siblingFile = dbPath + QStringLiteral(".other.data");

    // 创建伴随文件
    QFile sib(siblingFile);
    QVERIFY(sib.open(QIODevice::WriteOnly));
    sib.write("important sibling file");
    sib.close();

    // 正常执行一次恢复与收尾
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));
    controller.finishRestore(true);

    // 验证 journal 被删除，而数据库文件和伴随文件完整无损
    QVERIFY(!QFileInfo::exists(journalPath));
    QVERIFY(QFileInfo::exists(dbPath));
    QVERIFY(QFileInfo::exists(siblingFile));

    QFile::remove(siblingFile);
}

void SyncControllerTests::journalDeleteFailureBlocksSyncAndRetryDoesNotBumpEpoch()
{
    // 保证恢复日志删除失败时同步保持阻断，重试时不重复增加纪元，解除删除障碍后重试成功删除日志并恢复同步。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString opId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 targetEpoch = 15;
    const QString targetDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString targetFolder = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();

    // 写入处于 installed 状态的有效恢复意图日志
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), opId);
    obj.insert(QStringLiteral("epoch"), QString::number(targetEpoch));
    obj.insert(QStringLiteral("deviceId"), targetDevice);
    obj.insert(QStringLiteral("folderId"), targetFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    // 偏好中标记已开启同步
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    // 启动时遇到 installed 日志保持阻断
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 故障注入：将恢复日志文件暂存，并在原路径建立同名目录占位，使 deleteJournalFileSafely 拒绝删除非普通文件
    const QString backupJournal = journalPath + QStringLiteral(".bak");
    QVERIFY(QFile::rename(journalPath, backupJournal));
    QVERIFY(QDir().mkdir(journalPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(journalPath).isDir()) {
            QDir(journalPath).removeRecursively();
        }
        if (QFileInfo::exists(backupJournal)) {
            QFile::remove(backupJournal);
        }
    });

    // 点击立即同步：epoch 推进到 targetEpoch + 1，folder 写入成功，但删除日志因非普通文件占位失败，同步继续保持阻断
    controller.syncNow();
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QCOMPARE(SyncStore().deviceId(), targetDevice);
    QCOMPARE(SyncStore().folderId(), targetFolder);

    // 再次点击立即同步：因为 needsEpoch 已为 false，绝不再次递增纪元
    controller.syncNow();
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.hasProblem());

    // 解除占位：移除目录占位，还原合法恢复日志
    QVERIFY(QDir(journalPath).removeRecursively());
    QVERIFY(QFile::rename(backupJournal, journalPath));

    // 再次点击立即同步：成功删除日志并启动引擎，纪元依然保持 targetEpoch + 1 不递增
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
}

void SyncControllerTests::actualDbCloseReopenWithInstalledJournalResumesWithSameToken()
{
    // 保证在事务已落库且产生新待发送后进程中断重启，新控制器遇到 installed 日志幂等完成收尾，不重复递增纪元且不重复清空待发送队列。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString opId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 targetEpoch = 25;
    const QString targetDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString targetFolder = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // 1. 模拟恢复收尾在关闭前的执行：先用 opId 成功提交 beginEpochAfterRestore
    {
        SyncStore store;
        QVERIFY(store.beginEpochAfterRestore(targetEpoch, targetDevice, opId));
        QCOMPARE(store.epoch(), targetEpoch + 1);
        QCOMPARE(store.deviceId(), targetDevice);
        QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'local_restore_operation_id'")).toString(), opId);
    }

    // 2. 在 token 提交后新增一条任务改动入待发送（outbox）
    const QString newSyncId = addTask(QStringLiteral("token提交后新增的任务"));
    QVERIFY(!newSyncId.isEmpty());
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")).toInt(), 1);

    // 3. 模拟收尾未彻底删除日志即发生崩溃：保留 installed sidecar
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), opId);
    obj.insert(QStringLiteral("epoch"), QString::number(targetEpoch));
    obj.insert(QStringLiteral("deviceId"), targetDevice);
    obj.insert(QStringLiteral("folderId"), targetFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    // 偏好中标记已开启同步
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    // 4. 真实关闭并重新打开数据库，清除所有连接缓存和内存单例状态
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(dbPath));

    // 5. 构造全新控制器，模拟重启后启动检查
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    // 启动时识别到 installed 日志保持阻断
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));

    // 6. 点击立即同步：利用同一 operationId 幂等完成收尾并删除日志
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));

    // 7. 断言纪元不重复增加，设备和文件夹身份正确
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QCOMPARE(SyncStore().deviceId(), targetDevice);
    QCOMPARE(SyncStore().folderId(), targetFolder);

    // 8. 核心断言：token 命中幂等分支，未重复清空待发送队列，崩溃前新增的 outbox 改动依然完好保留
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")).toInt(), 1);
}

void SyncControllerTests::corruptFieldsAndDanglingSymlinkBlockSync()
{
    // 保证恢复日志存在悬空符号链接、非合法 UUID、非法设备或文件夹标识、浮点版本或路径不匹配等损坏字段时严格阻断同步，且不误删日志文件。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    // 偏好标记开启同步，以验证阻断会阻止引擎启动
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    const QString validOpId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString validDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString validFolder = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();

    auto runCorruptCheck = [&](const std::function<void()>& setup, const std::function<void()>& teardown) {
        setup();
        const qint64 initialEpoch = SyncStore().epoch();
        SyncController controller(macPlatform(cloudFolder()));
        controller.initialize();
        QVERIFY2(controller.hasProblem(), "损坏日志必须使控制器处于 problem 状态");
        QVERIFY2(!controller.engine() || !controller.engine()->isRunning(), "损坏日志必须阻止同步引擎启动");
        QCOMPARE(controller.summaryText(), QStringLiteral("恢复日志损坏"));

        // 调用 syncNow 后断言 epoch 不变、引擎仍停、文件或 symlink 仍在
        controller.syncNow();
        QCOMPARE(SyncStore().epoch(), initialEpoch);
        QVERIFY(!controller.engine() || !controller.engine()->isRunning());
        const QFileInfo fi(journalPath);
        QVERIFY(fi.exists() || fi.isSymLink());

        // 调用 prepareForRestore(&error) 必须返回 false 且 error 非空，证明不会把坏字段当合法日志覆写
        QString prepErr;
        const bool prepOk = controller.prepareForRestore(&prepErr);
        QVERIFY(!prepOk);
        QVERIFY(!prepErr.isEmpty());
        const QFileInfo fiAfter(journalPath);
        QVERIFY(fiAfter.exists() || fiAfter.isSymLink());

        teardown();
    };

    // 1. 悬空符号链接
    runCorruptCheck([&]() {
        const QString danglingTarget = m_data->filePath(QStringLiteral("non_existent_target.json"));
        QVERIFY(QFile::link(danglingTarget, journalPath));
        QVERIFY(QFileInfo(journalPath).isSymLink());
    }, [&]() {
        QVERIFY(QFileInfo(journalPath).isSymLink());
        QVERIFY(QFile::remove(journalPath));
    });

    // 辅助 lambda：写入 json object 并校验
    auto checkJsonObject = [&](const QJsonObject& obj) {
        runCorruptCheck([&]() {
            QFile file(journalPath);
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
            file.close();
        }, [&]() {
            QVERIFY(QFileInfo::exists(journalPath));
            QVERIFY(QFile::remove(journalPath));
        });
    };

    auto baseValidObject = [&]() {
        QJsonObject obj;
        obj.insert(QStringLiteral("v"), 1);
        obj.insert(QStringLiteral("operationId"), validOpId);
        obj.insert(QStringLiteral("epoch"), QStringLiteral("1"));
        obj.insert(QStringLiteral("deviceId"), validDevice);
        obj.insert(QStringLiteral("folderId"), validFolder);
        obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
        obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
        return obj;
    };

    // 2. 非合法 UUID (非 UUID 字符串，例如 op-installed-restart-test)
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("operationId"), QStringLiteral("op-installed-restart-test"));
        checkJsonObject(obj);
    }

    // 3. 非合法 deviceId (非 32 位十六进制)
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("deviceId"), QStringLiteral("not-a-32-hex-device-id"));
        checkJsonObject(obj);
    }

    // 4. 非合法 folderId (非空但非 32 位十六进制且非有效 UUID)
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("folderId"), QStringLiteral("bad-folder-id"));
        checkJsonObject(obj);
    }

    // 5. 浮点版本号 (v = 1.5)
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("v"), 1.5);
        checkJsonObject(obj);
    }

    // 6. JSON 数字 epoch (非十进制字符串)
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("epoch"), 10);
        checkJsonObject(obj);
    }

    // 7. 包含非法字符的 epoch 字符串
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("epoch"), QStringLiteral("10.5"));
        checkJsonObject(obj);
    }

    // 8. 数据库绝对路径不匹配
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("dbPath"), m_data->filePath(QStringLiteral("other.sqlite")));
        checkJsonObject(obj);
    }

    // 9. 未知 phase
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("phase"), QStringLiteral("unknown_phase"));
        checkJsonObject(obj);
    }

    // 10. 缺少 folderId 字段（缺失不属于合法空值）
    {
        QJsonObject obj = baseValidObject();
        obj.remove(QStringLiteral("folderId"));
        checkJsonObject(obj);
    }

    // 11. folderId 字段为 null（null 不属于合法空值）
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("folderId"), QJsonValue::Null);
        checkJsonObject(obj);
    }

    // 12. folderId 包含尾随换行
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("folderId"), validFolder + QStringLiteral("\n"));
        checkJsonObject(obj);
    }

    // 13. epoch 包含尾随换行
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("epoch"), QStringLiteral("1\n"));
        checkJsonObject(obj);
    }

    // 14. deviceId 包含尾随换行
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("deviceId"), validDevice + QStringLiteral("\n"));
        checkJsonObject(obj);
    }

    // 15. dbPath 为相对路径（拒绝相对路径回退）
    {
        QJsonObject obj = baseValidObject();
        obj.insert(QStringLiteral("dbPath"), QStringLiteral("this.sqlite"));
        checkJsonObject(obj);
    }
}

void SyncControllerTests::prepareForRestoreWriteFailureBlocksSyncAndTogglingCannotBypass()
{
    // 保证恢复意图写入失败时引擎停止且错误可见，切换同步开关或点击立即同步均无法绕过阻断，发起新的合法恢复成功后清除错误并恢复同步。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.engine() && controller.engine()->isRunning());

    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString dbDir = QFileInfo(dbPath).absolutePath();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    QVERIFY(!QFileInfo::exists(journalPath));

    const QFile::Permissions origPerms = QFile::permissions(dbDir);
    auto permGuard = qScopeGuard([&]() {
        QFile::setPermissions(dbDir, origPerms);
    });

    // 故障注入：临时将数据库父目录去掉写权限，使 sidecar 不存在的情况下 writeJournalFile 失败
    QVERIFY(QFile::setPermissions(dbDir, origPerms & ~QFile::WriteOwner & ~QFile::WriteUser & ~QFile::WriteGroup & ~QFile::WriteOther));

    // 使用探针断言确实无法在该目录下新建文件
    const QString probePath = dbDir + QStringLiteral("/probe.tmp");
    QFile probe(probePath);
    QVERIFY(!probe.open(QIODevice::WriteOnly));

    QString err;
    const bool prepOk = controller.prepareForRestore(&err);
    QVERIFY(!prepOk);
    QVERIFY(!err.isEmpty());
    QVERIFY(err.contains(QStringLiteral("无法打开恢复日志文件进行写入")) || err.contains(QStringLiteral("提交恢复日志文件失败")));
    QVERIFY(!QFileInfo::exists(journalPath));

    // 确认引擎停止且错误可见
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(!controller.statusDetail().isEmpty());

    // 验证切换同步开关（关闭再打开）无法绕过停止
    controller.setEnabled(false);
    controller.setEnabled(true);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 验证调用 syncNow 也无法恢复同步或启动引擎
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 解除故障注入：恢复目录权限，探针验证成功
    QVERIFY(QFile::setPermissions(dbDir, origPerms));
    QVERIFY(probe.open(QIODevice::WriteOnly));
    probe.close();
    QFile::remove(probePath);

    // 发起新的合法恢复重试：意图写入成功，并在 finishRestore 成功后清除错误、恢复同步
    QVERIFY(controller.prepareForRestore());
    controller.finishRestore(true);
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::corruptedJournalPathResolvedAllowsFreshRestore()
{
    // 保证日志路径被非普通文件损坏时阻断同步，在损坏路径修复后发起新的合法恢复能成功清除损坏标记并恢复同步。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(controller.engine() && controller.engine()->isRunning());

    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    // 故障注入：恢复日志路径被同名目录占位，导致 readJournalFile 判定 Corrupt 并设置 m_journalCorrupted
    QVERIFY(QDir().mkdir(journalPath));
    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(journalPath).isDir()) {
            QDir(journalPath).removeRecursively();
        }
    });

    QString err;
    const bool prepOk = controller.prepareForRestore(&err);
    QVERIFY(!prepOk);
    QVERIFY(!err.isEmpty());

    // 确认引擎停止且错误可见（损坏标记生效）
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(controller.summaryText(), QStringLiteral("恢复日志损坏"));

    // 验证切换同步开关（关闭再打开）无法绕过停止
    controller.setEnabled(false);
    controller.setEnabled(true);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 验证调用 syncNow 也无法恢复同步或启动引擎
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 解除故障注入：移除目录占位
    QVERIFY(QDir(journalPath).removeRecursively());

    // 发起新的合法恢复：意图写入成功后清除 m_journalCorrupted，并在 finishRestore 成功后恢复同步
    QVERIFY(controller.prepareForRestore());
    controller.finishRestore(true);
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::finishRestoreFalseWhenJournalDeleteFailsPreservesContextAndAllowsRetry()
{
    // 保证恢复取消时若删除 prepared 日志失败，能完整保留 operationId 与恢复上下文，重试时可根据操作标识成功安全清理日志且纪元恒定。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    const qint64 initialEpoch = SyncStore().epoch();
    const QString initialDevice = SyncStore().deviceId();
    const QString initialFolder = SyncStore().folderId();

    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    // 故障注入：将原 prepared 日志暂存，以同名目录占位制造删除失败
    const QString backupJournal = journalPath + QStringLiteral(".bak");
    QVERIFY(QFile::rename(journalPath, backupJournal));
    QVERIFY(QDir().mkdir(journalPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(journalPath).isDir()) {
            QDir(journalPath).removeRecursively();
        }
        if (QFileInfo::exists(backupJournal)) {
            QFile::remove(backupJournal);
        }
    });

    // 调用 finishRestore(false)，由于占位导致删除 prepared 日志失败
    controller.finishRestore(false);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(SyncStore().epoch(), initialEpoch);

    // 解除占位：还原原始 prepared 日志
    QVERIFY(QDir(journalPath).removeRecursively());
    QVERIFY(QFile::rename(backupJournal, journalPath));

    // 点击立即同步：重试清除日志，因为完整保留了 operationId，能够通过删除校验并恢复引擎，且纪元不变
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), initialEpoch);
    QCOMPARE(SyncStore().deviceId(), initialDevice);
    QCOMPARE(SyncStore().folderId(), initialFolder);
}

void SyncControllerTests::finishRestoreTrueWhenDbClosedRetainsContextAndBlocksSync()
{
    // 保证恢复完成时若数据库意外关闭，控制器保留恢复上下文并设置阻断错误，重新打开数据库后通过 syncNow 先写 installed 日志再推进纪元。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    const qint64 prevEpoch = SyncStore().epoch();

    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    auto readJournalJson = [](const QString& path) -> QJsonObject {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            return {};
        }
        return QJsonDocument::fromJson(file.readAll()).object();
    };

    // 断言磁盘当前是 prepared 日志
    QCOMPARE(readJournalJson(journalPath).value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));

    // 故障注入：在 finishRestore(true) 之前关闭数据库
    DatabaseManager::instance()->close();

    controller.finishRestore(true);

    // 断言处于阻断状态且报错明确，磁盘仍保留 prepared 日志
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.statusDetail().contains(QStringLiteral("数据库未处于打开状态")));
    QCOMPARE(readJournalJson(journalPath).value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));

    // 重新打开数据库
    QVERIFY(DatabaseManager::instance()->initialize(dbPath));

    // 验证切开关不能绕过阻断
    controller.setEnabled(false);
    controller.setEnabled(true);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 点击立即同步：先写 installed 日志，再完成纪元建立与日志清理
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), prevEpoch + 1);
}

void SyncControllerTests::finishRestoreTrueDbClosedSyncNowRequiresInstalledJournalWriteBeforeEpoch()
{
    // 保证数据库关闭后完成恢复保留 installed 上下文且 needsJournalWrite=true，重试时若写 installed 日志失败则不推进纪元。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString dbDir = QFileInfo(dbPath).absolutePath();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    const qint64 initialEpoch = SyncStore().epoch();
    QVERIFY(controller.prepareForRestore());

    DatabaseManager::instance()->close();
    controller.finishRestore(true);
    QVERIFY(controller.hasProblem());

    QVERIFY(DatabaseManager::instance()->initialize(dbPath));

    // 注入写日志失败（父目录去掉写权限）
    const QFile::Permissions origPerms = QFile::permissions(dbDir);
    auto permGuard = qScopeGuard([&]() {
        QFile::setPermissions(dbDir, origPerms);
    });
    QVERIFY(QFile::setPermissions(dbDir, origPerms & ~QFile::WriteOwner & ~QFile::WriteUser & ~QFile::WriteGroup & ~QFile::WriteOther));

    // 调用 syncNow，因为 needsJournalWrite=true，必须先写 installed 日志；写日志失败则终止，不推进 epoch
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(SyncStore().epoch(), initialEpoch); // 纪元绝不推进！

    // 恢复权限
    QVERIFY(QFile::setPermissions(dbDir, origPerms));

    // 再次 syncNow：成功写入 installed 并完成纪元推进和日志清理
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), initialEpoch + 1);
}

void SyncControllerTests::secondRestoreFailureWithOldInstalledJournalWriteBackFailureResumesOnRetry()
{
    // 保证第二次恢复取消且写回前次已安装日志失败时保留旧上下文，故障解除后同进程立即同步可幂等重试并维持纪元不变。
    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));

    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString dbDir = QFileInfo(dbPath).absolutePath();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    const qint64 initialEpoch = SyncStore().epoch();
    const QString initialDevice = SyncStore().deviceId();
    const QString initialFolder = SyncStore().folderId();
    const QString opId1 = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // 模拟第一次恢复已由 store 提交该 opId1
    QVERIFY(SyncStore().beginEpochAfterRestore(initialEpoch, initialDevice, opId1));
    const qint64 committedEpoch = SyncStore().epoch();
    QCOMPARE(committedEpoch, initialEpoch + 1);

    auto readJournalJson = [](const QString& path) -> QJsonObject {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            return {};
        }
        return QJsonDocument::fromJson(file.readAll()).object();
    };
    auto writeJournalJson = [](const QString& path, const QJsonObject& obj) -> bool {
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly)) {
            return false;
        }
        file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
        file.close();
        return true;
    };

    // 模拟磁盘遗留 opId1 的 installed 日志
    QJsonObject j1;
    j1.insert(QStringLiteral("v"), 1);
    j1.insert(QStringLiteral("operationId"), opId1);
    j1.insert(QStringLiteral("epoch"), QString::number(initialEpoch));
    j1.insert(QStringLiteral("deviceId"), initialDevice);
    j1.insert(QStringLiteral("folderId"), initialFolder);
    j1.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    j1.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QVERIFY(writeJournalJson(journalPath, j1));

    // 第二次恢复发起：prepareForRestore 会识别出磁盘原有的 j1 并记录为 m_previousJournal，然后写入新 prepared 日志 (opId2)
    QVERIFY(controller.prepareForRestore());
    QJsonObject diskJ2 = readJournalJson(journalPath);
    QCOMPARE(diskJ2.value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));
    const QString opId2 = diskJ2.value(QStringLiteral("operationId")).toString();
    QVERIFY(opId2 != opId1);

    // 故障注入：临时去掉父目录写权限，使得 finishRestore(false) 写回旧 installed 日志失败
    const QFile::Permissions origPerms = QFile::permissions(dbDir);
    auto permGuard = qScopeGuard([&]() {
        QFile::setPermissions(dbDir, origPerms);
    });
    QVERIFY(QFile::setPermissions(dbDir, origPerms & ~QFile::WriteOwner & ~QFile::WriteUser & ~QFile::WriteGroup & ~QFile::WriteOther));

    // 调用 finishRestore(false)，写回 j1 失败
    controller.finishRestore(false);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 解除故障注入
    QVERIFY(QFile::setPermissions(dbDir, origPerms));

    // 同进程 syncNow：写回旧 installed 日志，重试 epoch（命中 opId1 幂等不自增），安全删除日志，恢复引擎
    controller.syncNow();
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), committedEpoch);
    QCOMPARE(SyncStore().deviceId(), initialDevice);
    QCOMPARE(SyncStore().folderId(), initialFolder);
}

void SyncControllerTests::installedJournalWithProductionUuidFolderResumesSuccessfully()
{
    // 保证包含生产格式带连字符 UUID 文件夹标识的 installed 日志在重启时能被正常识别并幂等完成恢复。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString opId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 targetEpoch = 18;
    const QString targetDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    // 生产格式：QUuid::createUuid().toString(QUuid::WithoutBraces) 带连字符（36 字符）
    const QString targetFolder = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QCOMPARE(targetFolder.size(), 36);
    QVERIFY(targetFolder.contains(QLatin1Char('-')));

    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), opId);
    obj.insert(QStringLiteral("epoch"), QString::number(targetEpoch));
    obj.insert(QStringLiteral("deviceId"), targetDevice);
    obj.insert(QStringLiteral("folderId"), targetFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
    }

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    controller.syncNow();

    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!controller.hasProblem());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QCOMPARE(SyncStore().deviceId(), targetDevice);
    QCOMPARE(SyncStore().folderId(), targetFolder);
}

void SyncControllerTests::finishRestoreSafetyClassificationKeepsPreparedJournalOnRollbackFailure()
{
    // 保证 finishRestore(false, false) 必须保留当前 prepared 日志及操作身份，
    // 即使先前有旧 installed 日志也绝不恢复旧日志，阻断同步且禁止 syncNow 自行收尾，跨重启仍阻断；
    // 而 finishRestore(false, true) 在安全回滚时正常清理日志并恢复引擎。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString oldOpId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 oldEpoch = 50;
    const QString oldDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString oldFolder = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // 1. 制造原有的 installed 日志
    QJsonObject oldObj;
    oldObj.insert(QStringLiteral("v"), 1);
    oldObj.insert(QStringLiteral("operationId"), oldOpId);
    oldObj.insert(QStringLiteral("epoch"), QString::number(oldEpoch));
    oldObj.insert(QStringLiteral("deviceId"), oldDevice);
    oldObj.insert(QStringLiteral("folderId"), oldFolder);
    oldObj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    oldObj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    {
        QFile file(journalPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(QJsonDocument(oldObj).toJson(QJsonDocument::Compact));
        file.close();
    }

    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
    }

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    QVERIFY(controller.hasProblem());

    auto readDiskJson = [&](const QString& path) -> QJsonObject {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) {
            return {};
        }
        return QJsonDocument::fromJson(f.readAll()).object();
    };

    // 发起第二次恢复准备：生成当前新的 prepared 日志
    QVERIFY(controller.prepareForRestore());
    QJsonObject newPrepared = readDiskJson(journalPath);
    QCOMPARE(newPrepared.value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));
    const QString newOpId = newPrepared.value(QStringLiteral("operationId")).toString();
    QVERIFY(!newOpId.isEmpty());
    QVERIFY(newOpId != oldOpId);

    // 调用 finishRestore(false, false)：回滚失败
    controller.finishRestore(false, false);
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 磁盘上必须保留当前这次的 prepared 日志，绝不能写回 oldOpId 的 installed 日志
    QJsonObject diskAfter = readDiskJson(journalPath);
    QCOMPARE(diskAfter.value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));
    QCOMPARE(diskAfter.value(QStringLiteral("operationId")).toString(), newOpId);

    // 同进程 syncNow 必须被拒绝：不启动引擎，纪元不自增
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(readDiskJson(journalPath).value(QStringLiteral("phase")).toString(), QStringLiteral("prepared"));

    // 重建控制器模拟重启：读取磁盘 prepared 日志，依然阻断
    {
        SyncController restarted(macPlatform(cloudFolder()));
        restarted.initialize();
        QVERIFY(restarted.hasProblem());
        QVERIFY(!restarted.engine() || !restarted.engine()->isRunning());
    }

    // 2. 验证 finishRestore(false, true) 安全回滚分支：
    // 清理坏日志后重新进入一次干净的 prepare -> finishRestore(false, true)
    QVERIFY(QFile::remove(journalPath));
    SyncController cleanController(macPlatform(cloudFolder()));
    cleanController.initialize();
    cleanController.setEnabled(true);
    QVERIFY(waitIdle(cleanController.engine()));
    QVERIFY(!cleanController.hasProblem());

    QVERIFY(cleanController.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));
    cleanController.finishRestore(false, true);

    // 安全回滚后日志被安全删除，引擎恢复运行，无 problem
    QVERIFY(!QFileInfo::exists(journalPath));
    QVERIFY(!cleanController.hasProblem());
    QVERIFY(cleanController.engine() && cleanController.engine()->isRunning());
}

void SyncControllerTests::restoreFinalizeSyncSettingsReadFailureBlocksSyncAndResumesWhenHealthy()
{
    // 保证恢复收尾时读取已同步设置失败（sync_settings 表重命名/损坏）能阻断同步且保留日志，待环境恢复健康后调用 syncNow 成功收尾。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!controller.hasProblem());

    // 1. prepareForRestore 成功生成 prepared 日志
    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    // 2. 模拟恢复收尾时 sync_settings 表丢失：重命名 sync_settings 表，导致读取已同步设置失败
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_settings RENAME TO sync_settings_bak")));

    auto tableGuard = qScopeGuard([&]() {
        QSqlQuery restoreQuery(DatabaseManager::instance()->database());
        restoreQuery.exec(QStringLiteral("ALTER TABLE sync_settings_bak RENAME TO sync_settings"));
    });

    // 动作前断言故障生效：sync_settings 表不存在
    QCOMPARE(scalar(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table' AND name='sync_settings'")).toString(), QString());

    // 3. 模拟恢复完成收尾：finishRestore(true)
    controller.finishRestore(true);

    // 必须阻断：引擎停止，hasProblem 为 true，错误信息可见，且恢复日志绝对不能被删除
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QVERIFY(!controller.statusDetail().isEmpty());

    // 4. 在故障未修复前调用 syncNow：不得跳过错误，日志不得删除，引擎依然保持停止
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));

    // 5. 恢复健康：还原 sync_settings 表
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_settings_bak RENAME TO sync_settings")));
    tableGuard.dismiss();

    // 6. 调用 syncNow 重试：成功整理设置，安全删除日志，启动引擎
    controller.syncNow();
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::restoreFinalizeWriteBackMarkerClearFailurePreservesMarkersAndJournal()
{
    // 保证恢复收尾中设置写回标记清理失败时，写回标记与日志不丢失且引擎保持停止，修复后重试收尾成功。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!controller.hasProblem());

    // 1. 在 sync_state 中插入待写回标记与对应的 sync_settings
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("INSERT INTO sync_state (key, value) VALUES ('writeback/logic/dayStartHour', 'set')")));
    QVERIFY(query.exec(QStringLiteral("INSERT OR REPLACE INTO sync_settings (key, value, v_time, v_device) VALUES ('logic/dayStartHour', '4', 1, 'dev1')")));
    AppSettings::instance()->setDayStartHour(4);

    // 2. 准备恢复
    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    // 3. 注入故障：创建触发器阻止从 sync_state 删除 writeback/ 记录，使得 finishSettingWriteBack 失败
    QVERIFY(query.exec(QStringLiteral(
        "CREATE TRIGGER block_writeback_delete BEFORE DELETE ON sync_state "
        "WHEN OLD.key = 'writeback/logic/dayStartHour' "
        "BEGIN SELECT RAISE(ABORT, 'blocked writeback deletion'); END;")));

    auto triggerGuard = qScopeGuard([&]() {
        QSqlQuery cleanupQuery(DatabaseManager::instance()->database());
        cleanupQuery.exec(QStringLiteral("DROP TRIGGER IF EXISTS block_writeback_delete"));
    });

    // 动作前断言：触发器确实存在
    QCOMPARE(scalar(QStringLiteral("SELECT name FROM sqlite_master WHERE type='trigger' AND name='block_writeback_delete'")).toString(),
             QStringLiteral("block_writeback_delete"));

    // 4. 模拟恢复完成收尾：finishRestore(true)
    controller.finishRestore(true);

    // 必须阻断：引擎停、日志在、错误可见、writeback 标记未丢
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toString(),
             QStringLiteral("set"));

    // 在故障修复前调用 syncNow：不得跳过，日志与标记依然保留
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toString(),
             QStringLiteral("set"));

    // 5. 修复故障：移除触发器
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER block_writeback_delete")));
    triggerGuard.dismiss();

    // 6. 重试收尾成功：标记被清理，日志被安全删除，引擎恢复启动
    controller.syncNow();
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toInt(), 0);
}

void SyncControllerTests::restoreFinalizeLocalRecordFailureBlocksSyncAndPreservesJournal()
{
    // 保证恢复收尾中本地新设置入库记录失败时，同步阻断并保留恢复日志，移除故障后重试成功收尾。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!controller.hasProblem());

    // 本地产生改动（非默认值），确保在 reconcileSettings 时会调用 store.recordLocalSetting
    AppSettings::instance()->setDayStartHour(6);
    QCOMPARE(AppSettings::instance()->dayStartHour(), 6);

    // 1. 准备恢复
    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    // 删除库中已同步项，使本地改动在恢复整理时被判定为需要入库的新改动
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DELETE FROM sync_settings WHERE key = 'logic/dayStartHour'")));

    // 2. 注入故障：创建触发器阻止向 sync_settings 写入/更新记录，导致 recordLocalSetting 失败
    QVERIFY(query.exec(QStringLiteral(
        "CREATE TRIGGER block_sync_settings_insert BEFORE INSERT ON sync_settings "
        "WHEN NEW.key = 'logic/dayStartHour' "
        "BEGIN SELECT RAISE(ABORT, 'blocked sync_settings insert'); END;")));
    QVERIFY(query.exec(QStringLiteral(
        "CREATE TRIGGER block_sync_settings_update BEFORE UPDATE ON sync_settings "
        "WHEN NEW.key = 'logic/dayStartHour' AND NEW.pending = 1 "
        "BEGIN SELECT RAISE(ABORT, 'blocked sync_settings update'); END;")));

    auto triggerGuard = qScopeGuard([&]() {
        QSqlQuery cleanupQuery(DatabaseManager::instance()->database());
        cleanupQuery.exec(QStringLiteral("DROP TRIGGER IF EXISTS block_sync_settings_insert"));
        cleanupQuery.exec(QStringLiteral("DROP TRIGGER IF EXISTS block_sync_settings_update"));
    });

    // 动作前断言：触发器存在且阻止写入 logic/dayStartHour
    QCOMPARE(scalar(QStringLiteral("SELECT name FROM sqlite_master WHERE type='trigger' AND name='block_sync_settings_insert'")).toString(),
             QStringLiteral("block_sync_settings_insert"));
    {
        QSqlQuery testQuery(DatabaseManager::instance()->database());
        QVERIFY(!testQuery.exec(QStringLiteral("INSERT INTO sync_settings (key, value, v_time, v_device, base_time, base_device, pending) "
                                               "VALUES ('logic/dayStartHour', '6', 1, 'dev', 0, '', 1)")));
    }

    // 3. 模拟恢复完成收尾：finishRestore(true)
    controller.finishRestore(true);

    // 必须阻断：引擎停止、恢复日志保留、错误信息明确
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QVERIFY(controller.statusDetail().contains(QStringLiteral("记录本地设置失败"))
            || controller.statusDetail().contains(QStringLiteral("整理同步设置失败")));

    // 在故障修复前调用 syncNow：不得跳过，日志依然保留
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));

    // 4. 修复故障：移除触发器
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER block_sync_settings_insert")));
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER block_sync_settings_update")));
    triggerGuard.dismiss();

    // 5. 重试收尾成功：本地设置被成功记录进库，恢复日志被安全删除，引擎恢复启动
    controller.syncNow();
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!QFileInfo::exists(journalPath));
}

void SyncControllerTests::restoreFinalizeIsolatedWritebackQueryFailureSkipsCompletedStepsAndResumes()
{
    // 保证恢复收尾完成纪元与文件夹后因删除受阻保留上下文时，后续隔离重试准确触发 writeback 查询失败并保持阻断，恢复表后重试收尾成功且同一操作令牌不重复递增纪元。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");
    const QString backupJournal = dbPath + QStringLiteral(".sync-restore.json.bak");
    const QString opId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const qint64 targetEpoch = 15;
    const QString targetDevice = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(QLatin1Char('-')).toLower();
    const QString targetFolder = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // 1. 写入 installed 状态有效恢复意图日志
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("operationId"), opId);
    obj.insert(QStringLiteral("epoch"), QString::number(targetEpoch));
    obj.insert(QStringLiteral("deviceId"), targetDevice);
    obj.insert(QStringLiteral("folderId"), targetFolder);
    obj.insert(QStringLiteral("phase"), QStringLiteral("installed"));
    obj.insert(QStringLiteral("dbPath"), QFileInfo(dbPath).absoluteFilePath());
    QFile file(journalPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    file.close();

    // 偏好中标记已开启同步
    {
        QSettings settings;
        settings.setValue(QStringLiteral("sync/enabled"), true);
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();

    // 启动时遇到 installed 日志保持阻断
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());

    // 2. 模拟日志删除受阻：暂存恢复日志，原路径以目录占位
    const QString backupJournalFile = journalPath + QStringLiteral(".bak");
    QVERIFY(QFile::rename(journalPath, backupJournalFile));
    QVERIFY(QDir().mkdir(journalPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(journalPath).isDir()) {
            QDir(journalPath).removeRecursively();
        }
        if (QFileInfo::exists(backupJournalFile)) {
            QFile::remove(backupJournalFile);
        }
        QSqlQuery restoreStateQuery(DatabaseManager::instance()->database());
        restoreStateQuery.exec(QStringLiteral("ALTER TABLE sync_state_bak RENAME TO sync_state"));
    });

    // 第一次调用 syncNow：同进程恢复成功完成 epoch(token) 和 folder，但仅因日志删除受阻保留 installed 收尾上下文
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QCOMPARE(SyncStore().deviceId(), targetDevice);
    QCOMPARE(SyncStore().folderId(), targetFolder);

    // 3. 隔离 writeback 查询故障：临时重命名 sync_state 表
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_state RENAME TO sync_state_bak")));

    // 动作前断言：sync_state 表已不存在
    QCOMPARE(scalar(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table' AND name='sync_state'")).toString(), QString());

    // 4. 第二次调用 syncNow：因 epoch/folder 已完成而跳过，在设置整理阶段准确触发 writeback 查询失败并保持阻断
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(controller.statusDetail().contains(QStringLiteral("读取待写回设置标记失败"))
            || controller.statusDetail().contains(QStringLiteral("整理同步设置失败")));
    QVERIFY(QFileInfo(journalPath).isDir()); // 占位目录依然未被破坏

    // 5. 恢复环境：还原 sync_state 表，并移除目录占位、还原真正的恢复日志
    QVERIFY(query.exec(QStringLiteral("ALTER TABLE sync_state_bak RENAME TO sync_state")));
    QVERIFY(QDir(journalPath).removeRecursively());
    QVERIFY(QFile::rename(backupJournalFile, journalPath));
    cleanupGuard.dismiss();

    // 6. 再次调用 syncNow 重试：设置整理成功，安全删除日志并启动引擎
    controller.syncNow();
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!QFileInfo::exists(journalPath));

    // 7. 严格断言：同一 token 幂等，纪元保持 targetEpoch + 1 不变，绝不重复递增！
    QCOMPARE(SyncStore().epoch(), targetEpoch + 1);
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'local_restore_operation_id'")).toString(), opId);
}

void SyncControllerTests::restoreFinalizeQSettingsWriteBackFailureBlocksSyncAndPreservesJournal()
{
    // 保证恢复收尾时底层偏好后端不可写导致设置写回失败时，阻断同步并保留待写回标记与恢复日志，后端恢复后 syncNow 成功收尾。
    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalPath = dbPath + QStringLiteral(".sync-restore.json");

    SyncController controller(macPlatform(cloudFolder()));
    controller.initialize();
    controller.setEnabled(true);
    QVERIFY(waitIdle(controller.engine()));
    QVERIFY(!controller.hasProblem());

    // 1. 构造待写回的有效远端设置：在 sync_state 中插入待写回标记，在 sync_settings 中写入远端设置
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("INSERT INTO sync_state (key, value) VALUES ('writeback/logic/dayStartHour', 'set')")));
    QVERIFY(query.exec(QStringLiteral("INSERT OR REPLACE INTO sync_settings (key, value, v_time, v_device) VALUES ('logic/dayStartHour', '5', 10, 'peer1')")));
    AppSettings::instance()->setDayStartHour(4);

    // 2. 准备恢复
    QVERIFY(controller.prepareForRestore());
    QVERIFY(QFileInfo::exists(journalPath));

    // 3. 故障注入点：获取当前隔离 INI 文件路径，删掉该文件并创建同名目录，致底层 QSettings 陷入 AccessError
    QSettings probeSettings;
    const QString iniPath = probeSettings.fileName();
    QVERIFY(!iniPath.isEmpty());
    QFile::remove(iniPath);
    QVERIFY(QDir().mkdir(iniPath));

    auto cleanupGuard = qScopeGuard([&]() {
        if (QFileInfo(iniPath).isDir()) {
            QDir(iniPath).removeRecursively();
        }
        QFile emptyFile(iniPath);
        if (emptyFile.open(QIODevice::WriteOnly)) {
            emptyFile.close();
        }
    });

    // 动作前断言：底层偏好后端处于不健康状态
    QVERIFY(!AppSettings::instance()->isBackendHealthy());

    // 4. 模拟恢复完成收尾：finishRestore(true)
    controller.finishRestore(true);

    // 必须阻断：引擎停止、恢复日志保留、待写回标记保留
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toString(),
             QStringLiteral("set"));

    // 在故障修复前调用 syncNow：不得跳过，日志与标记依然保留
    controller.syncNow();
    QVERIFY(controller.hasProblem());
    QVERIFY(!controller.engine() || !controller.engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toString(),
             QStringLiteral("set"));

    // 5. 修复故障：移除目录占位，创建空文件恢复偏好后端可写
    QVERIFY(QDir(iniPath).removeRecursively());
    QFile emptyFile(iniPath);
    QVERIFY(emptyFile.open(QIODevice::WriteOnly));
    emptyFile.close();
    cleanupGuard.dismiss();
    QVERIFY(AppSettings::instance()->isBackendHealthy());

    // 6. 重试收尾成功：设置被正确写回本地偏好，标记被清理，恢复日志被安全删除，引擎恢复启动
    controller.syncNow();
    QVERIFY(!controller.hasProblem());
    QVERIFY(controller.engine() && controller.engine()->isRunning());
    QVERIFY(!QFileInfo::exists(journalPath));
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM sync_state WHERE key = 'writeback/logic/dayStartHour'")).toInt(), 0);
    QCOMPARE(AppSettings::instance()->dayStartHour(), 5);
}

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    if (app.arguments().size() == 5
        && app.arguments().at(1) == QStringLiteral("--sync-restart-probe")) {
        return restartProbe(app.arguments());
    }
    SyncControllerTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "SyncControllerTests.moc"
