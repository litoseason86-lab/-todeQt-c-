#pragma once

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QTimer>

class QIODevice;

// 两条传输通道共用换行分帧；缓冲有上限，半包也有截止时间，防止慢端无限占用内存。
class McpJsonStream : public QObject
{
    Q_OBJECT
public:
    McpJsonStream(QIODevice* device, qsizetype inputLimit, QObject* parent = nullptr);
    bool send(const QJsonObject& object);
    void finishInput();
signals:
    void received(const QJsonObject& object);
    void malformed(int code);
    void failed();
private:
    void read();
    void fail();
    QPointer<QIODevice> m_device;
    QByteArray m_buffer;
    qsizetype m_inputLimit;
    QTimer m_partialTimer;
    bool m_failed = false;
};
