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

    // 统计结果直接给 QML 卡片和图表使用，所以返回 QVariantMap/QVariantList。
    Q_INVOKABLE QVariantMap getTodayStats() const;
    Q_INVOKABLE QVariantList getWeekStats() const;
    Q_INVOKABLE QVariantMap getCategoryStats(const QVariant& startDateValue, const QVariant& endDateValue) const;

private:
    explicit StatisticsService(QObject* parent = nullptr);

    // 这些私有方法只负责单日基础指标，公共方法再组合成页面需要的数据。
    int calculateTotalDuration(const QDate& date) const;
    int countCompletedTasks(const QDate& date) const;
    int countTotalTasks(const QDate& date) const;
};

#endif // STATISTICSSERVICE_H
