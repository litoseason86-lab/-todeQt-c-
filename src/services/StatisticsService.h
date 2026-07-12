#ifndef STATISTICSSERVICE_H
#define STATISTICSSERVICE_H

#include <QDate>
#include <QList>
#include <QObject>
#include <QPair>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class StatisticsService : public QObject
{
    Q_OBJECT

public:
    static StatisticsService* instance();

    // 统计结果直接给 QML 卡片和图表使用，所以返回 QVariantMap/QVariantList。
    Q_INVOKABLE QVariantMap getDayStats(const QDate& date) const;
    Q_INVOKABLE QVariantMap getTodayStats() const;
    Q_INVOKABLE QVariantMap getDayComparison(const QDate& date) const;
    Q_INVOKABLE QVariantList getWeekStats(const QDate& weekStart) const;
    Q_INVOKABLE QVariantList getWeekStats() const;
    Q_INVOKABLE QVariantMap getWeekComparison(const QDate& weekStart) const;
    Q_INVOKABLE QVariantMap getCategoryStats(const QVariant& startDateValue, const QVariant& endDateValue) const;
    Q_INVOKABLE QVariantMap getMonthStats(int year, int month) const;
    Q_INVOKABLE QVariantMap getMonthStats() const;
    Q_INVOKABLE QVariantMap getMonthComparison(int year, int month) const;
    Q_INVOKABLE int getEffectiveDays(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getFocusSessionCount(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getStreakDays() const;
    Q_INVOKABLE int getTotalFocusDuration() const;
    Q_INVOKABLE QVariantList getMonthWeeklySummary(int year, int month) const;
    Q_INVOKABLE QVariantList getMonthWeeklySummary() const;

private:
    explicit StatisticsService(QObject* parent = nullptr);

    // 这些私有方法只负责单日基础指标，公共方法再组合成页面需要的数据。
    int calculateTotalDuration(const QDate& date) const;
    int countCompletedTasks(const QDate& date) const;
    int countTotalTasks(const QDate& date) const;
    QList<QDate> getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const;
    QPair<QDate, QDate> getWeekRange(const QDate& mondayOfWeek) const;
    QVariantMap buildComparisonResult(int currentValue, int previousValue, const QString& label) const;
};

#endif // STATISTICSSERVICE_H
