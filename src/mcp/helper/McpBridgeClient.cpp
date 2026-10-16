#include "McpBridgeClient.h"
#include "../common/McpEndpointFiles.h"
#include "../common/McpJsonStream.h"
#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonDocument>
#include <algorithm>
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
    m_idleTimer.setSingleShot(true);
    connect(&m_idleTimer, &QTimer::timeout, this, &McpBridgeClient::releaseIdleConnection);
}
McpBridgeClient::~McpBridgeClient() { m_failing = true; m_socket.abort(); }
void McpBridgeClient::setIdleDisconnectMs(int milliseconds)
{
    m_idleDisconnectMs = qMax(0, milliseconds);
    updateIdleTimer();
}
void McpBridgeClient::call(const QString& id, Tool tool, const QJsonObject& arguments)
{
    if (m_pending.contains(id) || m_pending.size() >= kMaxQueuedRequestsPerConnection) {
        emit completed(id, makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("连接请求队列已满"))));
        return;
    }
    m_pending.insert(id, {tool, arguments, QDeadlineTimer(m_toolTimeoutMs), false, ++m_nextOrder});
    m_deadlineTimer.start();
    updateIdleTimer();
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
    // 按提交顺序转发：主应用按收到的顺序逐条执行，客户端先发的请求就先执行。
    QStringList ids = m_pending.keys();
    std::sort(ids.begin(), ids.end(), [this](const QString& left, const QString& right) {
        return m_pending.value(left).order < m_pending.value(right).order;
    });
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
            const QJsonValue reason = frame.value("reason");
            // 主应用拒绝时说明原因：连接满了与凭据不对要分开报，否则用户会去查错方向。
            fail(reason == QJsonValue("bridge_version_mismatch") ? UnavailableReason::BridgeVersionMismatch
                 : reason == QJsonValue("connection_limit") ? UnavailableReason::ConnectionLimit
                 : UnavailableReason::AuthenticationFailed);
            return;
        }
        m_connectionTimer.stop();
        m_ready = true;
        sendPending();
        updateIdleTimer();
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
    updateIdleTimer();
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
    if (reason == UnavailableReason::ConnectionLimit) {
        // 请求根本没发出去（握手就被拒），不存在“结果未知”。通用的下一步会让用户去检查
        // 应用是否启动，这里必须改成“腾出连接”。
        QJsonObject error = makeError(ErrorCode::AppUnavailable,
            QStringLiteral("番茄Todo 的外部 AI 连接已满（最多 %1 条同时连接），这次调用没有执行").arg(kMaxConnections),
            QJsonObject{{"reason", unavailableReasonName(reason)}});
        error.insert(QStringLiteral("next_action"),
            QStringLiteral("请用户关闭不再使用的 AI 客户端或会话（每个会话各占一条连接，空闲 %1 秒后自动释放），"
                           "稍后再调用；不要循环重试。").arg(kBridgeIdleDisconnectMs / 1000));
        return makeToolErrorResult(error);
    }
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
    m_idleTimer.stop();
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
    updateIdleTimer();
}
void McpBridgeClient::cancelAll()
{
    const auto ids = m_pending.keys();
    for (const auto& id : ids) cancel(id);
    m_connectionTimer.stop();
    m_idleTimer.stop();
    m_socket.abort();
}
void McpBridgeClient::updateIdleTimer()
{
    if (m_ready && m_pending.isEmpty() && m_idleDisconnectMs > 0) m_idleTimer.start(m_idleDisconnectMs);
    else m_idleTimer.stop();
}
void McpBridgeClient::releaseIdleConnection()
{
    if (!m_ready || !m_pending.isEmpty()) return;
    // 主动断开空闲连接不是故障：没有在途请求，不产生任何结果。
    // abort 会同步发 disconnected，用 m_failing 挡住那条“连接断开”的失败处理。
    m_ready = false;
    m_failing = true;
    m_socket.abort();
    m_failing = false;
}
