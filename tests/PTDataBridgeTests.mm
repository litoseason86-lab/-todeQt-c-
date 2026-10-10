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

class PTDataBridgeTests : public QObject {
    Q_OBJECT
private slots:
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
private:
    QTemporaryDir m_preferences;
    QTemporaryDir m_database;
};
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
        NSDictionary *result = [bridge emptyTrash:@[@(confirmedId)] error:&error];
        QVERIFY(error == nil); QVERIFY([result[@"ok"] boolValue]);
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
        NSArray<NSDictionary *> *values = [routine routines]; QCOMPARE(values.count, NSUInteger(1));
        QCOMPARE([values.firstObject[@"weekdays"] integerValue], 5);
        const NSInteger routineId = [values.firstObject[@"id"] integerValue];
        QVERIFY([routine setWeekdays:routineId weekdays:9 error:&error]);
        QCOMPARE([[routine routines].firstObject[@"weekdays"] integerValue], 9);
    }
}
// 产品保证：例行字段级编辑转发整型科目，读取失败不会伪装成有效空列表。
void PTDataBridgeTests::routineBridgePreservesFieldTypesAndReadFailures() {
    @autoreleasepool {
        PTRoutineBridge *bridge = [PTRoutineBridge new]; NSError *error = nil;
        QVERIFY([bridge addTitle:@"阅读" categoryId:-1 weekdays:31 error:&error]);
        auto values = [bridge readRoutines:&error]; QVERIFY(error == nil);
        QCOMPARE(values.count, NSUInteger(1));
        const NSInteger id = [values.firstObject[@"id"] integerValue];
        QVERIFY(([bridge update:id changes:@{@"title": @"阅读两章", @"categoryId": @(-1)} error:&error]));
        values = [bridge readRoutines:&error];
        QVERIFY([values.firstObject[@"title"] isEqualToString:@"阅读两章"]);
        QCOMPARE([values.firstObject[@"weekdays"] integerValue], 31);
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
        [bridge syncNow];
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
        const NSDictionary *result = [bridge restoreItem:999999 error:&error];
        QVERIFY(error == nil);
        QVERIFY(![result[@"ok"] boolValue]);
        QVERIFY([result[@"code"] isEqualToString:@"gone"]);
        QVERIFY([result[@"error"] length] > 0);
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
QTEST_GUILESS_MAIN(PTDataBridgeTests)
#include "PTDataBridgeTests.moc"
