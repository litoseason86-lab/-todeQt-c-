#include <QDir>
#include <QRegularExpression>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <memory>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/RoutineRules.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/TaskManager.h"

// 设备间同步（050 阶段 2）的测试。
//
// 2a 部分只看一台设备：v18 的表结构，以及本机经由各服务的增删改是否被触发器正确记成
// 「字段版本 + 待发送」。触发器只认数据库里的写入，所以有些用例直接写 SQL，
// 那等于覆盖了所有不经过服务、却同样会写这些表的路径。
//
// 时钟：往 sync_runtime.test_now_ms 写值就能固定「此刻」，再把 sync_state.hlc 拨回 0，
// 版本号就完全由用例决定，不受跑测试时的真实时间影响。
namespace {

QSqlDatabase db()
{
    return DatabaseManager::instance()->database();
}

QVariant scalar(const QString& sql)
{
    QSqlQuery query(db());
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

int count(const QString& sql)
{
    return scalar(sql).toInt();
}

bool exec(const QString& sql)
{
    QSqlQuery query(db());
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return false;
    }
    return true;
}

// 固定时钟：此后本机改动的逻辑时间 = max(nowMs, 上一次 + 1)。
bool setClock(qint64 nowMs, bool resetLogicalTime = false)
{
    return exec(QStringLiteral("UPDATE sync_runtime SET test_now_ms = %1 WHERE singleton_id = 1").arg(nowMs))
        && (!resetLogicalTime || exec(QStringLiteral("UPDATE sync_state SET value = '0' WHERE key = 'hlc'")));
}

QString deviceId()
{
    return scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'device_id'")).toString();
}

QString syncIdOf(const QString& table, int id)
{
    return scalar(QStringLiteral("SELECT sync_id FROM %1 WHERE id = %2").arg(table).arg(id)).toString();
}

struct FieldVersion {
    bool exists = false;
    qint64 time = 0;
    QString device;
    qint64 baseTime = 0;
    QString baseDevice;
    bool pending = false;
};

FieldVersion versionOf(const QString& table, const QString& syncId, const QString& field)
{
    FieldVersion version;
    QSqlQuery query(db());
    query.prepare(QStringLiteral(
        "SELECT v_time, v_device, base_time, base_device, pending FROM sync_field_versions "
        "WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    query.bindValue(QStringLiteral(":field"), field);
    if (query.exec() && query.next()) {
        version.exists = true;
        version.time = query.value(0).toLongLong();
        version.device = query.value(1).toString();
        version.baseTime = query.value(2).toLongLong();
        version.baseDevice = query.value(3).toString();
        version.pending = query.value(4).toInt() == 1;
    }
    return version;
}

int versionCount(const QString& table, const QString& syncId)
{
    return count(QStringLiteral("SELECT COUNT(*) FROM sync_field_versions WHERE tbl = '%1' AND sync_id = '%2'")
                     .arg(table, syncId));
}

bool queued(const QString& table, const QString& syncId)
{
    return count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = '%1' AND sync_id = '%2'")
                     .arg(table, syncId)) == 1;
}

QString tombstoneKind(const QString& table, const QString& syncId)
{
    return scalar(QStringLiteral("SELECT kind FROM sync_tombstones WHERE tbl = '%1' AND sync_id = '%2'")
                      .arg(table, syncId)).toString();
}

// 模拟「这批已经写进同步文件」：清空待发送标记。2b 以后由 SyncStore 的确认发送完成，这里先直接改表。
bool markEverythingSent()
{
    return exec(QStringLiteral("UPDATE sync_field_versions SET pending = 0"))
        && exec(QStringLiteral("DELETE FROM sync_outbox"));
}

QHash<QString, QString> triggerSql()
{
    QHash<QString, QString> result;
    QSqlQuery query(db());
    query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"));
    while (query.next()) {
        result.insert(query.value(0).toString(), query.value(1).toString());
    }
    return result;
}

QDate today()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

} // namespace

class SyncTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    // 2a：表结构与触发器
    void freshDatabaseHasSyncInfrastructure();
    void serviceWritesAreVersionedPerField();
    void logicalClockNeverGoesBackwards();
    void presetCategoriesUseSlotIdentityAndMinimalVersions();
    void routineInstanceUsesDeterministicIdentityAndMinimalVersions();
    void focusSessionIsPublishedOnlyAfterItEnds();
    void applyingRemoteChangesSuppressesTriggers();
    void migrationFromV17BackfillsIdentitiesAndQueuesRecords();
    void v5RebuildKeepsSyncIdsAndDoesNotRequeue();
    void tamperedTriggerIsRebuiltOnStartup();
    void missingSyncTableDoesNotBlockStartup();

private:
    QTemporaryDir m_preferences;
    std::unique_ptr<QTemporaryDir> m_data;
};

void SyncTests::initTestCase()
{
    QVERIFY(m_preferences.isValid());
    // AppSettings 单例只落到临时 INI：例行生成要读日界点，不能读写真实偏好。
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoSyncTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SyncTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    AppSettings::instance()->setDayStartHour(4);
}

void SyncTests::init()
{
    m_data = std::make_unique<QTemporaryDir>();
    QVERIFY(m_data->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_data->filePath(QStringLiteral("sync.sqlite"))));
}

void SyncTests::cleanup()
{
    DatabaseManager::instance()->close();
    m_data.reset();
}

void SyncTests::freshDatabaseHasSyncInfrastructure()
{
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")).toInt(), 18);
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM pragma_table_info('%1') WHERE name = 'sync_id'")
                           .arg(table.name)) == 1, qPrintable(table.name));
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' "
                                      "AND name = 'idx_%1_sync_id'").arg(table.name)) == 1,
                 qPrintable(table.name));
    }
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '%1'")
                           .arg(name)) == 1, qPrintable(name));
    }

    // 设备标识是 32 位小写十六进制；纪元从 0 开始；运行标记默认「不在应用远端改动」。
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(deviceId()).hasMatch());
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'epoch'")).toString(),
             QStringLiteral("0"));
    QVERIFY(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'hlc'")).toLongLong() > 0);
    QCOMPARE(scalar(QStringLiteral("SELECT applying FROM sync_runtime WHERE singleton_id = 1")).toInt(), 0);

    // 库里的触发器恰好是规范的那一组，文本逐字一致。
    const QHash<QString, QString> canonical = SyncSchema::canonicalTriggerSql();
    QCOMPARE(canonical.size(), SyncSchema::triggers().size());
    QCOMPARE(triggerSql(), canonical);
}

void SyncTests::serviceWritesAreVersionedPerField()
{
    QVERIFY(setClock(1000, true));
    const QString me = deviceId();
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("写论文"), today(), -1, 30,
                                                           QStringLiteral("第一章"));
    QVERIFY(taskId > 0);
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(id).hasMatch());

    // 新建：每个同步列一行版本，都是这一次的逻辑时间和本机，等着发出去。
    const SyncSchema::Table* tasks = SyncSchema::table(QStringLiteral("tasks"));
    QVERIFY(tasks);
    QCOMPARE(versionCount(QStringLiteral("tasks"), id), int(tasks->fields.size()));
    for (const SyncSchema::Field& field : tasks->fields) {
        const FieldVersion version = versionOf(QStringLiteral("tasks"), id, field.column);
        QVERIFY2(version.time == 1000 && version.device == me && version.pending, qPrintable(field.column));
        QCOMPARE(version.baseTime, 0);
    }
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 发出去之后只改标题：只有标题记新版本，base 记下对方已经见过的那一版；其余列不动。
    QVERIFY(markEverythingSent());
    QVERIFY(setClock(2000));
    QVERIFY(TaskManager::instance()->updateTask(taskId, QStringLiteral("写论文（第二稿）"), -1, today()));
    FieldVersion title = versionOf(QStringLiteral("tasks"), id, QStringLiteral("title"));
    QCOMPARE(title.time, 2000);
    QCOMPARE(title.baseTime, 1000);
    QCOMPARE(title.baseDevice, me);
    QVERIFY(title.pending);
    const FieldVersion notes = versionOf(QStringLiteral("tasks"), id, QStringLiteral("notes"));
    QCOMPARE(notes.time, 1000);
    QVERIFY(!notes.pending);
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 还没发出去又改一次：对方见过的仍是 1000 那一版，base 保持不动。
    QVERIFY(setClock(3000));
    QVERIFY(TaskManager::instance()->updateTask(taskId, QStringLiteral("写论文（第三稿）"), -1, today()));
    title = versionOf(QStringLiteral("tasks"), id, QStringLiteral("title"));
    QCOMPARE(title.time, 3000);
    QCOMPARE(title.baseTime, 1000);

    // 值没变的更新（同一天内再「改期」到同一天）不产生新版本。
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->moveTasksToDate({taskId}, today()));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    // 删除：留下删除记录（普通删除），版本行清掉，记录重新进待发送队列。
    QVERIFY(setClock(4000));
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), id), QStringLiteral("delete"));
    QCOMPARE(scalar(QStringLiteral("SELECT v_time FROM sync_tombstones WHERE sync_id = '%1'").arg(id)).toLongLong(),
             4000);
    QCOMPARE(versionCount(QStringLiteral("tasks"), id), 0);
    QVERIFY(queued(QStringLiteral("tasks"), id));
}

void SyncTests::logicalClockNeverGoesBackwards()
{
    QVERIFY(setClock(5000, true));
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("时钟"), today(), -1, 0, QString());
    QVERIFY(taskId > 0);
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("title")).time, 5000);

    // 系统时钟被往回拨：新版本仍然排在旧版本后面（取「上一次 + 1」），不会因为改了钟就输给自己的旧值。
    QVERIFY(setClock(100));
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time, 5001);
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, false));
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time, 5002);
}

void SyncTests::presetCategoriesUseSlotIdentityAndMinimalVersions()
{
    // 两台设备建库时各自预置同一组科目：按位置取身份，版本取最小值，谁也不覆盖谁改过的名字。
    for (int slot = 1; slot <= 5; ++slot) {
        const QString id = SyncSchema::presetCategorySyncId(slot);
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE is_preset = 1 "
                                      "AND display_order = %1 AND sync_id = '%2'").arg(slot).arg(id)), 1);
        const FieldVersion name = versionOf(QStringLiteral("categories"), id, QStringLiteral("name"));
        QVERIFY(name.exists);
        QCOMPARE(name.time, 0);
        QCOMPARE(name.device, QString());
    }

    // 改名是真实修改，用真实版本；自定义科目用随机身份和真实版本。
    QVERIFY(setClock(7000, true));
    const int mathId = scalar(QStringLiteral("SELECT id FROM categories WHERE sync_id = 'preset-1'")).toInt();
    QVERIFY(CategoryManager::instance()->updateCategory(mathId, QStringLiteral("高等数学"),
                                                        QStringLiteral("#d4a574")));
    const FieldVersion renamed = versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"),
                                           QStringLiteral("name"));
    QCOMPARE(renamed.time, 7000);
    QCOMPARE(renamed.device, deviceId());
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"), QStringLiteral("color")).time, 0);

    const int customId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(customId > 0);
    const QString custom = syncIdOf(QStringLiteral("categories"), customId);
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(custom).hasMatch());
    QCOMPARE(versionOf(QStringLiteral("categories"), custom, QStringLiteral("name")).time, 7001);
}

void SyncTests::routineInstanceUsesDeterministicIdentityAndMinimalVersions()
{
    QVERIFY(setClock(9000, true));
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    const QString routine = scalar(QStringLiteral("SELECT sync_id FROM routines WHERE title = '背单词'")).toString();
    QVERIFY(!routine.isEmpty());

    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    const int taskId = scalar(QStringLiteral("SELECT id FROM tasks WHERE routine_generated = 1")).toInt();
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    // 两台设备各自生成的同一天实例，身份相同。
    QCOMPARE(id, SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate)));
    // 生成出来的默认值版本取最小值：另一台上已经完成的同一条不会被这份盖掉。
    const SyncSchema::Table* tasks = SyncSchema::table(QStringLiteral("tasks"));
    for (const SyncSchema::Field& field : tasks->fields) {
        const FieldVersion version = versionOf(QStringLiteral("tasks"), id, field.column);
        QVERIFY2(version.exists && version.time == 0 && version.device.isEmpty(), qPrintable(field.column));
    }
    // 仍然要发出去：另一台那天没打开过应用，就只能靠这一份补上当天的实例。
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 在实例上的真实操作用真实版本，赢过另一台生成的默认值。
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time > 9000);
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("title")).time, 0);
}

void SyncTests::focusSessionIsPublishedOnlyAfterItEnds()
{
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("专注"), today(), -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(markEverythingSent());

    // 开始专注时落库的那一行：有身份，但不记版本、不进队列。它只属于本机的计时器。
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '2026-09-30T10:00:00', 1)").arg(taskId)));
    const int running = scalar(QStringLiteral("SELECT MAX(id) FROM focus_sessions")).toInt();
    const QString runningId = syncIdOf(QStringLiteral("focus_sessions"), running);
    QVERIFY(!runningId.isEmpty());
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), runningId), 0);
    QVERIFY(!queued(QStringLiteral("focus_sessions"), runningId));

    // 丢弃或清理进行中的行（FocusTimer 的 discard 与孤儿清理都是这样删的）：不留删除记录。
    // 对方从来没见过它，发一条删除过去没有意义。
    QVERIFY(exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = %1").arg(running)));
    QVERIFY(tombstoneKind(QStringLiteral("focus_sessions"), runningId).isEmpty());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    // 结束的那一刻（FocusTimer 一条 UPDATE 写结束时刻、时长和完整番茄）才整条发布。
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '2026-09-30T11:00:00', 1)").arg(taskId)));
    const int finished = scalar(QStringLiteral("SELECT MAX(id) FROM focus_sessions")).toInt();
    const QString finishedId = syncIdOf(QStringLiteral("focus_sessions"), finished);
    QVERIFY(setClock(12000, true));
    QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET end_time = '2026-09-30T11:25:00', duration = 1500, "
                                "pomodoro_completed = 1 WHERE id = %1").arg(finished)));
    const SyncSchema::Table* sessions = SyncSchema::table(QStringLiteral("focus_sessions"));
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), finishedId), int(sessions->fields.size()));
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("task_id")).time, 12000);
    QVERIFY(queued(QStringLiteral("focus_sessions"), finishedId));

    // 之后在历史里改时长：只记这一列。
    QVERIFY(markEverythingSent());
    QVERIFY(setClock(13000));
    QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET duration = 1200 WHERE id = %1").arg(finished)));
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("duration")).time, 13000);
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("start_time")).time, 12000);

    // 删掉已结束的记录：留删除记录，发给对方。
    QVERIFY(exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = %1").arg(finished)));
    QCOMPARE(tombstoneKind(QStringLiteral("focus_sessions"), finishedId), QStringLiteral("delete"));

    // 休息记录落库时就是完整的，立即发布。
    QVERIFY(exec(QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                "VALUES ('2026-09-30T11:25:00', '2026-09-30T11:30:00', 300, 0)")));
    const QString restId = syncIdOf(QStringLiteral("rest_sessions"),
                                    scalar(QStringLiteral("SELECT MAX(id) FROM rest_sessions")).toInt());
    QCOMPARE(versionCount(QStringLiteral("rest_sessions"), restId), 4);
    QVERIFY(queued(QStringLiteral("rest_sessions"), restId));
}

void SyncTests::applyingRemoteChangesSuppressesTriggers()
{
    QVERIFY(markEverythingSent());
    // 应用远端改动时同一事务里置位：收到的改动不能被当成本机修改再发回去。
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("INSERT INTO tasks (title, date, completed, display_order, sync_id) "
                                "VALUES ('远端来的', '2026-09-30', 0, 1, 'remote-task')")));
    QVERIFY(exec(QStringLiteral("UPDATE tasks SET title = '远端改的' WHERE sync_id = 'remote-task'")));
    QVERIFY(exec(QStringLiteral("DELETE FROM tasks WHERE sync_id = 'remote-task'")));
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1")));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_field_versions WHERE sync_id = 'remote-task'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_tombstones")), 0);
}

void SyncTests::migrationFromV17BackfillsIdentitiesAndQueuesRecords()
{
    // 用当前代码建出数据，再把同步结构整个拆掉、版本号退回 17，就是一份 v17 的库。
    const QString date = today().toString(Qt::ISODate);
    const int englishId = scalar(QStringLiteral("SELECT id FROM categories WHERE sync_id = 'preset-2'")).toInt();
    QVERIFY(CategoryManager::instance()->updateCategory(englishId, QStringLiteral("英语阅读"),
                                                        QStringLiteral("#c9956e")));
    const int customId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(customId > 0);
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), customId, RoutineRules::kEveryDayMask));
    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("写代码"), today(), customId, 0, QString());
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                "VALUES (%1, '%2T09:00:00', '%2T09:25:00', 1500, 1)").arg(taskId).arg(date)));
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '%2T10:00:00', 1)").arg(taskId).arg(date)));
    QVERIFY(exec(QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                "VALUES ('%1T09:25:00', '%1T09:30:00', 300, 0)").arg(date)));

    for (const auto& trigger : SyncSchema::triggers()) {
        QVERIFY(exec(QStringLiteral("DROP TRIGGER %1").arg(trigger.first)));
    }
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        QVERIFY(exec(QStringLiteral("DROP TABLE %1").arg(name)));
    }
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QVERIFY(exec(QStringLiteral("DROP INDEX idx_%1_sync_id").arg(table.name)));
        QVERIFY(exec(QStringLiteral("ALTER TABLE %1 DROP COLUMN sync_id").arg(table.name)));
    }
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 17")));

    const QDir dir = QFileInfo(db().databaseName()).absoluteDir();
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const int snapshotsBefore = dir.entryList(pattern, QDir::Files).size();
    QVERIFY(DatabaseManager::instance()->createTables());

    // 升级前留了一份快照：v18 之后旧版本应用打不开这个库，想退回只能靠它。
    QCOMPARE(dir.entryList(pattern, QDir::Files).size(), snapshotsBefore + 1);
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")).toInt(), 18);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());

    // 每一行都有身份，且互不相同。
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE sync_id IS NULL OR sync_id = ''")
                           .arg(table.name)), 0);
        QCOMPARE(count(QStringLiteral("SELECT COUNT(DISTINCT sync_id) FROM %1").arg(table.name)),
                 count(QStringLiteral("SELECT COUNT(*) FROM %1").arg(table.name)));
    }

    // 预置科目按位置取固定身份。没改过的名字版本取最小值；改过的（英语 → 英语阅读）用真实版本，
    // 同步时才不会被另一台上没改过的默认名盖掉。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id LIKE 'preset-%'")), 5);
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"), QStringLiteral("name")).time, 0);
    QVERIFY(versionOf(QStringLiteral("categories"), QStringLiteral("preset-2"), QStringLiteral("name")).time > 0);
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-2"), QStringLiteral("color")).time, 0);

    // 例行实例按「例行身份 + 日期」回填。
    const QString routine = scalar(QStringLiteral("SELECT sync_id FROM routines")).toString();
    QCOMPARE(scalar(QStringLiteral("SELECT sync_id FROM tasks WHERE routine_generated = 1")).toString(),
             SyncSchema::routineInstanceSyncId(routine, date));

    // 首次全量发送：发布条件满足的记录全部入队；进行中的专注不入队、也没有版本。
    const int published = count(QStringLiteral("SELECT COUNT(*) FROM categories"))
        + count(QStringLiteral("SELECT COUNT(*) FROM routines")) + count(QStringLiteral("SELECT COUNT(*) FROM tasks"))
        + count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NOT NULL"))
        + count(QStringLiteral("SELECT COUNT(*) FROM rest_sessions"));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), published);
    const QString running = scalar(QStringLiteral("SELECT sync_id FROM focus_sessions WHERE end_time IS NULL")).toString();
    QVERIFY(!queued(QStringLiteral("focus_sessions"), running));
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), running), 0);

    // 升级后本机的修改照常记版本。
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(queued(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId)));
}

void SyncTests::v5RebuildKeepsSyncIdsAndDoesNotRequeue()
{
    const int first = TaskManager::instance()->createTask(QStringLiteral("第一条"), today(), -1, 0, QString());
    const int second = TaskManager::instance()->createTask(QStringLiteral("第二条"), today(), -1, 0, QString());
    QVERIFY(first > 0 && second > 0);
    const QString firstId = syncIdOf(QStringLiteral("tasks"), first);
    const QString secondId = syncIdOf(QStringLiteral("tasks"), second);
    QVERIFY(markEverythingSent());

    // 版本号拨回 4 会触发 v5 整表重建（createTables 的结构守卫同样会在外键不对时触发它）。
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 4")));
    QVERIFY(DatabaseManager::instance()->createTables());

    // 身份原样搬过去；唯一索引和触发器被重建带走后又补了回来。
    QCOMPARE(syncIdOf(QStringLiteral("tasks"), first), firstId);
    QCOMPARE(syncIdOf(QStringLiteral("tasks"), second), secondId);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_tasks_sync_id'")), 1);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    // 早已发出去的记录不会因为重跑 v18 再整库排一遍队。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    QVERIFY(TaskManager::instance()->setTaskCompleted(first, true));
    QVERIFY(queued(QStringLiteral("tasks"), firstId));
}

void SyncTests::tamperedTriggerIsRebuiltOnStartup()
{
    // 触发器被换成空壳（旧版本留下的、或外部改过的）：启动时按规范文本比较，不一致就重建。
    QVERIFY(exec(QStringLiteral("DROP TRIGGER tasks_sync_au")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER tasks_sync_au AFTER UPDATE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER tasks_sync_obsolete AFTER DELETE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER someone_elses AFTER DELETE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QHash<QString, QString> expected = SyncSchema::canonicalTriggerSql();
    // 不符合本应用命名约定的触发器不归我们管，原样留着。
    expected.insert(QStringLiteral("someone_elses"), triggerSql().value(QStringLiteral("someone_elses")));
    QCOMPARE(triggerSql(), expected);
    QVERIFY(exec(QStringLiteral("DROP TRIGGER someone_elses")));

    const int taskId = TaskManager::instance()->createTask(QStringLiteral("重建后"), today(), -1, 0, QString());
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(queued(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId)));
}

void SyncTests::missingSyncTableDoesNotBlockStartup()
{
    // 删掉一个预置科目（按远端改动的方式，不留删除记录），再拆掉待发送队列表：
    // 下次启动时，迁移链前面会补回预置科目——触发器此时若还在，就会因为队列表不存在而让启动失败。
    // 应用远端删除时同步核心会连同版本行一起清掉，这里照做，否则残留的版本会让迁移以为它早已发过。
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("DELETE FROM categories WHERE sync_id = 'preset-5'")));
    QVERIFY(exec(QStringLiteral("DELETE FROM sync_field_versions WHERE sync_id = 'preset-5'")));
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("DROP TABLE sync_outbox")));

    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id = 'preset-5'")), 1);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    // 补回来的预置科目仍按默认值处理：版本取最小值，并照常入队。
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-5"), QStringLiteral("name")).time, 0);
    QVERIFY(queued(QStringLiteral("categories"), QStringLiteral("preset-5")));
}

QTEST_MAIN(SyncTests)
#include "SyncTests.moc"
