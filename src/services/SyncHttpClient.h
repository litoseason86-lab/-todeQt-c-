#ifndef SYNCHTTPCLIENT_H
#define SYNCHTTPCLIENT_H

#include <QByteArray>
#include <QList>
#include <QPair>
#include <QString>
#include <QUrl>

// 同步服务器阻塞 HTTP 请求的平台无关接口。
//
// 请求在同步工作线程发出，但同一对象允许被多个线程同时调用；实现必须自行维护
// 正在执行的任务集合。cancelAll() 是退出与切页时唯一的跨线程入口，只取消调用
// 发生时已经存在的请求，之后新发出的请求继续正常工作。
class SyncHttpClient
{
public:
    struct Request {
        QByteArray method;
        QUrl url;
        QList<QPair<QByteArray, QByteArray>> headers;
        QByteArray body;
        int timeoutMs = 30000;
    };

    enum class Failure {
        None,
        Network,
        Timeout,
        Cancelled,
    };

    struct Response {
        Failure failure = Failure::None;
        int status = 0;
        QByteArray body;
        QString message;
    };

    virtual ~SyncHttpClient() = default;

    virtual Response send(const Request& request) = 0;
    virtual void cancelAll() = 0;
};

#endif // SYNCHTTPCLIENT_H
