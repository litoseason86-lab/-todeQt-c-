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

// 读快照时可受控注入 I/O 错误的本地同步文件夹替身，用于故障注入测试
class FaultySnapshotFolder : public LocalSyncFolder
{
public:
    using LocalSyncFolder::LocalSyncFolder;
    bool failSnapshotRead = true;

    bool read(const QString& path, QByteArray* data, Error* error) override
    {
        if (failSnapshotRead && path.contains(QStringLiteral("snapshot-"))) {
            if (error) {
                *error = {ErrorKind::Io, QStringLiteral("注入的快照 I/O 读取失败")};
            }
            return false;
        }
        return LocalSyncFolder::read(path, data, error);
    }
};

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
    void cleanupUsesLocalPeerObservations_data();
    void cleanupUsesLocalPeerObservations();
    void lateDeviceCatchesUpFromSnapshotAfterCleanup();
    void farBehindDeviceReadsSnapshotInsteadOfManyFiles();
    void restoringBackupRollsBackTheOtherDevice();
    void rollbackWaitsForSnapshotAndForBackup();
    void lostFileIsRecoveredThroughSnapshotRequest();

    // 3f：异常与暂停
    void corruptFileIsSkippedLoggedAndHealedBySnapshot();
    void newerFormatFileStopsWithoutSkipping();
    void memoRecordsRoundTripInEveryReadableFormat();
    void trashFormatFourWritesAndReadsVersionsOneThroughFour();
    void newerBatchFormatStopsWithoutAdvancingMemoCursor();
    void newerBatchFormatStopsWithoutAdvancingTrashCursor();
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

    // 058 阶段 5：高纪元损坏快照有界恢复与候选竞争
    void higherEpochCorruptedSnapshotRequestsSnapshotAndHealsViaPeer();
    void higherEpochMultipleCandidatesPicksValidOverCorrupted();
    void higherEpochMultipleSnapshotsOnSameDevicePicksValidOverCorrupted();
    void higherEpochChangesOnlyWithoutSnapshotRequestsSnapshotAndHeals();
    void higherEpochSnapshotRequestPersistenceFailureEntersError();
    void higherEpochNewerFormatSnapshotYieldsNewerVersion();
    void higherEpochSnapshotReadFailureExposesErrorStatus();

    // 058 阶段 4：快照发布阻断与有界预算
    void publishSnapshotFailureDoesNotAdvancePositionOrWriteFile();
    void localSyncFolderRejectsFilesExceedingBudget();
    void decodeDefendsAgainstFilesExceedingBudget();
    void writeMarkerRejectsWhenExceedingBudget();
    void writeCursorRejectsWhenExceedingBudget();
    void writeChangesRejectsWhenExceedingBudget();
    void writeSnapshotRejectsWhenExceedingBudget();
    void enginePublishSnapshotRejectsWhenSnapshotExceedsBudget();

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

void SyncTransportTests::cleanupUsesLocalPeerObservations_data()
{
    // 清理只依据本机观察到的游标变化和读取进度，不能被对端时钟、暂时损坏或旧纪元记录误导。
    QTest::addColumn<QString>("scenario");
    for (const char* name : {"slow-clock", "fast-clock", "corrupt", "known-then-corrupt", "new-epoch", "clock-rollback", "write-failure"}) {
        QTest::newRow(name) << QString::fromLatin1(name);
    }
}

void SyncTransportTests::cleanupUsesLocalPeerObservations()
{
    // 对端未读的旧改动须等本机观察满过期期限才清理，读不出游标时沿用已知进度，换纪元重新观察。
    QFETCH(QString, scenario);
    constexpr qint64 dayMs = 24 * 60 * 60 * 1000;
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    const qint64 firstSeen = now;
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    options.compactAfterFiles = 100;
    options.localWallClockMs = [&now] { return now; };
    auto mac = makeNode(QStringLiteral("observing-mac"), true, cloud, options);
    QVERIFY(mac->device.id != kDeviceB);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    SyncStore store(mac->device.connection);
    for (int batch = 1; batch <= 3; ++batch) {
        QVERIFY(!addTask(mac->device, QStringLiteral("观察前第 %1 批").arg(batch)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    const QStringList allFiles{SyncFiles::changeFileName({0, 1}), SyncFiles::changeFileName({0, 2}),
                               SyncFiles::changeFileName({0, 3})};
    QCOMPARE(cloud.changeFiles(mac->device, mac->device), allFiles);
    QCOMPARE(store.snapshotPosition(), (SyncPosition{0, 0}));
    SyncFiles::CursorFile cursor;
    cursor.device = kDeviceB;
    cursor.epoch = 0;
    // 两种偏差都远超 14 天；对端时间只当指纹的一部分，不是本机的过期时钟。
    cursor.writtenAtMs = now + (scenario == QLatin1String("slow-clock") ? -30 : 30) * dayMs;
    const qint64 acknowledged = scenario == QLatin1String("known-then-corrupt") ? 1
        : (scenario == QLatin1String("write-failure") ? 3 : 0);
    cursor.applied.insert(mac->device.id, {0, acknowledged});
    const QString cursorPath = cloud.path(mac->device, SyncFiles::deviceDirectory(kDeviceB) + QLatin1Char('/')
                                                                      + SyncFiles::cursorFileName());
    const auto writeCursor = [&](const QByteArray& bytes) {
        if (!QDir().mkpath(QFileInfo(cursorPath).absolutePath())) return false;
        QSaveFile file(cursorPath);
        return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size() && file.commit();
    };
    const bool initiallyCorrupt = scenario == QLatin1String("corrupt");
    QVERIFY(writeCursor(initiallyCorrupt ? QByteArray("{") : SyncFiles::encodeCursor(cursor)));
    QVERIFY(fileExists(cursorPath));
    if (scenario == QLatin1String("write-failure")) {
        // 只阻止新的观察记账，其它同步状态仍可写；清理必须保守保留文件，不能把写失败当作设备消失。
        QVERIFY(exec(mac->device, QStringLiteral(
            "CREATE TRIGGER fail_peer_seen BEFORE INSERT ON sync_state WHEN NEW.key LIKE 'peer_seen/%' "
            "BEGIN SELECT RAISE(ABORT, 'peer observation failure'); END")));
    }
    // 用生产入口写覆盖三批的快照，再做维护；此前三批都在，才能区分清理有没有越过对端读取位置。
    QVERIFY(store.requestFullSnapshot());
    QVERIFY(syncOnce(*mac));
    QCOMPARE(store.snapshotPosition(), (SyncPosition{0, 3}));
    QVERIFY(fileExists(cloud.path(mac->device, SyncFiles::deviceDirectory(mac->device.id) + QLatin1Char('/')
                                                                           + SyncFiles::snapshotFileName({0, 3}))));
    if (scenario == QLatin1String("known-then-corrupt")) {
        const QStringList unread{SyncFiles::changeFileName({0, 2}), SyncFiles::changeFileName({0, 3})};
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), unread);
        QVERIFY(writeCursor(QByteArray("{")));
        // 重开连接后仍须沿用位置 1，不能只靠引擎内存保存的进度使测试通过。
        mac->engine->stop();
        reopen(mac->device);
        QVERIFY(exec(mac->device, QStringLiteral("PRAGMA foreign_keys=ON")));
        mac->engine->start();
        QVERIFY(waitIdle(*mac->engine));
        QVERIFY(syncOnce(*mac));
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), unread);
    } else {
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), allFiles);
    }
    if (scenario == QLatin1String("write-failure")) {
        QCOMPARE(mac->engine->status(), SyncEngine::Status::Error);
        QVERIFY(mac->engine->statusDetail().contains(QStringLiteral("观察记录")));
        QVERIFY(exec(mac->device, QStringLiteral("DROP TRIGGER fail_peer_seen")));
        cursor.applied[mac->device.id] = {0, 3};
        QVERIFY(writeCursor(SyncFiles::encodeCursor(cursor)));
        QVERIFY(syncOnce(*mac));
        QVERIFY(cloud.changeFiles(mac->device, mac->device).isEmpty());
        return;
    }
    if (scenario == QLatin1String("new-epoch")) {
        // 旧指纹已观察超过 14 天，但新纪元必须重新计时；用真实恢复入口推进纪元，不直接伪造观察 JSON。
        now += 15 * dayMs;
        mac->engine->stop();
        QVERIFY(store.beginEpochAfterRestore(0, mac->device.id));
        QCOMPARE(store.epoch(), qint64(1));
        QVERIFY(writeCursor(QByteArray("{")));
        mac->engine->start();
        QVERIFY(waitIdle(*mac->engine));
        for (int batch = 1; batch <= 3; ++batch) {
            QVERIFY(!addTask(mac->device, QStringLiteral("新纪元第 %1 批").arg(batch)).isEmpty());
            QVERIFY(syncOnce(*mac));
        }
        const QStringList newFiles{SyncFiles::changeFileName({1, 1}), SyncFiles::changeFileName({1, 2}),
                                   SyncFiles::changeFileName({1, 3})};
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), newFiles);
        QVERIFY(store.requestFullSnapshot());
        QVERIFY(syncOnce(*mac));
        QCOMPARE(store.snapshotPosition(), (SyncPosition{1, 3}));
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), newFiles);
        return;
    }
    if (scenario == QLatin1String("slow-clock")) {
        // 指纹再次变化即从本机此刻重新观察，不受对端仍落后 30 天的时间戳影响。
        now += 13 * dayMs;
        ++cursor.writtenAtMs;
        QVERIFY(writeCursor(SyncFiles::encodeCursor(cursor)));
        QVERIFY(syncOnce(*mac));
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), allFiles);
        now += 2 * dayMs;
        QVERIFY(syncOnce(*mac));
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), allFiles);
        return;
    }
    if (scenario == QLatin1String("clock-rollback")) {
        now -= dayMs;
        QVERIFY(syncOnce(*mac));
        QCOMPARE(cloud.changeFiles(mac->device, mac->device), allFiles);
    }
    const qint64 observedAt = scenario == QLatin1String("clock-rollback") ? firstSeen - dayMs : firstSeen;
    now = observedAt + 14 * dayMs - 1;
    QVERIFY(syncOnce(*mac));
    const QStringList beforeExpiry = scenario == QLatin1String("known-then-corrupt")
        ? QStringList{SyncFiles::changeFileName({0, 2}), SyncFiles::changeFileName({0, 3})} : allFiles;
    QCOMPARE(cloud.changeFiles(mac->device, mac->device), beforeExpiry);
    ++now;
    QVERIFY(syncOnce(*mac));
    QVERIFY(cloud.changeFiles(mac->device, mac->device).isEmpty());
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

void SyncTransportTests::memoRecordsRoundTripInEveryReadableFormat()
{
    // 产品保证：增量与快照都写当前格式，并兼容从 1 到当前格式的全部旧格式，备忘录记录在每一种格式下内容不变；
    // 写出的格式不能低于 3（备忘录从格式 3 起才有，低了旧应用会把它当不认识的表跳过）。
    // 原来写死「格式 3」的断言随废纸篓升到格式 4 改成跟随常量；写死数字的版本钉在下面的废纸篓用例里。
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
    const int written = QJsonDocument::fromJson(bytes).object().value(QStringLiteral("batch")).toObject()
                            .value(QStringLiteral("format")).toInt();
    QCOMPARE(written, SyncJson::kFormatVersion);
    QVERIFY(written >= 3);
    SyncFiles::SnapshotFile snapshot; snapshot.coveredSeq = 1; snapshot.batch = batch;
    const QByteArray snapshotBytes = SyncFiles::encodeSnapshot(snapshot);
    QCOMPARE(QJsonDocument::fromJson(snapshotBytes).object().value(QStringLiteral("batch")).toObject()
                 .value(QStringLiteral("format")).toInt(), SyncJson::kFormatVersion);
    for (int format = SyncJson::kOldestReadableFormat; format <= SyncJson::kFormatVersion; ++format) {
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

void SyncTransportTests::trashFormatFourWritesAndReadsVersionsOneThroughFour()
{
    // 产品保证：带废纸篓记录的增量与快照写格式 4（旧应用据此停在这一批等更新，不会把废纸篓当成不认识的表跳过），
    // 格式 1 到 4 的文件都读得出来，废纸篓记录与删除记录的内容一字不变，包括超过备忘录正文上限的内容。
    // 这里故意写死 4：格式号若被改回 3，旧应用会跳过废纸篓记录并照常推进读取进度，更新后也补不回来。
    SyncBatch batch = sampleBatch(kDeviceA, 0);
    SyncRecord trash;
    trash.table = QStringLiteral("trash_items"); trash.syncId = QStringLiteral("trash-format");
    const SyncVersion version{1900000000728, kDeviceA};
    // 内容是 JSON 文本：带引号、转义的换行、emoji，正文 12000 字，比备忘录正文的上限 1 万字还长。
    const QString payload = QStringLiteral("{\"v\":1,\"body\":\"") + QString(12000, QChar(0x7532))
        + QStringLiteral("\\n带\\\"引号\\\" 😀\"}");
    trash.fields = {{QStringLiteral("kind"), {QStringLiteral("memo"), version, {}}},
                    {QStringLiteral("origin_sync_id"), {QStringLiteral("memo-origin-1"), version, {}}},
                    {QStringLiteral("title"), {QStringLiteral("废纸篓里的备忘"), version, {}}},
                    {QStringLiteral("payload"), {payload, version, {}}},
                    {QStringLiteral("deleted_at"), {QStringLiteral("2026-10-06T01:02:03.456Z"), version, {}}}};
    SyncRecord removed;
    removed.table = QStringLiteral("trash_items"); removed.syncId = QStringLiteral("trash-removed");
    removed.deleted = true; removed.deleteVersion = {1900000000900, kDeviceA};
    removed.deleteKind = QStringLiteral("delete");
    batch.records = {trash, removed};
    QVERIFY(payload.size() > 10000);

    const QByteArray bytes = SyncFiles::encodeChanges({1, 1900000000728, batch});
    QCOMPARE(QJsonDocument::fromJson(bytes).object().value(QStringLiteral("batch")).toObject()
                 .value(QStringLiteral("format")).toInt(), 4);
    SyncFiles::SnapshotFile snapshot; snapshot.coveredSeq = 1; snapshot.batch = batch;
    const QByteArray snapshotBytes = SyncFiles::encodeSnapshot(snapshot);
    QCOMPARE(QJsonDocument::fromJson(snapshotBytes).object().value(QStringLiteral("batch")).toObject()
                 .value(QStringLiteral("format")).toInt(), 4);
    const auto expectTrash = [&](const SyncBatch& read) {
        QCOMPARE(read.records.size(), 2);
        QCOMPARE(read.records.at(0).table, QStringLiteral("trash_items"));
        QCOMPARE(read.records.at(0).syncId, QStringLiteral("trash-format"));
        for (const QString& field : {QStringLiteral("kind"), QStringLiteral("origin_sync_id"), QStringLiteral("title"),
                                     QStringLiteral("payload"), QStringLiteral("deleted_at")}) {
            QCOMPARE(read.records.at(0).fields.value(field).value.toString(),
                     trash.fields.value(field).value.toString());
        }
        QVERIFY(read.records.at(1).deleted);
        QCOMPARE(read.records.at(1).table, QStringLiteral("trash_items"));
        QCOMPARE(read.records.at(1).syncId, QStringLiteral("trash-removed"));
        QCOMPARE(read.records.at(1).deleteKind, QStringLiteral("delete"));
    };
    for (int format = 1; format <= 4; ++format) {
        const auto changeFormat = [format](QJsonObject& outer) {
            auto inner = outer.value(QStringLiteral("batch")).toObject();
            inner.insert(QStringLiteral("format"), format); outer.insert(QStringLiteral("batch"), inner);
        };
        QString error;
        SyncFiles::ChangeFile decoded;
        QCOMPARE(SyncFiles::decodeChanges(tamper(bytes, changeFormat), kDeviceA, {0, 1}, &decoded, &error),
                 SyncFiles::ParseStatus::Ok);
        expectTrash(decoded.batch);
        SyncFiles::SnapshotFile readSnapshot;
        QCOMPARE(SyncFiles::decodeSnapshot(tamper(snapshotBytes, changeFormat), kDeviceA, {0, 1}, &readSnapshot, &error),
                 SyncFiles::ParseStatus::Ok);
        expectTrash(readSnapshot.batch);
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
        // 当前读取能力是 4，这里发格式 5；更早编译成能力 2、3 的旧版收到的是 3、4，停读的边界是同一道。
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

void SyncTransportTests::newerBatchFormatStopsWithoutAdvancingTrashCursor()
{
    // 产品保证：旧版读到更高的内部批次格式就停住、不推进读取进度，更新应用之后从原位置补齐废纸篓记录；
    // 不能像不认识的表那样被跳过。（格式 4 起带废纸篓；同一道停读边界对备忘录见上一条用例。）
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac, ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(exec(mac->device, QStringLiteral(
        "INSERT INTO trash_items(kind,origin_sync_id,title,payload,deleted_at) "
        "VALUES('memo','origin-trash','待升级的废纸篓项','{\"v\":1,\"body\":\"不能跳过\"}','2026-10-06T01:02:03.456Z')")));
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    const QString path = SyncFiles::changesDirectory(mac->device.id) + QLatin1Char('/') + SyncFiles::changeFileName({0, 1});
    QFile file(cloud.path(ipad->device, path));
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray original = file.readAll(); file.close();
    // 前提：这一批里确实有那行废纸篓记录，写出的内部格式是当前格式。
    const auto outer = QJsonDocument::fromJson(original).object();
    QCOMPARE(outer.value(QStringLiteral("batch")).toObject().value(QStringLiteral("format")).toInt(), SyncJson::kFormatVersion);
    SyncFiles::ChangeFile written;
    QString writtenError;
    QCOMPARE(SyncFiles::decodeChanges(original, mac->device.id, {0, 1}, &written, &writtenError),
             SyncFiles::ParseStatus::Ok);
    QCOMPARE(written.batch.records.size(), 1);
    QCOMPARE(written.batch.records.first().table, QStringLiteral("trash_items"));
    const auto newer = tamper(original, [](QJsonObject& o) {
        auto batch = o.value(QStringLiteral("batch")).toObject();
        batch.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1); o.insert(QStringLiteral("batch"), batch);
    });
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate)); file.write(newer); file.close();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NewerVersion);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 0}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 0);
    QVERIFY(SyncStore(ipad->device.connection).snapshotRequests().isEmpty());
    // 更新应用之后（这里以还原文件代表）：游标从原位置前进，废纸篓记录补齐，内容一字不变。
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate)); file.write(original); file.close();
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{0, 1}));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM trash_items")).toInt(), 1);
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT payload FROM trash_items")).toString(),
             QStringLiteral("{\"v\":1,\"body\":\"不能跳过\"}"));
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT origin_sync_id FROM trash_items")).toString(),
             QStringLiteral("origin-trash"));
}

void SyncTransportTests::higherEpochCorruptedSnapshotRequestsSnapshotAndHealsViaPeer()
{
    // 保证更高纪元快照损坏时，设备不会陷入无出口的 WaitingForSnapshot，而是记录问题、向源设备请求重发快照，
    // 保留本地数据库和游标不变且状态呈现 Error；源设备即使在恢复后仅有 snapshot seq=0 且无任何新增 changes 的情况下，
    // 也能成功响应旧纪元接收端的恢复请求并重写快照，且相同游标请求不会每轮重复重写；最终接收端能够成功采用新快照并恢复至 UpToDate。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    setUpPair(cloud, &mac, &ipad, options);
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 初始任务")).isEmpty());
    QVERIFY(syncOnce(*ipad));

    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    // 关键条件：恢复后仅有 snapshot seq=0，不添加任何新增 changes
    QVERIFY(syncOnce(*mac));

    // Mac 在新纪元 1 写了快照文件 snapshot-0001-00000000.json
    const QString snapshotRelPath = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    const QString snapshotAbsPath = cloud.path(mac->device, snapshotRelPath);
    QVERIFY(QFile::exists(snapshotAbsPath));

    // 故障注入点：用非法截断的 JSON 替换快照文件内容
    {
        QFile file(snapshotAbsPath);
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QVERIFY(file.write("{\"corrupted_json\":") > 0);
        file.close();
    }

    // 前置断言：验证该文件 decodeSnapshot 必定返回 Corrupt
    {
        QFile file(snapshotAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile parsed;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeSnapshot(file.readAll(), mac->device.id, {1, 0}, &parsed, &decodeError),
                 SyncFiles::ParseStatus::Corrupt);
    }

    // 将损坏的快照与改动同步给 iPad
    cloud.deliver(mac->device, ipad->device);

    // iPad 触发同步一轮
    QVERIFY(syncOnce(*ipad));

    // 断言 1：iPad 因高纪元快照损坏进入 Error 状态，而不是永久挂在 WaitingForSnapshot
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);
    QVERIFY(ipad->engine->statusDetail().contains(QStringLiteral("读不懂")));

    // 断言 2：iPad 本地数据库和游标均保留原样未受损
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 初始任务")});
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 0);

    // 断言 3：iPad 记录了坏文件问题日志与向源设备请求覆盖高纪元快照的请求
    QVERIFY(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = 'file'")).toInt() > 0);
    QCOMPARE(SyncStore(ipad->device.connection).snapshotRequests().value(mac->device.id), (SyncPosition{1, 0}));

    // 断言 4：iPad 写出的 cursor.json 包含对 Mac 高纪元快照的请求（未被本机旧纪元过滤）
    {
        const QString cursorAbsPath = cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id)
                                                + QLatin1Char('/') + SyncFiles::cursorFileName());
        QFile file(cursorAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::CursorFile parsedCursor;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeCursor(file.readAll(), ipad->device.id, &parsedCursor, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        QCOMPARE(parsedCursor.epoch, 0);
        QCOMPARE(parsedCursor.snapshotRequests.value(mac->device.id), (SyncPosition{1, 0}));
    }

    // 将 iPad 的 cursor 交付给 Mac
    cloud.deliver(ipad->device, mac->device);

    // Mac 执行同步与维护：应当响应旧纪元接收端的高纪元恢复请求并重写快照（即使无新增 changes 且 seq <= covered）
    QVERIFY(syncOnce(*mac));

    // 断言 5：Mac 的快照已被重写为合法快照
    qint64 firstWrittenAt = 0;
    {
        const SyncPosition snapPos = SyncStore(mac->device.connection).snapshotPosition();
        QCOMPARE(snapPos, (SyncPosition{1, 0}));
        QFile file(snapshotAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile parsedSnapshot;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeSnapshot(file.readAll(), mac->device.id, {1, 0}, &parsedSnapshot, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        firstWrittenAt = parsedSnapshot.writtenAtMs;
        QVERIFY(firstWrittenAt > 0);
    }

    // 断言 6：相同游标请求指纹不会在下一轮重复重写快照
    QTest::qWait(20);
    QVERIFY(syncOnce(*mac));
    {
        QFile file(snapshotAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile secondParsed;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeSnapshot(file.readAll(), mac->device.id, {1, 0}, &secondParsed, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        // 时间戳未变，证明未再次进入 writeSnapshot
        QCOMPARE(secondParsed.writtenAtMs, firstWrittenAt);
    }

    // 将 Mac 重写后的快照交付给 iPad
    cloud.deliver(mac->device, ipad->device);

    // iPad 再次触发同步：成功采用新快照并恢复至 UpToDate
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
    QVERIFY(!SyncStore(ipad->device.connection).snapshotRequests().contains(mac->device.id));
}

void SyncTransportTests::higherEpochMultipleCandidatesPicksValidOverCorrupted()
{
    // 保证在更高纪元存在多个候选快照时，若按设备标识先扫描到的候选快照损坏，系统继续尝试同纪元其他设备的候选快照，
    // 立即采用合法候选并恢复至 UpToDate。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // Mac 恢复备份开新纪元 1 并发布合法快照
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 恢复后新任务")).isEmpty());
    QVERIFY(syncOnce(*mac));

    // Mac 产生的快照文件路径
    const QString macSnapshotRelPath = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    const QString macSnapshotAbsPath = cloud.path(mac->device, macSnapshotRelPath);
    QVERIFY(QFile::exists(macSnapshotAbsPath));

    // 交付给 iPad 副本
    cloud.deliver(mac->device, ipad->device);

    // 在 iPad 的同步文件夹副本中伪造一个字母序排在前面的设备 badDevice，也带有纪元 1 的快照，但内容损坏
    const QString badDeviceId = QStringLiteral("00000000000000000000000000000001");
    // 前提断言：badDeviceId 在字母序上严格先于 mac->device.id
    QVERIFY(badDeviceId < mac->device.id);

    const QString badSnapshotRelPath = SyncFiles::deviceDirectory(badDeviceId)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    const QString badSnapshotAbsPath = cloud.path(ipad->device, badSnapshotRelPath);
    QDir(cloud.replica(ipad->device)).mkpath(SyncFiles::deviceDirectory(badDeviceId));
    {
        QFile file(badSnapshotAbsPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QVERIFY(file.write("{\"corrupted\":true") > 0);
        file.close();
    }

    // iPad 触发同步一轮
    QVERIFY(syncOnce(*ipad));

    // 断言：虽然先遇到了损坏的 badDevice 快照，但跳过并继续尝试 mac 的快照，成功完成采用
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
    QVERIFY(taskTitles(ipad->device).contains(QStringLiteral("Mac 恢复后新任务")));
}

void SyncTransportTests::higherEpochMultipleSnapshotsOnSameDevicePicksValidOverCorrupted()
{
    // 保证同一设备存在多个高纪元快照时（较新快照损坏、较旧快照合法），系统能够尝试较旧快照并成功采用，
    // 再通过连续的改动增量追平进度，恢复至 UpToDate。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // 在 Mac 恢复前先添加并同步一条“恢复前保留任务”
    QVERIFY(!addTask(mac->device, QStringLiteral("恢复前保留任务")).isEmpty());
    QVERIFY(syncOnce(*mac));
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("恢复前保留任务")});

    // 备份并恢复 Mac，开新纪元 1
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));

    // 恢复后初始快照 {1, 0} 生成
    QVERIFY(syncOnce(*mac));

    // 再添加一条“恢复后新增任务”并 sync
    QVERIFY(!addTask(mac->device, QStringLiteral("恢复后新增任务")).isEmpty());
    QVERIFY(syncOnce(*mac));

    // 前置断言：Mac 端真实存在 changes {1, 1} 与 snapshot {1, 0}
    const QString change1Rel = SyncFiles::changesDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::changeFileName({1, 1});
    QVERIFY(QFile::exists(cloud.path(mac->device, change1Rel)));
    const QString oldSnapshotRel = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    QVERIFY(QFile::exists(cloud.path(mac->device, oldSnapshotRel)));

    // 交付合法旧 snapshot {1, 0} + changes {1, 1} 给 iPad
    cloud.deliver(mac->device, ipad->device, [](const QString& rel) {
        // 若 Mac 生成了其他快照，拦截之，确保交付的快照只有旧快照 {1, 0}
        return rel.contains(QStringLiteral("snapshot-")) && !rel.contains(QStringLiteral("snapshot-0001-00000000.json"));
    });
    const QString oldSnapshotIpadAbs = cloud.path(ipad->device, oldSnapshotRel);
    QVERIFY(QFile::exists(oldSnapshotIpadAbs));
    const QString change1IpadAbs = cloud.path(ipad->device, change1Rel);
    QVERIFY(QFile::exists(change1IpadAbs));

    // 在 iPad 接收副本伪造损坏的较新快照 {1, 1}
    const QString badSnapshotRel = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 1});
    const QString badSnapshotIpadAbs = cloud.path(ipad->device, badSnapshotRel);
    {
        QFile file(badSnapshotIpadAbs);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QVERIFY(file.write("{\"corrupted\":true") > 0);
        file.close();
    }

    // 断言旧快照 decode 合法且含恢复前任务，坏快照 decodeCorrupt
    {
        QFile file(oldSnapshotIpadAbs);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile parsed;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeSnapshot(file.readAll(), mac->device.id, {1, 0}, &parsed, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        bool hasPreservedTask = false;
        for (const auto& rec : parsed.batch.records) {
            if (rec.table == QLatin1String("tasks")
                && rec.fields.value(QStringLiteral("title")).value.toString() == QStringLiteral("恢复前保留任务")) {
                hasPreservedTask = true;
                break;
            }
        }
        QVERIFY(hasPreservedTask);
    }
    {
        QFile file(badSnapshotIpadAbs);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile parsed;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeSnapshot(file.readAll(), mac->device.id, {1, 1}, &parsed, &decodeError),
                 SyncFiles::ParseStatus::Corrupt);
    }

    // iPad 触发同步一轮
    QVERIFY(syncOnce(*ipad));

    // 断言：成功采用旧快照并连续应用增量追平，epoch=1、两条任务都在且 peerCursor 指向 {1, 1}，状态为 UpToDate
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
    const QStringList titles = taskTitles(ipad->device);
    QVERIFY(titles.contains(QStringLiteral("恢复前保留任务")));
    QVERIFY(titles.contains(QStringLiteral("恢复后新增任务")));
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors().value(mac->device.id), (SyncPosition{1, 1}));
}

void SyncTransportTests::higherEpochChangesOnlyWithoutSnapshotRequestsSnapshotAndHeals()
{
    // 保证当更高纪元仅有改动文件（changes）到达而没有任何快照文件时，设备不会静默无请求，
    // 而是向改动来源设备持久化并写出快照请求；源设备收到请求后重写快照，接收端最终成功采用。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    SyncEngine::Options options = testOptions();
    options.maintenanceIntervalMs = 0;
    setUpPair(cloud, &mac, &ipad, options);

    // Mac 恢复备份开新纪元 1 并添加新任务
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 高纪元任务")).isEmpty());
    QVERIFY(syncOnce(*mac));

    // 将 Mac 的改动同步给 iPad，但拦截/不交付任何快照文件
    cloud.deliver(mac->device, ipad->device, [](const QString& rel) {
        return rel.contains(QStringLiteral("snapshot-"));
    });

    // 前置断言：iPad 副本中存在 Mac 的 changes 文件，但不存在任何 snapshot 文件
    const QString changeRel = SyncFiles::changesDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::changeFileName({1, 1});
    QVERIFY(QFile::exists(cloud.path(ipad->device, changeRel)));
    const QString snapRel = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 1});
    QVERIFY(!QFile::exists(cloud.path(ipad->device, snapRel)));

    // iPad 触发同步一轮
    QVERIFY(syncOnce(*ipad));

    // 断言 1：iPad 处于 WaitingForSnapshot 状态
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::WaitingForSnapshot);

    // 断言 2：iPad 持久化了高纪元快照请求（指向 Mac 和最高 changes 序号 {1, 1}）
    QCOMPARE(SyncStore(ipad->device.connection).snapshotRequests().value(mac->device.id), (SyncPosition{1, 1}));

    // 断言 3：iPad 此分支未伪记文件损坏
    QCOMPARE(scalar(ipad->device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = 'file'")).toInt(), 0);

    // 断言 4：iPad 写出的 cursor.json 包含该高纪元请求
    {
        const QString cursorAbsPath = cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id)
                                                + QLatin1Char('/') + SyncFiles::cursorFileName());
        QFile file(cursorAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::CursorFile parsedCursor;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeCursor(file.readAll(), ipad->device.id, &parsedCursor, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        QCOMPARE(parsedCursor.snapshotRequests.value(mac->device.id), (SyncPosition{1, 1}));
    }

    // 将 iPad 的 cursor 交付给 Mac
    cloud.deliver(ipad->device, mac->device);

    // Mac 执行同步与维护：应当响应高纪元请求并重写快照
    QVERIFY(syncOnce(*mac));

    // 将 Mac 重写后的快照交付给 iPad（本次不拦截）
    cloud.deliver(mac->device, ipad->device);

    // iPad 再次同步：成功采用快照
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
    QVERIFY(taskTitles(ipad->device).contains(QStringLiteral("Mac 高纪元任务")));
    QVERIFY(!SyncStore(ipad->device.connection).snapshotRequests().contains(mac->device.id));
}

void SyncTransportTests::higherEpochSnapshotRequestPersistenceFailureEntersError()
{
    // 保证在为高纪元损坏快照记录快照请求时，若持久化至 sync_state 失败，系统立即进入 Error 状态，
    // 不声称已请求、不写出缺少请求的游标文件，不修改本地数据库、纪元或游标进度；撤销触发器后同一轮重试可恢复。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 初始任务")).isEmpty());
    QVERIFY(syncOnce(*ipad));

    // Mac 恢复备份并发布快照
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(syncOnce(*mac));

    // 损坏 Mac 的快照
    const QString snapshotAbsPath = cloud.path(mac->device, SyncFiles::deviceDirectory(mac->device.id)
                                             + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0}));
    {
        QFile file(snapshotAbsPath);
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QVERIFY(file.write("{\"corrupted_json\":") > 0);
        file.close();
    }
    cloud.deliver(mac->device, ipad->device);

    // 在 iPad 上创建阻止写入 snapshot request 的 SQLite 触发器
    QVERIFY(exec(ipad->device, QStringLiteral(
        "CREATE TRIGGER fail_snapshot_request_insert "
        "BEFORE INSERT ON sync_state "
        "WHEN NEW.key LIKE 'request/%' "
        "BEGIN "
        "    SELECT RAISE(ABORT, 'injected failure for snapshot request insert'); "
        "END;")));

    // 同步动作前先验证触发器真实命中，并断言无请求
    QVERIFY(!SyncStore(ipad->device.connection).setSnapshotRequest(mac->device.id, {1, 0}));
    QVERIFY(!SyncStore(ipad->device.connection).snapshotRequests().contains(mac->device.id));

    // 动作前保存 peerCursors 和 cursor 文件完整字节
    const QHash<QString, SyncPosition> peerCursorsBefore = SyncStore(ipad->device.connection).peerCursors();
    const QString cursorAbsPath = cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id)
                                            + QLatin1Char('/') + SyncFiles::cursorFileName());
    QVERIFY(QFile::exists(cursorAbsPath));
    QByteArray cursorBytesBefore;
    {
        QFile file(cursorAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        cursorBytesBefore = file.readAll();
        file.close();
    }

    // iPad 触发同步：setSnapshotRequest 应当失败
    QVERIFY(syncOnce(*ipad));

    // 断言 1：持久化失败立即进入 Error 状态
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);
    QVERIFY(ipad->engine->statusDetail().contains(QStringLiteral("无法记录快照请求")));

    // 断言 2：不声称已请求（数据库中无请求）
    QVERIFY(!SyncStore(ipad->device.connection).snapshotRequests().contains(mac->device.id));

    // 断言 3：不写缺少请求的游标文件，cursor 字节与动作前完全一致
    {
        QFile file(cursorAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QByteArray cursorBytesAfter = file.readAll();
        file.close();
        QCOMPARE(cursorBytesAfter, cursorBytesBefore);
    }

    // 断言 4：不改动本地 epoch、数据与 peerCursors
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 0);
    QCOMPARE(SyncStore(ipad->device.connection).peerCursors(), peerCursorsBefore);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 初始任务")});

    // 撤销触发器注入
    QVERIFY(exec(ipad->device, QStringLiteral("DROP TRIGGER fail_snapshot_request_insert;")));

    // 重试同步
    QVERIFY(syncOnce(*ipad));

    // 此时 setSnapshotRequest 成功，请求被记录并写出到 cursor.json
    QCOMPARE(SyncStore(ipad->device.connection).snapshotRequests().value(mac->device.id), (SyncPosition{1, 0}));
    {
        const QString cursorAbsPath = cloud.path(ipad->device, SyncFiles::deviceDirectory(ipad->device.id)
                                                + QLatin1Char('/') + SyncFiles::cursorFileName());
        QFile file(cursorAbsPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        SyncFiles::CursorFile parsedCursor;
        QString decodeError;
        QCOMPARE(SyncFiles::decodeCursor(file.readAll(), ipad->device.id, &parsedCursor, &decodeError),
                 SyncFiles::ParseStatus::Ok);
        QCOMPARE(parsedCursor.snapshotRequests.value(mac->device.id), (SyncPosition{1, 0}));
    }
}

void SyncTransportTests::higherEpochNewerFormatSnapshotYieldsNewerVersion()
{
    // 保证在扫描更高纪元快照时，若候选快照格式高于本机支持版本（NewerFormat），引擎仍返回 NewerVersion。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 初始任务")).isEmpty());
    QVERIFY(syncOnce(*ipad));

    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 恢复后新任务")).isEmpty());
    QVERIFY(syncOnce(*mac));

    const QString snapshotRelPath = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    const QString snapshotAbsPath = cloud.path(mac->device, snapshotRelPath);
    QVERIFY(QFile::exists(snapshotAbsPath));

    // 读取原始快照并篡改内部 batch 格式版本为未来版本
    QFile file(snapshotAbsPath);
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray original = file.readAll();
    file.close();
    const QByteArray newer = tamper(original, [](QJsonObject& o) {
        auto batch = o.value(QStringLiteral("batch")).toObject();
        batch.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1);
        o.insert(QStringLiteral("batch"), batch);
    });
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    QVERIFY(file.write(newer) > 0);
    file.close();

    // 交付给 iPad 并同步
    cloud.deliver(mac->device, ipad->device);
    QVERIFY(syncOnce(*ipad));

    // 断言：引擎状态为 NewerVersion，本地数据和纪元不被篡改
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NewerVersion);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 0);
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("iPad 初始任务")});
}

void SyncTransportTests::higherEpochSnapshotReadFailureExposesErrorStatus()
{
    // 保证同步文件夹在读取更高纪元快照遭遇 I/O 错误时的注入稳定性，并记录当前实现进入 Error 的基线状态。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // 注入点单元验证：直接测试 FaultySnapshotFolder 的读取拦截能力
    FaultySnapshotFolder probeFolder(cloud.replica(ipad->device));
    SyncFolder::Error probeError;
    QByteArray probeData;
    probeFolder.failSnapshotRead = true;
    QVERIFY(!probeFolder.read(QStringLiteral("devices/some_device/snapshot-0001-00000000.json"), &probeData, &probeError));
    QCOMPARE(probeError.kind, SyncFolder::ErrorKind::Io);
    probeFolder.failSnapshotRead = false;
    QVERIFY(!probeFolder.read(QStringLiteral("devices/some_device/snapshot-0001-00000000.json"), &probeData, &probeError));
    QCOMPARE(probeError.kind, SyncFolder::ErrorKind::NotFound);

    // 将 iPad 引擎的文件夹换为带有故障注入能力的 FaultySnapshotFolder
    auto faultyFolder = std::make_unique<FaultySnapshotFolder>(cloud.replica(ipad->device));
    FaultySnapshotFolder* faultyPtr = faultyFolder.get();
    faultyPtr->failSnapshotRead = true;
    ipad->engine->setFolder(std::move(faultyFolder));

    // Mac 恢复备份开新纪元 1 并发布快照
    const QString backupPath = m_data->filePath(QStringLiteral("mac-backup.sqlite"));
    QVERIFY(QFile::copy(mac->device.path, backupPath));
    restoreBackup(*mac, backupPath);
    mac->engine->start();
    QVERIFY(waitIdle(*mac->engine));
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 新纪元任务")).isEmpty());
    QVERIFY(syncOnce(*mac));

    // 将 Mac 的快照送入 iPad 的副本
    cloud.deliver(mac->device, ipad->device);

    // 前置断言：验证副本中确实存在该快照
    const QString snapshotRel = SyncFiles::deviceDirectory(mac->device.id)
        + QLatin1Char('/') + SyncFiles::snapshotFileName({1, 0});
    QVERIFY(QFile::exists(cloud.path(ipad->device, snapshotRel)));

    // iPad 触发同步一轮
    QVERIFY(syncOnce(*ipad));

    // 当前暴露行为：快照读取发生 I/O 错误时，SyncWorker 返回 I/O 读取错误，SyncEngine 结束本轮并进入 Error 状态
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::Error);
    QCOMPARE(ipad->engine->statusDetail(), QStringLiteral("注入的快照 I/O 读取失败"));

    // 撤销注入：恢复正常读取
    faultyPtr->failSnapshotRead = false;
    QVERIFY(syncOnce(*ipad));

    // 快照成功应用，状态恢复为 UpToDate
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(SyncStore(ipad->device.connection).epoch(), 1);
}

void SyncTransportTests::publishSnapshotFailureDoesNotAdvancePositionOrWriteFile()
{
    // 保证全量快照导出失败时阻断发布：不写出快照文件、不推进快照位置且引擎暴露错误，故障解除后重试成功。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud-pub-fail")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // 建立新任务，让数据库有实际数据
    QVERIFY(!addTask(mac->device, QStringLiteral("物理任务")).isEmpty());

    // 请求全量快照
    SyncStore store(mac->device.connection);
    QVERIFY(store.requestFullSnapshot());
    QVERIFY(store.needsSnapshot());

    // 故障注入：重命名 sync_settings 表，使 exportSnapshot 失败
    QVERIFY(exec(mac->device, QStringLiteral("ALTER TABLE sync_settings RENAME TO sync_settings_fault")));

    // 记录注入前的快照位置和快照文件列表
    const SyncPosition initialSnapshotPos = store.snapshotPosition();
    const QString deviceDir = cloud.path(mac->device, SyncFiles::deviceDirectory(mac->device.id));
    QStringList snapshotsBefore;
    {
        QDirIterator it(deviceDir, QStringList() << QStringLiteral("snapshot-*.json"), QDir::Files);
        while (it.hasNext()) {
            snapshotsBefore.append(QFileInfo(it.next()).fileName());
        }
    }

    // 执行一轮同步
    QVERIFY(syncOnce(*mac));

    // 此时引擎应因导出快照失败而进入 Error 状态
    QCOMPARE(mac->engine->status(), SyncEngine::Status::Error);
    // 且不得推进快照位置
    QCOMPARE(SyncStore(mac->device.connection).snapshotPosition(), initialSnapshotPos);
    // 云盘目录中不得产生新的 snapshot 文件
    {
        QStringList snapshotsDuringFault;
        QDirIterator it(deviceDir, QStringList() << QStringLiteral("snapshot-*.json"), QDir::Files);
        while (it.hasNext()) {
            snapshotsDuringFault.append(QFileInfo(it.next()).fileName());
        }
        QCOMPARE(snapshotsDuringFault, snapshotsBefore);
    }

    // 撤销注入：恢复表名
    QVERIFY(exec(mac->device, QStringLiteral("ALTER TABLE sync_settings_fault RENAME TO sync_settings")));

    // 重试同步
    QVERIFY(syncOnce(*mac));

    // 成功完成同步
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    // 全量快照标记已被清除
    QVERIFY(!SyncStore(mac->device.connection).needsSnapshot());
    // 验证新快照文件已被成功更新并包含新加的物理任务
    {
        const QString snapshotPath = deviceDir + QLatin1Char('/') + SyncFiles::snapshotFileName({0, 0});
        QFile snapFile(snapshotPath);
        QVERIFY(snapFile.open(QIODevice::ReadOnly));
        SyncFiles::SnapshotFile parsedSnapshot;
        QString parseErr;
        QCOMPARE(SyncFiles::decodeSnapshot(snapFile.readAll(), mac->device.id, {0, 0}, &parsedSnapshot, &parseErr),
                 SyncFiles::ParseStatus::Ok);
        bool foundTask = false;
        for (const SyncRecord& rec : parsedSnapshot.batch.records) {
            if (rec.table == QStringLiteral("tasks")
                && rec.fields.value(QStringLiteral("title")).value.toString() == QStringLiteral("物理任务")) {
                foundTask = true;
                break;
            }
        }
        QVERIFY(foundTask);
    }
}

void SyncTransportTests::localSyncFolderRejectsFilesExceedingBudget()
{
    // 保证 LocalSyncFolder 循环读取时累计并在 append 前拒绝超出预算的文件，刚好处于预算内的文件正常读取。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    LocalSyncFolder folder(tempDir.path());
    SyncFolder::Error openErr;
    QVERIFY(folder.open(&openErr));

    // 1. 测试 Marker（预算 64KB）
    SyncFiles::Marker marker;
    marker.folderId = QStringLiteral("folder-123");
    marker.createdBy = kDeviceA;
    const QByteArray validMarker = SyncFiles::encodeMarker(marker);
    QVERIFY(validMarker.size() < SyncFiles::kMaxMarkerBytes);

    // 刚好等于预算（有效 JSON + 空白填充）
    const QByteArray exactMarker = validMarker + QByteArray(SyncFiles::kMaxMarkerBytes - validMarker.size(), ' ');
    QCOMPARE(exactMarker.size(), SyncFiles::kMaxMarkerBytes);
    {
        QFile f(tempDir.filePath(SyncFiles::markerFileName()));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(exactMarker);
        f.close();
    }
    QByteArray readData;
    SyncFolder::Error readErr;
    QVERIFY(folder.read(SyncFiles::markerFileName(), &readData, &readErr));
    QCOMPARE(readData.size(), SyncFiles::kMaxMarkerBytes);
    SyncFiles::Marker parsedMarker;
    QString parseErr;
    QCOMPARE(SyncFiles::decodeMarker(readData, &parsedMarker, &parseErr), SyncFiles::ParseStatus::Ok);

    // 超出预算 1 字节
    const QByteArray overMarker = exactMarker + " ";
    QCOMPARE(overMarker.size(), SyncFiles::kMaxMarkerBytes + 1);
    {
        QFile f(tempDir.filePath(SyncFiles::markerFileName()));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(overMarker);
        f.close();
    }
    readData.clear();
    readErr = {};
    QVERIFY(!folder.read(SyncFiles::markerFileName(), &readData, &readErr));
    QCOMPARE(readErr.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(readErr.message.contains(QStringLiteral("预算上限")));
    QVERIFY(readData.isEmpty());

    // 2. 测试 Changes（预算 8MB）
    const QString changesPath = SyncFiles::changesDirectory(kDeviceA)
        + QLatin1Char('/') + SyncFiles::changeFileName({1, 1});
    SyncFiles::ChangeFile changeFile;
    changeFile.seq = 1;
    changeFile.writtenAtMs = 1700000000000;
    changeFile.batch = sampleBatch(kDeviceA, 1);
    const QByteArray validChange = SyncFiles::encodeChanges(changeFile);
    QVERIFY(validChange.size() < SyncFiles::kMaxChangesBytes);

    const QByteArray exactChange = validChange + QByteArray(SyncFiles::kMaxChangesBytes - validChange.size(), ' ');
    QCOMPARE(exactChange.size(), SyncFiles::kMaxChangesBytes);
    QDir(tempDir.path()).mkpath(SyncFiles::changesDirectory(kDeviceA));
    {
        QFile f(tempDir.filePath(changesPath));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(exactChange);
        f.close();
    }
    readData.clear();
    readErr = {};
    QVERIFY(folder.read(changesPath, &readData, &readErr));
    QCOMPARE(readData.size(), SyncFiles::kMaxChangesBytes);

    const QByteArray overChange = exactChange + " ";
    QCOMPARE(overChange.size(), SyncFiles::kMaxChangesBytes + 1);
    {
        QFile f(tempDir.filePath(changesPath));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(overChange);
        f.close();
    }
    readData.clear();
    readErr = {};
    QVERIFY(!folder.read(changesPath, &readData, &readErr));
    QCOMPARE(readErr.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(readErr.message.contains(QStringLiteral("预算上限")));
    QVERIFY(readData.isEmpty());

    // 3. 测试未知同步文件直接被拒绝（预算为 0）
    const QString unknownPath = QStringLiteral("devices/some_device/unknown_file.json");
    QDir(tempDir.path()).mkpath(QStringLiteral("devices/some_device"));
    {
        QFile f(tempDir.filePath(unknownPath));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("{\"key\":\"value\"}");
        f.close();
    }
    readData.clear();
    readErr = {};
    QVERIFY(!folder.read(unknownPath, &readData, &readErr));
    QCOMPARE(readErr.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(readErr.message.contains(QStringLiteral("未知同步文件")));
    QVERIFY(readData.isEmpty());
}

void SyncTransportTests::decodeDefendsAgainstFilesExceedingBudget()
{
    // 保证 SyncFiles 各 decode 解析入口在解析前拦截超预算数据并判定为 Corrupt。
    // 1. 预算映射校验：已知四类返回各自安全预算，未知同步文件必须映射为 0
    QCOMPARE(SyncFiles::maxBudgetForPath(SyncFiles::markerFileName()), SyncFiles::kMaxMarkerBytes);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("devices/0123456789abcdef0123456789abcdef/cursor.json")),
             SyncFiles::kMaxCursorBytes);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/0001-00000001.json")),
             SyncFiles::kMaxChangesBytes);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("devices/0123456789abcdef0123456789abcdef/snapshot-0001-00000001.json")),
             SyncFiles::kMaxSnapshotBytes);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("other.json")), 0);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("devices/0123456789abcdef0123456789abcdef/other.dat")), 0);
    QCOMPARE(SyncFiles::maxBudgetForPath(QStringLiteral("snapshot.json")), 0);

    // 2. decodeMarker 防守
    SyncFiles::Marker marker;
    marker.folderId = QStringLiteral("fid");
    marker.createdBy = kDeviceA;
    const QByteArray validMarker = SyncFiles::encodeMarker(marker);
    const QByteArray overMarker = validMarker + QByteArray(SyncFiles::kMaxMarkerBytes - validMarker.size() + 1, ' ');
    SyncFiles::Marker parsedMarker;
    QString parseErr;
    QCOMPARE(SyncFiles::decodeMarker(overMarker, &parsedMarker, &parseErr), SyncFiles::ParseStatus::Corrupt);
    QVERIFY(parseErr.contains(QStringLiteral("预算上限")));

    // 3. decodeCursor 防守
    SyncFiles::CursorFile cursor;
    cursor.device = kDeviceA;
    cursor.epoch = 1;
    cursor.writtenAtMs = 1700000000000;
    const QByteArray validCursor = SyncFiles::encodeCursor(cursor);
    const QByteArray overCursor = validCursor + QByteArray(SyncFiles::kMaxCursorBytes - validCursor.size() + 1, ' ');
    SyncFiles::CursorFile parsedCursor;
    QCOMPARE(SyncFiles::decodeCursor(overCursor, kDeviceA, &parsedCursor, &parseErr), SyncFiles::ParseStatus::Corrupt);
    QVERIFY(parseErr.contains(QStringLiteral("预算上限")));
}

void SyncTransportTests::writeMarkerRejectsWhenExceedingBudget()
{
    // 保证 SyncWorker::createMarker 在写入前拦截超出安全预算的标记文件并拒绝写出，原文件不被替换。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    auto folder = std::make_unique<LocalSyncFolder>(tempDir.path());
    SyncFolder* folderPtr = folder.get();
    SyncFolder::Error openErr;
    QVERIFY(folderPtr->open(&openErr));
    SyncWorker worker(std::move(folder));

    // 1. 先证明写正常小 marker 能成功，并保存原文件内容
    SyncFiles::Marker normalMarker;
    normalMarker.folderId = QStringLiteral("normal-fid-12345");
    normalMarker.createdBy = kDeviceA;
    const QByteArray normalBytes = SyncFiles::encodeMarker(normalMarker);
    QVERIFY(normalBytes.size() < SyncFiles::kMaxMarkerBytes);
    const SyncFolder::Error normalErr = worker.createMarker(normalMarker);
    QVERIFY(normalErr.ok());
    const QString markerPath = tempDir.filePath(SyncFiles::markerFileName());
    QVERIFY(QFile::exists(markerPath));
    QFile normalFile(markerPath);
    QVERIFY(normalFile.open(QIODevice::ReadOnly));
    const QByteArray originalMarkerBytes = normalFile.readAll();
    normalFile.close();
    QCOMPARE(originalMarkerBytes, normalBytes);

    // 2. 构造编码后超过 64 KiB 预算的 marker
    SyncFiles::Marker overMarker;
    overMarker.folderId = QString(70 * 1024, QLatin1Char('m'));
    overMarker.createdBy = kDeviceA;
    const QByteArray overBytes = SyncFiles::encodeMarker(overMarker);
    QVERIFY(overBytes.size() > SyncFiles::kMaxMarkerBytes);

    // 3. 断言写入接口返回错误且原文件未被替换
    const SyncFolder::Error err = worker.createMarker(overMarker);
    QVERIFY(!err.ok());
    QCOMPARE(err.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(err.message.contains(QStringLiteral("预算")));

    QFile afterFile(markerPath);
    QVERIFY(afterFile.open(QIODevice::ReadOnly));
    QCOMPARE(afterFile.readAll(), originalMarkerBytes);
}

void SyncTransportTests::writeCursorRejectsWhenExceedingBudget()
{
    // 保证 SyncWorker::writeCursor 在写入前拦截超出安全预算的游标文件并拒绝写出，原文件不被替换。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    auto folder = std::make_unique<LocalSyncFolder>(tempDir.path());
    SyncFolder* folderPtr = folder.get();
    SyncFolder::Error openErr;
    QVERIFY(folderPtr->open(&openErr));
    SyncWorker worker(std::move(folder));

    // 1. 先证明写正常小 cursor 成功，并保存原文件内容
    SyncFiles::CursorFile normalCursor;
    normalCursor.device = kDeviceA;
    normalCursor.epoch = 1;
    normalCursor.writtenAtMs = 1700000000000;
    normalCursor.applied.insert(kDeviceB, {1, 10});
    const QByteArray normalBytes = SyncFiles::encodeCursor(normalCursor);
    QVERIFY(normalBytes.size() < SyncFiles::kMaxCursorBytes);
    const SyncFolder::Error normalErr = worker.writeCursor(normalCursor);
    QVERIFY(normalErr.ok());
    const QString cursorPath = tempDir.filePath(SyncFiles::deviceDirectory(kDeviceA) + QLatin1Char('/') + SyncFiles::cursorFileName());
    QVERIFY(QFile::exists(cursorPath));
    QFile normalFile(cursorPath);
    QVERIFY(normalFile.open(QIODevice::ReadOnly));
    const QByteArray originalCursorBytes = normalFile.readAll();
    normalFile.close();
    QCOMPARE(originalCursorBytes, normalBytes);

    // 2. 构造编码后超过 128 KiB 预算的 cursor（填充 2500 个合法 32 位 hex 设备标识）
    SyncFiles::CursorFile overCursor;
    overCursor.device = kDeviceA;
    overCursor.epoch = 1;
    overCursor.writtenAtMs = 1700000000000;
    for (int i = 0; i < 2500; ++i) {
        const QString peer = QStringLiteral("%1").arg(i, 32, 16, QLatin1Char('0'));
        overCursor.applied.insert(peer, {1, static_cast<qint64>(i + 1)});
    }
    const QByteArray overBytes = SyncFiles::encodeCursor(overCursor);
    QVERIFY(overBytes.size() > SyncFiles::kMaxCursorBytes);

    // 3. 断言写入接口返回错误且原文件未被替换
    const SyncFolder::Error err = worker.writeCursor(overCursor);
    QVERIFY(!err.ok());
    QCOMPARE(err.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(err.message.contains(QStringLiteral("预算")));

    QFile afterFile(cursorPath);
    QVERIFY(afterFile.open(QIODevice::ReadOnly));
    QCOMPARE(afterFile.readAll(), originalCursorBytes);
}

void SyncTransportTests::writeChangesRejectsWhenExceedingBudget()
{
    // 保证 SyncWorker::writeChanges 在写入前拦截超出安全预算的增量文件并拒绝写出，不产生新改动文件。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    auto folder = std::make_unique<LocalSyncFolder>(tempDir.path());
    SyncFolder* folderPtr = folder.get();
    SyncFolder::Error openErr;
    QVERIFY(folderPtr->open(&openErr));
    SyncWorker worker(std::move(folder));

    // 1. 先证明写正常小 changes 能成功，生成第 1 批改动
    SyncBatch normalBatch;
    normalBatch.device = kDeviceA;
    normalBatch.epoch = 1;
    SyncRecord normalRec;
    normalRec.table = QStringLiteral("tasks");
    normalRec.syncId = QStringLiteral("normal-task-1");
    normalRec.fields.insert(QStringLiteral("title"), {QStringLiteral("正常任务"), {1700000000000, kDeviceA}, {0, QString()}});
    normalBatch.records.append(normalRec);

    const SyncWorker::WriteResult normalResult = worker.writeChanges(normalBatch, 0, 1700000000000);
    QVERIFY(normalResult.error.ok());
    QCOMPARE(normalResult.position.seq, 1);
    const QString change1Path = tempDir.filePath(normalResult.path);
    QVERIFY(QFile::exists(change1Path));

    // 2. 构造编码后超过 8 MiB 预算的 changes（单条任务 notes 填充 9 MiB 文本）
    SyncBatch overBatch;
    overBatch.device = kDeviceA;
    overBatch.epoch = 1;
    SyncRecord bigRec;
    bigRec.table = QStringLiteral("tasks");
    bigRec.syncId = QStringLiteral("over-task-1");
    const QString bigNotes(9 * 1024 * 1024, QLatin1Char('c'));
    bigRec.fields.insert(QStringLiteral("notes"), {bigNotes, {1700000000001, kDeviceA}, {0, QString()}});
    overBatch.records.append(bigRec);

    SyncFiles::ChangeFile overChangeFile;
    overChangeFile.seq = 2;
    overChangeFile.writtenAtMs = 1700000000001;
    overChangeFile.batch = overBatch;
    const QByteArray overBytes = SyncFiles::encodeChanges(overChangeFile);
    QVERIFY(overBytes.size() > SyncFiles::kMaxChangesBytes);

    // 3. 断言写入接口返回错误且没有第 2 批文件生成
    const SyncWorker::WriteResult result = worker.writeChanges(overBatch, 1, 1700000000001);
    QVERIFY(!result.error.ok());
    QCOMPARE(result.error.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(result.error.message.contains(QStringLiteral("预算")));

    const QString change2Path = tempDir.filePath(SyncFiles::changesDirectory(kDeviceA)
                                                + QLatin1Char('/') + SyncFiles::changeFileName({1, 2}));
    QVERIFY(!QFile::exists(change2Path));
}

void SyncTransportTests::writeSnapshotRejectsWhenExceedingBudget()
{
    // 保证 SyncWorker::writeSnapshot 在写入前拦截超出安全预算的快照文件并拒绝写出，原快照不被替换。
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    auto folder = std::make_unique<LocalSyncFolder>(tempDir.path());
    SyncFolder* folderPtr = folder.get();
    SyncFolder::Error openErr;
    QVERIFY(folderPtr->open(&openErr));
    SyncWorker worker(std::move(folder));

    // 1. 先证明写正常小快照能成功，并保存原快照文件
    SyncFiles::SnapshotFile normalSnapshot;
    normalSnapshot.coveredSeq = 1;
    normalSnapshot.writtenAtMs = 1700000000000;
    normalSnapshot.batch = sampleBatch(kDeviceA, 1);
    const QByteArray normalBytes = SyncFiles::encodeSnapshot(normalSnapshot);
    QVERIFY(normalBytes.size() < SyncFiles::kMaxSnapshotBytes);

    const SyncWorker::WriteResult normalResult = worker.writeSnapshot(normalSnapshot);
    QVERIFY(normalResult.error.ok());
    const QString snapPath = tempDir.filePath(normalResult.path);
    QVERIFY(QFile::exists(snapPath));
    QFile normalSnapFile(snapPath);
    QVERIFY(normalSnapFile.open(QIODevice::ReadOnly));
    const QByteArray originalSnapBytes = normalSnapFile.readAll();
    normalSnapFile.close();

    // 2. 构造编码后超过 64 MiB 预算的快照（65 MiB 文本字段）
    SyncFiles::SnapshotFile overSnapshot;
    overSnapshot.coveredSeq = 1;
    overSnapshot.writtenAtMs = 1700000000001;
    overSnapshot.batch.device = kDeviceA;
    overSnapshot.batch.epoch = 1;
    SyncRecord bigRec;
    bigRec.table = QStringLiteral("tasks");
    bigRec.syncId = QStringLiteral("over-task-snap");
    const QString bigNotes(65 * 1024 * 1024, QLatin1Char('s'));
    bigRec.fields.insert(QStringLiteral("notes"), {bigNotes, {1700000000001, kDeviceA}, {0, QString()}});
    overSnapshot.batch.records.append(bigRec);

    const QByteArray overBytes = SyncFiles::encodeSnapshot(overSnapshot);
    QVERIFY(overBytes.size() > SyncFiles::kMaxSnapshotBytes);

    // 3. 断言写入接口返回错误且原快照文件未被替换
    const SyncWorker::WriteResult result = worker.writeSnapshot(overSnapshot);
    QVERIFY(!result.error.ok());
    QCOMPARE(result.error.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(result.error.message.contains(QStringLiteral("预算")));

    QFile afterSnapFile(snapPath);
    QVERIFY(afterSnapFile.open(QIODevice::ReadOnly));
    QCOMPARE(afterSnapFile.readAll(), originalSnapBytes);
}

void SyncTransportTests::enginePublishSnapshotRejectsWhenSnapshotExceedsBudget()
{
    // 保证 SyncEngine 在发布全量快照时若编码超出预算则阻断发布，不确认队列、不推进位置、不生成超限快照。
    FakeICloud cloud(m_data->filePath(QStringLiteral("cloud-pub-budget")));
    std::unique_ptr<Node> mac;
    std::unique_ptr<Node> ipad;
    setUpPair(cloud, &mac, &ipad);

    // 1. 先用正常小数据证明全量发布路径可成功
    QVERIFY(!addTask(mac->device, QStringLiteral("正常小任务")).isEmpty());
    SyncStore store(mac->device.connection);
    QVERIFY(store.requestFullSnapshot());
    QVERIFY(store.needsSnapshot());
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    QVERIFY(!store.needsSnapshot());

    // 2. 推进到新 epoch 并进入 needsSnapshot 状态
    QVERIFY(store.beginEpochAfterRestore(store.epoch(), mac->device.id));
    QCOMPARE(store.epoch(), 1);
    QVERIFY(store.needsSnapshot());

    // 3. 用参数绑定生成导致快照编码超限（> 64 MiB）的记录
    const QString hugeNotes(65 * 1024 * 1024, QLatin1Char('h'));
    QSqlQuery insertBig(deviceDb(mac->device));
    insertBig.prepare(QStringLiteral(
        "INSERT INTO tasks (title, notes, date, completed, display_order) VALUES (:title, :notes, :date, 0, 1)"));
    insertBig.bindValue(QStringLiteral(":title"), QStringLiteral("超大任务"));
    insertBig.bindValue(QStringLiteral(":notes"), hugeNotes);
    insertBig.bindValue(QStringLiteral(":date"), QStringLiteral("2026-10-01"));
    QVERIFY(insertBig.exec());

    // 前置断言：快照编码实际长度确实超出预算上限
    bool exportOk = false;
    QString exportErr;
    const SyncBatch hugeBatch = store.exportSnapshot(&exportOk, &exportErr);
    QVERIFY(exportOk);
    SyncFiles::SnapshotFile hugeSnapFile;
    hugeSnapFile.coveredSeq = store.outboundPosition().seq;
    hugeSnapFile.writtenAtMs = 1700000000000;
    hugeSnapFile.batch = hugeBatch;
    const QByteArray encodedHuge = SyncFiles::encodeSnapshot(hugeSnapFile);
    QVERIFY(encodedHuge.size() > SyncFiles::kMaxSnapshotBytes);

    // 4. 保存状态基线
    const int outboxCountBefore = scalar(mac->device, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")).toInt();
    QVERIFY(outboxCountBefore > 0);
    const SyncPosition outboundPosBefore = store.outboundPosition();
    const SyncPosition snapshotPosBefore = store.snapshotPosition();
    const bool needsSnapshotBefore = store.needsSnapshot();
    QVERIFY(needsSnapshotBefore);

    const QString deviceDir = cloud.path(mac->device, SyncFiles::deviceDirectory(mac->device.id));
    const QString overSnapshotPath = deviceDir + QLatin1Char('/') + SyncFiles::snapshotFileName({store.epoch(), 0});
    QVERIFY(!QFile::exists(overSnapshotPath));

    // 5. 启动同步：期望进入 Error 状态且所有状态不被推进、不写出超限快照
    QVERIFY(syncOnce(*mac));

    QCOMPARE(mac->engine->status(), SyncEngine::Status::Error);
    QVERIFY(mac->engine->statusDetail().contains(QStringLiteral("预算")));
    QCOMPARE(scalar(mac->device, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")).toInt(), outboxCountBefore);
    QCOMPARE(SyncStore(mac->device.connection).outboundPosition().epoch, outboundPosBefore.epoch);
    QCOMPARE(SyncStore(mac->device.connection).outboundPosition().seq, outboundPosBefore.seq);
    QCOMPARE(SyncStore(mac->device.connection).snapshotPosition().epoch, snapshotPosBefore.epoch);
    QCOMPARE(SyncStore(mac->device.connection).snapshotPosition().seq, snapshotPosBefore.seq);
    QCOMPARE(SyncStore(mac->device.connection).needsSnapshot(), needsSnapshotBefore);
    QVERIFY(!QFile::exists(overSnapshotPath));
}

QTEST_GUILESS_MAIN(SyncTransportTests)

#include "SyncTransportTests.moc"
