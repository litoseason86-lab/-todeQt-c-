#include "../src/platform/ios/bridge/PTBridgeSupport.h"
#include "../src/services/PendingDeletion.h"
#include "../src/services/TaskInteractionCoordinator.h"
#import "../src/platform/ios/bridge/PTTaskBridge.h"
#import "../src/platform/ios/bridge/PTPendingDeletionBridge.h"
#import "../src/platform/ios/bridge/PTInteractionBridge.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/TaskManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
#import "../src/platform/ios/bridge/PTCategoryBridge.h"
#import "../src/platform/ios/bridge/PTLogicalDayBridge.h"
#import "../src/platform/ios/bridge/PTSettingsBridge.h"
@interface PTSettingsBridge (TestInjection)
- (instancetype)initWithSettings:(AppSettings *)settings;
@end
#import "../src/platform/ios/bridge/PTStatisticsBridge.h"
#import "../src/platform/ios/bridge/PTFocusHistoryBridge.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QSettings>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <memory>
#include <QtTest>
#include <limits>
#include <optional>
#include "../src/services/LogicalDayService.h"

// 仅测试目标替换墙钟读取；不改系统时间或生产服务，默认仍取真实本地时间。
static std::optional<QDateTime> bridgeTestNow;
QDateTime QDateTime::currentDateTime() {
    return bridgeTestNow.value_or(QDateTime::fromMSecsSinceEpoch(QDateTime::currentMSecsSinceEpoch()));
}

class PTCoreBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void clockOverrideDrivesLogicalDayService();
    void categoryValuesAndErrors();
    void settingsSnapshotWritesAndFailures();
    void configurationSignalsAndLifetime();
    void statisticsReadEntryPointsAndNestedValues();
    void statisticsFailuresAndHistorySignalLifetime();
    void historyBandsMatchCaliberFixtures();
    void dateRelationsAndPeriodNavigation();
    void historyFieldsPartialChangesAndFailures();
    void initTestCase();
    void init();
    void cleanup();
    void taskReadsPreserveFieldsAndPartialChanges();
    void taskFailuresAreCollectedOnce();
    void taskWriteAndReadEntryPoints();
    void pendingDeletionSignalsAndState();
    void interactionTokenOwnsRegistration();
    void coreSignalsReturnToMainThreadAndDisconnect();
    void convertsStringsWithoutTruncation();
    void rejectsInvalidDatesAndPreservesTimestamps();
    void rejectsIntegerOverflow();
    void collectsOnlyCallFailures();
    void registryUsesWeakTypedReferences();
private:
    QTemporaryDir m_preferences;
    QTemporaryDir m_database;
};
// 产品保证：中文、空串和超长字符串逐字保留，桥接不偷偷截断输入。
void PTCoreBridgeTests::convertsStringsWithoutTruncation()
{
    @autoreleasepool {
        using namespace PTBridgeSupport;
        const QString longText = QStringLiteral("中文🙂").repeated(10000);
        QCOMPARE(string(string(longText)), longText);
        QCOMPARE(string(@""), QStringLiteral(""));
        QVERIFY([string(QString()) isEqualToString:@""]);
    }
}
// 产品保证：日期严格按 ISO 日历校验，闰日合法，时刻保留毫秒与时区偏移。
void PTCoreBridgeTests::rejectsInvalidDatesAndPreservesTimestamps()
{
    @autoreleasepool {
        using namespace PTBridgeSupport;
        QCOMPARE(date(@"2024-02-29"), QDate(2024, 2, 29));
        QVERIFY(!date(@"2023-02-29").isValid());
        QVERIFY(!date(@"2024-2-29").isValid());
        QVERIFY(!date(@"").isValid());
        QVERIFY(!date(@"2024-02-29extra").isValid());
        QVERIFY([date(QDate(2024, 2, 29)) isEqualToString:@"2024-02-29"]);
        const QDateTime value = QDateTime::fromString(QStringLiteral("2024-02-29T12:34:56.789+08:00"), Qt::ISODateWithMs);
        QVERIFY(value.isValid());
        QCOMPARE(timestamp(timestamp(value)), value);
        QCOMPARE(timestamp(timestamp(value)).time().msec(), 789);
        QVERIFY(!timestamp(@"garbage").isValid());
    }
}
// 产品保证：宽编号超出 C++ int 范围时拒绝，不截断成另一条记录编号。
void PTCoreBridgeTests::rejectsIntegerOverflow()
{
    using namespace PTBridgeSupport;
    int result = 17;
    QVERIFY(integer(-1, &result)); QCOMPARE(result, -1);
    QVERIFY(integer(std::numeric_limits<int>::max(), &result));
    QCOMPARE(result, std::numeric_limits<int>::max());
    QVERIFY(!integer(NSIntegerMax, &result));
    QVERIFY(!integer(NSIntegerMin, &result));
    QCOMPARE(result, std::numeric_limits<int>::max());
}
// 产品保证：同步失败只返回当前调用，背景失败仍可上报，嵌套错误与外层隔离。
void PTCoreBridgeTests::collectsOnlyCallFailures()
{
    PTBridgeSupport::FailureCollector collector;
    QVERIFY(!collector.collect(QStringLiteral("背景")));
    {
        PTBridgeSupport::FailureCollector::Call outer(collector);
        QVERIFY(collector.collect(QStringLiteral("外层")));
        {
            PTBridgeSupport::FailureCollector::Call inner(collector);
            QVERIFY(collector.collect(QStringLiteral("内层")));
            QCOMPARE(inner.error(), QStringLiteral("内层"));
        }
        QCOMPARE(outer.error(), QStringLiteral("外层"));
    }
    QVERIFY(!collector.collect(QStringLiteral("调用后")));
}
// 产品保证：登记按类型取服务，服务释放后自动失效，名字可复用但不能错转类型。
void PTCoreBridgeTests::registryUsesWeakTypedReferences()
{
    using namespace PTBridgeSupport;
    auto *object = new TaskInteractionCoordinator(nullptr);
    registerService(QStringLiteral("test.interactions"), object);
    QCOMPARE(service<TaskInteractionCoordinator>(QStringLiteral("test.interactions")), object);
    QVERIFY(service<PendingDeletion>(QStringLiteral("test.interactions")) == nullptr);
    delete object;
    QVERIFY(registeredService(QStringLiteral("test.interactions")) == nullptr);
    QVERIFY(registeredService(QStringLiteral("unknown")) == nullptr);
}
// 产品保证：测试不写正式用户偏好，所有服务读写只落到独立临时库。
void PTCoreBridgeTests::initTestCase() {
    QVERIFY(m_preferences.isValid());
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
    QCoreApplication::setApplicationName(QStringLiteral("PTCoreBridgeTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
}
// 产品保证：每个桥接场景从独立空库开始，不继承其它用例的任务和删除状态。
void PTCoreBridgeTests::init() {
    QVERIFY(m_database.isValid());
    QFile::remove(m_database.filePath(QStringLiteral("core.sqlite")));
    QVERIFY(DatabaseManager::instance()->initialize(m_database.filePath(QStringLiteral("core.sqlite"))));
}
// 产品保证：失败用例也会释放登记与数据库，不把后台服务状态带入下一条测试。
void PTCoreBridgeTests::cleanup() {
    PTBridgeSupport::registerService(QStringLiteral("pendingDeletion"), nullptr);
    PTBridgeSupport::registerService(QStringLiteral("taskInteractions"), nullptr);
    DatabaseManager::instance()->close();
    QSettings().clear(); AppSettings::instance()->reload();
}
// 产品保证：任务逐字段投影且编辑只覆盖传入的键，清空备注与科目不等于没改。
void PTCoreBridgeTests::taskReadsPreserveFieldsAndPartialChanges() {
    @autoreleasepool {
        auto *tasks = TaskManager::instance();
        const QDate day(2024, 2, 29);
        const int catA = CategoryManager::instance()->addCategory(QStringLiteral("甲科"), QStringLiteral("#123456"));
        const int catB = CategoryManager::instance()->addCategory(QStringLiteral("乙科"), QStringLiteral("#abcdef"));
        QVERIFY(catA > 0 && catB > 0 && catA != catB);
        int a = tasks->createTask(QStringLiteral("甲"), day, catA, 37, QStringLiteral("甲备注"));
        int b = tasks->createTask(QStringLiteral("乙"), day, catB, 51, QStringLiteral("乙备注"));
        QVERIFY(a > 0 && b > 0 && a != b);
        QVERIFY(tasks->completeTaskWithNote(b, QStringLiteral("乙完成")));
        QSqlQuery seed(DatabaseManager::instance()->database());
        QVERIFY(seed.exec(QStringLiteral("INSERT INTO focus_sessions(task_id,start_time,end_time,duration,mode,pomodoro_completed) VALUES "
            "(%1,'2024-02-29T08:00:00','2024-02-29T08:04:00',240,1,1),"
            "(%2,'2024-02-29T09:00:00','2024-02-29T09:08:00',480,0,0)").arg(a).arg(b)));
        PTTaskBridge *bridge = [PTTaskBridge new];
        PTTaskResult *result = [bridge tasksForDate:@"2024-02-29"];
        QVERIFY(result.valid); QCOMPARE(result.tasks.count, NSUInteger(2));
        for (PTTaskValue *value in result.tasks) {
            const auto map = tasks->getTask(static_cast<int>(value.taskId));
            QCOMPARE(value.taskId, NSInteger(map.value("id").toInt()));
            QCOMPARE(PTBridgeSupport::string(value.title), map.value("title").toString());
            QCOMPARE(PTBridgeSupport::string(value.categoryText), map.value("categoryText").toString());
            QCOMPARE(value.categoryId, NSInteger(map.value("categoryId").toInt()));
            QCOMPARE(PTBridgeSupport::string(value.categoryName), map.value("categoryName").toString());
            QCOMPARE(PTBridgeSupport::string(value.categoryColor), map.value("categoryColor").toString());
            QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toDate().toString(Qt::ISODate));
            QCOMPARE(bool(value.completed), map.value("completed").toBool());
            QCOMPARE(PTBridgeSupport::timestamp(value.createdAt), map.value("createdAt").toDateTime());
            QCOMPARE(value.estimatedMinutes, NSInteger(map.value("estimatedMinutes").toInt()));
            QCOMPARE(PTBridgeSupport::string(value.notes), map.value("notes").toString());
            QCOMPARE(PTBridgeSupport::string(value.completionNote), map.value("completionNote").toString());
            QCOMPARE(value.displayOrder, NSInteger(map.value("displayOrder").toInt()));
            QCOMPARE(value.actualPomodoros, NSInteger(map.value("actualPomodoros").toInt()));
            QCOMPARE(value.focusedSeconds, NSInteger(map.value("focusedSeconds").toInt()));
        }
        PTTaskChanges *change = [PTTaskChanges new]; change.title = @"新甲";
        QVERIFY(change.hasTitle && !change.hasNotes && !change.hasCategoryId);
        NSError *error = nil;
        QVERIFY([bridge updateTask:a changes:change error:&error]); QVERIFY(error == nil);
        auto updated = tasks->getTask(a);
        QCOMPARE(updated.value("notes").toString(), QStringLiteral("甲备注"));
        QCOMPARE(updated.value("estimatedMinutes").toInt(), 37);
        change = [PTTaskChanges new]; change.notes = @""; change.categoryId = -1;
        QVERIFY([bridge updateTask:a changes:change error:&error]);
        updated = tasks->getTask(a); QCOMPARE(updated.value("notes").toString(), QStringLiteral(""));
        QCOMPARE(updated.value("title").toString(), QStringLiteral("新甲"));
        QVERIFY(updated.value("categoryId").isNull());
    }
}
// 产品保证：空列表是有效结果；数据库读取失败只返回给调用方，不重复走背景失败回调。
void PTCoreBridgeTests::taskFailuresAreCollectedOnce() {
    @autoreleasepool {
        PTTaskBridge *bridge = [PTTaskBridge new];
        PTTaskResult *empty = [bridge tasksForDate:@"2024-02-29"];
        QVERIFY(empty.valid); QCOMPARE(empty.tasks.count, NSUInteger(0));
        __block int failures = 0; bridge.onFailure = ^(NSString *) { ++failures; };
        DatabaseManager::instance()->close();
        PTTaskResult *failed = [bridge tasksForDate:@"2024-02-29"];
        QVERIFY(!failed.valid && failed.error.length > 0); QCOMPARE(failures, 0);
        emit TaskManager::instance()->operationFailed(QStringLiteral("背景失败")); QCOMPARE(failures, 1);
        NSError *error = nil; QVERIFY(![bridge moveTask:NSIntegerMax before:-1 error:&error]); QVERIFY(error != nil);
    }
}
// 产品保证：各任务动作使用原服务接口，完成记录保留，排序与改期不误操作同名任务。
void PTCoreBridgeTests::taskWriteAndReadEntryPoints() {
    @autoreleasepool {
        PTTaskBridge *bridge = [PTTaskBridge new]; NSError *error = nil;
        const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        NSString *iso = PTBridgeSupport::date(today);
        NSInteger a = [bridge createTask:@"同名" date:iso categoryId:-1 estimatedMinutes:17 notes:@"第一" error:&error];
        NSInteger b = [bridge createTask:@"同名" date:iso categoryId:-1 estimatedMinutes:29 notes:@"第二" error:&error];
        QVERIFY(a > 0 && b > 0 && a != b); QVERIFY(error == nil);
        QCOMPARE([bridge todayTasks].tasks.count, NSUInteger(2));
        QCOMPARE([bridge weekTasks:PTBridgeSupport::date(today.addDays(1-today.dayOfWeek()))].tasks.count, NSUInteger(2));
        QCOMPARE([bridge search:@"同名" status:-1 limit:100].tasks.count, NSUInteger(2));
        QVERIFY([bridge moveTask:b before:a error:&error]); QCOMPARE([bridge todayTasks].tasks.firstObject.taskId, b);
        QVERIFY([bridge completeTask:a note:@"结论" error:&error]);
        QVERIFY([bridge setCompleted:a completed:NO error:&error]);
        QVERIFY([[bridge task:a].tasks.firstObject.completionNote isEqualToString:@"结论"]);
        QVERIFY([bridge moveTask:a toDate:PTBridgeSupport::date(today.addDays(-1)) error:&error]);
        QCOMPARE([bridge overdueTasks].tasks.count, NSUInteger(1));
        QVERIFY([bridge moveTasksToToday:@[@(a)] error:&error]);
        QVERIFY(([bridge moveTasks:@[@(a), @(b)] toDate:PTBridgeSupport::date(today.addDays(1)) error:&error]));
        QVERIFY([bridge duplicateTask:a date:iso error:&error]);
        QCOMPARE([bridge todayTasks].tasks.count, NSUInteger(1));
        QVERIFY(![bridge isRoutineGeneratedTask:a]);
    }
}
// 产品保证：撤销槽状态与退场、失败信号原样投影，取消不触库，提交成功后只退场一次。
void PTCoreBridgeTests::pendingDeletionSignalsAndState() {
    @autoreleasepool {
        auto *tasks = TaskManager::instance();
        const int id = tasks->createTask(QStringLiteral("待删"), QDate(2024, 2, 29), -1, 0, QString()); QVERIFY(id > 0);
        PendingDeletion pending(tasks, FocusHistoryService::instance());
        PTBridgeSupport::registerService(QStringLiteral("pendingDeletion"), &pending);
        PTPendingDeletionBridge *bridge = [PTPendingDeletionBridge new];
        __block int changes = 0, retired = 0; __block NSString *failedTitle = nil;
        bridge.onChanged = ^{ ++changes; }; bridge.onRetired = ^{ ++retired; };
        bridge.onCommitFailed = ^(NSString *title) { failedTitle = title; };
        NSError *error = nil;
        QVERIFY([bridge requestTask:id title:@"待删" error:&error]);
        QVERIFY(bridge.active); QCOMPARE(bridge.taskId, NSInteger(id)); QCOMPARE(bridge.sessionId, NSInteger(-1));
        QVERIFY([bridge.title isEqualToString:@"待删"]); QVERIFY(changes > 0);
        [bridge cancel]; QVERIFY(!bridge.active); QVERIFY(tasks->readTask(id).ok()); QCOMPARE(retired, 0);
        QVERIFY([bridge requestTask:id title:@"待删" error:&error]); QVERIFY([bridge commit:&error]);
        QCOMPARE(retired, 1); QVERIFY(!bridge.active); QVERIFY(!tasks->readTask(id).ok());
        QVERIFY([bridge requestSession:99999 title:@"记录" isRest:YES error:&error]);
        QVERIFY(bridge.sessionIsRest); QCOMPARE(bridge.sessionId, NSInteger(99999));
        QVERIFY(![bridge commit:&error]); QVERIFY([failedTitle isEqualToString:@"记录"]); QCOMPARE(retired, 2);
    }
}
// 产品保证：编辑读回最新任务，令牌释放或显式结束都会撤销刷新冻结，重复结束安全。
void PTCoreBridgeTests::interactionTokenOwnsRegistration() {
    @autoreleasepool {
        auto *tasks = TaskManager::instance();
        int id = tasks->createTask(QStringLiteral("最新标题"), QDate(2024, 2, 29), -1, 0, QString()); QVERIFY(id > 0);
        TaskInteractionCoordinator coordinator(tasks);
        PTBridgeSupport::registerService(QStringLiteral("taskInteractions"), &coordinator);
        PTInteractionBridge *bridge = [PTInteractionBridge new]; NSError *error = nil;
        // Objective-C 返回值可能在当前 autoreleasepool 留一份临时引用；排空池后验证真正释放的语义。
        @autoreleasepool {
            PTInteractionToken *editing = [bridge beginEdit:id source:@"test.edit" error:&error];
            QVERIFY(editing != nil && error == nil); QVERIFY([editing.task.title isEqualToString:@"最新标题"]);
            QVERIFY(bridge.refreshBlocked); editing = nil;
        }
        QVERIFY(!bridge.refreshBlocked);
        PTInteractionToken *token = [bridge beginDrag:id source:@"test.drag" error:&error]; QVERIFY(token != nil && bridge.refreshBlocked);
        [token end]; [token end]; QVERIFY(!bridge.refreshBlocked);
        QVERIFY([bridge beginEdit:99999 source:@"missing" error:&error] == nil); QVERIFY(error != nil);
        QVERIFY(bridge.lastError.length > 0 && !bridge.refreshBlocked);
    }
}
// 产品保证：每个领域信号回到主线程，桥接释放断连，恢复信号的记录编号不丢失。
void PTCoreBridgeTests::coreSignalsReturnToMainThreadAndDisconnect() {
    @autoreleasepool {
        PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
        TaskInteractionCoordinator coordinator(TaskManager::instance());
        PTBridgeSupport::registerService(QStringLiteral("pendingDeletion"), &pending);
        PTBridgeSupport::registerService(QStringLiteral("taskInteractions"), &coordinator);
        PTTaskBridge *tasks = [PTTaskBridge new];
        PTPendingDeletionBridge *deletion = [PTPendingDeletionBridge new]; PTInteractionBridge *interaction = [PTInteractionBridge new];
        __weak PTTaskBridge *weakTasks = tasks; __weak PTPendingDeletionBridge *weakDeletion = deletion; __weak PTInteractionBridge *weakInteraction = interaction;
        __block int calls = 0; __block BOOL mainThread = YES;
        void (^changed)(void) = ^{ ++calls; mainThread = mainThread && NSThread.isMainThread; };
        tasks.onChanged = changed; deletion.onChanged = changed; interaction.onChanged = changed;
        __block NSInteger deleted = -1, restored = -1; __block NSArray<NSNumber *> *restoredSessions = nil;
        tasks.onDeleted = ^(NSInteger id) { deleted = id; }; tasks.onRestored = ^(NSInteger id, NSArray<NSNumber *> *ids) { restored = id; restoredSessions = ids; };
        emit TaskManager::instance()->taskDeleted(42); QCOMPARE(deleted, NSInteger(42));
        emit TaskManager::instance()->taskRestored(43, {7, 11}); QCOMPARE(restored, NSInteger(43)); QVERIFY(([restoredSessions isEqualToArray:@[@7, @11]]));
        auto *taskService = TaskManager::instance();
        std::unique_ptr<QThread> worker(QThread::create([&] { emit taskService->tasksChanged(); emit pending.changed(); emit coordinator.changed(); }));
        worker->start(); QVERIFY(worker->wait(2000)); QCOMPARE(calls, 0); QTRY_COMPARE(calls, 3); QVERIFY(mainThread);
        tasks = nil; deletion = nil; interaction = nil;
        QVERIFY(weakTasks == nil && weakDeletion == nil && weakInteraction == nil);
        emit taskService->tasksChanged(); emit pending.changed(); emit coordinator.changed(); QCOMPARE(calls, 3);
    }
}
// 产品保证：测试墙钟能够驱动真实逻辑日服务，跨过日界会发变化信号。
void PTCoreBridgeTests::clockOverrideDrivesLogicalDayService() {
    struct Reset { ~Reset() { bridgeTestNow.reset(); } } reset;
    bridgeTestNow = QDateTime(QDate(2024, 2, 29), QTime(3, 59));
    QCOMPARE(QDateTime::currentDateTime(), *bridgeTestNow);
    AppSettings::instance()->setDayStartHour(4);
    auto *service = LogicalDayService::instance();
    QVERIFY(QMetaObject::invokeMethod(service, "onInvalidate", Qt::DirectConnection));
    PTLogicalDayBridge *bridge = [PTLogicalDayBridge new];
    __block int changes = 0; bridge.onChanged = ^{ ++changes; };
    QSignalSpy spy(service, &LogicalDayService::changed);
    QVERIFY([bridge.today isEqualToString:@"2024-02-28"]);
    QCOMPARE(bridge.dayStartHour, NSInteger(4));
    QCOMPARE(LogicalDay::today(4), QDate(2024, 2, 28));
    bridgeTestNow = QDateTime(QDate(2024, 2, 29), QTime(4, 0));
    QVERIFY(QMetaObject::invokeMethod(service, "checkSystemClock", Qt::DirectConnection));
    QCOMPARE(spy.count(), 1); QCOMPARE(changes, 1);
    QVERIFY([bridge.today isEqualToString:@"2024-02-29"]);
    QCOMPARE(LogicalDay::today(4), QDate(2024, 2, 29));
}
// 产品保证：科目保留字段并走原服务增删改，空结果与数据库失败可区分。
void PTCoreBridgeTests::categoryValuesAndErrors() {
    @autoreleasepool {
        PTCategoryBridge *bridge = [PTCategoryBridge new]; NSError *error = nil;
        NSInteger a = [bridge addCategory:@"甲科" color:@"#112233" error:&error];
        NSInteger b = [bridge addCategory:@"乙科" color:@"#aabbcc" error:&error];
        QVERIFY(a > 0 && b > 0 && a != b); QVERIFY(error == nil);
        auto rows = [bridge allCategories]; QVERIFY(rows.valid && rows.categories.count >= 2);
        for (PTCategoryValue *value in rows.categories) {
            auto map = CategoryManager::instance()->getCategoryById(static_cast<int>(value.categoryId));
            QCOMPARE(PTBridgeSupport::string(value.name), map.value("name").toString());
            QCOMPARE(PTBridgeSupport::string(value.color), map.value("color").toString());
            QCOMPARE(bool(value.isPreset), map.value("isPreset").toBool());
            QCOMPARE(value.displayOrder, NSInteger(map.value("displayOrder").toInt()));
            QCOMPARE(PTBridgeSupport::timestamp(value.createdAt), map.value("createdAt").toDateTime());
        }
        QVERIFY([[bridge category:a].categories.firstObject.name isEqualToString:@"甲科"]);
        QVERIFY([bridge nameExists:@"甲科" excluding:-1]); QVERIFY(![bridge nameExists:@"甲科" excluding:a]);
        QVERIFY([bridge canDeleteCategory:a]);
        QVERIFY([bridge updateCategory:a name:@"新甲" color:@"#334455" error:&error]);
        QVERIFY([[bridge category:a].categories.firstObject.color isEqualToString:@"#334455"]);
        QVERIFY([bridge deleteCategory:b error:&error]); QVERIFY(![bridge category:b].valid);
        // 空库确实没有科目，保证“空”断言不是建立在有预设科目的假设上。
        QSqlQuery clear(DatabaseManager::instance()->database()); QVERIFY(clear.exec("DELETE FROM categories"));
        QVERIFY([bridge allCategories].valid); QCOMPARE([bridge allCategories].categories.count, NSUInteger(0));
        __block int failures = 0; bridge.onFailure = ^(NSString *) { ++failures; };
        DatabaseManager::instance()->close(); QVERIFY(![bridge allCategories].valid); QCOMPARE(failures, 0);
        QVERIFY(![bridge updateCategory:a name:@"甲" color:@"#112233" error:&error]);
        QVERIFY(error.localizedDescription.length > 0); QCOMPARE(failures, 0);
    }
}
// 产品保证：设置快照完整投影，可写项落到原后端；写盘失败只成为调用错误，不伪报成功。
void PTCoreBridgeTests::settingsSnapshotWritesAndFailures() {
    @autoreleasepool {
        QTemporaryDir dir; QVERIFY(dir.isValid()); AppSettings settings(dir.filePath("settings.ini"));
        PTSettingsBridge *bridge = [[PTSettingsBridge alloc] initWithSettings:&settings]; NSError *error = nil;
        __block int successes = 0, failures = 0; bridge.onWriteSucceeded = ^(NSString *) { ++successes; };
        bridge.onWriteFailed = ^(NSString *, NSString *) { ++failures; };


        QVERIFY([bridge setLastMode:1 error:&error]);
        QVERIFY([bridge setWorkMinutes:43 error:&error]);
        QVERIFY([bridge setBreakMinutes:9 error:&error]);
        QVERIFY([bridge setFreeTimerWarningHours:6 error:&error]);
        QVERIFY([bridge setSoundEnabled:!settings.soundEnabled() error:&error]);
        QVERIFY([bridge setReduceMotion:!settings.reduceMotion() error:&error]);
        QVERIFY([bridge setSlimClockFont:!settings.slimClockFont() error:&error]);
        QVERIFY([bridge setRolloverIgnoredDate:@"2024-02-29" error:&error]);
        QVERIFY([bridge setBackgroundTheme:@"starry" error:&error]);
        QVERIFY([bridge setDayStartHour:3 error:&error]);
        QVERIFY([bridge setNickname:@"桥接测试" error:&error]);
        QVERIFY([bridge setSidebarVisible:!settings.sidebarVisible() error:&error]);
        QVERIFY(([bridge setSidebarOrder:@[@"focus", @"today"] error:&error]));
        QVERIFY([bridge setDashboardTimerVisible:!settings.dashboardTimerVisible() error:&error]);
        QVERIFY([bridge setReduceTransparency:!settings.reduceTransparency() error:&error]);
        QVERIFY([bridge setNaturalCompletionNoticeShown:!settings.naturalCompletionNoticeShown() error:&error]);
        QVERIFY([bridge setAutoStartBreak:!settings.autoStartBreak() error:&error]);
        QVERIFY([bridge setAutoStartNextPomodoro:!settings.autoStartNextPomodoro() error:&error]);
        QVERIFY([bridge setQuickStartEnabled:!settings.quickStartEnabled() error:&error]);
        QVERIFY([bridge setLongBreakEnabled:!settings.longBreakEnabled() error:&error]);
        QVERIFY([bridge setLongBreakMinutes:21 error:&error]);
        QVERIFY([bridge setLongBreakInterval:3 error:&error]);
        QVERIFY([bridge setScheduleDisplayMode:@"period" error:&error]);
        PTSettingsSnapshot *snapshot = [bridge snapshot];
        QCOMPARE(snapshot.lastMode, NSInteger(settings.lastMode()));
        QCOMPARE(snapshot.workMinutes, NSInteger(settings.workMinutes()));
        QCOMPARE(snapshot.breakMinutes, NSInteger(settings.breakMinutes()));
        QCOMPARE(snapshot.freeTimerWarningHours, NSInteger(settings.freeTimerWarningHours()));
        QCOMPARE(snapshot.soundEnabled, BOOL(settings.soundEnabled()));
        QCOMPARE(snapshot.reduceMotion, BOOL(settings.reduceMotion()));
        QCOMPARE(snapshot.slimClockFont, BOOL(settings.slimClockFont()));
        QCOMPARE(PTBridgeSupport::string(snapshot.rolloverIgnoredDate), settings.rolloverIgnoredDate());
        QCOMPARE(PTBridgeSupport::string(snapshot.backgroundTheme), settings.backgroundTheme());
        QCOMPARE(snapshot.dayStartHour, NSInteger(settings.dayStartHour()));
        QCOMPARE(PTBridgeSupport::string(snapshot.nickname), settings.nickname());
        QCOMPARE(snapshot.sidebarVisible, BOOL(settings.sidebarVisible()));
        QCOMPARE(snapshot.sidebarOrder.count, NSUInteger(settings.sidebarOrder().size()));
        for (NSUInteger i = 0; i < snapshot.sidebarOrder.count; ++i) QCOMPARE(PTBridgeSupport::string(snapshot.sidebarOrder[i]), settings.sidebarOrder().at(static_cast<qsizetype>(i)));
        QCOMPARE(snapshot.sidebarOrderIsDefault, BOOL(settings.sidebarOrderIsDefault()));
        QCOMPARE(snapshot.dashboardTimerVisible, BOOL(settings.dashboardTimerVisible()));
        QCOMPARE(snapshot.reduceTransparency, BOOL(settings.reduceTransparency()));
        QCOMPARE(snapshot.naturalCompletionNoticeShown, BOOL(settings.naturalCompletionNoticeShown()));
        QCOMPARE(snapshot.autoStartBreak, BOOL(settings.autoStartBreak()));
        QCOMPARE(snapshot.autoStartNextPomodoro, BOOL(settings.autoStartNextPomodoro()));
        QCOMPARE(snapshot.quickStartEnabled, BOOL(settings.quickStartEnabled()));
        QCOMPARE(snapshot.longBreakEnabled, BOOL(settings.longBreakEnabled()));
        QCOMPARE(snapshot.longBreakMinutes, NSInteger(settings.longBreakMinutes()));
        QCOMPARE(snapshot.longBreakInterval, NSInteger(settings.longBreakInterval()));
        QCOMPARE(PTBridgeSupport::string(snapshot.semesterStartDate), settings.semesterStartDate());
        QCOMPARE(snapshot.semesterWeeks, NSInteger(settings.semesterWeeks()));
        QCOMPARE(PTBridgeSupport::string(snapshot.scheduleDisplayMode), settings.scheduleDisplayMode());
        QCOMPARE(snapshot.scheduleShowWeekend, BOOL(settings.scheduleShowWeekend()));
        QVERIFY(successes > 0); QCOMPARE(failures, 0);
        QVERIFY([bridge setDailyFocusGoal:@"2024-02-29" minutes:180 error:&error]);
        QCOMPARE([bridge dailyFocusGoal:@"2024-02-29"], NSInteger(180));
        QVERIFY([bridge resetSidebarOrder:&error]); QVERIFY([bridge snapshot].sidebarOrderIsDefault);
        QVERIFY(![bridge setWorkMinutes:NSIntegerMax error:&error]);
        // 与现有 AppSettings 测试同样注入不可写后端：路径被目录占用，不依赖账户权限。
        const QString blockedPath = dir.filePath("blocked.ini"); QVERIFY(QDir().mkdir(blockedPath));
        AppSettings blocked(blockedPath); PTSettingsBridge *bad = [[PTSettingsBridge alloc] initWithSettings:&blocked];
        __block int background = 0; bad.onWriteFailed = ^(NSString *, NSString *) { ++background; };
        const int oldMinutes = blocked.workMinutes();
        QVERIFY(![bad setWorkMinutes:oldMinutes + 1 error:&error]);
        QVERIFY(error.localizedDescription.length > 0); QCOMPARE(blocked.workMinutes(), oldMinutes); QCOMPARE(background, 0);
        emit blocked.settingsWriteFailed(QStringLiteral("test"), QStringLiteral("背景失败")); QCOMPARE(background, 1);
    }
}
// 产品保证：科目、逻辑日与设置逐域信号转发，工作线程回主线程，释放后全部断连。
void PTCoreBridgeTests::configurationSignalsAndLifetime() {
    @autoreleasepool {
        PTCategoryBridge *categories = [PTCategoryBridge new]; PTLogicalDayBridge *days = [PTLogicalDayBridge new];
        PTSettingsBridge *settings = [PTSettingsBridge new];
        __weak PTCategoryBridge *weakCategories = categories; __weak PTLogicalDayBridge *weakDays = days; __weak PTSettingsBridge *weakSettings = settings;
        __block int count = 0; __block BOOL onMain = YES;
        void (^changed)(void) = ^{ ++count; onMain = onMain && NSThread.isMainThread; };
        categories.onChanged = changed; days.onChanged = changed; settings.onNicknameChanged = changed;
        auto *categoryService = CategoryManager::instance(); auto *dayService = LogicalDayService::instance(); auto *settingService = AppSettings::instance();
        std::unique_ptr<QThread> worker(QThread::create([=] { emit categoryService->categoriesChanged(); emit dayService->changed(); emit settingService->nicknameChanged(); }));
        worker->start(); QVERIFY(worker->wait(2000)); QCOMPARE(count, 0); QTRY_COMPARE(count, 3); QVERIFY(onMain);
        __block int propertyCount = 0;
        settings.onLastModeChanged = ^{ ++propertyCount; };
        settings.onWorkMinutesChanged = ^{ ++propertyCount; };
        settings.onBreakMinutesChanged = ^{ ++propertyCount; };
        settings.onFreeTimerWarningHoursChanged = ^{ ++propertyCount; };
        settings.onSoundEnabledChanged = ^{ ++propertyCount; };
        settings.onReduceMotionChanged = ^{ ++propertyCount; };
        settings.onSlimClockFontChanged = ^{ ++propertyCount; };
        settings.onRolloverIgnoredDateChanged = ^{ ++propertyCount; };
        settings.onBackgroundThemeChanged = ^{ ++propertyCount; };
        settings.onDayStartHourChanged = ^{ ++propertyCount; };
        settings.onNicknameChanged = ^{ ++propertyCount; };
        settings.onSidebarVisibleChanged = ^{ ++propertyCount; };
        settings.onSidebarOrderChanged = ^{ ++propertyCount; };
        settings.onSidebarOrderIsDefaultChanged = ^{ ++propertyCount; };
        settings.onDashboardTimerVisibleChanged = ^{ ++propertyCount; };
        settings.onReduceTransparencyChanged = ^{ ++propertyCount; };
        settings.onNaturalCompletionNoticeShownChanged = ^{ ++propertyCount; };
        settings.onAutoStartBreakChanged = ^{ ++propertyCount; };
        settings.onAutoStartNextPomodoroChanged = ^{ ++propertyCount; };
        settings.onQuickStartEnabledChanged = ^{ ++propertyCount; };
        settings.onLongBreakEnabledChanged = ^{ ++propertyCount; };
        settings.onLongBreakMinutesChanged = ^{ ++propertyCount; };
        settings.onLongBreakIntervalChanged = ^{ ++propertyCount; };
        settings.onSemesterStartDateChanged = ^{ ++propertyCount; };
        settings.onSemesterWeeksChanged = ^{ ++propertyCount; };
        settings.onScheduleDisplayModeChanged = ^{ ++propertyCount; };
        settings.onScheduleShowWeekendChanged = ^{ ++propertyCount; };
        settings.onDailyFocusGoalChanged = ^{ ++propertyCount; };
        emit settingService->lastModeChanged();
        emit settingService->workMinutesChanged();
        emit settingService->breakMinutesChanged();
        emit settingService->freeTimerWarningHoursChanged();
        emit settingService->soundEnabledChanged();
        emit settingService->reduceMotionChanged();
        emit settingService->slimClockFontChanged();
        emit settingService->rolloverIgnoredDateChanged();
        emit settingService->backgroundThemeChanged();
        emit settingService->dayStartHourChanged();
        emit settingService->nicknameChanged();
        emit settingService->sidebarVisibleChanged();
        emit settingService->sidebarOrderChanged();
        emit settingService->dashboardTimerVisibleChanged();
        emit settingService->reduceTransparencyChanged();
        emit settingService->naturalCompletionNoticeShownChanged();
        emit settingService->autoStartBreakChanged();
        emit settingService->autoStartNextPomodoroChanged();
        emit settingService->quickStartEnabledChanged();
        emit settingService->longBreakEnabledChanged();
        emit settingService->longBreakMinutesChanged();
        emit settingService->longBreakIntervalChanged();
        emit settingService->semesterStartDateChanged();
        emit settingService->semesterWeeksChanged();
        emit settingService->scheduleDisplayModeChanged();
        emit settingService->scheduleShowWeekendChanged();
        emit settingService->dailyFocusGoalChanged();
        QCOMPARE(propertyCount, 28);
        const int frozenCount = count;
        categories = nil; days = nil; settings = nil;
        QVERIFY(weakCategories == nil && weakDays == nil && weakSettings == nil);
        emit categoryService->categoriesChanged(); emit dayService->changed(); emit settingService->nicknameChanged(); QCOMPARE(count, frozenCount);
    }
}
// 逐字段对照服务返回值，包括嵌套空值；桥接不得改写统计口径或把空值补成零。
static void compareValue(PTDayStatistics *value, const QVariantMap &map);
static void compareValue(PTMonthStatistics *value, const QVariantMap &map);
static void compareValue(PTComparisonMetric *value, const QVariantMap &map);
static void compareValue(PTStatisticsComparison *value, const QVariantMap &map);
static void compareValue(PTWeekDayStatistics *value, const QVariantMap &map);
static void compareValue(PTCategoryStatisticsRow *value, const QVariantMap &map);
static void compareValue(PTCategoryStatistics *value, const QVariantMap &map);
static void compareValue(PTTaskStatisticsRow *value, const QVariantMap &map);
static void compareValue(PTTaskStatistics *value, const QVariantMap &map);
static void compareValue(PTMonthWeekStatistics *value, const QVariantMap &map);
static void compareValue(PTReviewGoalDay *value, const QVariantMap &map);
static void compareValue(PTReviewGoal *value, const QVariantMap &map);
static void compareValue(PTReviewTodayGoal *value, const QVariantMap &map);
static void compareValue(PTReviewSubject *value, const QVariantMap &map);
static void compareValue(PTReviewPlannedRow *value, const QVariantMap &map);
static void compareValue(PTReviewPlannedTasks *value, const QVariantMap &map);
static void compareValue(PTReviewFact *value, const QVariantMap &map);
static void compareValue(PTWeeklyReview *value, const QVariantMap &map);
static void compareValue(PTFocusSummaryDay *value, const QVariantMap &map);
static void compareValue(PTFocusSummaryCategory *value, const QVariantMap &map);
static void compareValue(PTFocusSummary *value, const QVariantMap &map);
static void compareValue(PTDayStatistics *value, const QVariantMap &map) {
    QCOMPARE(value.totalDuration, NSInteger(map.value("totalDuration").toLongLong()));
    QCOMPARE(value.completedTasks, NSInteger(map.value("completedTasks").toLongLong()));
    QCOMPARE(value.totalTasks, NSInteger(map.value("totalTasks").toLongLong()));
    QCOMPARE(value.completionRate, double(map.value("completionRate").toDouble()));
    QCOMPARE(value.sessionCount, NSInteger(map.value("sessionCount").toLongLong()));
    QCOMPARE(value.pomodoroCount, NSInteger(map.value("pomodoroCount").toLongLong()));
}
static void compareValue(PTMonthStatistics *value, const QVariantMap &map) {
    QCOMPARE(value.totalDuration, NSInteger(map.value("totalDuration").toLongLong()));
    QCOMPARE(value.effectiveDays, NSInteger(map.value("effectiveDays").toLongLong()));
    QCOMPARE(value.sessionCount, NSInteger(map.value("sessionCount").toLongLong()));
    QCOMPARE(value.completedTasks, NSInteger(map.value("completedTasks").toLongLong()));
    QCOMPARE(value.totalTasks, NSInteger(map.value("totalTasks").toLongLong()));
}
static void compareValue(PTComparisonMetric *value, const QVariantMap &map) {
    QCOMPARE(value.hasData, BOOL(map.value("hasData").toBool()));
    QCOMPARE(value.currentValue, NSInteger(map.value("currentValue").toLongLong()));
    QCOMPARE(value.previousValue, NSInteger(map.value("previousValue").toLongLong()));
    QCOMPARE(value.changePercent, double(map.value("changePercent").toDouble()));
    QCOMPARE(value.trend, NSInteger(map.value("trend").toLongLong()));
    QCOMPARE(PTBridgeSupport::string(value.displayText), map.value("displayText").toString());
}
static void compareValue(PTStatisticsComparison *value, const QVariantMap &map) {
    QCOMPARE(value.hasData, BOOL(map.value("hasData").toBool()));
    QCOMPARE(PTBridgeSupport::string(value.periodState), map.value("periodState").toString());
    compareValue(value.duration, map.value("duration").toMap());
    compareValue(value.sessionCount, map.value("sessionCount").toMap());
    compareValue(value.taskCompletion, map.value("taskCompletion").toMap());
    compareValue(value.effectiveDays, map.value("effectiveDays").toMap());
}
static void compareValue(PTWeekDayStatistics *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString());
    QCOMPARE(value.duration, NSInteger(map.value("duration").toLongLong()));
    QCOMPARE(value.tasks, NSInteger(map.value("tasks").toLongLong()));
    QCOMPARE(value.completedTasks, NSInteger(map.value("completedTasks").toLongLong()));
}
static void compareValue(PTCategoryStatisticsRow *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.name), map.value("name").toString());
    QCOMPARE(PTBridgeSupport::string(value.color), map.value("color").toString());
    QCOMPARE(value.duration, NSInteger(map.value("duration").toLongLong()));
    QCOMPARE(value.percentage, double(map.value("percentage").toDouble()));
}
static void compareValue(PTCategoryStatistics *value, const QVariantMap &map) {
    const auto categories = map.value("categories").toList(); QCOMPARE(value.categories.count, NSUInteger(categories.size()));
    for (NSUInteger i = 0; i < value.categories.count; ++i) compareValue(value.categories[i], categories.at(static_cast<qsizetype>(i)).toMap());
    QCOMPARE(value.totalDuration, NSInteger(map.value("totalDuration").toLongLong()));
}
static void compareValue(PTTaskStatisticsRow *value, const QVariantMap &map) {
    QCOMPARE(value.taskId, NSInteger(map.value("taskId").isNull() ? -1 : map.value("taskId").toInt()));
    QCOMPARE(PTBridgeSupport::string(value.title), map.value("title").toString());
    QCOMPARE(value.completed, BOOL(map.value("completed").toBool()));
    QCOMPARE(PTBridgeSupport::string(value.categoryName), map.value("categoryName").toString());
    QCOMPARE(PTBridgeSupport::string(value.color), map.value("color").toString());
    QCOMPARE(value.focusedSeconds, NSInteger(map.value("focusedSeconds").toLongLong()));
    QCOMPARE(value.pomodoros, NSInteger(map.value("pomodoros").toLongLong()));
    QCOMPARE(value.unassigned, BOOL(map.value("unassigned").toBool()));
}
static void compareValue(PTTaskStatistics *value, const QVariantMap &map) {
    const auto tasks = map.value("tasks").toList(); QCOMPARE(value.tasks.count, NSUInteger(tasks.size()));
    for (NSUInteger i = 0; i < value.tasks.count; ++i) compareValue(value.tasks[i], tasks.at(static_cast<qsizetype>(i)).toMap());
    QCOMPARE(value.totalDuration, NSInteger(map.value("totalDuration").toLongLong()));
    QCOMPARE(value.taskCount, NSInteger(map.value("taskCount").toLongLong()));
}
static void compareValue(PTMonthWeekStatistics *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.label), map.value("label").toString());
    QCOMPARE(value.duration, NSInteger(map.value("duration").toLongLong()));
    QCOMPARE(PTBridgeSupport::string(value.startDate), map.value("startDate").toString());
    QCOMPARE(PTBridgeSupport::string(value.endDate), map.value("endDate").toString());
}
static void compareValue(PTReviewGoalDay *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString());
    QCOMPARE(value.goalMinutes, NSInteger(map.value("goalMinutes").toLongLong()));
    QCOMPARE(value.actualSeconds, NSInteger(map.value("actualSeconds").toLongLong()));
    QCOMPARE(value.met, BOOL(map.value("met").toBool()));
}
static void compareValue(PTReviewGoal *value, const QVariantMap &map) {
    QCOMPARE(value.goalDays, NSInteger(map.value("goalDays").toLongLong()));
    QCOMPARE(value.metDays, NSInteger(map.value("metDays").toLongLong()));
    QCOMPARE(value.goalMinutesTotal, NSInteger(map.value("goalMinutesTotal").toLongLong()));
    QCOMPARE(value.actualSecondsTotal, NSInteger(map.value("actualSecondsTotal").toLongLong()));
    const auto days = map.value("days").toList(); QCOMPARE(value.days.count, NSUInteger(days.size()));
    for (NSUInteger i = 0; i < value.days.count; ++i) compareValue(value.days[i], days.at(static_cast<qsizetype>(i)).toMap());
}
static void compareValue(PTReviewTodayGoal *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString());
    QCOMPARE(value.goalMinutes, NSInteger(map.value("goalMinutes").toLongLong()));
    QCOMPARE(value.actualSeconds, NSInteger(map.value("actualSeconds").toLongLong()));
    QCOMPARE(value.progressPercent, double(map.value("progressPercent").toDouble()));
}
static void compareValue(PTReviewSubject *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.name), map.value("name").toString());
    QCOMPARE(PTBridgeSupport::string(value.color), map.value("color").toString());
    QCOMPARE(value.currentSeconds, NSInteger(map.value("currentSeconds").toLongLong()));
    QCOMPARE(value.currentSharePercent, double(map.value("currentSharePercent").toDouble()));
    QCOMPARE(value.pseudoSubject, BOOL(map.value("pseudoSubject").toBool()));
    QCOMPARE(value.previousSeconds == nil, map.value("previousSeconds").isNull()); if (value.previousSeconds) QCOMPARE(value.previousSeconds.longLongValue, map.value("previousSeconds").toLongLong());
    QCOMPARE(value.deltaSeconds == nil, map.value("deltaSeconds").isNull()); if (value.deltaSeconds) QCOMPARE(value.deltaSeconds.longLongValue, map.value("deltaSeconds").toLongLong());
    QCOMPARE(value.previousSharePercent == nil, map.value("previousSharePercent").isNull()); if (value.previousSharePercent) QCOMPARE(value.previousSharePercent.doubleValue, map.value("previousSharePercent").toDouble());
    QCOMPARE(value.deltaPoints == nil, map.value("deltaPoints").isNull()); if (value.deltaPoints) QCOMPARE(value.deltaPoints.doubleValue, map.value("deltaPoints").toDouble());
}
static void compareValue(PTReviewPlannedRow *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.subject), map.value("subject").toString());
    QCOMPARE(PTBridgeSupport::string(value.color), map.value("color").toString());
    QCOMPARE(value.plannedMinutes, NSInteger(map.value("plannedMinutes").toLongLong()));
    QCOMPARE(value.actualSeconds, NSInteger(map.value("actualSeconds").toLongLong()));
    QCOMPARE(value.actualDisplayMinutes, NSInteger(map.value("actualDisplayMinutes").toLongLong()));
    QCOMPARE(value.differenceDisplayMinutes, NSInteger(map.value("differenceDisplayMinutes").toLongLong()));
    QCOMPARE(value.investmentRatioPercent, double(map.value("investmentRatioPercent").toDouble()));
}
static void compareValue(PTReviewPlannedTasks *value, const QVariantMap &map) {
    const auto rows = map.value("rows").toList(); QCOMPARE(value.rows.count, NSUInteger(rows.size()));
    for (NSUInteger i = 0; i < value.rows.count; ++i) compareValue(value.rows[i], rows.at(static_cast<qsizetype>(i)).toMap());
    QCOMPARE(value.inProgress, BOOL(map.value("inProgress").toBool()));
    QCOMPARE(value.totalPlannedMinutes, NSInteger(map.value("totalPlannedMinutes").toLongLong()));
    QCOMPARE(value.totalActualSeconds, NSInteger(map.value("totalActualSeconds").toLongLong()));
    QCOMPARE(value.totalActualDisplayMinutes, NSInteger(map.value("totalActualDisplayMinutes").toLongLong()));
    QCOMPARE(value.totalDifferenceDisplayMinutes, NSInteger(map.value("totalDifferenceDisplayMinutes").toLongLong()));
    QCOMPARE(value.totalInvestmentRatioPercent == nil, map.value("totalInvestmentRatioPercent").isNull()); if (value.totalInvestmentRatioPercent) QCOMPARE(value.totalInvestmentRatioPercent.doubleValue, map.value("totalInvestmentRatioPercent").toDouble());
}
static void compareValue(PTReviewFact *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.type), map.value("type").toString());
    QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString());
    QCOMPARE(PTBridgeSupport::string(value.subject), map.value("subject").toString());
    QCOMPARE(value.goalMinutes == nil, map.value("goalMinutes").isNull()); if (value.goalMinutes) QCOMPARE(value.goalMinutes.longLongValue, map.value("goalMinutes").toLongLong());
    QCOMPARE(value.actualSeconds == nil, map.value("actualSeconds").isNull()); if (value.actualSeconds) QCOMPARE(value.actualSeconds.longLongValue, map.value("actualSeconds").toLongLong());
    QCOMPARE(value.ratioPercent == nil, map.value("ratioPercent").isNull()); if (value.ratioPercent) QCOMPARE(value.ratioPercent.doubleValue, map.value("ratioPercent").toDouble());
    QCOMPARE(value.currentSeconds == nil, map.value("currentSeconds").isNull()); if (value.currentSeconds) QCOMPARE(value.currentSeconds.longLongValue, map.value("currentSeconds").toLongLong());
    QCOMPARE(value.previousSeconds == nil, map.value("previousSeconds").isNull()); if (value.previousSeconds) QCOMPARE(value.previousSeconds.longLongValue, map.value("previousSeconds").toLongLong());
    QCOMPARE(value.currentSharePercent == nil, map.value("currentSharePercent").isNull()); if (value.currentSharePercent) QCOMPARE(value.currentSharePercent.doubleValue, map.value("currentSharePercent").toDouble());
    QCOMPARE(value.deltaPoints == nil, map.value("deltaPoints").isNull()); if (value.deltaPoints) QCOMPARE(value.deltaPoints.doubleValue, map.value("deltaPoints").toDouble());
    QCOMPARE(value.plannedMinutes == nil, map.value("plannedMinutes").isNull()); if (value.plannedMinutes) QCOMPARE(value.plannedMinutes.longLongValue, map.value("plannedMinutes").toLongLong());
    QCOMPARE(value.actualDisplayMinutes == nil, map.value("actualDisplayMinutes").isNull()); if (value.actualDisplayMinutes) QCOMPARE(value.actualDisplayMinutes.longLongValue, map.value("actualDisplayMinutes").toLongLong());
    QCOMPARE(value.shortfallDisplayMinutes == nil, map.value("shortfallDisplayMinutes").isNull()); if (value.shortfallDisplayMinutes) QCOMPARE(value.shortfallDisplayMinutes.longLongValue, map.value("shortfallDisplayMinutes").toLongLong());
}
static void compareValue(PTWeeklyReview *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.weekStart), map.value("weekStart").toString());
    QCOMPARE(PTBridgeSupport::string(value.weekEnd), map.value("weekEnd").toString());
    QCOMPARE(PTBridgeSupport::string(value.logicalTodayIso), map.value("logicalTodayIso").toString());
    QCOMPARE(PTBridgeSupport::string(value.periodState), map.value("periodState").toString());
    QCOMPARE(PTBridgeSupport::string(value.loadState), map.value("loadState").toString());
    QCOMPARE(PTBridgeSupport::string(value.errorMessage), map.value("errorMessage").toString());
    QCOMPARE(value.hasData, BOOL(map.value("hasData").toBool()));
    QCOMPARE(value.hasDisplayContent, BOOL(map.value("hasDisplayContent").toBool()));
    QCOMPARE(value.goal == nil, map.value("goal").toMap().isEmpty()); if (value.goal) compareValue(value.goal, map.value("goal").toMap());
    QCOMPARE(value.todayGoal == nil, map.value("todayGoal").toMap().isEmpty()); if (value.todayGoal) compareValue(value.todayGoal, map.value("todayGoal").toMap());
    const auto subjects = map.value("subjects").toList(); QCOMPARE(value.subjects.count, NSUInteger(subjects.size()));
    for (NSUInteger i = 0; i < value.subjects.count; ++i) compareValue(value.subjects[i], subjects.at(static_cast<qsizetype>(i)).toMap());
    QCOMPARE(value.plannedTasks == nil, map.value("plannedTasks").toMap().isEmpty()); if (value.plannedTasks) compareValue(value.plannedTasks, map.value("plannedTasks").toMap());
    const auto facts = map.value("facts").toList(); QCOMPARE(value.facts.count, NSUInteger(facts.size()));
    for (NSUInteger i = 0; i < value.facts.count; ++i) compareValue(value.facts[i], facts.at(static_cast<qsizetype>(i)).toMap());
}
static void compareValue(PTFocusSummaryDay *value, const QVariantMap &map) {
    QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString());
    QCOMPARE(value.seconds, NSInteger(map.value("seconds").toLongLong()));
    QCOMPARE(value.pomodoros, NSInteger(map.value("pomodoros").toLongLong()));
}
static void compareValue(PTFocusSummaryCategory *value, const QVariantMap &map) {
    QCOMPARE(value.categoryId, NSInteger(map.value("id").isNull() ? -1 : map.value("id").toInt()));
    QCOMPARE(PTBridgeSupport::string(value.name), map.value("name").toString());
    QCOMPARE(value.seconds, NSInteger(map.value("seconds").toLongLong()));
}
static void compareValue(PTFocusSummary *value, const QVariantMap &map) {
    QCOMPARE(value.seconds, NSInteger(map.value("seconds").toLongLong()));
    QCOMPARE(value.pomodoros, NSInteger(map.value("pomodoros").toLongLong()));
    const auto days = map.value("days").toList(); QCOMPARE(value.days.count, NSUInteger(days.size()));
    for (NSUInteger i = 0; i < value.days.count; ++i) compareValue(value.days[i], days.at(static_cast<qsizetype>(i)).toMap());
    const auto categories = map.value("categories").toList(); QCOMPARE(value.categories.count, NSUInteger(categories.size()));
    for (NSUInteger i = 0; i < value.categories.count; ++i) compareValue(value.categories[i], categories.at(static_cast<qsizetype>(i)).toMap());
}
// 产品保证：统计所有只读入口保持原服务口径，报告逐字段复制且不丢失嵌套可选状态。
void PTCoreBridgeTests::statisticsReadEntryPointsAndNestedValues() {
    @autoreleasepool {
        struct Reset { ~Reset() { bridgeTestNow.reset(); } } reset;
        bridgeTestNow = QDateTime(QDate(2024, 3, 7), QTime(12, 0));
        auto *settings = AppSettings::instance(); settings->setDayStartHour(4);
        auto *tasks = TaskManager::instance(); auto *service = StatisticsService::instance();
        const int category = CategoryManager::instance()->addCategory(QStringLiteral("统计科"), QStringLiteral("#123456")); QVERIFY(category > 0);
        const int a = tasks->createTask(QStringLiteral("统计甲"), QDate(2024, 2, 29), category, 120, QStringLiteral("甲"));
        const int b = tasks->createTask(QStringLiteral("统计乙"), QDate(2024, 2, 26), -1, 30, QStringLiteral("乙")); QVERIFY(a > 0 && b > 0 && a != b);
        QVERIFY(tasks->completeTask(a)); QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2024-02-29"), 120));
        QSqlQuery seed(DatabaseManager::instance()->database());
        QVERIFY(seed.exec(QStringLiteral("INSERT INTO focus_sessions(task_id,start_time,end_time,duration,mode,pomodoro_completed) VALUES "
            "(%1,'2024-02-29T08:00:00.789','2024-02-29T08:10:00.789',243,1,1),"
            "(%2,'2024-02-26T09:00:00','2024-02-26T09:08:00',480,0,0),"
            "(%1,'2024-02-22T08:00:00','2024-02-22T08:20:00',1200,0,0)").arg(a).arg(b)));
        QVERIFY(service->getMonthStats(2024, 2).value("totalDuration").toInt() > 0);
        QVERIFY(service->getWeeklyReview(QDate(2024, 2, 26), QStringLiteral("2024-03-07")).value("goal").toMap().value("days").toList().size() > 0);
        PTStatisticsBridge *bridge = [PTStatisticsBridge new];
        PTStatisticsResult *result0 = [bridge dayStats:@"2024-02-29"]; QVERIFY(result0.valid);
        const auto expected0 = service->getDayStats(QDate(2024, 2, 29));
        compareValue(result0.day, expected0);
        PTStatisticsResult *result1 = [bridge todayStats]; QVERIFY(result1.valid);
        const auto expected1 = service->getTodayStats();
        compareValue(result1.day, expected1);
        PTStatisticsResult *result2 = [bridge dayComparison:@"2024-02-29"]; QVERIFY(result2.valid);
        const auto expected2 = service->getDayComparison(QDate(2024, 2, 29));
        compareValue(result2.comparison, expected2);
        PTStatisticsResult *result3 = [bridge weekStats:@"2024-02-26"]; QVERIFY(result3.valid);
        const auto expected3 = service->getWeekStats(QDate(2024, 2, 26));
        QCOMPARE(result3.weekDays.count, NSUInteger(expected3.size()));
        for (NSUInteger j = 0; j < result3.weekDays.count; ++j) compareValue(result3.weekDays[j], expected3.at(static_cast<qsizetype>(j)).toMap());
        PTStatisticsResult *result4 = [bridge currentWeekStats]; QVERIFY(result4.valid);
        const auto expected4 = service->getWeekStats();
        QCOMPARE(result4.weekDays.count, NSUInteger(expected4.size()));
        for (NSUInteger j = 0; j < result4.weekDays.count; ++j) compareValue(result4.weekDays[j], expected4.at(static_cast<qsizetype>(j)).toMap());
        PTStatisticsResult *result5 = [bridge weekComparison:@"2024-02-26" logicalToday:@"2024-03-07"]; QVERIFY(result5.valid);
        const auto expected5 = service->getWeekComparison(QDate(2024, 2, 26), QStringLiteral("2024-03-07"));
        compareValue(result5.comparison, expected5);
        PTStatisticsResult *result6 = [bridge categoryStats:@"2024-02-01" to:@"2024-02-29"]; QVERIFY(result6.valid);
        const auto expected6 = service->getCategoryStats(QDate(2024, 2, 1), QDate(2024, 2, 29));
        compareValue(result6.categoryStats, expected6);
        PTStatisticsResult *result7 = [bridge dayTaskStats:@"2024-02-29"]; QVERIFY(result7.valid);
        const auto expected7 = service->getDayTaskStats(QDate(2024, 2, 29));
        compareValue(result7.taskStats, expected7);
        PTStatisticsResult *result8 = [bridge todayTaskStats]; QVERIFY(result8.valid);
        const auto expected8 = service->getTodayTaskStats();
        compareValue(result8.taskStats, expected8);
        PTStatisticsResult *result9 = [bridge monthStats:2024 month:2]; QVERIFY(result9.valid);
        const auto expected9 = service->getMonthStats(2024, 2);
        compareValue(result9.month, expected9);
        PTStatisticsResult *result10 = [bridge currentMonthStats]; QVERIFY(result10.valid);
        const auto expected10 = service->getMonthStats();
        compareValue(result10.month, expected10);
        PTStatisticsResult *result11 = [bridge monthComparison:2024 month:2]; QVERIFY(result11.valid);
        const auto expected11 = service->getMonthComparison(2024, 2);
        compareValue(result11.comparison, expected11);
        PTMonthStatisticsInput *input = [PTMonthStatisticsInput new]; const auto current = service->getMonthStats(2024, 2);
        input.totalDuration = current.value("totalDuration").toInt();
        input.effectiveDays = current.value("effectiveDays").toInt();
        input.sessionCount = current.value("sessionCount").toInt();
        input.completedTasks = current.value("completedTasks").toInt();
        input.totalTasks = current.value("totalTasks").toInt();
        PTStatisticsResult *result12 = [bridge monthComparison:2024 month:2 current:input]; QVERIFY(result12.valid);
        const auto expected12 = service->getMonthComparison(2024, 2, current);
        compareValue(result12.comparison, expected12);
        PTStatisticsResult *result13 = [bridge effectiveDays:@"2024-02-01" to:@"2024-02-29"]; QVERIFY(result13.valid);
        const auto expected13 = service->getEffectiveDays(QDate(2024, 2, 1), QDate(2024, 2, 29));
        QCOMPARE(result13.count, NSInteger(expected13));
        PTStatisticsResult *result14 = [bridge focusSessionCount:@"2024-02-01" to:@"2024-02-29"]; QVERIFY(result14.valid);
        const auto expected14 = service->getFocusSessionCount(QDate(2024, 2, 1), QDate(2024, 2, 29));
        QCOMPARE(result14.count, NSInteger(expected14));
        PTStatisticsResult *result15 = [bridge validPomodoroCount:@"2024-02-01" to:@"2024-02-29"]; QVERIFY(result15.valid);
        const auto expected15 = service->getValidPomodoroCount(QDate(2024, 2, 1), QDate(2024, 2, 29));
        QCOMPARE(result15.count, NSInteger(expected15));
        PTStatisticsResult *result16 = [bridge streakDays]; QVERIFY(result16.valid);
        const auto expected16 = service->getStreakDays();
        QCOMPARE(result16.count, NSInteger(expected16));
        PTStatisticsResult *result17 = [bridge totalFocusDuration]; QVERIFY(result17.valid);
        const auto expected17 = service->getTotalFocusDuration();
        QCOMPARE(result17.count, NSInteger(expected17));
        PTStatisticsResult *result18 = [bridge monthWeeklySummary:2024 month:2]; QVERIFY(result18.valid);
        const auto expected18 = service->getMonthWeeklySummary(2024, 2);
        QCOMPARE(result18.monthWeeks.count, NSUInteger(expected18.size()));
        for (NSUInteger j = 0; j < result18.monthWeeks.count; ++j) compareValue(result18.monthWeeks[j], expected18.at(static_cast<qsizetype>(j)).toMap());
        PTStatisticsResult *result19 = [bridge currentMonthWeeklySummary]; QVERIFY(result19.valid);
        const auto expected19 = service->getMonthWeeklySummary();
        QCOMPARE(result19.monthWeeks.count, NSUInteger(expected19.size()));
        for (NSUInteger j = 0; j < result19.monthWeeks.count; ++j) compareValue(result19.monthWeeks[j], expected19.at(static_cast<qsizetype>(j)).toMap());
        PTStatisticsResult *result20 = [bridge weeklyReview:@"2024-02-26" logicalToday:@"2024-03-07"]; QVERIFY(result20.valid);
        const auto expected20 = service->getWeeklyReview(QDate(2024, 2, 26), QStringLiteral("2024-03-07"));
        compareValue(result20.review, expected20);
        PTStatisticsResult *result21 = [bridge currentWeeklyReview]; QVERIFY(result21.valid);
        const auto expected21 = service->getWeeklyReview();
        compareValue(result21.review, expected21);
        PTStatisticsResult *result22 = [bridge focusSummary:@"2024-02-01" to:@"2024-02-29" dayStartHour:4]; QVERIFY(result22.valid);
        const auto expected22 = service->readFocusSummary(QDate(2024, 2, 1), QDate(2024, 2, 29), 4);
        compareValue(result22.summary, expected22.value);
        auto currentReview = [bridge weeklyReview:@"2024-02-26" logicalToday:@"2024-02-29"];
        QVERIFY(currentReview.valid); QVERIFY(currentReview.review.subjects.count > 0);
        QVERIFY(currentReview.review.subjects.firstObject.previousSeconds == nil);
        QVERIFY(currentReview.review.todayGoal != nil);
    }
}
// 产品保证：统计失败不当成空报告、不重复广播，统计与历史信号回主线程且释放即断连。
void PTCoreBridgeTests::statisticsFailuresAndHistorySignalLifetime() {
    @autoreleasepool {
        PTStatisticsBridge *stats = [PTStatisticsBridge new]; PTFocusHistoryBridge *history = [PTFocusHistoryBridge new];
        auto empty = [stats dayStats:@"2024-02-29"]; QVERIFY(empty.valid); QCOMPARE(empty.day.totalDuration, NSInteger(0));
        __block int background = 0; stats.onFailure = ^(NSString *) { ++background; };
        DatabaseManager::instance()->close(); auto failed = [stats dayStats:@"2024-02-29"];
        QVERIFY(!failed.valid && failed.error.length > 0); QCOMPARE(background, 0);
        auto review = [stats weeklyReview:@"2024-02-26" logicalToday:@"2024-03-07"];
        QVERIFY(!review.valid && review.error.length > 0); QCOMPARE(review.review.subjects.count, NSUInteger(0));
        QVERIFY(![stats monthWeeklySummary:2024 month:2].valid);
        QVERIFY(![stats focusSummary:@"2024-02-01" to:@"2024-02-29" dayStartHour:4].valid);
        QVERIFY(![history daySessions:@"2024-02-29"].valid); QVERIFY(![history invalidSessionCount].valid);
        __block int calls = 0; __block BOOL onMain = YES;
        stats.onFailure = ^(NSString *) { ++calls; onMain = onMain && NSThread.isMainThread; };
        history.onChanged = ^{ ++calls; onMain = onMain && NSThread.isMainThread; };
        __weak PTStatisticsBridge *weakStats = stats; __weak PTFocusHistoryBridge *weakHistory = history;
        auto *statistics = StatisticsService::instance(); auto *sessions = FocusHistoryService::instance();
        std::unique_ptr<QThread> worker(QThread::create([=] { emit statistics->operationFailed(QStringLiteral("背景")); emit sessions->historyChanged(); }));
        worker->start(); QVERIFY(worker->wait(2000)); QCOMPARE(calls, 0); QTRY_COMPARE(calls, 2); QVERIFY(onMain);
        stats = nil; history = nil; QVERIFY(weakStats == nil && weakHistory == nil);
        emit statistics->operationFailed(QStringLiteral("释放后")); emit sessions->historyChanged(); QCOMPARE(calls, 2);
    }
}
// 产品保证：历史逐字段保留毫秒、秒数与暂停跨度；编辑只交改动，补录与失败使用服务原文。
// 产品保证：页面日期关系与周期导航认调用方同一逻辑今日，闰月、跨年和无效日期不在 Swift 重算。
void PTCoreBridgeTests::dateRelationsAndPeriodNavigation() {
    @autoreleasepool {
        PTLogicalDayBridge *bridge = [PTLogicalDayBridge new];
        NSError *error = nil;
        QCOMPARE([bridge relationOfDate:@"2024-02-29" toDate:@"2024-02-28" error:&error], NSInteger(1));
        QVERIFY(!error);
        QCOMPARE([bridge relationOfDate:@"2024-02-28" toDate:@"2024-02-28" error:&error], NSInteger(0));
        QCOMPARE([bridge relationOfDate:@"2023-12-31" toDate:@"2024-02-28" error:&error], NSInteger(-1));
        [bridge relationOfDate:@"2024-02-30" toDate:@"2024-02-28" error:&error];
        QVERIFY(error); error = nil;
        [bridge relationOfDate:@"2024-2-28" toDate:@"2024-02-28" error:&error];
        QVERIFY(error); error = nil;
        PTPeriodDates *month = [bridge periodForAnchor:@"2024-01-31" range:@"month" shift:1 logicalToday:@"2024-03-01" error:&error];
        QVERIFY(month); QVERIFY(!error);
        QCOMPARE(PTBridgeSupport::string(month.start), QStringLiteral("2024-02-01"));
        QCOMPARE(PTBridgeSupport::string(month.end), QStringLiteral("2024-02-29"));
        QCOMPARE(month.year, NSInteger(2024)); QCOMPARE(month.month, NSInteger(2));
        QVERIFY(month.canAdvance); QVERIFY(!month.current);
        PTPeriodDates *week = [bridge periodForAnchor:@"2027-01-01" range:@"week" shift:0 logicalToday:@"2027-01-03" error:&error];
        QVERIFY(week); QVERIFY(week.current); QVERIFY(!week.canAdvance);
        QCOMPARE(PTBridgeSupport::string(week.start), QStringLiteral("2026-12-28"));
        QCOMPARE(PTBridgeSupport::string(week.end), QStringLiteral("2027-01-03"));
        PTPeriodDates *previous = [bridge periodForAnchor:week.start range:@"week" shift:-1 logicalToday:@"2027-01-03" error:&error];
        QCOMPARE(PTBridgeSupport::string(previous.start), QStringLiteral("2026-12-21"));
        PTPeriodDates *day = [bridge periodForAnchor:@"2024-02-28" range:@"day" shift:1 logicalToday:@"2024-02-28" error:&error];
        QCOMPARE(PTBridgeSupport::string(day.start), QStringLiteral("2024-02-29"));
        QVERIFY(!day.current); QVERIFY(!day.canAdvance);
        QVERIFY(![bridge periodForAnchor:@"2024-02-28" range:@"bad" shift:0 logicalToday:@"2024-02-28" error:&error]);
        QVERIFY(error); error = nil;
        QVERIFY(![bridge periodForAnchor:@"2000-01-01" range:@"month" shift:-1 logicalToday:@"2024-02-28" error:&error]);
        QVERIFY(error);
    }
}

// 产品保证：月历取档与 Mac 共用服务，小数分钟、阈值等号和非数值不会被桥接改变。
void PTCoreBridgeTests::historyBandsMatchCaliberFixtures() {
    @autoreleasepool {
        QFile fixture(QFINDTESTDATA("fixtures/calibers/heatmap-bands.json"));
        QVERIFY(fixture.open(QIODevice::ReadOnly));
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(fixture.readAll(), &error);
        QCOMPARE(error.error, QJsonParseError::NoError);
        QVERIFY(document.isArray());
        const auto rows = document.array();
        QCOMPARE(rows.size(), 19);
        PTFocusHistoryBridge *bridge = [PTFocusHistoryBridge new];
        for (const auto &entry : rows) {
            const auto row = entry.toObject();
            const auto input = row.value("input");
            double minutes = 0;
            if (input.isDouble()) minutes = input.toDouble();
            else if (input.isString()) {
                bool ok = false;
                minutes = input.toString().toDouble(&ok);
                if (!ok) minutes = std::numeric_limits<double>::quiet_NaN();
            } else if (input.isObject()) {
                const auto special = input.toObject().value("special").toString();
                if (special == "Infinity") minutes = std::numeric_limits<double>::infinity();
                else if (special == "-Infinity") minutes = -std::numeric_limits<double>::infinity();
                else minutes = std::numeric_limits<double>::quiet_NaN();
            }
            const int expected = row.value("expected").toInt();
            QCOMPARE(FocusHistoryService::instance()->bandForMinutes(minutes), expected);
            QCOMPARE([bridge bandForMinutes:minutes], expected);
        }
    }
}

void PTCoreBridgeTests::historyFieldsPartialChangesAndFailures() {
    @autoreleasepool {
        struct Reset { ~Reset() { bridgeTestNow.reset(); } } reset;
        bridgeTestNow = QDateTime(QDate(2024, 3, 7), QTime(12, 0)); AppSettings::instance()->setDayStartHour(4);
        auto *tasks = TaskManager::instance(); auto *service = FocusHistoryService::instance();
        const int a = tasks->createTask(QStringLiteral("历史甲"), QDate(2024, 2, 29), -1, 0, QString());
        const int b = tasks->createTask(QStringLiteral("历史乙"), QDate(2024, 2, 28), -1, 0, QString()); QVERIFY(a > 0 && b > 0 && a != b);
        QSqlQuery seed(DatabaseManager::instance()->database());
        QVERIFY(seed.exec(QStringLiteral("INSERT INTO focus_sessions(id,task_id,start_time,end_time,duration,mode,pomodoro_completed) VALUES "
            "(100,%1,'2024-02-29T08:00:00.789','2024-02-29T08:10:00.789',243,1,1),"
            "(101,NULL,'2024-02-29T11:00:00','2024-02-29T11:01:00',60,0,0)").arg(a)));
        QVERIFY(seed.exec("INSERT INTO rest_sessions(id,start_time,end_time,duration,manual) VALUES (200,'2024-02-29T09:00:00.456','2024-02-29T09:10:00.456',301,1)"));
        PTFocusHistoryBridge *bridge = [PTFocusHistoryBridge new]; NSError *error = nil;
        auto timeline = [bridge dayTimeline:@"2024-02-29"]; QVERIFY(timeline.valid); QCOMPARE(timeline.sessions.count, NSUInteger(2));
        auto raw = service->getDayTimeline(QDate(2024, 2, 29));
        for (NSUInteger i = 0; i < timeline.sessions.count; ++i) {
            auto value = timeline.sessions[i]; auto map = raw.at(static_cast<qsizetype>(i)).toMap();
            QCOMPARE(value.sessionId, NSInteger(map.value("id").toInt()));
            QCOMPARE(value.taskId, NSInteger(map.value("taskId").isNull() ? -1 : map.value("taskId").toInt()));
            QCOMPARE(PTBridgeSupport::string(value.taskTitle), map.value("taskTitle").toString());
            QCOMPARE(PTBridgeSupport::timestamp(value.startTime), QDateTime::fromString(map.value("startTime").toString(), Qt::ISODate));
            QCOMPARE(PTBridgeSupport::timestamp(value.endTime), QDateTime::fromString(map.value("endTime").toString(), Qt::ISODate));
            QCOMPARE(value.durationSeconds, NSInteger(map.value("durationSeconds").toInt()));
            QCOMPARE(PTBridgeSupport::string(value.date), map.value("date").toString()); QCOMPARE(bool(value.isRest), map.value("isRest").toBool());
        }
        QVERIFY(!timeline.sessions.firstObject.isRest && timeline.sessions.lastObject.isRest);
        QCOMPARE([bridge monthSessions:2024 month:2].sessions.count, NSUInteger(1));
        QCOMPARE([bridge dayTotalDuration:@"2024-02-29"].count, NSInteger(243));
        QCOMPARE([bridge invalidSessionCount].count, NSInteger(1));
        QVERIFY([[bridge formatDuration:3660] isEqualToString:@"1小时1分"]);
        auto options = [bridge taskOptions:@"2024-02-29"]; QVERIFY(options.valid); QCOMPARE(options.taskOptions.count, NSUInteger(2));
        auto rawOptions = service->getTaskOptions(QDate(2024, 2, 29));
        for (NSUInteger i = 0; i < options.taskOptions.count; ++i) {
            QCOMPARE(options.taskOptions[i].taskId, NSInteger(rawOptions.at(static_cast<qsizetype>(i)).toMap().value("id").toInt()));
            QCOMPARE(PTBridgeSupport::string(options.taskOptions[i].title), rawOptions.at(static_cast<qsizetype>(i)).toMap().value("title").toString());
        }
        PTSessionChanges *changes = [PTSessionChanges new]; changes.taskId = b;
        QVERIFY(changes.hasTaskId && !changes.hasDurationSeconds && !changes.hasStartTime && !changes.hasIsRest);
        QVERIFY([bridge updateSession:100 changes:changes error:&error]);
        auto updated = [bridge daySessions:@"2024-02-29"].sessions.firstObject;
        QCOMPARE(updated.taskId, NSInteger(b)); QCOMPARE(updated.durationSeconds, NSInteger(243));
        QCOMPARE(PTBridgeSupport::timestamp(updated.startTime).time().msec(), 789);
        QCOMPARE(PTBridgeSupport::timestamp(updated.startTime).msecsTo(PTBridgeSupport::timestamp(updated.endTime)), qint64(600000));
        // 清空使用显式哨兵；成功与失败必须和服务一致，桥接不能掩盖原服务约束失败。
        const bool serviceCleared = service->updateSessionFields(100, QVariantMap{{QStringLiteral("taskId"), -1}});
        const QString clearingError = service->lastError();
        changes = [PTSessionChanges new]; changes.taskId = -1;
        QCOMPARE(bool([bridge updateSession:100 changes:changes error:&error]), serviceCleared);
        if (!serviceCleared) QCOMPARE(PTBridgeSupport::string(error.localizedDescription), clearingError);
        QCOMPARE([bridge daySessions:@"2024-02-29"].sessions.firstObject.taskId, NSInteger(serviceCleared ? -1 : b));
        changes = [PTSessionChanges new]; changes.startTime = @"2024-02-29T08:01:00.547"; changes.durationSeconds = 255;
        QVERIFY([bridge updateSession:100 changes:changes error:&error]); updated = [bridge daySessions:@"2024-02-29"].sessions.firstObject;
        QCOMPARE(updated.durationSeconds, NSInteger(255)); QCOMPARE(PTBridgeSupport::timestamp(updated.startTime).time().msec(), 547);
        changes = [PTSessionChanges new]; changes.durationSeconds = 333;
        QVERIFY([bridge updateRestSession:200 changes:changes error:&error]);
        changes = [PTSessionChanges new]; changes.isRest = NO; changes.taskId = a;
        QVERIFY([bridge updateRestSession:200 changes:changes error:&error]);
        auto focusRows = [bridge daySessions:@"2024-02-29"].sessions; QCOMPARE(focusRows.count, NSUInteger(2));
        changes = [PTSessionChanges new]; changes.isRest = YES;
        QVERIFY([bridge updateSession:focusRows.lastObject.sessionId changes:changes error:&error]);
        NSInteger created = [bridge addManualSession:b startTime:@"2024-02-29T10:00:00.321" durationMinutes:10 error:&error]; QVERIFY(created > 0);
        QCOMPARE([bridge cleanupInvalidSessions:&error], NSInteger(1)); QCOMPARE([bridge invalidSessionCount].count, NSInteger(0));
        changes = [PTSessionChanges new]; changes.durationSeconds = 1;
        QVERIFY(![bridge updateSession:100 changes:changes error:&error]);
        QCOMPARE(PTBridgeSupport::string(error.localizedDescription), service->lastError()); QVERIFY([bridge.lastError isEqualToString:error.localizedDescription]);
        QVERIFY([bridge addManualSession:a startTime:@"2024-02-29T08:02:00" durationMinutes:5 error:&error] < 0);
        QCOMPARE(PTBridgeSupport::string(error.localizedDescription), service->lastError());
        QVERIFY(![bridge monthSessions:NSIntegerMax month:2].valid);
        QVERIFY(![bridge updateSession:NSIntegerMax changes:changes error:&error]);
    }
}
QTEST_GUILESS_MAIN(PTCoreBridgeTests)


#include "PTCoreBridgeTests.moc"
