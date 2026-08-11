#include "SingleInstanceGuard.h"

#include <QIODevice>
#include <QDebug>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QVariant>

namespace {
// 单实例激活协议只有一行短命令；留足余量即可，超出一律丢弃。
constexpr int kMaxMessageBytes = 4096;
const QByteArray kActivateCommand = QByteArrayLiteral("activate\n");
constexpr int kIpcTimeoutMs = 500;
}

SingleInstanceGuard::SingleInstanceGuard(const QString& lockPath,
                                         const QString& serverName,
                                         QObject* parent)
    : QObject(parent)
    , m_serverName(serverName)
    , m_lock(std::make_unique<QLockFile>(lockPath))
    , m_server(std::make_unique<QLocalServer>())
{
    // 只要锁文件中的进程仍存活，就不能按运行时长把锁误判为过期。
    m_lock->setStaleLockTime(0);
}

SingleInstanceGuard::~SingleInstanceGuard() = default;

SingleInstanceGuard::StartResult SingleInstanceGuard::start()
{
    if (m_started) {
        return m_result;
    }
    m_started = true;

    if (!m_lock->tryLock(0)) {
        if (m_lock->error() == QLockFile::LockFailedError) {
            m_result = notifyPrimaryInstance() ? SecondaryInstanceNotified
                                               : SecondaryInstanceUnreachable;
            return m_result;
        }

        // 这不是普通的“没抢到锁”，而是无法证明本进程具有排他权。
        // 调用方必须停止启动，否则两个进程会并发写数据库与活动会话状态。
        m_result = LockUnavailable;
        return m_result;
    }

    // 已取得排他锁，才能删除上次崩溃遗留的套接字端点；从进程绝不能碰它，
    // 否则会切断仍存活主进程的召回通道。
    QLocalServer::removeServer(m_serverName);
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    if (m_server->listen(m_serverName)) {
        connect(m_server.get(), &QLocalServer::newConnection,
                this, &SingleInstanceGuard::acceptPendingConnections);
    } else {
        qWarning() << "无法创建单实例召回通道:" << m_server->errorString();
    }

    // 即使本地套接字创建失败，排他锁仍然有效，主进程可以安全运行；
    // 失败只会让重复启动无法召回窗口，不应造成数据层降级。
    m_result = PrimaryInstance;
    return m_result;
}

bool SingleInstanceGuard::notifyPrimaryInstance() const
{
    QLocalSocket socket;
    socket.connectToServer(m_serverName, QIODevice::WriteOnly);
    if (!socket.waitForConnected(kIpcTimeoutMs)) {
        return false;
    }
    if (socket.write(kActivateCommand) != kActivateCommand.size()) {
        return false;
    }
    const bool written = socket.waitForBytesWritten(kIpcTimeoutMs)
        || socket.bytesToWrite() == 0;
    socket.disconnectFromServer();
    return written;
}

void SingleInstanceGuard::acceptPendingConnections()
{
    while (QLocalSocket* socket = m_server->nextPendingConnection()) {
        socket->setParent(this);
        connect(socket, &QLocalSocket::readyRead, this,
                [this, socket]() { consumeSocketMessage(socket); });
        connect(socket, &QLocalSocket::disconnected,
                socket, &QObject::deleteLater);

        // 客户端可能在 newConnection 槽运行前已经写完，不能只等下一次 readyRead。
        if (socket->bytesAvailable() > 0) {
            consumeSocketMessage(socket);
        }
    }
}

void SingleInstanceGuard::consumeSocketMessage(QLocalSocket* socket)
{
    if (!socket || socket->property("activationHandled").toBool()) {
        return;
    }

    QByteArray message = socket->property("instanceMessage").toByteArray();
    message.append(socket->readAll());

    // 上限。协议只有一行短命令，正常客户端几十字节就发完了。没有上限的话，
    // 一个只连不发换行的进程能让这个 QByteArray 一直涨到内存耗尽——
    // 恶意与写错的客户端都做得到，而且这里是本进程唯一接收外部字节的入口。
    if (message.size() > kMaxMessageBytes) {
        qWarning() << "Single instance message exceeds" << kMaxMessageBytes
                   << "bytes, dropping connection";
        socket->setProperty("activationHandled", true);
        socket->disconnectFromServer();
        return;
    }

    socket->setProperty("instanceMessage", message);
    if (!message.contains('\n')) {
        return;
    }

    socket->setProperty("activationHandled", true);
    if (message.startsWith(kActivateCommand)) {
        emit activationRequested();
    }
    socket->disconnectFromServer();
}
