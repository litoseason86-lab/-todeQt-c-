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
    void syncClipboardCopyWiring();

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

    // 重新应用应用身份：打开必须成功，磁盘建立数据库
    McpPaths::applyApplicationIdentity();
    error.clear();
    QVERIFY(app.openDatabase(&error));
    QVERIFY(error.isEmpty());
    QVERIFY(QFile::exists(guardDbPath));
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

QTEST_MAIN(SharedAppTests)
#include "SharedAppTests.moc"
