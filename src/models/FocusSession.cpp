#include "FocusSession.h"

#include <QDateTime>
#include <QSqlRecord>

namespace {
QVariant valueByName(const QSqlQuery& query, const char* name)
{
    // 测试和导出使用的 SELECT 列表不同，按列名读取能避免索引耦合。
    const int index = query.record().indexOf(QLatin1String(name));
    return index >= 0 ? query.value(index) : QVariant();
}
}

FocusSession FocusSession::fromQuery(const QSqlQuery& query)
{
    FocusSession session;
    session.id = valueByName(query, "id").toInt();
    const QVariant taskId = valueByName(query, "task_id");
    session.taskId = taskId.isNull() ? -1 : taskId.toInt();
    session.startTime = QDateTime::fromString(valueByName(query, "start_time").toString(), Qt::ISODate);
    session.endTime = QDateTime::fromString(valueByName(query, "end_time").toString(), Qt::ISODate);
    if (!session.startTime.isValid()) {
        // SQLite CURRENT_TIMESTAMP 使用空格分隔日期和时间，不是 Qt::ISODate 的 "T"。
        session.startTime = QDateTime::fromString(valueByName(query, "start_time").toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    if (!session.endTime.isValid()) {
        session.endTime = QDateTime::fromString(valueByName(query, "end_time").toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    session.durationSeconds = valueByName(query, "duration").toInt();
    return session;
}

QVariantMap FocusSession::toVariantMap() const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), id);
    map.insert(QStringLiteral("taskId"), taskId >= 0 ? QVariant(taskId) : QVariant());
    map.insert(QStringLiteral("startTime"), startTime);
    map.insert(QStringLiteral("endTime"), endTime);
    map.insert(QStringLiteral("duration"), durationSeconds);
    return map;
}
