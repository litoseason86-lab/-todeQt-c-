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
    QDate date;
    bool completed = false;
    QDateTime createdAt;

    static Task fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // TASK_H
