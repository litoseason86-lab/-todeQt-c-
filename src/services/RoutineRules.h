#ifndef ROUTINERULES_H
#define ROUTINERULES_H

// 每日例行的重复规则：一条例行不必每天生成，可以只落在一周中的某几天。
// 星期编号沿用 QDate::dayOfWeek()（周一=1 … 周日=7），与课表同一套口径，
// 避免两个功能对「星期几」各有一种解释。
namespace RoutineRules {

// 重复日用位掩码存：第 0 位是周一，第 6 位是周日。
// 选整数掩码而不是七个布尔列，是为了让「今天要不要生成」在 SQL 里一次位与就能判完，
// 生成查询不必按星期分支。
inline constexpr int kEveryDayMask = 0x7F;  // 二进制 1111111：一周七天全选

// 掩码至少要命中一天。0 表示这条例行永远不会生成任务，是一种看不出原因的坏状态：
// 用户以为保存成功了，任务却再也不出现。库层 CHECK 和服务层校验都直接拒绝它。
inline constexpr int kMinWeekdayMask = 1;
inline constexpr int kMaxWeekdayMask = kEveryDayMask;

inline constexpr bool isValidWeekdayMask(int mask)
{
    return mask >= kMinWeekdayMask && mask <= kMaxWeekdayMask;
}

// dayOfWeek 取 QDate::dayOfWeek() 的返回值（1–7）。越界返回 0，
// 与任何合法掩码相与都是 0，调用方据此判定「今天不生成」，不需要额外的错误分支。
inline constexpr int maskForDayOfWeek(int dayOfWeek)
{
    return (dayOfWeek >= 1 && dayOfWeek <= 7) ? (1 << (dayOfWeek - 1)) : 0;
}

}

#endif // ROUTINERULES_H
