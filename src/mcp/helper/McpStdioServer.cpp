#include "McpStdioServer.h"
#include "McpBridgeClient.h"
#include "../common/McpContracts.h"
#include <QCoreApplication>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <cmath>

using namespace McpContracts;
McpStdioServer::McpStdioServer(QIODevice* device, McpBridgeClient* bridge, QObject* parent)
    : QObject(parent), m_stream(device, kMaxRequestBytes), m_bridge(bridge)
{
    // stdio 的另一端就是拉起本进程的 AI 客户端，进程的生命周期由它决定（关闭 stdin 即退出）。
    // 这里不设握手期限、也不设半行期限：客户端晚一点才初始化、一行分几次写完，
    // 都不能让辅助程序自己静默退出——那样客户端只会看到“服务器断开”，查不到任何原因。
    m_stream.setPartialTimeout(0);
    // 单条请求超长只拒绝这一条并丢弃到行尾，其他在途请求照常完成。
    m_stream.setOversizedLineRecovery(true);
    // 背压：stdout 积压过多时停在消息边界，不再解析下一条请求（已读进来的留在流里）。
    // 同一批请求里可能有上百条 tools/list，每条都同步产出近 30 KiB 响应，
    // 只暂停“下一次读 stdin”挡不住它们。客户端读走一些之后由 bytesWritten 续上。
    m_stream.setDispatchGate([device] { return device->bytesToWrite() <= kOutputPauseBytes; });
    connect(device, &QIODevice::bytesWritten, this, [this] { m_stream.resumeDispatch(); });
    connect(&m_stream, &McpJsonStream::received, this, &McpStdioServer::receive);
    connect(&m_stream, &McpJsonStream::malformed, this, [this](int code) {
        error(QJsonValue(QJsonValue::Null), code, QStringLiteral("消息不是有效的 JSON-RPC 对象"));
    });
    connect(&m_stream, &McpJsonStream::oversized, this, [this] {
        // 超长的这一行没解析，取不到它的编号，只能按 JSON-RPC 约定以 null 编号报错。
        error(QJsonValue(QJsonValue::Null), JsonRpcError::InvalidRequest,
              QStringLiteral("单条请求超过 64 KiB 上限，已丢弃这条请求"));
    });
    connect(&m_stream, &McpJsonStream::failed, this, [this] {
        // 日志只写 stderr：stdout 只能出现协议消息。
        qWarning().noquote() << QStringLiteral("番茄Todo MCP 辅助程序：响应无法写出（客户端长期未读取标准输出，"
                                               "或单条响应超过上限），退出");
        stop();
    });
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
            // 只拒绝后来的这一条，原请求照常完成；以前直接退出，会把其他在途结果（包括写入）一起丢掉。
            // 响应编号填 null：填原编号的话，客户端会把这条错误当成原请求的结果。
            error(QJsonValue(QJsonValue::Null), JsonRpcError::InvalidRequest, QStringLiteral("重复的在途请求编号"));
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
                     {"serverInfo", QJsonObject{{"name", "pomodoro-todo"}, {"version", QCoreApplication::applicationVersion()}}},
                     {"instructions", serverInstructions()}});
        return;
    }
    if (!m_ready) { error(id, JsonRpcError::InvalidRequest, QStringLiteral("请先完成初始化")); return; }
    if (method == QStringLiteral("tools/list")) {
        // 清单只有一页，从不下发游标。null 等同没给；真带了游标说明客户端拿错了，按协议报参数错误。
        const QJsonValue cursor = params.value("cursor");
        if (!cursor.isUndefined() && !cursor.isNull()) {
            error(id, JsonRpcError::InvalidParams, QStringLiteral("无效的游标：工具清单只有一页"));
            return;
        }
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
    m_inflight.clear();
    m_bridge->cancelAll();
    emit finished();
}
void McpStdioServer::endInput()
{
    m_stream.finishInput();
    stop();
}
