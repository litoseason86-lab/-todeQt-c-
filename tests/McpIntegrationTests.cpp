#include <QtTest>
#include "../src/mcp/bridge/McpAccessController.h"
#include "../src/mcp/helper/McpBridgeClient.h"
#include "../src/mcp/common/McpEndpointFiles.h"
#include "../src/mcp/common/McpJsonStream.h"
#include "../src/platform/macos/MacLocalPeerIdentity.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QUuid>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <cstring>

using namespace McpContracts;
namespace {
// 测试可驱动事件循环；生产传输层禁止用这种等待方式。短目录同时避开 macOS /tmp 符号链接和 socket 长度上限。
bool until(const std::function<bool()>& predicate, int timeout = 3000)
{
    QDeadlineTimer deadline(timeout);
    while (!predicate() && !deadline.hasExpired()) QTest::qWait(5);
    return predicate();
}
QJsonObject metadata()
{
    return {{"app_version", "test"}, {"logical_today", "2026-09-17"}, {"time_zone", "Asia/Shanghai"}, {"day_start_hour", 4}};
}
QJsonObject errorBody(const QJsonObject& result)
{
    return QJsonDocument::fromJson(result.value("content").toArray().first().toObject().value("text").toString().toUtf8()).object();
}
QString code(const QJsonObject& result) { return errorBody(result).value("code").toString(); }
QByteArray line(const QJsonObject& object) { return QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n'; }
struct Host {
    QTemporaryDir directory {QStringLiteral("/private/tmp/mcp-XXXXXX")};
    QSettings settings {directory.filePath("settings.ini"), QSettings::IniFormat};
    McpPaths::Resolution endpoint {McpPaths::resolveForRoot(directory.filePath("endpoint"))};
    McpAccessController access {endpoint, settings, metadata};
};
QJsonObject createArguments(const QString& session)
{
    return {{"app_session_id", session}, {"idempotency_key", QUuid::createUuid().toString(QUuid::WithoutBraces)},
            {"title", "测试任务"}, {"date", "2026-09-17"}};
}
class ClientProcess : public QObject {
public:
    QProcess process;
    QByteArray buffer;
    QList<QJsonObject> replies;
    bool badOutput = false;
    ClientProcess()
    {
        connect(&process, &QProcess::readyReadStandardOutput, this, [this] {
            buffer += process.readAllStandardOutput();
            qsizetype end;
            while ((end = buffer.indexOf('\n')) >= 0) {
                QJsonParseError error;
                const auto document = QJsonDocument::fromJson(buffer.left(end), &error);
                if (error.error != QJsonParseError::NoError || !document.isObject()) badOutput = true;
                else replies.append(document.object());
                buffer.remove(0, end + 1);
            }
        });
    }
    ~ClientProcess() override
    {
        if (process.state() != QProcess::NotRunning) {
            process.closeWriteChannel();
            if (!process.waitForFinished(1500)) { process.kill(); process.waitForFinished(); }
        }
    }
    bool start(const QString& root)
    {
        process.start(QStringLiteral(MCP_TEST_HELPER), {root});
        return process.waitForStarted(3000);
    }
    void send(const QJsonValue& id, const QString& method, const QJsonObject& params = {})
    { process.write(line({{"jsonrpc", "2.0"}, {"id", id}, {"method", method}, {"params", params}})); }
    bool has(const QJsonValue& id) const
    {
        for (const auto& reply : replies) if (reply.value("id") == id) return true;
        return false;
    }
    QJsonObject take(const QJsonValue& id)
    {
        for (qsizetype i = 0; i < replies.size(); ++i)
            if (replies[i].value("id") == id) return replies.takeAt(i);
        return {};
    }
    bool initialize(const QString& version = QStringLiteral("2025-11-25"))
    {
        send(1, "initialize", {{"protocolVersion", version}, {"capabilities", QJsonObject{}},
                              {"clientInfo", QJsonObject{{"name", "isolated-test"}, {"version", "1"}}}});
        if (!until([this] { return has(1); })) return false;
        process.write(line({{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}}));
        return true;
    }
    void call(const QJsonValue& id, Tool tool, const QJsonObject& args = {})
    { send(id, "tools/call", {{"name", toolName(tool)}, {"arguments", args}}); }
};
class RawPeer : public QObject {
public:
    QLocalSocket socket;
    McpJsonStream stream {&socket, kMaxResponseBytes};
    QList<QJsonObject> frames;
    RawPeer() { connect(&stream, &McpJsonStream::received, this, [this](const QJsonObject& value) { frames.append(value); }); }
    bool connectTo(const McpPaths::Resolution& endpoint)
    {
        socket.connectToServer(endpoint.paths.socketPath);
        return until([this] { return socket.state() == QLocalSocket::ConnectedState; });
    }
    bool authenticate(const McpPaths::Resolution& endpoint)
    {
        QByteArray key; int version = 0;
        if (!McpEndpointFiles::read(endpoint.paths, &key, &version) || !connectTo(endpoint)) return false;
        stream.send({{"kind", "hello"}, {"version", version}, {"token", QString::fromLatin1(key)}});
        return until([this] { return !frames.isEmpty(); }) && frames.takeFirst().value("accepted").toBool();
    }
    QJsonObject call(const QString& id, Tool tool, const QJsonObject& args = {}, int remaining = kToolTimeoutMs)
    { return {{"kind", "call"}, {"id", id}, {"tool", toolName(tool)}, {"arguments", args}, {"remaining_ms", remaining}}; }
};
class MemoryDevice : public QIODevice {
public:
    QByteArray input, output;
    qint64 pendingOutput = 0;
    MemoryDevice() { open(ReadWrite | Unbuffered); }
    bool isSequential() const override { return true; }
    qint64 bytesAvailable() const override { return input.size(); }
    qint64 bytesToWrite() const override { return pendingOutput; }
    void feed(const QByteArray& bytes) { input += bytes; emit readyRead(); }
    qint64 readData(char* data, qint64 size) override {
        const auto count = qMin(size, qint64(input.size()));
        memcpy(data, input.constData(), size_t(count)); input.remove(0, count); return count;
    }
    qint64 writeData(const char* data, qint64 size) override { output.append(data, size); return size; }
};
}

class McpIntegrationTests : public QObject
{
    Q_OBJECT
private slots:
    void statusReportsInteractionAndRecentOperation()
    {
        Host host;
        QVERIFY(host.access.setEnabled(true));
        host.access.setBlockProvider([] { return QList<BusyBlock>{{BusyReason::Editing, QStringLiteral("测试弹窗"), 7}}; });
        const auto blocks = host.access.appStatus().value("blocks").toArray();
        QCOMPARE(blocks.size(), 1);
        QCOMPARE(blocks.first().toObject().value("reason"), QJsonValue("editing"));
        QVERIFY(host.access.blockSummary().contains(QStringLiteral("测试弹窗")));
        QSignalSpy copied(&host.access, &McpAccessController::copyRequested);
        host.access.copyHelperPath();
        QCOMPARE(copied.size(), 1);
        QVERIFY(copied.first().first().toString().endsWith("/PomodoroTodoMcp"));
        host.access.dispatch(Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(host.access.lastOperation().contains(QStringLiteral("PERMISSION_DENIED")));
        QVERIFY(!host.access.lastOperation().contains(QStringLiteral("测试任务")));
        host.access.beginRestore();
        QCOMPARE(host.access.appStatus().value("blocks").toArray().size(), 2);
    }
    void initTestCase() { QCoreApplication::setApplicationVersion("test"); }
    void defaultOff()
    {
        Host host;
        QVERIFY(host.directory.isValid());
        QVERIFY(!host.access.start());
        QVERIFY(!host.access.listening());
        QVERIFY(!QFileInfo::exists(host.endpoint.paths.rootDirectory));
    }
    void offlineDiscovery_data()
    {
        QTest::addColumn<QString>("version");
        QTest::addColumn<QString>("negotiated");
        QTest::newRow("2025-11-25") << "2025-11-25" << "2025-11-25";
        QTest::newRow("2025-06-18") << "2025-06-18" << "2025-06-18";
        QTest::newRow("unknown-version") << "1900-01-01" << "2025-11-25";
    }
    void offlineDiscovery()
    {
        QFETCH(QString, version); QFETCH(QString, negotiated);
        Host host; ClientProcess client;
        QVERIFY(client.start(host.endpoint.paths.rootDirectory));
        QVERIFY(client.initialize(version));
        const auto initialized = client.take(1).value("result").toObject();
        QCOMPARE(initialized.value("protocolVersion").toString(), negotiated);
        QCOMPARE(initialized.value("capabilities").toObject(), QJsonObject({{"tools", QJsonObject{}}}));
        client.send(2, "tools/list");
        client.call(3, Tool::GetStatus);
        client.call(4, Tool::ListCategories);
        QVERIFY(until([&] { return client.has(2) && client.has(3) && client.has(4); }));
        QCOMPARE(client.take(2).value("result").toObject().value("tools").toArray(), toolListJson());
        const auto result = client.take(3).value("result").toObject();
        const auto status = result.value("structuredContent").toObject();
        QVERIFY(validateAgainstSchema(status, contract(Tool::GetStatus).outputSchema).ok());
        QCOMPARE(errorBody(result), status); // 只读 content 的模型也取得完整字段。
        QCOMPARE(status.value("connected"), QJsonValue(false));
        QCOMPARE(status.value("unavailable_reason"), QJsonValue("endpoint_unreachable"));
        QCOMPARE(code(client.take(4).value("result").toObject()), QStringLiteral("APP_UNAVAILABLE"));
        QVERIFY(!client.badOutput);
    }
    void lifecycleAndErrors()
    {
        Host host; ClientProcess client;
        QVERIFY(client.start(host.endpoint.paths.rootDirectory));
        client.send(0, "tools/list");
        QVERIFY(until([&] { return client.has(0); }));
        QCOMPARE(client.take(0).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidRequest);
        QVERIFY(client.initialize()); client.take(1);
        client.send(2, "initialize"); client.send(3, "unknown"); client.send(4, "ping");
        client.call(5, Tool::GetTask, {{"task_id", 0}});
        client.process.write(line({{"jsonrpc", "2.0"}, {"method", "unknown-notification"}}));
        QVERIFY(until([&] { return client.has(2) && client.has(3) && client.has(4) && client.has(5); }));
        QCOMPARE(client.take(2).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidRequest);
        QCOMPARE(client.take(3).value("error").toObject().value("code").toInt(), JsonRpcError::MethodNotFound);
        QCOMPARE(client.take(4).value("result").toObject(), QJsonObject{});
        const auto invalid = client.take(5).value("result").toObject();
        QCOMPARE(code(invalid), QStringLiteral("VALIDATION_ERROR"));
        QVERIFY(invalid.value("isError").toBool());
        QVERIFY(!invalid.contains("structuredContent"));
        client.process.closeWriteChannel();
        QVERIFY(until([&] { return client.process.state() == QProcess::NotRunning; }));
        QCOMPARE(client.process.exitCode(), 0);
        QVERIFY(client.replies.isEmpty());
        QVERIFY(!client.badOutput);
    }
    void offlineThenOnlineAndPermission()
    {
        Host host; ClientProcess client;
        QVERIFY(client.start(host.endpoint.paths.rootDirectory)); QVERIFY(client.initialize()); client.take(1);
        client.call(2, Tool::GetStatus);
        QVERIFY(until([&] { return client.has(2); })); client.take(2);
        QVERIFY(host.access.setEnabled(true));
        client.call(3, Tool::GetStatus);
        QVERIFY(until([&] { return client.has(3); }));
        const auto status = client.take(3).value("result").toObject().value("structuredContent").toObject();
        QVERIFY(validateAgainstSchema(status, contract(Tool::GetStatus).outputSchema).ok());
        QCOMPARE(status.value("connected"), QJsonValue(true));
        QCOMPARE(status.value("app").toObject().value("app_session_id").toString(), host.access.sessionId());
        client.call(4, Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(until([&] { return client.has(4); }));
        QCOMPARE(code(client.take(4).value("result").toObject()), QStringLiteral("PERMISSION_DENIED"));
        host.access.setWriteEnabled(true);
        client.call(5, Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(until([&] { return client.has(5); }));
        QCOMPARE(errorBody(client.take(5).value("result").toObject()).value("details").toObject().value("reason"), QJsonValue("stage_not_ready"));
        const QString before = host.access.sessionId();
        QVERIFY(host.access.setEnabled(false));
        QVERIFY(before != host.access.sessionId());
        QVERIFY(!QFileInfo::exists(host.endpoint.paths.credentialPath));
        QVERIFY(!QFileInfo::exists(host.endpoint.paths.discoveryPath));
        QVERIFY(host.access.setEnabled(true));
        client.call(6, Tool::GetStatus);
        QVERIFY(until([&] { return client.has(6); }));
        // 断开的旧连接不会自动重发；下一次独立请求才按需重连。
        client.take(6);
        client.call(7, Tool::GetStatus);
        QVERIFY(until([&] { return client.has(7); }));
        QCOMPARE(client.take(7).value("result").toObject().value("structuredContent").toObject().value("connected"), QJsonValue(true));
    }
    void policyWriteFailureDoesNotGrant()
    {
        Host host;
        QVERIFY(host.access.setEnabled(false));
        QVERIFY(QFile::setPermissions(host.settings.fileName(), QFileDevice::ReadOwner));
        QVERIFY(!host.access.setEnabled(true));
        QVERIFY(!host.access.enabled());
        QVERIFY(!host.access.listening());
        QVERIFY(!host.access.setWriteEnabled(true));
        QVERIFY(!host.access.writeEnabled());
        QVERIFY(!host.access.lastError().isEmpty());
        QVERIFY(QFile::setPermissions(host.settings.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner));
        // 同一控制器不重启：恢复权限后应能保存，并清掉此前的失败提示。
        QVERIFY(host.access.setWriteEnabled(true));
        QVERIFY(host.access.writeEnabled());
        QVERIFY(host.access.lastError().isEmpty());
        QVERIFY(host.access.setEnabled(true));
        QVERIFY(host.access.enabled());
        QVERIFY(host.access.listening());
        QSettings persisted(host.settings.fileName(), QSettings::IniFormat);
        persisted.sync();
        QCOMPARE(persisted.value("mcp/enabled").toBool(), true);
        QCOMPARE(persisted.value("mcp/writeEnabled").toBool(), true);
    }
    void policyWriteFailureStillRevokes()
    {
        Host host;
        QVERIFY(host.access.setEnabled(true));
        QVERIFY(host.access.setWriteEnabled(true));
        QVERIFY(QFile::setPermissions(host.settings.fileName(), QFileDevice::ReadOwner));
        QVERIFY(!host.access.setWriteEnabled(false));
        QVERIFY(!host.access.writeEnabled());
        QVERIFY(!host.access.setEnabled(false));
        QVERIFY(!host.access.enabled());
        QVERIFY(!host.access.listening());
        QVERIFY(QFile::setPermissions(host.settings.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner));
        // 同一控制器不重启：恢复权限后应能保存，并清掉此前的失败提示。
        QVERIFY(host.access.setWriteEnabled(true));
        QVERIFY(host.access.writeEnabled());
        QVERIFY(host.access.lastError().isEmpty());
        QVERIFY(host.access.setEnabled(true));
        QVERIFY(host.access.enabled());
        QVERIFY(host.access.listening());
        QSettings persisted(host.settings.fileName(), QSettings::IniFormat);
        persisted.sync();
        QCOMPARE(persisted.value("mcp/enabled").toBool(), true);
        QCOMPARE(persisted.value("mcp/writeEnabled").toBool(), true);
    }
    void restoreAndShutdownGates()
    {
        Host host; QVERIFY(host.access.setEnabled(true)); host.access.setWriteEnabled(true);
        const QString session = host.access.sessionId();
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({{"test", true}}); });
        host.access.beginRestore();
        QVERIFY(session != host.access.sessionId());
        QCOMPARE(code(host.access.dispatch(Tool::ListCategories, {})), QStringLiteral("APP_BUSY"));
        QCOMPARE(host.access.appStatus().value("blocks").toArray().first().toObject().value("reason"), QJsonValue("backup_restore"));
        QVERIFY(!host.access.dispatch(Tool::GetStatus, {}).value("isError").toBool());
        host.access.setRestoreBlocked(false);
        QCOMPARE(code(host.access.dispatch(Tool::CreateTask, createArguments(session))), QStringLiteral("SESSION_EXPIRED"));
        QVERIFY(!host.access.dispatch(Tool::CreateTask, createArguments(host.access.sessionId())).value("isError").toBool());
        QCOMPARE(calls, 1);
        host.access.shutdown();
        QCOMPARE(code(host.access.dispatch(Tool::ListCategories, {})), QStringLiteral("APP_BUSY"));
        QVERIFY(!host.access.listening());
        QCOMPARE(host.settings.value("mcp/enabled").toBool(), true);
        QCOMPARE(host.settings.value("mcp/writeEnabled").toBool(), true);
    }
    void secureFilesAndExclusiveOwner()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        struct stat info {};
        QVERIFY(::stat(QFile::encodeName(host.endpoint.paths.rootDirectory), &info) == 0);
        QCOMPARE(info.st_mode & 0777, mode_t(0700));
        QVERIFY(::stat(QFile::encodeName(host.endpoint.paths.credentialPath), &info) == 0);
        QCOMPARE(info.st_mode & 0777, mode_t(0600));
        McpAccessController other(host.endpoint, host.settings, metadata);
        QVERIFY(!other.start());
        QByteArray key; int version = 0;
        QVERIFY(McpEndpointFiles::read(host.endpoint.paths, &key, &version));
        QCOMPARE(version, kBridgeProtocolVersion);
        QVERIFY(::chmod(QFile::encodeName(host.endpoint.paths.credentialPath), 0644) == 0);
        QVERIFY(!McpEndpointFiles::read(host.endpoint.paths, &key, &version));
        QVERIFY(::chmod(QFile::encodeName(host.endpoint.paths.credentialPath), 0600) == 0);
        QVERIFY(McpEndpointFiles::read(host.endpoint.paths, &key, &version));
    }
    void symlinkRefused()
    {
        Host host;
        QFile target(host.directory.filePath("target")); QVERIFY(target.open(QIODevice::WriteOnly)); target.write("keep"); target.close();
        QVERIFY(QDir().mkdir(host.endpoint.paths.rootDirectory));
        QVERIFY(::chmod(QFile::encodeName(host.endpoint.paths.rootDirectory), 0700) == 0);
        QVERIFY(QFile::link(target.fileName(), host.endpoint.paths.credentialPath));
        QVERIFY(!host.access.setEnabled(true));
        QVERIFY(target.open(QIODevice::ReadOnly)); QCOMPARE(target.readAll(), QByteArray("keep"));
        QVERIFY(QFileInfo(host.endpoint.paths.credentialPath).isSymLink());
    }
    void rootSymlinkRefused()
    {
        Host host;
        QVERIFY(QDir().mkdir(host.directory.filePath("real")));
        QVERIFY(QFile::link(host.directory.filePath("real"), host.endpoint.paths.rootDirectory));
        QVERIFY(!host.access.setEnabled(true));
        QVERIFY(!QFileInfo::exists(host.directory.filePath("real/key")));
    }
    void staleFilesReplaced()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        QByteArray first; int version; QVERIFY(McpEndpointFiles::read(host.endpoint.paths, &first, &version));
        QVERIFY(host.access.setEnabled(false));
        QFile stale(host.endpoint.paths.credentialPath); QVERIFY(stale.open(QIODevice::WriteOnly)); stale.write(first); stale.close();
        QVERIFY(host.access.setEnabled(true));
        QByteArray second; QVERIFY(McpEndpointFiles::read(host.endpoint.paths, &second, &version));
        QVERIFY(first != second);
    }
    void badCredentialAndPrivateVersion_data()
    {
        QTest::addColumn<bool>("badVersion");
        QTest::newRow("credential") << false;
        QTest::newRow("version") << true;
    }
    void badCredentialAndPrivateVersion()
    {
        QFETCH(bool, badVersion);
        Host host; QVERIFY(host.access.setEnabled(true));
        RawPeer peer; QVERIFY(peer.connectTo(host.endpoint));
        peer.stream.send({{"kind", "hello"}, {"version", badVersion ? 99 : 1}, {"token", "wrong"}});
        QVERIFY(until([&] { return !peer.frames.isEmpty(); }));
        QCOMPARE(peer.frames.first().value("accepted"), QJsonValue(false));
        QCOMPARE(peer.frames.first().value("reason"), QJsonValue(badVersion ? "bridge_version_mismatch" : "authentication_failed"));
        QVERIFY(until([&] { return peer.socket.state() == QLocalSocket::UnconnectedState; }));
    }
    void unauthorizedCallNeverDispatched()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        int calls = 0; host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return QJsonObject{}; });
        RawPeer peer; QVERIFY(peer.connectTo(host.endpoint));
        peer.stream.send(peer.call("x", Tool::ListCategories));
        QVERIFY(until([&] { return peer.socket.state() == QLocalSocket::UnconnectedState; }));
        QCOMPARE(calls, 0);
    }
    void cancellationAndExecutionPermission()
    {
        Host host; QVERIFY(host.access.setEnabled(true)); host.access.setWriteEnabled(true);
        int calls = 0; host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({}); });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        peer.socket.write(line(peer.call("cancel", Tool::ListCategories)) + line({{"kind", "cancel"}, {"id", "cancel"}})
                          + line(peer.call("read", Tool::ListCategories)));
        QVERIFY(until([&] { return peer.frames.size() == 1; }));
        QCOMPARE(peer.frames.first().value("id"), QJsonValue("read"));
        QCOMPARE(calls, 1); peer.frames.clear();
        peer.stream.send(peer.call("write", Tool::CreateTask, createArguments(host.access.sessionId())));
        host.access.setWriteEnabled(false);
        QVERIFY(until([&] { return !peer.frames.isEmpty(); }));
        QCOMPARE(code(peer.frames.first().value("result").toObject()), QStringLiteral("PERMISSION_DENIED"));
        QCOMPARE(calls, 1);
    }
    void expiredQueuedRequest()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) {
            ++calls;
            // 模拟同一主线程刚完成一项耗时操作；下一项排队请求必须重新检查截止时间。
            QTest::qSleep(15);
            return makeToolSuccessResult({});
        });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        peer.socket.write(line(peer.call("first", Tool::ListCategories)) + line(peer.call("expired", Tool::ListCategories, {}, 1)));
        QVERIFY(until([&] { return peer.frames.size() == 2; }));
        QCOMPARE(calls, 1);
        QCOMPARE(code(peer.frames.last().value("result").toObject()), QStringLiteral("APP_UNAVAILABLE"));
    }
    void duplicateAndQueueLimit_data()
    {
        QTest::addColumn<bool>("duplicate");
        QTest::newRow("duplicate") << true;
        QTest::newRow("queue-full") << false;
    }
    void duplicateAndQueueLimit()
    {
        QFETCH(bool, duplicate);
        Host host; QVERIFY(host.access.setEnabled(true));
        int calls = 0; host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return QJsonObject{}; });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        QByteArray batch;
        for (int i = 0; i < (duplicate ? 2 : 17); ++i) batch += line(peer.call(duplicate ? "same" : QString::number(i), Tool::ListCategories));
        peer.socket.write(batch);
        QVERIFY(until([&] { return peer.socket.state() == QLocalSocket::UnconnectedState; }));
        QCOMPARE(calls, 0);
    }
    void peerIdentity()
    {
        int descriptors[2]; QVERIFY(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
        QVERIFY(MacLocalPeerIdentity::isCurrentUser(descriptors[0]));
        ::close(descriptors[0]); ::close(descriptors[1]);
        QVERIFY(!MacLocalPeerIdentity::isCurrentUser(-1));
    }
    void frameBoundsAndUtf8()
    {
        MemoryDevice device; McpJsonStream stream(&device, 16);
        QSignalSpy received(&stream, &McpJsonStream::received), malformed(&stream, &McpJsonStream::malformed), failed(&stream, &McpJsonStream::failed);
        device.feed("{\"a\":"); device.feed("1}\n{}\n"); QCOMPARE(received.size(), 2);
        device.feed("[1]\n"); QCOMPARE(malformed.size(), 1);
        device.feed(QByteArray("{\"a\":\"") + char(0xff) + "\"}\n"); QCOMPARE(malformed.size(), 2);
        device.feed(QByteArray("{\"a\":\"") + QByteArray::fromHex("efbfbd") + "\"}\n"); QCOMPARE(received.size(), 3);
        device.feed("null\n"); QCOMPARE(malformed.size(), 3);
        QCOMPARE(malformed.last().first().toInt(), JsonRpcError::InvalidRequest);
        device.feed(QByteArray(17, 'x')); QCOMPARE(failed.size(), 1);
    }
    void incompleteEofAndOutputLimit()
    {
        MemoryDevice device; McpJsonStream stream(&device, kMaxRequestBytes);
        QSignalSpy malformed(&stream, &McpJsonStream::malformed), failed(&stream, &McpJsonStream::failed);
        device.feed("{"); stream.finishInput(); QCOMPARE(malformed.size(), 1);
        device.pendingOutput = kMaxResponseBytes;
        QVERIFY(!stream.send({{"a", 1}})); QCOMPARE(failed.size(), 1);
        MemoryDevice other; McpJsonStream large(&other, kMaxRequestBytes);
        QVERIFY(!large.send({{"text", QString(kMaxResponseBytes, 'x')}}));
        QVERIFY(other.output.isEmpty());
    }
    void disableInsideDispatch()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        host.access.setDataHandler([&](Tool, const QJsonObject&) {
            host.access.setEnabled(false);
            return makeToolSuccessResult({});
        });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        peer.stream.send(peer.call("disable", Tool::ListCategories));
        QVERIFY(until([&] { return peer.socket.state() == QLocalSocket::UnconnectedState; }));
        QVERIFY(!host.access.listening());
    }
    void emptyPathCannotConnectOrListen()
    {
        Host host;
        const auto endpoint = McpPaths::resolveForRoot(QString());
        McpAccessController access(endpoint, host.settings, metadata);
        QVERIFY(!access.setEnabled(true));
        McpBridgeClient bridge(endpoint); QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("status", Tool::GetStatus, {});
        QCOMPARE(spy.size(), 1);
        QCOMPARE(spy.first().at(1).toJsonObject().value("structuredContent").toObject().value("unavailable_reason"), QJsonValue("path_invalid"));
    }
    void pathInvalidStillLists()
    {
        Host host; ClientProcess client;
        QVERIFY(client.start(host.directory.path() + QString(150, 'x'))); QVERIFY(client.initialize()); client.take(1);
        client.send(2, "tools/list"); client.call(3, Tool::GetStatus);
        QVERIFY(until([&] { return client.has(2) && client.has(3); }));
        QCOMPARE(client.take(2).value("result").toObject().value("tools").toArray().size(), 10);
        const auto status = client.take(3).value("result").toObject().value("structuredContent").toObject();
        QVERIFY(validateAgainstSchema(status, contract(Tool::GetStatus).outputSchema).ok());
        QCOMPARE(status.value("unavailable_reason"), QJsonValue("path_invalid"));
        QCOMPARE(status.value("path_error").toObject().value("reason"), QJsonValue("path_too_long"));
    }
    void stdioCancellationIdsAndEof()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({}); });
        ClientProcess client; QVERIFY(client.start(host.endpoint.paths.rootDirectory)); QVERIFY(client.initialize()); client.take(1);
        client.process.write(line({{"jsonrpc", "2.0"}, {"id", "cancel-me"}, {"method", "tools/call"},
            {"params", QJsonObject{{"name", toolName(Tool::ListCategories)}, {"arguments", QJsonObject{}}}}})
            + line({{"jsonrpc", "2.0"}, {"method", "notifications/cancelled"}, {"params", QJsonObject{{"requestId", "cancel-me"}}}}));
        client.call(2, Tool::GetStatus); client.call("2", Tool::GetStatus);
        QVERIFY(until([&] { return client.has(2) && client.has("2"); }));
        QVERIFY(!client.has("cancel-me")); QCOMPARE(calls, 0);
        QCOMPARE(client.take(2).value("id"), QJsonValue(2));
        QCOMPARE(client.take("2").value("id"), QJsonValue("2"));
        client.process.write("{"); client.process.closeWriteChannel();
        QVERIFY(until([&] { return client.process.state() == QProcess::NotRunning; }));
        QCOMPARE(client.take(QJsonValue(QJsonValue::Null)).value("error").toObject().value("code").toInt(), JsonRpcError::ParseError);
        QVERIFY(!client.badOutput);
    }
    void stdioDuplicateInflight()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        ClientProcess client; QVERIFY(client.start(host.endpoint.paths.rootDirectory)); QVERIFY(client.initialize()); client.take(1);
        const auto request = line({{"jsonrpc", "2.0"}, {"id", "same"}, {"method", "tools/call"},
                                   {"params", QJsonObject{{"name", toolName(Tool::GetStatus)}}}});
        client.process.write(request + request);
        QVERIFY(until([&] { return client.process.state() == QProcess::NotRunning; }));
        QCOMPARE(client.take(QJsonValue(QJsonValue::Null)).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidRequest);
        QVERIFY(!client.has("same"));
    }
    void connectionLimitAndHandshakeTimeout()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        std::vector<std::unique_ptr<RawPeer>> peers;
        for (int i = 0; i < kMaxConnections; ++i) {
            auto peer = std::make_unique<RawPeer>(); QVERIFY(peer->connectTo(host.endpoint)); peers.push_back(std::move(peer));
        }
        RawPeer excess; QVERIFY(excess.connectTo(host.endpoint));
        QVERIFY(until([&] { return excess.socket.state() == QLocalSocket::UnconnectedState; }));
        QVERIFY(until([&] {
            for (const auto& peer : peers) if (peer->socket.state() != QLocalSocket::UnconnectedState) return false;
            return true;
        }, kHandshakeTimeoutMs + 1500));
        RawPeer recovered; QVERIFY(recovered.authenticate(host.endpoint));
    }
    void partialFrameTimeout()
    {
        MemoryDevice device; McpJsonStream stream(&device, kMaxRequestBytes);
        QSignalSpy failed(&stream, &McpJsonStream::failed);
        device.feed("{");
        QVERIFY(until([&] { return failed.size() == 1; }, kHandshakeTimeoutMs + 1500));
    }
    void unknownOutcomeDoesNotReplay()
    {
        Host host; QString error;
        QVERIFY(McpEndpointFiles::prepareRoot(host.endpoint.paths, &error));
        QLocalServer server; QVERIFY(server.listen(host.endpoint.paths.socketPath));
        QVERIFY(McpEndpointFiles::publish(host.endpoint.paths, QByteArray(64, 'a')));
        int calls = 0;
        connect(&server, &QLocalServer::newConnection, &server, [&] {
            auto* socket = server.nextPendingConnection();
            auto* stream = new McpJsonStream(socket, kMaxRequestBytes, socket);
            connect(stream, &McpJsonStream::received, socket, [&, socket, stream](const QJsonObject& frame) {
                if (frame.value("kind") == QJsonValue("hello"))
                    stream->send({{"kind", "hello"}, {"version", 1}, {"accepted", true}});
                else if (frame.value("kind") == QJsonValue("call")) { ++calls; socket->abort(); }
            });
        });
        McpBridgeClient bridge(host.endpoint); QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("write", Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(until([&] { return spy.size() == 1; }));
        QCOMPARE(code(spy.first().at(1).toJsonObject()), QStringLiteral("OUTCOME_UNKNOWN"));
        QCOMPARE(calls, 1);
        QTest::qWait(100); QCOMPARE(calls, 1); QCOMPARE(spy.size(), 1);
    }
    void toolTimeoutCancelsWithoutReplay()
    {
        Host host; QString error;
        QVERIFY(McpEndpointFiles::prepareRoot(host.endpoint.paths, &error));
        QLocalServer server; QVERIFY(server.listen(host.endpoint.paths.socketPath));
        QVERIFY(McpEndpointFiles::publish(host.endpoint.paths, QByteArray(64, 'a')));
        int calls = 0, cancellations = 0;
        connect(&server, &QLocalServer::newConnection, &server, [&] {
            auto* socket = server.nextPendingConnection();
            auto* stream = new McpJsonStream(socket, kMaxRequestBytes, socket);
            connect(stream, &McpJsonStream::received, socket, [&, stream](const QJsonObject& frame) {
                if (frame.value("kind") == QJsonValue("hello"))
                    stream->send({{"kind", "hello"}, {"version", 1}, {"accepted", true}});
                else if (frame.value("kind") == QJsonValue("call")) ++calls;
                else if (frame.value("kind") == QJsonValue("cancel")) ++cancellations;
            });
        });
        McpBridgeClient bridge(host.endpoint); QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("write", Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(until([&] { return spy.size() == 1 && cancellations == 1; }, kToolTimeoutMs + 1500));
        QCOMPARE(code(spy.first().at(1).toJsonObject()), QStringLiteral("OUTCOME_UNKNOWN"));
        QCOMPARE(calls, 1);
    }
    void socketByteBoundary_data()
    {
        QTest::addColumn<int>("bytes");
        QTest::newRow("103") << 103;
        QTest::newRow("104") << 104;
    }
    void socketByteBoundary()
    {
        QFETCH(int, bytes); Host host;
        const QString root = host.directory.path() + '/' + QString(bytes - QFile::encodeName(host.directory.path()).size() - 3, 'a');
        const auto endpoint = McpPaths::resolveForRoot(root);
        McpAccessController access(endpoint, host.settings, metadata);
        QCOMPARE(access.setEnabled(true), bytes == 103);
        McpBridgeClient bridge(endpoint); QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("status", Tool::GetStatus, {}); QVERIFY(until([&] { return spy.size() == 1; }));
        const auto status = spy.first().at(1).toJsonObject().value("structuredContent").toObject();
        QCOMPARE(status.value("connected").toBool(), bytes == 103);
        if (bytes == 104) QCOMPARE(status.value("unavailable_reason"), QJsonValue("path_invalid"));
    }
    void chineseSocketPath()
    {
        Host host;
        const auto endpoint = McpPaths::resolveForRoot(host.directory.filePath(QStringLiteral("接入")));
        McpAccessController access(endpoint, host.settings, metadata); QVERIFY(access.setEnabled(true));
        McpBridgeClient client(endpoint); QSignalSpy spy(&client, &McpBridgeClient::completed);
        client.call("x", Tool::GetStatus, {}); QVERIFY(until([&] { return spy.size() == 1; }));
        const auto status = spy.first().at(1).toJsonObject().value("structuredContent").toObject();
        QCOMPARE(status.value("connected"), QJsonValue(true));
    }
};
QTEST_GUILESS_MAIN(McpIntegrationTests)
#include "McpIntegrationTests.moc"
