#ifndef TASK_H
#define TASK_H

#include <QDate>
#include <QDateTime>
#include <QSqlQuery>
#include <QString>
#include <QVariantMap>

class Task
{
public:
    int id = -1;
    QString title;
    QString category;
    int categoryId = -1;
    QString categoryName;
    QString categoryColor;
    QDate date;
    bool completed = false;
    QDateTime createdAt;

    static Task fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // TASK_H
