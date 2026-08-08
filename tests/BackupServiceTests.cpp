#include <QDir>
#include <QFile>
#include <QSettings>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/BackupService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
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

private slots:
    void init();
    void cleanup();

    void createBackupProducesSingleFileNoTemp();
    void backupRejectsRuntimeProtectedDestinations();
    void backupCapturesAllBusinessTables();
    void backupWorksUnderWalMode();
    void corruptedBackupIsRejected();
    void backupMissingRequiredTableIsRejected();
    void higherSchemaVersionIsRejected();
    void formatVersionMismatchIsRejected();
    void schemaMetadataMismatchIsRejected();
    void restoreCreatesPreRestoreSnapshot();
    void repeatedRestoresCapPreRestoreSnapshots();
    void restoreMatchesTaskAndSessionCounts();
    void restorePreservesCountdownGoals();
    void restoreRestoresSettingsValue();
    void restoreRemovesSettingsMissingFromBackup();
    void restoreFailureKeepsOriginalDatabaseIntact();
    void activeTimerBlocksRestore();
    void asyncRestoreReloadsTaskSnapshots();
    void asyncRestoreRollbackReopensDatabaseWhenCopyFails();
    void asyncRestoreRollbackRestoresOriginalTaskCount();
    void olderSchemaBackupRestoresAndMigrates();
    void autoBackupRespectsIntervalAndRetention();
    void autoBackupDisabledDoesNothing();
    void shutdownWaitsForAsyncWorkers();

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
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
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
            QStringLiteral("focus_sessions"), QStringLiteral("countdown_goals")
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
}

void BackupServiceTests::olderSchemaBackupRestoresAndMigrates()
{
    QVERIFY(insertTask(QStringLiteral("旧版任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    // 伪造成较旧 schema 版本，恢复后应能被迁移链升级到当前版本。
    setBackupSchemaVersion(backupFile(), 5);

    const QVariantMap info = BackupService::instance()->readBackupInfo(backupFile());
    QCOMPARE(info.value(QStringLiteral("valid")).toBool(), true);

    QVERIFY(BackupService::instance()->restoreBackup(backupFile()));

    QSqlQuery version(DatabaseManager::instance()->database());
    QVERIFY(version.exec(QStringLiteral("PRAGMA user_version")) && version.next());
    QCOMPARE(version.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
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

void BackupServiceTests::shutdownWaitsForAsyncWorkers()
{
    QVERIFY(insertTask(QStringLiteral("退出时的异步备份任务")) > 0);

    BackupService* service = BackupService::instance();
    service->requestBackup(backupFile());
    QVERIFY(service->busy());

    // 不处理事件循环就进入退出收束：只有 waitForFinished() 真正等待了后台任务，
    // 这里才能看到完整文件；随后再次调用必须是无副作用的幂等操作。
    service->prepareForShutdown();
    QVERIFY(!service->busy());
    QVERIFY(QFileInfo::exists(backupFile()));
    service->prepareForShutdown();

    const QString ignoredPath = m_tempDir->filePath(QStringLiteral("after-shutdown.tomatobackup"));
    service->requestBackup(ignoredPath);
    QVERIFY(!service->busy());
    QVERIFY(!QFileInfo::exists(ignoredPath));
}

QTEST_MAIN(BackupServiceTests)
#include "BackupServiceTests.moc"
