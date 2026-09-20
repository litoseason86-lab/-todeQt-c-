#pragma once
#include "../common/McpJsonStream.h"
#include <QHash>

class McpBridgeClient;
class QIODevice;

// 固定工具发现不依赖主应用。外部 JSON-RPC 编号和内部转发编号分开，避免类型及重用冲突。
class McpStdioServer : public QObject
{
    Q_OBJECT
public:
    McpStdioServer(QIODevice* device, McpBridgeClient* bridge, QObject* parent = nullptr);
    void endInput();
signals:
    void finished();
private:
    void receive(const QJsonObject& message);
    void respond(const QJsonValue& id, const QJsonObject& result);
    void error(const QJsonValue& id, int code, const QString& message);
    void stop();
    static QString idKey(const QJsonValue& id);
    McpJsonStream m_stream;
    McpBridgeClient* m_bridge;
    QHash<QString, QJsonValue> m_inflight;
    bool m_initialized = false;
    bool m_ready = false;
    bool m_stopped = false;
    quint64 m_sequence = 0;
};
