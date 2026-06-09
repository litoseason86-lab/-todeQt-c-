#ifndef FOCUSSESSION_H
#define FOCUSSESSION_H

#include <QDateTime>
#include <QSqlQuery>
#include <QVariantMap>

class FocusSession
{
public:
    int id = -1;
    int taskId = -1;
    QDateTime startTime;
    QDateTime endTime;
    int durationSeconds = 0;

    static FocusSession fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // FOCUSSESSION_H
