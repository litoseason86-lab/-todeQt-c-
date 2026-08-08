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
    // 用户预估的番茄数；0 表示未设置。实际番茄数与专注秒数是从 focus_sessions 聚合出来的
    // 只读派生值，不落在 tasks 表里，避免与专注记录产生第二份可能不一致的真相。
    int estimatedMinutes = 0;
    int actualPomodoros = 0;
    int focusedSeconds = 0;

    // fromQuery 负责从 SQL 查询结果创建对象，toVariantMap 负责交给 QML 显示。
    static Task fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // TASK_H
