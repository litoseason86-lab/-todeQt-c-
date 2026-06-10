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
    // 这个结构体是数据库任务行在 C++ 里的形状，字段名尽量贴近数据库列名。
    int id = -1;
    QString title;
    QString category;
    int categoryId = -1;
    QString categoryName;
    QString categoryColor;
    QDate date;
    bool completed = false;
    QDateTime createdAt;

    // fromQuery 负责从 SQL 查询结果创建对象，toVariantMap 负责交给 QML 显示。
    static Task fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // TASK_H
