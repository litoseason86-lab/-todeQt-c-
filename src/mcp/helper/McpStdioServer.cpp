#include "McpStdioServer.h"
#include "McpBridgeClient.h"
#include "../common/McpContracts.h"
#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <cmath>

using namespace McpContracts;
McpStdioServer::McpStdioServer(QIODevice* device, McpBridgeClient* bridge, QObject* parent)
    : QObject(parent), m_stream(device, kMaxRequestBytes), m_bridge(bridge)
{
    m_initializationTimer.setSingleShot(true);
    m_initializationTimer.start(kHandshakeTimeoutMs);
    connect(&m_initializationTimer, &QTimer::timeout, this, &McpStdioServer::stop);
    connect(&m_stream, &McpJsonStream::received, this, &McpStdioServer::receive);
    connect(&m_stream, &McpJsonStream::malformed, this, [this](int code) {
        error(QJsonValue(QJsonValue::Null), code, QStringLiteral("消息不是有效的 JSON-RPC 对象"));
    });
    connect(&m_stream, &McpJsonStream::failed, this, &McpStdioServer::stop);
    connect(bridge, &McpBridgeClient::completed, this, [this](const QString& key, const QJsonObject& result) {
        auto it = m_inflight.find(key);
        if (it == m_inflight.end() || m_stopped) return;
        const QJsonValue id = it.value();
        m_inflight.erase(it);
        respond(id, result);
    });
}
QString McpStdioServer::idKey(const QJsonValue& id)
{
    if (id.isString()) return QStringLiteral("s:") + id.toString();
    if (id.isDouble() && std::isfinite(id.toDouble()) && std::floor(id.toDouble()) == id.toDouble()
        && std::abs(id.toDouble()) <= 9007199254740991.0)
        return QStringLiteral("n:") + QString::number(id.toDouble(), 'f', 0);
    return {};
}
void McpStdioServer::respond(const QJsonValue& id, const QJsonObject& result)
{
    m_stream.send({{"jsonrpc", "2.0"}, {"id", id}, {"result", result}});
}
void McpStdioServer::error(const QJsonValue& id, int code, const QString& message)
{
    m_stream.send({{"jsonrpc", "2.0"}, {"id", id}, {"error", QJsonObject{{"code", code}, {"message", message}}}});
}
void McpStdioServer::receive(const QJsonObject& message)
{
    if (m_stopped) return;
    const bool notification = !message.contains("id");
    const QJsonValue id = message.value("id");
    const QString method = message.value("method").toString();
    if (message.value("jsonrpc") != QJsonValue("2.0") || !message.value("method").isString()
        || (!notification && idKey(id).isEmpty()) || message.contains("result") || message.contains("error")) {
        error(QJsonValue(QJsonValue::Null), JsonRpcError::InvalidRequest, QStringLiteral("无效的请求结构或请求编号"));
        return;
    }
    const QJsonValue paramsValue = message.value("params");
    const QJsonObject params = paramsValue.toObject();
    if (notification) {
        // 通知绝不回复。只有完成初始化后才接收取消等业务通知。
        if (method == QStringLiteral("notifications/initialized") && m_initialized && (paramsValue.isUndefined() || paramsValue.isObject())) {
            m_ready = true;
            m_initializationTimer.stop();
        }
        else if (method == QStringLiteral("notifications/cancelled") && m_ready) {
            const QString key = idKey(params.value("requestId"));
            const auto correlations = m_inflight.keys();
            for (const auto& correlation : correlations) {
                if (!key.isEmpty() && idKey(m_inflight.value(correlation)) == key) {
                    m_inflight.remove(correlation);
                    m_bridge->cancel(correlation);
                    // 取消后不再回复原请求，也不声称已经回滚。
                }
            }
        }
        return;
    }
    for (const auto& active : m_inflight) {
        if (idKey(active) == idKey(id)) {
            error(QJsonValue(QJsonValue::Null), JsonRpcError::InvalidRequest, QStringLiteral("重复的在途请求编号"));
            stop();
            return;
        }
    }
    if (!paramsValue.isUndefined() && !paramsValue.isObject()) {
        error(id, JsonRpcError::InvalidParams, QStringLiteral("params 必须是对象"));
        return;
    }
    if (method == QStringLiteral("ping")) { respond(id, {}); return; }
    if (method == QStringLiteral("initialize")) {
        if (m_initialized) { error(id, JsonRpcError::InvalidRequest, QStringLiteral("不能重复初始化")); return; }
        const QJsonObject info = params.value("clientInfo").toObject();
        if (!params.value("protocolVersion").isString() || !params.value("capabilities").isObject()
            || !info.value("name").isString() || !info.value("version").isString()) {
            error(id, JsonRpcError::InvalidParams, QStringLiteral("初始化参数不完整"));
            return;
        }
        m_initialized = true;
        respond(id, {{"protocolVersion", negotiateProtocolVersion(params.value("protocolVersion").toString())},
                     {"capabilities", QJsonObject{{"tools", QJsonObject{}}}},
                     {"serverInfo", QJsonObject{{"name", "pomodoro-todo"}, {"version", QCoreApplication::applicationVersion()}}}});
        return;
    }
    if (!m_ready) { error(id, JsonRpcError::InvalidRequest, QStringLiteral("请先完成初始化")); return; }
    if (method == QStringLiteral("tools/list")) {
        if (params.contains("cursor")) { error(id, JsonRpcError::InvalidParams, QStringLiteral("固定清单不使用游标")); return; }
        respond(id, {{"tools", toolListJson()}});
        return;
    }
    if (method == QStringLiteral("tools/call")) {
        const ToolContract* definition = findTool(params.value("name").toString());
        if (!definition) { error(id, JsonRpcError::InvalidParams, QStringLiteral("未知工具名称")); return; }
        const QJsonValue arguments = params.value("arguments");
        if (!arguments.isUndefined() && !arguments.isObject()) {
            respond(id, makeToolErrorResult(makeError(ErrorCode::ValidationError, QStringLiteral("arguments 必须是对象"))));
            return;
        }
        const auto validation = validateToolArguments(definition->tool, arguments.toObject());
        if (!validation.ok()) { respond(id, makeToolErrorResult(makeValidationError(validation))); return; }
        if (m_inflight.size() >= kMaxQueuedRequestsPerConnection) {
            respond(id, makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("在途请求数量达到上限"))));
            return;
        }
        const QString correlation = QString::number(++m_sequence);
        m_inflight.insert(correlation, id);
        m_bridge->call(correlation, definition->tool, applySchemaDefaults(definition->tool, arguments.toObject()));
        return;
    }
    error(id, JsonRpcError::MethodNotFound, QStringLiteral("不支持此方法"));
}
void McpStdioServer::stop()
{
    if (m_stopped) return;
    m_stopped = true;
    m_initializationTimer.stop();
    m_inflight.clear();
    m_bridge->cancelAll();
    emit finished();
}
void McpStdioServer::endInput()
{
    m_stream.finishInput();
    stop();
}
