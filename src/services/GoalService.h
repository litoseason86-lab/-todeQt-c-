#ifndef GOALSERVICE_H
#define GOALSERVICE_H

#include "../models/LongGoal.h"

#include <QDate>
#include <QHash>
#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include <optional>

// 长期目标服务。表由本服务自建（与 CountdownService 同一先例），不进 DatabaseManager
// 的 user_version 迁移链：纯新增表、不改写既有数据、没有向后兼容包袱，走迁移链是过度设计。
//
// 进度不落库，一律由 focus_sessions 现算。唯一持久化的“奖励状态”是 fired_milestones
// 位掩码，它记录的不是进度而是“哪几档庆祝已经弹过”，用来防止撤销专注记录后重复庆祝。
class GoalService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)
    Q_PROPERTY(int maxTargetPomodoros READ maxTargetPomodoros CONSTANT)

public:
    // 与任务/例行标题共用同一上限，超长一律拒绝而非截断。
    static constexpr int kMaxTitleLength = 100;
    // 目标番茄数上限。按 25 分钟一个番茄算，9999 个约等于 4000 小时，
    // 足够覆盖“一万小时”级别的目标，同时挡住误输入的天文数字。
    static constexpr int kMaxTargetPomodoros = 9999;

    static GoalService* instance();

    int maxTitleLength() const { return kMaxTitleLength; }
    int maxTargetPomodoros() const { return kMaxTargetPomodoros; }

    // 增删改。startDate 传无效日期时取当前逻辑日；deadline 传无效日期表示长期目标。
    Q_INVOKABLE bool addGoal(const QString& title,
                             int categoryId,
                             int targetPomodoros,
                             const QVariant& startDateValue,
                             const QVariant& deadlineValue);
    Q_INVOKABLE bool updateGoal(int goalId,
                                const QString& title,
                                int categoryId,
                                int targetPomodoros,
                                const QVariant& startDateValue,
                                const QVariant& deadlineValue);
    Q_INVOKABLE bool deleteGoal(int goalId);
    Q_INVOKABLE bool reorderGoal(int fromIndex, int toIndex);

    // 读取。列表用一条带聚合子查询的 SQL 一次算完所有目标进度，不在循环里发查询。
    // 不是 const：首次读取时可能要建表（与 CountdownService 的 ensureDatabaseReady 同理）。
    Q_INVOKABLE QVariantList getGoals();
    Q_INVOKABLE QVariantMap getGoal(int goalId);
    // 返回指定月内有有效番茄的逻辑日；每日计数与目标总进度复用同一条有效番茄规则。
    Q_INVOKABLE QVariantList getGoalDailyCounts(int goalId, int year, int month);

    // 重算全部目标的里程碑并对新达成的档位发 milestoneReached。
    // 阶段 2 会由 FocusTimer 的 focusCompleted 驱动；现在先作为公开入口，便于测试直接调用。
    Q_INVOKABLE void refreshMilestones();

signals:
    void goalsChanged();
    // 进度较本进程上次刷新增加时发出；首次观察只播种缓存，避免启动时补发旧进度。
    void goalProgressed(int goalId, const QString& title, int doneCount, int targetPomodoros);
    // 每档里程碑只会发一次。percent 取值为 25/50/75/100。
    void milestoneReached(int goalId, const QString& title, int percent);
    void operationFailed(const QString& message);

private:
    explicit GoalService(QObject* parent = nullptr);

    bool ensureDatabaseReady();
    bool initializeDatabase();
    // 目标本体 + 进度/活跃日聚合的公共 SQL；列表和单条查询共用，保证两处口径一致。
    QString goalSelectSql() const;
    // 以下几个方法会在失败时发 operationFailed，所以不能是 const 成员。
    // ok 区分"查询失败"与"查询成功但没有匹配行"，避免把数据库错误误报为目标不存在。
    QList<LongGoal> loadGoals(std::optional<int> singleGoalId, bool* ok = nullptr);
    int forecastDaysFor(const LongGoal& goal, int activeDays) const;
    bool validateInput(const QString& title,
                       int categoryId,
                       int targetPomodoros,
                       QString* normalizedTitle);
    QDate resolveStartDate(const QVariant& startDateValue) const;
    void reportFailure(const QString& message);

    bool m_databaseReady = false;
    QString m_databaseName;
    // Toast 是瞬时反馈，不应持久化；回退会下调缓存，之后重新上涨仍会再次提示。
    QHash<int, int> m_lastDoneCounts;
};

#endif // GOALSERVICE_H
