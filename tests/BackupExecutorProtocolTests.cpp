#include "services/BackupExecutorProtocol.h"
#include "services/DatabaseManager.h"

#include <QDataStream>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

#include <algorithm>

namespace {
BackupExecutorProtocol::Request snapshotRequest()
{
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("snapshot");
    request.snapshot = {QStringLiteral("/local/database.db"), QStringLiteral("/external/backup.tomatobackup"),
                        QStringLiteral("/local/backups"), QStringLiteral("/local/settings.ini"),
                        QStringLiteral("manual"), DatabaseManager::kCurrentSchemaVersion, {}};
    return request;
}
}

class BackupExecutorProtocolTests : public QObject
{
    Q_OBJECT
private slots:
    void longHistorySettingsRoundTrip();
    void settingsBudgetBoundaries_data();
    void settingsBudgetBoundaries();
    void requestsAndResultsRoundTrip();
    void settingsKeepTheirTypesAndBytes();
    void invalidRequestsAreRejected_data();
    void invalidRequestsAreRejected();
    void runRequestValidatesBeforeTouchingFiles();
    void stageAndInspectReturnOperationResults();
    void stopMessagesUseKnownReasons();
    void partialAndCoalescedFramesAreRejected();
};

void BackupExecutorProtocolTests::requestsAndResultsRoundTrip()
{
    // 快照、检查、暂存请求和提交事实经协议往返后保持原值，结果不会吞掉已提交的失败。
    const auto snapshot = snapshotRequest();
    BackupExecutorProtocol::Request inspect;
    inspect.op = QStringLiteral("inspect");
    inspect.sourcePath = QStringLiteral("/local/snapshot.tomatobackup");
    inspect.schema = DatabaseManager::kCurrentSchemaVersion;
    BackupExecutorProtocol::Request stage;
    stage.op = QStringLiteral("stage");
    stage.sourcePath = QStringLiteral("/external/original.tomatobackup");
    stage.destinationPath = QStringLiteral("/local/.restore-staging-test.tmp");
    stage.maxBytes = 4096;
    stage.budgetMs = 1234;
    for (const auto& request : {snapshot, inspect, stage}) {
        const auto encoded = BackupExecutorProtocol::encodeRequest(request);
        QCOMPARE(encoded.count('\n'), 1);
        QString error;
        const auto decoded = BackupExecutorProtocol::decodeRequest(encoded, &error);
        QVERIFY2(decoded, qPrintable(error));
        QCOMPARE(BackupExecutorProtocol::encodeRequest(*decoded), encoded);
    }
    BackupExecutorProtocol::Result result{{false, QStringLiteral("提交后取消"), true},
                                          {{QStringLiteral("valid"), false}, {QStringLiteral("taskCount"), 7}}};
    QString error;
    const auto decoded = BackupExecutorProtocol::decodeResult(BackupExecutorProtocol::encodeResult(result), &error);
    QVERIFY2(decoded, qPrintable(error));
    QCOMPARE(decoded->operation.success, false);
    QCOMPARE(decoded->operation.error, result.operation.error);
    QCOMPARE(decoded->operation.committed, true);
    QCOMPARE(decoded->info, result.info);
    QVERIFY(!BackupExecutorProtocol::decodeResult("{}", &error));
    QVERIFY(!BackupExecutorProtocol::decodeResult("{\"success\":true,\"error\":\"\",\"committed\":\"false\"}", &error));
}

void BackupExecutorProtocolTests::settingsKeepTheirTypesAndBytes()
{
    // 进程协议原样转送偏好字节和 QVariant 类型，不把整数、列表或二进制转成 JSON 字符串。
    const QVariantMap values{{QStringLiteral("appearance/string"), QStringLiteral("中文\n偏好")},
                             {QStringLiteral("appearance/int"), 42},
                             {QStringLiteral("appearance/bool"), true},
                             {QStringLiteral("appearance/list"), QStringList{QStringLiteral("甲"), QStringLiteral("乙")}},
                             {QStringLiteral("appearance/bytes"), QByteArray("a\0b", 3)}};
    auto request = snapshotRequest();
    for (auto it = values.constBegin(); it != values.constEnd(); ++it) {
        QByteArray blob;
        QDataStream stream(&blob, QIODevice::WriteOnly);
        stream.setVersion(QDataStream::Qt_6_7);
        stream << it.value();
        QCOMPARE(stream.status(), QDataStream::Ok);
        request.snapshot.settings.insert(it.key(), blob);
    }
    QString error;
    const auto decoded = BackupExecutorProtocol::decodeRequest(BackupExecutorProtocol::encodeRequest(request), &error);
    QVERIFY2(decoded, qPrintable(error));
    QCOMPARE(decoded->snapshot.settings, request.snapshot.settings);
    for (auto it = decoded->snapshot.settings.constBegin(); it != decoded->snapshot.settings.constEnd(); ++it) {
        QDataStream stream(it.value());
        stream.setVersion(QDataStream::Qt_6_7);
        QVariant value;
        stream >> value;
        QCOMPARE(stream.status(), QDataStream::Ok);
        QCOMPARE(value.metaType(), values.value(it.key()).metaType());
        QCOMPARE(value, values.value(it.key()));
    }
}

void BackupExecutorProtocolTests::invalidRequestsAreRejected_data()
{
    // 未知协议、操作、路径、类型和偏好键在触碰文件前被拒绝，缺字段也不能靠默认值放行。
    QTest::addColumn<QString>("field");
    QTest::addColumn<QJsonValue>("value");
    QTest::newRow("version") << QStringLiteral("v") << QJsonValue(2);
    QTest::newRow("operation") << QStringLiteral("op") << QJsonValue(QStringLiteral("delete"));
    for (const QString& path : {QStringLiteral("source"), QStringLiteral("destination"),
                                QStringLiteral("stagingDirectory"), QStringLiteral("settingsPath")}) {
        QTest::newRow(qPrintable(path + QStringLiteral("-relative"))) << path << QJsonValue(QStringLiteral("relative.db"));
        QTest::newRow(qPrintable(path + QStringLiteral("-empty"))) << path << QJsonValue(QString());
        QTest::newRow(qPrintable(path + QStringLiteral("-nul"))) << path << QJsonValue(QStringLiteral("/local/a") + QChar::Null + QStringLiteral("b"));
    }
    QTest::newRow("kind") << QStringLiteral("kind") << QJsonValue(QStringLiteral("unknown"));
    QTest::newRow("foreign-setting") << QStringLiteral("settings") << QJsonValue(QJsonObject{{QStringLiteral("foreign/secret"), QStringLiteral("YWJj")}});
    QTest::newRow("bad-base64") << QStringLiteral("settings") << QJsonValue(QJsonObject{{QStringLiteral("appearance/key"), QStringLiteral("!@#$")}});
    QTest::newRow("budget-negative") << QStringLiteral("budgetMs") << QJsonValue(-1);
    QTest::newRow("budget-huge") << QStringLiteral("budgetMs") << QJsonValue(120001);
    QTest::newRow("budget-fraction") << QStringLiteral("budgetMs") << QJsonValue(1.5);
    QTest::newRow("schema-negative") << QStringLiteral("schema") << QJsonValue(-1);
    QTest::newRow("extra-field") << QStringLiteral("unused") << QJsonValue(true);
    QTest::newRow("missing-source") << QStringLiteral("source") << QJsonValue(QJsonValue::Undefined);
}

void BackupExecutorProtocolTests::invalidRequestsAreRejected()
{
    // 请求白名单逐项生效，不将非法字段忽略后当作有效备份任务。
    QFETCH(QString, field);
    QFETCH(QJsonValue, value);
    auto object = QJsonDocument::fromJson(BackupExecutorProtocol::encodeRequest(snapshotRequest())).object();
    QString error;
    QVERIFY(BackupExecutorProtocol::decodeRequest(QJsonDocument(object).toJson(QJsonDocument::Compact), &error));
    if (value.isUndefined()) object.remove(field);
    else object.insert(field, value);
    QVERIFY(!BackupExecutorProtocol::decodeRequest(QJsonDocument(object).toJson(QJsonDocument::Compact), &error));
    QVERIFY(!error.isEmpty());
}

void BackupExecutorProtocolTests::runRequestValidatesBeforeTouchingFiles()
{
    // 直接调用执行入口也拒绝越界复制预算，已有目标的内容保持不变。
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QFile source(dir.filePath(QStringLiteral("source")));
    QVERIFY(source.open(QIODevice::WriteOnly));
    QCOMPARE(source.write("new"), qint64(3));
    source.close();
    QFile target(dir.filePath(QStringLiteral("target")));
    QVERIFY(target.open(QIODevice::WriteOnly));
    QCOMPARE(target.write("old"), qint64(3));
    target.close();
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("stage");
    request.sourcePath = source.fileName();
    request.destinationPath = target.fileName();
    request.maxBytes = -1;
    const auto result = BackupExecutorProtocol::runRequest(request, {});
    QVERIFY(!result.operation.success);
    QVERIFY(!result.operation.committed);
    QVERIFY(target.open(QIODevice::ReadOnly));
    QCOMPARE(target.readAll(), QByteArray("old"));
    for (const qint64 budget : {qint64(-1), BackupOperations::kMaxBackupFileBytes + 1}) {
        request.maxBytes = budget;
        QString error;
        QVERIFY(!BackupExecutorProtocol::decodeRequest(BackupExecutorProtocol::encodeRequest(request), &error));
    }
}

void BackupExecutorProtocolTests::stageAndInspectReturnOperationResults()
{
    // 合法暂存复制按字节发布，检查无效文件返回结构化原因，已停止的请求不创建目标。
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QFile source(dir.filePath(QStringLiteral("source")));
    QVERIFY(source.open(QIODevice::WriteOnly));
    QCOMPARE(source.write("bytes"), qint64(5));
    source.close();
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("stage");
    request.sourcePath = source.fileName();
    request.destinationPath = dir.filePath(QStringLiteral("target"));
    request.maxBytes = 5;
    const auto staged = BackupExecutorProtocol::runRequest(request, {});
    QVERIFY(staged.operation.success);
    QVERIFY(staged.operation.committed);
    QFile target(request.destinationPath);
    QVERIFY(target.open(QIODevice::ReadOnly));
    QCOMPARE(target.readAll(), QByteArray("bytes"));
    request.op = QStringLiteral("inspect");
    request.schema = DatabaseManager::kCurrentSchemaVersion;
    const auto inspected = BackupExecutorProtocol::runRequest(request, {});
    QVERIFY(!inspected.operation.success);
    QVERIFY(!inspected.info.value(QStringLiteral("valid")).toBool());
    QVERIFY(!inspected.info.value(QStringLiteral("reason")).toString().isEmpty());
    request.op = QStringLiteral("stage");
    request.destinationPath = dir.filePath(QStringLiteral("cancelled"));
    auto operation = std::make_shared<BackupOperationControl>();
    operation->requestStop();
    QVERIFY(!BackupExecutorProtocol::runRequest(request, operation).operation.success);
    QVERIFY(!QFileInfo::exists(request.destinationPath));
}

void BackupExecutorProtocolTests::stopMessagesUseKnownReasons()
{
    // 取消、预算耗尽、退出在进程间保留停止原因，未知停止消息不冒充合法请求。
    using Reason = BackupOperationControl::StopReason;
    for (const auto reason : {Reason::Cancelled, Reason::TimedOut, Reason::Shutdown}) {
        QCOMPARE(BackupExecutorProtocol::decodeStop(BackupExecutorProtocol::encodeStop(reason)), std::optional<Reason>(reason));
    }
    QVERIFY(!BackupExecutorProtocol::decodeStop("{\"stop\":\"unknown\"}"));
    QVERIFY(!BackupExecutorProtocol::decodeStop("{\"stop\":\"cancelled\",\"extra\":1}"));
}

// 保证截断的半行 JSON 与合并在一起的两行粘包帧在协议解码层一律被拒绝，不会只解一半或吞掉第二帧。
void BackupExecutorProtocolTests::partialAndCoalescedFramesAreRejected()
{
    const auto reqBytes = BackupExecutorProtocol::encodeRequest(snapshotRequest());
    const auto resBytes = BackupExecutorProtocol::encodeResult({{true, {}, false}, {}});
    QString error;

    // 截断帧（半包无结尾花括号）
    QVERIFY(!BackupExecutorProtocol::decodeRequest(reqBytes.left(reqBytes.size() / 2), &error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!BackupExecutorProtocol::decodeResult(resBytes.left(resBytes.size() / 2), &error));
    QVERIFY(!error.isEmpty());

    // 粘包帧（两条 JSON 行紧连或带换行拼在同一帧中）
    QVERIFY(!BackupExecutorProtocol::decodeRequest(reqBytes + reqBytes, &error));
    QVERIFY(!BackupExecutorProtocol::decodeResult(resBytes + resBytes, &error));
    QVERIFY(!BackupExecutorProtocol::decodeStop("{\"stop\":\"cancelled\"}\n{\"stop\":\"shutdown\"}\n"));
}


// 保证超过旧版五百条门槛的每日目标历史通过协议后字节不变。
void BackupExecutorProtocolTests::longHistorySettingsRoundTrip()
{
    auto request = snapshotRequest();
    for (int i = 0; i < 600; ++i) request.snapshot.settings.insert(QStringLiteral("focus/dailyGoalHistory/%1").arg(i), QByteArray("value"));
    QString error;
    const auto decoded = BackupExecutorProtocol::decodeRequest(BackupExecutorProtocol::encodeRequest(request), &error);
    QVERIFY2(decoded, qPrintable(error));
    QCOMPARE(decoded->snapshot.settings, request.snapshot.settings);
}

// 保证协议在条数、单值和含中文键的总字节边界接受等号、拒绝多一字节或一条。
void BackupExecutorProtocolTests::settingsBudgetBoundaries_data()
{
    QTest::addColumn<QString>("budget");
    QTest::newRow("entries") << QStringLiteral("entries");
    QTest::newRow("value") << QStringLiteral("value");
    QTest::newRow("total") << QStringLiteral("total");
}

// 保证编码与外部解码执行同一预算，外部请求不能绕过编码器的超限拒绝。
void BackupExecutorProtocolTests::settingsBudgetBoundaries()
{
    QFETCH(QString, budget);
    auto request = snapshotRequest();
    auto& values = request.snapshot.settings;
    if (budget == QStringLiteral("entries")) {
        for (int i = 0; i < 40000; ++i) values.insert(QStringLiteral("focus/key/%1").arg(i), QByteArray("v"));
    } else if (budget == QStringLiteral("value")) {
        values.insert(QStringLiteral("focus/key"), QByteArray(64 * 1024, 'v'));
    } else {
        qint64 remaining = 8 * 1024 * 1024;
        for (int i = 0; remaining > 0; ++i) {
            const auto key = QStringLiteral("focus/中文/%1").arg(i);
            const auto size = qMin<qint64>(64 * 1024, remaining - key.toUtf8().size());
            QVERIFY(size > 0);
            values.insert(key, QByteArray(size, 'v'));
            remaining -= key.toUtf8().size() + size;
        }
        QCOMPARE(remaining, qint64(0));
    }
    const auto encoded = BackupExecutorProtocol::encodeRequest(request);
    QVERIFY(!encoded.isEmpty());
    QVERIFY(encoded.size() < BackupExecutorProtocol::kMaxLineBytes);
    QString error;
    QVERIFY2(BackupExecutorProtocol::decodeRequest(encoded, &error), qPrintable(error));
    auto object = QJsonDocument::fromJson(encoded).object();
    if (budget == QStringLiteral("entries")) values.insert(QStringLiteral("focus/extra"), QByteArray("v"));
    else if (budget == QStringLiteral("value")) values.last().append('v');
    else {
        auto partial = std::find_if(values.begin(), values.end(), [](const QByteArray& value) { return value.size() < 64 * 1024; });
        QVERIFY(partial != values.end());
        partial.value().append('v');
    }
    QJsonObject over;
    for (auto it = values.cbegin(); it != values.cend(); ++it) over.insert(it.key(), QString::fromLatin1(it.value().toBase64()));
    object.insert(QStringLiteral("settings"), over);
    QVERIFY(!BackupExecutorProtocol::decodeRequest(QJsonDocument(object).toJson(QJsonDocument::Compact), &error));
    QVERIFY(!error.isEmpty());
    QVERIFY(BackupExecutorProtocol::encodeRequest(request).isEmpty());
}

QTEST_GUILESS_MAIN(BackupExecutorProtocolTests)
#include "BackupExecutorProtocolTests.moc"
