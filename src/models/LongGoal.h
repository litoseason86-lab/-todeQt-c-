#ifndef LONGGOAL_H
#define LONGGOAL_H

#include <QDate>
#include <QDateTime>
#include <QSqlQuery>
#include <QString>
#include <QVariantMap>

// 长期目标：跨月累积的“某科目做够 N 个番茄”。
// 和 Task（只活一天）、CountdownGoal（只有日期没有数量）并列，补的是“带数量的长期目标”这一格。
//
// 关键约定：本结构体不存已完成数量。进度一律由 focus_sessions 现算，
// 保证删掉一条专注记录后进度自动回退，不存在“奖励状态和真实数据对不上”的可能。
// 只有 firedMilestones 是例外——它记录的不是进度，而是“哪几档庆祝已经弹过了”。
class LongGoal
{
public:
    // 里程碑位掩码的四个档位。用位掩码而不是“上次百分比”，
    // 是为了让进度回退再涨回来时不会重复弹窗（撤销专注记录后再补上属于正常操作）。
    enum MilestoneBit {
        Milestone25 = 1 << 0,
        Milestone50 = 1 << 1,
        Milestone75 = 1 << 2,
        Milestone100 = 1 << 3
    };

    // 四个档位对应的百分比阈值，与 MilestoneBit 一一对应且顺序一致。
    static constexpr int kMilestonePercents[4] = { 25, 50, 75, 100 };

    int id = -1;
    QString title;
    // 目标绑定的科目；进度只统计该科目下任务的专注记录。
    // 科目被删除时置空（外键 ON DELETE SET NULL），此时进度恒为 0，但目标本身保留，
    // 让用户能改绑而不是连目标一起消失。
    int categoryId = -1;
    QString categoryName;
    QString categoryColor;
    int targetPomodoros = 0;
    // 起始逻辑日：只有这天（含）之后的专注记录才算进度。
    // 填过去的日期即可把已有历史记录回填进来，新建目标当场就有进度。
    QDate startDate;
    // 截止日为空表示长期目标，不做逾期处理，只影响文案。
    QDate deadline;
    int displayOrder = 0;
    int firedMilestones = 0;
    // 首次达成 100% 的时刻；为空表示尚未达成。进度回退不会清空它，
    // “曾经达成过”是事实，不该因为后来删了几条记录就被抹掉。
    QDateTime achievedAt;
    QDateTime createdAt;

    // 以下三个字段不来自 long_goals 表，由 GoalService 聚合后填入，仅用于交给界面。
    int doneCount = 0;
    // 预测分母只统计真正做过有效番茄的逻辑日，由同一条聚合查询计算，不暴露给界面。
    int activeDays = 0;
    // 照当前速度预计还需多少天；无法预测（尚无任何记录）时为 -1，已达成时为 0。
    int forecastDays = -1;

    bool isAchieved() const { return targetPomodoros > 0 && doneCount >= targetPomodoros; }
    int percent() const;

    // percentOf 供里程碑判定复用，避免在服务层重复写同一个夹紧逻辑。
    static int percentOf(int doneCount, int targetPomodoros);
    // 给定完成数应当点亮的位掩码；只看当前进度，不关心历史。
    static int milestonesForProgress(int doneCount, int targetPomodoros);

    static LongGoal fromQuery(const QSqlQuery& query);
    QVariantMap toVariantMap() const;
};

#endif // LONGGOAL_H
