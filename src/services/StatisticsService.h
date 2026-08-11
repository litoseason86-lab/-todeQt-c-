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
    // 今日学习统计：按 task_id 分组聚合指定逻辑日的专注时长与有效番茄数。
    // task_id 为空(自由计时未选任务)会归为单行 unassigned=true。无参版取当前逻辑日。
    Q_INVOKABLE QVariantMap getDayTaskStats(const QDate& date) const;
    Q_INVOKABLE QVariantMap getTodayTaskStats() const;
    Q_INVOKABLE QVariantMap getMonthStats(int year, int month) const;
    Q_INVOKABLE QVariantMap getMonthStats() const;
    Q_INVOKABLE QVariantMap getMonthComparison(int year, int month) const;
    // 调用方刚算过当月时用这个重载：界面总是先 getMonthStats 再 getMonthComparison，
    // 无参版会把同一个月再整算一遍，占一次月刷新约四分之一的时间。
    Q_INVOKABLE QVariantMap getMonthComparison(int year, int month,
                                               const QVariantMap& precomputedCurrent) const;
    Q_INVOKABLE int getEffectiveDays(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getFocusSessionCount(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getValidPomodoroCount(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getStreakDays() const;
    Q_INVOKABLE int getTotalFocusDuration() const;
    Q_INVOKABLE QVariantList getMonthWeeklySummary(int year, int month) const;
    Q_INVOKABLE QVariantList getMonthWeeklySummary() const;
    // 每周复盘：计划 vs 实际番茄、科目对账、与上周对比，以及确定性事实/建议。
    // weekStart 必须是周一；无参版取当前逻辑周。全部走批量聚合 SQL，不遍历原始记录。
    Q_INVOKABLE QVariantMap getWeeklyReview(const QDate& weekStart) const;
    Q_INVOKABLE QVariantMap getWeeklyReview() const;

signals:
    void operationFailed(const QString& message);

private:
    explicit StatisticsService(QObject* parent = nullptr);

    // 这些私有方法只负责单日基础指标，公共方法再组合成页面需要的数据。
    int calculateTotalDuration(const QDate& date) const;
    int countCompletedTasks(const QDate& date) const;
    int countTotalTasks(const QDate& date) const;
    QList<QDate> getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const;
    QPair<QDate, QDate> getWeekRange(const QDate& mondayOfWeek) const;
    QVariantMap buildComparisonResult(int currentValue, int previousValue, const QString& label) const;
    // 某周的计划/实际聚合：{plannedTotal, completedTotal, focusedSeconds, activeDays, subjects[]}。
    // subjects 按科目名合并计划与实际番茄，供复盘对账与结论规则使用。
    QVariantMap weeklyAggregates(const QDate& weekStart, const QDate& weekEnd) const;
};

#endif // STATISTICSSERVICE_H
