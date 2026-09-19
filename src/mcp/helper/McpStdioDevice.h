#pragma once
#include <QIODevice>
#include <QSocketNotifier>
#include <memory>

// 标准输入输出也必须非阻塞；尤其不能让不读 stdout 的客户端卡住主事件循环。
class McpStdioDevice : public QIODevice
{
    Q_OBJECT
public:
    explicit McpStdioDevice(QObject* parent = nullptr);
    ~McpStdioDevice() override;
    bool start();
    bool isSequential() const override { return true; }
    qint64 bytesAvailable() const override;
    qint64 bytesToWrite() const override;
signals:
    void inputClosed();
    void transportFailed();
protected:
    qint64 readData(char* data, qint64 maxSize) override;
    qint64 writeData(const char* data, qint64 size) override;
private:
    void receive();
    void flushOutput();
    QByteArray m_input, m_output;
    std::unique_ptr<QSocketNotifier> m_reader, m_writer;
    int m_inputFlags = -1, m_outputFlags = -1;
};
