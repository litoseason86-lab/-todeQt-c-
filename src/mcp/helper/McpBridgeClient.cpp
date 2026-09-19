#include "McpBridgeClient.h"
#include "../common/McpEndpointFiles.h"
#include "../common/McpJsonStream.h"
#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonDocument>
#include <utility>

using namespace McpContracts;

McpBridgeClient::McpBridgeClient(const McpPaths::Resolution& endpoint, QObject* parent)
    : QObject(parent), m_endpoint(endpoint)
{
    m_socket.setReadBufferSize(kMaxResponseBytes + 1);
    m_connectionTimer.setSingleShot(true);
    connect(&m_connectionTimer, &QTimer::timeout, this, [this] {
        fail(m_socket.state() == QLocalSocket::ConnectedState ? UnavailableReason::HandshakeFailed : UnavailableReason::EndpointUnreachable);
    });
    connect(&m_socket, &QLocalSocket::connected, this, [this] {
        m_connectionTimer.start(kHandshakeTimeoutMs);
        m_stream->send({{"kind", "hello"}, {"version", kBridgeProtocolVersion}, {"token", QString::fromLatin1(m_credential)}});
        m_credential.clear();
    });
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] { fail(UnavailableReason::EndpointUnreachable); });
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this] { fail(UnavailableReason::EndpointUnreachable); });
    m_deadlineTimer.setInterval(50);
    connect(&m_deadlineTimer, &QTimer::timeout, this, [this] {
        const auto ids = m_pending.keys();
        for (const auto& id : ids) {
            if (!m_pending.contains(id) || !m_pending.value(id).deadline.hasExpired()) continue;
            const Pending pending = m_pending.value(id);
            cancel(id);
            emit completed(id, unavailable(pending.tool, UnavailableReason::EndpointUnreachable, pending.sent));
        }
    });
}
McpBridgeClient::~McpBridgeClient() { m_failing = true; m_socket.abort(); }
void McpBridgeClient::call(const QString& id, Tool tool, const QJsonObject& arguments)
{
    if (m_pending.contains(id) || m_pending.size() >= kMaxQueuedRequestsPerConnection) {
        emit completed(id, makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("连接请求队列已满"))));
        return;
    }
    m_pending.insert(id, {tool, arguments, QDeadlineTimer(kToolTimeoutMs), false});
    m_deadlineTimer.start();
    if (m_ready) sendPending();
    else if (m_socket.state() == QLocalSocket::UnconnectedState) connectEndpoint();
}
void McpBridgeClient::connectEndpoint()
{
    const auto checked = McpPaths::resolveForRoot(m_endpoint.paths.rootDirectory);
    if (!m_endpoint.ok() || !checked.ok() || checked.paths.socketPath != m_endpoint.paths.socketPath) {
        fail(UnavailableReason::PathInvalid);
        return;
    }
    int version = 0;
    if (!McpEndpointFiles::read(m_endpoint.paths, &m_credential, &version)) {
        fail(QFileInfo::exists(m_endpoint.paths.discoveryPath) ? UnavailableReason::AuthenticationFailed : UnavailableReason::EndpointUnreachable);
        return;
    }
    if (version != kBridgeProtocolVersion) { fail(UnavailableReason::BridgeVersionMismatch); return; }
    m_stream = std::make_unique<McpJsonStream>(&m_socket, kMaxResponseBytes);
    connect(m_stream.get(), &McpJsonStream::received, this, &McpBridgeClient::receive);
    connect(m_stream.get(), &McpJsonStream::failed, this, [this] { fail(UnavailableReason::HandshakeFailed); });
    connect(m_stream.get(), &McpJsonStream::malformed, this, [this] { fail(UnavailableReason::HandshakeFailed); });
    m_connectionTimer.start(kConnectTimeoutMs);
    m_socket.connectToServer(m_endpoint.paths.socketPath);
}
void McpBridgeClient::sendPending()
{
    const auto ids = m_pending.keys();
    for (const QString& id : ids) {
        auto it = m_pending.find(id);
        if (it == m_pending.end() || it->sent || it->deadline.hasExpired() || !m_ready) continue;
        const QJsonObject message {{"kind", "call"}, {"id", id}, {"tool", toolName(it->tool)},
                                  {"arguments", it->arguments}, {"remaining_ms", int(it->deadline.remainingTime())}};
        // 在写入 socket 前标记为已发送：底层失败可能同步回调，不能把不确定的写入当成未执行。
        it->sent = true;
        m_stream->send(message);
    }
}
void McpBridgeClient::receive(const QJsonObject& frame)
{
    if (!m_ready) {
        if (frame.value("kind") != QJsonValue("hello")) { fail(UnavailableReason::HandshakeFailed); return; }
        if (frame.value("version") != QJsonValue(kBridgeProtocolVersion)) { fail(UnavailableReason::BridgeVersionMismatch); return; }
        if (frame.value("accepted") != QJsonValue(true)) {
            fail(frame.value("reason") == QJsonValue("bridge_version_mismatch")
                 ? UnavailableReason::BridgeVersionMismatch : UnavailableReason::AuthenticationFailed);
            return;
        }
        m_connectionTimer.stop();
        m_ready = true;
        sendPending();
        return;
    }
    if (frame.value("kind") != QJsonValue("result") || !frame.value("result").isObject()) {
        fail(UnavailableReason::HandshakeFailed);
        return;
    }
    const QString id = frame.value("id").toString();
    if (!m_pending.contains(id)) return; // 已取消或超时的迟到应答不再交给模型。
    const Pending pending = m_pending.value(id);
    if (pending.deadline.hasExpired()) {
        cancel(id);
        emit completed(id, unavailable(pending.tool, UnavailableReason::EndpointUnreachable, pending.sent));
        return;
    }
    QJsonObject result = frame.value("result").toObject();
    if (pending.tool == Tool::GetStatus && !result.value("isError").toBool()) {
        if (!result.value("structuredContent").isObject()) { fail(UnavailableReason::HandshakeFailed); return; }
        result = makeToolSuccessResult(status(result.value("structuredContent"), UnavailableReason::EndpointUnreachable));
    }
    m_pending.remove(id);
    if (m_pending.isEmpty()) m_deadlineTimer.stop();
    emit completed(id, result);
}
QJsonObject McpBridgeClient::status(const QJsonValue& app, UnavailableReason reason) const
{
    const bool connected = app.isObject();
    return {{"connected", connected}, {"helper_version", QCoreApplication::applicationVersion()},
            {"bridge_protocol_version", kBridgeProtocolVersion},
            {"unavailable_reason", connected ? QJsonValue(QJsonValue::Null) : QJsonValue(unavailableReasonName(reason))},
            {"path_error", !connected && reason == UnavailableReason::PathInvalid
                               ? QJsonValue(McpPaths::pathErrorDetails(m_endpoint)) : QJsonValue(QJsonValue::Null)},
            {"app", app}};
}
QJsonObject McpBridgeClient::unavailable(Tool tool, UnavailableReason reason, bool sent) const
{
    if (tool == Tool::GetStatus) return makeToolSuccessResult(status(QJsonValue(QJsonValue::Null), reason));
    if (sent && contract(tool).access == ToolAccess::Write)
        return makeToolErrorResult(makeError(ErrorCode::OutcomeUnknown, QStringLiteral("写请求发出后未取得应答，无法确定是否已执行")));
    const QString message = reason == UnavailableReason::BridgeVersionMismatch
        ? QStringLiteral("主应用与辅助程序版本不兼容，请退出并重新打开主应用和 AI 客户端")
        : QStringLiteral("无法连接已授权的主应用");
    const QJsonObject details = reason == UnavailableReason::PathInvalid
        ? McpPaths::pathErrorDetails(m_endpoint) : QJsonObject{{"reason", unavailableReasonName(reason)}};
    return makeToolErrorResult(makeError(reason == UnavailableReason::PathInvalid ? ErrorCode::IpcPathInvalid : ErrorCode::AppUnavailable,
                                        message, details));
}
void McpBridgeClient::fail(UnavailableReason reason)
{
    if (m_failing) return;
    m_failing = true;
    m_ready = false;
    m_connectionTimer.stop();
    m_deadlineTimer.stop();
    m_socket.abort();
    m_credential.clear();
    const auto pending = std::exchange(m_pending, {});
    m_failing = false;
    for (auto it = pending.cbegin(); it != pending.cend(); ++it)
        emit completed(it.key(), unavailable(it->tool, reason, it->sent));
}
void McpBridgeClient::cancel(const QString& id)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end()) return;
    const bool sent = it->sent;
    m_pending.erase(it);
    if (sent && m_ready) m_stream->send({{"kind", "cancel"}, {"id", id}});
    if (m_pending.isEmpty()) m_deadlineTimer.stop();
}
void McpBridgeClient::cancelAll()
{
    const auto ids = m_pending.keys();
    for (const auto& id : ids) cancel(id);
    m_connectionTimer.stop();
    m_socket.abort();
}
