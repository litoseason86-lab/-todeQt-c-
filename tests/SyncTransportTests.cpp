#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QSaveFile>
#include <QScopeGuard>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <QWaitCondition>
#include <QtTest>

#include <functional>
#include <memory>

#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/SyncEngine.h"
#include "../src/services/SyncFiles.h"
#include "../src/services/SyncRecord.h"
#include "../src/services/SyncStore.h"
#include "../src/services/SyncWorker.h"
#include "../src/platform/macos/MacSyncFolder.h"

// 设备间同步的云盘传输（050 阶段 3）的测试。
//
// 3a 只看文件本身：文件名和位置的互转、四种文件的内容，以及坏文件、新版本文件能不能被认出来。
// 这一层不碰磁盘，所以直接比较字节与结构。
// 3b 看本地目录的读写：原子替换、错误归类（不存在、不可用）。
// 3c 看传输记账：读到哪、写到哪都记在库里，重开之后还在。
// 3d 起是两台设备的场景：每台设备一个真实结构的临时库、一个 SyncEngine，加一份自己的「云盘副本」
// （相当于它看到的 iCloud 云盘文件夹）。设备只读写自己的副本，测试用 FakeICloud::deliver 把一台写的文件
// 送到另一台的副本里：可以只送一部分、调换顺序、晚一点送，模拟 iCloud 的延迟与乱序。
// 引擎的定时器在测试里拨到一小时，一轮同步只在调用 syncOnce 时发生，结果不受跑测试时的快慢影响。
namespace {

const QString kDeviceA = QStringLiteral("0123456789abcdef0123456789abcdef");
const QString kDeviceB = QStringLiteral("fedcba9876543210fedcba9876543210");

// 一批带一条任务改动和一个设置项的改动，用来检查文件能不能把批次原样带过去。
SyncBatch sampleBatch(const QString& device, qint64 epoch)
{
    SyncBatch batch;
    batch.device = device;
    batch.epoch = epoch;
    SyncRecord record;
    record.table = QStringLiteral("tasks");
    record.syncId = QStringLiteral("task-1");
    SyncFieldValue title;
    title.value = QStringLiteral("背单词");
    title.version = {1790000000000, device};
    title.base = {1780000000000, kDeviceB};
    record.fields.insert(QStringLiteral("title"), title);
    batch.records.append(record);
    SyncRecord deleted;
    deleted.table = QStringLiteral("categories");
    deleted.syncId = QStringLiteral("cat-1");
    deleted.deleted = true;
    deleted.deleteVersion = {1790000000001, device};
    deleted.deleteKind = QStringLiteral("merge");
    deleted.mergedInto = QStringLiteral("cat-2");
    batch.records.append(deleted);
    batch.settings.append({QStringLiteral("logic/dayStartHour"), QStringLiteral("5"),
                           {1790000000002, device}, {0, QString()}});
    return batch;
}

// 一台「设备」：用应用自己的初始化建出完整结构的临时库（含 v18 同步表与触发器，各自一个设备标识），
// 再单独开一条连接当作这台设备。和 SyncTests 的做法一致：测试一律用真实的建表逻辑。
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

// 把一份快照写成可比较的文字：每条记录一行，字段按名字排序，带上值和版本。
// 两台设备导出的快照文字相同，就说明它们的同步数据完全一致。
QStringList describe(const SyncBatch& snapshot)
{
    QStringList lines;
    for (const SyncRecord& record : snapshot.records) {
        QStringList parts{record.table, record.syncId};
        if (record.deleted) {
            parts << QStringLiteral("deleted:%1@%2/%3").arg(record.deleteKind).arg(record.deleteVersion.time)
                         .arg(record.deleteVersion.device);
        }
        QStringList fields = record.fields.keys();
        fields.sort();
        for (const QString& field : fields) {
            const SyncFieldValue value = record.fields.value(field);
            parts << QStringLiteral("%1=%2@%3/%4").arg(field, SyncJson::canonicalValue(value.value))
                         .arg(value.version.time).arg(value.version.device);
        }
        lines << parts.join(QLatin1Char('|'));
    }
    for (const SyncSettingRecord& setting : snapshot.settings) {
        lines << QStringLiteral("setting|%1=%2@%3/%4").arg(setting.key, setting.value).arg(setting.version.time)
                     .arg(setting.version.device);
    }
    lines.sort();
    return lines;
}

QStringList describe(const Device& device)
{
    return describe(SyncStore(device.connection).exportSnapshot());
}

bool copyIfDifferent(const QString& source, const QString& target)
{
    QFile in(source);
    if (!in.open(QIODevice::ReadOnly)) {
        return false;
    }
    const QByteArray data = in.readAll();
    QFile existing(target);
    if (existing.open(QIODevice::ReadOnly) && existing.readAll() == data) {
        return true;
    }
    QDir().mkpath(QFileInfo(target).absolutePath());
    QSaveFile out(target);
    return out.open(QIODevice::WriteOnly) && out.write(data) == data.size() && out.commit();
}

// 假 iCloud：每台设备一份本地副本，设备只读写自己的那一份。deliver 把一台设备写的文件
// （它自己的设备目录，以及它建的标记文件）送到另一台的副本里：新增、更新，以及删除它那边已经删掉的。
// hold 返回 true 的文件这次先扣下不送，模拟还在路上。
class FakeICloud
{
public:
    explicit FakeICloud(QString root) : m_root(std::move(root)) {}

    QString replica(const Device& device) const
    {
        const QString base = m_root + QLatin1Char('/') + device.connection;
        QDir().mkpath(base);
        return base + QStringLiteral("/番茄Todo同步");
    }

    void deliver(const Device& from, const Device& to, const std::function<bool(const QString&)>& hold = {})
    {
        const QString source = replica(from);
        const QString target = replica(to);
        const QString own = SyncFiles::deviceDirectory(from.id);
        QSet<QString> present;
        QDirIterator files(source + QLatin1Char('/') + own, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
        while (files.hasNext()) {
            const QString path = files.next();
            // 写到一半的临时文件不会被 iCloud 送出去：它很快就被改名换掉了。
            if (SyncFiles::isTemporaryFileName(QFileInfo(path).fileName())) {
                continue;
            }
            const QString relative = QDir(source).relativeFilePath(path);
            present.insert(relative);
            if (hold && hold(relative)) {
                continue;
            }
            copyIfDifferent(path, target + QLatin1Char('/') + relative);
        }
        QDirIterator delivered(target + QLatin1Char('/') + own, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
        while (delivered.hasNext()) {
            const QString path = delivered.next();
            const QString relative = QDir(target).relativeFilePath(path);
            if (!present.contains(relative) && !(hold && hold(relative))) {
                QFile::remove(path);
            }
        }
        const QString marker = source + QLatin1Char('/') + SyncFiles::markerFileName();
        QFile markerFile(marker);
        SyncFiles::Marker parsed;
        QString error;
        if (markerFile.open(QIODevice::ReadOnly)
            && SyncFiles::decodeMarker(markerFile.readAll(), &parsed, &error) == SyncFiles::ParseStatus::Ok
            && parsed.createdBy == from.id && !(hold && hold(SyncFiles::markerFileName()))) {
            copyIfDifferent(marker, target + QLatin1Char('/') + SyncFiles::markerFileName());
        }
    }

    // 两个方向都送一遍。
    void exchange(const Device& a, const Device& b)
    {
        deliver(a, b);
        deliver(b, a);
    }

    QString path(const Device& device, const QString& relative) const
    {
        return replica(device) + QLatin1Char('/') + relative;
    }

    // 某台设备的副本里，owner 写的改动文件（文件名，升序）。
    QStringList changeFiles(const Device& replicaOf, const Device& owner) const
    {
        QStringList names = QDir(path(replicaOf, SyncFiles::changesDirectory(owner.id))).entryList(QDir::Files, QDir::Name);
        return names;
    }

    QStringList snapshotFiles(const Device& replicaOf, const Device& owner) const
    {
        return QDir(path(replicaOf, SyncFiles::deviceDirectory(owner.id)))
            .entryList({QStringLiteral("snapshot-*.json")}, QDir::Files, QDir::Name);
    }

private:
    QString m_root;
};

// 一台设备：库、引擎，以及它收到的界面通知与自动备份。
struct Node {
    Device device;
    std::unique_ptr<SyncEngine> engine;
    QList<SyncStore::ApplyResult> notified;
    // 每次自动备份时本机有哪些任务：用来确认备份发生在替换之前。
    QList<QStringList> backups;
    bool backupSucceeds = true;
};

SyncEngine::Options testOptions()
{
    SyncEngine::Options options;
    // 定时器拨到一小时：一轮同步只在测试调用 syncOnce 时发生。
    options.tickMs = 60 * 60 * 1000;
    options.publishIntervalMs = 0;
    options.scanIntervalMs = 0;
    options.retryMinMs = 0;
    options.retryMaxMs = 0;
    return options;
}

// 同步一轮并等它（以及它要求紧接着做的几轮）做完。
bool syncOnce(Node& node, int timeoutMs = 10000)
{
    node.engine->syncNow();
    QElapsedTimer timer;
    timer.start();
    while (!node.engine->isIdle()) {
        if (timer.elapsed() > timeoutMs) {
            return false;
        }
        QTest::qWait(1);
    }
    return true;
}

bool waitIdle(SyncEngine& engine, int timeoutMs = 10000)
{
    QElapsedTimer timer;
    timer.start();
    while (!engine.isIdle()) {
        if (timer.elapsed() > timeoutMs) {
            return false;
        }
        QTest::qWait(1);
    }
    return true;
}

bool fileExists(const QString& path)
{
    return QFileInfo::exists(path);
}

// 把一个 JSON 对象改一处再编码回去，用来造各种坏文件。
QByteArray tamper(const QByteArray& bytes, const std::function<void(QJsonObject&)>& change)
{
    QJsonObject object = QJsonDocument::fromJson(bytes).object();
    change(object);
    return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

} // namespace

class SyncTransportTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    // 3a：文件格式
    void fileNamesRoundTripAndRejectForeignNames();
    void deviceIdsTemporaryNamesAndEmptyFolders();
    void filesRoundTrip();
    void corruptFilesAreRecognized_data();
    void corruptFilesAreRecognized();
    void newerFormatsAreNotTreatedAsCorrupt();
    void wrongFolderHints_data();
    void wrongFolderHints();

    // 3b：文件夹读写
    void localFolderReadsWritesListsAndRemoves();
    void localFolderReplacesFilesAtomically();
    void localFolderClassifiesMissingAndUnavailable();

    // 3c：传输记账
    void transportProgressIsKeptInDatabase();
    void pendingCountFollowsOutboxAndSettings();
    void fileProblemsGoToSyncLog();

    // 3d：引擎主循环
    void macCreatesFolderWithMarkerAndSnapshot();
    void joiningNeedsConfirmationAndBacksUpFirst();
    void changesTravelBothWaysInBatches();
    void filesArrivingOutOfOrderWaitForTheGap();
    void redeliveredFilesChangeNothing();
    void sequenceIsNotReusedAfterUnacknowledgedWrite();
    void wrongFolderIsReportedWithHint();
    void joinWaitsWhileSnapshotIsStillUploading();
    void batchingWaitsUntilIntervalOrBackground();
    void backgroundTaskCoversFlushAfterCycleInProgress();
    void flushBeforeExitWritesPendingChanges();
    void fileWorkRunsOffTheMainThread();
    void everyCycleRelinksReferencesWhoseTargetIsBack();

    // 3e：快照、清理与全局回滚
    void oldFilesAreDeletedOnlyAfterEveryoneReadThem();
    void compactionSnapshotDoesNotSwallowPendingChanges();
    void lateDeviceCatchesUpFromSnapshotAfterCleanup();
    void farBehindDeviceReadsSnapshotInsteadOfManyFiles();
    void restoringBackupRollsBackTheOtherDevice();
    void rollbackWaitsForSnapshotAndForBackup();
    void lostFileIsRecoveredThroughSnapshotRequest();

    // 3f：异常与暂停
    void corruptFileIsSkippedLoggedAndHealedBySnapshot();
    void newerFormatFileStopsWithoutSkipping();
    void memoFormatThreeWritesAndReadsVersionsOneThroughThree();
    void newerBatchFormatStopsWithoutAdvancingMemoCursor();
    void readFailureIsRetriedNotSkipped();
    void stuckFolderOperationIsAbandonedAndRetried();
    void slowButSteadyFolderIsNotAbandoned();
    void noSpaceKeepsChangesUntilSpaceReturns();
    void unavailableFolderPausesAndResumes();
    void uploadProblemIsShown();
    void strayFilesAreIgnoredAndOwnLeftoversCleaned();
    void missingMarkerAfterJoinIsNotRecreated();

    // 3g：平台层（Mac）
    void macFolderLivesInsideICloudDrive();
    void macFolderIsUnavailableWithoutICloudDrive();

private:
    Device openDevice(const QString& name);
    void reopen(Device& device);
    std::unique_ptr<Node> makeNode(const QString& name, bool mayCreateFolder, FakeICloud& cloud,
                                   SyncEngine::Options options = testOptions());
    // Mac 建好文件夹、iPad 确认加入，iPad 的游标文件也送到了 Mac：两台都进入日常同步的状态。
    void setUpPair(FakeICloud& cloud, std::unique_ptr<Node>* mac, std::unique_ptr<Node>* ipad,
                   const SyncEngine::Options& options = testOptions());
    // 模拟一台设备恢复备份：换回备份时的库文件，开新纪元（设备标识保持恢复前的）。
    void restoreBackup(Node& node, const QString& backupPath);

    QTemporaryDir m_preferences;
    std::unique_ptr<QTemporaryDir> m_data;
    QStringList m_connections;
};

void SyncTransportTests::fileNamesRoundTripAndRejectForeignNames()
{
    SyncPosition position;
    QCOMPARE(SyncFiles::changeFileName({3, 42}), QStringLiteral("0003-00000042.json"));
    QVERIFY(SyncFiles::parseChangeFileName(SyncFiles::changeFileName({3, 42}), &position));
    QCOMPARE(position, (SyncPosition{3, 42}));
    // 位数超过补齐的宽度也照样能读：程序按数字比较，不按名字排序。
    QVERIFY(SyncFiles::parseChangeFileName(QStringLiteral("12345-123456789.json"), &position));
    QCOMPARE(position, (SyncPosition{12345, 123456789}));

    QCOMPARE(SyncFiles::snapshotFileName({0, 0}), QStringLiteral("snapshot-0000-00000000.json"));
    QVERIFY(SyncFiles::parseSnapshotFileName(SyncFiles::snapshotFileName({7, 0}), &position));
    QCOMPARE(position, (SyncPosition{7, 0}));

    // 不是本应用写的名字：写到一半的临时文件、iCloud 占位文件、冲突副本、系统文件、第 0 批改动。
    for (const QString& foreign : {QStringLiteral("0003-00000042.json.AbC123"), QStringLiteral(".0003-00000042.json.icloud"),
                                   QStringLiteral("0003-00000042 2.json"), QStringLiteral(".DS_Store"),
                                   QStringLiteral("0003-00000000.json"), QStringLiteral("0003-00000042.JSON"),
                                   QStringLiteral("snapshot-0003-00000042.json"), QStringLiteral("-1-3.json")}) {
        QVERIFY2(!SyncFiles::parseChangeFileName(foreign, nullptr), qPrintable(foreign));
    }
    for (const QString& foreign : {QStringLiteral("snapshot-0003-00000042 2.json"), QStringLiteral("0003-00000042.json"),
                                   QStringLiteral("snapshot-0003-00000042.json.x1Y2z3")}) {
        QVERIFY2(!SyncFiles::parseSnapshotFileName(foreign, nullptr), qPrintable(foreign));
    }
}

void SyncTransportTests::deviceIdsTemporaryNamesAndEmptyFolders()
{
    QVERIFY(SyncFiles::isDeviceId(kDeviceA));
    for (const QString& name : {QStringLiteral("0123456789ABCDEF0123456789ABCDEF"), QStringLiteral("../0123456789abcdef"),
                                QStringLiteral("0123456789abcdef0123456789abcde"), QStringLiteral(".DS_Store"), QString()}) {
        QVERIFY2(!SyncFiles::isDeviceId(name), qPrintable(name));
    }

    QVERIFY(SyncFiles::isTemporaryFileName(QStringLiteral("0003-00000042.json.AbC123")));
    QVERIFY(SyncFiles::isTemporaryFileName(QStringLiteral("cursor.json.q1W2e3")));
    QVERIFY(!SyncFiles::isTemporaryFileName(QStringLiteral("0003-00000042.json")));
    QVERIFY(!SyncFiles::isTemporaryFileName(QStringLiteral("notes.txt.AbC123")));

    QVERIFY(SyncFiles::isEffectivelyEmpty({}));
    QVERIFY(SyncFiles::isEffectivelyEmpty({QStringLiteral(".DS_Store"), QStringLiteral(".localized")}));
    QVERIFY(!SyncFiles::isEffectivelyEmpty({QStringLiteral(".DS_Store"), QStringLiteral("论文.pdf")}));
}

void SyncTransportTests::filesRoundTrip()
{
    SyncFiles::Marker marker{QStringLiteral("5f0c2a4e-folder"), kDeviceA, QStringLiteral("2026-09-30T10:00:00")};
    SyncFiles::Marker markerBack;
    QString error;
    QCOMPARE(SyncFiles::decodeMarker(SyncFiles::encodeMarker(marker), &markerBack, &error), SyncFiles::ParseStatus::Ok);
    QCOMPARE(markerBack.folderId, marker.folderId);
    QCOMPARE(markerBack.createdBy, kDeviceA);
    QCOMPARE(markerBack.createdAt, marker.createdAt);

    const SyncFiles::ChangeFile changes{42, 1790000000123, sampleBatch(kDeviceA, 3)};
    SyncFiles::ChangeFile changesBack;
    QCOMPARE(SyncFiles::decodeChanges(SyncFiles::encodeChanges(changes), kDeviceA, {3, 42}, &changesBack, &error),
             SyncFiles::ParseStatus::Ok);
    QCOMPARE(changesBack.seq, 42);
    QCOMPARE(changesBack.writtenAtMs, 1790000000123);
    QCOMPARE(changesBack.batch.device, kDeviceA);
    QCOMPARE(changesBack.batch.epoch, 3);
    QCOMPARE(changesBack.batch.records.size(), 2);
    QCOMPARE(changesBack.batch.records.at(0).fields.value(QStringLiteral("title")).value.toString(),
             QStringLiteral("背单词"));
    QCOMPARE(changesBack.batch.records.at(0).fields.value(QStringLiteral("title")).base.device, kDeviceB);
    QCOMPARE(changesBack.batch.records.at(1).mergedInto, QStringLiteral("cat-2"));
    QCOMPARE(changesBack.batch.settings.size(), 1);
    QCOMPARE(changesBack.batch.settings.at(0).value, QStringLiteral("5"));

    SyncFiles::SnapshotFile snapshot;
    snapshot.coveredSeq = 17;
    snapshot.writtenAtMs = 1790000000456;
    snapshot.applied.insert(kDeviceB, {3, 9});
    snapshot.batch = sampleBatch(kDeviceA, 3);
    SyncFiles::SnapshotFile snapshotBack;
    QCOMPARE(SyncFiles::decodeSnapshot(SyncFiles::encodeSnapshot(snapshot), kDeviceA, {3, 17}, &snapshotBack, &error),
             SyncFiles::ParseStatus::Ok);
    QCOMPARE(snapshotBack.coveredSeq, 17);
    QCOMPARE(snapshotBack.applied.value(kDeviceB), (SyncPosition{3, 9}));
    QCOMPARE(snapshotBack.batch.records.size(), 2);

    SyncFiles::CursorFile cursor;
    cursor.device = kDeviceB;
    cursor.epoch = 3;
    cursor.writtenAtMs = 1790000000789;
    cursor.applied.insert(kDeviceA, {3, 40});
    cursor.snapshotRequests.insert(kDeviceA, {3, 41});
    SyncFiles::CursorFile cursorBack;
    QCOMPARE(SyncFiles::decodeCursor(SyncFiles::encodeCursor(cursor), kDeviceB, &cursorBack, &error),
             SyncFiles::ParseStatus::Ok);
    QCOMPARE(cursorBack.epoch, 3);
    QCOMPARE(cursorBack.writtenAtMs, 1790000000789);
    QCOMPARE(cursorBack.applied.value(kDeviceA), (SyncPosition{3, 40}));
    QCOMPARE(cursorBack.snapshotRequests.value(kDeviceA), (SyncPosition{3, 41}));
}

void SyncTransportTests::corruptFilesAreRecognized_data()
{
    QTest::addColumn<QByteArray>("bytes");
    QTest::addColumn<QString>("kind");

    const QByteArray changes = SyncFiles::encodeChanges({42, 1790000000123, sampleBatch(kDeviceA, 3)});
    QTest::newRow("不是 JSON") << QByteArray("{\"format\":1,\"type\":\"chan") << QStringLiteral("changes");
    QTest::newRow("空文件") << QByteArray() << QStringLiteral("changes");
    QTest::newRow("不是对象") << QByteArray("[1,2,3]") << QStringLiteral("changes");
    QTest::newRow("缺格式版本") << tamper(changes, [](QJsonObject& o) { o.remove(QStringLiteral("format")); })
                             << QStringLiteral("changes");
    QTest::newRow("格式版本是 0") << tamper(changes, [](QJsonObject& o) { o.insert(QStringLiteral("format"), 0); })
                              << QStringLiteral("changes");
    QTest::newRow("类型不对") << tamper(changes, [](QJsonObject& o) { o.insert(QStringLiteral("type"), QStringLiteral("snapshot")); })
                          << QStringLiteral("changes");
    QTest::newRow("序号和文件名不同") << tamper(changes, [](QJsonObject& o) { o.insert(QStringLiteral("seq"), 41); })
                                << QStringLiteral("changes");
    QTest::newRow("序号不是整数") << tamper(changes, [](QJsonObject& o) { o.insert(QStringLiteral("seq"), 42.5); })
                              << QStringLiteral("changes");
    QTest::newRow("缺改动内容") << tamper(changes, [](QJsonObject& o) { o.remove(QStringLiteral("batch")); })
                             << QStringLiteral("changes");
    QTest::newRow("设备和目录不同") << tamper(changes, [](QJsonObject& o) {
        QJsonObject batch = o.value(QStringLiteral("batch")).toObject();
        batch.insert(QStringLiteral("device"), kDeviceB);
        o.insert(QStringLiteral("batch"), batch);
    }) << QStringLiteral("changes");
    QTest::newRow("纪元和文件名不同") << tamper(changes, [](QJsonObject& o) {
        QJsonObject batch = o.value(QStringLiteral("batch")).toObject();
        batch.insert(QStringLiteral("epoch"), 2);
        o.insert(QStringLiteral("batch"), batch);
    }) << QStringLiteral("changes");

    SyncFiles::SnapshotFile snapshotFile;
    snapshotFile.coveredSeq = 42;
    snapshotFile.batch = sampleBatch(kDeviceA, 3);
    const QByteArray snapshot = SyncFiles::encodeSnapshot(snapshotFile);
    QTest::newRow("快照覆盖序号不同") << tamper(snapshot, [](QJsonObject& o) { o.insert(QStringLiteral("coveredSeq"), 7); })
                                << QStringLiteral("snapshot");
    QTest::newRow("快照进度键不是设备") << tamper(snapshot, [](QJsonObject& o) {
        o.insert(QStringLiteral("applied"), QJsonObject{{QStringLiteral("../x"), QJsonObject{{QStringLiteral("epoch"), 3},
                                                                                         {QStringLiteral("seq"), 1}}}});
    }) << QStringLiteral("snapshot");

    SyncFiles::CursorFile cursorFile;
    cursorFile.device = kDeviceA;
    const QByteArray cursor = SyncFiles::encodeCursor(cursorFile);
    QTest::newRow("游标设备不同") << tamper(cursor, [](QJsonObject& o) { o.insert(QStringLiteral("device"), kDeviceB); })
                              << QStringLiteral("cursor");
    QTest::newRow("游标进度是负数") << tamper(cursor, [](QJsonObject& o) {
        o.insert(QStringLiteral("requests"), QJsonObject{{kDeviceB, QJsonObject{{QStringLiteral("epoch"), 0},
                                                                              {QStringLiteral("seq"), -1}}}});
    }) << QStringLiteral("cursor");

    const QByteArray marker = SyncFiles::encodeMarker({QStringLiteral("folder"), kDeviceA, QString()});
    QTest::newRow("标记缺文件夹身份") << tamper(marker, [](QJsonObject& o) { o.remove(QStringLiteral("folderId")); })
                                << QStringLiteral("marker");
    QTest::newRow("标记的建立者不是设备") << tamper(marker, [](QJsonObject& o) { o.insert(QStringLiteral("createdBy"), QStringLiteral("mac")); })
                                  << QStringLiteral("marker");
}

void SyncTransportTests::corruptFilesAreRecognized()
{
    QFETCH(QByteArray, bytes);
    QFETCH(QString, kind);
    QString error;
    SyncFiles::ParseStatus status = SyncFiles::ParseStatus::Ok;
    if (kind == QLatin1String("changes")) {
        SyncFiles::ChangeFile file;
        status = SyncFiles::decodeChanges(bytes, kDeviceA, {3, 42}, &file, &error);
    } else if (kind == QLatin1String("snapshot")) {
        SyncFiles::SnapshotFile file;
        status = SyncFiles::decodeSnapshot(bytes, kDeviceA, {3, 42}, &file, &error);
    } else if (kind == QLatin1String("cursor")) {
        SyncFiles::CursorFile file;
        status = SyncFiles::decodeCursor(bytes, kDeviceA, &file, &error);
    } else {
        SyncFiles::Marker marker;
        status = SyncFiles::decodeMarker(bytes, &marker, &error);
    }
    QCOMPARE(status, SyncFiles::ParseStatus::Corrupt);
    // 原因会写进同步日志给人看，不能是空的。
    QVERIFY(!error.isEmpty());
}

void SyncTransportTests::newerFormatsAreNotTreatedAsCorrupt()
{
    // 更新版本的应用写的文件：对方的数据是好的，只是本机读不懂，不能当坏文件跳过（跳过就丢了）。
    const QByteArray changes = SyncFiles::encodeChanges({42, 1790000000123, sampleBatch(kDeviceA, 3)});
    SyncFiles::ChangeFile file;
    QString error;
    const QByteArray newerOuter = tamper(changes, [](QJsonObject& o) {
        o.insert(QStringLiteral("format"), SyncFiles::kFormatVersion + 1);
        o.insert(QStringLiteral("seq"), QStringLiteral("以后换了写法"));
    });
    QCOMPARE(SyncFiles::decodeChanges(newerOuter, kDeviceA, {3, 42}, &file, &error), SyncFiles::ParseStatus::NewerFormat);
    QVERIFY(error.contains(QStringLiteral("更新")));

    const QByteArray newerBatch = tamper(changes, [](QJsonObject& o) {
        QJsonObject batch = o.value(QStringLiteral("batch")).toObject();
        batch.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1);
        o.insert(QStringLiteral("batch"), batch);
    });
    QCOMPARE(SyncFiles::decodeChanges(newerBatch, kDeviceA, {3, 42}, &file, &error), SyncFiles::ParseStatus::NewerFormat);

    const QByteArray marker = SyncFiles::encodeMarker({QStringLiteral("folder"), kDeviceA, QString()});
    SyncFiles::Marker parsed;
    QCOMPARE(SyncFiles::decodeMarker(tamper(marker, [](QJsonObject& o) {
                                         o.insert(QStringLiteral("format"), SyncFiles::kFormatVersion + 1);
                                     }), &parsed, &error),
             SyncFiles::ParseStatus::NewerFormat);
}

void SyncTransportTests::wrongFolderHints_data()
{
    QTest::addColumn<QString>("folderName");
    QTest::addColumn<QStringList>("entries");
    QTest::addColumn<QString>("expected");

    const QString inner = QStringLiteral("回到上一层");
    QTest::newRow("选成了 devices") << QStringLiteral("devices") << QStringList{kDeviceA, kDeviceB} << inner;
    QTest::newRow("选成了某台设备的目录") << kDeviceA
                                << QStringList{QStringLiteral("changes"), QStringLiteral("cursor.json")} << inner;
    QTest::newRow("选成了 changes") << QStringLiteral("changes") << QStringList{QStringLiteral("0000-00000001.json")}
                                  << inner;
    QTest::newRow("选成了外面一层") << QStringLiteral("iCloud 云盘")
                             << QStringList{QStringLiteral("番茄Todo同步"), QStringLiteral("论文")}
                             << QStringLiteral("先点进");
    QTest::newRow("缺标记文件") << QStringLiteral("番茄Todo同步") << QStringList{QStringLiteral("devices")}
                           << QStringLiteral("找不到标记文件");
    QTest::newRow("无关文件夹") << QStringLiteral("文稿") << QStringList{QStringLiteral("论文.pdf")}
                           << QStringLiteral("不是番茄Todo 的同步文件夹");
}

void SyncTransportTests::wrongFolderHints()
{
    QFETCH(QString, folderName);
    QFETCH(QStringList, entries);
    QFETCH(QString, expected);
    const QString hint = SyncFiles::wrongFolderHint(folderName, entries);
    QVERIFY2(hint.contains(expected), qPrintable(hint));
}

// ── 3b：文件夹读写 ──

void SyncTransportTests::localFolderReadsWritesListsAndRemoves()
{
    QTemporaryDir temp;
    QVERIFY(temp.isValid());
    // 根目录还不存在（Mac 第一次开启同步）：能打开，列根目录报不存在，第一次写入时连目录一起建出来。
    LocalSyncFolder folder(temp.filePath(QStringLiteral("番茄Todo同步")));
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    QCOMPARE(folder.name(), QStringLiteral("番茄Todo同步"));
    QVERIFY(folder.list(QString(), &error).isEmpty());
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);

    const QString path = SyncFiles::changesDirectory(kDeviceA) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    QVERIFY(folder.write(path, QByteArray("第一批"), &error));
    QVERIFY(error.ok());
    QByteArray data;
    QVERIFY(folder.read(path, &data, &error));
    QCOMPARE(data, QByteArray("第一批"));
    QCOMPARE(folder.list(SyncFiles::devicesDirectory(), &error), QStringList{kDeviceA});
    QVERIFY(error.ok());
    QCOMPARE(folder.list(SyncFiles::changesDirectory(kDeviceA), &error), QStringList{SyncFiles::changeFileName({0, 1})});

    // 隐藏文件也要列出来：清理本机目录、判断文件夹是不是空的都要看到它们。
    QFile hidden(temp.filePath(QStringLiteral("番茄Todo同步/.DS_Store")));
    QVERIFY(hidden.open(QIODevice::WriteOnly));
    hidden.close();
    QVERIFY(folder.list(QString(), &error).contains(QStringLiteral(".DS_Store")));

    QVERIFY(folder.remove(path, &error));
    QVERIFY(folder.list(SyncFiles::changesDirectory(kDeviceA), &error).isEmpty());
    QVERIFY(error.ok());
    // 本来就不存在也算删除成功：清理时对方可能已经删过，不能因此报错。
    QVERIFY(folder.remove(path, &error));
    QVERIFY(!folder.read(path, &data, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);
}

void SyncTransportTests::localFolderReplacesFilesAtomically()
{
    QTemporaryDir temp;
    QVERIFY(temp.isValid());
    LocalSyncFolder folder(temp.path());
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    const QString path = SyncFiles::deviceDirectory(kDeviceA) + QLatin1Char('/') + SyncFiles::cursorFileName();
    QVERIFY(folder.write(path, QByteArray(4096, 'a'), &error));
    QVERIFY(folder.write(path, QByteArray("短"), &error));
    QByteArray data;
    QVERIFY(folder.read(path, &data, &error));
    // 新内容整体换上，不是在旧文件上覆盖开头（那样会留下旧内容的尾巴）。
    QCOMPARE(data, QByteArray("短"));
    // 写完不留临时文件：对方的目录里只该出现完整的文件。
    QCOMPARE(folder.list(SyncFiles::deviceDirectory(kDeviceA), &error), QStringList{SyncFiles::cursorFileName()});
}

void SyncTransportTests::localFolderClassifiesMissingAndUnavailable()
{
    QTemporaryDir temp;
    QVERIFY(temp.isValid());
    SyncFolder::Error error;
    // 上一级都不存在：相当于 Mac 上没有 iCloud 云盘目录（没登录或关了云盘），整个位置不可用。
    LocalSyncFolder missingParent(temp.filePath(QStringLiteral("没有这一层/番茄Todo同步")));
    QVERIFY(!missingParent.open(&error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Unavailable);

    LocalSyncFolder folder(temp.filePath(QStringLiteral("root")));
    QVERIFY(folder.write(QStringLiteral("devices/x.json"), QByteArray("x"), &error));
    QVERIFY(folder.list(QStringLiteral("devices/没有的目录"), &error).isEmpty());
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);

    // 没有权限：同步要暂停等它恢复，而不是当成「目录是空的」继续走下去。
    const QString devices = temp.filePath(QStringLiteral("root/devices"));
    QVERIFY(QFile::setPermissions(devices, QFileDevice::Permissions()));
    QVERIFY(folder.list(QStringLiteral("devices"), &error).isEmpty());
    QFile::setPermissions(devices, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Unavailable);
}

// ── 3c：传输记账 ──

void SyncTransportTests::initTestCase()
{
    QVERIFY(m_preferences.isValid());
    // AppSettings 单例只落到临时 INI：例行生成、设置写回都不能碰真实偏好。
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoSyncTransportTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SyncTransportTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    AppSettings::instance()->setDayStartHour(4);
}

void SyncTransportTests::init()
{
    m_data = std::make_unique<QTemporaryDir>();
    QVERIFY(m_data->isValid());
}

void SyncTransportTests::cleanup()
{
    DatabaseManager::instance()->close();
    for (const QString& connection : std::as_const(m_connections)) {
        {
            QSqlDatabase database = QSqlDatabase::database(connection, false);
            database.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }
    m_connections.clear();
    m_data.reset();
}

Device SyncTransportTests::openDevice(const QString& name)
{
    Device device;
    device.path = m_data->filePath(name + QStringLiteral(".sqlite"));
    if (!DatabaseManager::instance()->initialize(device.path)) {
        qWarning() << "initialize failed" << device.path;
    }
    DatabaseManager::instance()->close();
    device.connection = QStringLiteral("transport-device-") + name;
    QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), device.connection);
    database.setDatabaseName(device.path);
    database.open();
    QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
    QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    m_connections.append(device.connection);
    device.id = SyncStore(device.connection).deviceId();
    return device;
}

// 关掉再打开同一个库：记账要落在库文件里，不能只在连接的内存里。
void SyncTransportTests::reopen(Device& device)
{
    {
        QSqlDatabase database = QSqlDatabase::database(device.connection, false);
        database.close();
    }
    QVERIFY(QSqlDatabase::database(device.connection).isOpen());
}

void SyncTransportTests::transportProgressIsKeptInDatabase()
{
    Device device = openDevice(QStringLiteral("a"));
    SyncStore store(device.connection);
    // 新库：没加入过文件夹、没读过任何设备、一批都没写过。
    QVERIFY(store.folderId().isEmpty());
    QVERIFY(store.peerCursors().isEmpty());
    QCOMPARE(store.outboundPosition(), (SyncPosition{0, 0}));
    QCOMPARE(store.snapshotPosition(), (SyncPosition{0, 0}));
    QVERIFY(store.snapshotRequests().isEmpty());
    QVERIFY(!store.lastSyncedAt().isValid());

    const QDateTime synced = QDateTime::fromString(QStringLiteral("2026-09-30T10:11:12.345"), Qt::ISODateWithMs);
    QVERIFY(store.setFolderId(QStringLiteral("folder-1")));
    QVERIFY(store.setPeerCursor(kDeviceA, {2, 40}));
    QVERIFY(store.setPeerCursor(kDeviceB, {2, 7}));
    QVERIFY(store.setOutboundPosition({2, 12}));
    QVERIFY(store.setSnapshotPosition({2, 10}));
    QVERIFY(store.setSnapshotRequest(kDeviceB, {2, 8}));
    QVERIFY(store.setLastSyncedAt(synced));

    reopen(device);
    SyncStore reopened(device.connection);
    QCOMPARE(reopened.folderId(), QStringLiteral("folder-1"));
    QCOMPARE(reopened.peerCursors().size(), 2);
    QCOMPARE(reopened.peerCursors().value(kDeviceA), (SyncPosition{2, 40}));
    QCOMPARE(reopened.outboundPosition(), (SyncPosition{2, 12}));
    QCOMPARE(reopened.snapshotPosition(), (SyncPosition{2, 10}));
    QCOMPARE(reopened.snapshotRequests().value(kDeviceB), (SyncPosition{2, 8}));
    QCOMPARE(reopened.lastSyncedAt(), synced);

    // 整体换掉游标：旧的一个不留（首次加入后按快照重新起步，旧纪元的进度作废）。
    QVERIFY(reopened.replacePeerCursors({{kDeviceB, {3, 0}}}));
    QCOMPARE(reopened.peerCursors().size(), 1);
    QCOMPARE(reopened.peerCursors().value(kDeviceB), (SyncPosition{3, 0}));
    QVERIFY(reopened.clearSnapshotRequest(kDeviceB));
    QVERIFY(reopened.snapshotRequests().isEmpty());
    QVERIFY(reopened.setFolderId(QString()));
    QVERIFY(reopened.folderId().isEmpty());
    // 记账不碰同步本身的状态：设备标识和纪元都还在。
    QCOMPARE(reopened.deviceId(), device.id);

    // 外部改坏的进度按「一批都没有」处理：宁可重读，不能跳过没读过的。
    QVERIFY(exec(device, QStringLiteral("UPDATE sync_state SET value = 'x:y' WHERE key = 'outbound'")));
    QCOMPARE(reopened.outboundPosition(), (SyncPosition{0, 0}));
}

void SyncTransportTests::pendingCountFollowsOutboxAndSettings()
{
    Device device = openDevice(QStringLiteral("a"));
    SyncStore store(device.connection);
    // 新库里预置科目已经在待发送队列里（迁移时把已有数据全部入队）。发出并确认之后就没有了。
    QVERIFY(store.hasPending());
    QVERIFY(store.acknowledge(store.collectPending()));
    QVERIFY(!store.hasPending());
    QCOMPARE(store.pendingCount(), 0);

    QVERIFY(exec(device, QStringLiteral("INSERT INTO tasks (title, date, completed, display_order) "
                                        "VALUES ('背单词', '2026-09-30', 0, 1)")));
    QVERIFY(store.hasPending());
    QCOMPARE(store.pendingCount(), 1);
    QVERIFY(store.recordLocalSetting(QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), false));
    QCOMPARE(store.pendingCount(), 2);
    QVERIFY(store.acknowledge(store.collectPending()));
    QVERIFY(!store.hasPending());
}

void SyncTransportTests::fileProblemsGoToSyncLog()
{
    Device device = openDevice(QStringLiteral("a"));
    SyncStore store(device.connection);
    const QString file = SyncFiles::changesDirectory(kDeviceB) + QLatin1Char('/') + SyncFiles::changeFileName({0, 3});
    QVERIFY(store.logFileProblem(kDeviceB, file, QStringLiteral("文件内容不是完整的 JSON")));
    QCOMPARE(scalar(device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = 'file'")).toInt(), 1);
    QCOMPARE(scalar(device, QStringLiteral("SELECT sync_id FROM sync_conflict_log")).toString(), file);
    QCOMPARE(scalar(device, QStringLiteral("SELECT record_label FROM sync_conflict_log")).toString(),
             SyncFiles::changeFileName({0, 3}));
    QCOMPARE(scalar(device, QStringLiteral("SELECT lost_device FROM sync_conflict_log")).toString(), kDeviceB);
    QVERIFY(scalar(device, QStringLiteral("SELECT detail FROM sync_conflict_log")).toString().contains(QStringLiteral("JSON")));
}

// ── 3d：引擎主循环 ──

std::unique_ptr<Node> SyncTransportTests::makeNode(const QString& name, bool mayCreateFolder, FakeICloud& cloud,
                                                  SyncEngine::Options options)
{
    auto node = std::make_unique<Node>();
    node->device = openDevice(name);
    options.mayCreateFolder = mayCreateFolder;
    node->engine = std::make_unique<SyncEngine>(std::make_unique<LocalSyncFolder>(cloud.replica(node->device)),
                                                options, node->device.connection);
    Node* raw = node.get();
    // 两台设备不共用单例服务：界面通知只记下来，不去碰单例。
    node->engine->setChangeNotifier([raw](const SyncStore::ApplyResult& result) { raw->notified.append(result); });
    node->engine->setSafetyBackup([raw](QString* error) {
        raw->backups.append(taskTitles(raw->device));
        if (!raw->backupSucceeds) {
            *error = QStringLiteral("备份目录写不进去");
        }
        return raw->backupSucceeds;
    });
    return node;
}

void SyncTransportTests::setUpPair(FakeICloud& cloud, std::unique_ptr<Node>* mac, std::unique_ptr<Node>* ipad,
                                   const SyncEngine::Options& options)
{
    *mac = makeNode(QStringLiteral("mac"), true, cloud, options);
    *ipad = makeNode(QStringLiteral("ipad"), false, cloud, options);
    (*mac)->engine->start();
    QVERIFY(waitIdle(*(*mac)->engine));
    QCOMPARE((*mac)->engine->status(), SyncEngine::Status::UpToDate);
    cloud.deliver((*mac)->device, (*ipad)->device);
    (*ipad)->engine->start();
    QVERIFY(waitIdle(*(*ipad)->engine));
    (*ipad)->engine->confirmJoin();
    QVERIFY(waitIdle(*(*ipad)->engine));
    QCOMPARE((*ipad)->engine->status(), SyncEngine::Status::UpToDate);
    cloud.deliver((*ipad)->device, (*mac)->device);
    QVERIFY(syncOnce(**mac));
}

void SyncTransportTests::restoreBackup(Node& node, const QString& backupPath)
{
    node.engine->stop();
    const qint64 epochBefore = SyncStore(node.device.connection).epoch();
    {
        QSqlDatabase database = QSqlDatabase::database(node.device.connection, false);
        database.close();
    }
    QVERIFY(QFile::remove(node.device.path));
    QVERIFY(QFile::copy(backupPath, node.device.path));
    QVERIFY(QSqlDatabase::database(node.device.connection).isOpen());
    QVERIFY(exec(node.device, QStringLiteral("PRAGMA foreign_keys = ON")));
    QVERIFY(SyncStore(node.device.connection).beginEpochAfterRestore(epochBefore, node.device.id));
    QVERIFY(SyncStore(node.device.connection).needsSnapshot());
}

void SyncTransportTests::macCreatesFolderWithMarkerAndSnapshot()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    auto mac = makeNode(QStringLiteral("mac"), true, cloud);
    QVERIFY(!addTask(mac->device, QStringLiteral("写代码")).isEmpty());
    // 根目录还不存在（第一次开启同步）：Mac 新建文件夹，写标记文件和第一份快照。
    mac->engine->start();
    QCOMPARE(mac->engine->status(), SyncEngine::Status::Starting);
    QVERIFY(waitIdle(*mac->engine));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);

    QFile markerFile(cloud.path(mac->device, SyncFiles::markerFileName()));
    QVERIFY(markerFile.open(QIODevice::ReadOnly));
    SyncFiles::Marker marker;
    QString error;
    QCOMPARE(SyncFiles::decodeMarker(markerFile.readAll(), &marker, &error), SyncFiles::ParseStatus::Ok);
    QCOMPARE(marker.createdBy, mac->device.id);
    SyncStore store(mac->device.connection);
    QCOMPARE(store.folderId(), marker.folderId);
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 0})});
    // 快照给所有设备起步用，它已经带上的改动不必再单独发：待发送清空，也没有写改动文件。
    QVERIFY(!store.needsSnapshot());
    QCOMPARE(store.pendingCount(), 0);
    QVERIFY(cloud.changeFiles(mac->device, mac->device).isEmpty());
    QVERIFY(mac->engine->lastSyncedAt().isValid());

    // 已经加入过的文件夹：再开一次直接接上，不会另建一个。
    mac->engine->stop();
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QCOMPARE(store.folderId(), marker.folderId);
}

void SyncTransportTests::joiningNeedsConfirmationAndBacksUpFirst()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    auto mac = makeNode(QStringLiteral("mac"), true, cloud);
    auto ipad = makeNode(QStringLiteral("ipad"), false, cloud);
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 的任务")).isEmpty());
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 的测试任务")).isEmpty());
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    cloud.deliver(mac->device, ipad->device);

    // 没确认之前：什么都不动，也不往文件夹里写任何东西。
    ipad->engine->start();
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NeedsConfirmation);
    QVERIFY(!ipad->engine->statusText().isEmpty());
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 的测试任务")});
    QVERIFY(ipad->backups.isEmpty());
    QVERIFY(!fileExists(cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id))));
    QVERIFY(SyncStore(ipad->device.connection).folderId().isEmpty());

    // 确认之后：先备份（备份时本机数据还在），再整体换成 Mac 的。你定了首次加入完全以 Mac 为准。
    ipad->engine->confirmJoin();
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(ipad->backups.size(), 1);
    QCOMPARE(ipad->backups.first(), QStringList{QStringLiteral("iPad 的测试任务")});
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("Mac 的任务")});
    QCOMPARE(describe(ipad->device), describe(mac->device));
    SyncStore ipadStore(ipad->device.connection);
    QCOMPARE(ipadStore.folderId(), SyncStore(mac->device.connection).folderId());
    QCOMPARE(ipadStore.peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    // 被换掉的任务交给界面：计时器据此解绑，列表刷新。
    QCOMPARE(ipad->notified.size(), 1);
    QVERIFY(!ipad->notified.first().deletedTaskIds.isEmpty());

    // 加入只做一次：之后再同步不会再备份、再替换。
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->backups.size(), 1);
}

void SyncTransportTests::changesTravelBothWaysInBatches()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // Mac 上连着改了三处：攒成一批、只写一个文件。
    const QString first = addTask(mac->device, QStringLiteral("背单词"));
    QVERIFY(!addTask(mac->device, QStringLiteral("刷题")).isEmpty());
    QVERIFY(exec(mac->device, QStringLiteral("UPDATE tasks SET notes = '第 3 单元' WHERE sync_id = '%1'").arg(first)));
    QVERIFY(syncOnce(*mac));
    QCOMPARE(cloud.changeFiles(mac->device, mac->device), QStringList{SyncFiles::changeFileName({0, 1})});
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);

    cloud.deliver(mac->device, ipad->device);
    ipad->notified.clear();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), (QStringList{QStringLiteral("刷题"), QStringLiteral("背单词")}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT notes FROM tasks WHERE sync_id = '%1'").arg(first)).toString(),
             QStringLiteral("第 3 单元"));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 1}));
    // 界面只刷新一次，且只刷新任务。
    QCOMPARE(ipad->notified.size(), 1);
    QVERIFY(ipad->notified.first().changedTables.contains(QStringLiteral("tasks")));
    // iPad 把读到哪写进自己的游标文件，Mac 据此才能清理旧文件。
    QFile cursorFile(cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id) + QLatin1Char('/')
                                                  + SyncFiles::cursorFileName()));
    QVERIFY(cursorFile.open(QIODevice::ReadOnly));
    SyncFiles::CursorFile cursor;
    QString error;
    QCOMPARE(SyncFiles::decodeCursor(cursorFile.readAll(), ipad->device.id, &cursor, &error), SyncFiles::ParseStatus::Ok);
    QCOMPARE(cursor.applied.value(mac->device.id), (SyncPosition{0, 1}));

    // 反方向：iPad 完成了一条，Mac 收到。
    QVERIFY(exec(ipad->device, QStringLiteral("UPDATE tasks SET completed = 1 WHERE sync_id = '%1'").arg(first)));
    QVERIFY(syncOnce(*ipad));
    cloud.deliver(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QCOMPARE(scalar(mac->device, QStringLiteral("SELECT completed FROM tasks WHERE sync_id = '%1'").arg(first)).toInt(), 1);
    QCOMPARE(describe(mac->device), describe(ipad->device));
}

void SyncTransportTests::filesArrivingOutOfOrderWaitForTheGap()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    QVERIFY(!addTask(mac->device, QStringLiteral("第一批")).isEmpty());
    QVERIFY(syncOnce(*mac));
    QVERIFY(!addTask(mac->device, QStringLiteral("第二批")).isEmpty());
    QVERIFY(syncOnce(*mac));
    const QString firstFile = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/')
        + SyncFiles::changeFileName({0, 1});

    // iCloud 先送到了第二批：等第一批，一批都不应用。
    cloud.deliver(mac->device, ipad->device, [&firstFile](const QString& path) { return path == firstFile; });
    QVERIFY(syncOnce(*ipad));
    QVERIFY(taskTitles(ipad->device).isEmpty());
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    // 刚缺号不急着请对方补快照：缺的那一批通常几秒后就到了（默认等两分钟）。
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());

    // 第一批到了：两批按顺序应用。
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), (QStringList{QStringLiteral("第一批"), QStringLiteral("第二批")}));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 2}));
}

void SyncTransportTests::redeliveredFilesChangeNothing()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    const QString task = addTask(mac->device, QStringLiteral("背单词"));
    QVERIFY(exec(mac->device, QStringLiteral("UPDATE tasks SET notes = '一' WHERE sync_id = '%1'").arg(task)));
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    const QStringList before = describe(ipad->device);

    // 应用了、但「读到第几批」没记下（被系统结束）：下次把这些文件再读一遍，什么都不该变。
    QVERIFY(SyncStore(ipad->device.connection).setPeerCursor(mac->device.id, {0, 0}));
    ipad->notified.clear();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(describe(ipad->device), before);
    QVERIFY(ipad->notified.isEmpty());
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log")).toInt(), 0);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 1}));
}

void SyncTransportTests::sequenceIsNotReusedAfterUnacknowledgedWrite()
{
    QTemporaryDir temp;
    QVERIFY(temp.isValid());
    SyncWorker worker(std::make_unique<LocalSyncFolder>(temp.path()));
    SyncBatch batch = sampleBatch(kDeviceA, 2);
    const SyncWorker::WriteResult first = worker.writeChanges(batch, 0, 1790000000000);
    QVERIFY(first.error.ok());
    QCOMPARE(first.position, (SyncPosition{2, 1}));
    // 写完文件、还没来得及记下序号就被结束：下次仍以为写到第 0 批。不能再用 1 号覆盖对方可能已经读过的文件。
    const SyncWorker::WriteResult again = worker.writeChanges(batch, 0, 1790000000001);
    QVERIFY(again.error.ok());
    QCOMPARE(again.position, (SyncPosition{2, 2}));
    // 别的纪元的旧文件不占这个纪元的号。
    batch.epoch = 3;
    QCOMPARE(worker.writeChanges(batch, 0, 1790000000002).position, (SyncPosition{3, 1}));
    // 本机记的比目录里的大（旧文件已被清理）：按本机记的往后排。
    QCOMPARE(worker.writeChanges(batch, 9, 1790000000003).position, (SyncPosition{3, 10}));
}

void SyncTransportTests::wrongFolderIsReportedWithHint()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // iPad 选成了里面的 devices 子文件夹：提示回到上一层，不写任何东西。
    Device other = openDevice(QStringLiteral("other"));
    SyncEngine inner(std::make_unique<LocalSyncFolder>(cloud.path(ipad->device, SyncFiles::devicesDirectory())),
                     testOptions(), other.connection);
    inner.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    inner.start();
    QVERIFY(waitIdle(inner));
    QCOMPARE(inner.status(), SyncEngine::Status::WrongFolder);
    QVERIFY2(inner.statusText().contains(QStringLiteral("回到上一层")), qPrintable(inner.statusText()));

    // iPad 选了一个空文件夹：iPad 不能新建同步文件夹，只提示先在 Mac 上开启。
    const QString empty = m_data->filePath(QStringLiteral("empty"));
    QVERIFY(QDir().mkpath(empty));
    inner.setFolder(std::make_unique<LocalSyncFolder>(empty));
    QVERIFY(waitIdle(inner));
    QCOMPARE(inner.status(), SyncEngine::Status::WrongFolder);
    QVERIFY2(inner.statusText().contains(QStringLiteral("Mac 上开启同步")), qPrintable(inner.statusText()));
    QVERIFY(QDir(empty).entryList(QDir::NoDotAndDotDot | QDir::AllEntries | QDir::Hidden).isEmpty());

    // Mac 不会在一个有别的东西的文件夹里新建：那可能是用户自己的文件夹。
    const QString occupied = m_data->filePath(QStringLiteral("occupied"));
    QVERIFY(QDir().mkpath(occupied + QStringLiteral("/论文")));
    Device another = openDevice(QStringLiteral("another-mac"));
    SyncEngine::Options options = testOptions();
    options.mayCreateFolder = true;
    SyncEngine creator(std::make_unique<LocalSyncFolder>(occupied), options, another.connection);
    creator.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    creator.start();
    QVERIFY(waitIdle(creator));
    QCOMPARE(creator.status(), SyncEngine::Status::WrongFolder);
    QVERIFY(!fileExists(occupied + QLatin1Char('/') + SyncFiles::markerFileName()));
}

void SyncTransportTests::joinWaitsWhileSnapshotIsStillUploading()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    auto mac = makeNode(QStringLiteral("mac"), true, cloud);
    auto ipad = makeNode(QStringLiteral("ipad"), false, cloud);
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 的任务")).isEmpty());
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 的测试任务")).isEmpty());
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));

    // 标记文件先到了，快照还在路上：等着，不动本机数据，也不备份。
    cloud.deliver(mac->device, ipad->device, [](const QString& path) { return path.contains(QStringLiteral("snapshot-")); });
    ipad->engine->start();
    QVERIFY(waitIdle(*ipad->engine));
    ipad->engine->confirmJoin();
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::WaitingForSnapshot);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 的测试任务")});
    QVERIFY(ipad->backups.isEmpty());

    // 快照到了：接着加入（确认一次就够，不用再点）。
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("Mac 的任务")});
}

void SyncTransportTests::batchingWaitsUntilIntervalOrBackground()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // 换成真实的节拍：每 10 毫秒检查一次、随时可以扫描，但两次写出至少隔一小时。
    SyncEngine::Options options = testOptions();
    options.tickMs = 10;
    options.publishIntervalMs = 60 * 60 * 1000;
    options.runInBackground = false;
    SyncEngine engine(std::make_unique<LocalSyncFolder>(cloud.replica(ipad->device)), options,
                      ipad->device.connection);
    engine.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    ipad->engine->stop();
    // 空闲了一阵之后的第一处改动立即写出，不必干等攒批间隔。
    QVERIFY(!addTask(ipad->device, QStringLiteral("先记的")).isEmpty());
    engine.start();
    QVERIFY(waitIdle(engine));
    const QStringList written = cloud.changeFiles(ipad->device, ipad->device);
    QCOMPARE(written.size(), 1);
    QVERIFY(!addTask(ipad->device, QStringLiteral("刚记下的")).isEmpty());
    QVERIFY(!addTask(ipad->device, QStringLiteral("又记一条")).isEmpty());
    QTest::qWait(200);
    QVERIFY(waitIdle(engine));
    // 之后的改动攒着：定时扫描照做，但一小时之内不再写出。
    QCOMPARE(cloud.changeFiles(ipad->device, ipad->device), written);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 2);
    QCOMPARE(engine.pendingCount(), 2);

    // 切到后台：立即写出攒下的改动，一批写完。
    engine.setForeground(false);
    QVERIFY(waitIdle(engine));
    QCOMPARE(cloud.changeFiles(ipad->device, ipad->device).size(), written.size() + 1);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 0);
    // iPad 在后台不再定时同步（进程很快会被系统挂起）。
    QVERIFY(!addTask(ipad->device, QStringLiteral("后台时记的")).isEmpty());
    QTest::qWait(100);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 1);
}

void SyncTransportTests::backgroundTaskCoversFlushAfterCycleInProgress()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    SyncEngine::Options options = testOptions();
    options.publishIntervalMs = 60 * 60 * 1000;
    options.runInBackground = false;
    SyncEngine engine(std::make_unique<LocalSyncFolder>(cloud.replica(ipad->device)), options,
                      ipad->device.connection);
    engine.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    ipad->engine->stop();
    engine.start();
    QVERIFY(waitIdle(engine));
    QSignalSpy finished(&engine, &SyncEngine::cycleFinished);
    int begun = 0;
    QList<qsizetype> endedAfterFinishes;
    engine.setBackgroundTaskProvider([&begun, &endedAfterFinishes, &finished] {
        ++begun;
        return [&endedAfterFinishes, &finished] { endedAfterFinishes.append(finished.count()); };
    });
    QVERIFY(!addTask(ipad->device, QStringLiteral("切后台前记的")).isEmpty());

    // 切到后台时，定时的那一轮正在进行（这里用手动同步代替）：后台任务要一直保留到后面那一轮「只写」做完，
    // 不能在正在进行的那一轮收尾时就还给系统。
    engine.syncNow();
    QVERIFY(engine.isBusy());
    engine.setForeground(false);
    QVERIFY(waitIdle(engine));
    QCOMPARE(begun, 1);
    QCOMPARE(endedAfterFinishes, QList<qsizetype>{1});
    QCOMPARE(finished.count(), 2);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 0);

    // 回到前台再切后台：再要一次；停下时还没用完的也要还。
    engine.setForeground(true);
    QVERIFY(waitIdle(engine));
    engine.setForeground(false);
    engine.stop();
    QCOMPARE(begun, 2);
    QCOMPARE(endedAfterFinishes.size(), 2);
}

void SyncTransportTests::flushBeforeExitWritesPendingChanges()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(mac->device, QStringLiteral("退出前记的")).isEmpty());
    const int before = int(cloud.changeFiles(mac->device, mac->device).size());
    QVERIFY(mac->engine->flushBeforeExit(5000));
    QCOMPARE(cloud.changeFiles(mac->device, mac->device).size(), before + 1);
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);
    QCOMPARE(mac->engine->status(), SyncEngine::Status::Stopped);

    // 文件夹已经不是加入的那一个（被删掉重建了）：不往里写，改动留在本机。
    QVERIFY(!addTask(ipad->device, QStringLiteral("文件夹换了之后记的")).isEmpty());
    QVERIFY(QFile::remove(cloud.path(ipad->device, SyncFiles::markerFileName())));
    QVERIFY(!ipad->engine->flushBeforeExit(5000));
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 1);
}

// 记下每个操作在哪个线程上执行。
class ThreadRecordingFolder : public LocalSyncFolder
{
public:
    ThreadRecordingFolder(const QString& root, QSet<QThread*>* threads) : LocalSyncFolder(root), m_threads(threads) {}
    bool open(Error* error) override { note(); return LocalSyncFolder::open(error); }
    QStringList list(const QString& dir, Error* error) override { note(); return LocalSyncFolder::list(dir, error); }
    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        note();
        return LocalSyncFolder::read(path, data, error);
    }
    bool write(const QString& path, const QByteArray& data, Error* error) override
    {
        note();
        return LocalSyncFolder::write(path, data, error);
    }

private:
    void note()
    {
        const QMutexLocker locker(&m_mutex);
        m_threads->insert(QThread::currentThread());
    }
    QSet<QThread*>* m_threads;
    QMutex m_mutex;
};

void SyncTransportTests::fileWorkRunsOffTheMainThread()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    Device device = openDevice(QStringLiteral("mac"));
    QSet<QThread*> threads;
    SyncEngine::Options options = testOptions();
    options.mayCreateFolder = true;
    {
        SyncEngine engine(std::make_unique<ThreadRecordingFolder>(cloud.replica(device), &threads), options,
                          device.connection);
        engine.setChangeNotifier([](const SyncStore::ApplyResult&) {});
        engine.start();
        QVERIFY(waitIdle(engine));
        QCOMPARE(engine.status(), SyncEngine::Status::UpToDate);
    }
    // 读写云盘可能要等上一两秒（下载），一律不在界面线程里做。
    QVERIFY(!threads.isEmpty());
    QVERIFY(!threads.contains(QThread::currentThread()));
}

void SyncTransportTests::everyCycleRelinksReferencesWhoseTargetIsBack()
{
    // 「待接回」的目标可能是本机自己生成回来的（例行实例收回后当天又启用），那时不一定有对方的批次到来：
    // 引擎每一轮开始都先把目标已经在本机的引用接上，并通知界面刷新；接回不是本机改动，不进待发送。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    auto mac = makeNode(QStringLiteral("mac"), true, cloud);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    const QString task = addTask(mac->device, QStringLiteral("背单词"));
    QVERIFY(exec(mac->device, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                             "VALUES (NULL, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")));
    const QString session = scalar(mac->device, QStringLiteral("SELECT sync_id FROM focus_sessions")).toString();
    QVERIFY(syncOnce(*mac));
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);
    // 专注记录的任务置空、等着接回这条任务（版本取这一列现在的版本，和收到时记下的一样）。
    QVERIFY(exec(mac->device, QStringLiteral(
        "INSERT INTO sync_pending_refs (tbl, sync_id, field, target_sync_id, v_time, v_device) "
        "SELECT 'focus_sessions', sync_id, field, '%1', v_time, v_device FROM sync_field_versions "
        "WHERE tbl = 'focus_sessions' AND sync_id = '%2' AND field = 'task_id'").arg(task, session)));
    mac->notified.clear();

    QVERIFY(syncOnce(*mac));
    QCOMPARE(scalar(mac->device, QStringLiteral("SELECT t.sync_id FROM focus_sessions f JOIN tasks t ON t.id = f.task_id "
                                                "WHERE f.sync_id = '%1'").arg(session)).toString(),
             task);
    QCOMPARE(scalar(mac->device, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")).toInt(), 0);
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);
    QVERIFY(!mac->notified.isEmpty());
    QVERIFY(mac->notified.first().changedTables.contains(QStringLiteral("focus_sessions")));
}

// ── 3e：快照、清理与全局回滚 ──

// 记下读过哪些文件：检查落后很多的设备是不是只下载了快照。
class CountingFolder : public LocalSyncFolder
{
public:
    CountingFolder(const QString& root, QStringList* reads) : LocalSyncFolder(root), m_reads(reads) {}
    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        m_reads->append(path);
        return LocalSyncFolder::read(path, data, error);
    }

private:
    QStringList* m_reads;
};

void SyncTransportTests::oldFilesAreDeletedOnlyAfterEveryoneReadThem()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.compactAfterFiles = 3;
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);

    // iPad 读完了前两批，但 Mac 还没有覆盖它们的快照：一个都不能删。删了的话，
    // 以后加入的设备（或者重装后的 iPad）从旧快照起步，就再也拿不到这两批。
    for (int batch = 1; batch <= 2; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    cloud.deliver(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QCOMPARE(cloud.changeFiles(mac->device, mac->device).size(), 2);
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 0})});

    // 写满三批：写一份覆盖到第 3 批的新快照，旧快照删掉；iPad 读过前两批，只删这两批，第 3 批留着等它读。
    QVERIFY(!addTask(mac->device, QStringLiteral("第 3 批")).isEmpty());
    QVERIFY(syncOnce(*mac));
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 3})});
    QCOMPARE(SyncStore(mac->device.connection).snapshotPosition(), (SyncPosition{0, 3}));
    QCOMPARE(cloud.changeFiles(mac->device, mac->device), QStringList{SyncFiles::changeFileName({0, 3})});

    // 第 3 批也读了：全部删掉，只留快照给以后加入的设备起步。
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    cloud.deliver(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QVERIFY(cloud.changeFiles(mac->device, mac->device).isEmpty());
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 3})});
    QCOMPARE(describe(ipad->device), describe(mac->device));
}

void SyncTransportTests::compactionSnapshotDoesNotSwallowPendingChanges()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(mac->device, QStringLiteral("第 1 批")).isEmpty());
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));

    // 按真实节拍跑：随时维护，但两次写出至少隔一小时。
    SyncEngine::Options options = testOptions();
    options.tickMs = 10;
    options.publishIntervalMs = 60 * 60 * 1000;
    options.maintenanceIntervalMs = 0;
    options.runInBackground = false;
    SyncEngine engine(std::make_unique<LocalSyncFolder>(cloud.replica(mac->device)), options, mac->device.connection);
    engine.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    mac->engine->stop();
    QVERIFY(!addTask(mac->device, QStringLiteral("第 2 批")).isEmpty());
    engine.start();
    QVERIFY(waitIdle(engine));
    QCOMPARE(cloud.changeFiles(mac->device, mac->device).size(), 2);
    // 之后记的这一条攒着没发（一小时之内不再写出）。
    QVERIFY(!addTask(mac->device, QStringLiteral("快照时还攒着的")).isEmpty());

    // 这时 iPad 请 Mac 补一份覆盖到第 2 批的快照（比如它读到了坏文件）：直接把它的游标文件放进 Mac 看到的副本里。
    SyncFiles::CursorFile cursor;
    cursor.device = ipad->device.id;
    cursor.epoch = 0;
    cursor.writtenAtMs = QDateTime::currentMSecsSinceEpoch();
    cursor.applied.insert(mac->device.id, {0, 1});
    cursor.snapshotRequests.insert(mac->device.id, {0, 2});
    QSaveFile request(cloud.path(mac->device, SyncFiles::deviceDirectory(ipad->device.id) + QLatin1Char('/')
                                                  + SyncFiles::cursorFileName()));
    QVERIFY(request.open(QIODevice::WriteOnly));
    request.write(SyncFiles::encodeCursor(cursor));
    QVERIFY(request.commit());
    QTest::qWait(100);
    QVERIFY(waitIdle(engine));
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 2})});
    // 快照里已经有攒着的那一条，但这种快照只给落后的设备追赶用，不能把它当成已经发出：
    // 跟上了的 iPad 不读快照，只读改动文件，确认掉的话它就永远收不到。
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 1);
    engine.setForeground(false);
    QVERIFY(waitIdle(engine));
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), (QStringList{QStringLiteral("快照时还攒着的"), QStringLiteral("第 1 批"),
                                                    QStringLiteral("第 2 批")}));
}

void SyncTransportTests::lateDeviceCatchesUpFromSnapshotAfterCleanup()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.compactAfterFiles = 2;
    options.maintenanceIntervalMs = 0;
    // 游标文件多旧都算「不再使用」：Mac 不等 iPad，写了快照就删。
    options.peerStaleDays = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);

    // iPad 很久没开：Mac 写了三批，前两批已经有快照兜底、被删掉了。
    for (int batch = 1; batch <= 3; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    QCOMPARE(cloud.changeFiles(mac->device, mac->device), QStringList{SyncFiles::changeFileName({0, 3})});
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 2})});

    // iPad 回来：缺了第 1、2 批，从快照补上，再接着读第 3 批。
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device),
             (QStringList{QStringLiteral("第 1 批"), QStringLiteral("第 2 批"), QStringLiteral("第 3 批")}));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 3}));
    QCOMPARE(describe(ipad->device), describe(mac->device));
}

void SyncTransportTests::farBehindDeviceReadsSnapshotInsteadOfManyFiles()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.compactAfterFiles = 4;
    options.catchUpViaSnapshot = 3;
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    for (int batch = 1; batch <= 5; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    // iPad 还在用（游标文件是新的），它没读过的改动文件都留着；快照覆盖到第 4 批。
    QCOMPARE(cloud.changeFiles(mac->device, mac->device).size(), 5);
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 4})});

    QStringList reads;
    ipad->engine->setFolder(std::make_unique<CountingFolder>(cloud.replica(ipad->device), &reads));
    QVERIFY(waitIdle(*ipad->engine));
    cloud.deliver(mac->device, ipad->device);
    reads.clear();
    QVERIFY(syncOnce(*ipad));
    // 落后 4 批、快照覆盖得到：下载一份快照加第 5 批，不去逐个下载前 4 批（每个约 1 秒）。
    const QString changes = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/');
    QVERIFY(reads.contains(SyncFiles::deviceDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::snapshotFileName({0, 4})));
    QVERIFY(reads.contains(changes + SyncFiles::changeFileName({0, 5})));
    for (int seq = 1; seq <= 4; ++seq) {
        QVERIFY2(!reads.contains(changes + SyncFiles::changeFileName({0, seq})), qPrintable(QString::number(seq)));
    }
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 5}));
    QCOMPARE(describe(ipad->device), describe(mac->device));
}

void SyncTransportTests::restoringBackupRollsBackTheOtherDevice()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    const QString kept = addTask(mac->device, QStringLiteral("备份之前就有"));
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));

    // 备份之后两台都记了东西，也都同步过。
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 备份之后加的")).isEmpty());
    QVERIFY(syncOnce(*mac));
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 备份之后加的")).isEmpty());
    QVERIFY(syncOnce(*ipad));
    cloud.exchange(mac->device, ipad->device);
    QVERIFY(syncOnce(*mac));
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device).size(), 3);
    const int backupsBefore = int(ipad->backups.size());

    // Mac 恢复备份（你定了：恢复备份 = 全局回滚）。Mac 开新纪元，写一份给所有设备的快照，旧纪元的文件删掉。
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(mac->device.connection).epoch(), 1);
    // 新纪元里还一批都没写，快照覆盖到第 0 批。
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({1, 0})});
    QVERIFY(cloud.changeFiles(mac->device, mac->device).isEmpty());

    // iPad 读到更高的纪元：先自动备份（备份里有它回滚前的全部数据），再整体换成 Mac 的快照。
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(ipad->backups.size(), backupsBefore + 1);
    QCOMPARE(ipad->backups.last().size(), 3);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("备份之前就有")});
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
    QCOMPARE(describe(ipad->device), describe(mac->device));
    // iPad 旧纪元的改动文件都删了：谁都用不上了。
    for (const QString& name : cloud.changeFiles(ipad->device, ipad->device)) {
        SyncPosition position;
        QVERIFY(SyncFiles::parseChangeFileName(name, &position));
        QCOMPARE(position.epoch, 1);
    }

    // 回滚之后的新改动照常同步。
    QVERIFY(exec(ipad->device, QStringLiteral("UPDATE tasks SET notes = '回滚后补的' WHERE sync_id = '%1'").arg(kept)));
    QVERIFY(syncOnce(*ipad));
    cloud.exchange(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QCOMPARE(scalar(mac->device, QStringLiteral("SELECT notes FROM tasks WHERE sync_id = '%1'").arg(kept)).toString(),
             QStringLiteral("回滚后补的"));
    QCOMPARE(taskTitles(mac->device), QStringList{QStringLiteral("备份之前就有")});
}

void SyncTransportTests::rollbackWaitsForSnapshotAndForBackup()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 的任务")).isEmpty());
    QVERIFY(syncOnce(*ipad));
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("回滚之后记的")).isEmpty());
    QVERIFY(syncOnce(*mac));

    // 新纪元的改动先到了、快照还在路上：什么都不应用，也不备份。
    cloud.deliver(mac->device, ipad->device, [](const QString& path) { return path.contains(QStringLiteral("snapshot-")); });
    const int backupsBefore = int(ipad->backups.size());
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::WaitingForSnapshot);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 的任务")});
    QCOMPARE(ipad->backups.size(), backupsBefore);

    // 快照到了，但自动备份失败：不替换。被换掉的数据只能从这份备份里找回，没有备份就不换。
    cloud.deliver(mac->device, ipad->device);
    ipad->backupSucceeds = false;
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::BackupFailed);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 的任务")});
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 0);

    // 备份恢复正常之后再换。
    ipad->backupSucceeds = true;
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("回滚之后记的")});
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
}

void SyncTransportTests::lostFileIsRecoveredThroughSnapshotRequest()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.gapRequestAfterMs = 0;
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    for (int batch = 1; batch <= 3; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    // 第 1 批在 iCloud 里丢了，一直送不到。
    const QString lost = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    const auto holdLost = [&lost](const QString& path) { return path == lost; };
    cloud.deliver(mac->device, ipad->device, holdLost);
    QVERIFY(syncOnce(*ipad));
    QVERIFY(taskTitles(ipad->device).isEmpty());
    // 等得太久（测试里拨成 0）：请 Mac 补一份覆盖到第 1 批的快照，写进游标文件。
    QCOMPARE(SyncStore(ipad->device.connection).snapshotRequests().value(mac->device.id), (SyncPosition{0, 1}));

    // Mac 维护时看到请求，写一份新快照（覆盖到第 3 批）。
    cloud.deliver(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 3})});

    // iPad 合并快照，把丢了的那一批补回来；请求撤掉。
    cloud.deliver(mac->device, ipad->device, holdLost);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device),
             (QStringList{QStringLiteral("第 1 批"), QStringLiteral("第 2 批"), QStringLiteral("第 3 批")}));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 3}));
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());
    QCOMPARE(describe(ipad->device), describe(mac->device));
}

// ── 3f：异常与暂停 ──

// 可以注入故障的文件夹。故障设置由测试（主线程）改、由工作线程读，所以加锁。
struct Faults {
    QMutex mutex;
    // 整个文件夹用不了（没登录 Apple ID、关了 iCloud 云盘）。
    bool unavailable = false;
    // 写入时报这类错（例如空间不足）。
    SyncFolder::ErrorKind writeError = SyncFolder::ErrorKind::None;
    // 读这些文件（相对路径）时报读写错误，直到从集合里拿掉。
    QSet<QString> failingReads;
    QString uploadProblem;
};

class FaultyFolder : public LocalSyncFolder
{
public:
    FaultyFolder(const QString& root, std::shared_ptr<Faults> faults) : LocalSyncFolder(root), m_faults(std::move(faults)) {}

    bool open(Error* error) override
    {
        return !unavailable(error) && LocalSyncFolder::open(error);
    }
    QStringList list(const QString& dir, Error* error) override
    {
        return unavailable(error) ? QStringList() : LocalSyncFolder::list(dir, error);
    }
    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        if (unavailable(error)) {
            return false;
        }
        {
            const QMutexLocker locker(&m_faults->mutex);
            if (m_faults->failingReads.contains(path)) {
                *error = {ErrorKind::Io, QStringLiteral("读取超时：%1").arg(path)};
                return false;
            }
        }
        return LocalSyncFolder::read(path, data, error);
    }
    bool write(const QString& path, const QByteArray& data, Error* error) override
    {
        if (unavailable(error)) {
            return false;
        }
        {
            const QMutexLocker locker(&m_faults->mutex);
            if (m_faults->writeError != ErrorKind::None) {
                *error = {m_faults->writeError, QStringLiteral("磁盘已满")};
                return false;
            }
        }
        return LocalSyncFolder::write(path, data, error);
    }
    QString uploadProblem(const QString&) override
    {
        const QMutexLocker locker(&m_faults->mutex);
        return m_faults->uploadProblem;
    }

private:
    bool unavailable(Error* error)
    {
        const QMutexLocker locker(&m_faults->mutex);
        if (m_faults->unavailable) {
            *error = {ErrorKind::Unavailable, QStringLiteral("iCloud 云盘不可用")};
        }
        return m_faults->unavailable;
    }

    std::shared_ptr<Faults> m_faults;
};

// 读某些文件会一直卡住的文件夹（断网时在等 iCloud 下载）：放行或取消之前一直等着。
// 取消能不能让它返回由 honorCancel 决定：iPad 的文件协调能取消，Mac 直接读文件取消不了。
// readDelayMs 让每次读先停一会儿，模拟慢、但一直在进行的下载。设置由测试（主线程）改、工作线程读，所以加锁。
struct Stall {
    QMutex mutex;
    QWaitCondition changed;
    QSet<QString> hangingReads;
    bool honorCancel = true;
    bool cancelRequested = false;
    int cancels = 0;
    int readDelayMs = 0;
};

class StallingFolder : public LocalSyncFolder
{
public:
    StallingFolder(const QString& root, std::shared_ptr<Stall> stall) : LocalSyncFolder(root), m_stall(std::move(stall)) {}

    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        int delayMs = 0;
        {
            QMutexLocker locker(&m_stall->mutex);
            delayMs = m_stall->readDelayMs;
            while (m_stall->hangingReads.contains(path)) {
                if (m_stall->honorCancel && m_stall->cancelRequested) {
                    m_stall->cancelRequested = false;
                    *error = {ErrorKind::Io, QStringLiteral("读取已取消：%1").arg(path)};
                    return false;
                }
                m_stall->changed.wait(&m_stall->mutex);
            }
        }
        if (delayMs > 0) {
            QThread::msleep(delayMs);
        }
        return LocalSyncFolder::read(path, data, error);
    }
    void cancelPendingIo() override
    {
        QMutexLocker locker(&m_stall->mutex);
        ++m_stall->cancels;
        m_stall->cancelRequested = true;
        m_stall->changed.wakeAll();
    }

private:
    std::shared_ptr<Stall> m_stall;
};

void SyncTransportTests::corruptFileIsSkippedLoggedAndHealedBySnapshot()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    for (int batch = 1; batch <= 3; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    cloud.deliver(mac->device, ipad->device);
    // iPad 这边收到的第 2 批坏了（磁盘出错、被别的程序改过）。
    const QString second = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 2});
    QFile broken(cloud.path(ipad->device, second));
    QVERIFY(broken.open(QIODevice::WriteOnly | QIODevice::Truncate));
    broken.write("{\"format\":1,\"type\":\"changes\",\"seq\":2,\"batch\":{\"rec");
    broken.close();

    // 跳过坏的那一批，后面的照常应用，不让一个坏文件卡住整个同步；记进同步日志，并请 Mac 补快照。
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), (QStringList{QStringLiteral("第 1 批"), QStringLiteral("第 3 批")}));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 3}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = 'file'")).toInt(), 1);
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT sync_id FROM sync_conflict_log WHERE kind = 'file'")).toString(),
             second);
    QCOMPARE(SyncStore(ipad->device.connection).snapshotRequests().value(mac->device.id), (SyncPosition{0, 2}));

    // Mac 看到请求，写一份覆盖到第 3 批的快照；iPad 合并它，坏文件里的改动回来了。
    cloud.deliver(ipad->device, mac->device);
    QVERIFY(syncOnce(*mac));
    QCOMPARE(cloud.snapshotFiles(mac->device, mac->device), QStringList{SyncFiles::snapshotFileName({0, 3})});
    cloud.deliver(mac->device, ipad->device, [&second](const QString& path) { return path == second; });
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device),
             (QStringList{QStringLiteral("第 1 批"), QStringLiteral("第 2 批"), QStringLiteral("第 3 批")}));
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());
    QCOMPARE(describe(ipad->device), describe(mac->device));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
}

void SyncTransportTests::newerFormatFileStopsWithoutSkipping()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(mac->device, QStringLiteral("新版本写的")).isEmpty());
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    const QString first = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    QFile file(cloud.path(ipad->device, first));
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray original = file.readAll();
    file.close();
    // 模拟 Mac 先升级了应用、用新格式写了这一批。
    const QByteArray newer = tamper(original, [](QJsonObject& o) { o.insert(QStringLiteral("format"), SyncFiles::kFormatVersion + 1); });
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(newer);
    file.close();

    // 读不懂就停在这里：不跳过（跳过就丢了），也不记成坏文件，提示更新应用。
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NewerVersion);
    QVERIFY(ipad->engine->statusText().contains(QStringLiteral("更新")));
    QVERIFY(taskTitles(ipad->device).isEmpty());
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log")).toInt(), 0);
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());

    // 「更新了应用」之后能读懂了：接着应用。
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(original);
    file.close();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("新版本写的")});
}

void SyncTransportTests::readFailureIsRetriedNotSkipped()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    auto faults = std::make_shared<Faults>();
    ipad->engine->setFolder(std::make_unique<FaultyFolder>(cloud.replica(ipad->device), faults));
    QVERIFY(waitIdle(*ipad->engine));
    for (int batch = 1; batch <= 2; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    cloud.deliver(mac->device, ipad->device);
    const QString first = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    {
        const QMutexLocker locker(&faults->mutex);
        faults->failingReads.insert(first);
    }

    // 读失败（下载超时、网络断了）是一时的：不跳过、不记坏文件，停在它前面，下一轮再试。
    QVERIFY(syncOnce(*ipad));
    QVERIFY(taskTitles(ipad->device).isEmpty());
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log")).toInt(), 0);
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);

    {
        const QMutexLocker locker(&faults->mutex);
        faults->failingReads.clear();
    }
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), (QStringList{QStringLiteral("第 1 批"), QStringLiteral("第 2 批")}));
}

void SyncTransportTests::stuckFolderOperationIsAbandonedAndRetried()
{
    // 断网时读一个还没下载的文件可能一直等着。以前这一轮永远结束不了：之后不再同步，连本机的改动也发不出去，
    // 界面却还显示上次的「已同步」。看门狗到点就取消正在等的读、放弃这一轮、显示出错，按出错的间隔重试。
    SyncEngine::Options options = testOptions();
    options.stallTimeoutMs = 300;
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    auto stall = std::make_shared<Stall>();
    ipad->engine->setFolder(std::make_unique<StallingFolder>(cloud.replica(ipad->device), stall));
    QVERIFY(waitIdle(*ipad->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 上记的")).isEmpty());
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    const QString first = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.insert(first);
    }
    // 用例无论在哪一步失败都要放行卡住的读，免得工作线程一直被占着、拖慢后面的用例。
    const auto releaseOnExit = qScopeGuard([stall] {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.clear();
        stall->changed.wakeAll();
    });

    // iPad 那样能取消的读：到点取消，这一轮放弃，显示出错；下一轮再试。
    QVERIFY(syncOnce(*ipad, 5000));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);
    QVERIFY2(ipad->engine->statusDetail().contains(QStringLiteral("没有进展")), qPrintable(ipad->engine->statusDetail()));
    {
        const QMutexLocker locker(&stall->mutex);
        QVERIFY(stall->cancels >= 1);
    }
    QVERIFY(taskTitles(ipad->device).isEmpty());

    // Mac 那样取消不了的读：卡住的那一步一直不回来，后面每一轮的文件操作都排在它后面，
    // 每一轮同样到点放弃、显示出错，而不是悄悄停住。
    {
        const QMutexLocker locker(&stall->mutex);
        stall->honorCancel = false;
        stall->cancelRequested = false;
    }
    for (int round = 0; round < 2; ++round) {
        QVERIFY(syncOnce(*ipad, 5000));
        QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);
    }

    // 下载终于回来了：排着的旧操作做完（结果按代数丢掉），下一轮正常把改动读进来。
    {
        const QMutexLocker locker(&stall->mutex);
        stall->hangingReads.clear();
        stall->changed.wakeAll();
    }
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("Mac 上记的")});
}

void SyncTransportTests::slowButSteadyFolderIsNotAbandoned()
{
    // 慢、但一直有进展（每读一个刚同步来的文件都要等一会儿）不算卡住。只看一步的总时长的话，
    // 慢网络下读满一轮就会超时，每一轮都被放弃，永远读不完。
    SyncEngine::Options options = testOptions();
    options.stallTimeoutMs = 400;
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    auto stall = std::make_shared<Stall>();
    ipad->engine->setFolder(std::make_unique<StallingFolder>(cloud.replica(ipad->device), stall));
    QVERIFY(waitIdle(*ipad->engine));
    QStringList expected;
    for (int batch = 1; batch <= 5; ++batch) {
        expected.append(QStringLiteral("第 %1 批").arg(batch));
        QVERIFY(!addTask(mac->device, expected.last()).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    cloud.deliver(mac->device, ipad->device);
    {
        const QMutexLocker locker(&stall->mutex);
        // 一轮要读 5 个文件，每个 100 毫秒，合计超过 400 毫秒；但每 100 毫秒就有一次进展。
        stall->readDelayMs = 100;
    }
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), expected);
    {
        const QMutexLocker locker(&stall->mutex);
        QCOMPARE(stall->cancels, 0);
    }
}

void SyncTransportTests::noSpaceKeepsChangesUntilSpaceReturns()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    auto faults = std::make_shared<Faults>();
    ipad->engine->setFolder(std::make_unique<FaultyFolder>(cloud.replica(ipad->device), faults));
    QVERIFY(waitIdle(*ipad->engine));
    {
        const QMutexLocker locker(&faults->mutex);
        faults->writeError = SyncFolder::ErrorKind::NoSpace;
    }
    QVERIFY(!addTask(ipad->device, QStringLiteral("空间不够时记的")).isEmpty());
    const QStringList before = cloud.changeFiles(ipad->device, ipad->device);

    // 写不出去：改动留在本机（待发送不清），状态说明空间不足。
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NoSpace);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 1);
    QCOMPARE(cloud.changeFiles(ipad->device, ipad->device), before);

    {
        const QMutexLocker locker(&faults->mutex);
        faults->writeError = SyncFolder::ErrorKind::None;
    }
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).pendingCount(), 0);
    QCOMPARE(cloud.changeFiles(ipad->device, ipad->device).size(), before.size() + 1);
}

void SyncTransportTests::unavailableFolderPausesAndResumes()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    auto faults = std::make_shared<Faults>();
    mac->engine->setFolder(std::make_unique<FaultyFolder>(cloud.replica(mac->device), faults));
    QVERIFY(waitIdle(*mac->engine));
    {
        const QMutexLocker locker(&faults->mutex);
        faults->unavailable = true;
    }
    QVERIFY(!addTask(mac->device, QStringLiteral("退出 Apple ID 期间记的")).isEmpty());

    // 退出了 Apple ID、关了 iCloud 云盘：暂停，说明原因；改动留在本机，数据一点不动。
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::FolderUnavailable);
    QVERIFY(mac->engine->statusText().contains(QStringLiteral("Apple ID")));
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 1);

    {
        const QMutexLocker locker(&faults->mutex);
        faults->unavailable = false;
    }
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 0);
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("退出 Apple ID 期间记的")});
}

void SyncTransportTests::uploadProblemIsShown()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    auto faults = std::make_shared<Faults>();
    mac->engine->setFolder(std::make_unique<FaultyFolder>(cloud.replica(mac->device), faults));
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("传不上去的")).isEmpty());
    QVERIFY(syncOnce(*mac));
    {
        const QMutexLocker locker(&faults->mutex);
        faults->uploadProblem = QStringLiteral("iCloud 储存空间已满");
    }
    // 本机写成功了，但 iCloud 传不上去：别的设备看不到这些改动，要让你知道。
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UploadFailed);
    QCOMPARE(mac->engine->statusDetail(), QStringLiteral("iCloud 储存空间已满"));
    {
        const QMutexLocker locker(&faults->mutex);
        faults->uploadProblem.clear();
    }
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
}

void SyncTransportTests::strayFilesAreIgnoredAndOwnLeftoversCleaned()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad, options);
    QVERIFY(!addTask(mac->device, QStringLiteral("正常的一批")).isEmpty());
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);

    const auto touch = [](const QString& path) {
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile file(path);
        return file.open(QIODevice::WriteOnly) && file.write("junk") == 4;
    };
    const QString macChanges = cloud.path(ipad->device, SyncFiles::changesDirectory(mac->device.id));
    // iPad 看到的 Mac 目录里的杂物：iCloud 的冲突副本、占位文件、别的程序放的东西、不像设备的目录。
    QVERIFY(touch(macChanges + QStringLiteral("/0000-00000002 2.json")));
    QVERIFY(touch(macChanges + QStringLiteral("/.0000-00000003.json.icloud")));
    QVERIFY(touch(cloud.path(ipad->device, SyncFiles::deviceDirectory(mac->device.id) + QStringLiteral("/说明.txt"))));
    QVERIFY(touch(cloud.path(ipad->device, SyncFiles::devicesDirectory() + QStringLiteral("/备份/0000-00000001.json"))));
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("正常的一批")});
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log")).toInt(), 0);
    // 别人目录里的东西一律不删，只有本机自己的目录归本机清理。
    QVERIFY(fileExists(macChanges + QStringLiteral("/0000-00000002 2.json")));

    // Mac 自己目录里写到一半留下的临时文件：维护时删掉。
    const QString leftover = cloud.path(mac->device, SyncFiles::changesDirectory(mac->device.id)
                                                         + QStringLiteral("/0000-00000009.json.AbC123"));
    QVERIFY(touch(leftover));
    QVERIFY(syncOnce(*mac));
    QVERIFY(!fileExists(leftover));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
}

void SyncTransportTests::missingMarkerAfterJoinIsNotRecreated()
{
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    const QString folderId = SyncStore(mac->device.connection).folderId();
    // 同步文件夹被人删掉或移走了（这里只剩下标记文件不见了）：暂停，不自己重建。
    // 重建就是另一个文件夹，iPad 还认着旧的，两边会各以为自己是第一次加入。
    QVERIFY(QFile::remove(cloud.path(mac->device, SyncFiles::markerFileName())));
    QVERIFY(!addTask(mac->device, QStringLiteral("文件夹不见之后记的")).isEmpty());
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::FolderMissing);
    QVERIFY(!fileExists(cloud.path(mac->device, SyncFiles::markerFileName())));
    QCOMPARE(SyncStore(mac->device.connection).folderId(), folderId);
    QCOMPARE(SyncStore(mac->device.connection).pendingCount(), 1);

    // 整个文件夹都被删了（空了，Mac 本来可以在这里新建）：同样不重建，已经加入过就等你来处理。
    QVERIFY(QDir(cloud.replica(mac->device)).removeRecursively());
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::FolderMissing);
    QVERIFY(!fileExists(cloud.replica(mac->device)));
    QCOMPARE(SyncStore(mac->device.connection).folderId(), folderId);
}

// ── 3g：平台层（Mac） ──

void SyncTransportTests::macFolderLivesInsideICloudDrive()
{
    // 用临时目录代替 iCloud 云盘，不碰真实的云盘。
    const QString drive = m_data->filePath(QStringLiteral("CloudDocs"));
    QVERIFY(QDir().mkpath(drive));
    MacSyncFolder folder(drive);
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    QCOMPARE(folder.name(), SyncFiles::defaultFolderName());
    QVERIFY(folder.displayPath().endsWith(QStringLiteral("CloudDocs/番茄Todo同步")));
    // 第一次写入时连「番茄Todo同步」这一层一起建出来。
    QVERIFY(folder.write(SyncFiles::markerFileName(), QByteArray("marker"), &error));
    QVERIFY(fileExists(drive + QStringLiteral("/番茄Todo同步/") + SyncFiles::markerFileName()));
    // 不在 iCloud 里的文件查不到上传状态：返回空，不当成出错。
    QVERIFY(folder.uploadProblem(SyncFiles::markerFileName()).isEmpty());
    QVERIFY(MacSyncFolder::defaultICloudDriveRoot().endsWith(QStringLiteral("/Library/Mobile Documents/com~apple~CloudDocs")));
}

void SyncTransportTests::macFolderIsUnavailableWithoutICloudDrive()
{
    // 没登录 Apple ID、关了 iCloud 云盘：云盘目录不在。报「不可用」并说明原因，也不自己建一个出来
    // ——建出来的只是本机普通文件夹，写进去的东西永远到不了 iPad。
    const QString drive = m_data->filePath(QStringLiteral("没有的云盘"));
    MacSyncFolder folder(drive);
    SyncFolder::Error error;
    QVERIFY(!folder.open(&error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Unavailable);
    QVERIFY(error.message.contains(QStringLiteral("Apple ID")));
    QVERIFY(!fileExists(drive));

    Device device = openDevice(QStringLiteral("mac"));
    SyncEngine::Options options = testOptions();
    options.mayCreateFolder = true;
    SyncEngine engine(std::make_unique<MacSyncFolder>(drive), options, device.connection);
    engine.setChangeNotifier([](const SyncStore::ApplyResult&) {});
    engine.start();
    QVERIFY(waitIdle(engine));
    QCOMPARE(engine.status(), SyncEngine::Status::FolderUnavailable);
    QVERIFY(!fileExists(drive));
    QVERIFY(SyncStore(device.connection).folderId().isEmpty());
}

void SyncTransportTests::memoFormatThreeWritesAndReadsVersionsOneThroughThree()
{
    // 产品保证：增量与快照都写格式 3，并兼容格式 1、2、3；不能以格式 2 发送旧应用会跳过的备忘。
    SyncBatch batch = sampleBatch(kDeviceA, 0);
    SyncRecord memo;
    memo.table = QStringLiteral("memos"); memo.syncId = QStringLiteral("memo-format");
    const SyncVersion version{1900000000728, kDeviceA};
    memo.fields = {{QStringLiteral("title"), {QStringLiteral("格式"), version, {}}},
                   {QStringLiteral("body"), {QStringLiteral("完整正文"), version, {}}},
                   {QStringLiteral("category_id"), {QVariant(), version, {}}},
                   {QStringLiteral("sort_order"), {1, version, {}}},
                   {QStringLiteral("created_at"), {QStringLiteral("2026-10-02T12:51:46.728Z"), version, {}}}};
    batch.records = {memo};
    const QByteArray bytes = SyncFiles::encodeChanges({1, 1900000000728, batch});
    QCOMPARE(QJsonDocument::fromJson(bytes).object().value(QStringLiteral("batch")).toObject()
                 .value(QStringLiteral("format")).toInt(), 3);
    SyncFiles::SnapshotFile snapshot; snapshot.coveredSeq = 1; snapshot.batch = batch;
    const QByteArray snapshotBytes = SyncFiles::encodeSnapshot(snapshot);
    QCOMPARE(QJsonDocument::fromJson(snapshotBytes).object().value(QStringLiteral("batch")).toObject()
                 .value(QStringLiteral("format")).toInt(), 3);
    for (const int format : {1, 2, 3}) {
        const auto changeFormat = [format](QJsonObject& outer) {
            auto inner = outer.value(QStringLiteral("batch")).toObject();
            inner.insert(QStringLiteral("format"), format); outer.insert(QStringLiteral("batch"), inner);
        };
        QString error;
        SyncFiles::ChangeFile decoded;
        QCOMPARE(SyncFiles::decodeChanges(tamper(bytes, changeFormat), kDeviceA, {0, 1}, &decoded, &error),
                 SyncFiles::ParseStatus::Ok);
        QCOMPARE(decoded.batch.records.first().table, QStringLiteral("memos"));
        QCOMPARE(decoded.batch.records.first().fields.value(QStringLiteral("body")).value.toString(), QStringLiteral("完整正文"));
        SyncFiles::SnapshotFile readSnapshot;
        QCOMPARE(SyncFiles::decodeSnapshot(tamper(snapshotBytes, changeFormat), kDeviceA, {0, 1}, &readSnapshot, &error),
                 SyncFiles::ParseStatus::Ok);
    }
}

void SyncTransportTests::newerBatchFormatStopsWithoutAdvancingMemoCursor()
{
    // 产品保证：读到更高的内部批次格式就停住，更新后从原位置补齐备忘，不能跳过后推进游标。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac, ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(exec(mac->device, QStringLiteral(
        "INSERT INTO memos(title,body,sort_order,created_at,updated_at) "
        "VALUES('待升级备忘','不能跳过',1,'2026-10-02T12:51:46.728Z','2026-10-02T12:51:46.728Z')")));
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    const QString path = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    QFile file(cloud.path(ipad->device, path));
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray original = file.readAll(); file.close();
    const auto outer = QJsonDocument::fromJson(original).object();
    QCOMPARE(outer.value(QStringLiteral("format")).toInt(), 1); // 外壳仍为 1，检查的是内部协议。
    QCOMPARE(outer.value(QStringLiteral("batch")).toObject().value(QStringLiteral("format")).toInt(), SyncJson::kFormatVersion);
    const auto newer = tamper(original, [](QJsonObject& o) {
        auto batch = o.value(QStringLiteral("batch")).toObject();
        // 编译为旧版读取能力 2 时，这里发格式 3；当前能力 3 则发 4，验证同一道停读边界。
        batch.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1); o.insert(QStringLiteral("batch"), batch);
    });
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate)); file.write(newer); file.close();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NewerVersion);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM memos")).toInt(), 0);
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate)); file.write(original); file.close();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 1}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT body FROM memos")).toString(), QStringLiteral("不能跳过"));
}

QTEST_GUILESS_MAIN(SyncTransportTests)

#include "SyncTransportTests.moc"
