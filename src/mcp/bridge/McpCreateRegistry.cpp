#include "McpCreateRegistry.h"
#include "../common/McpContracts.h"
#include <algorithm>

int McpCreateRegistry::capacity() { return McpContracts::kCreateRegistryCapacity; }
bool McpCreateRegistry::Entry::matches(const QByteArray& digest) const
{
    return digest.size() == qsizetype(parameterDigest.size())
        && std::equal(parameterDigest.begin(), parameterDigest.end(), digest.begin());
}
void McpCreateRegistry::clear() { m_entries.clear(); m_session.clear(); }
void McpCreateRegistry::beginSession(const QString& session)
{
    if (session == m_session) return;
    clear();
    m_session = session;
}
std::optional<McpCreateRegistry::Entry> McpCreateRegistry::find(const QByteArray& key) const
{
    const auto found = m_entries.constFind(QUuid::fromRfc4122(key));
    return found == m_entries.cend() ? std::nullopt : std::optional<Entry>(*found);
}
bool McpCreateRegistry::reserve(const QByteArray& key, const QByteArray& digest)
{
    if (key.size() != 16 || digest.size() != 32 || size() >= capacity()) return false;
    const auto uuid = QUuid::fromRfc4122(key);
    if (m_entries.contains(uuid)) return false;
    Entry entry;
    std::copy(digest.begin(), digest.end(), entry.parameterDigest.begin());
    m_entries.insert(uuid, entry);
    return true;
}
void McpCreateRegistry::commit(const QByteArray& key, qint64 taskId)
{
    auto found = m_entries.find(QUuid::fromRfc4122(key));
    // 只填写已预留的槽，不在提交之后再分配新登记。
    Q_ASSERT(found != m_entries.end());
    if (found != m_entries.end()) found->taskId = taskId;
}
void McpCreateRegistry::remove(const QByteArray& key) { m_entries.remove(QUuid::fromRfc4122(key)); }
