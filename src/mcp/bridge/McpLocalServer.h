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
signals:
    void connectionsChanged();
private:
    class Peer;
    McpPaths::PathSet m_paths;
    QLocalServer m_server;
    QByteArray m_credential;
    Handler m_handler;
    QList<Peer*> m_peers;
};
