#ifndef FOCUSSESSION_H
#define FOCUSSESSION_H

#include <QDateTime>
#include <QSqlQuery>
#include <QVariantMap>

class FocusSession
{
public:
    // 一条专注记录保存任务、开始结束时间和实际累计秒数。
    int id = -1;
    int taskId = -1;
    QDateTime startTime;
    QDateTime endTime;
    int durationSeconds = 0;

    // 统计和导出都会复用这两个转换函数，避免各自解析数据库字段。
    static FocusSession fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // FOCUSSESSION_H
