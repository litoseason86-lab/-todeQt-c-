#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <functional>
#include <memory>

#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/SyncFiles.h"
#include "../src/services/SyncRecord.h"
#include "../src/services/SyncStore.h"

// 设备间同步的云盘传输（050 阶段 3）的测试。
//
// 3a 只看文件本身：文件名和位置的互转、四种文件的内容，以及坏文件、新版本文件能不能被认出来。
// 这一层不碰磁盘，所以直接比较字节与结构。
// 3b 看本地目录的读写：原子替换、错误归类（不存在、不可用）。
// 3c 看传输记账：读到哪、写到哪都记在库里，重开之后还在。
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

private:
    Device openDevice(const QString& name);
    void reopen(Device& device);

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

QTEST_GUILESS_MAIN(SyncTransportTests)

#include "SyncTransportTests.moc"
