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
    // atCapacity 为真时这条连接只用来回一句“连接已满”：不占用连接名额，也不执行任何请求。
    Peer(QLocalSocket* connection, McpLocalServer* server, bool capacity = false)
        : QObject(server), socket(connection), owner(server), stream(connection, kMaxRequestBytes, this),
          atCapacity(capacity)
    {
        socket->setParent(this);
        socket->setReadBufferSize(kMaxRequestBytes + 1);
        timer.setSingleShot(true);
        timer.start(server->m_handshakeTimeoutMs);
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
        // 上一条结果写空后再执行下一条排队请求（背压），见 schedule()。
        connect(socket, &QLocalSocket::bytesWritten, this, [this] { schedule(); });
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
            // 等对方先发握手帧再回拒绝原因：连上就立刻写一帧然后关闭的话，对方的握手帧会撞上
            // 已关闭的连接（EPIPE），它只能报成“连不上”，看不到真正的原因。
            if (atCapacity) reason = QStringLiteral("connection_limit");
            else if (frame.value("version") != QJsonValue(kBridgeProtocolVersion)) reason = QStringLiteral("bridge_version_mismatch");
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
        schedule();
    }
    void schedule()
    {
        // 背压：上一条结果还没写进内核就先不执行下一条。否则并行的两条大结果会叠在发送缓冲里，
        // 以前这会越过上限把整条连接断开，连已经写库的请求也变成“结果未知”。
        // 等待期间请求的截止时间照常计算，执行前仍会检查是否已过期。
        if (scheduled || queue.isEmpty() || socket->bytesToWrite() > 0) return;
        scheduled = true;
        QTimer::singleShot(0, this, [this] { execute(); });
    }
    void execute()
    {
        scheduled = false;
        if (queue.isEmpty() || socket->state() != QLocalSocket::ConnectedState) return;
        // 排队期间可能有 reject() 等其它输出写进缓冲，这里再确认一次缓冲已空。
        if (socket->bytesToWrite() > 0) return;
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
        schedule();
    }
    QLocalSocket* socket;
    McpLocalServer* owner;
    McpJsonStream stream;
    QTimer timer;
    QList<Request> queue;
    bool authenticated = false;
    bool scheduled = false;
    bool atCapacity = false;
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
            if (!MacLocalPeerIdentity::isCurrentUser(socket->socketDescriptor())) {
                socket->abort();
                socket->deleteLater();
                continue;
            }
            if (m_peers.size() >= kMaxConnections) {
                rejectAtCapacity(socket);
                continue;
            }
            m_peers.append(new Peer(socket, this));
            emit connectionsChanged();
        }
    });
}
void McpLocalServer::rejectAtCapacity(QLocalSocket* socket)
{
    // 满员时也要说清原因：辅助程序据此报“连接已满”，而不是误报成应用没启动或接入没开。
    // 这条连接不进 m_peers（不占名额、不执行请求），收到对方的握手帧后回一句拒绝就断开；
    // 迟迟不发握手的由 Peer 自己的握手期限断开。
    // 同时在等回复的拒绝连接也有上限，免得满员时被大量连接反复占用资源。
    if (m_rejecting >= kMaxConnections) {
        socket->abort();
        socket->deleteLater();
        return;
    }
    ++m_rejecting;
    auto* peer = new Peer(socket, this, true);
    connect(peer, &QObject::destroyed, this, [this] { --m_rejecting; });
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
