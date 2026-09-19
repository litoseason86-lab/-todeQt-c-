#include "McpJsonStream.h"
#include "McpContracts.h"

#include <QIODevice>
#include <QJsonDocument>
#include <QJsonArray>
#include <QStringDecoder>

McpJsonStream::McpJsonStream(QIODevice* device, qsizetype inputLimit, QObject* parent)
    : QObject(parent), m_device(device), m_inputLimit(inputLimit)
{
    m_partialTimer.setSingleShot(true);
    m_partialTimer.setInterval(McpContracts::kHandshakeTimeoutMs);
    connect(&m_partialTimer, &QTimer::timeout, this, &McpJsonStream::fail);
    connect(device, &QIODevice::readyRead, this, &McpJsonStream::read);
}

void McpJsonStream::fail()
{
    if (m_failed) return;
    m_failed = true;
    m_buffer.clear();
    m_partialTimer.stop();
    emit failed();
}

void McpJsonStream::read()
{
    if (m_failed || !m_device) return;
    // 每轮最多处理 64 KiB，让应用计时和界面事件有机会运行；剩余数据下一轮继续。
    qsizetype budget = McpContracts::kMaxRequestBytes;
    while (!m_failed && m_device && m_device->bytesAvailable() > 0 && budget > 0) {
        const QByteArray chunk = m_device->read(qMin<qsizetype>(4096, budget));
        if (chunk.isEmpty()) break;
        budget -= chunk.size();
        for (char c : chunk) {
            if (c == '\n') {
                m_partialTimer.stop();
                QStringDecoder decoder(QStringDecoder::Utf8, QStringConverter::Flag::Stateless);
                const QString decoded = decoder.decode(m_buffer);
                QJsonParseError error;
                const QJsonDocument document = QJsonDocument::fromJson(m_buffer, &error);
                m_buffer.clear();
                if (decoder.hasError() || error.error != QJsonParseError::NoError) {
                    // Qt 文档解析器只接受对象和数组；合法 JSON 标量属于无效请求，而非 JSON 语法错误。
                    QJsonParseError scalarError;
                    const auto wrapped = QJsonDocument::fromJson('[' + decoded.toUtf8() + ']', &scalarError);
                    const bool scalar = !decoder.hasError() && scalarError.error == QJsonParseError::NoError
                        && wrapped.isArray() && wrapped.array().size() == 1;
                    emit malformed(scalar ? McpContracts::JsonRpcError::InvalidRequest : McpContracts::JsonRpcError::ParseError);
                } else if (!document.isObject()) {
                    emit malformed(McpContracts::JsonRpcError::InvalidRequest);
                } else {
                    emit received(document.object());
                }
                if (m_failed) return;
            } else {
                if (m_buffer.isEmpty()) m_partialTimer.start();
                m_buffer.append(c);
                if (m_buffer.size() > m_inputLimit) { fail(); return; }
            }
        }
    }
    if (!m_failed && m_device && m_device->bytesAvailable() > 0)
        QTimer::singleShot(0, this, &McpJsonStream::read);
}

bool McpJsonStream::send(const QJsonObject& object)
{
    if (m_failed || !m_device) return false;
    const QByteArray bytes = QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n';
    if (bytes.size() > McpContracts::kMaxResponseBytes
        || m_device->bytesToWrite() + bytes.size() > McpContracts::kMaxResponseBytes) {
        fail();
        return false;
    }
    if (m_device->write(bytes) != bytes.size()) { fail(); return false; }
    return true;
}

void McpJsonStream::finishInput()
{
    read();
    if (!m_buffer.isEmpty()) {
        emit malformed(McpContracts::JsonRpcError::ParseError);
        m_buffer.clear();
    }
    m_partialTimer.stop();
}
