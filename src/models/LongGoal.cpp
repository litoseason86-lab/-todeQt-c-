#include "LongGoal.h"

#include <QSqlRecord>
#include <QTimeZone>

#include <algorithm>
#include <cmath>

namespace {
QVariant valueByName(const QSqlQuery& query, const char* name)
{
    // 与 Task::fromQuery 同一套按列名取值的做法：列顺序变化不会破坏映射。
    const int index = query.record().indexOf(QLatin1String(name));
    return index >= 0 ? query.value(index) : QVariant();
}

QDateTime parseStoredDateTime(const QString& value)
{
    if (value.isEmpty()) {
        return QDateTime();
    }
    QDateTime dateTime = QDateTime::fromString(value, Qt::ISODate);
    if (dateTime.isValid()) {
        return dateTime;
    }
    // SQLite 的 CURRENT_TIMESTAMP 是空格分隔且按标准为 UTC，先标记时区再转本地。
    dateTime = QDateTime::fromString(value, QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    if (dateTime.isValid()) {
        dateTime.setTimeZone(QTimeZone::UTC);
        dateTime = dateTime.toLocalTime();
    }
    return dateTime;
}
}

int LongGoal::percentOf(int doneMinutes, int targetMinutes)
{
    if (targetMinutes <= 0) {
        return 0;
    }
    // 上限夹到 100：超额完成仍然只显示 100%，避免出现 130% 这种没有意义的进度。
    const int raw = static_cast<int>(std::llround(
        static_cast<double>(doneMinutes) / static_cast<double>(targetMinutes) * 100.0));
    return std::clamp(raw, 0, 100);
}

int LongGoal::percent() const
{
    return percentOf(doneMinutes, targetMinutes);
}

int LongGoal::milestonesForProgress(int doneMinutes, int targetMinutes)
{
    if (targetMinutes <= 0) {
        return 0;
    }

    // 注意这里用整除比较而不是先算百分比再比较：先四舍五入会让 74.6% 被当成 75% 达标。
    // 里程碑必须是真的做够了 target*25% 个番茄才算，宁可晚一个番茄，不能提前庆祝。
    int mask = 0;
    for (int i = 0; i < 4; ++i) {
        const int percent = kMilestonePercents[i];
        // 达标所需番茄数向上取整：target=10、percent=25 时需要 3 个而不是 2.5 个。
        const int needed = (targetMinutes * percent + 99) / 100;
        if (doneMinutes >= needed) {
            mask |= (1 << i);
        }
    }
    return mask;
}

LongGoal LongGoal::fromQuery(const QSqlQuery& query)
{
    LongGoal goal;
    goal.id = valueByName(query, "id").toInt();
    goal.title = valueByName(query, "title").toString();

    const QVariant categoryIdValue = valueByName(query, "category_id");
    if (categoryIdValue.isValid() && !categoryIdValue.isNull()) {
        goal.categoryId = categoryIdValue.toInt();
    }
    goal.categoryName = valueByName(query, "category_name").toString();
    goal.categoryColor = valueByName(query, "category_color").toString();

    goal.targetMinutes = valueByName(query, "target_minutes").toInt();
    goal.startDate = QDate::fromString(valueByName(query, "start_date").toString(), Qt::ISODate);

    const QString deadlineText = valueByName(query, "deadline").toString();
    if (!deadlineText.isEmpty()) {
        goal.deadline = QDate::fromString(deadlineText, Qt::ISODate);
    }

    goal.displayOrder = valueByName(query, "display_order").toInt();
    goal.firedMilestones = valueByName(query, "fired_milestones").toInt();
    goal.achievedAt = parseStoredDateTime(valueByName(query, "achieved_at").toString());
    goal.createdAt = parseStoredDateTime(valueByName(query, "created_at").toString());

    // done_count 只有带聚合子查询的列表查询才有；缺列时 toInt() 得 0，
    // 不会破坏只读取目标本体的查询。
    goal.doneMinutes = valueByName(query, "done_minutes").toInt();
    goal.activeDays = valueByName(query, "active_days").toInt();
    return goal;
}

QVariantMap LongGoal::toVariantMap() const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), id);
    map.insert(QStringLiteral("title"), title);
    map.insert(QStringLiteral("categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    map.insert(QStringLiteral("categoryName"), categoryName);
    map.insert(QStringLiteral("categoryColor"), categoryColor);
    map.insert(QStringLiteral("targetMinutes"), targetMinutes);
    map.insert(QStringLiteral("startDate"), startDate);
    // 截止日为空时给 QML 一个无效 QVariant，界面据此显示“长期目标”。
    map.insert(QStringLiteral("deadline"), deadline.isValid() ? QVariant(deadline) : QVariant());
    map.insert(QStringLiteral("displayOrder"), displayOrder);
    map.insert(QStringLiteral("firedMilestones"), firedMilestones);
    map.insert(QStringLiteral("achievedAt"), achievedAt.isValid() ? QVariant(achievedAt) : QVariant());
    map.insert(QStringLiteral("createdAt"), createdAt);
    map.insert(QStringLiteral("doneMinutes"), doneMinutes);
    map.insert(QStringLiteral("percent"), percent());
    map.insert(QStringLiteral("achieved"), isAchieved());
    map.insert(QStringLiteral("forecastDays"), forecastDays);
    return map;
}
