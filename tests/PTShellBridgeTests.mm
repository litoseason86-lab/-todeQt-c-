#import "../src/platform/ios/bridge/PTShellBridge.h"
#import "../src/platform/ios/bridge/PTLifecycleBridge.h"
#include <QCoreApplication>
#include "../src/platform/ios/native/IPadUiPreferences.h"
#include "../src/platform/ios/native/IPadShellPreferences.h"
#include <QSettings>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QThread>
#include <QSqlQuery>
#include <memory>
#include <QtTest>
#include "../src/services/AppSettings.h"
#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/TaskManager.h"

class PTShellBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void shellPreferencesWriteAndReadBack();
    void shellPreferencesFailureRestoresState_data();
    void shellPreferencesFailureRestoresState();
    void shellAppearanceLegacyReadDoesNotWrite_data();
    void shellAppearanceLegacyReadDoesNotWrite();
    void shellThemeServiceFailureRestoresAppearance_data();
    void shellThemeServiceFailureRestoresAppearance();
    void sameThemeSelectionStillRefreshesAppearance();
    void pageSelectionFailureKeepsPreviousValue_data();
    void pageSelectionFailureKeepsPreviousValue();
    void themeChoicePersistsTogetherAndAcceptsNonempty();
    void themeChoiceFailureRestoresBothKeys();
    void primaryGoalProjectsServiceAndRefreshes();
    void appearanceMigrationAndPersistence();
    void appearanceWriteFailureRestoresValue();
    void initTestCase();
    void init();
    void cleanup();
    void convertsServiceSnapshotAndPersistsLocalSelection();
    void forwardsChangesOnTheMainThread();
    void releaseDisconnectsCallbacks();
    void workerSignalsReturnToMainThread();
    void wallpaperUsesExistingQtResources();
    void capturesWithoutInterruptingFocusAndForwardsFailure();
    void closedDatabaseReturnsAnError();
    void lifecycleFlushIsSynchronous();
    void tickRefreshBenchmark();
    void nativeUIIsDefaultWithDeviceAndOverridePrecedence();
    void bothUIEntrancesWriteTheSameLocalKey();
    void timerSnapshotDoesNotQueryStatistics();
private:
    QTemporaryDir m_preferences;
    QTemporaryDir m_database;
};
void PTShellBridgeTests::initTestCase()
{
    // 测试隔离偏好域与数据库，桥接触发的本机设置不写到正式应用。
    QVERIFY(m_preferences.isValid());
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
    QCoreApplication::setApplicationName(QStringLiteral("PTShellBridgeTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
}
void PTShellBridgeTests::init()
{
    QVERIFY(m_database.isValid());
    QFile::remove(m_database.filePath(QStringLiteral("test.sqlite")));
    QVERIFY(DatabaseManager::instance()->initialize(m_database.filePath(QStringLiteral("test.sqlite"))));
}
void PTShellBridgeTests::cleanup()
{
    FocusTimer::instance()->stopFocus();
    PTLifecycleBridge.flushHandler = nil;
    DatabaseManager::instance()->close();
    QSettings().clear();
    AppSettings::instance()->reload();
}
// 产品保证：摘要和计时按真实服务值转换，外壳选页只保存到本机 ipad 分组。
void PTShellBridgeTests::convertsServiceSnapshotAndPersistsLocalSelection()
{
    @autoreleasepool {
        const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        const int first = TaskManager::instance()->createTask(QStringLiteral("未完成"), today, -1, 0, QString());
        const int second = TaskManager::instance()->createTask(QStringLiteral("已完成"), today, -1, 0, QString());
        QVERIFY(first > 0 && second > 0 && first != second);
        QVERIFY(TaskManager::instance()->setTaskCompleted(second, true));

        // 给第一个任务插入一段当天逻辑日期中午 12:00–12:10、duration=600、mode=0、pomodoro_completed=0 的已结束专注
        QSqlQuery sessionQuery(DatabaseManager::instance()->database());
        sessionQuery.prepare(QStringLiteral(
            "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, pomodoro_completed) "
            "VALUES (:taskId, :startTime, :endTime, :duration, :mode, :pomodoroCompleted)"));
        sessionQuery.bindValue(QStringLiteral(":taskId"), first);
        sessionQuery.bindValue(QStringLiteral(":startTime"), today.toString(Qt::ISODate) + QStringLiteral("T12:00:00"));
        sessionQuery.bindValue(QStringLiteral(":endTime"), today.toString(Qt::ISODate) + QStringLiteral("T12:10:00"));
        sessionQuery.bindValue(QStringLiteral(":duration"), 600);
        sessionQuery.bindValue(QStringLiteral(":mode"), 0);
        sessionQuery.bindValue(QStringLiteral(":pomodoroCompleted"), 0);
        QVERIFY(sessionQuery.exec());

        const int gap = KnowledgeGapService::instance()->addGap(QStringLiteral("到期"), -1, QString(), 1, today, -1);
        QVERIFY(gap > 0);
        PTShellBridge *bridge = [PTShellBridge new];
        PTShellSnapshot *snapshot = [bridge readSnapshot];
        QVERIFY(snapshot.valid);
        QCOMPARE(snapshot.todayPendingCount, NSInteger(1));
        QCOMPARE(snapshot.weekPendingCount, NSInteger(1));
        QCOMPARE(snapshot.todayFocusedSeconds, NSInteger(600));
        QCOMPARE(snapshot.dueGapCount, NSInteger(1));
        QVERIFY([snapshot.sidebarOrder.firstObject isEqualToString:AppSettings::instance()->sidebarOrder().first().toNSString()]);
        [bridge selectPage:@"memo"];
        QVERIFY([bridge readSnapshot].selectedPage && [[bridge readSnapshot].selectedPage isEqualToString:@"memo"]);
        QCOMPARE(QSettings().value(QStringLiteral("ipad/selectedPage")).toString(), QStringLiteral("memo"));
    }
}
// 产品保证：任务、计时与跨层失败信号在主线程刷新外壳，释放前能够正常收到。
void PTShellBridgeTests::forwardsChangesOnTheMainThread()
{
    @autoreleasepool {
        __block int calls = 0;
        __block BOOL mainThread = NO;
        PTShellBridge *bridge = [PTShellBridge new];
        bridge.onChanged = ^{ ++calls; mainThread = NSThread.isMainThread; };
        bridge.onTimerChanged = ^{ ++calls; mainThread = NSThread.isMainThread; };
        emit TaskManager::instance()->tasksChanged();
        emit FocusTimer::instance()->tick();
        QCOMPARE(calls, 2);
        QVERIFY(mainThread);
    }
}
// 产品保证：工作线程发出的服务信号排队回主线程，不从后台直接调用原生界面。
void PTShellBridgeTests::workerSignalsReturnToMainThread()
{
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        __block int calls = 0;
        __block BOOL mainThread = NO;
        bridge.onChanged = ^{ ++calls; mainThread = NSThread.isMainThread; };
        auto *tasks = TaskManager::instance();
        std::unique_ptr<QThread> worker(QThread::create([tasks] { emit tasks->tasksChanged(); }));
        worker->start();
        // 主线程等待后台结束期间不泵事件，先确认回调没有越过线程边界直接执行。
        QVERIFY(worker->wait(2000));
        QCOMPARE(calls, 0);
        QTRY_COMPARE(calls, 1);
        QVERIFY(mainThread);
    }
}
// 产品保证：壁纸使用现有 Qt 图片资源，未知主题与任意文件路径不返回图片。
void PTShellBridgeTests::wallpaperUsesExistingQtResources()
{
    @autoreleasepool {
        NSData *data = [PTShellBridge wallpaperDataForTheme:@"warm"];
        QVERIFY(data.length > 8);
        const QByteArray signature(static_cast<const char *>(data.bytes), 8);
        QCOMPARE(signature.toHex(), QByteArray("89504e470d0a1a0a"));
        QVERIFY([PTShellBridge wallpaperDataForTheme:@"../../main"] == nil);
        QVERIFY([PTShellBridge wallpaperDataForTheme:@"unknown"] == nil);
    }
}
// 产品保证：桥接对象释放后断开 Qt 信号，后续服务刷新不再调用已销毁的界面。
void PTShellBridgeTests::releaseDisconnectsCallbacks()
{
    __block int calls = 0;
    __weak PTShellBridge *released = nil;
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        released = bridge;
        bridge.onChanged = ^{ ++calls; };
        emit TaskManager::instance()->tasksChanged();
        QCOMPARE(calls, 1);
        bridge = nil;
    }
    QVERIFY(released == nil);
    emit TaskManager::instance()->tasksChanged();
    QCOMPARE(calls, 1);
}
// 产品保证：记一笔保留正在进行的计时，失败原因原样转发且不创建空条目。
void PTShellBridgeTests::capturesWithoutInterruptingFocusAndForwardsFailure()
{
    @autoreleasepool {
        const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        const int task = TaskManager::instance()->createTask(QStringLiteral("计时中的任务"), today, -1, 0, QString());
        QVERIFY(task > 0);
        QVERIFY(FocusTimer::instance()->startFocus(task, QStringLiteral("计时中的任务")));
        QVERIFY(FocusTimer::instance()->hasActiveSession());
        PTShellBridge *bridge = [PTShellBridge new];
        PTShellSnapshot *timer = [bridge readSnapshot];
        QVERIFY(timer.hasTimer && timer.running);
        QCOMPARE(timer.currentTaskId, NSInteger(task));
        QVERIFY([timer.taskTitle isEqualToString:@"计时中的任务"]);
        QVERIFY([bridge pause]);
        QVERIFY(![bridge readSnapshot].running);
        QVERIFY([bridge resume]);
        QVERIFY([bridge readSnapshot].running);
        const NSInteger id = [bridge captureTitle:@"中文 <b>标题" categoryId:-1 sourceTaskId:-1];
        QVERIFY(id > 0);
        QCOMPARE(KnowledgeGapService::instance()->getGap(static_cast<int>(id)).value(QStringLiteral("title")).toString(), QStringLiteral("中文 <b>标题"));
        QVERIFY(FocusTimer::instance()->hasActiveSession());
        __block NSString *failure = nil;
        bridge.onFailure = ^(NSString *message) { failure = message; };
        QCOMPARE([bridge captureTitle:@"" categoryId:-1 sourceTaskId:-1], NSInteger(-1));
        QVERIFY(failure.length > 0);
        QCOMPARE([bridge captureTitle:@"越界" categoryId:NSIntegerMax sourceTaskId:-1], NSInteger(-1));
    }
}
// 产品保证：读取失败与空数据分开返回，界面可以保留旧读数并提示重试。
void PTShellBridgeTests::closedDatabaseReturnsAnError()
{
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        QVERIFY([bridge readSnapshot].valid);
        DatabaseManager::instance()->close();
        PTShellSnapshot *snapshot = [bridge readSnapshot];
        QVERIFY(!snapshot.valid);
        QVERIFY(snapshot.error.length > 0);
    }
}
// 产品保证：生命周期保存回调同步执行，调用返回前草稿已保存，未登记时可安全调用。
void PTShellBridgeTests::lifecycleFlushIsSynchronous()
{
    __block int calls = 0;
    PTLifecycleBridge.flushHandler = ^{ ++calls; };
    [PTLifecycleBridge flush];
    QCOMPARE(calls, 1);
    PTLifecycleBridge.flushHandler = nil;
    [PTLifecycleBridge flush];
    QCOMPARE(calls, 1);
}
// 产品保证：外壳 tick 的刷新路径可计量，基准不靠耗时阈值判断正确性。
void PTShellBridgeTests::tickRefreshBenchmark()
{
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        __block int snapshots = 0, timers = 0;
        __weak PTShellBridge *weakBridge = bridge;
        bridge.onChanged = ^{ ++snapshots; (void)[weakBridge readSnapshot]; };
        bridge.onTimerChanged = ^{ ++timers; (void)[weakBridge readTimerSnapshot]; };
        QElapsedTimer clock;
        clock.start();
        int ticks = 0;
        // 无事件循环等待，避免墙钟秒级定时器影响计数；实际服务查询在同一主线程同步执行。
        while (clock.elapsed() < 1000) { @autoreleasepool { emit FocusTimer::instance()->tick(); ++ticks; } }
        const qint64 elapsed = clock.nsecsElapsed();
        QVERIFY(ticks > 0);
        QCOMPARE(snapshots, 0);
        QCOMPARE(timers, ticks);
        qInfo() << "tick-benchmark ticks=" << ticks << "fullSnapshots=" << snapshots
                << "aggregateReads=" << snapshots * 3 << "nsPerTick=" << elapsed / ticks;
        bridge.onChanged = nil; bridge.onTimerChanged = nil;
    }
}
// 产品保证：计时字段只来自计时器，不查询统计；统计表不可读时，计时仍可显示且不产生数据库错误。
void PTShellBridgeTests::timerSnapshotDoesNotQueryStatistics()
{
    @autoreleasepool {
        const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        const int task = TaskManager::instance()->createTask(QStringLiteral("计时任务"), today, -1, 0, QString());
        QVERIFY(task > 0);
        QVERIFY(FocusTimer::instance()->startFocus(task, QStringLiteral("计时任务")));
        PTShellBridge *bridge = [PTShellBridge new];
        QVERIFY([bridge readSnapshot].valid);
        __block int failures = 0;
        bridge.onFailure = ^(NSString *) { ++failures; };
        // 仅在隔离数据库故意破坏统计表，保证误加回的查询真实失败，不能靠替身自称零读取。
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("ALTER TABLE tasks RENAME TO tasks_unavailable")));
        QVERIFY(![bridge readSnapshot].valid);
        QCOMPARE(failures, 0);
        PTShellTimerSnapshot *value = [bridge readTimerSnapshot];
        QVERIFY(value.valid); QVERIFY(value.hasTimer); QVERIFY(value.running);
        QCOMPARE(value.currentTaskId, NSInteger(task));
        QVERIFY([value.taskTitle isEqualToString:@"计时任务"]);
        QCOMPARE(failures, 0);
        // 恢复表供计时器 cleanup 结算；不污染同目标的后续测试。
        QVERIFY(query.exec(QStringLiteral("ALTER TABLE tasks_unavailable RENAME TO tasks")));
    }
}
// 产品保证：无偏好 iPad 默认原生，旧偏好与强制参数保留优先级，任何开关都不能改变 iPhone 伴侣页。
void PTShellBridgeTests::nativeUIIsDefaultWithDeviceAndOverridePrecedence()
{
    QVERIFY(!QSettings().contains(QStringLiteral("ipad/nativeUI")));
    QVERIFY(IPadUiPreferences::shouldUseNative(true, {}, {}));
    QVERIFY(!IPadUiPreferences::shouldUseNative(false, {QStringLiteral("--ipad-native-ui")}, "1"));
    QVERIFY(!IPadUiPreferences::shouldUseNative(true, {QStringLiteral("--ipad-qml-ui"), QStringLiteral("--ipad-native-ui")}, "1"));
    QVERIFY(IPadUiPreferences::shouldUseNative(true, {QStringLiteral("--ipad-native-ui")}, "0"));
    QVERIFY(!IPadUiPreferences::shouldUseNative(true, {}, "0"));
    QSettings().setValue(QStringLiteral("ipad/nativeUI"), false);
    QVERIFY(!IPadUiPreferences::shouldUseNative(true, {}, {}));
    QVERIFY(IPadUiPreferences::shouldUseNative(true, {}, "1"));
}
// 产品保证：原生回退与 QML 恢复都写同一本机键，不修改业务设置，也不即时改变当前页面。
void PTShellBridgeTests::bothUIEntrancesWriteTheSameLocalKey()
{
    @autoreleasepool {
        PTShellBridge *native = [PTShellBridge new];
        [native selectPage:@"settings"];
        NSError *error = nil;
        QVERIFY([native setNativeUI:NO error:&error]); QVERIFY(error == nil);
        QVERIFY(QSettings().contains(QStringLiteral("ipad/nativeUI")));
        QVERIFY(!QSettings().value(QStringLiteral("ipad/nativeUI")).toBool());
        IPadUiPreferences qml(true);
        QVERIFY(qml.setNativeUI(true));
        QVERIFY(QSettings().value(QStringLiteral("ipad/nativeUI")).toBool());
        QCOMPARE(QSettings().allKeys(), QStringList({QStringLiteral("ipad/nativeUI"), QStringLiteral("ipad/selectedPage")}));
        QCOMPARE(QSettings().value(QStringLiteral("ipad/selectedPage")).toString(), QStringLiteral("settings"));
        IPadUiPreferences phone(false);
        QVERIFY(!phone.setNativeUI(false));
        QVERIFY(QSettings().value(QStringLiteral("ipad/nativeUI")).toBool());
    }
}
// 产品保证：主题选择经设置服务保存并发成功信号，非空新主题不被桥接的过期名单拒绝。
void PTShellBridgeTests::themeChoicePersistsTogetherAndAcceptsNonempty()
{
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        NSError *error = nil;
        QVERIFY([bridge setAppearance:@"light" error:&error]);
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };
        QSignalSpy writes(AppSettings::instance(), &AppSettings::settingsWriteSucceeded);
        QVERIFY([bridge selectTheme:@"moon" error:&error]);
        PTShellSnapshot *value = [bridge readSnapshot];
        QVERIFY([value.appearance isEqualToString:@"theme"]);
        QVERIFY([value.backgroundTheme isEqualToString:@"moon"]);
        QCOMPARE(AppSettings::instance()->backgroundTheme(), QStringLiteral("moon"));
        QVERIFY(changes > 0);
        QVERIFY([bridge selectTheme:@"future-theme" error:&error]);
        QCOMPARE(AppSettings::instance()->backgroundTheme(), QStringLiteral("future-theme"));
        QCOMPARE(writes.count(), 2);
        QCOMPARE(writes.at(0).at(0).toString(), QStringLiteral("appearance/backgroundTheme"));
        changes = 0;
        QVERIFY(![bridge selectTheme:@"" error:&error]);
        QVERIFY(error != nil);
        QVERIFY([[bridge readSnapshot].backgroundTheme isEqualToString:@"future-theme"]);
        QCOMPARE(changes, 0);
    }
}
// 产品保证：主题服务写失败时返回错误，还原外观模式并保持旧主题，不发成功刷新。
void PTShellBridgeTests::themeChoiceFailureRestoresBothKeys()
{
    @autoreleasepool {
        auto *appSettings = AppSettings::instance();
        appSettings->setBackgroundTheme(QStringLiteral("warm"));
        QCOMPARE(appSettings->backgroundTheme(), QStringLiteral("warm"));
        QTemporaryDir blocked;
        QVERIFY(blocked.isValid());
        QFile file(blocked.filePath(QStringLiteral("PomodoroTodoTests")));
        QVERIFY(file.open(QIODevice::WriteOnly)); file.close();
        // 只阻断服务当前后端，本机外观键仍可写；裸 QSettings 绕过服务会伪报成功。
        const auto restore = qScopeGuard([this, appSettings] {
            QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
            appSettings->reload();
        });
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, blocked.path());
        appSettings->reload();
        QCOMPARE(appSettings->backgroundTheme(), QStringLiteral("warm"));
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
        PTShellBridge *bridge = [PTShellBridge new];
        NSError *error = nil;
        QVERIFY([bridge setAppearance:@"light" error:&error]);
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };
        QSignalSpy failures(appSettings, &AppSettings::settingsWriteFailed);
        const BOOL ok = [bridge selectTheme:@"starry" error:&error];
        QVERIFY(!ok); QVERIFY(error.localizedDescription.length > 0);
        QCOMPARE(QSettings().value(QStringLiteral("ipad/appearance")).toString(), QStringLiteral("light"));
        QCOMPARE(appSettings->backgroundTheme(), QStringLiteral("warm"));
        QCOMPARE(failures.count(), 1);
        QCOMPARE(failures.at(0).at(0).toString(), QStringLiteral("appearance/backgroundTheme"));
        QCOMPARE(changes, 0);
    }
}
// 产品保证：侧栏主目标使用服务给出的名称和剩余天数，主目标变化后刷新，无目标不冒充零天目标。
void PTShellBridgeTests::primaryGoalProjectsServiceAndRefreshes()
{
    @autoreleasepool {
        auto *service = CountdownService::instance();
        QVERIFY(service->reload());
        PTShellBridge *bridge = [PTShellBridge new];
        QVERIFY(![bridge readSnapshot].hasPrimaryGoal);
        __block int changed = 0;
        bridge.onChanged = ^{ ++changed; };
        QVERIFY(service->addGoal(QStringLiteral("考研初试"), QDate(2030, 12, 21)));
        service->syncReferenceDateTo(QDate(2030, 10, 10));
        const auto goal = service->primaryGoal().toMap();
        QVERIFY(!goal.isEmpty());
        PTShellSnapshot *value = [bridge readSnapshot];
        QVERIFY(value.hasPrimaryGoal);
        QCOMPARE(QString::fromNSString(value.primaryGoalName), goal.value(QStringLiteral("name")).toString());
        QCOMPARE(value.primaryGoalDaysRemaining, NSInteger(goal.value(QStringLiteral("daysRemaining")).toInt()));
        QVERIFY(changed > 0);
        changed = 0;
        QVERIFY(service->deleteGoal(goal.value(QStringLiteral("goalId")).toInt()));
        QVERIFY(changed > 0);
        value = [bridge readSnapshot];
        QVERIFY(!value.hasPrimaryGoal);
        QVERIFY(value.primaryGoalName.length == 0);
    }
}
// 产品保证：老用户的壁纸设置只在读取时推导外观，新外观写入只保存本机键且成功后刷新。
void PTShellBridgeTests::appearanceMigrationAndPersistence()
{
    @autoreleasepool {
        PTShellBridge *bridge = [PTShellBridge new];
        QVERIFY(!QSettings().contains(QStringLiteral("ipad/appearance")));
        QVERIFY([[bridge readSnapshot].appearance isEqualToString:@"system"]);
        QSettings().setValue(QStringLiteral("ipad/useWallpaper"), true);
        QVERIFY([[bridge readSnapshot].appearance isEqualToString:@"theme"]);
        QVERIFY(!QSettings().contains(QStringLiteral("ipad/appearance")));
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };
        for (NSString *mode in @[@"light", @"dark", @"theme", @"system"]) {
            NSError *error = nil;
            QVERIFY([bridge setAppearance:mode error:&error]);
            QVERIFY(error == nil);
            QVERIFY([[bridge readSnapshot].appearance isEqualToString:mode]);
        }
        QCOMPARE(changes, 4);
        QCOMPARE(QSettings().allKeys(), QStringList({QStringLiteral("ipad/appearance"), QStringLiteral("ipad/useWallpaper")}));
        NSError *error = nil;
        QVERIFY(![bridge setAppearance:@"invalid" error:&error]);
        QVERIFY(error != nil);
        QVERIFY([[bridge readSnapshot].appearance isEqualToString:@"system"]);
        QCOMPARE(changes, 4);
    }
}
// 产品保证：本机外观写入失败时恢复旧值、不发成功变化，返回可展示的失败原因。
void PTShellBridgeTests::appearanceWriteFailureRestoresValue()
{
    @autoreleasepool {
        // 用路径上的普通文件阻断偏好子目录，稳定触发 AccessError，不依赖当前用户的权限等级。
        QTemporaryDir blocked;
        QVERIFY(blocked.isValid());
        QFile file(blocked.filePath(QStringLiteral("PomodoroTodoTests")));
        QVERIFY(file.open(QIODevice::WriteOnly)); file.close();
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, blocked.path());
        PTShellBridge *bridge = [PTShellBridge new];
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };
        NSError *error = nil;
        const BOOL ok = [bridge setAppearance:@"dark" error:&error];
        const auto value = [bridge readSnapshot];
        // 在断言前恢复路径，失败也不会污染后续测试。
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
        QVERIFY(!ok); QVERIFY(error.localizedDescription.length > 0);
        QVERIFY([value.appearance isEqualToString:@"system"]);
        QCOMPARE(changes, 0);
    }
}
// 产品保证：选页失败时保留已有页或无键状态，不把未落盘的新选择留在缓存中。
void PTShellBridgeTests::pageSelectionFailureKeepsPreviousValue_data()
{
    QTest::addColumn<bool>("hadPage");
    QTest::newRow("existing-page") << true;
    QTest::newRow("no-page-key") << false;
}

// 产品保证：桥接选页的 void 接口也遵守失败还原，且不会广播成功变化。
void PTShellBridgeTests::pageSelectionFailureKeepsPreviousValue()
{
    @autoreleasepool {
        QFETCH(bool, hadPage);
        QTemporaryDir blocked;
        QVERIFY(blocked.isValid());
        QFile obstruction(blocked.filePath(QStringLiteral("PomodoroTodoTests")));
        QVERIFY(obstruction.open(QIODevice::WriteOnly));
        obstruction.close();
        // 普通文件挡住偏好目录，稳定制造写失败；持有观察后端，确保能看到错误的缓存写入。
        const auto restorePath = qScopeGuard([this] {
            QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
        });
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, blocked.path());
        QSettings observed;
        const QString key = QStringLiteral("ipad/selectedPage");
        if (hadPage) observed.setValue(key, QStringLiteral("memo"));
        QCOMPARE(observed.contains(key), hadPage);
        if (hadPage) QCOMPARE(observed.value(key).toString(), QStringLiteral("memo"));
        PTShellBridge *bridge = [PTShellBridge new];
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };

        [bridge selectPage:@"history"];

        QCOMPARE(observed.contains(key), hadPage);
        QCOMPARE(observed.value(key, QStringLiteral("dashboard")).toString(),
                 hadPage ? QStringLiteral("memo") : QStringLiteral("dashboard"));
        QCOMPARE(changes, 0);
    }
}

// 产品保证：四个 C++ 偏好入口成功后可读回，主题仍经服务保存，未变主题会要求外壳补刷新。
void PTShellBridgeTests::shellPreferencesWriteAndReadBack()
{
    auto snapshot = IPadShellPreferences::readSnapshot();
    QVERIFY(!snapshot.useWallpaper);
    QCOMPARE(snapshot.appearance, QStringLiteral("system"));
    QCOMPARE(snapshot.selectedPage, QStringLiteral("dashboard"));
    QVERIFY(!QSettings().contains(QStringLiteral("ipad/appearance")));
    QString error = QStringLiteral("旧错误");
    QVERIFY(IPadShellPreferences::setUseWallpaper(true, &error));
    QVERIFY(error.isEmpty());
    snapshot = IPadShellPreferences::readSnapshot();
    QVERIFY(snapshot.useWallpaper);
    QCOMPARE(snapshot.appearance, QStringLiteral("theme"));
    QCOMPARE(QSettings().value(QStringLiteral("ipad/useWallpaper")).toBool(), true);
    QVERIFY(!QSettings().contains(QStringLiteral("ipad/appearance")));
    for (const QString& mode : {QStringLiteral("light"), QStringLiteral("dark"),
                                QStringLiteral("theme"), QStringLiteral("system")}) {
        error = QStringLiteral("旧错误");
        QVERIFY(IPadShellPreferences::setAppearance(mode, &error));
        QVERIFY(error.isEmpty());
        QCOMPARE(IPadShellPreferences::readSnapshot().appearance, mode);
        QCOMPARE(QSettings().value(QStringLiteral("ipad/appearance")).toString(), mode);
    }
    auto* settings = AppSettings::instance();
    const QString theme = QStringLiteral("cpp-future-theme");
    QVERIFY(settings->backgroundTheme() != theme);
    QSignalSpy changed(settings, &AppSettings::backgroundThemeChanged);
    bool needsRefresh = true;
    QVERIFY(IPadShellPreferences::selectTheme(theme, &error, &needsRefresh));
    QVERIFY(error.isEmpty());
    QVERIFY(!needsRefresh);
    QCOMPARE(changed.count(), 1);
    QCOMPARE(settings->backgroundTheme(), theme);
    QCOMPARE(QSettings().value(QStringLiteral("appearance/backgroundTheme")).toString(), theme);
    QCOMPARE(IPadShellPreferences::readSnapshot().appearance, QStringLiteral("theme"));
    QVERIFY(IPadShellPreferences::setAppearance(QStringLiteral("system"), &error));
    changed.clear();
    needsRefresh = false;
    QVERIFY(IPadShellPreferences::selectTheme(theme, &error, &needsRefresh));
    QVERIFY(needsRefresh);
    QCOMPARE(changed.count(), 0);
    QCOMPARE(IPadShellPreferences::readSnapshot().appearance, QStringLiteral("theme"));
    QVERIFY(IPadShellPreferences::setSelectedPage(QStringLiteral("memo"), &error));
    QVERIFY(error.isEmpty());
    QCOMPARE(IPadShellPreferences::readSnapshot().selectedPage, QStringLiteral("memo"));
    QCOMPARE(QSettings().value(QStringLiteral("ipad/selectedPage")).toString(), QStringLiteral("memo"));
}

// 产品保证：四个入口的写失败都还原已有值，原先无键时删除新键。
void PTShellBridgeTests::shellPreferencesFailureRestoresState_data()
{
    QTest::addColumn<QString>("operation");
    QTest::addColumn<bool>("existed");
    for (const QString& operation : {QStringLiteral("wallpaper"), QStringLiteral("appearance"),
                                     QStringLiteral("theme"), QStringLiteral("page")}) {
        QTest::newRow(qPrintable(operation + QStringLiteral("-existing"))) << operation << true;
        QTest::newRow(qPrintable(operation + QStringLiteral("-absent"))) << operation << false;
    }
}

// 产品保证：保存失败返回 false 和中文原因，缓存及读取快照继续反映原偏好。
void PTShellBridgeTests::shellPreferencesFailureRestoresState()
{
    QFETCH(QString, operation);
    QFETCH(bool, existed);
    QTemporaryDir blocked;
    QVERIFY(blocked.isValid());
    QFile obstruction(blocked.filePath(QStringLiteral("PomodoroTodoTests")));
    QVERIFY(obstruction.open(QIODevice::WriteOnly));
    obstruction.close();
    auto* appSettings = AppSettings::instance();
    const QString oldTheme = appSettings->backgroundTheme();
    // 仅阻断新的本机偏好后端；主题服务仍持有原后端，保证测到第一步失败时不会执行第二步。
    const auto restorePath = qScopeGuard([this] {
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    });
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, blocked.path());
    const QString key = operation == QStringLiteral("wallpaper") ? QStringLiteral("ipad/useWallpaper")
        : operation == QStringLiteral("page") ? QStringLiteral("ipad/selectedPage") : QStringLiteral("ipad/appearance");
    const QVariant previous = operation == QStringLiteral("wallpaper") ? QVariant(false)
        : operation == QStringLiteral("page") ? QVariant(QStringLiteral("memo")) : QVariant(QStringLiteral("light"));
    QSettings observed;
    if (existed) observed.setValue(key, previous);
    QCOMPARE(observed.contains(key), existed);
    if (existed) {
        QCOMPARE(observed.value(key), previous);
        observed.sync();
        QCOMPARE(observed.status(), QSettings::AccessError);
    }
    QString error;
    bool needsRefresh = true;
    const bool saved = [&] {
        if (operation == QStringLiteral("wallpaper")) return IPadShellPreferences::setUseWallpaper(true, &error);
        if (operation == QStringLiteral("appearance")) return IPadShellPreferences::setAppearance(QStringLiteral("dark"), &error);
        if (operation == QStringLiteral("theme")) return IPadShellPreferences::selectTheme(QStringLiteral("starry"), &error, &needsRefresh);
        return IPadShellPreferences::setSelectedPage(QStringLiteral("history"), &error);
    }();
    QVERIFY(!saved);
    QVERIFY(!error.isEmpty());
    QCOMPARE(observed.contains(key), existed);
    if (existed) QCOMPARE(observed.value(key), previous);
    const auto snapshot = IPadShellPreferences::readSnapshot();
    if (operation == QStringLiteral("wallpaper")) QVERIFY(!snapshot.useWallpaper);
    else if (operation == QStringLiteral("page")) QCOMPARE(snapshot.selectedPage, existed ? QStringLiteral("memo") : QStringLiteral("dashboard"));
    else QCOMPARE(snapshot.appearance, existed ? QStringLiteral("light") : QStringLiteral("system"));
    QCOMPARE(appSettings->backgroundTheme(), oldTheme);
    if (operation == QStringLiteral("theme")) QVERIFY(!needsRefresh);
}

// 产品保证：旧壁纸键无论开启或关闭，都只在读取时推导外观，不自动补写外观键。
void PTShellBridgeTests::shellAppearanceLegacyReadDoesNotWrite_data()
{
    QTest::addColumn<bool>("wallpaper");
    QTest::newRow("wallpaper-off") << false;
    QTest::newRow("wallpaper-on") << true;
}

// 产品保证：C++ 快照兼容旧壁纸体验，重复读取也不改变磁盘键集合。
void PTShellBridgeTests::shellAppearanceLegacyReadDoesNotWrite()
{
    QFETCH(bool, wallpaper);
    QSettings settings;
    QVERIFY(!settings.contains(QStringLiteral("ipad/appearance")));
    settings.setValue(QStringLiteral("ipad/useWallpaper"), wallpaper);
    settings.sync();
    QCOMPARE(settings.status(), QSettings::NoError);
    const QStringList keys = settings.allKeys();
    for (int read = 0; read < 2; ++read) {
        const auto snapshot = IPadShellPreferences::readSnapshot();
        QCOMPARE(snapshot.useWallpaper, wallpaper);
        QCOMPARE(snapshot.appearance, wallpaper ? QStringLiteral("theme") : QStringLiteral("system"));
        QCOMPARE(snapshot.selectedPage, QStringLiteral("dashboard"));
        QVERIFY(!settings.contains(QStringLiteral("ipad/appearance")));
        QCOMPARE(settings.allKeys(), keys);
    }
}

// 产品保证：主题服务第二步失败时也恢复第一步的外观已有值或无键状态。
void PTShellBridgeTests::shellThemeServiceFailureRestoresAppearance_data()
{
    QTest::addColumn<bool>("hadAppearance");
    QTest::newRow("existing-appearance") << true;
    QTest::newRow("no-appearance-key") << false;
}

// 产品保证：主题保存失败保留原主题、回退本机外观，并返回失败且不要求成功刷新。
void PTShellBridgeTests::shellThemeServiceFailureRestoresAppearance()
{
    QFETCH(bool, hadAppearance);
    auto* appSettings = AppSettings::instance();
    QTemporaryDir blocked;
    QVERIFY(blocked.isValid());
    QFile obstruction(blocked.filePath(QStringLiteral("PomodoroTodoTests")));
    QVERIFY(obstruction.open(QIODevice::WriteOnly));
    obstruction.close();
    // 服务后端留在被阻断的位置，再恢复全局路径，使本机外观可写，隔离第二步失败。
    const auto restore = qScopeGuard([this, appSettings] {
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
        appSettings->reload();
    });
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, blocked.path());
    appSettings->reload();
    const QString oldTheme = appSettings->backgroundTheme();
    QVERIFY(oldTheme != QStringLiteral("starry"));
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    QSettings observed;
    const QString key = QStringLiteral("ipad/appearance");
    if (hadAppearance) observed.setValue(key, QStringLiteral("light"));
    observed.sync();
    QCOMPARE(observed.status(), QSettings::NoError);
    QCOMPARE(observed.contains(key), hadAppearance);
    if (hadAppearance) QCOMPARE(observed.value(key).toString(), QStringLiteral("light"));
    QSignalSpy failures(appSettings, &AppSettings::settingsWriteFailed);
    QString error;
    bool needsRefresh = true;
    QVERIFY(!IPadShellPreferences::selectTheme(QStringLiteral("starry"), &error, &needsRefresh));
    QVERIFY(!error.isEmpty());
    QVERIFY(!needsRefresh);
    QCOMPARE(failures.count(), 1);
    QCOMPARE(appSettings->backgroundTheme(), oldTheme);
    QCOMPARE(observed.contains(key), hadAppearance);
    if (hadAppearance) QCOMPARE(observed.value(key).toString(), QStringLiteral("light"));
}

// 产品保证：主题没有变化但外观切到主题时，桥接仍恰好补发一次外壳刷新。
void PTShellBridgeTests::sameThemeSelectionStillRefreshesAppearance()
{
    @autoreleasepool {
        PTShellBridge* bridge = [PTShellBridge new];
        NSError* error = nil;
        QVERIFY([bridge setAppearance:@"system" error:&error]);
        const QString theme = AppSettings::instance()->backgroundTheme();
        QVERIFY(!theme.isEmpty());
        __block int changes = 0;
        bridge.onChanged = ^{ ++changes; };
        QVERIFY([bridge selectTheme:theme.toNSString() error:&error]);
        QVERIFY(error == nil);
        QCOMPARE(changes, 1);
        QVERIFY([[bridge readSnapshot].appearance isEqualToString:@"theme"]);
    }
}

QTEST_GUILESS_MAIN(PTShellBridgeTests)
#include "PTShellBridgeTests.moc"
