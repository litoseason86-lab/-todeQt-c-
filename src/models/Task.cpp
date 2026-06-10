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
    const QVariant categoryIdValue = valueByName(query, "category_id");
    if (categoryIdValue.isValid() && !categoryIdValue.isNull()) {
        task.categoryId = categoryIdValue.toInt();
    }
    task.categoryName = valueByName(query, "category_name").toString();
    task.categoryColor = valueByName(query, "category_color").toString();
    task.date = QDate::fromString(valueByName(query, "date").toString(), Qt::ISODate);
    task.completed = valueByName(query, "completed").toBool();
    task.createdAt = QDateTime::fromString(valueByName(query, "created_at").toString(), Qt::ISODate);
    if (!task.createdAt.isValid()) {
        task.createdAt = QDateTime::fromString(valueByName(query, "created_at").toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    if (task.categoryName.isEmpty()) {
        task.categoryName = task.category;
    }
    if (task.category.isEmpty()) {
        task.category = task.categoryName;
    }
    return task;
}

QVariantMap Task::toVariantMap() const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), id);
    map.insert(QStringLiteral("title"), title);
    map.insert(QStringLiteral("categoryText"), category);
    map.insert(QStringLiteral("categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    map.insert(QStringLiteral("categoryName"), categoryName);
    map.insert(QStringLiteral("categoryColor"), categoryColor);

    QVariantMap categoryMap;
    if (categoryId > 0 || !categoryName.isEmpty() || !categoryColor.isEmpty()) {
        categoryMap.insert(QStringLiteral("id"), categoryId > 0 ? QVariant(categoryId) : QVariant());
        categoryMap.insert(QStringLiteral("name"), categoryName);
        categoryMap.insert(QStringLiteral("color"), categoryColor);
    }
    map.insert(QStringLiteral("category"), categoryMap);
    map.insert(QStringLiteral("categoryData"), categoryMap);
    map.insert(QStringLiteral("date"), date);
    map.insert(QStringLiteral("completed"), completed);
    map.insert(QStringLiteral("createdAt"), createdAt);
    return map;
}
