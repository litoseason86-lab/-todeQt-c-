#include <QDir>
#include <QFile>
#include <QMutex>
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

#include "../src/services/AppSettings.h"
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

// 设备间同步接进应用（050 阶段 4）的测试：SyncController 怎么开关同步、怎么和恢复备份、逻辑日起点、
// 前后台、退出衔接，iPad 怎么选文件夹，同步日志怎么给人看。
//
// 「这台设备」用应用主连接（DatabaseManager），和正式运行时一样，SyncController 与各服务单例都读写它。
// 需要另一台设备时，另开一个真实结构的临时库和它自己的 SyncEngine。两台共用一个临时目录当同步文件夹：
// iCloud 的延迟与乱序由 SyncTransportTests 负责，这里只看接线。
// 引擎的定时器拨到一小时，一轮同步只在测试调用 syncNow 或引擎被要求同步时发生。
namespace {

const QString kTaskDate = QStringLiteral("2026-09-30");

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
    void syncLogReadsAsPlainSentencesNewestFirst();
    void logChangesAreAnnouncedOnlyWhenSomethingWasLogged();
    void longMemoConflictsHaveShortSummariesAndCopyableOriginals();

    // 051 阶段 2：设置
    void contentSettingsAreRecordedButDeviceSettingsAreNot();
    void remoteSettingsAreWrittenBackAndSnapshotGapsRemoved();
    void invalidRemoteSettingsAreNotWrittenBack();
    void startupWritesBackSeveralSettingsWithoutReRecordingThem();

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
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoSyncControllerTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SyncControllerTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
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

QTEST_GUILESS_MAIN(SyncControllerTests)
#include "SyncControllerTests.moc"
