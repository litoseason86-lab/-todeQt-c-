#ifndef ROUTINEMANAGER_H
#define ROUTINEMANAGER_H

#include "RoutineRules.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class RoutineManager : public QObject
{
    Q_OBJECT

public:
    static RoutineManager* instance();

    // 例行项的增删改查，供「每日例行」管理弹窗使用。categoryId <= 0 表示不设科目。
    // weekdays 是重复日位掩码（见 RoutineRules）：省略即每天，至少要选中一天。
    Q_INVOKABLE bool addRoutine(const QString& title, int categoryId,
                                int weekdays = RoutineRules::kEveryDayMask);
    // 以下四个写入口都会连带处理「今天已经生成的那条实例」，改规则不能只改明天的：
    //   - updateRoutine：把当日实例的标题和科目同步成新值（已完成的也同步，改名不破坏数据）。
    //   - deleteRoutine / setRoutineActive(false) / 把今天从 setRoutineWeekdays 中去掉：
    //     收回当日实例，但只收「未完成且一次专注都没开始过」的那种，其余保留成普通任务。
    // 收回时会把生成戳退回 NULL，因此「停用后又启用」「取消今天后又勾回今天」能把任务补回来。

    // 更新只覆盖标题和科目，不碰重复日：重复日在单独的弹窗里改，
    // 两件事从不在同一次提交里发生。放在一条语句里覆盖写，少传一个参数就会把用户设好的
    // 「周一三五」静默改回「每天」——拆开之后这种错根本没有机会发生。
    Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId);
    // 编辑只交出用户改过的字段，键为 title / categoryId。没交的取库里现在的值：
    // 编辑开着时另一台改了它，同步写进来的新值不会被打开时的旧值盖掉。
    // 不认识的键、类型不对的值整次拒绝；没有改动时只确认例行还在。
    Q_INVOKABLE bool updateRoutineChanges(int id, const QVariantMap& changes);
    Q_INVOKABLE bool deleteRoutine(int id);
    Q_INVOKABLE bool setRoutineActive(int id, bool active);
    // 只改重复日的单字段写入，与 setRoutineActive 同形，供「重复」弹窗使用。
    Q_INVOKABLE bool setRoutineWeekdays(int id, int weekdays);
    Q_INVOKABLE QVariantList getRoutines() const;

    // 生成「今天」的例行任务行：幂等、删不复活、不补历史（Task 3 实现）。
    // 只生成重复日命中今天的例行；星期按逻辑日取，凌晨日界点前仍算前一天那一档。
    Q_INVOKABLE int materializeToday();

signals:
    void routinesChanged();
    void operationFailed(const QString& message);

private:
    explicit RoutineManager(QObject* parent = nullptr);
    void reportFailure(const QString& message) const;
    // 收回当日实例后广播任务侧的变更。规则变化本身走 routinesChanged，
    // 但被删掉的任务属于 TaskManager 的事实，必须按它的信号约定通知出去。
    void notifyTasksReclaimed(const QList<int>& taskIds) const;
};

#endif // ROUTINEMANAGER_H
