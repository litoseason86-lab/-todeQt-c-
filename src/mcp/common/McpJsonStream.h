#pragma once

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QTimer>

#include <functional>

class QIODevice;

// 两条传输通道共用换行分帧；缓冲有上限，半包也有截止时间，防止慢端无限占用内存。
class McpJsonStream : public QObject
{
    Q_OBJECT
public:
    McpJsonStream(QIODevice* device, qsizetype inputLimit, QObject* parent = nullptr);
    bool send(const QJsonObject& object);
    void finishInput();
    // 半行（收到一部分、迟迟等不到换行）的等待上限，0 表示不限。本地 socket 上保留默认期限，
    // 防止别的进程占着连接只发半帧；stdio 的另一端是拉起辅助程序的 AI 客户端本身，
    // 它分几次写完一行不该让进程自行退出。
    void setPartialTimeout(int milliseconds);
    int partialTimeout() const { return m_partialTimeoutMs; }
    // 开启后，超过输入上限的一行只丢弃这一行并发 oversized()，后面的消息照常处理；
    // 关闭（默认）时按传输失败处理，适合对端必须守规矩的私有通道。
    void setOversizedLineRecovery(bool enabled);
    // 背压闸门：返回 false 时停在消息边界，不再解析下一条；已经读进来的字节留在流里，
    // 等 resumeDispatch() 继续。只暂停“下一次读设备”是不够的——一次读进来的几 KiB 里
    // 可能就有上百条请求，同步答完照样把输出缓冲撑爆。
    void setDispatchGate(std::function<bool()> gate);
    void resumeDispatch();
signals:
    void received(const QJsonObject& object);
    void malformed(int code);
    void oversized();
    void failed();
private:
    void read();
    void dispatchLine();
    void fail();
    QPointer<QIODevice> m_device;
    QByteArray m_buffer;
    // 已经从设备读出、但还没解析完的字节。闸门关上时它们留在这里，不会丢也不会被提前解析。
    QByteArray m_carry;
    qsizetype m_carryOffset = 0;
    std::function<bool()> m_gate;
    bool m_stalled = false;
    qsizetype m_inputLimit;
    QTimer m_partialTimer;
    int m_partialTimeoutMs;
    bool m_recoverOversized = false;
    // 正在丢弃超长的一行，直到遇到它的换行为止。
    bool m_discarding = false;
    bool m_failed = false;
};
