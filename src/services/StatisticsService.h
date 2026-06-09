#ifndef STATISTICSSERVICE_H
#define STATISTICSSERVICE_H

#include <QDate>
#include <QObject>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class StatisticsService : public QObject
{
    Q_OBJECT

public:
    static StatisticsService* instance();

    Q_INVOKABLE QVariantMap getTodayStats() const;
    Q_INVOKABLE QVariantList getWeekStats() const;
    Q_INVOKABLE QVariantMap getCategoryStats(const QVariant& startDateValue, const QVariant& endDateValue) const;

private:
    explicit StatisticsService(QObject* parent = nullptr);

    int calculateTotalDuration(const QDate& date) const;
    int countCompletedTasks(const QDate& date) const;
    int countTotalTasks(const QDate& date) const;
};

#endif // STATISTICSSERVICE_H
