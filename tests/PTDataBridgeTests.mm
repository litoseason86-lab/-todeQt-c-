#include "../src/services/RoutineManager.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/TaskManager.h"
#include <QScopeGuard>
#include "../src/services/DatabaseManager.h"
#include "../src/services/AppSettings.h"
#include "../src/services/SyncController.h"
#include "../src/services/BackupService.h"
#import "../src/platform/ios/bridge/PTBridgeSupport.h"
#import "../src/platform/ios/bridge/PTTrashBridge.h"
#import "../src/platform/ios/bridge/PTSyncBridge.h"
#import "../src/platform/ios/bridge/PTBackupBridge.h"
#import "../src/platform/ios/bridge/PTExportBridge.h"
#import "../src/platform/ios/bridge/PTRoutineBridge.h"
#include <QFile>
#include <QSettings>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

// 旧实现先用选择器断言暴露缺失契约，避免测试向尚不存在的方法发消息。
@interface PTSyncBridge (T24FailureContract)
- (BOOL)setEnabled:(BOOL)value error:(NSError **)error;
- (BOOL)confirmJoin:(NSError **)error;
- (BOOL)syncNow:(NSError **)error;
- (BOOL)chooseFolder:(NSError **)error;
- (BOOL)rebuildFolder:(NSError **)error;
- (BOOL)copyLostValue:(NSString *)text error:(NSError **)error;
@end

// 仅测试声明内部转换入口，不把 QVariantMap 暴露给 Swift 模块。
@interface PTTrashItemValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTTrashActionValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTRoutineValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTBackupInfoValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTBackupEntryValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTSyncLogValue (PTDataBridgeTests)
- (instancetype)initWithMap:(const QVariantMap &)map;
@end

class PTDataBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void entityWriteReasonsAreClaimed_data();
    void entityWriteReasonsAreClaimed();
    void syncActionsRejectReleasedService_data();
    void syncActionsRejectReleasedService();
    void initTestCase();
    void init();
    void cleanup();
    void trashBridgeDistinguishesEmptyAndReadFailure();
    void trashBridgeEmptyUsesProvidedIdentifiers();
    void syncBridgeDistinguishesEmptyAndDatabaseFailure();
    void backupBridgeDistinguishesMissingAndUnreadableFolder();
    void exportAndRoutineBridgeForwardServiceOperations();
    void routineBridgePreservesFieldTypesAndReadFailures();
    void syncBridgeSurvivesServiceDestruction();
    void backupBridgeDetectsPreferenceWriteFailure();
    void trashRestoreKeepsStructuredFailure();
    void trashEmptyRejectsOverflowWithoutDeletingTruncatedId();
    void trashTypedValuesPreserveDetailsAndFailure();
    void typedValuesPreserveRoutineBackupAndSyncFields();
private:
    QTemporaryDir m_preferences;
    QTemporaryDir m_database;
};

// 产品保证：每个写入桥接都保留参数、存储及数据库关闭的具体服务原因。
void PTDataBridgeTests::entityWriteReasonsAreClaimed_data()
{
    QTest::addColumn<QString>("action"); QTest::addColumn<QString>("failure");
    for (const QString& action : QStringList{"routine-add", "routine-update", "routine-delete", "routine-active", "routine-weekdays"})
        for (const QString& failure : QStringList{"invalid", "closed", "write"})
            QTest::newRow((action + '-' + failure).toUtf8().constData()) << action << failure;
}
// 产品保证：一次调用的 NSError 与服务原因逐字一致，外壳和旁观桥接均不重复收到。
void PTDataBridgeTests::entityWriteReasonsAreClaimed()
{
    @autoreleasepool {
        QFETCH(QString, action); QFETCH(QString, failure);
        auto* categories = CategoryManager::instance();
        const int category = categories->addCategory(QStringLiteral("桥接科目"), "#123456");
        QVERIFY(category > 0);
        auto* service = RoutineManager::instance();
        QVERIFY(service->addRoutine(QStringLiteral("桥接例行"), category));
        const int validId = service->getRoutines().first().toMap().value("id").toInt();
        PTRoutineBridge* bridge = [PTRoutineBridge new]; PTRoutineBridge* observer = [PTRoutineBridge new];
        __block int ownerFailures = 0, observerFailures = 0;
        bridge.onFailure = ^(NSString*) { ++ownerFailures; }; observer.onFailure = ^(NSString*) { ++observerFailures; };
        int shellFailures = 0; QObject shell;
        PTBridgeSupport::registerUnclaimedFailureHandler(&shell, [&](const QString&) { ++shellFailures; });
        const auto unregister = qScopeGuard([&] { PTBridgeSupport::unregisterUnclaimedFailureHandler(&shell); });
        QSignalSpy failures(service, SIGNAL(operationFailed(QString))); QVERIFY(failures.isValid());
        if (failure == "closed") DatabaseManager::instance()->close();
        if (failure == "write") {
            const QString table = action.startsWith("task-") ? "tasks" : action.startsWith("category-") ? "categories" : "routines";
            const QString verb = action.endsWith("create") || action.endsWith("add") ? "INSERT" : action.endsWith("delete") ? "DELETE" : "UPDATE";
            QSqlQuery trigger(DatabaseManager::instance()->database());
            QVERIFY(trigger.exec("CREATE TEMP TRIGGER t32_bridge_failure BEFORE " + verb + " ON " + table + " BEGIN SELECT RAISE(ABORT, 'T32 bridge write blocked'); END"));
        }
        const int id = failure == "invalid" ? 0 : validId;
        NSString* title = failure == "invalid" ? @"" : @"新标题";
        NSError* error = nil;
        const BOOL result = action == "routine-add" ? [bridge addTitle:title categoryId:category weekdays:127 error:&error]
            : action == "routine-update" ? [bridge update:id changes:@{@"title":title} error:&error]
            : action == "routine-delete" ? [bridge deleteRoutine:id error:&error]
            : action == "routine-active" ? [bridge setActive:id active:NO error:&error]
            : [bridge setWeekdays:id weekdays:1 error:&error];
        QVERIFY(!result); QVERIFY(error != nil); QCOMPARE(failures.size(), 1);
        const QString message = failures.first().first().toString();
        QVERIFY(message.contains(QStringLiteral("失败：")));
        if (failure == "write") QVERIFY(message.contains(QStringLiteral("T32 bridge write blocked")));
        QCOMPARE(PTBridgeSupport::string(error.localizedDescription), message);
        QCOMPARE(ownerFailures, 0); QCOMPARE(observerFailures, 0); QCOMPARE(shellFailures, 0);
    }
}

// 产品保证：桥接验证只写测试偏好与临时数据库，不触及用户数据。
void PTDataBridgeTests::initTestCase() {
    QVERIFY(m_preferences.isValid());
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
    QCoreApplication::setApplicationName(QStringLiteral("PTDataBridgeTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
}
// 产品保证：每条桥接用例的空状态来自新的数据库，而非前一条的残留。
void PTDataBridgeTests::init() {
    QVERIFY(m_database.isValid());
    QFile::remove(m_database.filePath(QStringLiteral("data.sqlite")));
    QVERIFY(DatabaseManager::instance()->initialize(m_database.filePath(QStringLiteral("data.sqlite"))));
}
// 产品保证：失败路径同样解除登记和存储配置，不污染下一条用例。
void PTDataBridgeTests::cleanup() {
    PTBridgeSupport::registerService(QStringLiteral("syncController"), nullptr);
    BackupService::instance()->configure(QString(), QString());
    DatabaseManager::instance()->close();
    QSettings().clear();
    AppSettings::instance()->reload();
}
// 产品保证：空废纸篓是有效读取；数据库关闭时桥接明确返回读取失败。
void PTDataBridgeTests::trashBridgeDistinguishesEmptyAndReadFailure() {
    @autoreleasepool {
        PTTrashBridge *bridge = [PTTrashBridge new];
        auto empty = [bridge readItems]; QVERIFY(empty.valid); QCOMPARE(empty.items.count, NSUInteger(0));
        DatabaseManager::instance()->close();
        auto failed = [bridge readItems]; QVERIFY(!failed.valid); QVERIFY(failed.error.length > 0);
    }
}
// 产品保证：清空只删除确认时传入的编号，确认后新增的记录仍留在废纸篓。
void PTDataBridgeTests::trashBridgeEmptyUsesProvidedIdentifiers() {
    @autoreleasepool {
        QSqlQuery seed(DatabaseManager::instance()->database());
        const QString deleted = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
        QVERIFY(seed.prepare(QStringLiteral("INSERT INTO trash_items(kind, origin_sync_id, title, payload, deleted_at) VALUES ('memo', '', :title, '{\"v\":1}', :deleted)")));
        seed.bindValue(QStringLiteral(":title"), QStringLiteral("确认时条目")); seed.bindValue(QStringLiteral(":deleted"), deleted); QVERIFY(seed.exec());
        const int confirmedId = seed.lastInsertId().toInt();
        QVERIFY(seed.prepare(QStringLiteral("INSERT INTO trash_items(kind, origin_sync_id, title, payload, deleted_at) VALUES ('memo', '', :title, '{\"v\":1}', :deleted)")));
        seed.bindValue(QStringLiteral(":title"), QStringLiteral("确认后条目")); seed.bindValue(QStringLiteral(":deleted"), deleted); QVERIFY(seed.exec());
        const int laterId = seed.lastInsertId().toInt(); QVERIFY(confirmedId > 0 && laterId > confirmedId);
        PTTrashBridge *bridge = [PTTrashBridge new]; NSError *error = nil;
        PTTrashActionValue *result = [bridge emptyTrash:@[@(confirmedId)] error:&error];
        QVERIFY(error == nil); QVERIFY(result.ok);
        QCOMPARE(seed.exec(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE id = %1").arg(confirmedId)), true); QVERIFY(seed.next()); QCOMPARE(seed.value(0).toInt(), 0);
        QVERIFY(seed.exec(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE id = %1").arg(laterId))); QVERIFY(seed.next()); QCOMPARE(seed.value(0).toInt(), 1);
    }
}
// 产品保证：同步日志的正常空结果与数据库读取失败有不同状态，计数失败也映射为错误。
void PTDataBridgeTests::syncBridgeDistinguishesEmptyAndDatabaseFailure() {
    @autoreleasepool {
        SyncController controller(SyncController::Platform{});
        PTBridgeSupport::registerService(QStringLiteral("syncController"), &controller);
        PTSyncBridge *bridge = [PTSyncBridge new];
        auto empty = [bridge syncLog:50]; QVERIFY(empty.valid); QCOMPARE(empty.entries.count, NSUInteger(0));
        NSError *error = nil; QCOMPARE([bridge readLogCount:&error], NSInteger(0)); QVERIFY(error == nil);
        DatabaseManager::instance()->close();
        auto failed = [bridge syncLog:50]; QVERIFY(!failed.valid); QVERIFY(failed.error.length > 0);
        error = nil; [bridge readLogCount:&error]; QVERIFY(error != nil);
        PTBridgeSupport::registerService(QStringLiteral("syncController"), nullptr);
    }
}
// 产品保证：不存在的备份目录是空列表，存在但不是目录的路径报告存储错误。
void PTDataBridgeTests::backupBridgeDistinguishesMissingAndUnreadableFolder() {
    @autoreleasepool {
        auto *service = BackupService::instance();
        const QString settings = m_preferences.filePath(QStringLiteral("backup.ini"));
        const QString missing = m_preferences.filePath(QStringLiteral("not-created"));
        service->configure(settings, missing);
        PTBackupBridge *bridge = [PTBackupBridge new]; NSError *error = nil;
        NSArray *empty = [bridge readBackups:&error]; QCOMPARE(empty.count, NSUInteger(0)); QVERIFY(error == nil);
        QFile file(m_preferences.filePath(QStringLiteral("not-a-directory"))); QVERIFY(file.open(QIODevice::WriteOnly)); file.close();
        service->configure(settings, file.fileName()); error = nil;
        NSArray *failed = [bridge readBackups:&error]; QCOMPARE(failed.count, NSUInteger(0)); QVERIFY(error != nil);
        QVERIFY([error.localizedDescription containsString:@"备份文件夹"]);
        service->configure(QString(), QString());
    }
}
// 产品保证：导出文件名和例行读写由 C++ 服务决定，桥接只转发字段与掩码。
void PTDataBridgeTests::exportAndRoutineBridgeForwardServiceOperations() {
    @autoreleasepool {
        PTExportBridge *exportBridge = [PTExportBridge new];
        NSString *name = [exportBridge generateFileName:@"tasks" startDate:@"2026-10-01" endDate:@"2026-10-07"];
        QVERIFY(name.length > 0); QVERIFY([name containsString:@"2026"]);
        PTRoutineBridge *routine = [PTRoutineBridge new]; NSError *error = nil;
        QVERIFY([routine addTitle:@"桥接例行" categoryId:-1 weekdays:5 error:&error]); QVERIFY(error == nil);
        NSArray<PTRoutineValue *> *values = [routine routines]; QCOMPARE(values.count, NSUInteger(1));
        QCOMPARE(values.firstObject.weekdays, 5);
        const NSInteger routineId = values.firstObject.routineId;
        QVERIFY([routine setWeekdays:routineId weekdays:9 error:&error]);
        QCOMPARE([routine routines].firstObject.weekdays, 9);
    }
}
// 产品保证：例行字段级编辑转发整型科目，读取失败不会伪装成有效空列表。
void PTDataBridgeTests::routineBridgePreservesFieldTypesAndReadFailures() {
    @autoreleasepool {
        PTRoutineBridge *bridge = [PTRoutineBridge new]; NSError *error = nil;
        QVERIFY([bridge addTitle:@"阅读" categoryId:-1 weekdays:31 error:&error]);
        auto values = [bridge readRoutines:&error]; QVERIFY(error == nil);
        QCOMPARE(values.count, NSUInteger(1));
        const NSInteger id = values.firstObject.routineId;
        QVERIFY(([bridge update:id changes:@{@"title": @"阅读两章", @"categoryId": @(-1)} error:&error]));
        values = [bridge readRoutines:&error];
        QVERIFY([values.firstObject.title isEqualToString:@"阅读两章"]);
        QCOMPARE(values.firstObject.weekdays, 31);
        QVERIFY(![bridge update:id changes:@{@"categoryId": @(1.5)} error:&error]);
        QVERIFY(error != nil);
        DatabaseManager::instance()->close(); error = nil;
        QVERIFY([bridge readRoutines:&error] == nil); QVERIFY(error != nil);
    }
}
// 产品保证：同步控制器销毁后桥接拒绝读取，不访问悬空的登记指针。
void PTDataBridgeTests::syncBridgeSurvivesServiceDestruction() {
    @autoreleasepool {
        PTSyncBridge *bridge;
        {
            SyncController controller(SyncController::Platform{});
            PTBridgeSupport::registerService(QStringLiteral("syncController"), &controller);
            bridge = [PTSyncBridge new];
            QVERIFY([bridge syncLog:10].valid);
            QVERIFY([bridge syncLog:10].error.length == 0);
        }
        QVERIFY(![bridge syncLog:10].valid);
        NSError *error = nil; [bridge readLogCount:&error]; QVERIFY(error != nil);
        error = nil;
        QVERIFY(![bridge syncNow:&error]);
        QVERIFY([error.localizedDescription isEqualToString:@"同步服务未登记或已释放"]);
    }
}
// 产品保证：同步的每个动作在服务未登记或已释放时都能返回具体原因。
void PTDataBridgeTests::syncActionsRejectReleasedService_data()
{
    QTest::addColumn<int>("action");
    for (int action = 0; action < 6; ++action)
        QTest::newRow(qPrintable(QString::number(action))) << action;
}

// 产品保证：失效登记不能让用户动作静默成功，NSError 明确指出同步服务不可用。
void PTDataBridgeTests::syncActionsRejectReleasedService()
{
    @autoreleasepool {
        QFETCH(int, action);
        PTBridgeSupport::registerService(QStringLiteral("syncController"), nullptr);
        PTSyncBridge* bridge = [PTSyncBridge new];
        const SEL selectors[] = {@selector(setEnabled:error:), @selector(confirmJoin:), @selector(syncNow:),
            @selector(chooseFolder:), @selector(rebuildFolder:), @selector(copyLostValue:error:)};
        QVERIFY([bridge respondsToSelector:selectors[action]]);
        NSError* error = nil;
        BOOL result = YES;
        switch (action) {
        case 0: result = [bridge setEnabled:YES error:&error]; break;
        case 1: result = [bridge confirmJoin:&error]; break;
        case 2: result = [bridge syncNow:&error]; break;
        case 3: result = [bridge chooseFolder:&error]; break;
        case 4: result = [bridge rebuildFolder:&error]; break;
        case 5: result = [bridge copyLostValue:@"丢失值" error:&error]; break;
        }
        QVERIFY(!result);
        QVERIFY(error != nil);
        QVERIFY([error.localizedDescription isEqualToString:@"同步服务未登记或已释放"]);
    }
}

// 产品保证：自动备份开关只有落盘成功才算保存，内存读回不能吞掉偏好写失败。
void PTDataBridgeTests::backupBridgeDetectsPreferenceWriteFailure() {
    @autoreleasepool {
        QFile blocker(m_preferences.filePath(QStringLiteral("blocker")));
        QVERIFY(blocker.open(QIODevice::WriteOnly)); blocker.close();
        auto *service = BackupService::instance();
        service->configure(blocker.fileName() + QStringLiteral("/settings.ini"), QString());
        PTBackupBridge *bridge = [PTBackupBridge new];
        const bool previous = bridge.autoBackupEnabled;
        NSError *error = nil; [bridge setAutoBackupEnabled:!previous error:&error];
        QVERIFY(error != nil);
        QVERIFY([error.localizedDescription containsString:@"保存失败"]);
    }
}
// 产品保证：恢复失败仍交回结构化原因和状态，Swift 不因异常而丢掉冲突时间段。
void PTDataBridgeTests::trashRestoreKeepsStructuredFailure() {
    @autoreleasepool {
        PTTrashBridge *bridge = [PTTrashBridge new]; NSError *error = nil;
        PTTrashActionValue *result = [bridge restoreItem:999999 error:&error];
        QVERIFY(error == nil);
        QVERIFY(!result.ok);
        QVERIFY([result.code isEqualToString:@"gone"]);
        QVERIFY(result.error.length > 0);
    }
}
// 产品保证：批量清空编号越界时整批拒绝，不截断成另一条有效编号造成误删。
void PTDataBridgeTests::trashEmptyRejectsOverflowWithoutDeletingTruncatedId() {
    @autoreleasepool {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.prepare(QStringLiteral("INSERT INTO trash_items(kind, origin_sync_id, title, payload, deleted_at) VALUES ('memo', '', '保留', '{\"v\":1}', :deleted)")));
        query.bindValue(QStringLiteral(":deleted"), QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
        QVERIFY(query.exec()); const int id = query.lastInsertId().toInt(); QVERIFY(id > 0);
        PTTrashBridge *bridge = [PTTrashBridge new]; NSError *error = nil;
        const qint64 overflow = (qint64(1) << 32) + id;
        [bridge emptyTrash:@[@(overflow)] error:&error]; QVERIFY(error != nil);
        QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE id = %1").arg(id)));
        QVERIFY(query.next()); QCOMPARE(query.value(0).toInt(), 1);
    }
}
// 产品保证：废纸篓详情的合法零时间、缺少时间和服务恢复失败，在有类型的值对象里仍可区分。
void PTDataBridgeTests::trashTypedValuesPreserveDetailsAndFailure() {
    @autoreleasepool {
        const QVariantMap details{
            {QStringLiteral("date"), QStringLiteral("2026-10-10")}, {QStringLiteral("completed"), true},
            {QStringLiteral("estimatedMinutes"), 25}, {QStringLiteral("startTime"), QStringLiteral("2026-10-10T00:00:00")},
            {QStringLiteral("endTime"), QStringLiteral("2026-10-10T00:45:00")}, {QStringLiteral("durationSeconds"), 2700},
            {QStringLiteral("mode"), 2}, {QStringLiteral("taskTitle"), QStringLiteral("阅读 🍅")},
            {QStringLiteral("manual"), true}, {QStringLiteral("dueDate"), QStringLiteral("2026-10-11")},
            {QStringLiteral("status"), 3}, {QStringLiteral("weekdays"), 96}, {QStringLiteral("active"), true},
            {QStringLiteral("weekday"), 6}, {QStringLiteral("startMinutes"), 0}, {QStringLiteral("endMinutes"), 45},
            {QStringLiteral("weekStart"), 2}, {QStringLiteral("weekEnd"), 18}, {QStringLiteral("weekParity"), 1},
            {QStringLiteral("location"), QStringLiteral("图书馆")}, {QStringLiteral("targetDate"), QStringLiteral("2027-01-01")}};
        QVariantMap itemMap{
            {QStringLiteral("id"), 42}, {QStringLiteral("kind"), QStringLiteral("schedule_entry")},
            {QStringLiteral("title"), QStringLiteral("午夜课表")}, {QStringLiteral("deletedAt"), QStringLiteral("2026-10-10T12:00:00")},
            {QStringLiteral("deletedDate"), QStringLiteral("2026-10-10")}, {QStringLiteral("remainingDays"), 29},
            {QStringLiteral("originSyncId"), QStringLiteral("origin-42")}, {QStringLiteral("categoryName"), QStringLiteral("阅读")},
            {QStringLiteral("categoryColor"), QStringLiteral("#aabbcc")}, {QStringLiteral("restorable"), false},
            {QStringLiteral("blockedReason"), QStringLiteral("依赖已删除")}, {QStringLiteral("details"), details}};
        PTTrashItemValue *item = [[PTTrashItemValue alloc] initWithMap:itemMap];
        QCOMPARE(item.itemId, NSInteger(42)); QVERIFY([item.kind isEqualToString:@"schedule_entry"]);
        QVERIFY([item.title isEqualToString:@"午夜课表"]); QVERIFY([item.deletedAt isEqualToString:@"2026-10-10T12:00:00"]);
        QVERIFY([item.deletedDate isEqualToString:@"2026-10-10"]); QCOMPARE(item.remainingDays, NSInteger(29));
        QVERIFY([item.originSyncId isEqualToString:@"origin-42"]); QVERIFY([item.categoryName isEqualToString:@"阅读"]);
        QVERIFY([item.categoryColor isEqualToString:@"#aabbcc"]); QVERIFY(!item.restorable);
        QVERIFY([item.blockedReason isEqualToString:@"依赖已删除"]);
        PTTrashDetailsValue *value = item.details;
        QVERIFY([value.date isEqualToString:@"2026-10-10"]); QVERIFY(value.completed); QCOMPARE(value.estimatedMinutes, NSInteger(25));
        QVERIFY([value.startTime isEqualToString:@"2026-10-10T00:00:00"]); QVERIFY([value.endTime isEqualToString:@"2026-10-10T00:45:00"]);
        QCOMPARE(value.durationSeconds, NSInteger(2700)); QCOMPARE(value.mode, NSInteger(2));
        QVERIFY([value.taskTitle isEqualToString:@"阅读 🍅"]); QVERIFY(value.manual);
        QVERIFY([value.dueDate isEqualToString:@"2026-10-11"]); QCOMPARE(value.status, NSInteger(3));
        QCOMPARE(value.weekdays, NSInteger(96)); QVERIFY(value.active); QCOMPARE(value.weekday, NSInteger(6));
        QVERIFY(value.startMinutes != nil); QCOMPARE(value.startMinutes.integerValue, NSInteger(0));
        QCOMPARE(value.endMinutes.integerValue, NSInteger(45)); QCOMPARE(value.weekStart, NSInteger(2));
        QCOMPARE(value.weekEnd, NSInteger(18)); QCOMPARE(value.weekParity, NSInteger(1));
        QVERIFY([value.location isEqualToString:@"图书馆"]); QVERIFY([value.targetDate isEqualToString:@"2027-01-01"]);
        itemMap[QStringLiteral("details")] = QVariantMap{};
        PTTrashItemValue *missing = [[PTTrashItemValue alloc] initWithMap:itemMap];
        QVERIFY(missing.details.startMinutes == nil); QVERIFY(missing.details.endMinutes == nil);
        const QVariantMap failure{{QStringLiteral("ok"), false}, {QStringLiteral("title"), QStringLiteral("专注记录")},
            {QStringLiteral("error"), QStringLiteral("记录冲突")}, {QStringLiteral("code"), QStringLiteral("conflict")},
            {QStringLiteral("conflict"), QStringLiteral("focus")}};
        PTTrashActionValue *action = [[PTTrashActionValue alloc] initWithMap:failure];
        QVERIFY(!action.ok); QVERIFY([action.title isEqualToString:@"专注记录"]); QVERIFY([action.error isEqualToString:@"记录冲突"]);
        QVERIFY([action.code isEqualToString:@"conflict"]); QVERIFY([action.conflict isEqualToString:@"focus"]);
    }
}
// 产品保证：例行科目和星期、备份元信息和大文件大小、日志完整原文和复制能力均由桥接保真转换。
void PTDataBridgeTests::typedValuesPreserveRoutineBackupAndSyncFields() {
    @autoreleasepool {
        const QVariantMap routineMap{{QStringLiteral("id"), 7}, {QStringLiteral("title"), QStringLiteral("周末阅读")},
            {QStringLiteral("categoryId"), 9}, {QStringLiteral("categoryName"), QStringLiteral("文学")},
            {QStringLiteral("categoryColor"), QStringLiteral("#123456")}, {QStringLiteral("active"), true}, {QStringLiteral("weekdays"), 96}};
        PTRoutineValue *routine = [[PTRoutineValue alloc] initWithMap:routineMap];
        QCOMPARE(routine.routineId, NSInteger(7)); QVERIFY([routine.title isEqualToString:@"周末阅读"]);
        QCOMPARE(routine.categoryId, NSInteger(9)); QVERIFY([routine.categoryName isEqualToString:@"文学"]);
        QVERIFY([routine.categoryColor isEqualToString:@"#123456"]); QVERIFY(routine.active); QCOMPARE(routine.weekdays, NSInteger(96));
        const QVariantMap infoMap{{QStringLiteral("valid"), true}, {QStringLiteral("reason"), QString()},
            {QStringLiteral("created_at"), QStringLiteral("2026-10-10T14:30:00")}, {QStringLiteral("app_version"), QStringLiteral("1.5.0")},
            {QStringLiteral("taskCount"), 123}, {QStringLiteral("sessionCount"), 456}};
        PTBackupInfoValue *info = [[PTBackupInfoValue alloc] initWithMap:infoMap];
        QVERIFY(info.valid); QCOMPARE(info.reason.length, NSUInteger(0));
        QVERIFY([info.createdAt isEqualToString:@"2026-10-10T14:30:00"]); QVERIFY([info.appVersion isEqualToString:@"1.5.0"]);
        QCOMPARE(info.taskCount, NSInteger(123)); QCOMPARE(info.sessionCount, NSInteger(456));
        const qint64 wideValue = (qint64(1) << 53) + 123;
        const QVariantMap entryMap{{QStringLiteral("path"), QStringLiteral("/backup/原始.tomatobackup")},
            {QStringLiteral("name"), QStringLiteral("原始.tomatobackup")}, {QStringLiteral("modified"), QStringLiteral("2026-10-10T15:00:00")},
            {QStringLiteral("sizeBytes"), wideValue}};
        PTBackupEntryValue *entry = [[PTBackupEntryValue alloc] initWithMap:entryMap];
        QVERIFY([entry.path isEqualToString:@"/backup/原始.tomatobackup"]); QVERIFY([entry.name isEqualToString:@"原始.tomatobackup"]);
        QVERIFY([entry.modified isEqualToString:@"2026-10-10T15:00:00"]); QCOMPARE(entry.sizeBytes, wideValue);
        QVariantMap logMap{{QStringLiteral("id"), wideValue}, {QStringLiteral("kind"), QStringLiteral("edit")},
            {QStringLiteral("kindLabel"), QStringLiteral("修改冲突")}, {QStringLiteral("time"), QStringLiteral("今天 15:00")},
            {QStringLiteral("title"), QStringLiteral("备忘录标题")}, {QStringLiteral("summary"), QStringLiteral("截断摘要…")},
            {QStringLiteral("detail"), QStringLiteral("同步详情")}, {QStringLiteral("fieldLabel"), QStringLiteral("正文")},
            {QStringLiteral("lostValue"), QStringLiteral("  第一行\n🍅\n")}, {QStringLiteral("keptValue"), QStringLiteral("新版")},
            {QStringLiteral("canCopyLostValue"), true}};
        PTSyncLogValue *log = [[PTSyncLogValue alloc] initWithMap:logMap];
        QCOMPARE(log.entryId, wideValue); QVERIFY([log.kind isEqualToString:@"edit"]); QVERIFY([log.kindLabel isEqualToString:@"修改冲突"]);
        QVERIFY([log.time isEqualToString:@"今天 15:00"]); QVERIFY([log.title isEqualToString:@"备忘录标题"]);
        QVERIFY([log.summary isEqualToString:@"截断摘要…"]); QVERIFY([log.detail isEqualToString:@"同步详情"]);
        QVERIFY([log.fieldLabel isEqualToString:@"正文"]); QVERIFY([log.lostValue isEqualToString:@"  第一行\n🍅\n"]);
        QVERIFY([log.keptValue isEqualToString:@"新版"]); QVERIFY(log.canCopyLostValue);
        logMap[QStringLiteral("canCopyLostValue")] = false;
        PTSyncLogValue *blocked = [[PTSyncLogValue alloc] initWithMap:logMap];
        QVERIFY(blocked.lostValue.length > 0); QVERIFY(!blocked.canCopyLostValue);
    }
}
QTEST_GUILESS_MAIN(PTDataBridgeTests)
#include "PTDataBridgeTests.moc"
