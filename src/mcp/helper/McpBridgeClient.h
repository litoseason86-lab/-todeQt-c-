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
signals:
    void completed(const QString& id, const QJsonObject& result);
private:
    struct Pending {
        McpContracts::Tool tool;
        QJsonObject arguments;
        QDeadlineTimer deadline;
        bool sent = false;
    };
    void connectEndpoint();
    void sendPending();
    void receive(const QJsonObject& frame);
    void fail(McpContracts::UnavailableReason reason);
    QJsonObject unavailable(McpContracts::Tool tool, McpContracts::UnavailableReason reason, bool sent) const;
    QJsonObject status(const QJsonValue& app, McpContracts::UnavailableReason reason) const;
    McpPaths::Resolution m_endpoint;
    QLocalSocket m_socket;
    std::unique_ptr<McpJsonStream> m_stream;
    QHash<QString, Pending> m_pending;
    QTimer m_connectionTimer, m_deadlineTimer;
    QByteArray m_credential;
    bool m_ready = false;
    bool m_failing = false;
};
