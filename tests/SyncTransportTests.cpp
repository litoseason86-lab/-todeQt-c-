#include <QJsonDocument>
#include <QJsonObject>
#include <QtTest>

#include <functional>

#include "../src/services/SyncFiles.h"
#include "../src/services/SyncRecord.h"

// 设备间同步的云盘传输（050 阶段 3）的测试。
//
// 3a 只看文件本身：文件名和位置的互转、四种文件的内容，以及坏文件、新版本文件能不能被认出来。
// 这一层不碰磁盘，所以直接比较字节与结构。
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
    // 3a：文件格式
    void fileNamesRoundTripAndRejectForeignNames();
    void deviceIdsTemporaryNamesAndEmptyFolders();
    void filesRoundTrip();
    void corruptFilesAreRecognized_data();
    void corruptFilesAreRecognized();
    void newerFormatsAreNotTreatedAsCorrupt();
    void wrongFolderHints_data();
    void wrongFolderHints();
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

QTEST_GUILESS_MAIN(SyncTransportTests)

#include "SyncTransportTests.moc"
