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
    // 默认期限长于官方辅助程序，仅兜底非官方客户端；测试缩短期限，执行中和背压期间不计算空闲。
    void setIdleTimeoutMs(int milliseconds) { m_idleTimeoutMs = qMax(1, milliseconds); }
    int idleTimeoutMs() const { return m_idleTimeoutMs; }
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
    int m_idleTimeoutMs = McpContracts::kServerIdleDisconnectMs;
};
