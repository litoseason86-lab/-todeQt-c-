#ifndef ROUTINEMANAGER_H
#define ROUTINEMANAGER_H

#include "RoutineRules.h"

#include <QObject>
#include <QString>
#include <QVariantList>

class RoutineManager : public QObject
{
    Q_OBJECT

public:
    static RoutineManager* instance();

    // 例行项的增删改查，供「每日例行」管理弹窗使用。categoryId <= 0 表示不设科目。
    // weekdays 是重复日位掩码（见 RoutineRules）：省略即每天，至少要选中一天。
    Q_INVOKABLE bool addRoutine(const QString& title, int categoryId,
                                int weekdays = RoutineRules::kEveryDayMask);
    // 更新只覆盖标题和科目，不碰重复日：重复日在单独的弹窗里改，
    // 两件事从不在同一次提交里发生。放在一条语句里覆盖写，少传一个参数就会把用户设好的
    // 「周一三五」静默改回「每天」——拆开之后这种错根本没有机会发生。
    Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId);
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
};

#endif // ROUTINEMANAGER_H
