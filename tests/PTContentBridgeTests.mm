#import "../src/platform/ios/bridge/PTKnowledgeGapBridge.h"
#import "../src/platform/ios/bridge/PTMemoBridge.h"
#import "../src/platform/ios/bridge/PTCountdownBridge.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/MemoService.h"
#include "../src/services/CountdownService.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/TaskManager.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/AppSettings.h"
#include <QSettings>
#include <QTemporaryDir>
#include <QThread>
#include <QSqlQuery>
#include <QtTest>
#include <memory>

class PTContentBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase();
    void init();
    void cleanup();
    void gapFieldsActionsAndPartialChanges();
    void memoFieldsWritesAndPartialChanges();
    void countdownModelOrderingAndPartialChanges();
    void readsSeparateEmptyMissingAndFailure();
    void failuresAreReportedOnceAndRejectOverflow();
    void signalsReturnToMainThreadAndDisconnect();
private:
    QTemporaryDir preferences, database;
};
void PTContentBridgeTests::initTestCase() {
    // 偏好与数据库完全隔离，避免并行测试互相改逻辑日设置。
    QVERIFY(preferences.isValid()); QVERIFY(database.isValid());
    QCoreApplication::setOrganizationName("PTContentBridgeTests");
    QCoreApplication::setApplicationName("PTContentBridgeTests");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences.path());
}
void PTContentBridgeTests::init() {
    QFile::remove(database.filePath("test.sqlite"));
    QVERIFY(DatabaseManager::instance()->initialize(database.filePath("test.sqlite")));
}
void PTContentBridgeTests::cleanup() { DatabaseManager::instance()->close(); }
// 产品保证：缺口字段、改期、解决重开与转任务原样走服务，字段修改不覆盖未改正文。
void PTContentBridgeTests::gapFieldsActionsAndPartialChanges() {
    @autoreleasepool {
        PTKnowledgeGapBridge *b = [PTKnowledgeGapBridge new]; NSError *error = nil;
        const auto today = LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate).toNSString();
        const int category = CategoryManager::instance()->addCategory(QStringLiteral("缺口科目"), QStringLiteral("#be8568"));
        QVERIFY(category > 0);
        const int source = TaskManager::instance()->createTask(QStringLiteral("来源现场"), LogicalDay::today(AppSettings::instance()->dayStartHour()), category, 23, QString());
        QVERIFY(source > 0);
        NSInteger first = [b addTitle:@"第一条" categoryId:category detail:@"现场" priority:2 dueDate:@"" sourceTaskId:source error:&error];
        NSInteger second = [b addTitle:@"第二条" categoryId:-1 detail:@"不同正文" priority:0 dueDate:today sourceTaskId:-1 error:&error];
        QVERIFY(first > 0 && second > 0 && first != second); QVERIFY(!error);
        auto value = [b gap:first].items.firstObject;
        QVERIFY([value.detail isEqualToString:@"现场"]); QCOMPARE(value.priority, NSInteger(2)); QCOMPARE(value.sourceTaskId, NSInteger(source));
        QCOMPARE(value.gapId, first); QCOMPARE(value.categoryId, NSInteger(category));
        QVERIFY([value.title isEqualToString:@"第一条"]); QVERIFY([value.categoryName isEqualToString:@"缺口科目"]);
        QVERIFY([value.categoryColor isEqualToString:@"#be8568"]); QVERIFY([value.sourceTaskTitle isEqualToString:@"来源现场"]);
        QCOMPARE(value.status, NSInteger(0)); QVERIFY(!value.scheduled && !value.overdue && !value.dueToday);
        QCOMPARE(value.overdueDays, NSInteger(0)); QCOMPARE(value.linkedTaskId, NSInteger(-1));
        QVERIFY(!value.linkedTaskOpen && !value.linkedTaskCompleted); QVERIFY(value.linkedTaskTitle.length == 0);
        QVERIFY(value.createdAt.length > 0 && value.updatedAt.length > 0 && value.resolvedAt.length == 0);
        auto scheduled = [b gap:second].items.firstObject;
        QVERIFY(scheduled.scheduled && scheduled.dueToday); QVERIFY([scheduled.dueDate isEqualToString:today]);
        PTKnowledgeGapChanges *changes = [PTKnowledgeGapChanges new]; changes.title = @"改标题";
        QVERIFY(changes.hasTitle && !changes.hasDetail); QVERIFY([b updateGap:first changes:changes error:&error]);
        QVERIFY([[b gap:first].items.firstObject.detail isEqualToString:@"现场"]);
        QVERIFY([b setDueDate:first date:today error:&error]);
        QVERIFY(([b moveGaps:@[@(first), @(second)] date:@"" error:&error]));
        QVERIFY([b resolveGap:first resolution:@"结论" error:&error]); QCOMPARE([b gap:first].items.firstObject.status, NSInteger(2)); QVERIFY([b gap:first].items.firstObject.resolvedAt.length > 0);
        QVERIFY([b reopenGap:first error:&error]); QVERIFY([[b gap:first].items.firstObject.resolution isEqualToString:@"结论"]);
        QVERIFY([b convertGap:first date:today error:&error] > 0);
        QVERIFY([b gap:first].items.firstObject.linkedTaskOpen);
        QVERIFY([b convertGap:first date:today error:&error] < 0); QVERIFY(error.localizedDescription.length > 0);
        error = nil; QVERIFY([b deleteGap:second error:&error]);
        QCOMPARE([b gapsWithStatus:-1 categoryId:0 search:@"改标题"].items.count, NSUInteger(1));
    }
}
// 产品保证：备忘录点新建即写库，读回所有字段；部分更新和完整同科目排序不会覆盖正文。
void PTContentBridgeTests::memoFieldsWritesAndPartialChanges() {
    @autoreleasepool {
        PTMemoBridge *b = [PTMemoBridge new]; NSError *error = nil;
        const int category = CategoryManager::instance()->addCategory(QStringLiteral("备忘科目"), QStringLiteral("#c9956e"));
        QVERIFY(category > 0);
        NSInteger first = [b createTitle:@"标题" body:@"正文🍅\n下一行" categoryId:category error:&error];
        NSInteger second = [b createTitle:@"" body:@"" categoryId:category error:&error];
        QVERIFY(first > 0 && second > 0 && first != second); QCOMPARE([b memos].items.count, NSUInteger(2));
        auto value = [b memo:first].items.firstObject; QVERIFY([value.body isEqualToString:@"正文🍅\n下一行"]);
        QVERIFY([value.preview isEqualToString:@"正文🍅"]); QVERIFY(value.updatedAt.length > 0 && value.createdAt.length > 0);
        QCOMPARE(value.memoId, first); QCOMPARE(value.categoryId, NSInteger(category)); QCOMPARE(value.sortOrder, NSInteger(1));
        QVERIFY([value.title isEqualToString:@"标题"]); QVERIFY([value.displayTitle isEqualToString:@"标题"]);
        QVERIFY([value.categoryName isEqualToString:@"备忘科目"]); QVERIFY([value.categoryColor isEqualToString:@"#c9956e"]);
        PTMemoChanges *changes = [PTMemoChanges new]; changes.title = @"";
        QVERIFY(changes.hasTitle && !changes.hasBody); QVERIFY([b updateMemo:first changes:changes error:&error]);
        QVERIFY([[b memo:first].items.firstObject.body isEqualToString:@"正文🍅\n下一行"]);
        QVERIFY(([b reorderCategory:category ids:@[@(second), @(first)] error:&error]));
        QCOMPARE([b memos].items.firstObject.memoId, second);
        QVERIFY([b deleteMemo:first error:&error]); QCOMPARE([b memos].items.count, NSUInteger(1));
    }
}
// 产品保证：倒计时主目标取服务首项，排序、剩余天数与部分更新保持服务口径。
void PTContentBridgeTests::countdownModelOrderingAndPartialChanges() {
    @autoreleasepool {
        PTCountdownBridge *b = [PTCountdownBridge new]; NSError *error = nil;
        const auto today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        __block int modelChanges = 0, primaryChanges = 0;
        b.onChanged = ^{ ++modelChanges; }; b.onPrimaryGoalChanged = ^{ ++primaryChanges; };
        QVERIFY([b addName:@"第一目标" date:today.addDays(8).toString(Qt::ISODate).toNSString() error:&error]);
        QVERIFY([b addName:@"第二目标" date:today.addDays(21).toString(Qt::ISODate).toNSString() error:&error]);
        QVERIFY(modelChanges >= 2 && primaryChanges >= 1);
        auto rows = [b goals]; QVERIFY(rows.valid); QCOMPARE(rows.items.count, NSUInteger(2));
        QVERIFY([rows.items[0].name isEqualToString:@"第一目标"]); QCOMPARE(rows.items[0].displayOrder, NSInteger(0));
        QVERIFY(rows.items[0].createdAt.length > 0 && rows.items[0].updatedAt.length > 0);
        NSInteger second = rows.items[1].goalId; QCOMPARE(rows.items[1].daysRemaining, NSInteger(21));
        QVERIFY([b reorderFrom:1 to:0 error:&error]); QCOMPARE([b primaryGoal].items.firstObject.goalId, second);
        PTCountdownChanges *changes = [PTCountdownChanges new]; changes.name = @"只改名字";
        QVERIFY([b updateGoal:second changes:changes error:&error]);
        QVERIFY([[b primaryGoal].items.firstObject.targetDate isEqualToString:today.addDays(21).toString(Qt::ISODate).toNSString()]);
        QCOMPARE([b daysRemaining:today.addDays(8).toString(Qt::ISODate).toNSString()], NSInteger(8));
        QVERIFY([b deleteGoal:second error:&error]); QCOMPARE([b goals].items.count, NSUInteger(1));
        QSqlQuery trash(DatabaseManager::instance()->database()); QVERIFY(trash.exec("SELECT COUNT(*) FROM trash_items WHERE kind = 'countdown_goal'")); QVERIFY(trash.next()); QCOMPARE(trash.value(0).toInt(), 1);
    }
}
// 产品保证：空列表合法，单项不存在和关库读取失败必须带错误，不伪装为空。
void PTContentBridgeTests::readsSeparateEmptyMissingAndFailure() {
    @autoreleasepool {
        PTKnowledgeGapBridge *g = [PTKnowledgeGapBridge new]; PTMemoBridge *m = [PTMemoBridge new]; PTCountdownBridge *c = [PTCountdownBridge new];
        QVERIFY([g gapsWithStatus:-1 categoryId:0 search:@""].valid); QVERIFY([m memos].valid); QVERIFY([c goals].valid);
        QVERIFY(![g gap:99999].valid); QVERIFY(![m memo:99999].valid);
        DatabaseManager::instance()->close();
        QVERIFY(![g gapsWithStatus:-1 categoryId:0 search:@""].valid); QVERIFY(![m memos].valid); QVERIFY(![c goals].valid);
        QVERIFY([m memos].error.length > 0);
    }
}
// 产品保证：同步写失败只由 NSError 返回一次，背景错误独立转发，宽整数不截断。
void PTContentBridgeTests::failuresAreReportedOnceAndRejectOverflow() {
    @autoreleasepool {
        PTMemoBridge *m = [PTMemoBridge new]; __block int calls = 0; m.onFailure = ^(NSString *) { ++calls; }; NSError *error = nil;
        QVERIFY([m createTitle:@"" body:@"" categoryId:NSIntegerMax error:&error] < 0); QVERIFY(error);
        error = nil; QVERIFY(![m deleteMemo:9999 error:&error]); QVERIFY(error); QCOMPARE(calls, 0);
        emit MemoService::instance()->operationFailed(QStringLiteral("背景失败")); QCOMPARE(calls, 1);
        PTKnowledgeGapBridge *g = [PTKnowledgeGapBridge new]; QVERIFY(![g gap:NSIntegerMax].valid);
        PTCountdownBridge *c = [PTCountdownBridge new]; QVERIFY(![c reorderFrom:NSIntegerMax to:0 error:&error]);
    }
}
// 产品保证：三个领域信号均转发，工作线程回主线程，释放桥接后不再回调。
void PTContentBridgeTests::signalsReturnToMainThreadAndDisconnect() {
    __block int gapCalls = 0, taskCalls = 0, memoCalls = 0, goalCalls = 0, primaryCalls = 0;
    __block BOOL mainThread = NO;
    __weak PTMemoBridge *released = nil;
    @autoreleasepool {
        PTKnowledgeGapBridge *g = [PTKnowledgeGapBridge new]; PTMemoBridge *m = [PTMemoBridge new]; PTCountdownBridge *c = [PTCountdownBridge new];
        released = m;
        g.onChanged = ^{ ++gapCalls; }; g.onTasksAffected = ^{ ++taskCalls; };
        m.onChanged = ^{ ++memoCalls; mainThread = NSThread.isMainThread; };
        c.onChanged = ^{ ++goalCalls; }; c.onPrimaryGoalChanged = ^{ ++primaryCalls; };
        emit KnowledgeGapService::instance()->gapsChanged(); emit KnowledgeGapService::instance()->tasksAffected();
        emit MemoService::instance()->memosChanged(); emit CountdownService::instance()->primaryGoalChanged(); emit CountdownService::instance()->goalsReloaded();
        QCOMPARE(gapCalls, 1); QCOMPARE(taskCalls, 1); QCOMPARE(memoCalls, 1); QCOMPARE(goalCalls, 1); QCOMPARE(primaryCalls, 1);
        auto *service = MemoService::instance(); std::unique_ptr<QThread> worker(QThread::create([service] { emit service->memosChanged(); }));
        worker->start(); QVERIFY(worker->wait(2000)); QCOMPARE(memoCalls, 1); QTRY_COMPARE(memoCalls, 2); QVERIFY(mainThread);
    }
    QVERIFY(released == nil); emit MemoService::instance()->memosChanged(); QCOMPARE(memoCalls, 2);
    emit KnowledgeGapService::instance()->gapsChanged(); emit CountdownService::instance()->goalsReloaded(); QCOMPARE(gapCalls, 1); QCOMPARE(goalCalls, 1);
}
QTEST_GUILESS_MAIN(PTContentBridgeTests)
#include "PTContentBridgeTests.moc"
