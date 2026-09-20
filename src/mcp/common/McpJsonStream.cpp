#include "McpJsonStream.h"
#include "McpContracts.h"

#include <QIODevice>
#include <QJsonDocument>
#include <QJsonArray>
#include <QStringDecoder>

namespace {
// 只含空格、制表符、回车的行不是消息（CRLF 的残留或客户端多写的空行），
// 直接跳过；回一条 id 为 null 的解析错误只会让客户端记一条莫名其妙的错误日志。
bool isBlankLine(const QByteArray& line)
{
    for (char c : line) {
        if (c != ' ' && c != '\t' && c != '\r') return false;
    }
    return true;
}
}

McpJsonStream::McpJsonStream(QIODevice* device, qsizetype inputLimit, QObject* parent)
    : QObject(parent), m_device(device), m_inputLimit(inputLimit),
      m_partialTimeoutMs(McpContracts::kHandshakeTimeoutMs)
{
    m_partialTimer.setSingleShot(true);
    m_partialTimer.setInterval(m_partialTimeoutMs);
    connect(&m_partialTimer, &QTimer::timeout, this, &McpJsonStream::fail);
    connect(device, &QIODevice::readyRead, this, &McpJsonStream::read);
}

void McpJsonStream::setPartialTimeout(int milliseconds)
{
    m_partialTimeoutMs = qMax(0, milliseconds);
    m_partialTimer.stop();
    if (m_partialTimeoutMs > 0) {
        m_partialTimer.setInterval(m_partialTimeoutMs);
        if (!m_buffer.isEmpty()) m_partialTimer.start();
    }
}

void McpJsonStream::setOversizedLineRecovery(bool enabled)
{
    m_recoverOversized = enabled;
}

void McpJsonStream::fail()
{
    if (m_failed) return;
    m_failed = true;
    m_buffer.clear();
    m_carry.clear();
    m_carryOffset = 0;
    m_partialTimer.stop();
    emit failed();
}

void McpJsonStream::setDispatchGate(std::function<bool()> gate)
{
    m_gate = std::move(gate);
}

void McpJsonStream::resumeDispatch()
{
    if (!m_stalled || m_failed) return;
    m_stalled = false;
    read();
}

// 把 m_buffer 里攒齐的一行交出去。解析结果只有三种：正常消息、非法消息、以及非 JSON 对象。
void McpJsonStream::dispatchLine()
{
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
}

void McpJsonStream::read()
{
    if (m_failed || !m_device) return;
    // 每轮最多从设备取 64 KiB，让应用计时和界面事件有机会运行；剩余数据下一轮继续。
    qsizetype budget = McpContracts::kMaxRequestBytes;
    while (!m_failed && m_device) {
        // 背压只能停在消息边界：已经读进来还没解析的字节留在 m_carry 里，
        // 等输出发下去由 resumeDispatch() 接着处理。只暂停“下一次读设备”挡不住
        // 同一批里的上百条请求——它们同步产出的响应照样会把输出缓冲撑爆。
        if (m_gate && !m_gate()) { m_stalled = true; return; }
        if (m_carryOffset >= m_carry.size()) {
            m_carry.clear();
            m_carryOffset = 0;
            if (budget <= 0 || m_device->bytesAvailable() <= 0) break;
            m_carry = m_device->read(qMin<qsizetype>(4096, budget));
            if (m_carry.isEmpty()) break;
            budget -= m_carry.size();
        }
        // 一次只推进到下一条消息结束，然后回到上面重新看闸门。
        bool boundary = false;
        while (!boundary && m_carryOffset < m_carry.size()) {
            const char c = m_carry.at(m_carryOffset++);
            if (m_discarding) {
                // 超长的那一行已经报过错；丢到它的换行为止，下一行照常解析。
                if (c == '\n') { m_discarding = false; boundary = true; }
                continue;
            }
            if (c == '\n') {
                boundary = true;
                m_partialTimer.stop();
                if (isBlankLine(m_buffer)) { m_buffer.clear(); continue; }
                dispatchLine();
                if (m_failed) return;
                continue;
            }
            if (m_buffer.isEmpty() && m_partialTimeoutMs > 0) m_partialTimer.start();
            m_buffer.append(c);
            if (m_buffer.size() > m_inputLimit) {
                if (!m_recoverOversized) { fail(); return; }
                // 只拒绝这一条：内存里不再攒它的内容，丢弃模式一直持续到它的换行。
                m_buffer.clear();
                m_partialTimer.stop();
                m_discarding = true;
                boundary = true;
                emit oversized();
                if (m_failed) return;
            }
        }
    }
    if (!m_failed && m_device && (m_carryOffset < m_carry.size() || m_device->bytesAvailable() > 0))
        QTimer::singleShot(0, this, &McpJsonStream::read);
}

bool McpJsonStream::send(const QJsonObject& object)
{
    if (m_failed || !m_device) return false;
    const QByteArray bytes = QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n';
    // 单条消息仍以 1 MiB 为限，生产方在生成结果时已经按预算检查过。
    // 积压上限只防“对端长期不读”：前面还有没发完的结果是正常情况（并行调用、客户端读得慢），
    // 由背压排队发送；把它当故障断线，会连带丢掉已经执行过的写入结果。
    if (bytes.size() > McpContracts::kMaxResponseBytes
        || m_device->bytesToWrite() + bytes.size() > McpContracts::kMaxOutputBacklogBytes) {
        fail();
        return false;
    }
    if (m_device->write(bytes) != bytes.size()) { fail(); return false; }
    return true;
}

void McpJsonStream::finishInput()
{
    read();
    // 输入结束时残留的半行是一条不完整的消息；只剩空白（例如末尾的 \r）不算，
    // 正在丢弃的超长行此前已经报过错，也不再重复报。
    if (!m_discarding && !m_buffer.isEmpty() && !isBlankLine(m_buffer))
        emit malformed(McpContracts::JsonRpcError::ParseError);
    m_buffer.clear();
    m_carry.clear();
    m_carryOffset = 0;
    m_discarding = false;
    m_partialTimer.stop();
}
