#include <QDir>
#include <QProcess>
#include <QFutureWatcher>
#include <QSemaphore>
#include <QThread>
#include <cstdio>
#include <cstring>
#include <utility>
#include "../src/services/BackupSqliteDriver.h"
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QSignalSpy>
#include <QScopeGuard>
#include <QSqlError>
#include <QSqlQuery>
#include <QDataStream>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>
#include <sqlite3.h>

#include "../src/services/AppSettings.h"
#include "../src/services/BackupOperations.h"
#include "../src/services/BackupService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/SyncController.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/TaskManager.h"

namespace {

int insertTask(const QString& title)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed) VALUES (:title, :date, 0)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), QDate::currentDate().toString(Qt::ISODate));
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

bool insertFocusSession(int taskId, int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (:taskId, :start, :end, :duration, 1, 1)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":start"), QStringLiteral("2026-07-20T10:00:00"));
    query.bindValue(QStringLiteral(":end"), QStringLiteral("2026-07-20T10:25:00"));
    query.bindValue(QStringLiteral(":duration"), duration);
    return query.exec();
}

bool ensureCountdownTable()
{
    // countdown_goals 由 CountdownService 惰性建表；测试未链接该服务，手动建同构表以模拟。
    QSqlQuery query(DatabaseManager::instance()->database());
    return query.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS countdown_goals ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, target_date TEXT NOT NULL, "
        "display_order INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)"));
}

bool insertCountdownGoal(const QString& name)
{
    if (!ensureCountdownTable()) {
        return false;
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES (:name, :date, 1, :now, :now)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":date"), QStringLiteral("2026-12-01"));
    query.bindValue(QStringLiteral(":now"), QStringLiteral("2026-07-20T08:00:00"));
    return query.exec();
}

int scalarCount(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(sql) || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

void setBackupSchemaVersion(const QString& path, int version)
{
    const QString conn = QStringLiteral("TweakBackupConn");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
        db.setDatabaseName(path);
        QVERIFY(db.open());
        QSqlQuery q(db);
        q.exec(QStringLiteral("PRAGMA user_version = %1").arg(version));
        q.prepare(QStringLiteral("UPDATE backup_meta SET value = :v WHERE key = 'schema_version'"));
        q.bindValue(QStringLiteral(":v"), QString::number(version));
        q.exec();
        db.close();
    }
    QSqlDatabase::removeDatabase(conn);
}

void setBackupMetaValue(const QString& path, const QString& key, const QString& value)
{
    const QString connectionName =
        QStringLiteral("TweakBackupMeta_") + QUuid::createUuid().toString(QUuid::WithoutBraces);
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(path);
        QVERIFY(database.open());
        QSqlQuery query(database);
        query.prepare(QStringLiteral(
            "INSERT OR REPLACE INTO backup_meta (key, value) VALUES (:key, :value)"));
        query.bindValue(QStringLiteral(":key"), key);
        query.bindValue(QStringLiteral(":value"), value);
        QVERIFY(query.exec());
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
}

} // namespace

class BackupServiceTests : public QObject
{
    Q_OBJECT

public:
    static int shutdownProbe();
private slots:
    void copyCancellationAtCommitBoundaries_data();
    void copyCancellationAtCommitBoundaries();
    void sqlProgressAndBusyObserveCancellation_data();
    void sqlProgressAndBusyObserveCancellation();
    void restoreCancellationAtInstallBoundaries_data();
    void restoreCancellationAtInstallBoundaries();
    void shutdownDuringInstalledRestorePreservesJournal();
    void cooperativeShutdownExitsWholeProcess();
    void queuedBackupResultStillObservesCancellation();
    void cancelledAutomaticBackupKeepsRetentionAndSchedule();
    void asyncExpiredRestoreKeepsOriginalDatabase_data();
    void asyncExpiredRestoreKeepsOriginalDatabase();
    void synchronousBackupCannotReplaceActiveOperation();
    void restoreAdmissionPrecedesReentrantCallbacks_data();
    void restoreAdmissionPrecedesReentrantCallbacks();
    void synchronousSnapshotsReserveTheirOperation_data();
    void synchronousSnapshotsReserveTheirOperation();
    void completionNotificationsPreserveReentrantOperation_data();
    void completionNotificationsPreserveReentrantOperation();
    void asyncCancellationDoesNotPublishSuccess();
    void asyncRestoreCancellationPreservesOriginalData();
    void cancellationBeforeWorkPreservesFiles();
    void elapsedBudgetRejectsSnapshotAndInspection();
    void init();
    void cleanup();

    void readBackupsSeparatesNoneFromUnreadableFolder();
    void createBackupProducesSingleFileNoTemp();
    void backupRejectsRuntimeProtectedDestinations();
    void backupCapturesAllBusinessTables();
    void backupWorksUnderWalMode();
    void restoreRestoresIndependentPomodoroCycle();
    void backupConnectionClosePreservesMainWriteLock_data();
    void backupConnectionClosePreservesMainWriteLock();
    void oversizedBackupIsRejectedBeforeRestore_data();
    void oversizedBackupIsRejectedBeforeRestore();
    void boundedCopyPreservesDestinationAndAcceptsExactLimit();
    void backupResourceShapeIsRejected_data();
    void backupResourceShapeIsRejected();
    void backupAcceptsCellExactlyAtBudget();
    void backupPublicationRejectsUnrestorableLargeField();
    void corruptedBackupIsRejected();
    void backupMissingRequiredTableIsRejected();
    void backupMissingRequiredColumnIsRejected();
    void version13BackupMissingScheduleTableIsRejected();
    void version13BackupMissingScheduleConstraintIsRejected();
    void version13BackupInvalidPrimaryKeyIsRejected();
    void version14BackupMissingKnowledgeGapTableIsRejected();
    void version14BackupWithCascadingKnowledgeGapForeignKeyIsRejected();
    void version14BackupWithCompositeKnowledgeGapForeignKeyIsRejected();
    void olderBackupWithoutKnowledgeGapTableIsAccepted();
    void version20BackupBrokenMemoSchemaIsRejected_data();
    void version20BackupBrokenMemoSchemaIsRejected();
    void version19BackupWithoutMemosRestoresAndMigrates();
    void version20BackupRestoresAllMemoFields();
    void version20BackupWithoutTrashRestoresIntoEmptyTrash();
    void version21BackupKeepsTrashItems();
    void version21BackupWithTrashSyncTriggersIsAcceptedAndRestored();
    void version21BackupBrokenTrashSchemaIsRejected_data();
    void version21BackupBrokenTrashSchemaIsRejected();
    void higherSchemaVersionIsRejected();
    void formatVersionMismatchIsRejected();
    void schemaMetadataMismatchIsRejected();
    void restoreCreatesPreRestoreSnapshot();
    void restoreDropsForeignSettingKeysAndKeepsShortcutOverrides();
    void backupEmbedsOnlyOwnedSettingKeys();
    void qt69BackupRestoresWithCurrentRuntime_data();
    void qt69BackupRestoresWithCurrentRuntime();
    void settingsScalarEncodingRemainsCompatible_data();
    void settingsScalarEncodingRemainsCompatible();
    void settingsSnapshotSkipsForeignKeysAndApplyLeavesThemAlone();
    void nativeSettingsDoNotFallBackToGlobalDomain();
    void restoreRefusesOversizedSettingValue();
    void asyncRestoreRejectsUnsafeSettings_data();
    void asyncRestoreRejectsUnsafeSettings();
    void commentedVirtualTableIsRejected();
    void restoreRefusesBackupCarryingTriggers();
    void restoreReplacesSyncTriggersWithTheAppsOwn();
    void repeatedRestoresCapPreRestoreSnapshots();
    void newPreRestoreSnapshotSurvivesOlderSnapshotsWithFutureTimes();
    void failedAsyncPreflightKeepsAllPreRestoreSnapshots_data();
    void failedAsyncPreflightKeepsAllPreRestoreSnapshots();
    void restoreMatchesTaskAndSessionCounts();
    void restoreUsesValidatedBytesWhenSourcePathChanges();
    void restorePreservesCountdownGoals();
    void restoreRestoresSettingsValue();
    void restoreKeepsMcpPolicy_data();
    void restoreKeepsMcpPolicy();
    void restoreRemovesSettingsMissingFromBackup();
    void restoreBringsBackDailyGoalHistorySnapshot();
    void restoreOldBackupWithoutGoalHistoryImportsLegacyDateOnly();
    void restoreFailureKeepsOriginalDatabaseIntact();
    void activeTimerBlocksRestore();
    void asyncRestoreReloadsTaskSnapshots();
    void asyncRestoreRollbackReopensDatabaseWhenCopyFails();
    void asyncRestoreRollbackRestoresOriginalTaskCount();
    void olderSchemaBackupRestoresAndMigrates();
    void autoBackupRespectsIntervalAndRetention();
    void autoBackupDisabledDoesNothing();
    void beforeSyncBackupHasItsOwnQuotaAndYieldsToOtherJobs();
    void shutdownWaitsForAsyncWorkers();
    void restoreRejectsWhenPreparationCallbackFails();
    void restoreSucceedsWhenNoPreparationCallbackRegistered();
    void restoreSyncCompletedSignalSemanticsAndBranchCoverage();

private:
    QString dbPath() const { return m_tempDir->filePath(QStringLiteral("pomodoro.db")); }
    QString settingsPath() const { return m_tempDir->filePath(QStringLiteral("settings.ini")); }
    QString backupsDir() const { return m_tempDir->filePath(QStringLiteral("backups")); }
    QString backupFile() const { return m_tempDir->filePath(QStringLiteral("manual.tomatobackup")); }

    QTemporaryDir* m_tempDir = nullptr;
};

void BackupServiceTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(dbPath()));
    BackupService::instance()->configure(settingsPath(), backupsDir());
}

void BackupServiceTests::cleanup()
{
    BackupService::instance()->m_nextOperationForTest.reset();
    BackupService::instance()->m_operation.reset();
    BackupService::instance()->m_afterRestoreValidationHookForTest = {};
    BackupService::instance()->m_shutdownPrepared = false;
    BackupService::instance()->setRestorePreparationCallback(nullptr);
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

// 产品保证：检查信息及两种恢复入口都拒绝超限备份，不把体积检查遗漏在某个入口。
void BackupServiceTests::oversizedBackupIsRejectedBeforeRestore_data()
{
    QTest::addColumn<QString>("entry");
    QTest::newRow("inspect") << QStringLiteral("inspect");
    QTest::newRow("sync") << QStringLiteral("sync");
    QTest::newRow("async") << QStringLiteral("async");
}

// 产品保证：超限文件即使包含有效SQLite数据，也不会覆盖当前任务、偏好或消耗恢复点。
void BackupServiceTests::oversizedBackupIsRejectedBeforeRestore()
{
    QFETCH(QString, entry);
    QVERIFY(insertTask(QStringLiteral("备份任务")) > 0);
    QSettings settings(settingsPath(), QSettings::IniFormat);
    settings.setValue(QStringLiteral("timer/workDuration"), 25);
    settings.sync();
    auto* backup = BackupService::instance();
    QVERIFY(backup->createBackup(backupFile()));
    QVERIFY(backup->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool());
    QVERIFY(insertTask(QStringLiteral("恢复前保留任务")) > 0);
    settings.setValue(QStringLiteral("timer/workDuration"), 40);
    settings.sync();
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    const auto snapshots = QDir(backupsDir()).entryList(QStringList{QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files);
    {
        // 稀疏填充不分配同等物理磁盘；SQLite允许尾随零，因此失败不能被无效格式掩盖。
        QFile file(backupFile());
        QVERIFY(file.open(QIODevice::ReadWrite));
        QVERIFY(file.resize(BackupOperations::kMaxBackupFileBytes + 1));
        QVERIFY(file.size() > BackupOperations::kMaxBackupFileBytes);
    }
    QString reason;
    if (entry == QStringLiteral("inspect")) {
        const auto info = backup->readBackupInfo(backupFile());
        QVERIFY(!info.value(QStringLiteral("valid")).toBool());
        reason = info.value(QStringLiteral("reason")).toString();
    } else {
        QSignalSpy completed(backup, &BackupService::restoreCompleted);
        if (entry == QStringLiteral("sync")) {
            QVERIFY(!backup->restoreBackup(backupFile()));
        } else {
            backup->requestRestore(backupFile());
            QTRY_COMPARE_WITH_TIMEOUT(completed.count(), 1, 15000);
        }
        QCOMPARE(completed.count(), 1);
        QVERIFY(!completed.first().at(0).toBool());
        reason = completed.first().at(1).toString();
    }
    QVERIFY2(reason.contains(QStringLiteral("预算")), qPrintable(reason));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    settings.sync();
    QCOMPARE(settings.value(QStringLiteral("timer/workDuration")).toInt(), 40);
    QCOMPARE(QDir(backupsDir()).entryList(QStringList{QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files), snapshots);
    QVERIFY(QDir(backupsDir()).entryList(QStringList{QStringLiteral(".restore-staging-*")}, QDir::Files | QDir::Hidden).isEmpty());
}

// 产品保证：有界复制失败保留旧目标，恰好达到边界的文件仍能完整原子替换。
void BackupServiceTests::boundedCopyPreservesDestinationAndAcceptsExactLimit()
{
    const QString sourcePath = m_tempDir->filePath(QStringLiteral("copy-source"));
    const QString destinationPath = m_tempDir->filePath(QStringLiteral("copy-target"));
    {
        QFile source(sourcePath);
        QVERIFY(source.open(QIODevice::WriteOnly));
        QCOMPARE(source.write("123456789"), qint64(9));
        QFile target(destinationPath);
        QVERIFY(target.open(QIODevice::WriteOnly));
        QCOMPARE(target.write("原有内容"), qint64(12));
    }
    const auto rejected = BackupOperations::atomicCopy(sourcePath, destinationPath, 8);
    QVERIFY(!rejected.success);
    QVERIFY(rejected.error.contains(QStringLiteral("预算")));
    {
        QFile target(destinationPath);
        QVERIFY(target.open(QIODevice::ReadOnly));
        QCOMPARE(target.readAll(), QByteArray("原有内容"));
    }
    QVERIFY(BackupOperations::atomicCopy(sourcePath, destinationPath, 9).success);
    QFile target(destinationPath);
    QVERIFY(target.open(QIODevice::ReadOnly));
    QCOMPARE(target.readAll(), QByteArray("123456789"));
}

// 产品保证：预算覆盖跨表总行数、文本真实字节及BLOB，生成表达式不会作为普通数据执行。
void BackupServiceTests::backupResourceShapeIsRejected_data()
{
    QTest::addColumn<QString>("kind");
    for (const char* kind : {"rows", "text", "blob", "generated"}) {
        QTest::newRow(kind) << QString::fromLatin1(kind);
    }
}

// 产品保证：小于文件体积上限的合法SQLite仍须满足内部数据规模约束。
void BackupServiceTests::backupResourceShapeIsRejected()
{
    QFETCH(QString, kind);
    QVERIFY(insertTask(QStringLiteral("有效备份任务")) > 0);
    auto* backup = BackupService::instance();
    QVERIFY(backup->createBackup(backupFile()));
    QVERIFY(backup->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool());
    const QString connection = QStringLiteral("ResourceShape_") + QUuid::createUuid().toString();
    const auto removeConnection = qScopeGuard([&] { QSqlDatabase::removeDatabase(connection); });
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery q(db);
        if (kind == QStringLiteral("rows")) {
            // 每张额外表单独未超限，合计超过上限；引号表名防止检查器拼SQL时漏转义。
            QVERIFY(q.exec(QStringLiteral("CREATE TABLE \"audit\"\"rows\"(n INTEGER)")));
            QVERIFY(q.exec(QStringLiteral("CREATE TABLE extra_rows(n INTEGER)")));
            const qint64 half = BackupOperations::kMaxBackupRows / 2 + 1;
            const QString fill = QStringLiteral("WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM rows WHERE n<%1) INSERT INTO %2 SELECT n FROM rows");
            QVERIFY(q.exec(fill.arg(half).arg(QStringLiteral("\"audit\"\"rows\""))));
            QVERIFY(q.exec(fill.arg(half).arg(QStringLiteral("extra_rows"))));
            QVERIFY(q.exec(QStringLiteral("SELECT (SELECT count(*) FROM \"audit\"\"rows\") + (SELECT count(*) FROM extra_rows)")) && q.next());
            QVERIFY(q.value(0).toLongLong() > BackupOperations::kMaxBackupRows);
        } else if (kind == QStringLiteral("generated")) {
            QVERIFY(q.exec(QStringLiteral("CREATE TABLE extra_generated(n INTEGER, computed INTEGER GENERATED ALWAYS AS (n+1) VIRTUAL)")));
            QVERIFY(q.exec(QStringLiteral("INSERT INTO extra_generated(n) VALUES(1)")));
        } else {
            const QString expression = QStringLiteral("zeroblob(%1)").arg(BackupOperations::kMaxBackupCellBytes + 1);
            if (kind == QStringLiteral("text")) {
                QVERIFY(q.exec(QStringLiteral("UPDATE tasks SET notes=CAST(%1 AS TEXT)").arg(expression)));
                // length(TEXT)遇NUL返回0，按字符计数的错误预算检查会被此数据绕过。
                QVERIFY(q.exec(QStringLiteral("SELECT length(notes), length(CAST(notes AS BLOB)) FROM tasks")) && q.next());
                QCOMPARE(q.value(0).toLongLong(), qint64(0));
                QVERIFY(q.value(1).toLongLong() > BackupOperations::kMaxBackupCellBytes);
            } else {
                QVERIFY(q.exec(QStringLiteral("CREATE TABLE \"extra\"\"field\"(\"value\"\"bytes\" BLOB)")));
                QVERIFY(q.exec(QStringLiteral("INSERT INTO \"extra\"\"field\" VALUES(%1)").arg(expression)));
            }
        }
        db.close();
    }
    QVERIFY(QFileInfo(backupFile()).size() < BackupOperations::kMaxBackupFileBytes);
    const auto info = backup->readBackupInfo(backupFile());
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    const QString reason = info.value(QStringLiteral("reason")).toString();
    QVERIFY2(reason.contains(kind == QStringLiteral("generated") ? QStringLiteral("生成列") : QStringLiteral("预算")), qPrintable(reason));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

// 产品保证：恰好达到字段字节上限的备份仍可检查，不能把包含NUL的文本误判为无数据。
void BackupServiceTests::backupAcceptsCellExactlyAtBudget()
{
    QVERIFY(insertTask(QStringLiteral("边界任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("ResourceBoundary_") + QUuid::createUuid().toString();
    const auto removeConnection = qScopeGuard([&] { QSqlDatabase::removeDatabase(connection); });
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery q(db);
        QVERIFY(q.exec(QStringLiteral("UPDATE tasks SET notes=CAST(zeroblob(%1) AS TEXT)").arg(BackupOperations::kMaxBackupCellBytes)));
        db.close();
    }
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
}

// 产品保证：不能成功发布本版本无法恢复的超限快照，失败保留上一次可恢复的文件。
void BackupServiceTests::backupPublicationRejectsUnrestorableLargeField()
{
    QVERIFY(insertTask(QStringLiteral("原有备份任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QByteArray original;
    {
        QFile file(backupFile());
        QVERIFY(file.open(QIODevice::ReadOnly));
        original = file.readAll();
    }
    QVERIFY(!original.isEmpty());
    QSqlQuery q(DatabaseManager::instance()->database());
    QVERIFY(q.exec(QStringLiteral("UPDATE tasks SET notes=CAST(zeroblob(%1) AS TEXT)").arg(BackupOperations::kMaxBackupCellBytes + 1)));
    q.finish();
    QVERIFY(!BackupService::instance()->createBackup(backupFile()));
    QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("预算")));
    QFile file(backupFile());
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), original);
}

void BackupServiceTests::createBackupProducesSingleFileNoTemp()
{
    QVERIFY(insertTask(QStringLiteral("备份任务")) > 0);

    QSignalSpy spy(BackupService::instance(), &BackupService::backupCompleted);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(QFileInfo::exists(backupFile()));
    // 不留半成品临时文件。
    QVERIFY(!QFileInfo::exists(backupFile() + QStringLiteral(".tmp")));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toBool(), true);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), true);
    QCOMPARE(info.value(QStringLiteral("schemaVersion")).toInt(), DatabaseManager::kCurrentSchemaVersion);
}

void BackupServiceTests::backupRejectsRuntimeProtectedDestinations()
{
    QVERIFY(insertTask(QStringLiteral("受保护目标任务")) > 0);

    // settings.ini 尚不存在也必须被保护；路径中的不存在目录和 .. 只是在制造别名，
    // 不能让调用方借此把快照写到应用运行时会使用的位置。
    QVERIFY(!QFileInfo::exists(settingsPath()));
    const QString aliasedSettingsPath = QDir(m_tempDir->path()).filePath(
        QStringLiteral("not-created/../settings.ini"));
    QVERIFY(!BackupService::instance()->createBackup(aliasedSettingsPath));
    QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("设置文件")));
    QVERIFY(!QFileInfo::exists(settingsPath()));

    const QString aliasedDatabasePath = QDir(m_tempDir->path()).filePath(
        QStringLiteral("not-created/../pomodoro.db"));
    QVERIFY(!BackupService::instance()->createBackup(aliasedDatabasePath));
    QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("数据库")));
    QVERIFY(!BackupService::instance()->createBackup(dbPath() + QStringLiteral("-wal")));
    QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("受保护")));
    QVERIFY(!BackupService::instance()->createBackup(dbPath() + QStringLiteral(".sync-disabled")));
    QVERIFY(BackupService::instance()->lastError().contains(QStringLiteral("受保护")));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

void BackupServiceTests::backupCapturesAllBusinessTables()
{
    const int taskId = insertTask(QStringLiteral("含记录任务"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSession(taskId, 1500));
    QVERIFY(insertCountdownGoal(QStringLiteral("考研倒计时")));

    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 打开备份文件，确认关键业务表都在且数据被带上。
    const QString conn = QStringLiteral("VerifyBackupTables");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        const QStringList expected = {
            QStringLiteral("tasks"), QStringLiteral("categories"), QStringLiteral("routines"),
            QStringLiteral("focus_sessions"), QStringLiteral("countdown_goals"), QStringLiteral("memos")
        };
        for (const QString& table : expected) {
            QSqlQuery q(db);
            q.prepare(QStringLiteral("SELECT 1 FROM sqlite_master WHERE type='table' AND name=:n"));
            q.bindValue(QStringLiteral(":n"), table);
            QVERIFY2(q.exec() && q.next(), qPrintable(QStringLiteral("缺表 ") + table));
        }
        QSqlQuery counts(db);
        QVERIFY(counts.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")) && counts.next());
        QCOMPARE(counts.value(0).toInt(), 1);
        QVERIFY(counts.exec(QStringLiteral("SELECT COUNT(*) FROM countdown_goals")) && counts.next());
        QCOMPARE(counts.value(0).toInt(), 1);
        db.close();
    }
    QSqlDatabase::removeDatabase(conn);
}

void BackupServiceTests::backupWorksUnderWalMode()
{
    // 即便源库处于 WAL 模式，VACUUM INTO 也应产出包含已提交数据的完整快照。
    {
        QSqlQuery pragma(DatabaseManager::instance()->database());
        QVERIFY(pragma.exec(QStringLiteral("PRAGMA journal_mode = WAL")));
    }
    QVERIFY(insertTask(QStringLiteral("WAL 任务")) > 0);

    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), true);
    QCOMPARE(info.value(QStringLiteral("taskCount")).toInt(), 1);
}

void BackupServiceTests::restoreRestoresIndependentPomodoroCycle()
{
    // 恢复整库备份必须恢复备份时的循环计数，不能继承当前库或内存中的另一轮计数。
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("UPDATE pomodoro_cycle_state SET completed_pomodoros=2")));
    }
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 2);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("UPDATE pomodoro_cycle_state SET completed_pomodoros=5")));
    }
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 5);
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 2);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT completed_pomodoros FROM pomodoro_cycle_state")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 2);
}

void BackupServiceTests::corruptedBackupIsRejected()
{
    const QString garbage = m_tempDir->filePath(QStringLiteral("garbage.tomatobackup"));
    QFile file(garbage);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("this is definitely not a sqlite database");
    file.close();

    const QVariantMap info = BackupService::instance()->readBackupInfo(garbage);
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);

    QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
    QVERIFY(!BackupService::instance()->restoreBackup(garbage));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toBool(), false);
}

void BackupServiceTests::backupMissingRequiredTableIsRejected()
{
    // 构造一个合法 SQLite 但缺少 tasks 表的文件。
    const QString path = m_tempDir->filePath(QStringLiteral("notasks.tomatobackup"));
    const QString conn = QStringLiteral("MissingTableConn");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
        db.setDatabaseName(path);
        QVERIFY(db.open());
        QSqlQuery q(db);
        QVERIFY(q.exec(QStringLiteral("CREATE TABLE categories (id INTEGER PRIMARY KEY)")));
        db.close();
    }
    QSqlDatabase::removeDatabase(conn);

    const QVariantMap info = BackupService::instance()->readBackupInfo(path);
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(!BackupService::instance()->restoreBackup(path));
}

void BackupServiceTests::backupMissingRequiredColumnIsRejected()
{
    QVERIFY(insertTask(QStringLiteral("结构校验任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 表名和 user_version 都保持合法，只删除所有版本都依赖的基础列。
    // CREATE TABLE IF NOT EXISTS 不会修复这种残缺表，若检查阶段放行，恢复会显示成功，
    // 之后每一次任务查询才因缺少 title 失败。
    const QString connectionName = QStringLiteral("MissingRequiredColumn");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        // 同步触发器引用着 title，SQLite 会因此拒绝删列。它们挂在 tasks 上，本用例只关心缺列，先拆掉。
        QVERIFY2(query.exec(QStringLiteral("DROP TRIGGER tasks_sync_ai")), qPrintable(query.lastError().text()));
        QVERIFY2(query.exec(QStringLiteral("DROP TRIGGER tasks_sync_au")), qPrintable(query.lastError().text()));
        QVERIFY2(query.exec(QStringLiteral("DROP TRIGGER tasks_sync_ad")), qPrintable(query.lastError().text()));
        QVERIFY2(query.exec(QStringLiteral("ALTER TABLE tasks DROP COLUMN title")),
                 qPrintable(query.lastError().text()));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY2(info.value(QStringLiteral("reason")).toString().contains(
                 QStringLiteral("tasks.title")),
             qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version13BackupMissingScheduleTableIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("MissingScheduleTable");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("DROP TABLE schedule_entries")));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(
        QStringLiteral("schedule_entries")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version13BackupInvalidPrimaryKeyIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connectionName = QStringLiteral("InvalidScheduleId");
    {
        auto database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("SELECT sql FROM sqlite_master WHERE name='schedule_entries'")));
        QVERIFY(query.next());
        QString sql = query.value(0).toString();
        query.finish();
        sql.replace(QStringLiteral("INTEGER PRIMARY KEY AUTOINCREMENT"), QStringLiteral("INT PRIMARY KEY"));
        QVERIFY(query.exec(QStringLiteral("DROP TABLE schedule_entries")));
        QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("主键")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version13BackupMissingScheduleConstraintIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("MissingScheduleConstraint");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("ALTER TABLE schedule_periods RENAME TO old_periods")));
        QVERIFY(query.exec(QStringLiteral(
            "CREATE TABLE schedule_periods ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, period_index INTEGER NOT NULL UNIQUE, "
            "start_minutes INTEGER NOT NULL, end_minutes INTEGER NOT NULL)")));
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO schedule_periods SELECT * FROM old_periods")));
        QVERIFY(query.exec(QStringLiteral("DROP TABLE old_periods")));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(
        QStringLiteral("约束")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version14BackupMissingKnowledgeGapTableIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("MissingKnowledgeGapTable");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    // v14 及以后的备份必须带着这张表。缺了就放行的话，恢复会建出一张空表并报成功，
    // 用户手写的全部知识缺口就这么无声消失了——而那些内容不可再生。
    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY2(info.value(QStringLiteral("reason")).toString().contains(
                 QStringLiteral("knowledge_gaps")),
             qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version14BackupWithCascadingKnowledgeGapForeignKeyIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("CascadingKnowledgeGapForeignKey");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
        QVERIFY(query.next());
        QString sql = query.value(0).toString();
        query.finish();
        const QString setNull =
            QStringLiteral("linked_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
        QVERIFY(sql.contains(setNull));
        sql.replace(setNull,
                    QStringLiteral("linked_task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE"));
        QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
        QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    // 列和 CHECK 都在，只有删除动作不对：这样的备份恢复后能正常启动、正常使用，
    // 直到某天删掉一条任务，关联它的知识缺口被连带删除。必须在恢复之前挡下。
    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY2(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("外键")),
             qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::version14BackupWithCompositeKnowledgeGapForeignKeyIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("CompositeKnowledgeGapForeignKey");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
        QVERIFY(query.next());
        QString sql = query.value(0).toString();
        query.finish();
        const QString sourceColumn =
            QStringLiteral("source_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
        const QString linkedColumn =
            QStringLiteral("linked_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
        QVERIFY(sql.contains(sourceColumn));
        QVERIFY(sql.contains(linkedColumn));
        sql.replace(sourceColumn, QStringLiteral("source_task_id INTEGER"));
        sql.replace(linkedColumn, QStringLiteral("linked_task_id INTEGER"));
        const qsizetype closingParen = sql.lastIndexOf(QLatin1Char(')'));
        QVERIFY(closingParen > 0);
        sql.insert(closingParen,
                   QStringLiteral(", FOREIGN KEY (source_task_id, linked_task_id) "
                                  "REFERENCES tasks(id, id) ON DELETE SET NULL\n        "));
        QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
        QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    // 外部改过的备份不会只坏成一种样子。这一份逐行看外键完全合规，合起来却是一条复合约束：
    // 恢复之后能正常启动，但知识缺口一条也存不进去（tasks 上没有 (id, id) 复合唯一索引，
    // SQLite 直接报 foreign key mismatch）。恢复之前就得挡下来。
    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY2(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("外键")),
             qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::olderBackupWithoutKnowledgeGapTableIsAccepted()
{
    QVERIFY(insertTask(QStringLiteral("旧备份里的任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("LegacyWithoutKnowledgeGaps");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    // 降回 v13：这正是升级前做的那些备份的样子。
    setBackupSchemaVersion(backupFile(), 13);

    // 新增表的必要性必须按备份自己的 schema 版本判断。把它无条件加进所有版本的
    // 必需表清单，会让用户升级前做的每一个备份都被判成损坏，再也恢复不回来。
    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(),
             qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    // 恢复之后由迁移链把缺的表补齐，用户的旧任务照常还在。
    QSqlQuery check(DatabaseManager::instance()->database());
    QVERIFY(check.exec(QStringLiteral(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
    QVERIFY(check.next());
    check.finish();
    QVERIFY(check.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '旧备份里的任务'")));
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toInt(), 1);
}

void BackupServiceTests::higherSchemaVersionIsRejected()
{
    QVERIFY(insertTask(QStringLiteral("未来任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    // 把备份伪造成更高 schema 版本。
    setBackupSchemaVersion(backupFile(), DatabaseManager::kCurrentSchemaVersion + 5);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("更高版本")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
}

void BackupServiceTests::formatVersionMismatchIsRejected()
{
    QVERIFY(insertTask(QStringLiteral("格式校验任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    setBackupMetaValue(backupFile(), QStringLiteral("format_version"), QStringLiteral("999"));

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("格式")));
}

void BackupServiceTests::schemaMetadataMismatchIsRejected()
{
    QVERIFY(insertTask(QStringLiteral("版本不一致任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    const QString connectionName = QStringLiteral("MismatchPragma");
    {
        QSqlDatabase database =
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(backupFile());
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 6")));
        database.close();
    }
    QSqlDatabase::removeDatabase(connectionName);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), false);
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("不一致")));
}

void BackupServiceTests::restoreCreatesPreRestoreSnapshot()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    // 恢复目录里应出现一份 before-restore 快照。
    QDir dir(backupsDir());
    const QStringList before = dir.entryList(
        QStringList{QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files);
    QVERIFY(!before.isEmpty());
}

void BackupServiceTests::repeatedRestoresCapPreRestoreSnapshots()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 恢复前快照此前完全没有清理逻辑（pruneAutoBackups 只匹配 auto- 前缀），
    // 每恢复一次就永久多留一份完整数据库副本。
    //
    // 不用「连续恢复很多次」来造这个局面：快照文件名带秒级时间戳，那样每次都要
    // qSleep 一秒才能拿到不同文件名，一个用例就要跑七八秒。直接铺好历史快照，
    // 再跑一次真实恢复，测到的是同一段清理逻辑。
    QDir(backupsDir()).mkpath(QStringLiteral("."));
    const int existing = BackupService::kBeforeRestoreRetention + 3;
    for (int i = 0; i < existing; ++i) {
        QFile stale(QDir(backupsDir()).filePath(
            QStringLiteral("before-restore-2020010100000%1.tomatobackup").arg(i)));
        QVERIFY(stale.open(QIODevice::WriteOnly));
        stale.write("stale");
        stale.close();
    }

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    QDir dir(backupsDir());
    const QStringList snapshots = dir.entryList(
        QStringList{QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files);
    QCOMPARE(snapshots.size(), BackupService::kBeforeRestoreRetention);

    // 自动备份是另一套配额，不能被恢复前快照挤掉，反之亦然。
    const QStringList autos = dir.entryList(
        QStringList{QStringLiteral("auto-*.tomatobackup")}, QDir::Files);
    QVERIFY(autos.isEmpty());
}

void BackupServiceTests::newPreRestoreSnapshotSurvivesOlderSnapshotsWithFutureTimes()
{
    // 以前系统时钟偏快时留下的快照，修改时间和文件名都在「未来」。清理曾按修改时间倒序
    // 保留前 N 份，刚写好的恢复前快照反而排到最后、当场被删——这次恢复要是失败，
    // 回滚去拷一个已经不存在的文件，恢复前的数据就彻底没了。
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    QDir dir(backupsDir());
    QVERIFY(dir.mkpath(QStringLiteral(".")));
    const QDateTime future = QDateTime::currentDateTime().addDays(30);
    QStringList staleNames;
    for (int i = 0; i < BackupService::kBeforeRestoreRetention; ++i) {
        const QString name = QStringLiteral("before-restore-20991231-23595%1-000.tomatobackup").arg(i);
        QFile stale(dir.filePath(name));
        QVERIFY(stale.open(QIODevice::WriteOnly));
        stale.write("stale");
        // 先把缓冲写进磁盘再改时间：否则 close() 时才真正写入，修改时间又被刷回「现在」。
        QVERIFY(stale.flush());
        QVERIFY(stale.setFileTime(future.addSecs(i), QFileDevice::FileModificationTime));
        stale.close();
        staleNames.append(name);
    }

    QVERIFY2(BackupService::instance()->restoreBackup(backupFile()),
             qPrintable(BackupService::instance()->lastError()));

    const QStringList snapshots = dir.entryList(
        QStringList{QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files);
    QStringList fresh;
    for (const QString& name : snapshots) {
        if (!staleNames.contains(name)) {
            fresh.append(name);
        }
    }
    QVERIFY2(fresh.size() == 1,
             qPrintable(QStringLiteral("本次恢复的恢复前快照被清理掉了：%1").arg(snapshots.join(u','))));
    QCOMPARE(snapshots.size(), BackupService::kBeforeRestoreRetention);
}

void BackupServiceTests::failedAsyncPreflightKeepsAllPreRestoreSnapshots_data()
{
    QTest::addColumn<int>("snapshotCount");
    QTest::newRow("at-retention") << BackupService::kBeforeRestoreRetention;
    QTest::newRow("above-retention") << BackupService::kBeforeRestoreRetention + 2;
}

void BackupServiceTests::failedAsyncPreflightKeepsAllPreRestoreSnapshots()
{
    QFETCH(int, snapshotCount);

    QDir dir(backupsDir());
    QVERIFY(dir.mkpath(QStringLiteral(".")));

    QStringList expectedSnapshots;
    for (int i = 0; i < snapshotCount; ++i) {
        const QString fileName = QStringLiteral(
            "before-restore-2020010100000%1.tomatobackup").arg(i);
        QFile snapshot(dir.filePath(fileName));
        QVERIFY(snapshot.open(QIODevice::WriteOnly));
        QVERIFY(snapshot.write("existing snapshot") > 0);
        snapshot.close();
        expectedSnapshots.append(fileName);
    }
    expectedSnapshots.sort();

    const QString damagedSource =
        m_tempDir->filePath(QStringLiteral("damaged-external.tomatobackup"));
    QFile damaged(damagedSource);
    QVERIFY(damaged.open(QIODevice::WriteOnly));
    QVERIFY(damaged.write("not a sqlite backup") > 0);
    damaged.close();

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(damagedSource);
    QVERIFY2(restoredSpy.wait(10000), "异步预检失败信号未在 10 秒内返回");
    QCOMPARE(restoredSpy.last().at(0).toBool(), false);

    // 预检失败没有创建新恢复点，因此旧快照集合必须逐个保持不变，不能顺手做配额清理。
    const QStringList actualSnapshots = dir.entryList(
        QStringList{QStringLiteral("before-restore-*.tomatobackup")},
        QDir::Files,
        QDir::Name);
    QCOMPARE(actualSnapshots, expectedSnapshots);
}

void BackupServiceTests::restoreMatchesTaskAndSessionCounts()
{
    const int taskId = insertTask(QStringLiteral("任务一"));
    QVERIFY(taskId > 0);
    QVERIFY(insertTask(QStringLiteral("任务二")) > 0);
    QVERIFY(insertFocusSession(taskId, 1500));
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 备份后再改动当前库：多加任务、删专注。
    QVERIFY(insertTask(QStringLiteral("多余任务")) > 0);
    QVERIFY(QSqlQuery(DatabaseManager::instance()->database())
                .exec(QStringLiteral("DELETE FROM focus_sessions")));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 3);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 0);

    QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toBool(), true);

    // 恢复后计数与备份时一致。
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 1);
    // 恢复后的库不残留备份专用表。
    QCOMPARE(scalarCount(QStringLiteral(
        "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('backup_meta','backup_settings')")), 0);
}

void BackupServiceTests::restoreUsesValidatedBytesWhenSourcePathChanges()
{
    QVERIFY(insertTask(QStringLiteral("已校验版本")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    QVERIFY(insertTask(QStringLiteral("替换版本多出的任务")) > 0);
    const QString replacement =
        m_tempDir->filePath(QStringLiteral("replacement.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(replacement));

    // 在完整性校验结束后替换同一路径。旧实现会重新打开该路径读取设置并安装，
    // 因而把“没有校验过”的两任务版本装进去；正确实现只能恢复已经暂存的一任务版本。
    bool sourceReplaced = false;
    BackupService::instance()->m_afterRestoreValidationHookForTest = [this,
                                                                      replacement,
                                                                      &sourceReplaced]() {
        sourceReplaced = QFile::remove(backupFile())
            && QFile::copy(replacement, backupFile());
    };

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QVERIFY(sourceReplaced);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

void BackupServiceTests::restorePreservesCountdownGoals()
{
    QVERIFY(insertCountdownGoal(QStringLiteral("四级倒计时")));
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    QVERIFY(QSqlQuery(DatabaseManager::instance()->database())
                .exec(QStringLiteral("DELETE FROM countdown_goals")));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM countdown_goals")), 0);

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM countdown_goals")), 1);
}

void BackupServiceTests::restoreKeepsMcpPolicy_data()
{
    QTest::addColumn<bool>("localEnabled");
    QTest::newRow("keep-disabled") << false;
    QTest::newRow("keep-enabled") << true;
}

void BackupServiceTests::restoreKeepsMcpPolicy()
{
    QFETCH(bool, localEnabled);
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("mcp/enabled"), !localEnabled);
        settings.setValue(QStringLiteral("mcp/writeEnabled"), !localEnabled);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("接入策略隔离")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("mcp/enabled"), localEnabled);
        settings.setValue(QStringLiteral("mcp/writeEnabled"), localEnabled);
        settings.sync();
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QSettings settings(settingsPath(), QSettings::IniFormat);
    // 开着和关着都必须保留，不能借恢复备份偷偷重新授权或关闭本机接入。
    QCOMPARE(settings.value(QStringLiteral("mcp/enabled")).toBool(), localEnabled);
    QCOMPARE(settings.value(QStringLiteral("mcp/writeEnabled")).toBool(), localEnabled);
    QVERIFY(!AppSettings::ownedSettingGroups().contains(QStringLiteral("mcp")));
    QVERIFY(!BackupOperations::isLocalSettingKey(QStringLiteral("mcp/enabled")));
}

void BackupServiceTests::restoreRestoresSettingsValue()
{
    // 通过与 BackupService 相同的 ini 存储写入一个偏好。
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/workMinutes"), 42);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("带设置任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 备份后改动偏好。
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/workMinutes"), 10);
        settings.sync();
    }

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    QSettings restored(settingsPath(), QSettings::IniFormat);
    QCOMPARE(restored.value(QStringLiteral("focus/workMinutes")).toInt(), 42);
}

void BackupServiceTests::restoreRemovesSettingsMissingFromBackup()
{
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/workMinutes"), 42);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("设置全量恢复任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("appearance/temporaryFutureKey"), true);
        settings.sync();
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    QSettings restored(settingsPath(), QSettings::IniFormat);
    QVERIFY(!restored.contains(QStringLiteral("appearance/temporaryFutureKey")));
    QCOMPARE(restored.value(QStringLiteral("focus/workMinutes")).toInt(), 42);
}

void BackupServiceTests::restoreBringsBackDailyGoalHistorySnapshot()
{
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-20"));
        settings.setValue(QStringLiteral("focus/dailyGoalMinutes"), 300);
        settings.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-19"), 240);
        settings.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-20"), 300);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("目标历史任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    {
        // 备份之后本机又设了两天目标。
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-22"));
        settings.setValue(QStringLiteral("focus/dailyGoalMinutes"), 180);
        settings.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-21"), 200);
        settings.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-22"), 180);
        settings.sync();
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    // 恢复先清掉本机自有键再写回快照：备份之后新增的历史消失，快照里的历史回来，
    // 与恢复后的专注记录取自同一时刻。
    QSettings restored(settingsPath(), QSettings::IniFormat);
    QVERIFY(!restored.contains(QStringLiteral("focus/dailyGoalHistory/2026-07-21")));
    QVERIFY(!restored.contains(QStringLiteral("focus/dailyGoalHistory/2026-07-22")));
    QCOMPARE(restored.value(QStringLiteral("focus/dailyGoalHistory/2026-07-19")).toInt(), 240);
    QCOMPARE(restored.value(QStringLiteral("focus/dailyGoalHistory/2026-07-20")).toInt(), 300);

    // 恢复后重载会发出目标变更信号，统计页据此刷新。
    AppSettings settings(settingsPath());
    QSignalSpy changed(&settings, &AppSettings::dailyFocusGoalChanged);
    settings.reload();
    QCOMPARE(changed.count(), 1);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-22")), 0);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 300);
}

void BackupServiceTests::restoreOldBackupWithoutGoalHistoryImportsLegacyDateOnly()
{
    {
        // 旧版本做的备份：只有那一对键，没有按日期的历史。
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-20"));
        settings.setValue(QStringLiteral("focus/dailyGoalMinutes"), 300);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("旧备份任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-18"), 100);
        settings.sync();
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    // 启动（构造）时只导入旧键明确对应的那一天，不推测补齐其它日期。
    AppSettings settings(settingsPath());
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 300);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-18")), 0);
    QSettings after(settingsPath(), QSettings::IniFormat);
    QCOMPARE(after.value(QStringLiteral("focus/dailyGoalHistory/2026-07-20")).toInt(), 300);
    QVERIFY(!after.contains(QStringLiteral("focus/dailyGoalHistory/2026-07-18")));
}

void BackupServiceTests::restoreFailureKeepsOriginalDatabaseIntact()
{
    QVERIFY(insertTask(QStringLiteral("受保护任务")) > 0);
    QVERIFY(insertTask(QStringLiteral("受保护任务二")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    // 恢复一个非法备份必须失败，且原库分毫不动、仍可用。
    const QString garbage = m_tempDir->filePath(QStringLiteral("bad.tomatobackup"));
    QFile file(garbage);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("corrupt");
    file.close();

    QVERIFY(!BackupService::instance()->restoreBackup(garbage));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    QVERIFY(insertTask(QStringLiteral("恢复失败后仍可写")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 3);
}

void BackupServiceTests::activeTimerBlocksRestore()
{
    const int taskId = insertTask(QStringLiteral("活动专注任务"));
    QVERIFY(taskId > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(
        taskId, QStringLiteral("活动专注任务"), 25 * 60));

    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
    QVERIFY(FocusTimer::instance()->hasActiveSession());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);

    QVERIFY(FocusTimer::instance()->stopFocus());
}

void BackupServiceTests::asyncRestoreReloadsTaskSnapshots()
{
    QVERIFY(insertTask(QStringLiteral("备份内任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增任务")) > 0);

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    QSignalSpy tasksChangedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    BackupService::instance()->requestRestore(backupFile());

    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内完成");
    QCOMPARE(restoredSpy.last().at(0).toBool(), true);
    QVERIFY(tasksChangedSpy.count() >= 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    QVERIFY(!BackupService::instance()->busy());
}

void BackupServiceTests::asyncRestoreRollbackReopensDatabaseWhenCopyFails()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    // 设置文件只读 → applySettingsSnapshot 失败 → 安装阶段判定失败 → 触发回滚。
    QFile settingsFile(settingsPath());
    if (!settingsFile.exists()) {
        QSettings seed(settingsPath(), QSettings::IniFormat);
        seed.setValue(QStringLiteral("backup/seed"), 1);
        seed.sync();
    }
    QVERIFY(QFile::setPermissions(settingsPath(), QFileDevice::ReadOwner));

    // 受控开关只影响下一次回滚，用来稳定模拟磁盘满造成的拷贝失败。
    BackupService::instance()->m_forceRollbackCopyFailureForTest = true;

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupFile());
    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内结束");
    QCOMPARE(restoredSpy.last().at(0).toBool(), false);

    // 回滚拷贝失败了，但数据库必须仍然是打开且可用的。
    QVERIFY2(DatabaseManager::instance()->isOpen(),
             "回滚拷贝失败后数据库仍处于关闭状态，应用会变成僵尸态");
    QSqlQuery probe(DatabaseManager::instance()->database());
    QVERIFY2(probe.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) && probe.next(),
             "数据库虽然标记为打开，但已经无法查询");

    // 数据库已可用时不应误导用户重启应用。
    const QString message = restoredSpy.last().at(1).toString();
    QVERIFY2(!message.contains(QStringLiteral("请重启应用")),
             "数据库已重新打开，提示语不应要求用户重启");

    QVERIFY(QFile::setPermissions(settingsPath(),
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner));
    QVERIFY(!BackupService::instance()->busy());
}

void BackupServiceTests::asyncRestoreRollbackRestoresOriginalTaskCount()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        // 必须有一个会被恢复删除的自有键，否则仅有 mcp/ 时恢复根本不写偏好，无法注入写失败。
        settings.setValue(QStringLiteral("backup/seed"), 1);
        settings.setValue(QStringLiteral("mcp/enabled"), true);
        settings.setValue(QStringLiteral("mcp/writeEnabled"), false);
        settings.sync();
    }
    QFile settingsFile(settingsPath());
    if (!settingsFile.exists()) {
        QSettings seed(settingsPath(), QSettings::IniFormat);
        seed.setValue(QStringLiteral("backup/seed"), 1);
        seed.sync();
    }
    QVERIFY(QFile::setPermissions(settingsPath(), QFileDevice::ReadOwner));

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupFile());
    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内结束");
    QCOMPARE(restoredSpy.last().at(0).toBool(), false);

    // 未注入失败时回滚应完整恢复原库，包括恢复前新增的第二条任务。
    QVERIFY(DatabaseManager::instance()->isOpen());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    QVERIFY(QFile::setPermissions(settingsPath(),
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner));
    QSettings settings(settingsPath(), QSettings::IniFormat);
    QCOMPARE(settings.value(QStringLiteral("mcp/enabled")).toBool(), true);
    QCOMPARE(settings.value(QStringLiteral("mcp/writeEnabled")).toBool(), false);
}

void BackupServiceTests::olderSchemaBackupRestoresAndMigrates()
{
    // 直接插入会沿用 v11 的 display_order=0，构造本应用自己产生过的合法旧备份。
    // 恢复入口应接受它，再由正式初始化链迁到 v12，不能要求备份提前满足新不变量。
    QVERIFY(insertTask(QStringLiteral("旧版任务甲")) > 0);
    QVERIFY(insertTask(QStringLiteral("旧版任务乙")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    setBackupSchemaVersion(backupFile(), 11);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), true);

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    QSqlQuery version(DatabaseManager::instance()->database());
    QVERIFY(version.exec(QStringLiteral("PRAGMA user_version")) && version.next());
    QCOMPARE(version.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
    version.finish();
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    QSqlQuery invariant(DatabaseManager::instance()->database());
    QVERIFY(invariant.exec(QStringLiteral(
        "SELECT MIN(display_order), COUNT(DISTINCT display_order), COUNT(*) FROM tasks")));
    QVERIFY(invariant.next());
    QVERIFY(invariant.value(0).toInt() > 0);
    QCOMPARE(invariant.value(1).toInt(), invariant.value(2).toInt());

    const QVariantList restored = TaskManager::instance()->getTasksByDate(QDate::currentDate());
    QCOMPARE(restored.size(), 2);
    QCOMPARE(restored.at(0).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("旧版任务甲"));
    QCOMPARE(restored.at(1).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("旧版任务乙"));
}

void BackupServiceTests::autoBackupRespectsIntervalAndRetention()
{
    BackupService::instance()->setAutoBackupEnabled(true);
    QVERIFY(insertTask(QStringLiteral("自动备份任务")) > 0);

    QDir dir(backupsDir());
    // 反复触发自动备份：每次先清空 lastBackupIso 使其“到期”，
    // 保留策略应把自动备份数量限制在上限内。
    for (int i = 0; i < BackupService::kAutoBackupRetention + 3; ++i) {
        {
            QSettings settings(settingsPath(), QSettings::IniFormat);
            settings.remove(QStringLiteral("backup/lastBackupIso"));
            settings.sync();
        }
        QTest::qSleep(1100); // 保证时间戳文件名不同
        QVERIFY(BackupService::instance()->runAutoBackupIfDue());
    }

    const QStringList autos = dir.entryList(
        QStringList{QStringLiteral("auto-*.tomatobackup")}, QDir::Files);
    QVERIFY2(autos.size() <= BackupService::kAutoBackupRetention,
             qPrintable(QStringLiteral("自动备份数=%1").arg(autos.size())));
    QVERIFY(autos.size() >= 1);
}

void BackupServiceTests::autoBackupDisabledDoesNothing()
{
    BackupService::instance()->setAutoBackupEnabled(false);
    QVERIFY(BackupService::instance()->runAutoBackupIfDue());

    QDir dir(backupsDir());
    const QStringList autos = dir.entryList(
        QStringList{QStringLiteral("auto-*.tomatobackup")}, QDir::Files);
    QVERIFY(autos.isEmpty());
}

void BackupServiceTests::beforeSyncBackupHasItsOwnQuotaAndYieldsToOtherJobs()
{
    QVERIFY(insertTask(QStringLiteral("同步替换前的任务")) > 0);
    // 先铺好几份旧的替换前备份，以及另外两类快照：文件名带秒级时间戳，不靠连做很多次来造。
    QDir dir(backupsDir());
    QVERIFY(dir.mkpath(QStringLiteral(".")));
    const QStringList others = {QStringLiteral("auto-20200101-000000-000.tomatobackup"),
                                QStringLiteral("before-restore-20200101-000000-000.tomatobackup")};
    QStringList stale = others;
    for (int i = 0; i < BackupService::kBeforeSyncRetention + 2; ++i) {
        stale.append(QStringLiteral("before-sync-2020010100000%1.tomatobackup").arg(i));
    }
    for (const QString& name : std::as_const(stale)) {
        QFile file(dir.filePath(name));
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("stale");
    }

    // 同步整体替换本机数据之前：写一份完整的备份，旧的替换前备份收敛到配额，另外两类一份不动。
    QString error;
    QVERIFY(BackupService::instance()->backupBeforeSyncReplace(&error));
    QVERIFY(error.isEmpty());
    const QStringList kept = dir.entryList({QStringLiteral("before-sync-*.tomatobackup")}, QDir::Files);
    QCOMPARE(kept.size(), BackupService::kBeforeSyncRetention);
    QString fresh;
    for (const QString& name : kept) {
        if (!stale.contains(name)) {
            fresh = name;
        }
    }
    QVERIFY(!fresh.isEmpty());
    const QVariantMap info = BackupService::instance()->readBackupInfo(dir.filePath(fresh));
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
    QCOMPARE(info.value(QStringLiteral("taskCount")).toInt(), 1);
    for (const QString& name : others) {
        QVERIFY(QFileInfo::exists(dir.filePath(name)));
    }

    // 另一项备份正在后台进行：不和它撞在一起，拒绝并说明原因，同步稍后会再试。
    BackupService* service = BackupService::instance();
    service->requestBackup(backupFile());
    QVERIFY(service->busy());
    error.clear();
    QVERIFY(!service->backupBeforeSyncReplace(&error));
    QVERIFY(error.contains(QStringLiteral("正在进行")));
    QCOMPARE(dir.entryList({QStringLiteral("before-sync-*.tomatobackup")}, QDir::Files).size(),
             BackupService::kBeforeSyncRetention);
    QTRY_VERIFY(!service->busy());
}

void BackupServiceTests::shutdownWaitsForAsyncWorkers()
{
    QVERIFY(insertTask(QStringLiteral("退出时的异步备份任务")) > 0);

    BackupService* service = BackupService::instance();
    service->requestBackup(backupFile());
    QVERIFY(service->busy());

    // 保证退出会收束后台任务且不留下回调；允许已完整发布或在发布前取消，绝不接受部分备份。
    QSignalSpy completed(service, &BackupService::backupCompleted);
    service->prepareForShutdown();
    QVERIFY(!service->busy());
    QVERIFY(service->m_activeWorkers.isEmpty());
    QCOMPARE(completed.count(), 0);
    if (QFileInfo::exists(backupFile())) {
        QVERIFY(service->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool());
    }
    service->prepareForShutdown();

    const QString ignoredPath = m_tempDir->filePath(QStringLiteral("after-shutdown.tomatobackup"));
    service->requestBackup(ignoredPath);
    QVERIFY(!service->busy());
    QVERIFY(!QFileInfo::exists(ignoredPath));
}

void BackupServiceTests::version20BackupBrokenMemoSchemaIsRejected_data()
{
    QTest::addColumn<QString>("oldText");
    QTest::addColumn<QString>("replacement");
    QTest::newRow("missing-table") << QString() << QString();
    QTest::newRow("missing-column") << QStringLiteral("body TEXT NOT NULL DEFAULT '' CHECK(length(body) <= 10000),") << QString();
    QTest::newRow("cascade") << QStringLiteral("SET NULL") << QStringLiteral("CASCADE");
    QTest::newRow("invalid-primary-key") << QStringLiteral("INTEGER PRIMARY KEY AUTOINCREMENT") << QStringLiteral("INT PRIMARY KEY");
    QTest::newRow("missing-length-limit") << QStringLiteral("CHECK(length(title) <= 60)") << QString();
    QTest::newRow("nullable-text") << QStringLiteral("body TEXT NOT NULL") << QStringLiteral("body TEXT");
    QTest::newRow("wrong-column-type") << QStringLiteral("body TEXT") << QStringLiteral("body INTEGER");
}

void BackupServiceTests::version20BackupBrokenMemoSchemaIsRejected()
{
    QFETCH(QString, oldText);
    QFETCH(QString, replacement);
    QVERIFY(insertTask(QStringLiteral("正式库保留")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("BrokenMemoBackup");
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        QVERIFY(query.exec(QStringLiteral("SELECT sql FROM sqlite_master WHERE name = 'memos'")) && query.next());
        QString sql = query.value(0).toString();
        query.finish();
        QVERIFY(query.exec(QStringLiteral("DROP TABLE memos")));
        if (!oldText.isEmpty()) {
            QVERIFY(sql.contains(oldText));
            sql.replace(oldText, replacement);
            QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        }
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("memos")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '正式库保留'")), 1);
    QVERIFY(DatabaseManager::memoSchemaIsValid(DatabaseManager::instance()->database()));
}

void BackupServiceTests::version19BackupWithoutMemosRestoresAndMigrates()
{
    QVERIFY(insertTask(QStringLiteral("v19 旧任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("Version19MemoBackup");
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        // 真实 v19 没有 memos，不能只调低版本号而继续带着新表来冒充旧备份。
        QVERIFY(query.exec(QStringLiteral("DROP TABLE memos")));
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);
    setBackupSchemaVersion(backupFile(), 19);
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("PRAGMA user_version")), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = 'v19 旧任务'")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM memos")), 0);
    QVERIFY(DatabaseManager::memoSchemaIsValid(DatabaseManager::instance()->database()));
}

void BackupServiceTests::version20BackupRestoresAllMemoFields()
{
    // 产品保证：备份恢复完整保留备忘的业务字段，包括已存入库的内容更新时间。
    int id = 0;
    int category = 0;
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("SELECT id FROM categories ORDER BY display_order LIMIT 1")) && query.next());
        category = query.value(0).toInt();
        query.finish();
        // 同步触发器按内容版本生成更新时间，固定时钟后才能得到下方指定的源数据。
        QVERIFY(query.exec(QStringLiteral("UPDATE sync_runtime SET test_now_ms=%1 WHERE singleton_id=1")
                               .arg(QDateTime::fromString(QStringLiteral("2026-10-02T09:00:00.000Z"), Qt::ISODateWithMs).toMSecsSinceEpoch())));
        QVERIFY(query.exec(QStringLiteral("UPDATE sync_state SET value='0' WHERE key='hlc'")));
        query.prepare(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                                     "VALUES ('数学进度', :body, :category, 7, '2026-10-01T08:00:00.000Z', '2026-10-02T09:00:00.000Z')"));
        query.bindValue(QStringLiteral(":body"), QStringLiteral("  第 8 讲\n第 3 章\n"));
        query.bindValue(QStringLiteral(":category"), category);
        QVERIFY(query.exec());
        id = query.lastInsertId().toInt();
    }
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("DELETE FROM memos")));
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QSqlQuery check(DatabaseManager::instance()->database());
    check.prepare(QStringLiteral("SELECT id, title, body, category_id, sort_order, created_at, updated_at FROM memos WHERE id = :id"));
    check.bindValue(QStringLiteral(":id"), id);
    QVERIFY(check.exec() && check.next());
    QCOMPARE(check.value(0).toInt(), id);
    QCOMPARE(check.value(1).toString(), QStringLiteral("数学进度"));
    QCOMPARE(check.value(2).toString(), QStringLiteral("  第 8 讲\n第 3 章\n"));
    QCOMPARE(check.value(3).toInt(), category);
    QCOMPARE(check.value(4).toInt(), 7);
    QCOMPARE(check.value(5).toString(), QStringLiteral("2026-10-01T08:00:00.000Z"));
    QCOMPARE(check.value(6).toString(), QStringLiteral("2026-10-02T09:00:00.000Z"));
    QVERIFY(!check.next());
}

void BackupServiceTests::version20BackupWithoutTrashRestoresIntoEmptyTrash()
{
    // 产品保证：v20 的旧备份（没有废纸篓表）可以恢复，恢复后升到 v21 并得到一张空的废纸篓，原有数据不丢。
    QVERIFY(insertTask(QStringLiteral("v20 旧任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("Version20TrashBackup");
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        // 真实 v20 没有 trash_items，不能只调低版本号而继续带着新表来冒充旧备份。
        QVERIFY(query.exec(QStringLiteral("DROP TABLE trash_items")));
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);
    setBackupSchemaVersion(backupFile(), 20);
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("PRAGMA user_version")), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = 'v20 旧任务'")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QVERIFY(DatabaseManager::trashSchemaIsValid(DatabaseManager::instance()->database()));
}

void BackupServiceTests::version21BackupKeepsTrashItems()
{
    // 产品保证：v21 备份连同废纸篓一起恢复——恢复是全局回滚，备份之后新放进去的项消失，备份时在的项回来。
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
            "VALUES ('memo', 'in-backup', '备份时在的', '{\"v\":1}', '2026-10-05T01:00:00.000Z')")));
    }
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("DELETE FROM trash_items")));
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
            "VALUES ('memo', 'after-backup', '备份后放进的', '{\"v\":1}', '2026-10-06T01:00:00.000Z')")));
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'in-backup' "
                                        "AND payload = '{\"v\":1}'")), 1);
}

void BackupServiceTests::version21BackupWithTrashSyncTriggersIsAcceptedAndRestored()
{
    // 产品保证：废纸篓登记同步之后，备份里带着 trash_items 的同步触发器和每一行的同步身份；
    // 这样的 v21 备份能通过检查并恢复（同步触发器只按名字放行，名字清单从同步表清单推出），
    // 恢复后废纸篓的内容、同步身份和触发器都在。
    // version21BackupKeepsTrashItems 的备份在登记同步后同样带着触发器、也会走到这条检查，但它不断言触发器真的在备份里；这里显式断言。
    QStringList expectedTriggers;
    for (const auto& spec : SyncSchema::triggers()) {
        if (spec.first.startsWith(QStringLiteral("trash_items_sync_"))) {
            expectedTriggers.append(spec.first);
        }
    }
    QVERIFY(!expectedTriggers.isEmpty());
    const QString liveTriggerSql = QStringLiteral(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND instr(name, 'trash_items_sync_') = 1");
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
            "VALUES ('memo', 'in-backup', '备份时在的', '{\"v\":1}', '2026-10-05T01:00:00.000Z')")));
    }
    QCOMPARE(scalarCount(liveTriggerSql), int(expectedTriggers.size()));
    const QString identity = [] {
        QSqlQuery query(DatabaseManager::instance()->database());
        return query.exec(QStringLiteral("SELECT sync_id FROM trash_items WHERE origin_sync_id = 'in-backup'"))
                && query.next() ? query.value(0).toString() : QString();
    }();
    QVERIFY(!identity.isEmpty());
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 前提：备份文件里确实有 trash_items_sync_ 开头的触发器，那一行带着同步身份。
    const QString connection = QStringLiteral("TrashSyncTriggerBackup");
    QStringList backedUpTriggers;
    QString backedUpIdentity;
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        QVERIFY(query.exec(QStringLiteral(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND instr(name, 'trash_items_sync_') = 1")));
        while (query.next()) {
            backedUpTriggers.append(query.value(0).toString());
        }
        QVERIFY(query.exec(QStringLiteral("SELECT sync_id FROM trash_items WHERE origin_sync_id = 'in-backup'"))
                && query.next());
        backedUpIdentity = query.value(0).toString();
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);
    backedUpTriggers.sort();
    expectedTriggers.sort();
    QCOMPARE(backedUpTriggers, expectedTriggers);
    QCOMPARE(backedUpIdentity, identity);

    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
    QCOMPARE(info.value(QStringLiteral("schemaVersion")).toInt(), DatabaseManager::kCurrentSchemaVersion);

    // 备份之后废纸篓换了内容；恢复把备份时的那一行连同身份带回来，触发器还在。
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("DELETE FROM trash_items")));
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
            "VALUES ('memo', 'after-backup', '备份后放进的', '{\"v\":1}', '2026-10-06T01:00:00.000Z')")));
    }
    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'in-backup' "
                                        "AND sync_id = '%1'").arg(identity)), 1);
    QCOMPARE(scalarCount(liveTriggerSql), int(expectedTriggers.size()));
}

void BackupServiceTests::version21BackupBrokenTrashSchemaIsRejected_data()
{
    QTest::addColumn<QString>("oldText");
    QTest::addColumn<QString>("replacement");
    QTest::newRow("missing-table") << QString() << QString();
    QTest::newRow("missing-column") << QStringLiteral("title TEXT NOT NULL DEFAULT '',") << QString();
    QTest::newRow("nullable-payload") << QStringLiteral("payload TEXT NOT NULL") << QStringLiteral("payload TEXT");
    QTest::newRow("missing-check") << QStringLiteral("CHECK(length(kind) > 0)") << QString();
    QTest::newRow("invalid-primary-key") << QStringLiteral("INTEGER PRIMARY KEY AUTOINCREMENT") << QStringLiteral("INT PRIMARY KEY");
    // 废纸篓登记同步之后，备份里的建表语句末尾带着同步迁移追加的「, sync_id TEXT」；表约束必须排在所有列定义之后，
    // 所以外键要接在 sync_id 后面，插在 deleted_at 后面会让重建这张表的语句本身出现语法错误。
    // oldText 带逗号：origin_sync_id 的定义里也有「sync_id TEXT」，不带逗号会被一起替换掉。
    QTest::newRow("foreign-key") << QStringLiteral(", sync_id TEXT")
                                 << QStringLiteral(", sync_id TEXT, FOREIGN KEY (origin_sync_id) REFERENCES categories(sync_id)");
}

void BackupServiceTests::version21BackupBrokenTrashSchemaIsRejected()
{
    // 产品保证：v21 备份缺废纸篓表或结构不对时被拒绝恢复，正式库不受影响；契约与启动检查共用。
    QFETCH(QString, oldText);
    QFETCH(QString, replacement);
    QVERIFY(insertTask(QStringLiteral("正式库保留")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("BrokenTrashBackup");
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        QVERIFY(query.exec(QStringLiteral("SELECT sql FROM sqlite_master WHERE name = 'trash_items'")) && query.next());
        QString sql = query.value(0).toString();
        query.finish();
        QVERIFY(query.exec(QStringLiteral("DROP TABLE trash_items")));
        if (!oldText.isEmpty()) {
            QVERIFY(sql.contains(oldText));
            sql.replace(oldText, replacement);
            QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
        }
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);
    const auto info = BackupService::instance()->readBackupInfo(backupFile());
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    QVERIFY(info.value(QStringLiteral("reason")).toString().contains(QStringLiteral("trash_items")));
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '正式库保留'")), 1);
    QVERIFY(DatabaseManager::trashSchemaIsValid(DatabaseManager::instance()->database()));
}

int main(int argc, char** argv)
{
    if (argc == 3 && std::strcmp(argv[1], "--sqlite-write-lock-probe") == 0) {
        QCoreApplication app(argc, argv);
        // 独立进程只探测写锁后回滚，不修改数据；同进程锁检查无法证明操作系统互斥仍有效。
        sqlite3* database = nullptr;
        int code = sqlite3_open_v2(argv[2], &database, SQLITE_OPEN_READWRITE, nullptr);
        if (code == SQLITE_OK) {
            code = sqlite3_exec(database, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr);
            if (code == SQLITE_OK) sqlite3_exec(database, "ROLLBACK", nullptr, nullptr, nullptr);
        }
        sqlite3_close(database);
        std::printf("%d\n", code);
        return 0;
    }
    if (argc == 2 && std::strcmp(argv[1], "--backup-shutdown-probe") == 0) {
        QCoreApplication app(argc, argv);
        return BackupServiceTests::shutdownProbe();
    }
    QGuiApplication app(argc, argv);
    BackupServiceTests tests;
    return QTest::qExec(&tests, argc, argv);
}

// 保证DELETE与WAL模式下，快照连接读取或VACUUM后关闭都不解除主库未提交事务的写锁。
void BackupServiceTests::backupConnectionClosePreservesMainWriteLock_data()
{
    QTest::addColumn<QString>("journalMode");
    QTest::addColumn<bool>("vacuum");
    QTest::addColumn<bool>("control");
    for (const QString& mode : {QStringLiteral("DELETE"), QStringLiteral("WAL")}) {
        for (bool vacuum : {false, true}) {
            for (bool control : {false, true}) {
                const QByteArray name = mode.toLatin1() + (vacuum ? "-vacuum" : "-read")
                    + (control ? "-same-runtime-control" : "-backup-driver");
                QTest::newRow(name.constData()) << mode << vacuum << control;
            }
        }
    }
}

// 保证快照生命周期内主事务始终排斥外部写者；同运行实例对照排除探针自身关闭锁的误判。
void BackupServiceTests::backupConnectionClosePreservesMainWriteLock()
{
    QFETCH(QString, journalMode);
    QFETCH(bool, vacuum);
    QFETCH(bool, control);
    const QString path = m_tempDir->filePath(QStringLiteral("lock-source.sqlite"));
    const QString primaryName = QStringLiteral("lock-primary");
    const QString secondaryName = QStringLiteral("lock-secondary");
    const auto removeConnections = qScopeGuard([&] {
        QSqlDatabase::removeDatabase(secondaryName);
        QSqlDatabase::removeDatabase(primaryName);
    });
    auto database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), primaryName);
    database.setDatabaseName(path);
    QVERIFY(database.open());
    const auto closePrimary = qScopeGuard([&] {
        QSqlQuery rollback(database);
        rollback.exec(QStringLiteral("ROLLBACK"));
        rollback.finish();
        database.close();
    });
    {
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("CREATE TABLE lock_values(value INTEGER)")));
        QVERIFY(query.exec(QStringLiteral("INSERT INTO lock_values VALUES(0)")));
        QVERIFY(query.exec(QStringLiteral("PRAGMA journal_mode=") + journalMode) && query.next());
        QCOMPARE(query.value(0).toString().toUpper(), journalMode);
        query.finish();
        QVERIFY(query.exec(QStringLiteral("BEGIN IMMEDIATE")));
        QVERIFY(query.exec(QStringLiteral("UPDATE lock_values SET value=1")));
    }
    const auto externalWriter = [&]() {
        QProcess process;
        const auto stop = qScopeGuard([&] {
            if (process.state() != QProcess::NotRunning) {
                process.kill();
                process.waitForFinished(1000);
            }
        });
        process.start(QCoreApplication::applicationFilePath(),
                      {QStringLiteral("--sqlite-write-lock-probe"), path});
        if (!process.waitForFinished(10000) || process.exitStatus() != QProcess::NormalExit
            || process.exitCode() != 0) return -1;
        bool valid = false;
        const int code = process.readAllStandardOutput().trimmed().toInt(&valid);
        return valid ? code : -1;
    };
    QCOMPARE(externalWriter(), SQLITE_BUSY);
    {
        auto secondary = control
            ? QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), secondaryName)
            : QSqlDatabase::addDatabase(new BackupSqliteDriver({}), secondaryName);
        secondary.setDatabaseName(path);
        QVERIFY(secondary.open());
        {
            QSqlQuery query(secondary);
            const QString sql = vacuum
                ? QStringLiteral("VACUUM main INTO '%1'").arg(path + QStringLiteral(".copy"))
                : QStringLiteral("SELECT value FROM lock_values");
            QVERIFY2(query.exec(sql), qPrintable(query.lastError().text()));
            if (!vacuum) {
                QVERIFY(query.next());
                QCOMPARE(query.value(0).toInt(), 0);
            }
            query.finish();
        }
        secondary.close();
    }
    QCOMPARE(externalWriter(), SQLITE_BUSY);
    QSqlQuery ownWrite(database);
    QVERIFY(ownWrite.exec(QStringLiteral("SELECT value FROM lock_values")) && ownWrite.next());
    QCOMPARE(ownWrite.value(0).toInt(), 1);
}
// 保证：读备份列表时能分清「还没有备份」和「备份文件夹读不了」（iPad 设置页要分开显示）：文件夹不存在是成功的空列表；
// 有备份时新旧接口给出同样的列表，只列备份文件、新的在前；文件夹没有读取权限或者是个普通文件时报 Storage，
// 而旧接口仍回落为空列表，Mac 设置页的行为不变。
void BackupServiceTests::readBackupsSeparatesNoneFromUnreadableFolder()
{
    BackupService* service = BackupService::instance();
    const QString folder = backupsDir();
    QVERIFY(!QFileInfo::exists(folder));
    const ServiceReadResult<QVariantList> none = service->readBackups();
    QVERIFY(none.ok());
    QVERIFY(none.value.isEmpty());

    // 先建较旧的 a、再建较新的 b：期望顺序 b、a 与文件名顺序、创建顺序都相反。
    QVERIFY(QDir().mkpath(folder));
    const auto writeBackup = [&folder](const QString& name, const QDateTime& modified) {
        QFile file(QDir(folder).filePath(name));
        // 先把内容刷到磁盘再改时间：留在缓冲里的话，关文件时的写入会把修改时间刷回「现在」。
        if (!file.open(QIODevice::WriteOnly) || file.write("x") != 1 || !file.flush())
            return false;
        return file.setFileTime(modified, QFileDevice::FileModificationTime);
    };
    const QDateTime now = QDateTime::currentDateTime();
    QVERIFY(writeBackup(QStringLiteral("a") + service->backupFileExtension(), now.addSecs(-7200)));
    QVERIFY(writeBackup(QStringLiteral("b") + service->backupFileExtension(), now.addSecs(-3600)));
    QVERIFY(writeBackup(QStringLiteral("notes.txt"), now));
    const ServiceReadResult<QVariantList> listed = service->readBackups();
    QVERIFY(listed.ok());
    QCOMPARE(listed.value.size(), 2);
    QCOMPARE(listed.value.at(0).toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("b") + service->backupFileExtension());
    QCOMPARE(listed.value.at(1).toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("a") + service->backupFileExtension());
    QCOMPARE(listed.value, service->listBackups());

    // 没有读取和进入权限。先恢复权限再断言，失败时临时目录也能正常删掉。
    const QFileDevice::Permissions permissions = QFile::permissions(folder);
    QVERIFY(QFile::setPermissions(folder, QFileDevice::WriteOwner));
    const ServiceReadResult<QVariantList> locked = service->readBackups();
    const QVariantList legacy = service->listBackups();
    QVERIFY(QFile::setPermissions(folder, permissions));
    QVERIFY(locked.error == ServiceReadError::Storage);
    QVERIFY(locked.value.isEmpty());
    QVERIFY(legacy.isEmpty());

    // 路径上是个普通文件。
    QVERIFY(QDir(folder).removeRecursively());
    QFile plain(folder);
    QVERIFY(plain.open(QIODevice::WriteOnly));
    plain.close();
    QVERIFY(service->readBackups().error == ServiceReadError::Storage);
}

#include "BackupServiceTests.moc"

void BackupServiceTests::restoreDropsForeignSettingKeysAndKeepsShortcutOverrides()
{
    // 备份文件是外部输入：可能来自别的版本、被手工改过、或者干脆是伪造的。
    // 恢复只应写回本应用拥有的键。这条同时守住两侧——陌生键要丢，
    // 而动态的快捷键覆盖必须留下（扁平白名单会把它们一起丢掉，那比不过滤更糟）。
    // 直接写临时设置文件，与本文件其它用例一致：AppSettings::instance() 是进程单例，
    // 指向真实的用户设置，而备份服务被 configure() 指到了临时路径。
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("shortcuts/focus.start"), QStringLiteral("Ctrl+Return"));
        settings.setValue(QStringLiteral("profile/nickname"), QStringLiteral("备份前昵称"));
        settings.sync();
    }
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 往备份里塞一个本应用不认识的键，模拟被改过或来自别处的文件。
    {
        const QString connection = QStringLiteral("ForeignKeyInject");
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
            db.setDatabaseName(backupFile());
            QVERIFY(db.open());
            QByteArray blob;
            QDataStream out(&blob, QIODevice::WriteOnly);
            out << QVariant(QStringLiteral("payload"));
            QSqlQuery insert(db);
            insert.prepare(QStringLiteral(
                "INSERT OR REPLACE INTO backup_settings (key, value) VALUES (:k, :v)"));
            insert.bindValue(QStringLiteral(":k"), QStringLiteral("evil/payload"));
            insert.bindValue(QStringLiteral(":v"), blob);
            QVERIFY(insert.exec());
            db.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }

    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("profile/nickname"), QStringLiteral("恢复前昵称"));
        settings.sync();
    }
    QVERIFY2(BackupService::instance()->restoreBackup(backupFile()),
             qPrintable(BackupService::instance()->lastError()));

    QSettings restored(settingsPath(), QSettings::IniFormat);
    // 陌生键不得落盘。
    QVERIFY2(!restored.allKeys().contains(QStringLiteral("evil/payload")),
             "备份里的陌生键被写进了本应用的偏好文件");
    // 自己的键照常恢复。
    QCOMPARE(restored.value(QStringLiteral("profile/nickname")).toString(),
             QStringLiteral("备份前昵称"));
    // 动态的快捷键覆盖必须活下来。
    QCOMPARE(restored.value(QStringLiteral("shortcuts/focus.start")).toString(),
             QStringLiteral("Ctrl+Return"));
}

// —— 偏好快照只涉及本应用的键（2026-09-15 审查修复）——
// 生产用的是 macOS 原生偏好，默认开启回退：allKeys() 会把系统全局域的键一起列出来，
// 文本替换词典、语言、地区……每份备份都夹带了这些个人信息，恢复失败回滚时
// 还会把它们原样写进应用自己的偏好，从此本应用不再跟随系统设置变化。
// 测试走 ini 文件碰不到原生回退，所以直接把「外来键」写进 ini 来模拟那份列表。

// 产品保证：实际旧SDK生成的备份在同步和异步入口都继续可恢复。
void BackupServiceTests::qt69BackupRestoresWithCurrentRuntime_data()
{
    QTest::addColumn<bool>("asynchronous");
    QTest::newRow("sync") << false;
    QTest::newRow("async") << true;
}

// 产品保证：Qt6.9/旧实现生成的真实备份保留任务、专注和标量偏好，不被当前流版本误拒绝或改值。
void BackupServiceTests::qt69BackupRestoresWithCurrentRuntime()
{
    QFETCH(bool, asynchronous);
    const QString fixturePath = QFINDTESTDATA("fixtures/backup-qt690-cc58394.tomatobackup");
    QFile fixture(fixturePath);
    QVERIFY(fixture.open(QIODevice::ReadOnly));
    QFile provenance(QFINDTESTDATA("fixtures/backup-qt690-cc58394.provenance.json"));
    QVERIFY(provenance.open(QIODevice::ReadOnly));
    const auto proof = QJsonDocument::fromJson(provenance.readAll()).object();
    QCOMPARE(proof.value(QStringLiteral("qtVersion")).toString(), QStringLiteral("6.9.0"));
    QCOMPARE(QCryptographicHash::hash(fixture.readAll(), QCryptographicHash::Sha256).toHex(),
             proof.value(QStringLiteral("sha256")).toString().toLatin1());
    fixture.close();
    const auto settings = BackupOperations::readEmbeddedSettings(fixturePath);
    QVERIFY2(settings.success, qPrintable(settings.error));
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatBool")).metaType().id(), QMetaType::Bool);
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatBool")).toBool(), true);
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatInteger")).metaType().id(), QMetaType::LongLong);
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatInteger")).toLongLong(), qlonglong(-1234567890123LL));
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatReal")).toDouble(), 0.625);
    QCOMPARE(settings.values.value(QStringLiteral("appearance/compatUnicode")).toString(), QStringLiteral("旧SDK学习👩‍💻\n虚构数据"));

    auto* service = BackupService::instance();
    const auto info = service->readBackupInfo(fixturePath);
    QVERIFY2(info.value(QStringLiteral("valid")).toBool(), qPrintable(info.value(QStringLiteral("reason")).toString()));
    QCOMPARE(info.value(QStringLiteral("taskCount")).toInt(), 1);
    QCOMPARE(info.value(QStringLiteral("sessionCount")).toInt(), 1);
    // 当前库有不同任务/偏好，只有真实替换成功才能满足后续断言。
    QVERIFY(insertTask(QStringLiteral("当前库应被替换的虚构任务")) > 0);
    QSettings current(settingsPath(), QSettings::IniFormat);
    current.setValue(QStringLiteral("focus/workMinutes"), 19);
    current.sync();
    QCOMPARE(current.value(QStringLiteral("focus/workMinutes")).toInt(), 19);
    QSignalSpy completed(service, &BackupService::restoreCompleted);
    if (asynchronous) {
        service->requestRestore(fixturePath);
        QTRY_COMPARE_WITH_TIMEOUT(completed.count(), 1, 10000);
    } else {
        QVERIFY(service->restoreBackup(fixturePath));
        QCOMPARE(completed.count(), 1);
    }
    QVERIFY2(completed.first().at(0).toBool(), qPrintable(completed.first().at(1).toString()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='Qt6.9虚构兼容任务'")), 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE duration=1500")), 1);
    current.sync();
    QCOMPARE(current.value(QStringLiteral("focus/workMinutes")).toInt(), 37);
    QCOMPARE(current.value(QStringLiteral("appearance/compatUnicode")).toString(), QStringLiteral("旧SDK学习👩‍💻\n虚构数据"));
}

// 产品保证：已支持的标量类型保持固定字节表示，不能随着构建SDK默认流版本漂移。
void BackupServiceTests::settingsScalarEncodingRemainsCompatible_data()
{
    QTest::addColumn<QVariant>("value");
    QTest::addColumn<QByteArray>("encoded");
    QFile fixture(QFINDTESTDATA("fixtures/backup-settings-scalars.json"));
    QVERIFY(fixture.open(QIODevice::ReadOnly));
    const auto samples = QJsonDocument::fromJson(fixture.readAll()).object().value(QStringLiteral("samples")).toArray();
    QCOMPARE(samples.size(), 9);
    for (const QJsonValue& sample : samples) {
        const auto row = sample.toObject();
        const QString kind = row.value(QStringLiteral("kind")).toString();
        const auto stored = row.value(QStringLiteral("value"));
        QVariant value;
        if (kind == QStringLiteral("bool")) value = stored.toBool();
        else if (kind == QStringLiteral("int")) value = stored.toInt();
        else if (kind == QStringLiteral("uint")) value = QVariant::fromValue(static_cast<uint>(stored.toDouble()));
        else if (kind == QStringLiteral("longlong")) value = QVariant::fromValue(static_cast<qlonglong>(stored.toDouble()));
        else if (kind == QStringLiteral("ulonglong")) value = QVariant::fromValue(stored.toString().toULongLong());
        else if (kind == QStringLiteral("double")) value = stored.toDouble();
        else value = stored.toString();
        QTest::newRow(kind.toUtf8().constData()) << value << QByteArray::fromHex(row.value(QStringLiteral("hex")).toString().toLatin1());
    }
}

// 产品保证：固定样本、受支持旧流版本与真实备份的编码/解码互相兼容，类型和值均保留。
void BackupServiceTests::settingsScalarEncodingRemainsCompatible()
{
    QFETCH(QVariant, value);
    QFETCH(QByteArray, encoded);
    QVERIFY(!encoded.isEmpty());
    // 用当前SDK的兼容编码器验证两代历史格式，不能称为实际运行过旧SDK。
    QList<int> versions{QDataStream::Qt_6_7};
#if QT_VERSION >= QT_VERSION_CHECK(6, 10, 0)
    versions.append(QDataStream::Qt_6_10);
#endif
    for (int version : versions) {
        QByteArray bytes;
        QDataStream writer(&bytes, QIODevice::WriteOnly);
        writer.setVersion(version);
        writer << value;
        QCOMPARE(writer.status(), QDataStream::Ok);
        QCOMPARE(bytes, encoded);
    }
    const QString key = QStringLiteral("appearance/encodingFixture");
    QSettings settings(settingsPath(), QSettings::IniFormat);
    settings.setValue(key, value);
    settings.sync();
    QCOMPARE(settings.status(), QSettings::NoError);
    QCOMPARE(settings.value(key).metaType().id(), value.metaType().id());
    QVERIFY(insertTask(QStringLiteral("编码兼容任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("ScalarFixture_") + QUuid::createUuid().toString();
    const auto removeConnection = qScopeGuard([&] { QSqlDatabase::removeDatabase(connection); });
    {
        auto db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery q(db);
        q.prepare(QStringLiteral("SELECT value FROM backup_settings WHERE key=:key"));
        q.bindValue(QStringLiteral(":key"), key);
        QVERIFY(q.exec() && q.next());
        QCOMPARE(q.value(0).toByteArray(), encoded);
        q.finish();
        // 独立固定字节重新装入备份，不以同一写实现自证解码正确。
        q.prepare(QStringLiteral("UPDATE backup_settings SET value=:value WHERE key=:key"));
        q.bindValue(QStringLiteral(":value"), encoded);
        q.bindValue(QStringLiteral(":key"), key);
        QVERIFY(q.exec());
        QCOMPARE(q.numRowsAffected(), 1);
        q.finish();
        db.close();
    }
    const auto restored = BackupOperations::readEmbeddedSettings(backupFile());
    QVERIFY2(restored.success, qPrintable(restored.error));
    QCOMPARE(restored.values.value(key).metaType().id(), value.metaType().id());
    QCOMPARE(restored.values.value(key), value);
}

void BackupServiceTests::backupEmbedsOnlyOwnedSettingKeys()
{
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/workMinutes"), 42);
        settings.setValue(QStringLiteral("shortcuts/focus.start"), QStringLiteral("Ctrl+Return"));
        settings.setValue(QStringLiteral("AppleLocale"), QStringLiteral("zh_CN"));
        settings.setValue(QStringLiteral("NSUserDictionaryReplacementItems"),
                          QStringLiteral("私人文本替换"));
        settings.setValue(QStringLiteral("backup/autoEnabled"), true);
        settings.setValue(QStringLiteral("mcp/enabled"), true);
        settings.setValue(QStringLiteral("mcp/writeEnabled"), true);
        settings.sync();
    }
    QVERIFY(insertTask(QStringLiteral("偏好过滤任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    QStringList embeddedKeys;
    const QString connection = QStringLiteral("EmbeddedKeysProbe");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery rows(db);
        QVERIFY(rows.exec(QStringLiteral("SELECT key FROM backup_settings")));
        while (rows.next()) {
            embeddedKeys.append(rows.value(0).toString());
        }
        rows.finish();
        db.close();
    }
    QSqlDatabase::removeDatabase(connection);

    QVERIFY(embeddedKeys.contains(QStringLiteral("focus/workMinutes")));
    QVERIFY(embeddedKeys.contains(QStringLiteral("shortcuts/focus.start")));
    QVERIFY2(!embeddedKeys.contains(QStringLiteral("AppleLocale")),
             "系统全局域的键被嵌进了备份文件");
    QVERIFY2(!embeddedKeys.contains(QStringLiteral("NSUserDictionaryReplacementItems")),
             "用户的文本替换词典被嵌进了备份文件");
    // 自动备份策略属于本机，恢复时本来就不用它，不必随备份带走。
    QVERIFY(!embeddedKeys.contains(QStringLiteral("backup/autoEnabled")));
    for (const QString& key : embeddedKeys) QVERIFY(!key.startsWith(QStringLiteral("mcp/")));
}

void BackupServiceTests::settingsSnapshotSkipsForeignKeysAndApplyLeavesThemAlone()
{
    {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.setValue(QStringLiteral("focus/workMinutes"), 42);
        settings.setValue(QStringLiteral("backup/autoEnabled"), false);
        settings.setValue(QStringLiteral("AppleLanguages"), QStringLiteral("zh-Hans"));
        settings.sync();
    }

    bool ok = false;
    const QVariantMap snapshot = BackupService::instance()->currentSettingsSnapshot(&ok);
    QVERIFY(ok);
    QCOMPARE(snapshot.value(QStringLiteral("focus/workMinutes")).toInt(), 42);
    // 回滚要用它恢复本机的自动备份策略，所以 backup/ 要留在快照里。
    QVERIFY(snapshot.contains(QStringLiteral("backup/autoEnabled")));
    QVERIFY2(!snapshot.contains(QStringLiteral("AppleLanguages")),
             "设置快照带上了外来键，回滚时会被写进应用自己的偏好");

    // 写回快照只替换本应用的键：不认识的键既不写入，也不删除——
    // 原生偏好里还有 Cocoa 自己记的窗口位置之类，清空整个域会把它们一起抹掉。
    QVariantMap values;
    values.insert(QStringLiteral("focus/workMinutes"), 25);
    QVERIFY(BackupService::instance()->applySettingsSnapshot(values));

    QSettings after(settingsPath(), QSettings::IniFormat);
    QCOMPARE(after.value(QStringLiteral("focus/workMinutes")).toInt(), 25);
    QVERIFY(!after.contains(QStringLiteral("backup/autoEnabled")));
    QCOMPARE(after.value(QStringLiteral("AppleLanguages")).toString(), QStringLiteral("zh-Hans"));
}

void BackupServiceTests::nativeSettingsDoNotFallBackToGlobalDomain()
{
    // 空路径 = 生产用的原生偏好。只检查回退开关，不读写任何真实偏好。
    const std::unique_ptr<QSettings> settings = BackupOperations::openSettings(QString());
    QVERIFY(settings);
    QVERIFY2(!settings->fallbacksEnabled(),
             "原生偏好开着回退，allKeys() 会列出系统全局域的键");
}

void BackupServiceTests::restoreRefusesOversizedSettingValue()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 塞一个超大的值。QDataStream 解 QVariant 时会先读容器长度再按该长度预留空间，
    // 一个被篡改的长度字段能让解析侧试图分配远超文件大小的内存。
    // 上限必须在解析之前生效——放到解析之后就来不及了。
    {
        const QString connection = QStringLiteral("OversizedInject");
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
            db.setDatabaseName(backupFile());
            QVERIFY(db.open());
            QByteArray blob;
            QDataStream out(&blob, QIODevice::WriteOnly);
            out << QVariant(QString(200000, QLatin1Char('x')));
            QVERIFY(blob.size() > 64 * 1024);
            QSqlQuery insert(db);
            insert.prepare(QStringLiteral(
                "INSERT OR REPLACE INTO backup_settings (key, value) VALUES (:k, :v)"));
            insert.bindValue(QStringLiteral(":k"), QStringLiteral("profile/nickname"));
            insert.bindValue(QStringLiteral(":v"), blob);
            QVERIFY(insert.exec());
            db.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }

    // 整份恢复必须失败并给出原因，而不是带着一个可疑的巨值继续。
    QVERIFY(!BackupService::instance()->restoreBackup(backupFile()));
    QVERIFY2(BackupService::instance()->lastError().contains(QStringLiteral("过大")),
             qPrintable(BackupService::instance()->lastError()));
}

void BackupServiceTests::restoreRefusesBackupCarryingTriggers()
{
    // 产品保证：备忘录上的外来触发器也不能随备份恢复，只有清单里的同步触发器获准。
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));

    // 往备份里植入一个 Trigger。恢复是把外部文件整个复制成主库，
    // 如果不检查 sqlite_master，这个 Trigger 会永久活在用户库里，
    // 之后每次新增备忘都静默执行——恢复前快照也发现不了这种延迟破坏。
    {
        const QString connection = QStringLiteral("TriggerInject");
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
            db.setDatabaseName(backupFile());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY2(q.exec(QStringLiteral(
                "CREATE TRIGGER evil AFTER INSERT ON memos BEGIN "
                "DELETE FROM tasks WHERE id <> NEW.id; END")), qPrintable(q.lastError().text()));
            db.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }

    // 期望：拒绝恢复。备份是数据，不是可信的数据库程序。
    QVERIFY2(!BackupService::instance()->restoreBackup(backupFile()),
             "带 Trigger 的备份被接受了");
}

void BackupServiceTests::restoreReplacesSyncTriggersWithTheAppsOwn()
{
    // 产品保证：带备忘录同步触发器的备份可恢复，伪造的同名触发器在第一次业务写入前被换掉。
    QSqlQuery memo(DatabaseManager::instance()->database());
    QVERIFY(memo.exec(QStringLiteral("INSERT INTO memos(title,body,sort_order,created_at,updated_at) "
                                    "VALUES('备忘备份','完整正文',1,'2026-10-02T12:51:46.728Z','2026-10-02T12:51:46.728Z')")));
    const int memoId = memo.lastInsertId().toInt();
    memo.finish();
    // v18 起库里本来就有维护同步版本的触发器，备份自然带着它们；这样的备份必须能恢复。
    const int taskId = insertTask(QStringLiteral("原始任务"));
    QVERIFY(taskId > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY2(BackupService::instance()->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool(),
             qPrintable(BackupService::instance()->lastError()));

    // 以后改了同步表或触发器写法，更早版本的备份里的同步触发器文本就和这一版不同（这里换掉一个当作旧版本）；
    // 名字照抄、内容伪造的也一样（删一条任务就清空全部科目）。旧备份不能因此恢复不了，
    // 伪造的也不能活进库里：打开恢复后的库时，在任何写入之前就被拆掉，换成本应用这一版的。
    {
        const QString connection = QStringLiteral("ForgedSyncTrigger");
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
            db.setDatabaseName(backupFile());
            QVERIFY(db.open());
            QSqlQuery q(db);
            QVERIFY2(q.exec(QStringLiteral("DROP TRIGGER memos_sync_ad")), qPrintable(q.lastError().text()));
            QVERIFY2(q.exec(QStringLiteral("CREATE TRIGGER memos_sync_ad AFTER DELETE ON memos BEGIN DELETE FROM categories; END")),
                     qPrintable(q.lastError().text()));
            QVERIFY2(q.exec(QStringLiteral("DROP TRIGGER tasks_sync_au")), qPrintable(q.lastError().text()));
            QVERIFY2(q.exec(QStringLiteral(
                "CREATE TRIGGER tasks_sync_au AFTER UPDATE OF title ON tasks BEGIN SELECT 1; END")),
                qPrintable(q.lastError().text()));
            QVERIFY2(q.exec(QStringLiteral("DROP TRIGGER tasks_sync_ad")), qPrintable(q.lastError().text()));
            QVERIFY2(q.exec(QStringLiteral(
                "CREATE TRIGGER tasks_sync_ad AFTER DELETE ON tasks BEGIN DELETE FROM categories; END")),
                qPrintable(q.lastError().text()));
            db.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }

    QVERIFY2(BackupService::instance()->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool(),
             qPrintable(BackupService::instance()->lastError()));
    QVERIFY2(BackupService::instance()->restoreBackup(backupFile()), qPrintable(BackupService::instance()->lastError()));

    // 库里的同步触发器恰好是本应用这一版的那一组；删一条任务不会清掉科目。
    QHash<QString, QString> triggers;
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'")));
    while (query.next()) {
        triggers.insert(query.value(0).toString(), query.value(1).toString());
    }
    query.finish();
    QCOMPARE(triggers, SyncSchema::canonicalTriggerSql());
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM categories")) && query.next());
    const int categories = query.value(0).toInt();
    query.finish();
    QVERIFY(categories > 0);
    QVERIFY(query.exec(QStringLiteral("SELECT body FROM memos WHERE id=%1").arg(memoId)) && query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("完整正文"));
    query.finish();
    QVERIFY(query.exec(QStringLiteral("DELETE FROM memos WHERE id=%1").arg(memoId)));
    QVERIFY(query.exec(QStringLiteral("DELETE FROM tasks WHERE id = %1").arg(taskId)));
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM categories")) && query.next());
    QCOMPARE(query.value(0).toInt(), categories);
}

void BackupServiceTests::asyncRestoreRejectsUnsafeSettings_data()
{
    QTest::addColumn<QByteArray>("blob");
    QByteArray nested;
    QDataStream stream(&nested, QIODevice::WriteOnly);
    // 直接构造线性字节，测试本身也不递归创建或销毁深层 QVariant。
    for (int i = 0; i < 6000; ++i) {
        stream << quint32(QMetaType::QVariantList) << quint8(0) << quint32(1);
    }
    stream << QVariant(1);
    QTest::newRow("deep-list") << nested;
    QByteArray hugeString;
    QDataStream header(&hugeString, QIODevice::WriteOnly);
    header << quint32(QMetaType::QString) << quint8(0) << quint32(0x7ffffff0);
    QTest::newRow("forged-string-length") << hugeString;
    QByteArray scalar;
    QDataStream scalarStream(&scalar, QIODevice::WriteOnly);
    scalarStream << QVariant(42);
    QTest::newRow("trailing-bytes") << (scalar + QByteArray("garbage"));
}

void BackupServiceTests::asyncRestoreRejectsUnsafeSettings()
{
    QFETCH(QByteArray, blob);
    QVERIFY(insertTask(QStringLiteral("安全保留")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("UnsafeSettingsInject");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        query.prepare(QStringLiteral("INSERT OR REPLACE INTO backup_settings VALUES (:key, :value)"));
        query.bindValue(QStringLiteral(":key"), QStringLiteral("profile/nickname"));
        query.bindValue(QStringLiteral(":value"), blob);
        QVERIFY(query.exec());
    }
    QSqlDatabase::removeDatabase(connection);
    QSignalSpy completed(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupFile());
    QTRY_COMPARE(completed.count(), 1);
    QVERIFY(!completed.first().at(0).toBool());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

void BackupServiceTests::commentedVirtualTableIsRejected()
{
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    const QString connection = QStringLiteral("VirtualTableInject");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        db.setDatabaseName(backupFile());
        QVERIFY(db.open());
        QSqlQuery query(db);
        QVERIFY2(query.exec(QStringLiteral("CREATE VIRTUAL /* comment */ TABLE extra USING fts5(body)")),
                 qPrintable(query.lastError().text()));
    }
    QSqlDatabase::removeDatabase(connection);
    QVERIFY(!BackupService::instance()->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool());
}

void BackupServiceTests::restoreRejectsWhenPreparationCallbackFails()
{
    // 保证恢复意图准备回调拒绝时，同步 restoreBackup 与异步 requestRestore 均拒绝换库，原任务和偏好不变，不派发后台工作。
    // 准备基线备份文件
    QVERIFY(insertTask(QStringLiteral("备份里的原始任务")) > 0);
    const QString backupPath = m_tempDir->filePath(QStringLiteral("prep_fail_test.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(backupPath));

    // 在当前库修改数据和偏好
    QVERIFY(insertTask(QStringLiteral("当前库的新任务")) > 0);
    AppSettings::instance()->setWorkMinutes(45);
    QCOMPARE(AppSettings::instance()->workMinutes(), 45);

    // 真实 BackupService 同步/异步入口遇 sidecar 同名目录拒绝且原任务/偏好不变（用真实控制器回调）
    SyncController controller(SyncController::Platform{});
    BackupService::instance()->setRestorePreparationCallback([&controller](QString* err) {
        return controller.prepareForRestore(err);
    });

    const QString dbPath = DatabaseManager::instance()->database().databaseName();
    const QString journalDir = dbPath + QStringLiteral(".sync-restore.json");
    QVERIFY(QDir().mkdir(journalDir));

    // 1. 同步 restoreBackup 入口验证
    {
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        const bool ok = BackupService::instance()->restoreBackup(backupPath);
        QVERIFY(!ok);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.first().at(0).toBool(), false);
        QVERIFY2(!BackupService::instance()->lastError().isEmpty(), "错误信息不应为空");

        // 数据库与设置未被替换
        QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='当前库的新任务'")), 1);
        QCOMPARE(AppSettings::instance()->workMinutes(), 45);
        QVERIFY(QFileInfo(journalDir).isDir());
    }

    // 2. 异步 requestRestore 入口验证
    {
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        BackupService::instance()->requestRestore(backupPath);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.first().at(0).toBool(), false);
        QVERIFY2(!BackupService::instance()->lastError().isEmpty(), "错误信息不应为空");
        QVERIFY(!BackupService::instance()->busy());

        // 数据库与设置依然完整
        QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='当前库的新任务'")), 1);
        QCOMPARE(AppSettings::instance()->workMinutes(), 45);
        QVERIFY(QFileInfo(journalDir).isDir());
    }

    QVERIFY(QDir(journalDir).removeRecursively());
}

void BackupServiceTests::restoreSucceedsWhenNoPreparationCallbackRegistered()
{
    // 保证未装配恢复意图回调时，BackupService 保持现有独立恢复能力，正常完成备份换库与设置恢复。
    BackupService::instance()->setRestorePreparationCallback(nullptr);
    QVERIFY(insertTask(QStringLiteral("独立测试任务")) > 0);
    const QString backupPath = m_tempDir->filePath(QStringLiteral("standalone_test.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(backupPath));

    QVERIFY(BackupService::instance()->restoreBackup(backupPath));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title='独立测试任务'")), 1);
}

void BackupServiceTests::restoreSyncCompletedSignalSemanticsAndBranchCoverage()
{
    // 保证 restoreSyncCompleted 内部信号在所有恢复入口与出口中具备精准语义：
    // 1. 严格先于 UI restoreCompleted 发送；
    // 2. 准备前拒绝绝不发送；
    // 3. safeToResume 精确反映真实回滚/重开安全状态。

    // 基线有效备份
    QVERIFY(insertTask(QStringLiteral("基线任务")) > 0);
    const QString validBackup = m_tempDir->filePath(QStringLiteral("sync_sem_valid.tomatobackup"));
    QVERIFY(BackupService::instance()->createBackup(validBackup));

    struct SignalTracker {
        QList<QString> order;
        bool lastSuccess = false;
        bool lastSafe = false;
    } tracker;

    auto recordSignals = [&](QMetaObject::Connection& connSync, QMetaObject::Connection& connUi) {
        tracker.order.clear();
        connSync = connect(BackupService::instance(), &BackupService::restoreSyncCompleted,
                           this, [&](bool success, bool safe) {
            tracker.order.append(QStringLiteral("restoreSyncCompleted"));
            tracker.lastSuccess = success;
            tracker.lastSafe = safe;
        });
        connUi = connect(BackupService::instance(), &BackupService::restoreCompleted,
                         this, [&](bool, const QString&) {
            tracker.order.append(QStringLiteral("restoreCompleted"));
        });
    };

    QMetaObject::Connection cSync;
    QMetaObject::Connection cUi;

    // 分支 1：准备前回调拒绝 -> 绝不发射 restoreSyncCompleted
    {
        recordSignals(cSync, cUi);
        BackupService::instance()->setRestorePreparationCallback([](QString* err) {
            if (err) *err = QStringLiteral("测试准备拒绝");
            return false;
        });
        QVERIFY(!BackupService::instance()->restoreBackup(validBackup));
        disconnect(cSync);
        disconnect(cUi);
        QCOMPARE(tracker.order.count(), 1);
        QCOMPARE(tracker.order.first(), QStringLiteral("restoreCompleted"));
    }

    // 清除准备回调，后续测试走准入
    BackupService::instance()->setRestorePreparationCallback(nullptr);

    // 分支 2：同步入口 restoreBackup 成功 -> (true, true)
    {
        recordSignals(cSync, cUi);
        QVERIFY(BackupService::instance()->restoreBackup(validBackup));
        disconnect(cSync);
        disconnect(cUi);
        QCOMPARE(tracker.order.count(), 2);
        QCOMPARE(tracker.order.at(0), QStringLiteral("restoreSyncCompleted"));
        QCOMPARE(tracker.order.at(1), QStringLiteral("restoreCompleted"));
        QCOMPARE(tracker.lastSuccess, true);
        QCOMPARE(tracker.lastSafe, true);
    }

    // 分支 3：同步入口 restoreBackup 安装失败但安全回滚 -> (false, true)
    {
        recordSignals(cSync, cUi);
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
        const bool ok = BackupService::instance()->restoreBackup(validBackup);
        disconnect(cSync);
        disconnect(cUi);
        QVERIFY(!ok);
        QCOMPARE(tracker.order.count(), 2);
        QCOMPARE(tracker.order.at(0), QStringLiteral("restoreSyncCompleted"));
        QCOMPARE(tracker.order.at(1), QStringLiteral("restoreCompleted"));
        QCOMPARE(tracker.lastSuccess, false);
        QCOMPARE(tracker.lastSafe, true);
    }

    // 分支 4：异步入口 requestRestore 预检失败（未关库） -> (false, true)
    {
        const QString brokenBackup = m_tempDir->filePath(QStringLiteral("broken_preflight.tomatobackup"));
        {
            QFile f(brokenBackup);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("not a valid sqlite backup file");
            f.close();
        }
        recordSignals(cSync, cUi);
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        BackupService::instance()->requestRestore(brokenBackup);
        QVERIFY(spy.wait(10000));
        disconnect(cSync);
        disconnect(cUi);
        QCOMPARE(tracker.order.count(), 2);
        QCOMPARE(tracker.order.at(0), QStringLiteral("restoreSyncCompleted"));
        QCOMPARE(tracker.order.at(1), QStringLiteral("restoreCompleted"));
        QCOMPARE(tracker.lastSuccess, false);
        QCOMPARE(tracker.lastSafe, true);
    }

    // 分支 5：异步入口 requestRestore 成功 -> (true, true)
    {
        recordSignals(cSync, cUi);
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        BackupService::instance()->requestRestore(validBackup);
        QVERIFY(spy.wait(10000));
        disconnect(cSync);
        disconnect(cUi);
        QCOMPARE(tracker.order.count(), 2);
        QCOMPARE(tracker.order.at(0), QStringLiteral("restoreSyncCompleted"));
        QCOMPARE(tracker.order.at(1), QStringLiteral("restoreCompleted"));
        QCOMPARE(tracker.lastSuccess, true);
        QCOMPARE(tracker.lastSafe, true);
    }

    // 分支 6：异步入口 requestRestore 回滚失败 -> (false, false)
    {
        const QString settingsFile = m_tempDir->filePath(QStringLiteral("sem_settings.ini"));
        BackupService::instance()->configure(settingsFile, backupsDir());
        auto guard = qScopeGuard([&]() {
            BackupService::instance()->configure(settingsPath(), backupsDir());
        });
        {
            QSettings seed(settingsFile, QSettings::IniFormat);
            seed.setValue(QStringLiteral("backup/seed"), 1);
            seed.sync();
        }
        QVERIFY(QFile::setPermissions(settingsFile, QFileDevice::ReadOwner));
        BackupService::instance()->m_forceRollbackCopyFailureForTest = true;

        recordSignals(cSync, cUi);
        QSignalSpy spy(BackupService::instance(), &BackupService::restoreCompleted);
        BackupService::instance()->requestRestore(validBackup);
        QVERIFY(spy.wait(10000));
        disconnect(cSync);
        disconnect(cUi);

        QVERIFY(QFile::setPermissions(settingsFile, QFileDevice::ReadOwner | QFileDevice::WriteOwner));

        QCOMPARE(tracker.order.count(), 2);
        QCOMPARE(tracker.order.at(0), QStringLiteral("restoreSyncCompleted"));
        QCOMPARE(tracker.order.at(1), QStringLiteral("restoreCompleted"));
        QCOMPARE(tracker.lastSuccess, false);
        QCOMPARE(tracker.lastSafe, false);
    }
}

// 保证取消发生在任何工作之前时，复制和快照均不写目标，检查信息不报告有效。
void BackupServiceTests::cancellationBeforeWorkPreservesFiles()
{
    QVERIFY(insertTask(QStringLiteral("取消必须保留")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QFile original(backupFile());
    QVERIFY(original.open(QIODevice::ReadOnly));
    const QByteArray before = original.readAll();
    original.close();
    auto operation = std::make_shared<BackupOperationControl>();
    operation->requestStop();
    const QString target = m_tempDir->filePath(QStringLiteral("cancelled-copy"));
    const auto copy = BackupOperations::atomicCopy(backupFile(), target, -1, operation);
    QVERIFY(!copy.success);
    QVERIFY(!copy.committed);
    QVERIFY(!QFileInfo::exists(target));
    const auto snapshot = BackupOperations::createSnapshot(dbPath(), settingsPath(), backupFile(),
        QStringLiteral("manual"), DatabaseManager::kCurrentSchemaVersion, operation);
    QVERIFY(!snapshot.success);
    QVERIFY(!snapshot.committed);
    QVERIFY(original.open(QIODevice::ReadOnly));
    QCOMPARE(original.readAll(), before);
    const auto info = BackupOperations::inspectBackup(backupFile(), DatabaseManager::kCurrentSchemaVersion, operation);
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    QVERIFY(!BackupOperations::readEmbeddedSettings(backupFile(), operation).success);
}

// 保证已用尽处理预算的操作在入口拒绝，不生成新快照或把取消校验判为有效。
void BackupServiceTests::elapsedBudgetRejectsSnapshotAndInspection()
{
    QVERIFY(insertTask(QStringLiteral("预算原数据")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    auto operation = std::make_shared<BackupOperationControl>(0);
    QVERIFY(operation->stopped());
    const auto info = BackupOperations::inspectBackup(backupFile(), DatabaseManager::kCurrentSchemaVersion, operation);
    QVERIFY(!info.value(QStringLiteral("valid")).toBool());
    const QString destination = m_tempDir->filePath(QStringLiteral("expired.tomatobackup"));
    const auto result = BackupOperations::createSnapshot(dbPath(), settingsPath(), destination,
        QStringLiteral("manual"), DatabaseManager::kCurrentSchemaVersion, operation);
    QVERIFY(!result.success);
    QVERIFY(!QFileInfo::exists(destination));
}

// 保证显式取消异步备份不报告成功，原目标保留；完成前仍拒绝另一项备份。
void BackupServiceTests::asyncCancellationDoesNotPublishSuccess()
{
    QVERIFY(insertTask(QStringLiteral("异步取消")) > 0);
    auto* service = BackupService::instance();
    QSignalSpy completed(service, &BackupService::backupCompleted);
    service->requestBackup(backupFile());
    QVERIFY(service->busy());
    service->cancelCurrentOperation();
    QVERIFY(service->busy());
    QTRY_COMPARE(completed.count(), 1);
    QVERIFY(!completed.at(0).at(0).toBool());
    QVERIFY(!QFileInfo::exists(backupFile()));
    QVERIFY(!service->busy());
}

// 保证异步恢复在安装前取消时保留当前任务及偏好，并只在真实完成后发安全结束。
void BackupServiceTests::asyncRestoreCancellationPreservesOriginalData()
{
    QVERIFY(insertTask(QStringLiteral("旧备份任务")) > 0);
    auto* service = BackupService::instance();
    QVERIFY(service->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("不可被取消恢复删除")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    QSignalSpy completed(service, &BackupService::restoreCompleted);
    QSignalSpy syncCompleted(service, &BackupService::restoreSyncCompleted);
    service->requestRestore(backupFile());
    QVERIFY(service->operationBlocksUi());
    service->cancelCurrentOperation();
    QVERIFY(service->operationBlocksUi());
    QTRY_COMPARE(completed.count(), 1);
    QVERIFY(!completed.at(0).at(0).toBool());
    QCOMPARE(syncCompleted.count(), 1);
    QVERIFY(syncCompleted.at(0).at(1).toBool());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
}

// 保证复制取消前已写过至少一块，仍保留旧目标；原子提交后取消必须报告已提交事实。
void BackupServiceTests::copyCancellationAtCommitBoundaries_data()
{
    QTest::addColumn<QByteArray>("stage");
    QTest::newRow("second-chunk") << QByteArray("copy-chunk");
    QTest::newRow("before-commit") << QByteArray("copy-before-commit");
    QTest::newRow("after-commit") << QByteArray("copy-after-commit");
}

// 保证原子复制在取消边界不混淆原目标保留与已提交结果，且不留下暂存文件。
void BackupServiceTests::copyCancellationAtCommitBoundaries()
{
    QFETCH(QByteArray, stage);
    const QString source = m_tempDir->filePath(QStringLiteral("copy-source"));
    const QString target = m_tempDir->filePath(QStringLiteral("copy-target"));
    const QByteArray content(3 * 1024 * 1024, 'n');
    QFile file(source);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write(content), content.size());
    file.close();
    file.setFileName(target);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("old", 3), 3);
    file.close();
    auto operation = std::make_shared<BackupOperationControl>();
    int hits = 0;
    operation->m_checkpointForTest = [&](const char* checkpoint) {
        if (stage != checkpoint) return;
        if (++hits >= (stage == "copy-chunk" ? 2 : 1)) operation->requestStop();
    };
    const auto result = BackupOperations::atomicCopy(source, target, -1, operation);
    QVERIFY(!result.success);
    QCOMPARE(result.committed, stage == "copy-after-commit");
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), result.committed ? content : QByteArray("old"));
    QVERIFY(hits > 0);
    QCOMPARE(QDir(m_tempDir->path()).entryList({QStringLiteral("copy-target.*")}, QDir::Files).size(), 0);
}

// 保证长SQL计算和持锁查询都观察取消，不只在语句之间检查。
void BackupServiceTests::sqlProgressAndBusyObserveCancellation_data()
{
    QTest::addColumn<bool>("busy");
    QTest::newRow("long-sql") << false;
    QTest::newRow("exclusive-lock") << true;
}

// 保证独立SQLite连接可以在进度/等锁回调取消，且原主库连接与数据仍完好。
void BackupServiceTests::sqlProgressAndBusyObserveCancellation()
{
    QFETCH(bool, busy);
    QVERIFY(insertTask(QStringLiteral("SQL取消后保留")) > 0);
    QSqlQuery lock(DatabaseManager::instance()->database());
    if (busy) QVERIFY(lock.exec(QStringLiteral("BEGIN EXCLUSIVE")));
    const auto rollback = qScopeGuard([&] { if (busy) lock.exec(QStringLiteral("ROLLBACK")); });
    auto operation = std::make_shared<BackupOperationControl>();
    int entered = 0;
    operation->m_checkpointForTest = [&](const char* stage) {
        if (std::strcmp(stage, busy ? "sql-busy" : "sql-progress") == 0) {
            ++entered;
            operation->requestStop();
        }
    };
    const QString name = QStringLiteral("cancel-sql-connection");
    {
        auto database = QSqlDatabase::addDatabase(new BackupSqliteDriver(operation), name);
        database.setDatabaseName(dbPath());
        QVERIFY(database.open());
        QSqlQuery query(database);
        const QString sql = busy ? QStringLiteral("SELECT COUNT(*) FROM tasks") : QStringLiteral(
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2000000) SELECT sum(x) FROM n");
        QVERIFY(!query.exec(sql));
        QVERIFY(query.lastError().isValid());
        QVERIFY(entered > 0);
        database.close();
    }
    QSqlDatabase::removeDatabase(name);
    QVERIFY(DatabaseManager::instance()->isOpen());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

// 保证恢复取消分别覆盖预检后、恢复点发布后、主库提交前后，以及补救回滚失败。
void BackupServiceTests::restoreCancellationAtInstallBoundaries_data()
{
    QTest::addColumn<int>("commitIndex");
    QTest::addColumn<bool>("afterCommit");
    QTest::addColumn<bool>("rollbackFails");
    QTest::addColumn<bool>("rollbackTimeout");
    QTest::newRow("preflight-committed") << 1 << true << false << false;
    QTest::newRow("snapshot-committed") << 2 << true << false << false;
    QTest::newRow("install-before-commit") << 3 << false << false << false;
    QTest::newRow("install-after-commit") << 3 << true << false << false;
    QTest::newRow("install-rollback-fails") << 3 << true << true << false;
    QTest::newRow("rollback-budget-exhausted") << 3 << true << false << true;
}

// 保证主库已提交的取消进入独立回滚；回滚失败保留prepared日志并阻断同步，重建后仍保护。
void BackupServiceTests::restoreCancellationAtInstallBoundaries()
{
    QFETCH(int, commitIndex);
    QFETCH(bool, afterCommit);
    QFETCH(bool, rollbackFails);
    QFETCH(bool, rollbackTimeout);
    const bool unsafe = rollbackFails || rollbackTimeout;
    auto* service = BackupService::instance();
    QVERIFY(insertTask(QStringLiteral("旧备份")) > 0);
    QSettings settings(settingsPath(), QSettings::IniFormat);
    settings.setValue(QStringLiteral("timer/workDuration"), 25);
    settings.sync();
    QVERIFY(service->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前保留")) > 0);
    settings.setValue(QStringLiteral("timer/workDuration"), 40);
    settings.sync();
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    auto operation = std::make_shared<BackupOperationControl>();
    int commits = 0;
    operation->m_checkpointForTest = [&](const char* stage) {
        if (std::strcmp(stage, afterCommit ? "copy-after-commit" : "copy-before-commit") == 0
            && ++commits == commitIndex) operation->requestStop();
    };
    SyncController controller(SyncController::Platform{});
    controller.initialize();
    service->setRestorePreparationCallback([&](QString* error) { return controller.prepareForRestore(error); });
    const auto connection = connect(service, &BackupService::restoreSyncCompleted, &controller, &SyncController::finishRestore);
    const auto rollbackBudget = connect(service, &BackupService::restoreStarted, &controller, [&] {
        // 只给补救链注入已用尽预算；安装自身仍用原令牌，不能把两个阶段混在一起。
        if (rollbackTimeout) service->m_nextOperationForTest = std::make_shared<BackupOperationControl>(0);
    });
    const auto disconnect = qScopeGuard([&] {
        QObject::disconnect(connection);
        QObject::disconnect(rollbackBudget);
        service->setRestorePreparationCallback(nullptr);
        service->m_forceRollbackCopyFailureForTest = false;
    });
    service->m_nextOperationForTest = operation;
    service->m_forceRollbackCopyFailureForTest = rollbackFails;
    QSignalSpy completed(service, &BackupService::restoreCompleted);
    QSignalSpy syncCompleted(service, &BackupService::restoreSyncCompleted);
    service->requestRestore(backupFile());
    QTRY_COMPARE(completed.count(), 1);
    QCOMPARE(commits, commitIndex);
    QVERIFY(!completed.at(0).at(0).toBool());
    QCOMPARE(syncCompleted.count(), 1);
    QCOMPARE(syncCompleted.at(0).at(1).toBool(), !unsafe);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), unsafe ? 1 : 2);
    QCOMPARE(settings.value(QStringLiteral("timer/workDuration")).toInt(), 40);
    QCOMPARE(controller.isRestoreStateUncertain(), unsafe);
    SyncController restarted(SyncController::Platform{});
    restarted.initialize();
    QCOMPARE(restarted.isRestoreStateUncertain(), unsafe);
    if (commitIndex >= 2) {
        QVERIFY(!QDir(backupsDir()).entryList({QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files).isEmpty());
    }
}

// 保证退出时SQL工作收到协作取消，整个测试进程连同Qt全局线程池都能退出。
int BackupServiceTests::shutdownProbe()
{
    QTemporaryDir directory;
    if (!directory.isValid()) return 20;
    if (!DatabaseManager::instance()->initialize(directory.filePath(QStringLiteral("probe.db")))) return 21;
    BackupService service;
    service.configure(directory.filePath(QStringLiteral("settings.ini")), directory.filePath(QStringLiteral("backups")));
    auto operation = std::make_shared<BackupOperationControl>();
    QSemaphore entered;
    std::atomic<bool> reached{false};
    operation->m_checkpointForTest = [&](const char* stage) {
        if (std::strcmp(stage, "sql-step") != 0 || reached.exchange(true)) return;
        entered.release();
        while (!operation->stopped()) QThread::msleep(1);
    };
    service.m_nextOperationForTest = operation;
    service.requestBackup(directory.filePath(QStringLiteral("cancelled.tomatobackup")));
    if (!entered.tryAcquire(1, 3000)) return 22;
    std::puts("WORKER_ENTERED");
    std::fflush(stdout);
    service.prepareForShutdown();
    if (!service.m_activeWorkers.isEmpty() || service.busy()) return 23;
    if (QFileInfo::exists(directory.filePath(QStringLiteral("cancelled.tomatobackup")))) return 24;
    DatabaseManager::instance()->close();
    std::puts("SHUTDOWN_RETURNED");
    return 0;
}

// 保证父进程验证真正退出而非只看函数返回；护栏失败也回收自己的实验进程。
void BackupServiceTests::cooperativeShutdownExitsWholeProcess()
{
    QProcess process;
    const auto cleanup = qScopeGuard([&] {
        if (process.state() != QProcess::NotRunning) {
            process.kill();
            process.waitForFinished(1000);
        }
    });
    process.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--backup-shutdown-probe")});
    QVERIFY(process.waitForStarted(3000));
    QByteArray output;
    QDeadlineTimer handshake(3000);
    while (!output.contains("WORKER_ENTERED") && !handshake.hasExpired()) {
        process.waitForReadyRead(100);
        output += process.readAllStandardOutput();
        if (process.state() == QProcess::NotRunning) break;
    }
    QVERIFY2(output.contains("WORKER_ENTERED"), "退出前必须确认工作线程已进入受控阻塞点");
    QVERIFY2(process.waitForFinished(5000), "工作已经进入SQL检查点，但取消后整个进程未退出");
    QCOMPARE(process.exitStatus(), QProcess::NormalExit);
    QCOMPARE(process.exitCode(), 0);
    output += process.readAllStandardOutput();
    QVERIFY(output.contains("WORKER_ENTERED"));
    QVERIFY(output.contains("SHUTDOWN_RETURNED"));
}

// 保证工作已提交但完成回调尚未执行时，取消仍不报告成功，已提交的完整文件不会误删。
void BackupServiceTests::queuedBackupResultStillObservesCancellation()
{
    QVERIFY(insertTask(QStringLiteral("提交后取消")) > 0);
    auto* service = BackupService::instance();
    QSignalSpy completed(service, &BackupService::backupCompleted);
    service->requestBackup(backupFile());
    QVERIFY(service->busy());
    QCOMPARE(service->m_activeWorkers.size(), 1);
    service->m_activeWorkers.first()->waitForFinished();
    QVERIFY(QFileInfo::exists(backupFile()));
    QCOMPARE(completed.count(), 0);
    service->cancelCurrentOperation();
    QVERIFY(service->busy());
    QTRY_COMPARE(completed.count(), 1);
    QVERIFY(!completed.at(0).at(0).toBool());
    QVERIFY(service->readBackupInfo(backupFile()).value(QStringLiteral("valid")).toBool());
}

// 保证自动备份提交后取消不推进上次成功时间，也不借取消结果清理历史恢复点。
void BackupServiceTests::cancelledAutomaticBackupKeepsRetentionAndSchedule()
{
    QVERIFY(insertTask(QStringLiteral("自动备份取消")) > 0);
    QVERIFY(QDir().mkpath(backupsDir()));
    for (int i = 0; i < BackupService::kAutoBackupRetention + 1; ++i) {
        QFile file(QDir(backupsDir()).filePath(QStringLiteral("auto-20000101-%1.tomatobackup").arg(i)));
        QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write("preserve"), 8);
    }
    auto operation = std::make_shared<BackupOperationControl>();
    operation->m_checkpointForTest = [&](const char* stage) {
        if (std::strcmp(stage, "copy-after-commit") == 0) operation->requestStop();
    };
    auto* service = BackupService::instance();
    service->m_nextOperationForTest = operation;
    QVERIFY(service->lastBackupTimeIso().isEmpty());
    service->requestAutoBackupIfDue();
    QVERIFY(service->busy());
    QTRY_VERIFY(!service->busy());
    QVERIFY(service->lastBackupTimeIso().isEmpty());
    QCOMPARE(QDir(backupsDir()).entryList({QStringLiteral("auto-20000101-*.tomatobackup")}, QDir::Files).size(),
             BackupService::kAutoBackupRetention + 1);
}

// 保证预检开始前及复制后到下一阶段之间，都不重置整条恢复链的预算。
void BackupServiceTests::asyncExpiredRestoreKeepsOriginalDatabase_data()
{
    QTest::addColumn<bool>("expireDuringPreflight");
    QTest::newRow("expired-at-start") << false;
    QTest::newRow("expired-between-stages") << true;
}

// 保证恢复链预算用尽时在换库前结束，原数据与恢复点配额不变。
void BackupServiceTests::asyncExpiredRestoreKeepsOriginalDatabase()
{
    auto* service = BackupService::instance();
    QVERIFY(insertTask(QStringLiteral("备份版本")) > 0);
    QVERIFY(service->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("当前版本")) > 0);
    QFETCH(bool, expireDuringPreflight);
    auto operation = std::make_shared<BackupOperationControl>(expireDuringPreflight ? 120000 : 0);
    if (expireDuringPreflight) {
        operation->m_checkpointForTest = [&](const char* stage) {
            if (std::strcmp(stage, "copy-after-commit") == 0) operation->m_deadline = QDeadlineTimer(0);
        };
    } else {
        QVERIFY(operation->stopped());
    }
    service->m_nextOperationForTest = operation;
    QSignalSpy completed(service, &BackupService::restoreCompleted);
    QSignalSpy safe(service, &BackupService::restoreSyncCompleted);
    service->requestRestore(backupFile());
    QTRY_COMPARE(completed.count(), 1);
    QVERIFY(!completed.first().first().toBool());
    QVERIFY(completed.first().at(1).toString().contains(QStringLiteral("预算")));
    QCOMPARE(safe.count(), 1);
    QVERIFY(safe.first().at(1).toBool());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    QCOMPARE(QDir(backupsDir()).entryList({QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files).size(), 0);
}

// 保证安装已提交但收尾尚未执行时退出，prepared日志与恢复点保留，重启不会自动恢复同步。
void BackupServiceTests::shutdownDuringInstalledRestorePreservesJournal()
{
    auto* service = BackupService::instance();
    QVERIFY(insertTask(QStringLiteral("备份旧库")) > 0);
    QVERIFY(service->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("当前保留项")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);
    auto operation = std::make_shared<BackupOperationControl>();
    std::atomic<bool> installed{false};
    int commits = 0;
    operation->m_checkpointForTest = [&](const char* stage) {
        if (std::strcmp(stage, "copy-after-commit") == 0 && ++commits == 3) {
            installed.store(true);
            while (!operation->stopped()) QThread::msleep(1);
        }
    };
    SyncController controller(SyncController::Platform{});
    controller.initialize();
    service->setRestorePreparationCallback([&](QString* error) { return controller.prepareForRestore(error); });
    service->m_nextOperationForTest = operation;
    const auto cleanup = qScopeGuard([&] {
        operation->requestStop();
        service->prepareForShutdown();
        service->setRestorePreparationCallback(nullptr);
    });
    QSignalSpy completed(service, &BackupService::restoreCompleted);
    QSignalSpy safe(service, &BackupService::restoreSyncCompleted);
    service->requestRestore(backupFile());
    QTRY_VERIFY(installed.load());
    QVERIFY(service->busy());
    QVERIFY(service->operationBlocksUi());
    QCOMPARE(completed.count(), 0);
    service->prepareForShutdown();
    QVERIFY(service->m_activeWorkers.isEmpty());
    QCOMPARE(completed.count(), 0);
    QCOMPARE(safe.count(), 0);
    QVERIFY(DatabaseManager::instance()->initialize(dbPath()));
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    SyncController restarted(SyncController::Platform{});
    restarted.initialize();
    QVERIFY(restarted.isRestoreStateUncertain());
    const auto points = QDir(backupsDir()).entryList({QStringLiteral("before-restore-*.tomatobackup")}, QDir::Files);
    QCOMPARE(points.size(), 1);
    QVERIFY(service->readBackupInfo(QDir(backupsDir()).filePath(points.first())).value(QStringLiteral("valid")).toBool());
}

// 保证同步备份入口不能夺走异步操作的取消身份，拒绝时不创建第二个目标文件。
void BackupServiceTests::synchronousBackupCannotReplaceActiveOperation()
{
    QVERIFY(insertTask(QStringLiteral("只允许一项备份")) > 0);
    auto* service = BackupService::instance();
    const auto cleanup = qScopeGuard([&] { service->prepareForShutdown(); });
    service->requestBackup(backupFile());
    QVERIFY(service->busy());
    const auto operation = service->m_operation;
    const QString other = m_tempDir->filePath(QStringLiteral("other.tomatobackup"));
    QVERIFY(!service->createBackup(other));
    QCOMPARE(service->m_operation, operation);
    QVERIFY(!QFileInfo::exists(other));
    service->cancelCurrentOperation();
    QTRY_VERIFY(!service->busy());
}

// 保证同步和异步恢复在调用准备回调、通知恢复开始之前，就已阻止第二项备份进入。
void BackupServiceTests::restoreAdmissionPrecedesReentrantCallbacks_data()
{
    QTest::addColumn<bool>("asynchronous");
    QTest::addColumn<bool>("duringPreparation");
    QTest::newRow("sync-preparation") << false << true;
    QTest::newRow("sync-started") << false << false;
    QTest::newRow("async-preparation") << true << true;
    QTest::newRow("async-started") << true << false;
}

// 保证恢复重入请求被拒绝且不替换取消身份，原恢复仍正确安装数据并在完成时释放准入。
void BackupServiceTests::restoreAdmissionPrecedesReentrantCallbacks()
{
    QFETCH(bool, asynchronous);
    QFETCH(bool, duringPreparation);
    BackupService service;
    service.configure(settingsPath(), backupsDir());
    QVERIFY(insertTask(QStringLiteral("备份里的任务")) > 0);
    QVERIFY(service.createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复应当移除的任务")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    QSemaphore releaseWorker;
    const auto original = std::make_shared<BackupOperationControl>();
    const auto unexpected = std::make_shared<BackupOperationControl>();
    // 旧实现会错误启动第二项工作；让它停在首次入口，断言失败也不会并发触碰正在恢复的库。
    unexpected->m_checkpointForTest = [&, first = true](const char* stage) mutable {
        if (qstrcmp(stage, "operation-start") == 0 && std::exchange(first, false)) {
            releaseWorker.acquire();
        }
    };
    QObject callbacks;
    const auto cleanup = qScopeGuard([&] {
        QObject::disconnect(&service, nullptr, &callbacks, nullptr);
        service.setRestorePreparationCallback({});
        unexpected->requestStop();
        releaseWorker.release();
        service.prepareForShutdown();
    });
    const QString other = m_tempDir->filePath(QStringLiteral("reentrant.tomatobackup"));
    int attempts = 0;
    bool sawBusy = false;
    bool sawBlocking = false;
    bool keptIdentity = false;
    bool internallyFinishedWhileBusy = false;
    const auto reenter = [&] {
        ++attempts;
        sawBusy = service.busy();
        sawBlocking = service.operationBlocksUi();
        service.m_nextOperationForTest = unexpected;
        service.requestBackup(other);
        service.m_nextOperationForTest.reset();
        keptIdentity = service.m_operation == original;
    };
    if (duringPreparation) {
        service.setRestorePreparationCallback([&](QString*) { reenter(); return true; });
    } else {
        connect(&service, &BackupService::restoreStarted, &callbacks, reenter);
    }
    connect(&service, &BackupService::restoreSyncCompleted, &callbacks, [&] {
        internallyFinishedWhileBusy = service.busy() && service.m_operation == original;
    });
    QSignalSpy backups(&service, &BackupService::backupCompleted);
    QSignalSpy restored(&service, &BackupService::restoreCompleted);
    service.m_nextOperationForTest = original;
    if (asynchronous) {
        service.requestRestore(backupFile());
        QTRY_COMPARE_WITH_TIMEOUT(restored.count(), 1, 15000);
    } else {
        QVERIFY(service.restoreBackup(backupFile()));
    }
    QCOMPARE(attempts, 1);
    QVERIFY(sawBusy);
    QVERIFY(sawBlocking);
    QVERIFY(keptIdentity);
    QCOMPARE(backups.count(), 1);
    QVERIFY(!backups.first().at(0).toBool());
    QVERIFY(!QFileInfo::exists(other));
    QCOMPARE(restored.count(), 1);
    QVERIFY(restored.first().at(0).toBool());
    QVERIFY(internallyFinishedWhileBusy);
    QVERIFY(!service.busy());
    QVERIFY(!service.operationBlocksUi());
    QVERIFY(!service.m_operation);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

// 保证同步手动、自动及替换前快照都占用同一操作准入，而不是只检查异步任务已有的busy。
void BackupServiceTests::synchronousSnapshotsReserveTheirOperation_data()
{
    QTest::addColumn<QString>("entry");
    QTest::newRow("manual") << QStringLiteral("manual");
    QTest::newRow("automatic") << QStringLiteral("automatic");
    QTest::newRow("before-sync") << QStringLiteral("before-sync");
}

// 保证同步快照执行期间的重入不能创建新目标或抢走原操作身份，成功及失败都会释放占用。
void BackupServiceTests::synchronousSnapshotsReserveTheirOperation()
{
    QFETCH(QString, entry);
    QVERIFY(insertTask(QStringLiteral("同步快照准入")) > 0);
    BackupService service;
    service.configure(settingsPath(), backupsDir());
    QSemaphore releaseWorker;
    const auto unexpected = std::make_shared<BackupOperationControl>();
    unexpected->m_checkpointForTest = [&, first = true](const char* stage) mutable {
        if (qstrcmp(stage, "operation-start") == 0 && std::exchange(first, false)) {
            releaseWorker.acquire();
        }
    };
    const auto cleanup = qScopeGuard([&] {
        unexpected->requestStop();
        releaseWorker.release();
        service.prepareForShutdown();
    });
    const auto original = std::make_shared<BackupOperationControl>();
    const QString other = m_tempDir->filePath(QStringLiteral("other.tomatobackup"));
    bool observed = false;
    bool occupied = false;
    bool keptIdentity = false;
    // 同步路径不运行事件循环，用现有入口检查点确定进入操作后才发起重入，不依赖时长猜测。
    original->m_checkpointForTest = [&](const char* stage) {
        if (observed || qstrcmp(stage, "operation-start") != 0) return;
        observed = true;
        occupied = service.busy();
        service.m_nextOperationForTest = unexpected;
        service.requestBackup(other);
        service.m_nextOperationForTest.reset();
        keptIdentity = service.m_operation == original;
    };
    service.m_nextOperationForTest = original;
    bool success = false;
    if (entry == QStringLiteral("manual")) success = service.createBackup(backupFile());
    else if (entry == QStringLiteral("automatic")) success = service.runAutoBackupIfDue();
    else { QString error; success = service.backupBeforeSyncReplace(&error); }
    QVERIFY(success);
    QVERIFY(observed);
    QVERIFY(occupied);
    QVERIFY(keptIdentity);
    QVERIFY(!QFileInfo::exists(other));
    QVERIFY(!service.busy());
    QVERIFY(!service.m_operation);

    // 失败出口也必须释放；自动备份先移除刚记录的周期，确保这次真的进入操作。
    if (entry == QStringLiteral("automatic")) {
        QSettings settings(settingsPath(), QSettings::IniFormat);
        settings.remove(QStringLiteral("backup/lastBackupIso"));
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }
    const auto cancelled = std::make_shared<BackupOperationControl>();
    cancelled->requestStop();
    service.m_nextOperationForTest = cancelled;
    if (entry == QStringLiteral("manual")) success = service.createBackup(backupFile());
    else if (entry == QStringLiteral("automatic")) success = service.runAutoBackupIfDue();
    else { QString error; success = service.backupBeforeSyncReplace(&error); }
    QVERIFY(!success);
    QVERIFY(!service.busy());
    QVERIFY(!service.operationBlocksUi());
    QVERIFY(service.operationText().isEmpty());
    QVERIFY(!service.m_operation);
}

// 保证三类状态通知都可以触发下一项工作，旧收尾不能再覆盖新任务的文字、遮罩或身份。
void BackupServiceTests::completionNotificationsPreserveReentrantOperation_data()
{
    QTest::addColumn<QString>("notification");
    QTest::newRow("busy") << QStringLiteral("busy");
    QTest::newRow("text") << QStringLiteral("text");
    QTest::newRow("blocks-ui") << QStringLiteral("blocks-ui");
}

// 保证通知观察到完整状态，并且通知中启动的新备份仍保持busy、遮罩和自己的取消身份。
void BackupServiceTests::completionNotificationsPreserveReentrantOperation()
{
    QFETCH(QString, notification);
    QVERIFY(insertTask(QStringLiteral("通知重入")) > 0);
    BackupService service;
    service.configure(settingsPath(), backupsDir());
    QSemaphore releaseWorker;
    const auto next = std::make_shared<BackupOperationControl>();
    next->m_checkpointForTest = [&, first = true](const char* stage) mutable {
        if (qstrcmp(stage, "operation-start") == 0 && std::exchange(first, false)) {
            releaseWorker.acquire();
        }
    };
    QObject callbacks;
    const auto cleanup = qScopeGuard([&] {
        QObject::disconnect(&service, nullptr, &callbacks, nullptr);
        next->requestStop();
        releaseWorker.release();
        service.prepareForShutdown();
    });
    bool consistent = true;
    bool started = false;
    QString nextText;
    const auto observe = [&](const QString& signal) {
        consistent = consistent && (service.busy()
            ? service.operationBlocksUi() && !service.operationText().isEmpty() && bool(service.m_operation)
            : !service.operationBlocksUi() && service.operationText().isEmpty() && !service.m_operation);
        if (signal == notification && !service.busy() && !started) {
            started = true;
            service.m_nextOperationForTest = next;
            service.requestBackup(m_tempDir->filePath(QStringLiteral("next.tomatobackup")));
            nextText = service.operationText();
        }
    };
    connect(&service, &BackupService::busyChanged, &callbacks, [&] { observe(QStringLiteral("busy")); });
    connect(&service, &BackupService::operationTextChanged, &callbacks, [&] { observe(QStringLiteral("text")); });
    connect(&service, &BackupService::operationBlocksUiChanged, &callbacks, [&] { observe(QStringLiteral("blocks-ui")); });
    QSignalSpy completed(&service, &BackupService::backupCompleted);
    service.requestBackup(backupFile());
    QVERIFY(service.busy());
    QTRY_COMPARE_WITH_TIMEOUT(completed.count(), 1, 15000);
    QVERIFY(completed.first().at(0).toBool());
    QVERIFY(started);
    QVERIFY(consistent);
    QVERIFY(service.busy());
    QVERIFY(service.operationBlocksUi());
    QVERIFY(!nextText.isEmpty());
    QCOMPARE(service.operationText(), nextText);
    QCOMPARE(service.m_operation, next);
    QVERIFY(service.m_activeWorkers.size() == 1);
}
