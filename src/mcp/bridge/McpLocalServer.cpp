#include "McpLocalServer.h"
#include "../common/McpJsonStream.h"
#include "../common/McpEndpointFiles.h"
#include "../../platform/macos/MacLocalPeerIdentity.h"
#include <QDeadlineTimer>
#include <QLocalSocket>
#include <QTimer>
#include <QFile>
#include <sys/stat.h>
#include <utility>

using namespace McpContracts;

class McpLocalServer::Peer : public QObject
{
public:
    struct Request { QString id; Tool tool; QJsonObject arguments; QDeadlineTimer deadline; };
    Peer(QLocalSocket* connection, McpLocalServer* server)
        : QObject(server), socket(connection), owner(server), stream(connection, kMaxRequestBytes, this)
    {
        socket->setParent(this);
        socket->setReadBufferSize(kMaxRequestBytes + 1);
        timer.setSingleShot(true);
        timer.start(kHandshakeTimeoutMs);
        connect(&timer, &QTimer::timeout, this, [this] { socket->abort(); });
        connect(&stream, &McpJsonStream::failed, this, [this] { socket->abort(); });
        connect(&stream, &McpJsonStream::malformed, this, [this] { socket->abort(); });
        connect(socket, &QLocalSocket::disconnected, this, [this] {
            owner->m_peers.removeOne(this);
            emit owner->connectionsChanged();
            queue.clear();
            deleteLater();
        });
        connect(&stream, &McpJsonStream::received, this, [this](const QJsonObject& frame) { receive(frame); });
    }
    void reject(const QJsonObject& error)
    {
        const auto pending = std::exchange(queue, {});
        for (const auto& request : pending) {
            if (request.tool == Tool::GetStatus) queue.append(request);
            else send(request.id, makeToolErrorResult(error));
        }
    }
    void send(const QString& id, const QJsonObject& result)
    {
        stream.send({{"kind", "result"}, {"id", id}, {"result", result}});
    }
    void receive(const QJsonObject& frame)
    {
        const QString kind = frame.value("kind").toString();
        if (!authenticated) {
            if (kind != QStringLiteral("hello")) { socket->abort(); return; }
            QString reason;
            if (frame.value("version") != QJsonValue(kBridgeProtocolVersion)) reason = QStringLiteral("bridge_version_mismatch");
            else if (frame.value("token").toString().toLatin1() != owner->m_credential) reason = QStringLiteral("authentication_failed");
            stream.send({{"kind", "hello"}, {"version", kBridgeProtocolVersion}, {"accepted", reason.isEmpty()}, {"reason", reason}});
            if (!reason.isEmpty()) { socket->disconnectFromServer(); return; }
            authenticated = true;
            timer.stop();
            return;
        }
        const QString id = frame.value("id").toString();
        if (id.isEmpty() || id.size() > 128) { socket->abort(); return; }
        if (kind == QStringLiteral("cancel")) {
            for (qsizetype i = queue.size(); i > 0; --i)
                if (queue[i - 1].id == id) queue.removeAt(i - 1);
            return;
        }
        if (kind != QStringLiteral("call") || !frame.value("arguments").isObject()) { socket->abort(); return; }
        for (const auto& pending : queue) {
            if (pending.id == id) { socket->abort(); return; }
        }
        if (queue.size() >= kMaxQueuedRequestsPerConnection) { socket->abort(); return; }
        const ToolContract* definition = findTool(frame.value("tool").toString());
        if (!definition) { socket->abort(); return; }
        const QJsonValue remaining = frame.value("remaining_ms");
        const int milliseconds = remaining.toInt(-1);
        if (!remaining.isDouble() || remaining.toDouble() != milliseconds
            || milliseconds < 1 || milliseconds > kToolTimeoutMs) { socket->abort(); return; }
        queue.append({id, definition->tool, frame.value("arguments").toObject(), QDeadlineTimer(milliseconds)});
        // 不在读帧回调里执行：同批取消先入队，再在主线程依次检查权限、期限并调用业务层。
        if (!scheduled) {
            scheduled = true;
            QTimer::singleShot(0, this, [this] { execute(); });
        }
    }
    void execute()
    {
        scheduled = false;
        if (queue.isEmpty() || socket->state() != QLocalSocket::ConnectedState) return;
        const Request request = queue.takeFirst();
        QJsonObject result;
        if (request.deadline.hasExpired()) {
            result = makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("请求在执行前已过期")));
        } else {
            const auto validation = validateToolArguments(request.tool, request.arguments);
            result = validation.ok() ? owner->m_handler(request.tool, applySchemaDefaults(request.tool, request.arguments))
                                     : makeToolErrorResult(makeValidationError(validation));
        }
        if (socket->state() != QLocalSocket::ConnectedState) return;
        send(request.id, result);
        if (!queue.isEmpty()) {
            scheduled = true;
            QTimer::singleShot(0, this, [this] { execute(); });
        }
    }
    QLocalSocket* socket;
    McpLocalServer* owner;
    McpJsonStream stream;
    QTimer timer;
    QList<Request> queue;
    bool authenticated = false;
    bool scheduled = false;
};

McpLocalServer::McpLocalServer(const McpPaths::PathSet& paths, QObject* parent)
    : QObject(parent), m_paths(paths)
{
    // UserAccessOption 会让 Qt 先在更长的临时目录绑定，103 字节合法路径也可能失败。
    // 控制器已经验证 0700 私有目录；直接绑定后再收紧 socket 权限，不扩大任何用户的访问范围。
    m_server.setSocketOptions(QLocalServer::NoOptions);
    m_server.setMaxPendingConnections(kMaxConnections);
    connect(&m_server, &QLocalServer::newConnection, this, [this] {
        while (m_server.hasPendingConnections()) {
            QLocalSocket* socket = m_server.nextPendingConnection();
            if (m_peers.size() >= kMaxConnections || !MacLocalPeerIdentity::isCurrentUser(socket->socketDescriptor())) {
                socket->abort();
                socket->deleteLater();
                continue;
            }
            m_peers.append(new Peer(socket, this));
            emit connectionsChanged();
        }
    });
}
McpLocalServer::~McpLocalServer() { close(); }
bool McpLocalServer::listen(const QByteArray& credential, Handler handler)
{
    const auto checked = McpPaths::resolveForRoot(m_paths.rootDirectory);
    if (!checked.ok() || checked.paths.socketPath != m_paths.socketPath || !handler
        || !McpEndpointFiles::validateRoot(m_paths)) return false;
    m_credential = credential;
    m_handler = std::move(handler);
    if (!m_server.listen(m_paths.socketPath)) return false;
    if (::chmod(QFile::encodeName(m_paths.socketPath).constData(), 0600) != 0) {
        m_server.close();
        return false;
    }
    return true;
}
void McpLocalServer::close()
{
    m_server.close();
    const auto peers = std::exchange(m_peers, {});
    for (Peer* peer : peers) {
        peer->queue.clear();
        peer->socket->abort();
        peer->deleteLater();
    }
    m_credential.clear();
}
void McpLocalServer::rejectQueued(const QJsonObject& error)
{
    const auto peers = m_peers;
    for (Peer* peer : peers) peer->reject(error);
}
int McpLocalServer::connectionCount() const { return int(m_peers.size()); }
