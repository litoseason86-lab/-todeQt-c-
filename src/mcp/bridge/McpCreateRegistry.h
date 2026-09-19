#ifndef MCPCREATEREGISTRY_H
#define MCPCREATEREGISTRY_H

#include <QHash>
#include <QUuid>
#include <QString>
#include <array>
#include <optional>

// 每条仅保存 UUID（16 字节）、SHA-256 参数摘要（32 字节）和任务编号。
// 不缓存用户文本或响应；容量满不驱逐，重放始终按原编号读取当前数据。
class McpCreateRegistry
{
public:
    struct Entry {
        std::array<char, 32> parameterDigest{};
        qint64 taskId = 0;
        bool matches(const QByteArray& digest) const;
    };
    static int capacity();
    void beginSession(const QString& session);
    void clear();
    int size() const { return int(m_entries.size()); }
    std::optional<Entry> find(const QByteArray& key) const;
    bool reserve(const QByteArray& key, const QByteArray& digest);
    void commit(const QByteArray& key, qint64 taskId);
    void remove(const QByteArray& key);
private:
    QString m_session;
    QHash<QUuid, Entry> m_entries;
};
#endif
