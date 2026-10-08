#import "../src/platform/ios/bridge/PTShellBridge.h"
#import "../src/platform/ios/bridge/PTLifecycleBridge.h"
#include <QCoreApplication>
#include <QSettings>
#include <QTemporaryDir>
#include <QThread>
#include <memory>
#include <QtTest>
#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/TaskManager.h"

class PTShellBridgeTests : public QObject {
    Q_OBJECT
private slots:
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
        const int gap = KnowledgeGapService::instance()->addGap(QStringLiteral("到期"), -1, QString(), 1, today, -1);
        QVERIFY(gap > 0);
        PTShellBridge *bridge = [PTShellBridge new];
        PTShellSnapshot *snapshot = [bridge readSnapshot];
        QVERIFY(snapshot.valid);
        QCOMPARE(snapshot.todayPendingCount, NSInteger(1));
        QCOMPARE(snapshot.weekPendingCount, NSInteger(1));
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
QTEST_GUILESS_MAIN(PTShellBridgeTests)
#include "PTShellBridgeTests.moc"
