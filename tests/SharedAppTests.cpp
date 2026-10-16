#include <QCoreApplication>
#include <QGuiApplication>
#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QScopeGuard>
#include <QSettings>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include <QtGui/qpa/qwindowsysteminterface.h>

#include "app/AppLifecycle.h"
#include "app/AppServices.h"
#include "app/SharedApp.h"
#include "mcp/common/McpPaths.h"
#include "services/AppSettings.h"
#include "services/ApplicationActivity.h"
#include "services/BackupService.h"
#include "services/DatabaseManager.h"
#include "services/FocusHistoryService.h"
#include "services/FocusTimer.h"
#include "services/KnowledgeGapService.h"
#include "services/LocalSyncFolder.h"
#include "services/LogicalDay.h"
#include "services/LogicalDayService.h"
#include "services/NotificationService.h"
#include "services/MonotonicClock.h"
#include "services/SyncFiles.h"
#include "services/SyncStore.h"
#include "services/PendingDeletion.h"
#include "services/RoutineManager.h"
#include "services/SyncController.h"
#include "services/TaskManager.h"
#include "services/TrashService.h"
#include "services/TrayController.h"

namespace {

// 推进计时而不等待真实时间；让检查点的新旧进度确定不同，并避免周期 tick 意外替代生命周期连线。
class LifecycleClock : public MonotonicClock
{
public:
    qint64 ns = 1000000000;
    qint64 nowNsecs() const override { return ns; }
    QString bootSessionId() const override { return QStringLiteral("shared-app-test-boot"); }
    void advanceSeconds(qint64 seconds) { ns += seconds * 1000000000; }
};

QVariant queryValue(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(sql) || !query.next()) {
        return {};
    }
    return query.value(0);
}

bool executeSql(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (query.exec(sql)) {
        return true;
    }
    qWarning() << query.lastError().text();
    return false;
}


SyncController::Platform makeTestPlatform(const QString& folder, int* backgroundTaskCount = nullptr)
{
    SyncController::Platform platform;
    platform.makeFolder = [folder](const QByteArray&, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<LocalSyncFolder>(folder));
    };
    platform.fixedFolderDisplayPath = QStringLiteral("iCloud 云盘/番茄Todo同步");
    if (backgroundTaskCount) {
        platform.backgroundTask = [backgroundTaskCount] {
            (*backgroundTaskCount)++;
            return std::function<void()>([] {});
        };
    }
    platform.engine.mayCreateFolder = true;
    platform.engine.runInBackground = false;
    // 同步只在生命周期明确要求时写出，避免后台周期掩盖缺失的退出或前后台调用。
    platform.engine.tickMs = 3600000;
    platform.engine.publishIntervalMs = 3600000;
    return platform;
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

} // namespace

class SharedAppTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void shutdownStepsNamesAndExecutionOrder_data();
    void shutdownStepsNamesAndExecutionOrder();
    void applicationStateTransitions();
    void openDatabaseGuardsAgainstEmptyOrganizationName();
    void applicationIdentityAndDatabasePathContract();
    void crossServiceSignalsWiring();
    void logicalDayAndDatabaseChangesMaintainDailyData();
    void restoreUsesRestoredDayBoundaryBeforePurgingTrash_data();
    void restoreUsesRestoredDayBoundaryBeforePurgingTrash();
    void unsafeRestoreKeepsMaintenanceBlockedUntilSafeCompletion();
    void interruptedRestoreKeepsTrashAfterRestart_data();
    void interruptedRestoreKeepsTrashAfterRestart();
    void syncClipboardCopyWiring();
    void sharedAppWiresBackupServicePreparationCallbackToSyncController();
    void sharedAppRestoreFailureSafetyClassificationWiringAndLifecycle();

private:
    QTemporaryDir m_preferences;
    LifecycleClock m_clock;
    std::unique_ptr<QTemporaryDir> m_tempDir;
    QString m_testDbPath;
};

void SharedAppTests::initTestCase()
{
    // 保证生产身份的契约测试也只读写临时偏好，不能改动正式同步开关或历史设置。
    QVERIFY(m_preferences.isValid());
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    QSettings::setPath(QSettings::IniFormat, QSettings::SystemScope, m_preferences.path());
    QStandardPaths::setTestModeEnabled(true);
    QCOMPARE(QSettings::defaultFormat(), QSettings::IniFormat);
    McpPaths::applyApplicationIdentity();
    QVERIFY(QSettings().fileName().startsWith(m_preferences.path() + QLatin1Char('/')));
}

void SharedAppTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
}

void SharedAppTests::init()
{
    m_tempDir = std::make_unique<QTemporaryDir>();
    QVERIFY(m_tempDir->isValid());
    m_testDbPath = m_tempDir->filePath(QStringLiteral("shared_app_test.db"));
    // 每条用例从空偏好和空计时状态开始；尤其不能把 iOS 的恢复策略泄漏到下一条 Mac 用例。
    QSettings settings;
    settings.clear();
    settings.sync();
    AppSettings::instance()->reload();
    auto* timer = FocusTimer::instance();
    timer->resetSession();
    timer->resetPomodoroCount();
    timer->setRecoveryPolicy(FocusTimer::RecoveryPolicy::PauseOnRestore);
    timer->setApplicationActivity(nullptr);
    timer->setManualRestAllowed(true);
    m_clock.ns = 1000000000;
    timer->m_clock = &m_clock;
    BackupService::instance()->m_shutdownPrepared = false;
}

void SharedAppTests::cleanup()
{
    // 断言提前退出也要清掉计时器及注入的时钟，不能让后续用例使用已关闭的库。
    auto* timer = FocusTimer::instance();
    timer->resetSession();
    timer->m_clock = SystemMonotonicClock::instance();
    timer->setRecoveryPolicy(FocusTimer::RecoveryPolicy::PauseOnRestore);
    timer->setApplicationActivity(nullptr);
    timer->setManualRestAllowed(true);
    TrashService::instance()->setNowForTesting({});
    BackupService::instance()->setRestorePreparationCallback(nullptr);
    BackupService::instance()->m_shutdownPrepared = false;
    DatabaseManager::instance()->close();
    m_tempDir.reset();
}

void SharedAppTests::shutdownStepsNamesAndExecutionOrder_data()
{
    // 保证 Mac 的前置关闭钩子和 iOS 的运行锚点策略都经过真实退出流程。
    QTest::addColumn<bool>("mobile");
    QTest::newRow("mac") << false;
    QTest::newRow("ios") << true;
}

void SharedAppTests::shutdownStepsNamesAndExecutionOrder()
{
    // 保证退出先保存草稿、提交待删、落盘计时，再写出所有同步改动，最后关库。
    QFETCH(bool, mobile);
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    options.enableOfflineRecovery = mobile;
    options.allowManualRest = !mobile;
    options.monitorApplicationActivity = mobile;
    options.enablePhaseAlarms = mobile;
    SharedApp app(options);
    QVERIFY(app.openDatabase());
    app.restoreSession();
    const QString folder = m_tempDir->filePath(QStringLiteral("shutdown_sync"));
    app.setUpSync(makeTestPlatform(folder));
    app.startDay();
    app.createInteractionServices();
    auto* sync = app.services().syncController();
    sync->setEnabled(true);
    QVERIFY(waitIdle(sync->engine()));
    QVERIFY(sync->engine()->isRunning());
    const QString device = SyncStore().deviceId();
    const QDir changes(QDir(folder).filePath(SyncFiles::changesDirectory(device)));
    QVERIFY(changes.entryList({QStringLiteral("*.json")}, QDir::Files).isEmpty());

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("待删除"), QDate::currentDate()));
    const int deletedId = queryValue(QStringLiteral("SELECT id FROM tasks WHERE title='待删除'")).toInt();
    const QString deletedSyncId = queryValue(QStringLiteral("SELECT sync_id FROM tasks WHERE title='待删除'")).toString();
    QVERIFY(deletedId > 0);
    QVERIFY(!deletedSyncId.isEmpty());
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("正在专注"), QDate::currentDate()));
    const int focusId = queryValue(QStringLiteral("SELECT id FROM tasks WHERE title='正在专注'")).toInt();
    QVERIFY(focusId > 0);
    QVERIFY(FocusTimer::instance()->startFocus(focusId, QStringLiteral("正在专注")));
    // 停掉周期 tick 但保留运行状态；本用例只允许退出步骤写检查点，不能被真实时间凑巧触发替代。
    FocusTimer::instance()->m_timer.stop();
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 0);
    m_clock.advanceSeconds(7);
    auto* pending = app.services().pendingDeletion();
    pending->setDelayMs(3600000);
    QVERIFY(pending->requestTask(deletedId, QStringLiteral("待删除")));
    QVERIFY(pending->active());
    QVERIFY(SyncStore().hasPending());

    // 临时数据库内记录真正发生的检查点写入及其前置状态，不观察产品代码自报的步骤名称。
    QVERIFY(executeSql(QStringLiteral("CREATE TABLE shutdown_checkpoint_audit (deleted_count INTEGER, draft_count INTEGER, elapsed INTEGER)")));
    QVERIFY(executeSql(QStringLiteral(
        "CREATE TRIGGER audit_shutdown_checkpoint AFTER UPDATE ON active_focus_state BEGIN "
        "INSERT INTO shutdown_checkpoint_audit VALUES "
        "((SELECT COUNT(*) FROM tasks WHERE title='待删除'),"
        "(SELECT COUNT(*) FROM tasks WHERE title='退出草稿'), NEW.elapsed_seconds); END")));

    QStringList observed;
    if (!mobile) {
        app.lifecycle().setPreShutdownHook([&] {
            observed.append(QStringLiteral("preShutdown"));
            QVERIFY(DatabaseManager::instance()->isOpen());
            QVERIFY(pending->active());
            QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='退出草稿'")).toInt(), 0);
        });
    }
    app.lifecycle().setFlushDraftsHook([&] {
        observed.append(QStringLiteral("flushDrafts"));
        QVERIFY(DatabaseManager::instance()->isOpen());
        QVERIFY(pending->active());
        QVERIFY(TaskManager::instance()->addTask(QStringLiteral("退出草稿"), QDate::currentDate()));
    });
    connect(pending, &PendingDeletion::retired, &app, [&] {
        observed.append(QStringLiteral("commitPendingDeletion"));
        QVERIFY(DatabaseManager::instance()->isOpen());
        QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='退出草稿'")).toInt(), 1);
    });
    QStringList expected = {QStringLiteral("flushDrafts"), QStringLiteral("commitPendingDeletion"),
        QStringLiteral("focusTimer"), QStringLiteral("backup"), QStringLiteral("sync"), QStringLiteral("databaseClose")};
    if (!mobile) {
        expected.prepend(QStringLiteral("preShutdown"));
    }
    QCOMPARE(app.lifecycle().shutdownStepNames(), expected);

    app.lifecycle().shutdown();

    QVERIFY(!DatabaseManager::instance()->isOpen());
    QVERIFY(!pending->active());
    QVERIFY(!sync->engine()->isRunning());
    QCOMPARE(observed, expected.mid(0, mobile ? 2 : 3));

    const QStringList files = changes.entryList({QStringLiteral("*.json")}, QDir::Files);
    QCOMPARE(files.size(), 1);
    SyncPosition position;
    QVERIFY(SyncFiles::parseChangeFileName(files.first(), &position));
    QFile file(changes.filePath(files.first()));
    QVERIFY(file.open(QIODevice::ReadOnly));
    SyncFiles::ChangeFile change;
    QString error;
    QCOMPARE(SyncFiles::decodeChanges(file.readAll(), device, position, &change, &error), SyncFiles::ParseStatus::Ok);
    bool deletionWritten = false;
    bool draftWritten = false;
    for (const auto& record : change.batch.records) {
        deletionWritten |= record.table == QStringLiteral("tasks") && record.syncId == deletedSyncId && record.deleted;
        draftWritten |= record.table == QStringLiteral("tasks") && !record.deleted
            && record.fields.value(QStringLiteral("title")).value.toString() == QStringLiteral("退出草稿");
    }
    QVERIFY(deletionWritten);
    QVERIFY(draftWritten);

    // 关库事实已断言；重新打开同一临时库核对磁盘结果，避免只检查退出前的内存状态。
    QVERIFY(DatabaseManager::instance()->initialize(m_testDbPath));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='待删除'")).toInt(), 0);
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 7);
    QCOMPARE(queryValue(QStringLiteral("SELECT running FROM active_focus_state")).toBool(), mobile);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM shutdown_checkpoint_audit WHERE deleted_count=0 AND draft_count=1 AND elapsed=7")).toInt(), 1);
    QVERIFY(!SyncStore().hasPending());
}

void SharedAppTests::applicationStateTransitions()
{
    // 保证前后台状态切换时，计时仅在离开 Active 时写一次检查点并在回到 Active 时记下时刻；草稿仅在非 Active 时保存；同步控制器如实接收所有状态并仅在 Suspended/Hidden 转入后台。
    SharedApp::Options iosOptions;
    iosOptions.databasePath = m_testDbPath;
    iosOptions.enableOfflineRecovery = true;
    iosOptions.allowManualRest = false;
    iosOptions.monitorApplicationActivity = true;
    iosOptions.enablePhaseAlarms = true;

    SharedApp app(iosOptions);
    QVERIFY(app.openDatabase());
    app.restoreSession();

    int backgroundTaskCount = 0;
    app.setUpSync(makeTestPlatform(m_tempDir->filePath(QStringLiteral("sync_state")), &backgroundTaskCount));
    app.startDay();
    app.createInteractionServices();

    SyncController* syncController = app.services().syncController();
    QVERIFY(syncController != nullptr);
    syncController->setEnabled(true);
    if (syncController->statusKey() == QStringLiteral("needsConfirmation")) {
        syncController->confirmJoin();
    }
    SyncEngine* engine = syncController->engine();
    QVERIFY(engine != nullptr);
    QVERIFY(waitIdle(engine));

    int draftSaveCount = 0;
    QList<int> progressAtDraftSave;
    app.lifecycle().setFlushDraftsHook([&] {
        draftSaveCount++;
        // 草稿处理必须晚于 GuiApplicationActivity 驱动的检查点，随后同步才能看到最新落盘状态。
        progressAtDraftSave.append(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt());
    });

    // 先重置当前应用状态为 Active
    QWindowSystemInterface::handleApplicationStateChanged(Qt::ApplicationActive, true);
    QWindowSystemInterface::flushWindowSystemEvents();
    QGuiApplication::processEvents();
    app.lifecycle().handleApplicationStateChanged(Qt::ApplicationActive);

    const GuiApplicationActivity* activity = app.applicationActivity();
    QVERIFY(activity != nullptr);
    QVERIFY(activity->isForeground());

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("前后台专注"), QDate::currentDate()));
    const int taskId = queryValue(QStringLiteral("SELECT id FROM tasks WHERE title='前后台专注'")).toInt();
    QVERIFY(taskId > 0);
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("前后台专注")));
    // 屏蔽周期 tick，只由真实 Qt 状态事件触发生命周期检查点；时钟仍按测试明确推进。
    FocusTimer::instance()->m_timer.stop();
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 0);
    QVERIFY(executeSql(QStringLiteral("CREATE TEMP TABLE checkpoint_writes (elapsed INTEGER)")));
    QVERIFY(executeSql(QStringLiteral("CREATE TEMP TRIGGER audit_checkpoint AFTER UPDATE ON active_focus_state "
                                      "BEGIN INSERT INTO checkpoint_writes VALUES (NEW.elapsed_seconds); END")));
    m_clock.advanceSeconds(3);

    // 监听应用离开前台信号
    QSignalSpy leftForegroundSpy(activity, &GuiApplicationActivity::leftForeground);

    // 1. Active -> Inactive
    // 计时：写一次检查点（发出 leftForeground）；草稿：保存一次；同步：Inactive 仍算前台（不触发 backgroundTask）
    QWindowSystemInterface::handleApplicationStateChanged(Qt::ApplicationInactive, true);
    QWindowSystemInterface::flushWindowSystemEvents();
    QGuiApplication::processEvents();
    app.lifecycle().handleApplicationStateChanged(Qt::ApplicationInactive);

    QCOMPARE(leftForegroundSpy.count(), 1);
    QVERIFY(!activity->isForeground());
    QCOMPARE(draftSaveCount, 1);
    QCOMPARE(backgroundTaskCount, 0); // 仍按前台
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 3);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM checkpoint_writes")).toInt(), 1);
    QCOMPARE(progressAtDraftSave, QList<int>{3});
    m_clock.advanceSeconds(2);

    // 2. Inactive -> Suspended
    // 计时：不再写第二次（leftForeground 次数保持 1）；草稿：保存一次；同步：真正转入后台（触发 backgroundTask）
    QWindowSystemInterface::handleApplicationStateChanged(Qt::ApplicationSuspended, true);
    QWindowSystemInterface::flushWindowSystemEvents();
    QGuiApplication::processEvents();
    app.lifecycle().handleApplicationStateChanged(Qt::ApplicationSuspended);

    QCOMPARE(leftForegroundSpy.count(), 1);
    QVERIFY(!activity->isForeground());
    QCOMPARE(draftSaveCount, 2);
    QCOMPARE(backgroundTaskCount, 1); // 转入后台
    QVERIFY(waitIdle(engine));
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 3);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM checkpoint_writes")).toInt(), 1);
    QCOMPARE(progressAtDraftSave, (QList<int>{3, 3}));
    m_clock.advanceSeconds(2);

    // 3. Suspended -> Active
    // 计时：不写检查点，记下回到前台的时刻；草稿：不保存；同步：恢复前台（不触发后台任务）
    const qint64 prevForegroundNsecs = activity->lastForegroundNsecs();
    QWindowSystemInterface::handleApplicationStateChanged(Qt::ApplicationActive, true);
    QWindowSystemInterface::flushWindowSystemEvents();
    QGuiApplication::processEvents();
    app.lifecycle().handleApplicationStateChanged(Qt::ApplicationActive);

    QCOMPARE(leftForegroundSpy.count(), 1);
    QVERIFY(activity->isForeground());
    QVERIFY(activity->lastForegroundNsecs() >= prevForegroundNsecs);
    QCOMPARE(draftSaveCount, 2);
    QCOMPARE(backgroundTaskCount, 1);
    QVERIFY(waitIdle(engine));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM checkpoint_writes")).toInt(), 1);
    m_clock.advanceSeconds(3);

    // 4. Active -> Hidden
    // 计时：写一次检查点；草稿：保存一次；同步：转入后台（触发 backgroundTask）
    QWindowSystemInterface::handleApplicationStateChanged(Qt::ApplicationHidden, true);
    QWindowSystemInterface::flushWindowSystemEvents();
    QGuiApplication::processEvents();
    app.lifecycle().handleApplicationStateChanged(Qt::ApplicationHidden);

    QCOMPARE(leftForegroundSpy.count(), 2);
    QVERIFY(!activity->isForeground());
    QCOMPARE(draftSaveCount, 3);
    QCOMPARE(backgroundTaskCount, 2);
    QVERIFY(waitIdle(engine));
    QCOMPARE(queryValue(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")).toInt(), 10);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM checkpoint_writes")).toInt(), 2);
    QCOMPARE(progressAtDraftSave, (QList<int>{3, 3, 10}));
}

void SharedAppTests::openDatabaseGuardsAgainstEmptyOrganizationName()
{
    // 保证应用组织名为空时拒绝打开数据库且不在磁盘建库；设置应用身份后能成功打开。
    const QString originalOrg = QCoreApplication::organizationName();
    const QString originalApp = QCoreApplication::applicationName();
    auto restoreIdentity = qScopeGuard([&] {
        QCoreApplication::setOrganizationName(originalOrg);
        QCoreApplication::setApplicationName(originalApp);
    });

    const QString guardDbPath = m_tempDir->filePath(QStringLiteral("guarded.db"));
    QVERIFY(!QFile::exists(guardDbPath));

    SharedApp::Options options;
    options.databasePath = guardDbPath;
    SharedApp app(options);

    // 组织名置空：打开必须失败，磁盘不得建库
    QCoreApplication::setOrganizationName(QString());
    QString error;
    QVERIFY(!app.openDatabase(&error));
    QVERIFY(error.contains(QStringLiteral("组织名为空")));
    QVERIFY(!QFile::exists(guardDbPath));
    QVERIFY(app.trayController() == nullptr);

    // 重新应用应用身份：打开必须成功，磁盘建立数据库
    McpPaths::applyApplicationIdentity();
    error.clear();
    QVERIFY(app.openDatabase(&error));
    QVERIFY(error.isEmpty());
    QVERIFY(QFile::exists(guardDbPath));
    QVERIFY(app.trayController() != nullptr);
}

void SharedAppTests::applicationIdentityAndDatabasePathContract()
{
    // 保证设置身份后组织名与应用名固定为 PomodoroTodo，且默认数据库路径严格位于 AppDataLocation 下。
    McpPaths::applyApplicationIdentity();
    QCOMPARE(QCoreApplication::organizationName(), QStringLiteral("PomodoroTodo"));
    QCOMPARE(QCoreApplication::applicationName(), QStringLiteral("PomodoroTodo"));

    const QString expectedDbPath = QDir(
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
    ).filePath(QStringLiteral("pomodoro.db"));

    QCOMPARE(DatabaseManager::defaultDatabasePath(), expectedDbPath);
}

void SharedAppTests::crossServiceSignalsWiring()
{
    // 保证 startDay 装配跨服务刷新连线，历史记录变更和知识缺口转任务变更均能触发任务变更信号。
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    SharedApp app(options);
    QVERIFY(app.openDatabase());
    app.startDay();

    QSignalSpy tasksChangedSpy(TaskManager::instance(), &TaskManager::tasksChanged);

    // 历史编辑改变任务累计时长，装配层广播刷新
    emit FocusHistoryService::instance()->historyChanged();
    QCOMPARE(tasksChangedSpy.count(), 1);

    // 知识缺口转任务触库，装配层广播刷新
    emit KnowledgeGapService::instance()->tasksAffected();
    QCOMPARE(tasksChangedSpy.count(), 2);
}

void SharedAppTests::logicalDayAndDatabaseChangesMaintainDailyData()
{
    // 保证逻辑日失效后补出今天的例行并清理到期废纸篓，换库通知也能清理到期项。
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    SharedApp app(options);
    QVERIFY(app.openDatabase());
    app.startDay();

    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("跨日例行"), 0));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM routines WHERE title='跨日例行'")).toInt(), 1);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='跨日例行'")).toInt(), 0);
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("过期废纸篓"), QDate::currentDate()));
    const int expiredTask = queryValue(QStringLiteral("SELECT id FROM tasks WHERE title='过期废纸篓'")).toInt();
    QVERIFY(expiredTask > 0);
    QVERIFY(TaskManager::instance()->deleteTask(expiredTask));
    // 只在临时库把删除时间回拨，避免修改系统时间；真实时钟下该项必然早于 30 个逻辑日的保留期。
    QVERIFY(executeSql(QStringLiteral("UPDATE trash_items SET deleted_at='2000-01-01T00:00:00.000Z' WHERE title='过期废纸篓'")));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);

    // 经生产日界定时器触发 LogicalDayService，不直接调用生成或清理服务，确保验证的是装配连线。
    auto* boundary = LogicalDayService::instance()->findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(boundary != nullptr);
    QSignalSpy dayChanged(LogicalDayService::instance(), &LogicalDayService::changed);
    QVERIFY(QMetaObject::invokeMethod(boundary, "timeout", Qt::DirectConnection));
    QCOMPARE(dayChanged.count(), 1);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='跨日例行'")).toInt(), 1);
    QCOMPARE(queryValue(QStringLiteral("SELECT date FROM tasks WHERE title='跨日例行'")).toString(),
             LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("换库后清理"), QDate::currentDate()));
    const int restoredTask = queryValue(QStringLiteral("SELECT id FROM tasks WHERE title='换库后清理'")).toInt();
    QVERIFY(restoredTask > 0);
    QVERIFY(TaskManager::instance()->deleteTask(restoredTask));
    QVERIFY(executeSql(QStringLiteral("UPDATE trash_items SET deleted_at='2000-01-01T00:00:00.000Z' WHERE title='换库后清理'")));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
    // initialize 的已有连接路径同样发布 databaseChanged，覆盖备份换库完成后的共享刷新入口。
    QSignalSpy databaseChanged(DatabaseManager::instance(), &DatabaseManager::databaseChanged);
    QVERIFY(DatabaseManager::instance()->initialize(m_testDbPath));
    QCOMPARE(databaseChanged.count(), 1);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 0);
}

// 产品保证：同步与异步恢复都必须先恢复备份日界，再按同一口径判断废纸篓是否已满保留期。
void SharedAppTests::restoreUsesRestoredDayBoundaryBeforePurgingTrash_data()
{
    // 产品保证：同步与异步恢复入口都在设置安装完成后才清理废纸篓。
    QTest::addColumn<bool>("asynchronous");
    QTest::newRow("synchronous") << false;
    QTest::newRow("asynchronous") << true;
}

// 产品保证：恢复时仍剩一个逻辑日的项目不被旧设置提前清掉，已经满期的项目仍会正常清理。
void SharedAppTests::restoreUsesRestoredDayBoundaryBeforePurgingTrash()
{
    QFETCH(bool, asynchronous);
    auto* backup = BackupService::instance();
    const QString previousSettingsPath = backup->m_settingsFilePath;
    const QString previousBackupsDir = backup->m_backupsDir;
    const auto restoreConfiguration = qScopeGuard([=] {
        backup->configure(previousSettingsPath, previousBackupsDir);
    });
    backup->configure(QString(), m_tempDir->filePath(QStringLiteral("isolated-backups")));

    const QDateTime now(QDate(2026, 11, 1), QTime(2, 0));
    const QDateTime protectedDeletion(QDate(2026, 10, 2), QTime(12, 0));
    const QDateTime expiredDeletion(QDate(2026, 10, 1), QTime(12, 0));
    // 两套日界对同一条记录必须确实得出不同结果；只注入服务时钟，不改系统时间。
    QCOMPARE(LogicalDay::dateOf(protectedDeletion, 4).daysTo(LogicalDay::dateOf(now, 4)), 29);
    QCOMPARE(LogicalDay::dateOf(expiredDeletion, 4).daysTo(LogicalDay::dateOf(now, 4)), 30);
    QCOMPARE(LogicalDay::dateOf(protectedDeletion, 0).daysTo(LogicalDay::dateOf(now, 0)), 30);
    TrashService::instance()->setNowForTesting(now);
    AppSettings::instance()->setDayStartHour(4);
    QCOMPARE(AppSettings::instance()->dayStartHour(), 4);

    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    SharedApp app(options);
    QVERIFY(app.openDatabase());
    app.startDay();
    const QList<QPair<QString, QDateTime>> cases = {
        {QStringLiteral("保留期内"), protectedDeletion},
        {QStringLiteral("确实到期"), expiredDeletion}
    };
    for (const auto& item : cases) {
        const int taskId = TaskManager::instance()->createTask(item.first, QDate(2026, 10, 2), -1, 0, QString());
        QVERIFY(taskId > 0);
        QVERIFY(TaskManager::instance()->deleteTask(taskId));
        QSqlQuery stamp(DatabaseManager::instance()->database());
        stamp.prepare(QStringLiteral("UPDATE trash_items SET deleted_at=:deleted WHERE title=:title"));
        stamp.bindValue(QStringLiteral(":deleted"), item.second.toUTC().toString(Qt::ISODateWithMs));
        stamp.bindValue(QStringLiteral(":title"), item.first);
        QVERIFY(stamp.exec());
        QCOMPARE(stamp.numRowsAffected(), 1);
    }
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 2);
    const QString backupPath = m_tempDir->filePath(QStringLiteral("logical-day.tomatobackup"));
    QVERIFY(backup->createBackup(backupPath));
    AppSettings::instance()->setDayStartHour(0);
    QCOMPARE(AppSettings::instance()->dayStartHour(), 0);

    QSignalSpy completed(backup, &BackupService::restoreCompleted);
    QVERIFY(completed.isValid());
    if (asynchronous) {
        backup->requestRestore(backupPath);
        QTRY_COMPARE_WITH_TIMEOUT(completed.count(), 1, 10000);
    } else {
        QVERIFY(backup->restoreBackup(backupPath));
        QCOMPARE(completed.count(), 1);
    }
    QVERIFY2(completed.first().at(0).toBool(), qPrintable(completed.first().at(1).toString()));
    QCOMPARE(AppSettings::instance()->dayStartHour(), 4);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE title='保留期内'")).toInt(), 1);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE title='确实到期'")).toInt(), 0);
}

// 产品保证：恢复中或不安全失败后不自动清理，外部拒绝通知不解除保护，安全完成后恢复正常维护。
void SharedAppTests::unsafeRestoreKeepsMaintenanceBlockedUntilSafeCompletion()
{
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    SharedApp app(options);
    QVERIFY(app.openDatabase());
    app.startDay();
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("恢复保护中的到期项"), QDate(2026, 10, 2), -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QVERIFY(executeSql(QStringLiteral("UPDATE trash_items SET deleted_at='2000-01-01T12:00:00.000Z'")));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);

    auto* backup = BackupService::instance();
    // 这里只验证装配对恢复分类信号的响应；两条完整恢复链由相邻数据驱动用例覆盖。
    emit backup->restoreStarted();
    QVERIFY(DatabaseManager::instance()->initialize(m_testDbPath));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
    emit backup->restoreCompleted(false, QStringLiteral("另一次请求被拒绝"));
    QVERIFY(DatabaseManager::instance()->initialize(m_testDbPath));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);

    emit backup->restoreSyncCompleted(false, false);
    auto* boundary = LogicalDayService::instance()->findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(boundary != nullptr);
    QVERIFY(QMetaObject::invokeMethod(boundary, "timeout", Qt::DirectConnection));
    QVERIFY(DatabaseManager::instance()->initialize(m_testDbPath));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);

    emit backup->restoreSyncCompleted(false, true);
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 0);
}

// 产品保证：未确认完成或日志损坏的恢复在重启后也不能按旧日界提前永久删除项目。
void SharedAppTests::interruptedRestoreKeepsTrashAfterRestart_data()
{
    QTest::addColumn<bool>("corruptJournal");
    QTest::newRow("prepared") << false;
    QTest::newRow("corrupt") << true;
}

// 产品保证：恢复保护跨控制器和数据库重建保留，日界维护也不能绕过未完成恢复。
void SharedAppTests::interruptedRestoreKeepsTrashAfterRestart()
{
    QFETCH(bool, corruptJournal);
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    const QString folder = m_tempDir->filePath(QStringLiteral("interrupted-sync"));
    const QString journalPath = m_testDbPath + QStringLiteral(".sync-restore.json");
    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 11, 1), QTime(2, 0)));
    AppSettings::instance()->setDayStartHour(4);
    {
        SharedApp before(options);
        QVERIFY(before.openDatabase());
        before.setUpSync(makeTestPlatform(folder));
        const int id = TaskManager::instance()->createTask(QStringLiteral("恢复中断保留项"), QDate(2026, 10, 2), -1, 0, QString());
        QVERIFY(id > 0);
        QVERIFY(TaskManager::instance()->deleteTask(id));
        QSqlQuery stamp(DatabaseManager::instance()->database());
        stamp.prepare(QStringLiteral("UPDATE trash_items SET deleted_at=:deleted"));
        stamp.bindValue(QStringLiteral(":deleted"), QDateTime(QDate(2026, 10, 2), QTime(12, 0)).toUTC().toString(Qt::ISODateWithMs));
        QVERIFY(stamp.exec());
        QCOMPARE(stamp.numRowsAffected(), 1);
        QString error;
        QVERIFY2(before.services().syncController()->prepareForRestore(&error), qPrintable(error));
        QVERIFY(QFileInfo::exists(journalPath));
        // 模拟进程在换库后、备份设置尚未安装的持久化截面；不调用完成通知，不伪造成功。
        AppSettings::instance()->setDayStartHour(0);
        QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
    }
    DatabaseManager::instance()->close();
    if (corruptJournal) {
        QFile journal(journalPath);
        QVERIFY(journal.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QCOMPARE(journal.write("{"), qint64(1));
    }
    SharedApp restarted(options);
    QVERIFY(restarted.openDatabase());
    restarted.setUpSync(makeTestPlatform(folder));
    QCOMPARE(AppSettings::instance()->dayStartHour(), 0);
    restarted.startDay();
    QVERIFY(restarted.services().syncController()->hasProblem());
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
    auto* boundary = LogicalDayService::instance()->findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(boundary != nullptr);
    QVERIFY(QMetaObject::invokeMethod(boundary, "timeout", Qt::DirectConnection));
    QCOMPARE(queryValue(QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
}

void SharedAppTests::syncClipboardCopyWiring()
{
    // 保证在 Mac 和 iOS 选项下，通过 SyncController 发起复制请求，系统剪贴板均能同步更新为待复制文本。
    const QString originalClipboard = QGuiApplication::clipboard()->text();
    auto restoreClipboard = qScopeGuard([&] {
        QGuiApplication::clipboard()->setText(originalClipboard);
    });

    // 1. Mac 选项
    {
        SharedApp::Options macOptions;
        macOptions.databasePath = m_testDbPath;
        SharedApp app(macOptions);
        QVERIFY(app.openDatabase());
        app.setUpSync(makeTestPlatform(m_tempDir->filePath(QStringLiteral("sync_clip_mac"))));
        app.connectClipboard();

        QGuiApplication::clipboard()->setText(QStringLiteral("unrelated_clipboard_mac"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QStringLiteral("unrelated_clipboard_mac"));

        app.services().syncController()->copyLostValue(QStringLiteral("mac_lost_conflict_value"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QStringLiteral("mac_lost_conflict_value"));
    }

    // 2. iOS 选项
    {
        SharedApp::Options iosOptions;
        iosOptions.databasePath = m_testDbPath;
        iosOptions.enableOfflineRecovery = true;
        iosOptions.allowManualRest = false;
        iosOptions.monitorApplicationActivity = true;
        iosOptions.enablePhaseAlarms = true;
        SharedApp app(iosOptions);
        QVERIFY(app.openDatabase());
        app.setUpSync(makeTestPlatform(m_tempDir->filePath(QStringLiteral("sync_clip_ios"))));
        app.connectClipboard();

        QGuiApplication::clipboard()->setText(QStringLiteral("unrelated_clipboard_ios"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QStringLiteral("unrelated_clipboard_ios"));

        app.services().syncController()->copyLostValue(QStringLiteral("ios_lost_conflict_value"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QStringLiteral("ios_lost_conflict_value"));
    }
}

void SharedAppTests::sharedAppWiresBackupServicePreparationCallbackToSyncController()
{
    // 保证 SharedApp 正确装配 BackupService 的恢复意图准备回调至 SyncController，在真实恢复链路中拦截 sidecar 冲突，且使用弱引用在控制器销毁后安全返回拒绝。
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    auto app = std::make_unique<SharedApp>(options);
    QVERIFY(app->openDatabase());
    const QString syncFolder = m_tempDir->filePath(QStringLiteral("shared_prep_sync"));
    app->setUpSync(makeTestPlatform(syncFolder));

    SyncController* controller = app->services().syncController();
    QVERIFY(controller != nullptr);

    // 创建基线备份文件
    const QString backupPath = m_tempDir->filePath(QStringLiteral("shared_test.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(backupPath));

    // 1. 制造 sidecar 目录占位，走真实 BackupService::restoreBackup 链路测试
    const QString journalDir = m_testDbPath + QStringLiteral(".sync-restore.json");
    QVERIFY(QDir().mkdir(journalDir));

    {
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        const bool ok = BackupService::instance()->restoreBackup(backupPath);
        QVERIFY(!ok);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.first().at(0).toBool(), false);
        QVERIFY2(!BackupService::instance()->lastError().isEmpty(), "错误信息不应为空");
        QVERIFY(QFileInfo(journalDir).isDir());
    }
    QVERIFY(QDir(journalDir).removeRecursively());

    // 2. 销毁 app 从而释放 SyncController
    app.reset();

    // 验证控制器销毁后，真实 restoreBackup 链路安全返回拒绝且给出控制器已失效报错
    {
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        const bool ok = BackupService::instance()->restoreBackup(backupPath);
        QVERIFY(!ok);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.first().at(0).toBool(), false);
        QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("同步控制器已失效")));
    }
}

void SharedAppTests::sharedAppRestoreFailureSafetyClassificationWiringAndLifecycle()
{
    // 保证在 SharedApp 真实装配下：
    // 1. 回滚失败 (safeToResume=false) 发射 restoreSyncCompleted(false, false) 且早于 restoreCompleted，
    //    SyncController 保持 prepared 日志阻断且跨重启仍阻断，syncNow 无法绕过；
    // 2. 安全回滚 (safeToResume=true) 发射 restoreSyncCompleted(false, true)，清理日志并恢复引擎；
    // 3. 准备前与忙碌拒绝不发射 restoreSyncCompleted，不破坏现有阻断状态。
    SharedApp::Options options;
    options.databasePath = m_testDbPath;
    auto app = std::make_unique<SharedApp>(options);
    QVERIFY(app->openDatabase());
    const QString syncFolder = m_tempDir->filePath(QStringLiteral("shared_safety_sync"));
    app->setUpSync(makeTestPlatform(syncFolder));

    SyncController* controller = app->services().syncController();
    QVERIFY(controller != nullptr);
    controller->initialize();
    controller->setEnabled(true);
    QVERIFY(waitIdle(controller->engine()));

    const QString backupPath = m_tempDir->filePath(QStringLiteral("shared_safety_test.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(backupPath));

    const QString journalPath = m_testDbPath + QStringLiteral(".sync-restore.json");

    // 子场景 1：干净状态下的安全回滚 (safeToResume = true)
    // 利用 validationHook 在校验后破坏暂存副本，使安装校验失败并触发完整安全回滚
    BackupService::instance()->configure(QString(), m_tempDir->filePath(QStringLiteral("backups")));
    BackupService::instance()->m_forceRollbackCopyFailureForTest = false;
    BackupService::instance()->m_afterRestoreValidationHookForTest = [&]() {
        QDir dir(BackupService::instance()->backupsDirectory());
        const QStringList tmps = dir.entryList(QStringList() << QStringLiteral(".restore-staging-*.tmp"), QDir::Files | QDir::Hidden);
        for (const QString& f : tmps) {
            const QString p = dir.filePath(f);
            const QString conn = QStringLiteral("HookDrop_") + QUuid::createUuid().toString(QUuid::WithoutBraces);
            {
                QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
                db.setDatabaseName(p);
                if (db.open()) {
                    QSqlQuery q(db);
                    q.exec(QStringLiteral("PRAGMA user_version = 999"));
                    db.close();
                }
            }
            QSqlDatabase::removeDatabase(conn);
        }
    };

    QList<QString> signalOrder;
    bool syncCompletedSuccess = true;
    bool syncCompletedSafe = false;

    auto connSync = connect(BackupService::instance(), &BackupService::restoreSyncCompleted,
                            this, [&](bool success, bool safeToResume) {
        signalOrder.append(QStringLiteral("restoreSyncCompleted"));
        syncCompletedSuccess = success;
        syncCompletedSafe = safeToResume;
    });
    auto connUi = connect(BackupService::instance(), &BackupService::restoreCompleted,
                          this, [&](bool, const QString&) {
        signalOrder.append(QStringLiteral("restoreCompleted"));
    });

    const bool restoreOk = BackupService::instance()->restoreBackup(backupPath);
    QVERIFY(!restoreOk);

    disconnect(connSync);
    disconnect(connUi);

    // 断言 1：信号发射顺序与参数（restoreSyncCompleted 先于 restoreCompleted）
    QCOMPARE(signalOrder.count(), 2);
    QCOMPARE(signalOrder.at(0), QStringLiteral("restoreSyncCompleted"));
    QCOMPARE(signalOrder.at(1), QStringLiteral("restoreCompleted"));
    QCOMPARE(syncCompletedSuccess, false);
    QCOMPARE(syncCompletedSafe, true);

    // 断言 2：安全回滚后 prepared 日志已被删除，引擎恢复运行，无 problem
    QVERIFY(!QFileInfo::exists(journalPath));
    QVERIFY(!controller->hasProblem());
    QVERIFY(controller->engine() && controller->engine()->isRunning());

    // 子场景 2：回滚失败导致 safeToResume = false
    // 设置文件只读触发安装校验失败，配合 m_forceRollbackCopyFailureForTest 强制回滚拷贝失败
    const QString settingsFile = QDir(m_tempDir->path()).filePath(QStringLiteral("settings.ini"));
    BackupService::instance()->configure(settingsFile, m_tempDir->filePath(QStringLiteral("backups")));
    auto configGuard = qScopeGuard([]() {
        BackupService::instance()->configure(QString(), QString());
    });
    {
        QSettings seed(settingsFile, QSettings::IniFormat);
        seed.setValue(QStringLiteral("backup/seed"), 1);
        seed.sync();
    }
    QVERIFY(QFile::setPermissions(settingsFile, QFileDevice::ReadOwner));
    BackupService::instance()->m_forceRollbackCopyFailureForTest = true;

    signalOrder.clear();
    connSync = connect(BackupService::instance(), &BackupService::restoreSyncCompleted,
                       this, [&](bool success, bool safeToResume) {
        signalOrder.append(QStringLiteral("restoreSyncCompleted"));
        syncCompletedSuccess = success;
        syncCompletedSafe = safeToResume;
    });
    connUi = connect(BackupService::instance(), &BackupService::restoreCompleted,
                     this, [&](bool, const QString&) {
        signalOrder.append(QStringLiteral("restoreCompleted"));
    });

    QSignalSpy uiSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupPath);
    if (uiSpy.isEmpty()) {
        QVERIFY2(uiSpy.wait(10000), qPrintable(QStringLiteral("异步恢复未在 10 秒内结束，lastError=%1, busy=%2, dbOpen=%3, spyCount=%4")
            .arg(BackupService::instance()->lastError())
            .arg(BackupService::instance()->busy())
            .arg(DatabaseManager::instance()->isOpen())
            .arg(uiSpy.count())));
    }

    disconnect(connSync);
    disconnect(connUi);

    // 恢复文件权限
    QVERIFY(QFile::setPermissions(settingsFile, QFileDevice::ReadOwner | QFileDevice::WriteOwner));

    QCOMPARE(signalOrder.count(), 2);
    QCOMPARE(signalOrder.at(0), QStringLiteral("restoreSyncCompleted"));
    QCOMPARE(signalOrder.at(1), QStringLiteral("restoreCompleted"));
    QCOMPARE(syncCompletedSuccess, false);
    QCOMPARE(syncCompletedSafe, false);

    // 断言：SyncController 保持阻断，磁盘保留 prepared 日志
    QVERIFY(controller->hasProblem());
    QVERIFY(!controller->engine() || !controller->engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));

    // 断言：同进程 syncNow 无法解除阻断
    controller->syncNow();
    QVERIFY(controller->hasProblem());
    QVERIFY(!controller->engine() || !controller->engine()->isRunning());
    QVERIFY(QFileInfo::exists(journalPath));

    // 断言：重建控制器重启应用，依然受 prepared 日志阻断
    {
        SyncController restartedController(makeTestPlatform(syncFolder));
        restartedController.initialize();
        QVERIFY(restartedController.hasProblem());
        QVERIFY(!restartedController.engine() || !restartedController.engine()->isRunning());
    }

    // 子场景 3：已有 prepared 阻断下第二次恢复失败但安全回滚，写回旧 prepared 日志继续阻断
    BackupService::instance()->configure(QString(), m_tempDir->filePath(QStringLiteral("backups")));
    BackupService::instance()->m_forceRollbackCopyFailureForTest = false;
    BackupService::instance()->m_afterRestoreValidationHookForTest = [&]() {
        QDir dir(BackupService::instance()->backupsDirectory());
        const QStringList tmps = dir.entryList(QStringList() << QStringLiteral(".restore-staging-*.tmp"), QDir::Files | QDir::Hidden);
        for (const QString& f : tmps) {
            const QString p = dir.filePath(f);
            const QString conn = QStringLiteral("HookDrop2_") + QUuid::createUuid().toString(QUuid::WithoutBraces);
            {
                QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
                db.setDatabaseName(p);
                if (db.open()) {
                    QSqlQuery q(db);
                    q.exec(QStringLiteral("PRAGMA user_version = 999"));
                    db.close();
                }
            }
            QSqlDatabase::removeDatabase(conn);
        }
    };

    signalOrder.clear();
    connSync = connect(BackupService::instance(), &BackupService::restoreSyncCompleted,
                       this, [&](bool success, bool safeToResume) {
        signalOrder.append(QStringLiteral("restoreSyncCompleted"));
        syncCompletedSuccess = success;
        syncCompletedSafe = safeToResume;
    });
    connUi = connect(BackupService::instance(), &BackupService::restoreCompleted,
                     this, [&](bool, const QString&) {
        signalOrder.append(QStringLiteral("restoreCompleted"));
    });

    const bool restoreOk2 = BackupService::instance()->restoreBackup(backupPath);
    QVERIFY(!restoreOk2);

    disconnect(connSync);
    disconnect(connUi);

    QCOMPARE(signalOrder.count(), 2);
    QCOMPARE(signalOrder.at(0), QStringLiteral("restoreSyncCompleted"));
    QCOMPARE(signalOrder.at(1), QStringLiteral("restoreCompleted"));
    QCOMPARE(syncCompletedSuccess, false);
    QCOMPARE(syncCompletedSafe, true);

    // 因为先前已有未确认的 prepared 日志，即使本次回滚成功，仍写回前次 prepared 日志并保持阻断
    QVERIFY(QFileInfo::exists(journalPath));
    QVERIFY(controller->hasProblem());
    QVERIFY(!controller->engine() || !controller->engine()->isRunning());

    // 子场景 4：准备前拒绝不发射 restoreSyncCompleted
    QSignalSpy syncSpy4(BackupService::instance(), &BackupService::restoreSyncCompleted);
    BackupService::instance()->setRestorePreparationCallback([](QString* err) {
        if (err) *err = QStringLiteral("测试准备拒绝");
        return false;
    });
    QVERIFY(!BackupService::instance()->restoreBackup(backupPath));
    QCOMPARE(syncSpy4.count(), 0);
}

QTEST_MAIN(SharedAppTests)
#include "SharedAppTests.moc"
