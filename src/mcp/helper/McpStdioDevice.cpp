#include "McpStdioDevice.h"
#include "../common/McpContracts.h"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

McpStdioDevice::McpStdioDevice(QObject* parent) : QIODevice(parent) {}
McpStdioDevice::~McpStdioDevice()
{
    if (m_inputFlags >= 0) ::fcntl(STDIN_FILENO, F_SETFL, m_inputFlags);
    if (m_outputFlags >= 0) ::fcntl(STDOUT_FILENO, F_SETFL, m_outputFlags);
}
bool McpStdioDevice::start()
{
    m_inputFlags = ::fcntl(STDIN_FILENO, F_GETFL);
    m_outputFlags = ::fcntl(STDOUT_FILENO, F_GETFL);
    if (m_inputFlags < 0 || m_outputFlags < 0
        || ::fcntl(STDIN_FILENO, F_SETFL, m_inputFlags | O_NONBLOCK) < 0
        || ::fcntl(STDOUT_FILENO, F_SETFL, m_outputFlags | O_NONBLOCK) < 0) return false;
    open(QIODevice::ReadWrite | QIODevice::Unbuffered);
    m_reader = std::make_unique<QSocketNotifier>(STDIN_FILENO, QSocketNotifier::Read);
    m_writer = std::make_unique<QSocketNotifier>(STDOUT_FILENO, QSocketNotifier::Write);
    m_writer->setEnabled(false);
    connect(m_reader.get(), &QSocketNotifier::activated, this, &McpStdioDevice::receive);
    connect(m_writer.get(), &QSocketNotifier::activated, this, &McpStdioDevice::flushOutput);
    return true;
}
qint64 McpStdioDevice::bytesAvailable() const { return m_input.size() + QIODevice::bytesAvailable(); }
qint64 McpStdioDevice::bytesToWrite() const { return m_output.size(); }
qint64 McpStdioDevice::readData(char* data, qint64 maxSize)
{
    const qint64 count = qMin(maxSize, qint64(m_input.size()));
    std::memcpy(data, m_input.constData(), size_t(count));
    m_input.remove(0, count);
    return count;
}
qint64 McpStdioDevice::writeData(const char* data, qint64 size)
{
    if (size < 0 || size + m_output.size() > McpContracts::kMaxResponseBytes) return -1;
    m_output.append(data, size);
    flushOutput();
    return size;
}
void McpStdioDevice::receive()
{
    char buffer[4096];
    const ssize_t count = ::read(STDIN_FILENO, buffer, sizeof(buffer));
    if (count > 0) {
        if (m_input.size() + count > McpContracts::kMaxRequestBytes) {
            m_reader->setEnabled(false);
            emit transportFailed();
            return;
        }
        m_input.append(buffer, count);
        emit readyRead();
    } else if (count == 0) {
        m_reader->setEnabled(false);
        emit inputClosed();
    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        m_reader->setEnabled(false);
        emit transportFailed();
    }
}
void McpStdioDevice::flushOutput()
{
    if (m_output.isEmpty()) { if (m_writer) m_writer->setEnabled(false); return; }
    const ssize_t count = ::write(STDOUT_FILENO, m_output.constData(), size_t(m_output.size()));
    if (count > 0) {
        m_output.remove(0, count);
        emit bytesWritten(count);
    } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        m_output.clear();
        if (m_writer) m_writer->setEnabled(false);
        emit transportFailed();
        return;
    }
    if (m_writer) m_writer->setEnabled(!m_output.isEmpty());
}
