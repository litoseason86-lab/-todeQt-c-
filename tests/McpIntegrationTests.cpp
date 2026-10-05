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
#include <fcntl.h>
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
        host.access.setBlockProvider([] { return QList<BusyBlock>{{BusyReason::Editing, QStringLiteral("TodayTaskView.edit_dialog"), 7}}; });
        const auto blocks = host.access.appStatus().value("blocks").toArray();
        QCOMPARE(blocks.size(), 1);
        QCOMPARE(blocks.first().toObject().value("reason"), QJsonValue("editing"));
        // 模型从 APP_BUSY 拿稳定来源标识；设置页给人看的是位置说明，不夹带内部标识和写给模型的指令。
        QCOMPARE(blocks.first().toObject().value("source"), QJsonValue("TodayTaskView.edit_dialog"));
        const QString summary = host.access.blockSummary();
        QVERIFY2(summary.contains(QStringLiteral("今日任务")), qPrintable(summary));
        QVERIFY2(!summary.contains(QStringLiteral("TodayTaskView")), qPrintable(summary));
        QVERIFY2(!summary.contains(QStringLiteral("details.blocks")), qPrintable(summary));
        QVERIFY2(!summary.contains(QStringLiteral("next_action")), qPrintable(summary));
        QSignalSpy copied(&host.access, &McpAccessController::copyRequested);
        host.access.copyHelperPath();
        QCOMPARE(copied.size(), 1);
        QVERIFY(copied.first().first().toString().endsWith("/PomodoroTodoMcp"));
        host.access.dispatch(Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(host.access.lastOperation().contains(QStringLiteral("PERMISSION_DENIED")));
        QVERIFY(!host.access.lastOperation().contains(QStringLiteral("测试任务")));
        host.access.beginRestore();
        const auto restoring = host.access.appStatus().value("blocks").toArray();
        QCOMPARE(restoring.size(), 2);
        // 来源标识是给模型的稳定英文键，恢复与退出也不能混进中文说明。
        QCOMPARE(restoring.last().toObject().value("source"), QJsonValue("backup.restore"));
        QVERIFY(host.access.blockSummary().contains(QStringLiteral("恢复备份")));
    }
    void sessionIdIgnoresHexCase()
    {
        Host host; QVERIFY(host.access.setEnabled(true)); QVERIFY(host.access.setWriteEnabled(true));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({}); });
        // UUID 的十六进制大小写不改变身份：大写的同一个会话编号不能被当成过期会话。
        const auto result = host.access.dispatch(Tool::CreateTask, createArguments(host.access.sessionId().toUpper()));
        QVERIFY2(!result.value("isError").toBool(), qPrintable(code(result)));
        QCOMPARE(calls, 1);
        QCOMPARE(code(host.access.dispatch(Tool::CreateTask, createArguments(QUuid::createUuid().toString(QUuid::WithoutBraces)))),
                 QStringLiteral("SESSION_EXPIRED"));
        QCOMPARE(calls, 1);
    }
    void disablingAccessRevokesWrite()
    {
        Host host; QVERIFY(host.access.setEnabled(true)); QVERIFY(host.access.setWriteEnabled(true));
        QVERIFY(host.access.setEnabled(false));
        QVERIFY(!host.access.writeEnabled());
        // 关掉再打开只恢复读取：写权限要用户再单独打开，不能随“重新开启接入”悄悄回来。
        QVERIFY(host.access.setEnabled(true));
        QVERIFY(!host.access.writeEnabled());
        QSettings persisted(host.settings.fileName(), QSettings::IniFormat);
        persisted.sync();
        QCOMPARE(persisted.value("mcp/enabled").toBool(), true);
        QCOMPARE(persisted.value("mcp/writeEnabled").toBool(), false);
        QCOMPARE(code(host.access.dispatch(Tool::CreateTask, createArguments(host.access.sessionId()))),
                 QStringLiteral("PERMISSION_DENIED"));
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
        // 初始化说明告诉模型先取会话与逻辑今日，免得它猜日期或凭空编会话编号。
        QVERIFY(initialized.value("instructions").toString().contains(QStringLiteral("pomodoro_get_status")));
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
        // 已有一条 1 MiB 的结果没发完不是故障：背压限制积压，后面还能再排一条，不能因此断线。
        device.pendingOutput = kMaxResponseBytes;
        QVERIFY(stream.send({{"a", 1}})); QCOMPARE(failed.size(), 0);
        // 远超硬上限说明对端长期不读，这时才按传输失败处理，防止内存无限增长。
        device.pendingOutput = 64 * kMaxResponseBytes;
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
        // 只拒绝重复的那一条：原请求照常返回，辅助程序不退出，其他在途结果不会跟着丢。
        QVERIFY(until([&] { return client.has("same") && client.has(QJsonValue(QJsonValue::Null)); }));
        QCOMPARE(client.take(QJsonValue(QJsonValue::Null)).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidRequest);
        QVERIFY(client.take("same").contains("result"));
        QCOMPARE(client.process.state(), QProcess::Running);
        client.send(2, "ping");
        QVERIFY(until([&] { return client.has(2); }));
        QVERIFY(!client.badOutput);
    }
    void stdioSurvivesSlowStartAndSplitLines()
    {
        // 标准输入输出的另一端就是拉起辅助程序的 AI 客户端：晚于 5 秒才初始化、
        // 一行分几次写完，都不能让辅助程序自己静默退出。
        Host host; ClientProcess client; QVERIFY(client.start(host.endpoint.paths.rootDirectory));
        const QByteArray initialize = line({{"jsonrpc", "2.0"}, {"id", 1}, {"method", "initialize"},
            {"params", QJsonObject{{"protocolVersion", "2025-11-25"}, {"capabilities", QJsonObject{}},
                                   {"clientInfo", QJsonObject{{"name", "slow-client"}, {"version", "1"}}}}}});
        client.process.write(initialize.left(10));
        QTest::qWait(kHandshakeTimeoutMs + 1000);
        QCOMPARE(client.process.state(), QProcess::Running);
        client.process.write(initialize.mid(10));
        QVERIFY(until([&] { return client.has(1); }));
        QVERIFY(client.take(1).contains("result"));
        client.process.write(line({{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}}));
        client.send(2, "tools/list");
        QVERIFY(until([&] { return client.has(2); }));
        QCOMPARE(client.take(2).value("result").toObject().value("tools").toArray().size(), 10);
        QVERIFY(!client.badOutput);
    }
    void stdioOversizedLineAndBlankLines()
    {
        Host host; ClientProcess client;
        QVERIFY(client.start(host.endpoint.paths.rootDirectory)); QVERIFY(client.initialize()); client.take(1);
        // 空行不是消息，不应换来一条 id 为 null 的解析错误。
        client.process.write("\n \r\n");
        client.send(2, "ping");
        QVERIFY(until([&] { return client.has(2); }));
        QVERIFY(!client.has(QJsonValue(QJsonValue::Null)));
        // 超过 64 KiB 的一行只拒绝这一条并丢弃到行尾，后面的请求照常处理。
        client.process.write(QByteArray(kMaxRequestBytes + 100, 'x') + '\n');
        client.send(3, "ping");
        QVERIFY(until([&] { return client.has(3); }));
        QCOMPARE(client.take(QJsonValue(QJsonValue::Null)).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidRequest);
        QCOMPARE(client.process.state(), QProcess::Running);
        // 游标为 null 等同没给；真正的游标仍按协议报参数错误。
        client.send(4, "tools/list", {{"cursor", QJsonValue(QJsonValue::Null)}});
        client.send(5, "tools/list", {{"cursor", "next-page"}});
        QVERIFY(until([&] { return client.has(4) && client.has(5); }));
        QCOMPARE(client.take(4).value("result").toObject().value("tools").toArray().size(), 10);
        QCOMPARE(client.take(5).value("error").toObject().value("code").toInt(), JsonRpcError::InvalidParams);
        QVERIFY(!client.badOutput);
    }
    void pipelinedLargeResultsStayConnected()
    {
        // 模型会并行调用工具。两条大结果先后生成时要按顺序发完，
        // 不能因为发送缓冲里叠了两条就断开整条连接，把已写库的请求也变成“结果未知”。
        Host host; QVERIFY(host.access.setEnabled(true));
        const QString blob(300000, QChar(u'x'));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({{"blob", blob}}); });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        peer.socket.write(line(peer.call("a", Tool::ListCategories)) + line(peer.call("b", Tool::ListCategories))
                          + line(peer.call("c", Tool::ListCategories)));
        QVERIFY(until([&] { return peer.frames.size() == 3 || peer.socket.state() != QLocalSocket::ConnectedState; }, 10000));
        QCOMPARE(peer.socket.state(), QLocalSocket::ConnectedState);
        QCOMPARE(peer.frames.size(), 3);
        QCOMPARE(calls, 3);
        for (const auto& frame : peer.frames)
            QVERIFY(!frame.value("result").toObject().value("isError").toBool());
    }
    void executionWaitsForUnreadResult()
    {
        // 背压：对端没读走上一条结果时，主应用不继续执行后面的请求。
        // 否则慢读端会让主应用把一串大结果都攒在内存里，排队的写入也会在结果送不出去时照样执行。
        Host host; QVERIFY(host.access.setEnabled(true));
        const QString blob(300000, QChar(u'x'));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({{"blob", blob}}); });
        RawPeer peer; QVERIFY(peer.authenticate(host.endpoint));
        // 认证之后不再解析，并把读缓冲压到很小：Qt 读满就停，内核缓冲随即写满，服务端的结果留在它自己的发送缓冲里。
        QObject::disconnect(&peer.socket, &QLocalSocket::readyRead, &peer.stream, nullptr);
        peer.socket.setReadBufferSize(1024);
        peer.socket.write(line(peer.call("a", Tool::ListCategories)) + line(peer.call("b", Tool::ListCategories))
                          + line(peer.call("c", Tool::ListCategories)));
        QVERIFY(until([&] { return calls >= 1; }));
        QTest::qWait(500);
        QCOMPARE(calls, 1);
        // 对端开始读，排队的请求依次执行、结果依次送达。
        peer.socket.setReadBufferSize(0);
        QByteArray received;
        QVERIFY(until([&] { received += peer.socket.readAll(); return received.count('\n') == 3; }, 10000));
        QCOMPARE(calls, 3);
        QCOMPARE(peer.socket.state(), QLocalSocket::ConnectedState);
    }
    void helperStdoutBacklogDoesNotExit()
    {
        // 客户端暂时没读 stdout 时，辅助程序把结果留在缓冲里等它读走，
        // 不能在积压超过 1 MiB 时直接退出、连同已经执行的请求结果一起丢掉。
        Host host; QVERIFY(host.access.setEnabled(true));
        const QString blob(300000, QChar(u'x'));
        int calls = 0;
        host.access.setDataHandler([&](Tool, const QJsonObject&) { ++calls; return makeToolSuccessResult({{"blob", blob}}); });
        // 用自己的管道接管子进程 stdout：QProcess 会在事件循环里自动读空它的管道，模拟不了“客户端没来读”。
        int output[2]; QVERIFY(::pipe(output) == 0);
        QVERIFY(::fcntl(output[0], F_SETFL, ::fcntl(output[0], F_GETFL) | O_NONBLOCK) == 0);
        QProcess process;
        process.setChildProcessModifier([writer = output[1], reader = output[0]] {
            ::dup2(writer, STDOUT_FILENO); ::close(writer); ::close(reader);
        });
        process.start(QStringLiteral(MCP_TEST_HELPER), {host.endpoint.paths.rootDirectory});
        QVERIFY(process.waitForStarted(3000));
        ::close(output[1]);
        QByteArray received;
        const auto drain = [&] {
            char buffer[65536];
            ssize_t count = 0;
            while ((count = ::read(output[0], buffer, sizeof buffer)) > 0) received.append(buffer, count);
        };
        process.write(line({{"jsonrpc", "2.0"}, {"id", 1}, {"method", "initialize"},
            {"params", QJsonObject{{"protocolVersion", "2025-11-25"}, {"capabilities", QJsonObject{}},
                                   {"clientInfo", QJsonObject{{"name", "slow-reader"}, {"version", "1"}}}}}}));
        QVERIFY(until([&] { drain(); return received.count('\n') == 1; }));
        process.write(line({{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}}));
        for (int id = 2; id <= 4; ++id)
            process.write(line({{"jsonrpc", "2.0"}, {"id", id}, {"method", "tools/call"},
                {"params", QJsonObject{{"name", toolName(Tool::ListCategories)}, {"arguments", QJsonObject{}}}}}));
        // 这段时间一个字节也不读：三条大结果都压在辅助程序的输出缓冲里。
        QVERIFY(until([&] { return calls == 3 || process.state() != QProcess::Running; }, 10000));
        QTest::qWait(500);
        QCOMPARE(process.state(), QProcess::Running);
        // 积压超过上限后辅助程序暂停读取新请求（背压）：客户端读走之前，后来的请求留在管道里不执行。
        for (int id = 5; id <= 6; ++id)
            process.write(line({{"jsonrpc", "2.0"}, {"id", id}, {"method", "tools/call"},
                {"params", QJsonObject{{"name", toolName(Tool::ListCategories)}, {"arguments", QJsonObject{}}}}}));
        QTest::qWait(500);
        QCOMPARE(calls, 3);
        QVERIFY(until([&] { drain(); return received.count('\n') == 6 || process.state() != QProcess::Running; }, 10000));
        QCOMPARE(calls, 5);
        const QList<QByteArray> lines = received.trimmed().split('\n');
        QCOMPARE(lines.size(), 6);
        for (qsizetype index = 1; index < lines.size(); ++index) {
            const auto reply = QJsonDocument::fromJson(lines.at(index)).object();
            // 握手前排队的请求按提交顺序转发、主应用按收到的顺序执行，结果也按顺序到达。
            QCOMPARE(reply.value("id").toInt(), int(index + 1));
            QVERIFY(!reply.value("result").toObject().value("isError").toBool());
        }
        process.closeWriteChannel();
        drain();
        if (!process.waitForFinished(3000)) process.kill();
        ::close(output[0]);
    }
    void idleBridgeReleasesConnection()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        McpBridgeClient bridge(host.endpoint); bridge.setIdleDisconnectMs(100);
        QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("first", Tool::GetStatus, {});
        QVERIFY(until([&] { return spy.size() == 1; }));
        QCOMPARE(host.access.connectionCount(), 1);
        // 空闲的辅助程序不长期占着有限的连接名额；下一次调用自动重连，模型感觉不到断开过。
        QVERIFY(until([&] { return host.access.connectionCount() == 0; }));
        bridge.call("second", Tool::GetStatus, {});
        QVERIFY(until([&] { return spy.size() == 2; }));
        QCOMPARE(spy.last().at(1).toJsonObject().value("structuredContent").toObject().value("connected"), QJsonValue(true));
        // 有请求在途时不能按空闲断开：处理器慢于空闲期限，结果仍要正常送达，不能变成“结果未知”。
        host.access.setDataHandler([&](Tool, const QJsonObject&) { QTest::qSleep(250); return makeToolSuccessResult({}); });
        bridge.call("slow", Tool::ListCategories, {});
        QVERIFY(until([&] { return spy.size() == 3; }));
        QVERIFY(!spy.last().at(1).toJsonObject().value("isError").toBool());
    }
    void dispatchGateStopsAtMessageBoundary()
    {
        // 背压必须停在消息边界：一次从设备读进来的几 KiB 里可能有上百条请求，
        // 只暂停“下一次读设备”挡不住它们同步产出的响应。没解析的输入要原样留着，之后接着处理。
        MemoryDevice device; McpJsonStream stream(&device, kMaxRequestBytes);
        int seen = 0;
        connect(&stream, &McpJsonStream::received, this, [&](const QJsonObject&) { ++seen; });
        bool open = false;
        stream.setDispatchGate([&] { return open; });
        QByteArray batch;
        for (int i = 0; i < 20; ++i) batch += line({{"jsonrpc", "2.0"}, {"id", i}, {"method", "ping"}});
        device.feed(batch);
        QCOMPARE(seen, 0);
        open = true;
        stream.resumeDispatch();
        QCOMPARE(seen, 20);
        // 解析途中关闸：停在边界，剩下的留到下一次放行，一条不丢也不重复。
        seen = 0;
        stream.setDispatchGate([&] { return seen < 3; });
        device.feed(batch);
        QCOMPARE(seen, 3);
        stream.setDispatchGate([] { return true; });
        stream.resumeDispatch();
        QCOMPARE(seen, 20);
    }
    void helperSurvivesMixedBatchWhileBacklogged()
    {
        // 同一批请求里既有几条大结果，也有上百条同步响应的请求，期间客户端短暂不读 stdout：
        // 辅助程序既不能退出，也不能丢结果——背压只推迟，不丢弃。
        Host host; QVERIFY(host.access.setEnabled(true));
        // 单条结果约 940 KiB：贴近真实工具的响应预算（1 MiB 减去信封余量）。
        const QString blob(470000, QChar(u'x'));
        host.access.setDataHandler([&](Tool, const QJsonObject&) { return makeToolSuccessResult({{"blob", blob}}); });
        int output[2]; QVERIFY(::pipe(output) == 0);
        QVERIFY(::fcntl(output[0], F_SETFL, ::fcntl(output[0], F_GETFL) | O_NONBLOCK) == 0);
        QProcess process;
        process.setChildProcessModifier([writer = output[1], reader = output[0]] {
            ::dup2(writer, STDOUT_FILENO); ::close(writer); ::close(reader);
        });
        process.start(QStringLiteral(MCP_TEST_HELPER), {host.endpoint.paths.rootDirectory});
        QVERIFY(process.waitForStarted(3000));
        ::close(output[1]);
        QByteArray received;
        const auto drain = [&] {
            char buffer[65536];
            ssize_t count = 0;
            while ((count = ::read(output[0], buffer, sizeof buffer)) > 0) received.append(buffer, count);
        };
        process.write(line({{"jsonrpc", "2.0"}, {"id", 1}, {"method", "initialize"},
            {"params", QJsonObject{{"protocolVersion", "2025-11-25"}, {"capabilities", QJsonObject{}},
                                   {"clientInfo", QJsonObject{{"name", "batch-client"}, {"version", "1"}}}}}}));
        QVERIFY(until([&] { drain(); return received.count('\n') == 1; }));
        process.write(line({{"jsonrpc", "2.0"}, {"method", "notifications/initialized"}}));
        constexpr int kBigCalls = 6;
        constexpr int kListCalls = 150;
        // 再追加一批很小的请求：输入总量超过单条请求上限（64 KiB）。闸门关着时它们不会被解析，
        // 未解析的输入必须有上限并暂停读取，否则设备缓冲会越过上限把辅助程序判成传输失败。
        constexpr int kPings = 2000;
        constexpr int kBatch = kBigCalls + kListCalls + kPings;
        QByteArray batch;
        int nextId = 2;
        for (int i = 0; i < kBigCalls; ++i, ++nextId)
            batch += line({{"jsonrpc", "2.0"}, {"id", nextId}, {"method", "tools/call"},
                {"params", QJsonObject{{"name", toolName(Tool::ListCategories)}, {"arguments", QJsonObject{}}}}});
        for (int i = 0; i < kListCalls; ++i, ++nextId)
            batch += line({{"jsonrpc", "2.0"}, {"id", nextId}, {"method", "tools/list"}});
        for (int i = 0; i < kPings; ++i, ++nextId)
            batch += line({{"jsonrpc", "2.0"}, {"id", nextId}, {"method", "ping"}});
        QVERIFY(batch.size() > kMaxRequestBytes);
        process.write(batch);
        // 先攒一段积压：这期间一个字节也不读。
        QTest::qWait(300);
        QCOMPARE(process.state(), QProcess::Running);
        QVERIFY(until([&] { drain(); return received.count('\n') == kBatch + 1
                                            || process.state() != QProcess::Running; }, 30000));
        QCOMPARE(process.state(), QProcess::Running);
        QCOMPARE(received.count('\n'), kBatch + 1);
        int big = 0;
        for (const auto& reply : received.trimmed().split('\n')) {
            QVERIFY(!QJsonDocument::fromJson(reply).object().value("result").toObject().value("isError").toBool());
            if (reply.size() > 500000) ++big;
        }
        QCOMPARE(big, kBigCalls);
        process.closeWriteChannel();
        drain();
        if (!process.waitForFinished(3000)) process.kill();
        ::close(output[0]);
    }
    void staleWritePermissionIsClearedOnLoad()
    {
        // 旧版关闭接入不会撤销写权限，升级后本机可能留着“接入关闭但写授权仍在”的状态；
        // 加载时就要清掉，否则第一次重新打开接入就把写权限悄悄带回来。
        Host host;
        host.settings.setValue(QStringLiteral("mcp/enabled"), false);
        host.settings.setValue(QStringLiteral("mcp/writeEnabled"), true);
        host.settings.sync();
        McpAccessController upgraded(host.endpoint, host.settings, metadata);
        QVERIFY(!upgraded.writeEnabled());
        QVERIFY(upgraded.setEnabled(true));
        QVERIFY(upgraded.enabled());
        QVERIFY(!upgraded.writeEnabled());
        QSettings persisted(host.settings.fileName(), QSettings::IniFormat);
        persisted.sync();
        QCOMPARE(persisted.value("mcp/writeEnabled").toBool(), false);
        QCOMPARE(code(upgraded.dispatch(Tool::CreateTask, createArguments(upgraded.sessionId()))),
                 QStringLiteral("PERMISSION_DENIED"));
    }
    void connectionLimitReportsReason()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        std::vector<std::unique_ptr<RawPeer>> peers;
        for (int i = 0; i < kMaxConnections; ++i) {
            auto peer = std::make_unique<RawPeer>(); QVERIFY(peer->authenticate(host.endpoint)); peers.push_back(std::move(peer));
        }
        // 连接满了要如实说“连接数已满”，不能误报成应用没启动或接入没开。
        McpBridgeClient bridge(host.endpoint); QSignalSpy spy(&bridge, &McpBridgeClient::completed);
        bridge.call("status", Tool::GetStatus, {});
        QVERIFY(until([&] { return spy.size() == 1; }));
        const auto status = spy.takeFirst().at(1).toJsonObject().value("structuredContent").toObject();
        QVERIFY(validateAgainstSchema(status, contract(Tool::GetStatus).outputSchema).ok());
        QCOMPARE(status.value("connected"), QJsonValue(false));
        QCOMPARE(status.value("unavailable_reason"), QJsonValue("connection_limit"));
        bridge.call("read", Tool::ListCategories, {});
        QVERIFY(until([&] { return spy.size() == 1; }));
        const auto error = errorBody(spy.takeFirst().at(1).toJsonObject());
        QCOMPARE(error.value("code"), QJsonValue("APP_UNAVAILABLE"));
        QCOMPARE(error.value("details").toObject().value("reason"), QJsonValue("connection_limit"));
        QVERIFY(!error.value("next_action").toString().contains(QStringLiteral("启动番茄Todo")));
        // 空出一条之后，下一次调用就能连上。
        peers.pop_back();
        QVERIFY(until([&] { return host.access.connectionCount() == kMaxConnections - 1; }));
        bridge.call("again", Tool::GetStatus, {});
        QVERIFY(until([&] { return spy.size() == 1; }));
        QCOMPARE(spy.first().at(1).toJsonObject().value("structuredContent").toObject().value("connected"), QJsonValue(true));
    }
    void connectionLimitRejectsExcessPeer()
    {
        Host host; QVERIFY(host.access.setEnabled(true));
        std::vector<std::unique_ptr<RawPeer>> peers;
        for (int i = 0; i < kMaxConnections; ++i) {
            auto peer = std::make_unique<RawPeer>(); QVERIFY(peer->connectTo(host.endpoint)); peers.push_back(std::move(peer));
        }
        // 满员时等对方发完握手帧再回拒绝原因：连上就立刻写一帧然后关闭的话，对方的握手帧会撞上
        // 已关闭的连接，它只能报成“连不上”。凭据对不对都先报满员，反正这条连接不会被执行。
        // 这里用生产的握手期限：上面那些连接要在检查期间一直挂着，期限由下一个用例单独测。
        RawPeer excess; QVERIFY(excess.connectTo(host.endpoint));
        excess.stream.send({{"kind", "hello"}, {"version", kBridgeProtocolVersion}, {"token", "无所谓"}});
        QVERIFY(until([&] { return !excess.frames.isEmpty(); }));
        QCOMPARE(excess.frames.first().value("accepted"), QJsonValue(false));
        QCOMPARE(excess.frames.first().value("reason"), QJsonValue("connection_limit"));
        QVERIFY(until([&] { return excess.socket.state() == QLocalSocket::UnconnectedState; }));
        // 前面的连接一断开，名额就空出来。
        peers.clear();
        QVERIFY(until([&] { return host.access.connectionCount() == 0; }));
        RawPeer recovered; QVERIFY(recovered.authenticate(host.endpoint));
    }
    void handshakeTimeoutFreesSilentPeers()
    {
        // 一直不发握手帧的连接由握手期限收走，不会长期占着名额；满员后多出来的那条也一样。
        // 期限改短只是为了不必真等 5 秒，收走连接走的是同一条代码路径；生产默认值单独核对。
        Host host;
        QCOMPARE(McpLocalServer(host.endpoint.paths).handshakeTimeoutMs(), kHandshakeTimeoutMs);
        const int timeout = 300;
        host.access.setHandshakeTimeoutMs(timeout);
        QVERIFY(host.access.setEnabled(true));
        std::vector<std::unique_ptr<RawPeer>> silent;
        for (int i = 0; i < kMaxConnections + 1; ++i) {
            auto peer = std::make_unique<RawPeer>(); QVERIFY(peer->connectTo(host.endpoint)); silent.push_back(std::move(peer));
        }
        QVERIFY(until([&] {
            for (const auto& peer : silent) if (peer->socket.state() != QLocalSocket::UnconnectedState) return false;
            return true;
        }, timeout + 3000));
        RawPeer recovered; QVERIFY(recovered.authenticate(host.endpoint));
    }
    void partialFrameTimeout()
    {
        // 收到半帧、迟迟等不到换行时，等满期限就判失败。生产期限就是握手期限；这里改短，不必真等 5 秒。
        MemoryDevice device; McpJsonStream stream(&device, kMaxRequestBytes);
        QCOMPARE(stream.partialTimeout(), kHandshakeTimeoutMs);
        stream.setPartialTimeout(300);
        QSignalSpy failed(&stream, &McpJsonStream::failed);
        device.feed("{");
        QVERIFY(until([&] { return failed.size() == 1; }, 3000));
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
        // 生产期限是 kToolTimeoutMs；改短只是为了不必真等 10 秒，到期取消走的是同一条代码路径。
        QCOMPARE(bridge.toolTimeoutMs(), kToolTimeoutMs);
        bridge.setToolTimeoutMs(300);
        bridge.call("write", Tool::CreateTask, createArguments(host.access.sessionId()));
        QVERIFY(until([&] { return spy.size() == 1 && cancellations == 1; }, 3000));
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
