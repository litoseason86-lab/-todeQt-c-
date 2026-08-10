#ifndef FOCUSSESSIONRULES_H
#define FOCUSSESSIONRULES_H

#include <QString>

namespace FocusSessionRules {

// 少于 3 分钟的会话属于误触或测试残留，不进入历史、统计和导出。
inline constexpr int kMinimumValidDurationSeconds = 3 * 60;

// 番茄工作模式在 focus_sessions.mode 里的取值；自由计时(正向计时)是 0。
inline constexpr int kPomodoroMode = 1;

// 一条专注记录计入“实际番茄”，当且仅当：番茄工作模式、自然到点，
// 且时长达到有效专注门槛。手动停止只保留专注时长，不伪装成完整番茄。
// 自由计时只累计专注分钟，不折算番茄。这是“有效番茄”的唯一口径，任务列表聚合、
// 单任务查询和长期目标进度都从这里取；不允许在别处复制出第二套阈值或模式判断。
// 放在本头文件而不是某个服务的匿名命名空间里，就是为了让多个服务能共享同一份定义。
inline QString validPomodoroPredicate(const QString& tableAlias = QString())
{
    const QString prefix = tableAlias.isEmpty() ? QString() : tableAlias + QLatin1Char('.');
    return QStringLiteral(
               "%1pomodoro_completed = 1 AND %1mode = %2 "
               "AND %1duration >= %3")
        .arg(prefix)
        .arg(kPomodoroMode)
        .arg(kMinimumValidDurationSeconds);
}

// 与 predicate 一样接受表别名：多表 JOIN 中的裸列名会在新增同名列后突然变成歧义。
inline QString validPomodoroCountExpr(const QString& tableAlias = QString())
{
    return QStringLiteral("SUM(CASE WHEN %1 THEN 1 ELSE 0 END)")
        .arg(validPomodoroPredicate(tableAlias));
}

// “有效专注秒数”的唯一口径：对计时模式不敏感——番茄段和自由计时都算，
// 只要单段达到有效专注门槛。任务的预计用时、长期目标进度都从这里取。
//
// 这一条与 validPomodoroCountExpr 的差别就是长期目标此前的缺陷所在：目标进度曾经
// 只数完整番茄，用户用自由计时刷再久，目标也纹丝不动。两个口径都留着是因为它们
// 回答的问题不同（“做了几个番茄”与“投入了多久”），但都必须只有这一份定义。
inline QString focusedSecondsExpr(const QString& tableAlias = QString())
{
    const QString column = tableAlias.isEmpty()
        ? QStringLiteral("duration")
        : (tableAlias + QStringLiteral(".duration"));
    return QStringLiteral("SUM(CASE WHEN %1 >= %2 THEN %1 ELSE 0 END)")
        .arg(column)
        .arg(kMinimumValidDurationSeconds);
}

}

#endif // FOCUSSESSIONRULES_H
