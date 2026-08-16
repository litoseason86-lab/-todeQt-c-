#ifndef SINGLEINSTANCEGUARD_H
#define SINGLEINSTANCEGUARD_H

#include <QObject>
#include <QString>

#include <memory>

class QLocalServer;
class QLocalSocket;
class QLockFile;

// 单实例守卫同时负责两件事：阻止多个进程并发写数据库，以及把重复启动
// 转换成“召回现有窗口”。锁文件只判断主从，本地套接字只传递激活意图。
class SingleInstanceGuard : public QObject
{
    Q_OBJECT

public:
    enum StartResult {
        PrimaryInstance,
        SecondaryInstanceNotified,
        SecondaryInstanceUnreachable,
        LockUnavailable
    };
    Q_ENUM(StartResult)

    explicit SingleInstanceGuard(const QString& lockPath,
                                 const QString& serverName,
                                 QObject* parent = nullptr);
    ~SingleInstanceGuard() override;

    StartResult start();

signals:
    void activationRequested();

private:
    bool notifyPrimaryInstance() const;
    void acceptPendingConnections();
    void consumeSocketMessage(QLocalSocket* socket);
    void closeClientSocket(QLocalSocket* socket);

    QString m_serverName;
    std::unique_ptr<QLockFile> m_lock;
    std::unique_ptr<QLocalServer> m_server;
    bool m_started = false;
    StartResult m_result = LockUnavailable;
    int m_activeClientCount = 0;
};

#endif // SINGLEINSTANCEGUARD_H
