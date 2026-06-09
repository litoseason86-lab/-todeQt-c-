#include "Task.h"

#include <QDateTime>
#include <QSqlRecord>

namespace {
QVariant valueByName(const QSqlQuery& query, const char* name)
{
    const int index = query.record().indexOf(QLatin1String(name));
    return index >= 0 ? query.value(index) : QVariant();
}
}

Task Task::fromQuery(const QSqlQuery& query)
{
    Task task;
    task.id = valueByName(query, "id").toInt();
    task.title = valueByName(query, "title").toString();
    task.category = valueByName(query, "category").toString();
    task.date = QDate::fromString(valueByName(query, "date").toString(), Qt::ISODate);
    task.completed = valueByName(query, "completed").toBool();
    task.createdAt = QDateTime::fromString(valueByName(query, "created_at").toString(), Qt::ISODate);
    if (!task.createdAt.isValid()) {
        task.createdAt = QDateTime::fromString(valueByName(query, "created_at").toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    return task;
}

QVariantMap Task::toVariantMap() const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), id);
    map.insert(QStringLiteral("title"), title);
    map.insert(QStringLiteral("category"), category);
    map.insert(QStringLiteral("date"), date);
    map.insert(QStringLiteral("completed"), completed);
    map.insert(QStringLiteral("createdAt"), createdAt);
    return map;
}
