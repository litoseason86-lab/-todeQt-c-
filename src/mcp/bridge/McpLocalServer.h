#pragma once
#include "../common/McpPaths.h"
#include "../common/McpContracts.h"
#include <QLocalServer>
#include <functional>

class McpLocalServer : public QObject
{
    Q_OBJECT
public:
    using Handler = std::function<QJsonObject(McpContracts::Tool, const QJsonObject&)>;
    explicit McpLocalServer(const McpPaths::PathSet& paths, QObject* parent = nullptr);
    ~McpLocalServer() override;
    const McpPaths::PathSet& paths() const { return m_paths; }
    bool listen(const QByteArray& credential, Handler handler);
    void close();
    void rejectQueued(const QJsonObject& error);
    int connectionCount() const;
    // 握手期限：连上后多久不发握手帧就断开。只供测试缩短等待，生产沿用 kHandshakeTimeoutMs；
    // 只影响之后新来的连接。
    void setHandshakeTimeoutMs(int milliseconds) { m_handshakeTimeoutMs = qMax(1, milliseconds); }
    int handshakeTimeoutMs() const { return m_handshakeTimeoutMs; }
signals:
    void connectionsChanged();
private:
    class Peer;
    // 连接已满时回一帧带原因的拒绝再断开，不执行任何请求。
    void rejectAtCapacity(QLocalSocket* socket);
    McpPaths::PathSet m_paths;
    QLocalServer m_server;
    QByteArray m_credential;
    Handler m_handler;
    QList<Peer*> m_peers;
    // 正在等待握手、只为回一句“连接已满”的连接数；不占用 m_peers 的名额。
    int m_rejecting = 0;
    int m_handshakeTimeoutMs = McpContracts::kHandshakeTimeoutMs;
};
