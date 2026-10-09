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
#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
#import "../src/platform/ios/bridge/PTCategoryBridge.h"
#import "../src/platform/ios/bridge/PTLogicalDayBridge.h"
#import "../src/platform/ios/bridge/PTSettingsBridge.h"
@interface PTSettingsBridge (TestInjection)
- (instancetype)initWithSettings:(AppSettings *)settings;
@end
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
QTEST_GUILESS_MAIN(PTCoreBridgeTests)


#include "PTCoreBridgeTests.moc"
