#include "Task.h"

#include <QDateTime>
#include <QSqlRecord>
#include <QTimeZone>

namespace {
QVariant valueByName(const QSqlQuery& query, const char* name)
{
    // 共享查询的列会演进；按列名读取可以避免列顺序变化破坏映射。
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
    const QString createdAtText = valueByName(query, "created_at").toString();
    task.createdAt = QDateTime::fromString(createdAtText, Qt::ISODate);
    if (!createdAtText.contains(QLatin1Char('T'))) {
        // SQLite CURRENT_TIMESTAMP 没有时区后缀，但标准规定值是 UTC；先标记 UTC 再转本地。
        task.createdAt = QDateTime::fromString(createdAtText, QStringLiteral("yyyy-MM-dd HH:mm:ss"));
        if (task.createdAt.isValid()) {
            task.createdAt.setTimeZone(QTimeZone::UTC);
            task.createdAt = task.createdAt.toLocalTime();
        }
    }
    if (task.categoryName.isEmpty()) {
        // 旧数据库可能只有 tasks.category，需要映射到新的 categoryName。
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
    // 保留 categoryData，兼容早于标准化 category 对象的 QML 视图和测试。
    map.insert(QStringLiteral("categoryData"), categoryMap);
    map.insert(QStringLiteral("date"), date);
    map.insert(QStringLiteral("completed"), completed);
    map.insert(QStringLiteral("createdAt"), createdAt);
    return map;
}
