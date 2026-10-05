#pragma once
#include "../common/McpPaths.h"
#include "../common/McpContracts.h"
#include <QDeadlineTimer>
#include <QHash>
#include <QLocalSocket>
#include <QTimer>
#include <memory>

class McpJsonStream;

// 按需建立连接；只重连后续调用，不重放断线前已发出的请求。
class McpBridgeClient : public QObject
{
    Q_OBJECT
public:
    explicit McpBridgeClient(const McpPaths::Resolution& endpoint, QObject* parent = nullptr);
    ~McpBridgeClient() override;
    const McpPaths::Resolution& endpoint() const { return m_endpoint; }
    void call(const QString& id, McpContracts::Tool tool, const QJsonObject& arguments);
    void cancel(const QString& id);
    void cancelAll();
    // 空闲多久释放连接；只供测试缩短等待，生产沿用 kBridgeIdleDisconnectMs。
    void setIdleDisconnectMs(int milliseconds);
    // 一次工具调用最多等多久；只供测试缩短等待，生产沿用 kToolTimeoutMs。只影响之后发起的调用。
    void setToolTimeoutMs(int milliseconds) { m_toolTimeoutMs = qMax(1, milliseconds); }
    int toolTimeoutMs() const { return m_toolTimeoutMs; }
signals:
    void completed(const QString& id, const QJsonObject& result);
private:
    struct Pending {
        McpContracts::Tool tool;
        QJsonObject arguments;
        QDeadlineTimer deadline;
        bool sent = false;
        // 提交顺序。握手完成前排队的请求要按先来后到转发，不能按哈希表的遍历顺序。
        quint64 order = 0;
    };
    void connectEndpoint();
    void sendPending();
    void receive(const QJsonObject& frame);
    void fail(McpContracts::UnavailableReason reason);
    // 没有在途请求时开始计空闲，有请求就停表；空闲到点主动断开，把连接名额让给别的会话。
    void updateIdleTimer();
    void releaseIdleConnection();
    QJsonObject unavailable(McpContracts::Tool tool, McpContracts::UnavailableReason reason, bool sent) const;
    QJsonObject status(const QJsonValue& app, McpContracts::UnavailableReason reason) const;
    McpPaths::Resolution m_endpoint;
    QLocalSocket m_socket;
    std::unique_ptr<McpJsonStream> m_stream;
    QHash<QString, Pending> m_pending;
    QTimer m_connectionTimer, m_deadlineTimer, m_idleTimer;
    QByteArray m_credential;
    int m_idleDisconnectMs = McpContracts::kBridgeIdleDisconnectMs;
    int m_toolTimeoutMs = McpContracts::kToolTimeoutMs;
    quint64 m_nextOrder = 0;
    bool m_ready = false;
    bool m_failing = false;
};
