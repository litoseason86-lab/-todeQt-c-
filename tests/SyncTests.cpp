#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <functional>
#include <memory>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
// FocusTimer 声明 friend class SyncTests，用例之间据此复位单例计时器。
#include "../src/services/FocusTimer.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/RoutineRules.h"
#include "../src/services/SyncNotifier.h"
#include "../src/services/SyncRecord.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/SyncStore.h"
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

// ── 两台设备（2b 起） ──
//
// 每台设备一个临时库：先用应用自己的初始化建出完整结构（含 v18 同步表与触发器，各自一个设备标识），
// 再单独开一条连接当作这台设备。本机的增删改大多直接写 SQL：同步只依赖数据库里的触发器，
// 任何写入路径都会被它兜住。需要服务层语义（删除科目、收回例行……）的用例用 withServices 临时切过去。
struct Device {
    QString path;
    QString connection;
    QString id;
};

QSqlDatabase deviceDb(const Device& device)
{
    return QSqlDatabase::database(device.connection);
}

bool exec(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return false;
    }
    return true;
}

QVariant scalar(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

int count(const Device& device, const QString& sql)
{
    return scalar(device, sql).toInt();
}

bool setClock(const Device& device, qint64 nowMs)
{
    return exec(device, QStringLiteral("UPDATE sync_runtime SET test_now_ms = %1 WHERE singleton_id = 1").arg(nowMs));
}

// 新建一条任务（排在当天末尾，与服务层一致），返回它的 sync_id。
QString addTask(const Device& device, const QString& title, const QString& date = QStringLiteral("2026-09-30"))
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES (:title, :date, 0, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), date);
    query.bindValue(QStringLiteral(":orderDate"), date);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM tasks WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

QVariant taskValue(const Device& device, const QString& syncId, const QString& column)
{
    return scalar(device, QStringLiteral("SELECT %1 FROM tasks WHERE sync_id = '%2'").arg(column, syncId));
}

QStringList taskTitles(const Device& device)
{
    QStringList titles;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT title FROM tasks ORDER BY title, id"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    return titles;
}

// syncId 为空时由触发器分配随机身份；需要固定「谁并进谁」的用例自己指定身份。
QString addCategory(const Device& device, const QString& name, const QString& syncId = QString())
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO categories (name, color, is_preset, display_order, sync_id) "
        "VALUES (:name, '#123456', 0, (SELECT COALESCE(MAX(display_order), 0) + 1 FROM categories), :syncId)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":syncId"), syncId.isEmpty() ? QVariant() : QVariant(syncId));
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM categories WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

qint64 localIdOf(const Device& device, const QString& table, const QString& syncId)
{
    return scalar(device, QStringLiteral("SELECT id FROM %1 WHERE sync_id = '%2'").arg(table, syncId)).toLongLong();
}

// 把任务挂到某个科目下（按服务层的写法，同时写科目名文本）。
bool setTaskCategory(const Device& device, const QString& taskSyncId, const QString& categorySyncId)
{
    return exec(device, QStringLiteral(
        "UPDATE tasks SET category_id = c.id, category = c.name FROM categories c "
        "WHERE c.sync_id = '%1' AND tasks.sync_id = '%2'").arg(categorySyncId, taskSyncId));
}

// 任务所属科目的 sync_id（没有科目时为空）。
QString taskCategory(const Device& device, const QString& taskSyncId)
{
    return scalar(device, QStringLiteral("SELECT c.sync_id FROM tasks t LEFT JOIN categories c ON c.id = t.category_id "
                                         "WHERE t.sync_id = '%1'").arg(taskSyncId)).toString();
}

QStringList customCategoryNames(const Device& device)
{
    QStringList names;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT name FROM categories WHERE is_preset = 0 ORDER BY name"));
    while (query.next()) {
        names.append(query.value(0).toString());
    }
    return names;
}

// 一天里的任务按显示顺序排出来的 sync_id，比较两台设备的顺序是否一致。
QStringList dayOrder(const Device& device, const QString& date)
{
    QStringList ids;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT sync_id FROM tasks WHERE date = '%1' ORDER BY completed, display_order, id")
                   .arg(date));
    while (query.next()) {
        ids.append(query.value(0).toString());
    }
    return ids;
}

// 把一份快照写成可比较的文字：每条记录一行，字段按名字排序，带上值和版本（不带 base，它只影响日志）。
// 两台设备导出的快照文字相同，就说明它们的同步数据完全一致。
QStringList describe(const SyncBatch& snapshot)
{
    QStringList lines;
    for (const SyncRecord& record : snapshot.records) {
        QStringList parts{record.table, record.syncId};
        if (record.deleted) {
            parts << QStringLiteral("deleted:%1:%2@%3/%4")
                         .arg(record.deleteKind, record.mergedInto)
                         .arg(record.deleteVersion.time)
                         .arg(record.deleteVersion.device);
        }
        QStringList fields = record.fields.keys();
        fields.sort();
        for (const QString& field : fields) {
            const SyncFieldValue value = record.fields.value(field);
            parts << QStringLiteral("%1=%2@%3/%4")
                         .arg(field, SyncJson::canonicalValue(value.value))
                         .arg(value.version.time)
                         .arg(value.version.device);
        }
        lines << parts.join(QLatin1Char('|'));
    }
    for (const SyncSettingRecord& setting : snapshot.settings) {
        lines << QStringLiteral("setting|%1=%2@%3/%4")
                     .arg(setting.key, setting.value)
                     .arg(setting.version.time)
                     .arg(setting.version.device);
    }
    lines.sort();
    return lines;
}

// 快照经过一次 JSON：写进云盘文件再读回来，确认文件格式带得全。
SyncBatch throughJson(const SyncBatch& batch)
{
    SyncBatch parsed;
    QString error;
    const QByteArray bytes = QJsonDocument(SyncJson::toJson(batch)).toJson(QJsonDocument::Compact);
    if (!SyncJson::fromJson(QJsonDocument::fromJson(bytes).object(), &parsed, &error)) {
        qWarning() << "snapshot json failed:" << error;
    }
    return parsed;
}

// 按发生顺序记下各服务发出的刷新信号。它是连接的上下文对象，析构时连接自动断开，不会漏到别的用例。
class SignalRecorder : public QObject
{
public:
    QStringList events;

    SignalRecorder()
    {
        connect(TaskManager::instance(), &TaskManager::taskDeleted, this,
                [this](int taskId) { events << QStringLiteral("taskDeleted:%1").arg(taskId); });
        connect(TaskManager::instance(), &TaskManager::tasksChanged, this,
                [this] { events << QStringLiteral("tasksChanged"); });
        connect(CategoryManager::instance(), &CategoryManager::categoriesChanged, this,
                [this] { events << QStringLiteral("categoriesChanged"); });
        connect(RoutineManager::instance(), &RoutineManager::routinesChanged, this,
                [this] { events << QStringLiteral("routinesChanged"); });
        connect(FocusHistoryService::instance(), &FocusHistoryService::historyChanged, this,
                [this] { events << QStringLiteral("historyChanged"); });
        connect(AppSettings::instance(), &AppSettings::dayStartHourChanged, this,
                [this] { events << QStringLiteral("dayStartHourChanged"); });
    }
};

// 对方（另一台设备）发来的一条删除记录。
SyncRecord remoteDeletion(const QString& table, const QString& syncId, const SyncVersion& version)
{
    SyncRecord record;
    record.table = table;
    record.syncId = syncId;
    record.deleted = true;
    record.deleteVersion = version;
    record.deleteKind = QStringLiteral("delete");
    return record;
}

int logCount(const Device& device, const QString& kind = QString())
{
    return kind.isEmpty() ? count(device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
                          : count(device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = '%1'")
                                              .arg(kind));
}

// 假云盘：临时文件夹。每台设备只写自己的子目录 devices/<设备>/changes/<序号>.json（与正式方案同一布局），
// 读对方目录里本机还没应用过的文件。游标记在内存里，改它就能模拟「确认丢了、再读一遍」。
class FakeCloud
{
public:
    explicit FakeCloud(QString root) : m_root(std::move(root)) {}

    // 把这台设备的待发送改动写成一个文件并确认发送，返回写出的记录数。
    int publish(const Device& device)
    {
        SyncStore store(device.connection);
        const SyncBatch batch = store.collectPending();
        if (batch.isEmpty()) {
            return 0;
        }
        const QString dir = QStringLiteral("%1/devices/%2/changes").arg(m_root, batch.device);
        QDir().mkpath(dir);
        const int sequence = ++m_sequence[batch.device];
        QFile file(QStringLiteral("%1/%2.json").arg(dir).arg(sequence, 8, 10, QLatin1Char('0')));
        if (!file.open(QIODevice::WriteOnly)) {
            return -1;
        }
        file.write(QJsonDocument(SyncJson::toJson(batch)).toJson(QJsonDocument::Compact));
        file.close();
        return store.acknowledge(batch) ? int(batch.records.size() + batch.settings.size()) : -1;
    }

    // 按序应用对方写出、本机还没应用过的文件。某个文件应用失败就停在那里，下次从它重试。
    QList<SyncStore::ApplyResult> pull(const Device& device)
    {
        SyncStore store(device.connection);
        QList<SyncStore::ApplyResult> results;
        const QDir devices(m_root + QStringLiteral("/devices"));
        for (const QString& source : devices.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
            if (source == device.id) {
                continue;
            }
            const QDir changes(devices.filePath(source + QStringLiteral("/changes")));
            for (const QString& name : changes.entryList({QStringLiteral("*.json")}, QDir::Files, QDir::Name)) {
                const int sequence = name.section(QLatin1Char('.'), 0, 0).toInt();
                if (sequence <= m_cursor[device.id].value(source)) {
                    continue;
                }
                QFile file(changes.filePath(name));
                SyncBatch batch;
                QString error = QStringLiteral("读不开同步文件");
                if (!file.open(QIODevice::ReadOnly)
                    || !SyncJson::fromJson(QJsonDocument::fromJson(file.readAll()).object(), &batch, &error)) {
                    SyncStore::ApplyResult failed;
                    failed.error = error;
                    results.append(failed);
                    break;
                }
                const SyncStore::ApplyResult result = store.applyRemote(batch);
                results.append(result);
                if (!result.ok) {
                    break;
                }
                m_cursor[device.id][source] = sequence;
            }
        }
        return results;
    }

    // 模拟「应用了但确认丢了」（断线、被系统挂起）：把 reader 对 source 的游标退回，下次会重读这些文件。
    void rewind(const Device& reader, const Device& source, int sequence = 0)
    {
        m_cursor[reader.id][source.id] = sequence;
    }

private:
    QString m_root;
    QHash<QString, int> m_sequence;
    QHash<QString, QHash<QString, int>> m_cursor;
};

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

    // 2b：读出与应用（两台设备）
    void batchSurvivesJsonRoundTrip();
    void insertUpdateDeleteReachOtherDevice();
    void editsOfDifferentFieldsAreBothKept();
    void concurrentEditsOfSameFieldConvergeAndAreLogged();
    void sequentialEditsAcrossDevicesAreNotConflicts();
    void deleteWinsOverConcurrentEdit_deleteArrivesFirst();
    void deleteWinsOverConcurrentEdit_editArrivesFirst();
    void concurrentCreatesStayTwoRecords();
    void redeliveredBatchesChangeNothing();
    void editDuringSendIsNotLost();
    void causalEditWinsDespiteClockSkew();
    void sameLogicalTimeConvergesByDevice();
    void badRecordIsSkippedWithoutBlockingBatch();
    void remoteTaskDeletionKeepsItsSessions();
    void runningSessionIsNeverSent();
    void batchFromOtherEpochOrSameDeviceIsRejected();

    // 2c：引用与去重（sol6 审查复现过的卡死、冲突场景）
    void sessionOnRemotelyDeletedTaskIsKeptDetached();
    void taskUnderRemotelyDeletedCategoryBecomesUncategorized();
    void renamedCategoryThenRecreatedNameSyncs();
    void renameCollidingWithOtherSidesNewCategoryMerges();
    void sameNameCategoriesCreatedOnBothSidesMerge();
    void swappedCategoryNamesAreNotMerged();
    void mergeReachesSideThatDidNotCollide();
    void presetsRenamedToSameNameGetSuffix();
    void sameDayTasksAreRenumberedWithoutMigration();
    void corruptMergeChainDoesNotHang();

    // 2d：例行与逻辑日起点
    void reclaimedInstanceIsSoftDeletedAndRegenerates();
    void bothDevicesGenerateOneInstanceAndKeepCompletion();
    void remoteReclaimKeepsTouchedInstanceOnBothSides();
    void regeneratedInstanceReachesOtherDevice();
    void userDeletedInstanceStaysDeletedOnBothDevices();
    void dayStartHourSyncsWithDefaultsAndLatestWins();
    void referenceArrivingBeforeItsTargetIsRelinked();
    void derivedEmptyReferenceIsNotSentBack();

    // 2e：快照、首次加入与全局回滚
    void firstJoinReplacesJoiningDeviceWithSnapshot();
    void globalRollbackReplacesOtherDeviceAndRejectsOldEpoch();
    void publishedSnapshotAcknowledgesQueuedChanges();

    // 2f：提交后的精确通知
    void notificationsFollowChangedTablesInOrder();
    void failedApplyPublishesNothing();
    void remoteDeletionUnbindsRunningTimer();

private:
    Device openDevice(const QString& name);
    // 临时把服务层（TaskManager 等单例）切到这台设备的库上执行一段操作，用完关掉。
    void withServices(const Device& device, const std::function<void()>& action);
    // 两台设备来回同步，直到一轮下来谁也没有新改动要发。
    void syncAll(FakeCloud& cloud, const QList<Device>& devices);

    QTemporaryDir m_preferences;
    std::unique_ptr<QTemporaryDir> m_data;
    QStringList m_connections;
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
    // 单例计时器与设置跨用例共享：复位，免得上一条用例的计时或逻辑日起点漏到下一条。
    FocusTimer::instance()->resetSession();
    AppSettings::instance()->setDayStartHour(4);
    DatabaseManager::instance()->close();
    for (const QString& connection : m_connections) {
        {
            QSqlDatabase database = QSqlDatabase::database(connection);
            database.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }
    m_connections.clear();
    m_data.reset();
}

Device SyncTests::openDevice(const QString& name)
{
    Device device;
    device.path = m_data->filePath(name + QStringLiteral(".sqlite"));
    if (!DatabaseManager::instance()->initialize(device.path)) {
        qWarning() << "initialize failed" << device.path;
    }
    DatabaseManager::instance()->close();
    device.connection = QStringLiteral("sync-device-") + name;
    QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), device.connection);
    database.setDatabaseName(device.path);
    database.open();
    QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
    QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    m_connections.append(device.connection);
    device.id = SyncStore(device.connection).deviceId();
    return device;
}

void SyncTests::withServices(const Device& device, const std::function<void()>& action)
{
    QVERIFY(DatabaseManager::instance()->initialize(device.path));
    action();
    DatabaseManager::instance()->close();
}

void SyncTests::syncAll(FakeCloud& cloud, const QList<Device>& devices)
{
    // 应用对方的改动之后本机可能产生新的改动（例如排序归一），所以要来回几轮，直到安静下来。
    for (int round = 0; round < 6; ++round) {
        int published = 0;
        for (const Device& device : devices) {
            published += cloud.publish(device);
        }
        for (const Device& device : devices) {
            for (const SyncStore::ApplyResult& result : cloud.pull(device)) {
                QVERIFY2(result.ok, qPrintable(result.error));
            }
        }
        if (published == 0) {
            return;
        }
    }
    QFAIL("来回同步六轮后仍有新改动，没有收敛");
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

    QTest::ignoreMessage(QtWarningMsg, "同步结构不完整，已先拆掉同步触发器，随后由迁移补齐");
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id = 'preset-5'")), 1);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    // 补回来的预置科目仍按默认值处理：版本取最小值，并照常入队。
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-5"), QStringLiteral("name")).time, 0);
    QVERIFY(queued(QStringLiteral("categories"), QStringLiteral("preset-5")));
}

// ── 2b：读出与应用 ──
//
// 需要决定「谁的修改更晚」的用例，把时钟拨到远超真实时间的值（约 2096 年）：
// 逻辑时间取 max(此刻, 上一次 + 1)，拨得足够大，版本就完全由用例决定。
namespace {
constexpr qint64 kFuture = 4000000000000LL;
}

void SyncTests::batchSurvivesJsonRoundTrip()
{
    SyncBatch batch;
    batch.device = QStringLiteral("device-a");
    batch.epoch = 3;
    SyncRecord live;
    live.table = QStringLiteral("tasks");
    live.syncId = QStringLiteral("task-1");
    live.fields.insert(QStringLiteral("title"),
                       {QStringLiteral("写论文"), {1000, QStringLiteral("device-a")}, {500, QStringLiteral("device-b")}});
    live.fields.insert(QStringLiteral("completed"), {qint64(1), {1001, QStringLiteral("device-a")}, {}});
    live.fields.insert(QStringLiteral("category_id"), {QVariant(), {1002, QStringLiteral("device-a")}, {}});
    SyncRecord gone;
    gone.table = QStringLiteral("categories");
    gone.syncId = QStringLiteral("category-1");
    gone.deleted = true;
    gone.deleteVersion = {2000, QStringLiteral("device-a")};
    gone.deleteKind = QStringLiteral("merge");
    gone.mergedInto = QStringLiteral("category-0");
    batch.records = {live, gone};
    batch.settings = {{QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), {3000, QStringLiteral("device-a")}, {}}};

    const QByteArray bytes = QJsonDocument(SyncJson::toJson(batch)).toJson();
    SyncBatch parsed;
    QString error;
    QVERIFY2(SyncJson::fromJson(QJsonDocument::fromJson(bytes).object(), &parsed, &error), qPrintable(error));
    QCOMPARE(parsed.device, batch.device);
    QCOMPARE(parsed.epoch, qint64(3));
    QCOMPARE(parsed.records.size(), 2);
    const SyncRecord& task = parsed.records.at(0);
    QCOMPARE(task.fields.size(), 3);
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("completed"), QStringLiteral("category_id")}) {
        QCOMPARE(SyncJson::canonicalValue(task.fields.value(field).value),
                 SyncJson::canonicalValue(live.fields.value(field).value));
        QVERIFY(task.fields.value(field).version == live.fields.value(field).version);
    }
    QVERIFY(task.fields.value(QStringLiteral("title")).base == live.fields.value(QStringLiteral("title")).base);
    const SyncRecord& category = parsed.records.at(1);
    QVERIFY(category.deleted);
    QVERIFY(category.deleteVersion == gone.deleteVersion);
    QCOMPARE(category.deleteKind, QStringLiteral("merge"));
    QCOMPARE(category.mergedInto, QStringLiteral("category-0"));
    QCOMPARE(parsed.settings.size(), 1);
    QCOMPARE(parsed.settings.first().value, QStringLiteral("5"));

    // 更新的版本写出的文件：拒绝，而不是按旧含义去猜。
    QJsonObject future = SyncJson::toJson(batch);
    future.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1);
    QVERIFY(!SyncJson::fromJson(future, &parsed, &error));
    QVERIFY(!error.isEmpty());
}

void SyncTests::insertUpdateDeleteReachOtherDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});

    const QString id = addTask(a, QStringLiteral("买菜"));
    syncAll(cloud, {a, b});
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("买菜"));
    // 应用收到的改动不会反过来进 B 的待发送队列（触发器在应用期间跳过）。
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '买菜和水果' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("买菜和水果"));

    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_tombstones WHERE sync_id = '%1'").arg(id)), 1);
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::editsOfDifferentFieldsAreBothKept()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("写论文"));
    syncAll(cloud, {a, b});

    // 两台都离线，各改一个字段：合并后两处修改都在，而且不算冲突。
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '写论文（第二稿）' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET notes = '第三章' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(taskValue(device, id, QStringLiteral("title")).toString(), QStringLiteral("写论文（第二稿）"));
        QCOMPARE(taskValue(device, id, QStringLiteral("notes")).toString(), QStringLiteral("第三章"));
    }
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::concurrentEditsOfSameFieldConvergeAndAreLogged()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("标题"));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 改的' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    // 同一字段两边同时改：后改的（B）为准，两台设备结果一致。
    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("B 改的"));
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("B 改的"));
    // 输掉的值两边都记了一笔，而且是给人看的文字：哪条任务、哪一项、丢了什么、留下什么。
    for (const Device& device : {a, b}) {
        QCOMPARE(logCount(device, QStringLiteral("edit")), 1);
        QSqlQuery log(deviceDb(device));
        QVERIFY(log.exec(QStringLiteral("SELECT record_label, field, lost_value, kept_value FROM sync_conflict_log")));
        QVERIFY(log.next());
        QCOMPARE(log.value(1).toString(), QStringLiteral("title"));
        QCOMPARE(log.value(2).toString(), QStringLiteral("A 改的"));
        QCOMPARE(log.value(3).toString(), QStringLiteral("B 改的"));
    }
}

void SyncTests::sequentialEditsAcrossDevicesAreNotConflicts()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("标题"));
    syncAll(cloud, {a, b});

    // 看过对方的修改再改：这是先后修改，不是冲突，一条日志都不该有。
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 接着改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 再改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("B 再改"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::deleteWinsOverConcurrentEdit_deleteArrivesFirst()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    // A 离线删除；B 离线修改，时间上更晚。删除仍然优先。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '复习第二章' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(cloud.publish(a) > 0);
    cloud.pull(b);
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    }
    // B 那次没发出去的修改随删除作废，记在 B 的日志里。
    QCOMPARE(logCount(b, QStringLiteral("delete")), 1);
    QCOMPARE(scalar(b, QStringLiteral("SELECT lost_value FROM sync_conflict_log")).toString(),
             QStringLiteral("复习第二章"));
}

void SyncTests::deleteWinsOverConcurrentEdit_editArrivesFirst()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '复习第二章' WHERE sync_id = '%1'").arg(id)));
    // 这次 B 的修改先到 A：A 已经删了，修改被忽略（不复活），并记下这次作废的修改。
    QVERIFY(cloud.publish(b) > 0);
    cloud.pull(a);
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    }
    QCOMPARE(logCount(a, QStringLiteral("delete")), 1);
}

void SyncTests::concurrentCreatesStayTwoRecords()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // 两台离线各建一条同名任务：身份不同，就是两条任务，不会互相覆盖。
    QVERIFY(!addTask(a, QStringLiteral("买菜")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("买菜")).isEmpty());
    syncAll(cloud, {a, b});
    QCOMPARE(taskTitles(a), QStringList({QStringLiteral("买菜"), QStringLiteral("买菜")}));
    QCOMPARE(taskTitles(b), QStringList({QStringLiteral("买菜"), QStringLiteral("买菜")}));
}

void SyncTests::redeliveredBatchesChangeNothing()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '改过', notes = '备注' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(cloud.publish(a) > 0);
    cloud.pull(b);

    // sol6 审查第 4 条：已经写入、却没收到确认（断线、被挂起），连续两次之后全部变成冲突。
    // 这里 B 把 A 的全部文件从头再读两遍，其间 B 自己又改了别的列：什么都不该变，也不该有冲突。
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET completed = 1 WHERE sync_id = '%1'").arg(id)));
    for (int round = 0; round < 2; ++round) {
        cloud.rewind(b, a);
        for (const SyncStore::ApplyResult& result : cloud.pull(b)) {
            QVERIFY2(result.ok, qPrintable(result.error));
        }
    }
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("改过"));
    QCOMPARE(taskValue(b, id, QStringLiteral("notes")).toString(), QStringLiteral("备注"));
    QCOMPARE(taskValue(b, id, QStringLiteral("completed")).toInt(), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    QCOMPARE(logCount(b), 0);
}

void SyncTests::editDuringSendIsNotLost()
{
    Device a = openDevice(QStringLiteral("a"));
    const QString id = addTask(a, QStringLiteral("任务"));
    SyncStore store(a.connection);
    QVERIFY(store.acknowledge(store.collectPending()));

    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '第一次' WHERE sync_id = '%1'").arg(id)));
    const SyncBatch sent = store.collectPending();
    QCOMPARE(sent.records.size(), 1);
    // 正在写同步文件的时候又改了一次，然后才确认刚才那批。
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '第二次' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(store.acknowledge(sent));

    // 第二次的修改还在队列里，下一批带的是它；base 改成刚发出去的那一版（对方马上就会见到它）。
    const SyncBatch next = store.collectPending();
    QCOMPARE(next.records.size(), 1);
    const SyncFieldValue title = next.records.first().fields.value(QStringLiteral("title"));
    QCOMPARE(title.value.toString(), QStringLiteral("第二次"));
    QVERIFY(title.base == sent.records.first().fields.value(QStringLiteral("title")).version);
    QVERIFY(store.acknowledge(next));
    QVERIFY(store.collectPending().isEmpty());
}

void SyncTests::causalEditWinsDespiteClockSkew()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});

    // B 的时钟快很多；A 看过 B 的修改之后再改，即使 A 的时钟慢，A 这次也一定排在后面。
    QVERIFY(setClock(b, kFuture * 2));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(setClock(a, kFuture));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 看过之后又改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("A 看过之后又改"));
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("A 看过之后又改"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::sameLogicalTimeConvergesByDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});

    // 两台设备恰好给出同一逻辑时间：再比设备标识，所有设备选出同一个结果。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '甲' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '乙' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    const QString expected = a.id > b.id ? QStringLiteral("甲") : QStringLiteral("乙");
    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), expected);
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), expected);
}

void SyncTests::badRecordIsSkippedWithoutBlockingBatch()
{
    Device b = openDevice(QStringLiteral("b"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncBatch batch;
    batch.device = remote;
    // 空标题撞上表上的约束；另一条来自不认识的表（更新的版本多同步了一张表）；中间夹一条正常的。
    SyncRecord bad;
    bad.table = QStringLiteral("tasks");
    bad.syncId = QStringLiteral("bad-task");
    bad.fields.insert(QStringLiteral("title"), {QString(QStringLiteral("")), version, {}});
    bad.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    SyncRecord unknown;
    unknown.table = QStringLiteral("future_table");
    unknown.syncId = QStringLiteral("future-1");
    unknown.fields.insert(QStringLiteral("x"), {qint64(1), version, {}});
    SyncRecord good;
    good.table = QStringLiteral("tasks");
    good.syncId = QStringLiteral("good-task");
    good.fields.insert(QStringLiteral("title"), {QStringLiteral("正常的任务"), version, {}});
    good.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    good.fields.insert(QStringLiteral("display_order"), {qint64(1), version, {}});
    batch.records = {bad, unknown, good};

    // 跳过的每一条都会在运行日志里留一行，真机排查时靠它；这里预期正好两行。
    QTest::ignoreMessage(QtWarningMsg, QRegularExpression(QStringLiteral("^Skipped sync record \"tasks\" \"bad-task\"")));
    QTest::ignoreMessage(QtWarningMsg, QRegularExpression(QStringLiteral("^Skipped sync record \"future_table\"")));
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    // 整批照常提交：坏的两条跳过并记日志，正常的那条落地。
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(result.skippedRecords, 2);
    QCOMPARE(logCount(b, QStringLiteral("skipped")), 2);
    QCOMPARE(taskValue(b, QStringLiteral("good-task"), QStringLiteral("title")).toString(), QStringLiteral("正常的任务"));
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = 'bad-task'")), 0);
}

void SyncTests::remoteTaskDeletionKeepsItsSessions()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    const qint64 localId = scalar(a, QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(id)).toLongLong();
    QVERIFY(exec(a, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)").arg(localId)));
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE t.sync_id = '%1'").arg(id)), 1);

    // 在 A 上走服务层删任务（先解除专注记录的关联再删）。B 上任务消失，专注记录作为历史留下，只是不再关联任务。
    withServices(a, [&] { QVERIFY(TaskManager::instance()->deleteTask(int(localId))); });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE task_id IS NULL AND duration = 1500")), 1);
}

void SyncTests::runningSessionIsNeverSent()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});
    const qint64 localId = scalar(a, QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(id)).toLongLong();
    QVERIFY(exec(a, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                   "VALUES (%1, '2026-09-30T10:00:00', 1)").arg(localId)));

    for (const SyncRecord& record : SyncStore(a.connection).collectPending().records) {
        QVERIFY(record.table != QLatin1String("focus_sessions"));
    }
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 0);
}

void SyncTests::batchFromOtherEpochOrSameDeviceIsRejected()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    QVERIFY(!addTask(a, QStringLiteral("任务")).isEmpty());
    SyncBatch batch = SyncStore(a.connection).collectPending();
    QVERIFY(!batch.isEmpty());

    // 纪元不同：属于全局回滚前（或之后）的改动，不能直接合并。
    batch.epoch = 1;
    SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY(!result.ok);
    QVERIFY(!result.error.isEmpty());
    // 设备标识与本机相同：多半是两台设备恢复了同一份备份，合并会把两边搅乱。
    batch.epoch = 0;
    batch.device = b.id;
    result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY(!result.ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
}

// ── 2c：引用与去重 ──
//
// 每条都对应 sol6 局域网方案审查时用真实表结构复现过的问题：在那个方案里，这些情况要么让同步永久卡住，
// 要么冒出一堆看不懂的冲突。这里要求：整批照常提交（syncAll 里逐批断言 ok），两台设备结果一致。

void SyncTests::sessionOnRemotelyDeletedTaskIsKeptDetached()
{
    // 审查第 1 条：Mac 删了一条任务，iPad 离线时在这条任务上做了专注——当年报「外键目标不存在」，永久卡死。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString task = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(task)));
    QVERIFY(exec(b, QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, category_name_snapshot) "
        "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1, '数学')")
                        .arg(localIdOf(b, QStringLiteral("tasks"), task))));
    syncAll(cloud, {a, b});

    // 任务按删除优先消失；专注记录作为历史留下，只是不再关联任务，科目快照还在，统计照样有归属。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(task)), 0);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE task_id IS NULL "
                                              "AND duration = 1500 AND category_name_snapshot = '数学'")), 1);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::taskUnderRemotelyDeletedCategoryBecomesUncategorized()
{
    // 审查第 1 条的另一种：删科目，而另一台离线时在这个科目下建了任务。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString category = addCategory(a, QStringLiteral("编程"));
    syncAll(cloud, {a, b});

    withServices(a, [&] {
        QVERIFY(CategoryManager::instance()->deleteCategory(int(localIdOf(a, QStringLiteral("categories"), category))));
    });
    const QString task = addTask(b, QStringLiteral("写代码"));
    QVERIFY(setTaskCategory(b, task, category));
    syncAll(cloud, {a, b});

    // 与本机删除科目的做法一致：任务留着，科目和旧的科目名文本一起清空，变成未分类。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id = '%1'").arg(category)), 0);
        QVERIFY(taskValue(device, task, QStringLiteral("category_id")).isNull());
        QVERIFY(taskValue(device, task, QStringLiteral("category")).isNull());
        QCOMPARE(taskValue(device, task, QStringLiteral("title")).toString(), QStringLiteral("写代码"));
    }
}

void SyncTests::renamedCategoryThenRecreatedNameSyncs()
{
    // 审查第 3 条：把「编程」改名后再新建一个「编程」——按名字认科目的方案里，对方连读取都失败。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString old = addCategory(a, QStringLiteral("编程"));
    const QString first = addTask(a, QStringLiteral("旧任务"));
    QVERIFY(setTaskCategory(a, first, old));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '计算机' WHERE sync_id = '%1'").arg(old)));
    const QString recreated = addCategory(a, QStringLiteral("编程"));
    const QString second = addTask(a, QStringLiteral("新任务"));
    QVERIFY(setTaskCategory(a, second, recreated));
    syncAll(cloud, {a, b});

    QCOMPARE(customCategoryNames(b), QStringList({QStringLiteral("编程"), QStringLiteral("计算机")}));
    QCOMPARE(taskCategory(b, first), old);
    QCOMPARE(taskCategory(b, second), recreated);
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::renameCollidingWithOtherSidesNewCategoryMerges()
{
    // 审查第 3 条：A 把「编程」改成「计算机」，B 同时新建了「计算机」——当年撞上名称唯一约束，写入失败。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString renamed = addCategory(a, QStringLiteral("编程"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '计算机' WHERE sync_id = '%1'").arg(renamed)));
    const QString onA = addTask(a, QStringLiteral("A 的任务"));
    QVERIFY(setTaskCategory(a, onA, renamed));
    const QString created = addCategory(b, QStringLiteral("计算机"));
    const QString onB = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(setTaskCategory(b, onB, created));
    syncAll(cloud, {a, b});

    // 合并成一个：留身份较小的那个，两边的任务都指向它，另一个留下「合并」删除记录。
    const QString winner = qMin(renamed, created);
    const QString loser = qMax(renamed, created);
    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("计算机")});
        QCOMPARE(taskCategory(device, onA), winner);
        QCOMPARE(taskCategory(device, onB), winner);
        QCOMPARE(taskValue(device, onB, QStringLiteral("category")).toString(), QStringLiteral("计算机"));
        QCOMPARE(scalar(device, QStringLiteral("SELECT kind || ':' || merged_into FROM sync_tombstones "
                                               "WHERE sync_id = '%1'").arg(loser)).toString(),
                 QStringLiteral("merge:") + winner);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::sameNameCategoriesCreatedOnBothSidesMerge()
{
    // 审查第 5 条：两边各建一个同名科目，只因为创建时间不同就一定冲突，要人去选。这里自动合并，不算冲突。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString x = addCategory(a, QStringLiteral("英语阅读"));
    const QString y = addCategory(b, QStringLiteral("英语阅读"));
    const QString taskA = addTask(a, QStringLiteral("精读"));
    const QString taskB = addTask(b, QStringLiteral("泛读"));
    QVERIFY(setTaskCategory(a, taskA, x));
    QVERIFY(setTaskCategory(b, taskB, y));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("英语阅读")});
        QCOMPARE(taskCategory(device, taskA), qMin(x, y));
        QCOMPARE(taskCategory(device, taskB), qMin(x, y));
        // 只有一条「已合并」的说明，没有要人处理的冲突。
        QCOMPARE(logCount(device, QStringLiteral("edit")), 0);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::swappedCategoryNamesAreNotMerged()
{
    // 两个科目互换名字：逐条应用时中途会撞名，但最终并没有重名，不能被误判成要合并。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString first = addCategory(a, QStringLiteral("甲"));
    const QString second = addCategory(a, QStringLiteral("乙"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '临时' WHERE sync_id = '%1'").arg(first)));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '甲' WHERE sync_id = '%1'").arg(second)));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '乙' WHERE sync_id = '%1'").arg(first)));
    syncAll(cloud, {a, b});

    QCOMPARE(scalar(b, QStringLiteral("SELECT name FROM categories WHERE sync_id = '%1'").arg(first)).toString(),
             QStringLiteral("乙"));
    QCOMPARE(scalar(b, QStringLiteral("SELECT name FROM categories WHERE sync_id = '%1'").arg(second)).toString(),
             QStringLiteral("甲"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::mergeReachesSideThatDidNotCollide()
{
    // A 看到撞名、做了合并；B 却在这之前把自己那个科目改成了别的名字，本机没有撞名。
    // 合并记录必须发给 B，否则 B 会一直留着 A 已经并掉的那个科目。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // 固定身份：A 的较小，撞名时 B 的并进 A 的。换成随机身份，一半的情况下合并方向相反，
    // 那种方向即使合并没发出去，两边也碰巧一致，这条用例就测不出问题了。
    const QString x = addCategory(a, QStringLiteral("编程"), QStringLiteral("aaaa-category"));
    const QString y = addCategory(b, QStringLiteral("编程"), QStringLiteral("bbbb-category"));
    const QString task = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(setTaskCategory(b, task, y));
    QVERIFY(cloud.publish(b) > 0);
    QVERIFY(exec(b, QStringLiteral("UPDATE categories SET name = '编程基础' WHERE sync_id = '%1'").arg(y)));
    cloud.pull(a);  // A 只看到 B 改名之前的那一批：撞名，把 B 的并进自己的
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(y)).toString(),
             QStringLiteral("merge"));
    syncAll(cloud, {a, b});

    // 两台设备最终一致：只剩 A 的那个科目，B 的任务也挂到它下面；B 那次改名随合并作废（记了日志）。
    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("编程")});
        QCOMPARE(taskCategory(device, task), x);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
    QCOMPARE(logCount(a, QStringLiteral("merge")), 2);
}

void SyncTests::presetsRenamedToSameNameGetSuffix()
{
    // 预置科目不能删，也就不能合并：两边把不同的预置科目改成同一个名字时，后改的留下名字，另一个加后缀。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '数理' WHERE sync_id = 'preset-1'")));
    QVERIFY(exec(b, QStringLiteral("UPDATE categories SET name = '数理' WHERE sync_id = 'preset-2'")));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(scalar(device, QStringLiteral("SELECT name FROM categories WHERE sync_id = 'preset-2'")).toString(),
                 QStringLiteral("数理"));
        QCOMPARE(scalar(device, QStringLiteral("SELECT name FROM categories WHERE sync_id = 'preset-1'")).toString(),
                 QStringLiteral("数理（2）"));
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM categories WHERE is_preset = 1")), 5);
    }
}

void SyncTests::sameDayTasksAreRenumberedWithoutMigration()
{
    // 审查第 7 条：两端同一天各加任务，排序号撞了；当年每次同步后启动都要走 v12 修一遍并生成迁移快照，
    // 快照只留三份，真正升级前的那几份很快被挤掉。这里在同步的同一个事务里按确定规则重排，两边顺序一致。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString date = QStringLiteral("2026-09-30");
    for (const QString& title : {QStringLiteral("A1"), QStringLiteral("A2")}) {
        QVERIFY(!addTask(a, title, date).isEmpty());
    }
    for (const QString& title : {QStringLiteral("B1"), QStringLiteral("B2")}) {
        QVERIFY(!addTask(b, title, date).isEmpty());
    }
    const QDir dataDir(m_data->path());
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const int snapshotsBefore = dataDir.entryList(pattern, QDir::Files).size();
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(DISTINCT display_order) FROM tasks WHERE date = '%1'")
                                   .arg(date)), 4);
        QCOMPARE(count(device, QStringLiteral("SELECT MIN(display_order) FROM tasks WHERE date = '%1'").arg(date)), 1);
    }
    QCOMPARE(dayOrder(a, date), dayOrder(b, date));

    // 重新打开两台设备的库：启动检查看不到任何需要修复的排序，不会走 v12，也就不会多出迁移快照。
    withServices(a, [] {});
    withServices(b, [] {});
    QCOMPARE(dataDir.entryList(pattern, QDir::Files).size(), snapshotsBefore);
}

void SyncTests::corruptMergeChainDoesNotHang()
{
    // 合并总是并向身份较小的一方，正常不会成环；外部改坏的数据里出现环，也只追有限步，然后当作找不到。
    Device b = openDevice(QStringLiteral("b"));
    QVERIFY(exec(b, QStringLiteral("INSERT INTO sync_tombstones (tbl, sync_id, v_time, v_device, kind, merged_into, "
                                   "deleted_at) VALUES ('categories', 'loop-x', 1, 'd', 'merge', 'loop-y', 1), "
                                   "('categories', 'loop-y', 1, 'd', 'merge', 'loop-x', 1)")));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncRecord task;
    task.table = QStringLiteral("tasks");
    task.syncId = QStringLiteral("task-in-loop");
    task.fields.insert(QStringLiteral("title"), {QStringLiteral("环里的任务"), version, {}});
    task.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    task.fields.insert(QStringLiteral("category_id"), {QStringLiteral("loop-x"), version, {}});
    task.fields.insert(QStringLiteral("category"), {QStringLiteral("环"), version, {}});
    SyncBatch batch;
    batch.device = remote;
    batch.records = {task};
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    QVERIFY(taskValue(b, QStringLiteral("task-in-loop"), QStringLiteral("category_id")).isNull());
}

// ── 2d：例行与逻辑日起点 ──

void SyncTests::reclaimedInstanceIsSoftDeletedAndRegenerates()
{
    // 单机行为不变：停用例行收回今天没动过的实例，重新启用又能生成回来；只是收回现在留下的是「收回」记录。
    RoutineManager* routines = RoutineManager::instance();
    QVERIFY(routines->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    const int routineId = scalar(QStringLiteral("SELECT id FROM routines")).toInt();
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));
    QCOMPARE(routines->materializeToday(), 1);

    QVERIFY(setClock(20000, true));
    QVERIFY(routines->setRoutineActive(routineId, false));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), instance), QStringLiteral("reclaim"));
    // 标记用完就复位：之后的普通删除不能被误记成收回。
    QVERIFY(scalar(QStringLiteral("SELECT delete_kind FROM sync_runtime")).isNull());

    QVERIFY(routines->setRoutineActive(routineId, true));
    QCOMPARE(routines->materializeToday(), 1);
    // 同一个身份回来了，用真实版本（要在对方那里取代收回记录），收回记录随之消失。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
    QVERIFY(versionOf(QStringLiteral("tasks"), instance, QStringLiteral("title")).time > 20000);
    QVERIFY(tombstoneKind(QStringLiteral("tasks"), instance).isEmpty());

    // 用户自己删掉的实例：删除优先，生成戳被退回也不会再生成。
    QVERIFY(TaskManager::instance()->deleteTask(
        scalar(QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(instance)).toInt()));
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), instance), QStringLiteral("delete"));
    QVERIFY(exec(QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")));
    QCOMPARE(routines->materializeToday(), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    QCOMPARE(scalar(QStringLiteral("SELECT last_generated_date FROM routines")).toString(),
             today().toString(Qt::ISODate));
}

void SyncTests::bothDevicesGenerateOneInstanceAndKeepCompletion()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));

    // A 生成当天实例并完成了它；B 还没收到，稍后自己也生成了同一天的实例（默认值：未完成）。
    withServices(a, [&] {
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
        QVERIFY(TaskManager::instance()->setTaskCompleted(int(localIdOf(a, QStringLiteral("tasks"), instance)), true));
    });
    withServices(b, [] { QCOMPARE(RoutineManager::instance()->materializeToday(), 1); });
    syncAll(cloud, {a, b});

    // 同一天只有一条，而且 B 晚生成的那份没有盖掉 A 上的「已完成」。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_generated = 1")), 1);
        QCOMPARE(taskValue(device, instance, QStringLiteral("completed")).toInt(), 1);
    }
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::remoteReclaimKeepsTouchedInstanceOnBothSides()
{
    // 审查第 1 条的例行版本：停用例行时 Mac 收回今天没专注过的实例，可它只看得到本机的专注记录；
    // iPad 离线时在这条实例上专注过。当年直接卡死；这里两边最后都留着实例，专注记录两边都挂在它上面。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString routine = scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString();
    const QString instance = SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate));

    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), instance))));
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(int(localIdOf(a, QStringLiteral("routines"), routine)),
                                                             false));
    });
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("reclaim"));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                              "WHERE t.sync_id = '%1'").arg(instance)), 1);
        QCOMPARE(scalar(device, QStringLiteral("SELECT active FROM routines")).toInt(), 0);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::regeneratedInstanceReachesOtherDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString routine = scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString();
    const QString instance = SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate));
    const int routineId = int(localIdOf(a, QStringLiteral("routines"), routine));

    // A 停用：两边没动过的实例都收回。
    withServices(a, [&] { QVERIFY(RoutineManager::instance()->setRoutineActive(routineId, false)); });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);

    // A 又启用并重新生成：B 那边也补回来。
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(routineId, true));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
    QCOMPARE(scalar(b, QStringLiteral("SELECT active FROM routines")).toInt(), 1);
}

void SyncTests::userDeletedInstanceStaysDeletedOnBothDevices()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));

    withServices(a, [&] {
        QVERIFY(TaskManager::instance()->deleteTask(int(localIdOf(a, QStringLiteral("tasks"), instance))));
    });
    syncAll(cloud, {a, b});
    QCOMPARE(scalar(b, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("delete"));

    // B 的生成戳因为别的原因退回了（例如改过逻辑日起点）：你在另一台上删掉的实例也不会被 B 生成回来。
    QVERIFY(exec(b, QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")));
    withServices(b, [] { QCOMPARE(RoutineManager::instance()->materializeToday(), 0); });
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    }
}

void SyncTests::dayStartHourSyncsWithDefaultsAndLatestWins()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString key = QStringLiteral("logic/dayStartHour");
    SyncStore storeA(a.connection);
    SyncStore storeB(b.connection);
    // 两台都还是出厂默认的 4 点：各自记下的是最小版本，谁也不覆盖谁。
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("4"), true));
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("4"), true));
    syncAll(cloud, {a, b});

    // A 改成 5 点：B 收到后，由调用方把新值写回 AppSettings。
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("5"), false));
    QVERIFY(cloud.publish(a) > 0);
    const QList<SyncStore::ApplyResult> results = cloud.pull(b);
    QCOMPARE(results.size(), 1);
    QCOMPARE(results.first().changedSettings.value(key), QStringLiteral("5"));
    QCOMPARE(storeB.syncedSetting(key), QStringLiteral("5"));
    // 写回 AppSettings 之后它又发出变更信号、调用方再记一次：值没变，不是本机改动，不会再发回去。
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("5"), false));
    QVERIFY(storeB.collectPending().settings.isEmpty());

    // 两边同时改：后改的为准，输掉的一方记日志。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("6"), false));
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("3"), false));
    syncAll(cloud, {a, b});
    QCOMPARE(storeA.syncedSetting(key), QStringLiteral("3"));
    QCOMPARE(storeB.syncedSetting(key), QStringLiteral("3"));
    QCOMPARE(logCount(a, QStringLiteral("edit")), 1);
    QCOMPARE(scalar(a, QStringLiteral("SELECT lost_value FROM sync_conflict_log")).toString(), QStringLiteral("6 点"));

    // 新加入的设备第一次记下默认值：不会盖掉已经改过的设置。
    Device c = openDevice(QStringLiteral("c"));
    QVERIFY(SyncStore(c.connection).recordLocalSetting(key, QStringLiteral("4"), true));
    syncAll(cloud, {a, b, c});
    for (const Device& device : {a, b, c}) {
        QCOMPARE(SyncStore(device.connection).syncedSetting(key), QStringLiteral("3"));
    }
}

void SyncTests::referenceArrivingBeforeItsTargetIsRelinked()
{
    // 一条专注记录先到，它指向的任务本机还没有（例如那条任务被收回、之后才补回来）：
    // 先落空值并记下目标，目标到了再接回去。
    Device b = openDevice(QStringLiteral("b"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncRecord session;
    session.table = QStringLiteral("focus_sessions");
    session.syncId = QStringLiteral("early-session");
    session.fields.insert(QStringLiteral("task_id"), {QStringLiteral("late-task"), version, {}});
    session.fields.insert(QStringLiteral("start_time"), {QStringLiteral("2026-09-30T09:00:00"), version, {}});
    session.fields.insert(QStringLiteral("end_time"), {QStringLiteral("2026-09-30T09:25:00"), version, {}});
    session.fields.insert(QStringLiteral("duration"), {qint64(1500), version, {}});
    session.fields.insert(QStringLiteral("mode"), {qint64(1), version, {}});
    SyncBatch first;
    first.device = remote;
    first.records = {session};
    QVERIFY(SyncStore(b.connection).applyRemote(first).ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE sync_id = 'early-session' "
                                     "AND task_id IS NULL")), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 1);

    SyncRecord task;
    task.table = QStringLiteral("tasks");
    task.syncId = QStringLiteral("late-task");
    task.fields.insert(QStringLiteral("title"), {QStringLiteral("后到的任务"), version, {}});
    task.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    task.fields.insert(QStringLiteral("display_order"), {qint64(1), version, {}});
    SyncBatch second;
    second.device = remote;
    second.records = {task};
    QVERIFY(SyncStore(b.connection).applyRemote(second).ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE fs.sync_id = 'early-session' AND t.sync_id = 'late-task'")), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 0);
}

void SyncTests::derivedEmptyReferenceIsNotSentBack()
{
    // A 因为引用的目标暂时没有而把引用置空，这个空值的版本还是 B 那一版。之后 A 改了这条记录的别的字段，
    // 整条记录（连同这个推出来的空值）发回 B：B 不能按「版本相同就比大小」把自己正常的引用也清掉。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    const QString task = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), task))));
    const QString session = scalar(b, QStringLiteral("SELECT sync_id FROM focus_sessions")).toString();

    // A 只收到了专注记录、没收到它的任务（例如任务那条被收回、之后才补回来）。
    const SyncBatch fromB = SyncStore(b.connection).collectPending();
    SyncBatch onlySession;
    onlySession.device = fromB.device;
    onlySession.epoch = fromB.epoch;
    for (const SyncRecord& record : fromB.records) {
        if (record.table == QLatin1String("focus_sessions")) {
            onlySession.records.append(record);
        }
    }
    QVERIFY(SyncStore(a.connection).applyRemote(onlySession).ok);
    QVERIFY(SyncStore(b.connection).acknowledge(fromB));
    QVERIFY(scalar(a, QStringLiteral("SELECT task_id FROM focus_sessions WHERE sync_id = '%1'").arg(session)).isNull());

    // A 在这条专注记录上改了时长，于是整条记录被发回 B。
    QVERIFY(exec(a, QStringLiteral("UPDATE focus_sessions SET duration = 1200 WHERE sync_id = '%1'").arg(session)));
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(SyncStore(a.connection).collectPending());
    QVERIFY2(result.ok, qPrintable(result.error));

    // B 只收下了时长，仍然挂着自己的任务。
    QCOMPARE(scalar(b, QStringLiteral("SELECT duration FROM focus_sessions WHERE sync_id = '%1'").arg(session)).toInt(),
             1200);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE fs.sync_id = '%1' AND t.sync_id = '%2'").arg(session, task)), 1);
}

// ── 2e：快照、首次加入与全局回滚 ──

void SyncTests::firstJoinReplacesJoiningDeviceWithSnapshot()
{
    // 你定了：iPad 第一次加入时完全以 Mac 为准，iPad 上的都是测试数据，不用保留。
    Device mac = openDevice(QStringLiteral("mac"));
    Device ipad = openDevice(QStringLiteral("ipad"));
    const QString date = today().toString(Qt::ISODate);

    // Mac：自定义科目和它下面的任务、改过名的预置科目、例行与当天实例、专注与休息、改过的逻辑日起点。
    const QString programming = addCategory(mac, QStringLiteral("编程"));
    const QString macTask = addTask(mac, QStringLiteral("写代码"), date);
    QVERIFY(setTaskCategory(mac, macTask, programming));
    QVERIFY(exec(mac, QStringLiteral("UPDATE categories SET name = '英语阅读' WHERE sync_id = 'preset-2'")));
    withServices(mac, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    QVERIFY(exec(mac, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                     "VALUES (%1, '%2T09:00:00', '%2T09:25:00', 1500, 1)")
                          .arg(localIdOf(mac, QStringLiteral("tasks"), macTask)).arg(date)));
    QVERIFY(exec(mac, QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                     "VALUES ('%1T09:25:00', '%1T09:30:00', 300, 0)").arg(date)));
    QVERIFY(exec(mac, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(addTask(mac, QStringLiteral("删掉的")))));
    QVERIFY(SyncStore(mac.connection).recordLocalSetting(QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), false));

    // iPad：自己的测试数据、正在计时的专注、一条知识缺口（本机独有、不同步的表）。
    const QString ipadCategory = addCategory(ipad, QStringLiteral("iPad 科目"));
    const QString ipadTask = addTask(ipad, QStringLiteral("iPad 的测试任务"), date);
    QVERIFY(setTaskCategory(ipad, ipadTask, ipadCategory));
    const qint64 ipadTaskId = localIdOf(ipad, QStringLiteral("tasks"), ipadTask);
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                      "VALUES (%1, '%2T08:00:00', '%2T08:25:00', 1500, 1)").arg(ipadTaskId).arg(date)));
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                      "VALUES (%1, '%2T10:00:00', 1)").arg(ipadTaskId).arg(date)));
    const qint64 mathId = localIdOf(ipad, QStringLiteral("categories"), QStringLiteral("preset-1"));
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO knowledge_gaps (title, category_id, source_task_id, created_at, "
                                      "updated_at) VALUES ('极限的定义', %1, %2, '%3', '%3')")
                           .arg(mathId).arg(ipadTaskId).arg(date)));
    QVERIFY(SyncStore(ipad.connection).recordLocalSetting(QStringLiteral("logic/dayStartHour"), QStringLiteral("4"), true));

    const SyncBatch snapshot = throughJson(SyncStore(mac.connection).exportSnapshot());
    const SyncStore::ApplyResult result = SyncStore(ipad.connection).replaceWithSnapshot(snapshot);
    QVERIFY2(result.ok, qPrintable(result.error));
    // iPad 自己的任务被换掉了；计时器据此解绑（提交后逐个发 taskDeleted）。逻辑日起点交给调用方写回。
    QVERIFY(result.deletedTaskIds.contains(int(ipadTaskId)));
    QCOMPARE(result.changedSettings.value(QStringLiteral("logic/dayStartHour")), QStringLiteral("5"));

    // 两台的同步数据逐字段、逐版本一致（导出的快照完全相同）。
    QCOMPARE(describe(SyncStore(ipad.connection).exportSnapshot()), describe(SyncStore(mac.connection).exportSnapshot()));
    QCOMPARE(SyncStore(ipad.connection).epoch(), SyncStore(mac.connection).epoch());
    QCOMPARE(count(ipad, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);
    // 正在计时的那一行不受影响（只是它的任务没了，按删除任务的做法解除关联）。
    QCOMPARE(count(ipad, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NULL AND task_id IS NULL")), 1);
    // 不同步的知识缺口：指向预置科目的引用原样保留（预置科目没被删、本机编号没变），指向被换掉的任务的置空。
    QCOMPARE(scalar(ipad, QStringLiteral("SELECT category_id FROM knowledge_gaps")).toLongLong(), mathId);
    QVERIFY(scalar(ipad, QStringLiteral("SELECT source_task_id FROM knowledge_gaps")).isNull());
    QCOMPARE(logCount(ipad, QStringLiteral("skipped")), 0);

    // 之后照常增量同步。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    QVERIFY(SyncStore(mac.connection).markSnapshotPublished(SyncStore(mac.connection).exportSnapshot()));
    QVERIFY(exec(ipad, QStringLiteral("UPDATE tasks SET notes = 'iPad 上补的备注' WHERE sync_id = '%1'").arg(macTask)));
    QVERIFY(exec(mac, QStringLiteral("UPDATE tasks SET title = '写代码（Mac 改）' WHERE sync_id = '%1'").arg(macTask)));
    syncAll(cloud, {mac, ipad});
    for (const Device& device : {mac, ipad}) {
        QCOMPARE(taskValue(device, macTask, QStringLiteral("notes")).toString(), QStringLiteral("iPad 上补的备注"));
        QCOMPARE(taskValue(device, macTask, QStringLiteral("title")).toString(), QStringLiteral("写代码（Mac 改）"));
    }
}

void SyncTests::globalRollbackReplacesOtherDeviceAndRejectsOldEpoch()
{
    // D1：恢复备份 = 全局回滚。两台一起回到备份的状态，另一台在回滚前没同步过来的改动被换掉
    // （调用方事先做了自动备份，能从那里找回）。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString kept = addTask(a, QStringLiteral("备份之前就有"));
    syncAll(cloud, {a, b});
    const QString backupPath = m_data->filePath(QStringLiteral("a-backup.sqlite"));
    QVERIFY(QFile::copy(a.path, backupPath));

    // 备份之后两台都继续记了东西；B 还有一条没发出去的。
    QVERIFY(!addTask(a, QStringLiteral("A 备份之后加的")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("B 备份之后加的")).isEmpty());
    syncAll(cloud, {a, b});
    QVERIFY(!addTask(b, QStringLiteral("B 还没发的")).isEmpty());
    const SyncBatch staleFromB = SyncStore(b.connection).collectPending();

    // A 恢复备份：换回旧库文件，开新纪元（设备标识保持恢复前的），发一份全量快照。
    const qint64 epochBefore = SyncStore(a.connection).epoch();
    QSqlDatabase::database(a.connection, false).close();
    QVERIFY(QFile::remove(a.path));
    QVERIFY(QFile::copy(backupPath, a.path));
    QVERIFY(QSqlDatabase::database(a.connection).isOpen());
    QVERIFY(exec(a, QStringLiteral("PRAGMA foreign_keys = ON")));
    QVERIFY(SyncStore(a.connection).beginEpochAfterRestore(epochBefore, a.id));
    QCOMPARE(SyncStore(a.connection).epoch(), epochBefore + 1);
    QVERIFY(SyncStore(a.connection).needsSnapshot());
    const SyncBatch snapshot = throughJson(SyncStore(a.connection).exportSnapshot());
    QVERIFY(SyncStore(a.connection).markSnapshotPublished(snapshot));
    QVERIFY(!SyncStore(a.connection).needsSnapshot());

    // 回滚之前的旧改动（旧纪元）不能再合进来。
    QVERIFY(!SyncStore(a.connection).applyRemote(staleFromB).ok);
    // B 读到纪元更高的快照：不能当普通改动合并，要整体替换。
    QVERIFY(!SyncStore(b.connection).applyRemote(snapshot).ok);
    const SyncStore::ApplyResult replaced = SyncStore(b.connection).replaceWithSnapshot(snapshot);
    QVERIFY2(replaced.ok, qPrintable(replaced.error));
    QCOMPARE(SyncStore(b.connection).epoch(), epochBefore + 1);
    for (const Device& device : {a, b}) {
        QCOMPARE(taskTitles(device), QStringList{QStringLiteral("备份之前就有")});
    }
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));

    // 回滚之后的新改动照常同步（新纪元）。旧纪元的文件不再读：换一个云盘文件夹，相当于传输层只读新纪元的文件。
    FakeCloud fresh(m_data->filePath(QStringLiteral("cloud-epoch-1")));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET notes = '回滚后补的' WHERE sync_id = '%1'").arg(kept)));
    syncAll(fresh, {a, b});
    QCOMPARE(taskValue(a, kept, QStringLiteral("notes")).toString(), QStringLiteral("回滚后补的"));
}

void SyncTests::publishedSnapshotAcknowledgesQueuedChanges()
{
    // Mac 第一次开启同步：写出快照，快照已经带上的改动不必再单独发；快照导出之后才改的仍然待发送。
    Device a = openDevice(QStringLiteral("a"));
    const QString first = addTask(a, QStringLiteral("第一条"));
    QVERIFY(!SyncStore(a.connection).collectPending().isEmpty());
    const SyncBatch snapshot = SyncStore(a.connection).exportSnapshot();
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '快照之后改的' WHERE sync_id = '%1'").arg(first)));
    QVERIFY(SyncStore(a.connection).markSnapshotPublished(snapshot));

    const SyncBatch pending = SyncStore(a.connection).collectPending();
    QCOMPARE(pending.records.size(), 1);
    QCOMPARE(pending.records.first().syncId, first);
    QCOMPARE(pending.records.first().fields.value(QStringLiteral("title")).value.toString(),
             QStringLiteral("快照之后改的"));
}

// ── 2f：提交后的精确通知 ──
//
// 这几条用单例库当「本机」：各服务的信号挂在单例上，计时器也只认单例库。

void SyncTests::notificationsFollowChangedTablesInOrder()
{
    RoutineManager::instance();  // 先建出例行管理器：它会把 categoriesChanged 转成 routinesChanged
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("要被远端删的"), today(), -1, 0, QString());
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(taskId > 0 && categoryId > 0);
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};

    SyncBatch batch;
    batch.device = remote;
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId), version));
    SyncRecord renamed;
    renamed.table = QStringLiteral("categories");
    renamed.syncId = syncIdOf(QStringLiteral("categories"), categoryId);
    renamed.fields.insert(QStringLiteral("name"), {QStringLiteral("计算机"), version, {}});
    batch.records.append(renamed);
    SyncRecord session;
    session.table = QStringLiteral("focus_sessions");
    session.syncId = QStringLiteral("remote-session");
    session.fields.insert(QStringLiteral("start_time"), {QStringLiteral("2026-09-30T09:00:00"), version, {}});
    session.fields.insert(QStringLiteral("end_time"), {QStringLiteral("2026-09-30T09:25:00"), version, {}});
    session.fields.insert(QStringLiteral("duration"), {qint64(1500), version, {}});
    batch.records.append(session);
    batch.settings.append({QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), version, {}});

    SignalRecorder recorder;
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    // 应用过程本身一个信号都不发：事务提交之前发出去，失败回滚时就收不回来了。
    QVERIFY(recorder.events.isEmpty());

    SyncNotifier::publish(result);
    const QString deleted = QStringLiteral("taskDeleted:%1").arg(taskId);
    // 先删除事实、后列表刷新：计时器这类持有任务编号的服务先解绑。
    QCOMPARE(recorder.events.first(), deleted);
    QVERIFY(recorder.events.indexOf(QStringLiteral("tasksChanged")) > recorder.events.indexOf(deleted));
    for (const char* expected : {"categoriesChanged", "routinesChanged", "historyChanged", "dayStartHourChanged"}) {
        QVERIFY2(recorder.events.contains(QString::fromLatin1(expected)), expected);
    }
    // 逻辑日起点写回了 AppSettings。
    QCOMPARE(AppSettings::instance()->dayStartHour(), 5);

    // 只动了专注记录的一批：不发科目、例行的信号，也不整库重载。
    SignalRecorder onlyHistory;
    SyncBatch sessionsOnly;
    sessionsOnly.device = remote;
    SyncRecord longer = session;
    longer.fields.insert(QStringLiteral("duration"), {qint64(1200), {kFuture + 1, remote}, {}});
    sessionsOnly.records.append(longer);
    const SyncStore::ApplyResult second = SyncStore().applyRemote(sessionsOnly);
    QVERIFY(second.ok);
    SyncNotifier::publish(second);
    QVERIFY(!onlyHistory.events.contains(QStringLiteral("categoriesChanged")));
    QVERIFY(!onlyHistory.events.contains(QStringLiteral("routinesChanged")));
    QVERIFY(onlyHistory.events.contains(QStringLiteral("historyChanged")));
}

void SyncTests::failedApplyPublishesNothing()
{
    RoutineManager::instance();
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("还在的任务"), today(), -1, 0, QString());
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncBatch batch;
    batch.device = remote;
    batch.epoch = 7;  // 纪元不对：整批拒绝
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId),
                                        {kFuture, remote}));

    SignalRecorder recorder;
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY(!result.ok);
    SyncNotifier::publish(result);
    QVERIFY(recorder.events.isEmpty());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE id = %1").arg(taskId)), 1);
}

void SyncTests::remoteDeletionUnbindsRunningTimer()
{
    // 另一台删掉了本机正在计时的任务：计时照常继续，只是不再挂在这条任务上，
    // 活动状态里也不能留着旧编号，否则重启恢复时会带回一个已经不存在的任务。
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("正在计时的"), today(), -1, 0, QString());
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("正在计时的")));
    QCOMPARE(FocusTimer::instance()->currentTaskId(), taskId);

    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncBatch batch;
    batch.device = remote;
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId),
                                        {kFuture, remote}));
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    QVERIFY(result.deletedTaskIds.contains(taskId));
    SyncNotifier::publish(result);

    QCOMPARE(FocusTimer::instance()->currentTaskId(), -1);
    QVERIFY(FocusTimer::instance()->hasActiveSession());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NULL AND task_id IS NULL")), 1);
    QVERIFY(scalar(QStringLiteral("SELECT task_id FROM active_focus_state")).isNull());
}

QTEST_MAIN(SyncTests)
#include "SyncTests.moc"
