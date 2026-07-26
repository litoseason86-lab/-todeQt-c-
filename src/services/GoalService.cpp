#include "GoalService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

#include <algorithm>
#include <cmath>

namespace {

QString dayShift()
{
    // 所有日期比较都必须走逻辑日：dayStartHour 之前的凌晨算前一天。
    // 直接用物理日期会让凌晨专注被算到第二天，进度和活跃天数一起错位。
    return LogicalDay::sqlShift(AppSettings::instance()->dayStartHour());
}

QDate logicalToday()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

}

GoalService::GoalService(QObject* parent)
    : QObject(parent)
{
    // 换库或同路径重开由 DatabaseManager 统一广播；这里只需把建表状态作废，
    // 下一次业务调用时 ensureDatabaseReady 会重新建表。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged, this, [this]() {
        m_databaseReady = false;
        // 数据库切换后目标 id 与进度都属于另一套命名空间，旧缓存绝不能跨库比较。
        m_lastDoneCounts.clear();
        if (initializeDatabase()) {
            emit goalsChanged();
        }
    });
    connect(AppSettings::instance(), &AppSettings::dayStartHourChanged, this, [this]() {
        // 逻辑日起点参与所有进度 SQL。口径变化后旧缓存不能继续比较，
        // 否则下一次专注可能凭空出现 +1，或被旧的较大计数吞掉。
        m_lastDoneCounts.clear();
        emit goalsChanged();
    });

    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (db.isOpen()) {
        initializeDatabase();
    }
}

GoalService* GoalService::instance()
{
    static GoalService service;
    return &service;
}

void GoalService::reportFailure(const QString& message)
{
    qWarning() << "GoalService:" << message;
    emit operationFailed(message);
}

bool GoalService::initializeDatabase()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Cannot initialize long goals: database is not open";
        return false;
    }

    QSqlQuery query(db);
    // 科目被删除时 category_id 置空而不是连目标一起删：用户的目标本体是有价值的，
    // 让他改绑科目，而不是删个科目就丢一个长期目标。
    if (!query.exec(QStringLiteral(
            "CREATE TABLE IF NOT EXISTS long_goals ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "title TEXT NOT NULL CHECK(length(trim(title)) > 0), "
            "category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL, "
            "target_pomodoros INTEGER NOT NULL CHECK(target_pomodoros > 0), "
            "start_date TEXT NOT NULL, "
            "deadline TEXT, "
            "display_order INTEGER NOT NULL DEFAULT 0, "
            "fired_milestones INTEGER NOT NULL DEFAULT 0, "
            "achieved_at TEXT, "
            "created_at TEXT NOT NULL)"))) {
        qWarning() << "Failed to create long_goals table:" << query.lastError().text();
        return false;
    }

    if (!query.exec(QStringLiteral(
            "CREATE INDEX IF NOT EXISTS idx_long_goals_order ON long_goals(display_order)"))) {
        qWarning() << "Failed to create long_goals order index:" << query.lastError().text();
        return false;
    }

    m_databaseReady = true;
    m_databaseName = db.databaseName();
    return true;
}

bool GoalService::ensureDatabaseReady()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        reportFailure(QStringLiteral("数据库未打开"));
        return false;
    }

    // 已经在当前库上建过表就直接放行，不必每次业务调用都执行一遍 CREATE TABLE。
    if (m_databaseReady && m_databaseName == db.databaseName()) {
        return true;
    }

    if (!initializeDatabase()) {
        reportFailure(QStringLiteral("初始化长期目标数据表失败"));
        return false;
    }
    return true;
}

QString GoalService::goalSelectSql() const
{
    // 进度不存库，每次查询现算；有效会话先在 CTE 中归一成“科目 + 逻辑日”，
    // 再一次性聚合全部目标的完成数和活跃日，避免目标越多 SQL 往返次数越多。
    // 这样删掉一条专注记录后进度自动回退，不存在“奖励状态和真实数据对不上”的可能。
    // 口径：会话快照科目、自然完成番茄、时长达标、且落在起始逻辑日之后。
    // 番茄的判定表达式从 FocusSessionRules 取，与任务列表用的是同一份定义。
    return QStringLiteral(
        "WITH valid_sessions AS ("
        "SELECT COALESCE(fs.category_id_snapshot, t.category_id) AS category_id, "
        "date(fs.start_time, :dayShift) AS logical_day "
        "FROM focus_sessions fs "
        "LEFT JOIN tasks t ON fs.task_id = t.id "
        "WHERE %1) "
        "SELECT g.id, g.title, g.category_id, "
        "c.name AS category_name, c.color AS category_color, "
        "g.target_pomodoros, g.start_date, g.deadline, g.display_order, "
        "g.fired_milestones, g.achieved_at, g.created_at, "
        "COUNT(v.logical_day) AS done_count, "
        "COUNT(DISTINCT v.logical_day) AS active_days "
        "FROM long_goals g "
        "LEFT JOIN categories c ON g.category_id = c.id "
        "LEFT JOIN valid_sessions v ON v.category_id = g.category_id "
        "AND v.logical_day >= g.start_date ")
        .arg(FocusSessionRules::validPomodoroPredicate(QStringLiteral("fs")));
}

QList<LongGoal> GoalService::loadGoals(std::optional<int> singleGoalId, bool* ok)
{
    QList<LongGoal> goals;
    if (ok) {
        *ok = false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return goals;
    }

    QString sql = goalSelectSql();
    if (singleGoalId.has_value()) {
        sql += QStringLiteral("WHERE g.id = :goalId ");
    }
    sql += QStringLiteral("GROUP BY g.id ORDER BY g.display_order ASC, g.id ASC");

    QSqlQuery query(db);
    query.prepare(sql);
    query.bindValue(QStringLiteral(":dayShift"), dayShift());
    if (singleGoalId.has_value()) {
        query.bindValue(QStringLiteral(":goalId"), *singleGoalId);
    }

    if (!query.exec()) {
        reportFailure(QStringLiteral("读取长期目标失败: ") + query.lastError().text());
        return goals;
    }

    while (query.next()) {
        goals.append(LongGoal::fromQuery(query));
    }
    if (ok) {
        *ok = true;
    }
    return goals;
}

int GoalService::forecastDaysFor(const LongGoal& goal, int activeDays) const
{
    const int remain = goal.targetPomodoros - goal.doneCount;
    if (remain <= 0) {
        return 0;
    }
    if (activeDays <= 0 || goal.doneCount <= 0) {
        // 还没有任何有效番茄，无从推算速度。界面据此隐藏这一行，而不是显示一个编造的天数。
        return -1;
    }

    const double rate = static_cast<double>(goal.doneCount) / static_cast<double>(activeDays);
    return static_cast<int>(std::ceil(static_cast<double>(remain) / rate));
}

QVariantList GoalService::getGoals()
{
    QVariantList result;
    if (!ensureDatabaseReady()) {
        return result;
    }

    const QList<LongGoal> goals = loadGoals(std::nullopt);
    for (const LongGoal& goal : goals) {
        LongGoal filled = goal;
        filled.forecastDays = forecastDaysFor(filled, filled.activeDays);
        result.append(filled.toVariantMap());
    }
    return result;
}

QVariantMap GoalService::getGoal(int goalId)
{
    if (goalId <= 0) {
        reportFailure(QStringLiteral("目标编号无效"));
        return QVariantMap();
    }
    if (!ensureDatabaseReady()) {
        return QVariantMap();
    }

    bool loadOk = false;
    const QList<LongGoal> goals = loadGoals(goalId, &loadOk);
    if (!loadOk) {
        reportFailure(QStringLiteral("读取目标失败，请重试"));
        return QVariantMap();
    }
    if (goals.isEmpty()) {
        return QVariantMap();
    }

    LongGoal filled = goals.first();
    filled.forecastDays = forecastDaysFor(filled, filled.activeDays);
    return filled.toVariantMap();
}

QVariantList GoalService::getGoalDailyCounts(int goalId, int year, int month)
{
    QVariantList result;
    if (!ensureDatabaseReady()) {
        return result;
    }

    const QDate monthFirst(year, month, 1);
    if (goalId <= 0 || !monthFirst.isValid()) {
        reportFailure(QStringLiteral("目标或月份参数无效"));
        return result;
    }

    bool loadOk = false;
    const QList<LongGoal> goals = loadGoals(goalId, &loadOk);
    if (!loadOk) {
        // loadGoals 已报告底层 SQL 错误，这里补充业务上下文，调用方仍统一收到空数组。
        reportFailure(QStringLiteral("读取目标热力数据失败"));
        return result;
    }
    if (goals.isEmpty()) {
        reportFailure(QStringLiteral("目标不存在"));
        return result;
    }

    const LongGoal& goal = goals.first();
    if (goal.categoryId <= 0 || !goal.startDate.isValid()) {
        reportFailure(QStringLiteral("目标缺少有效科目或起始日期"));
        return result;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    // 科目口径必须优先使用会话快照：任务后来改科目或被删除，都不能改写历史归属。
    // 有效番茄表达式直接取 FocusSessionRules，避免热力图另造时长阈值。
    query.prepare(QStringLiteral(
        "SELECT date(fs.start_time, :dayShift) AS logical_day, %1 AS count "
        "FROM focus_sessions fs "
        "LEFT JOIN tasks t ON fs.task_id = t.id "
        "WHERE COALESCE(fs.category_id_snapshot, t.category_id) = :categoryId "
        "AND fs.duration IS NOT NULL "
        "AND date(fs.start_time, :dayShift) >= :startDate "
        "AND date(fs.start_time, :dayShift) BETWEEN :monthFirst AND :monthLast "
        "GROUP BY logical_day "
        "ORDER BY logical_day ASC")
                      .arg(FocusSessionRules::validPomodoroCountExpr(QStringLiteral("fs"))));
    query.bindValue(QStringLiteral(":dayShift"), dayShift());
    query.bindValue(QStringLiteral(":categoryId"), goal.categoryId);
    query.bindValue(QStringLiteral(":startDate"), goal.startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":monthFirst"), monthFirst.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":monthLast"),
                    QDate(year, month, monthFirst.daysInMonth()).toString(Qt::ISODate));

    if (!query.exec()) {
        reportFailure(QStringLiteral("统计目标每日番茄失败: ") + query.lastError().text());
        return result;
    }

    while (query.next()) {
        const int count = query.value(1).toInt();
        if (count <= 0) {
            // 该日可能只有无效会话；接口契约只返回真正点亮热力格的日期。
            continue;
        }
        const QDate date = QDate::fromString(query.value(0).toString(), Qt::ISODate);
        if (!date.isValid()) {
            continue;
        }
        QVariantMap entry;
        entry.insert(QStringLiteral("day"), date.day());
        entry.insert(QStringLiteral("count"), count);
        result.append(entry);
    }
    return result;
}

bool GoalService::validateInput(const QString& title,
                                int categoryId,
                                int targetPomodoros,
                                QString* normalizedTitle)
{
    const QString trimmed = title.trimmed();
    if (trimmed.isEmpty()) {
        reportFailure(QStringLiteral("目标名称不能为空"));
        return false;
    }
    if (trimmed.length() > kMaxTitleLength) {
        // 与任务标题一致：拒绝而不是截断，避免用户以为存下去了却少了一截。
        reportFailure(QStringLiteral("目标名称不能超过 %1 个字").arg(kMaxTitleLength));
        return false;
    }
    if (targetPomodoros <= 0 || targetPomodoros > kMaxTargetPomodoros) {
        reportFailure(QStringLiteral("目标番茄数需在 1 到 %1 之间").arg(kMaxTargetPomodoros));
        return false;
    }

    // 进度只统计所绑科目下的专注记录，没有科目的目标进度恒为 0、里程碑永不触发，
    // 表现和"功能坏了"完全一样。所以科目在写入路径是必填项，宁可拒绝也不要静默存成 NULL。
    // 读取路径不做这个校验：科目被删除时外键会把已有目标的 category_id 置空，
    // 这些存量目标必须仍能被读出来并改绑。
    if (categoryId <= 0) {
        reportFailure(QStringLiteral("请先为目标选择科目"));
        return false;
    }

    *normalizedTitle = trimmed;
    return true;
}

QDate GoalService::resolveStartDate(const QVariant& startDateValue) const
{
    const QDate parsed = startDateValue.toDate();
    // 传空或非法日期时落到当前逻辑日；填过去的日期可以把已有专注记录回填成进度。
    return parsed.isValid() ? parsed : logicalToday();
}

bool GoalService::addGoal(const QString& title,
                          int categoryId,
                          int targetPomodoros,
                          const QVariant& startDateValue,
                          const QVariant& deadlineValue)
{
    QString normalizedTitle;
    if (!validateInput(title, categoryId, targetPomodoros, &normalizedTitle)) {
        return false;
    }
    if (!ensureDatabaseReady()) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), -1) + 1 FROM long_goals"))
        || !orderQuery.next()) {
        reportFailure(QStringLiteral("获取目标排序失败: ") + orderQuery.lastError().text());
        return false;
    }
    const int displayOrder = orderQuery.value(0).toInt();

    const QDate startDate = resolveStartDate(startDateValue);
    const QDate deadline = deadlineValue.toDate();

    // 插入目标行与对齐里程碑掩码必须同生共死：只落库不对齐的话，
    // 用户下一次完成任意番茄时，refreshMilestones 会把"建目标之前就做完的历史"
    // 当成刚刚达成，一次性弹出最高档庆祝。
    if (!db.transaction()) {
        reportFailure(QStringLiteral("新建目标开启事务失败: ") + db.lastError().text());
        return false;
    }

    QSqlQuery insertQuery(db);
    insertQuery.prepare(QStringLiteral(
        "INSERT INTO long_goals "
        "(title, category_id, target_pomodoros, start_date, deadline, display_order, "
        "fired_milestones, achieved_at, created_at) "
        "VALUES (:title, :categoryId, :target, :startDate, :deadline, :displayOrder, "
        "0, NULL, :createdAt)"));
    insertQuery.bindValue(QStringLiteral(":title"), normalizedTitle);
    insertQuery.bindValue(QStringLiteral(":categoryId"),
                          categoryId > 0 ? QVariant(categoryId) : QVariant());
    insertQuery.bindValue(QStringLiteral(":target"), targetPomodoros);
    insertQuery.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    insertQuery.bindValue(QStringLiteral(":deadline"),
                          deadline.isValid() ? QVariant(deadline.toString(Qt::ISODate)) : QVariant());
    insertQuery.bindValue(QStringLiteral(":displayOrder"), displayOrder);
    insertQuery.bindValue(QStringLiteral(":createdAt"),
                          QDateTime::currentDateTime().toString(Qt::ISODate));

    if (!insertQuery.exec()) {
        const QString error = insertQuery.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("新建目标失败: ") + error);
        return false;
    }

    // 新目标可能因为起始日回填而立刻就有进度，甚至一建出来就已达标。
    // 这里先对齐一次里程碑，避免把“建目标之前就完成的部分”当成新达成连弹几个窗。
    const int newId = insertQuery.lastInsertId().toInt();
    bool loadOk = false;
    const QList<LongGoal> created = loadGoals(newId, &loadOk);
    if (!loadOk || created.isEmpty()) {
        db.rollback();
        reportFailure(QStringLiteral("新建目标后回读失败，已撤销本次新建"));
        return false;
    }

    const LongGoal& goal = created.first();
    const int mask = LongGoal::milestonesForProgress(goal.doneCount, goal.targetPomodoros);
    if (mask != 0) {
        QSqlQuery seedQuery(db);
        seedQuery.prepare(QStringLiteral(
            "UPDATE long_goals SET fired_milestones = :mask, "
            "achieved_at = CASE WHEN :achieved = 1 THEN :now ELSE achieved_at END "
            "WHERE id = :id"));
        seedQuery.bindValue(QStringLiteral(":mask"), mask);
        seedQuery.bindValue(QStringLiteral(":achieved"),
                            (mask & LongGoal::Milestone100) ? 1 : 0);
        seedQuery.bindValue(QStringLiteral(":now"),
                            QDateTime::currentDateTime().toString(Qt::ISODate));
        seedQuery.bindValue(QStringLiteral(":id"), newId);
        if (!seedQuery.exec()) {
            const QString error = seedQuery.lastError().text();
            db.rollback();
            reportFailure(QStringLiteral("初始化目标里程碑失败: ") + error);
            return false;
        }
    }

    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("新建目标提交失败: ") + error);
        return false;
    }

    emit goalsChanged();
    return true;
}

bool GoalService::updateGoal(int goalId,
                             const QString& title,
                             int categoryId,
                             int targetPomodoros,
                             const QVariant& startDateValue,
                             const QVariant& deadlineValue)
{
    if (goalId <= 0) {
        reportFailure(QStringLiteral("目标编号无效"));
        return false;
    }
    QString normalizedTitle;
    if (!validateInput(title, categoryId, targetPomodoros, &normalizedTitle)) {
        return false;
    }
    if (!ensureDatabaseReady()) {
        return false;
    }

    bool loadOk = false;
    const QList<LongGoal> existing = loadGoals(goalId, &loadOk);
    if (!loadOk) {
        // 读取本身失败时不能说"目标不存在"，否则用户可能重建一个本来存在的目标。
        reportFailure(QStringLiteral("读取目标失败，请重试"));
        return false;
    }
    if (existing.isEmpty()) {
        reportFailure(QStringLiteral("目标不存在"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    const QDate startDate = resolveStartDate(startDateValue);
    const QDate deadline = deadlineValue.toDate();

    // 主字段与派生里程碑是一个业务操作：任一写入失败都必须回滚，
    // 否则会出现“新目标值 + 旧奖励状态”的半成品。
    if (!db.transaction()) {
        reportFailure(QStringLiteral("更新目标开启事务失败: ") + db.lastError().text());
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE long_goals SET title = :title, category_id = :categoryId, "
        "target_pomodoros = :target, start_date = :startDate, deadline = :deadline "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":categoryId"),
                    categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":target"), targetPomodoros);
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":deadline"),
                    deadline.isValid() ? QVariant(deadline.toString(Qt::ISODate)) : QVariant());
    query.bindValue(QStringLiteral(":id"), goalId);

    if (!query.exec()) {
        const QString error = query.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("更新目标失败: ") + error);
        return false;
    }

    bool updatedOk = false;
    const QList<LongGoal> updated = loadGoals(goalId, &updatedOk);
    if (!updatedOk || updated.isEmpty()) {
        db.rollback();
        reportFailure(QStringLiteral("更新目标后回读失败，已撤销本次修改"));
        return false;
    }

    // 标题和截止日不参与进度口径，编辑它们时必须原样保留奖励位。
    // 只有目标值、科目或起始日变化，才允许按新口径重新对齐里程碑。
    const LongGoal& goal = updated.first();
    const LongGoal& oldGoal = existing.first();
    const bool progressDefinitionChanged = oldGoal.categoryId != goal.categoryId
        || oldGoal.targetPomodoros != goal.targetPomodoros
        || oldGoal.startDate != goal.startDate;
    const int mask = progressDefinitionChanged
        ? LongGoal::milestonesForProgress(goal.doneCount, goal.targetPomodoros)
        : oldGoal.firedMilestones;
    const int newBits = progressDefinitionChanged
        ? mask & ~oldGoal.firedMilestones
        : 0;
    const bool achievedNow = (newBits & LongGoal::Milestone100) != 0;

    QSqlQuery maskQuery(db);
    maskQuery.prepare(QStringLiteral(
        "UPDATE long_goals SET fired_milestones = :mask, "
        "achieved_at = CASE WHEN :achievedNow = 1 AND achieved_at IS NULL "
        "THEN :now ELSE achieved_at END WHERE id = :id"));
    maskQuery.bindValue(QStringLiteral(":mask"), mask);
    maskQuery.bindValue(QStringLiteral(":achievedNow"), achievedNow ? 1 : 0);
    maskQuery.bindValue(QStringLiteral(":now"),
                        QDateTime::currentDateTime().toString(Qt::ISODate));
    maskQuery.bindValue(QStringLiteral(":id"), goalId);
    if (!maskQuery.exec()) {
        const QString error = maskQuery.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("重算目标里程碑失败: ") + error);
        return false;
    }

    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("更新目标提交失败: ") + error);
        return false;
    }

    // 编辑可能改变进度聚合口径。提交成功后立即以新值重建基线，
    // 下一次真实番茄才能准确判断“是否前进”。
    m_lastDoneCounts.insert(goalId, goal.doneCount);
    emit goalsChanged();
    if (newBits != 0) {
        int highest = 0;
        for (int i = 0; i < 4; ++i) {
            if (newBits & (1 << i)) {
                highest = LongGoal::kMilestonePercents[i];
            }
        }
        emit milestoneReached(goal.id, goal.title, highest);
    }
    return true;
}

bool GoalService::deleteGoal(int goalId)
{
    if (!ensureDatabaseReady()) {
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM long_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), goalId);

    if (!query.exec()) {
        reportFailure(QStringLiteral("删除目标失败: ") + query.lastError().text());
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        reportFailure(QStringLiteral("目标不存在"));
        return false;
    }

    m_lastDoneCounts.remove(goalId);
    emit goalsChanged();
    return true;
}

bool GoalService::reorderGoal(int fromIndex, int toIndex)
{
    if (fromIndex == toIndex) {
        return true;
    }
    if (!ensureDatabaseReady()) {
        return false;
    }

    QList<LongGoal> goals = loadGoals(std::nullopt);
    if (fromIndex < 0 || fromIndex >= goals.size() || toIndex < 0 || toIndex >= goals.size()) {
        reportFailure(QStringLiteral("目标排序下标越界"));
        return false;
    }

    goals.move(fromIndex, toIndex);

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        reportFailure(QStringLiteral("目标排序开启事务失败: ") + db.lastError().text());
        return false;
    }

    // 整表重写 display_order：目标数量是个位数量级，比维护稀疏序号简单且不会退化。
    for (int i = 0; i < goals.size(); ++i) {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("UPDATE long_goals SET display_order = :order WHERE id = :id"));
        query.bindValue(QStringLiteral(":order"), i);
        query.bindValue(QStringLiteral(":id"), goals.at(i).id);
        if (!query.exec()) {
            const QString error = query.lastError().text();
            db.rollback();
            reportFailure(QStringLiteral("目标排序失败: ") + error);
            return false;
        }
    }

    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("目标排序提交失败: ") + error);
        return false;
    }

    emit goalsChanged();
    return true;
}

void GoalService::refreshMilestones()
{
    if (!ensureDatabaseReady()) {
        return;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    bool loadOk = false;
    const QList<LongGoal> goals = loadGoals(std::nullopt, &loadOk);
    if (!loadOk) {
        return;
    }

    for (const LongGoal& goal : goals) {
        const bool hasPreviousCount = m_lastDoneCounts.contains(goal.id);
        const int previousCount = m_lastDoneCounts.value(goal.id, -1);
        // 先写缓存再发同步信号，避免接收方重入 refreshMilestones 时重复发同一推进。
        m_lastDoneCounts.insert(goal.id, goal.doneCount);
        if (hasPreviousCount && goal.doneCount > previousCount) {
            emit goalProgressed(goal.id, goal.title, goal.doneCount, goal.targetPomodoros);
        }
        // 无条件写回：进度回退后再涨回也属于一次真实推进，应该重新出现轻量 Toast。

        const int mask = LongGoal::milestonesForProgress(goal.doneCount, goal.targetPomodoros);
        // 只做按位或，绝不清位：进度回退（比如删掉几条专注记录）再涨回来时不该重复庆祝。
        // 需要清位的只有用户主动改变进度口径（目标值、科目、起始日），
        // 那条路径在 updateGoal 里单独处理。
        const int newBits = mask & ~goal.firedMilestones;
        if (newBits == 0) {
            continue;
        }

        const int merged = goal.firedMilestones | mask;
        const bool achievedNow = (newBits & LongGoal::Milestone100) != 0;

        QSqlQuery query(db);
        query.prepare(QStringLiteral(
            "UPDATE long_goals SET fired_milestones = :mask, "
            "achieved_at = CASE WHEN :achievedNow = 1 AND achieved_at IS NULL "
            "THEN :now ELSE achieved_at END "
            "WHERE id = :id"));
        query.bindValue(QStringLiteral(":mask"), merged);
        query.bindValue(QStringLiteral(":achievedNow"), achievedNow ? 1 : 0);
        query.bindValue(QStringLiteral(":now"), QDateTime::currentDateTime().toString(Qt::ISODate));
        query.bindValue(QStringLiteral(":id"), goal.id);
        if (!query.exec()) {
            reportFailure(QStringLiteral("记录目标里程碑失败: ") + query.lastError().text());
            continue;
        }

        // 一次刷新可能同时跨过好几档（例如一次性导入大量历史记录）。
        // 这种情况只报最高的一档，避免连弹四个庆祝窗。
        int highest = 0;
        for (int i = 0; i < 4; ++i) {
            if (newBits & (1 << i)) {
                highest = LongGoal::kMilestonePercents[i];
            }
        }
        emit milestoneReached(goal.id, goal.title, highest);
    }

    // doneCount、百分比、预测和热力都是查询时派生值，没有数据库行可替它们发变更通知。
    // 每轮重算结束统一失效一次，目标页即使正打开也不会继续展示旧进度。
    emit goalsChanged();
}
