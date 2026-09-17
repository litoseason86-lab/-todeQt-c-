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
    // logicalTodayIso 是页面本次刷新生成的「逻辑今天」（yyyy-MM-dd，已按 dayStartHour 换算过），
    // 周比较与复盘收到同一个值，据此判断当前周／已结束周。服务不再对它做日界换算；
    // 当前周不做周际比较，三项指标 hasData 为假，结果里带 periodState。
    Q_INVOKABLE QVariantMap getWeekComparison(const QDate& weekStart,
                                              const QString& logicalTodayIso) const;
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
    // 每周复盘。weekStart 必须是周一，logicalTodayIso 同 getWeekComparison。
    // 结果字段固定：周期（periodState）、加载状态（loadState / errorMessage）、
    // 可选模块（goal / todayGoal / plannedTasks）、F2 用的整体科目（subjects）与结构化事实（facts）。
    // 统计判断全部在这里完成，界面只格式化与展示。全部走批量聚合 SQL，不按任务逐条取会话。
    // 复盘专用查询失败不发 operationFailed，只通过 loadState = error 返回，不带任何半份统计。
    Q_INVOKABLE QVariantMap getWeeklyReview(const QDate& weekStart,
                                            const QString& logicalTodayIso) const;
    // 无参版取当前逻辑周，只读一次逻辑今天。
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
    // 整周对整周的比较，只给已结束周用；不判断周期，所以不对界面开放。
    QVariantMap getWeekComparison(const QDate& weekStart) const;
};

#endif // STATISTICSSERVICE_H
