#include "TaskManager.h"

#include "../models/Task.h"
#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDebug>
#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

namespace {
bool isValidTaskId(int taskId)
{
    return taskId > 0;
}

QDate normalizeDate(const QVariant& value)
{
    // QML 会传 Date，测试常传字符串，C++ 调用方也可能直接传 QDate。
    if (value.canConvert<QDate>()) {
        const QDate date = value.toDate();
        if (date.isValid()) {
            return date;
        }
    }

    if (value.canConvert<QDateTime>()) {
        const QDateTime dateTime = value.toDateTime();
        if (dateTime.isValid()) {
            return dateTime.date();
        }
    }

    const QString text = value.toString().trimmed();
    if (!text.isEmpty()) {
        const QDate isoDate = QDate::fromString(text, Qt::ISODate);
        if (isoDate.isValid()) {
            return isoDate;
        }

        const QDateTime isoDateTime = QDateTime::fromString(text, Qt::ISODate);
        if (isoDateTime.isValid()) {
            return isoDateTime.date();
        }
    }

    return QDate();
}

int clampEstimatedMinutes(int value)
{
    // 越界一律夹紧：负数当未设置，超上限压到上限，绝不因预估值让任务本体保存失败。
    return qBound(0, value, TaskManager::kMaxEstimatedMinutes);
}

// “有效番茄”的口径已上移到 FocusSessionRules，长期目标进度要复用同一份定义。
// 这里保留一个同名薄封装，只是为了让本文件原有调用点不必逐个改写。
QString validPomodoroCountExpr(const QString& tableAlias = QString())
{
    return FocusSessionRules::validPomodoroCountExpr(tableAlias);
}

// “有效专注秒数”同样上移到 FocusSessionRules——长期目标进度也要用同一份定义。
// 这里保留同名薄封装，只是为了让本文件原有调用点不必逐个改写。
QString focusedSecondsExpr(const QString& tableAlias = QString())
{
    return FocusSessionRules::focusedSecondsExpr(tableAlias);
}

QString taskSelectSql()
{
    // 同时返回标准化科目字段和旧版文本科目，让旧数据库和新 UI 共用同一查询结果。
    // 日期条件先利用 tasks 索引筛出当前页面任务，再按 task_id 走专注记录索引聚合。
    // 若先把整张 focus_sessions 分组物化，历史记录越多，每次打开任务页都会线性变慢。
    return QStringLiteral(
        "SELECT t.id, t.title, "
        "COALESCE(c.name, t.category) AS category, "
        "t.category_id, c.name AS category_name, c.color AS category_color, "
        "t.date, t.completed, t.created_at, t.estimated_minutes, t.notes, t.display_order, "
        "COALESCE((SELECT %1 FROM focus_sessions fs "
        "WHERE fs.task_id = t.id AND fs.duration IS NOT NULL), 0) AS actual_pomodoros, "
        "COALESCE((SELECT %2 FROM focus_sessions fs "
        "WHERE fs.task_id = t.id AND fs.duration IS NOT NULL), 0) AS focused_seconds "
        "FROM tasks t "
        "LEFT JOIN categories c ON t.category_id = c.id ")
        .arg(validPomodoroCountExpr(QStringLiteral("fs")), focusedSecondsExpr());
}

bool bindCategoryTextFromId(QSqlQuery& query, int categoryId, QString* categoryName)
{
    if (categoryId <= 0) {
        *categoryName = QString();
        return true;
    }

    query.prepare(QStringLiteral("SELECT name FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), categoryId);
    if (!query.exec()) {
        qWarning() << "Failed to look up category for task:" << query.lastError().text();
        return false;
    }

    if (!query.next()) {
        qWarning() << "Failed to add task: category not found" << categoryId;
        return false;
    }

    *categoryName = query.value(0).toString();
    return true;
}
}

TaskManager::TaskManager(QObject* parent)
    : QObject(parent)
{
    // 数据库整体恢复后，所有 QML 列表快照必须失效；否则旧任务 ID 会继续作用于新库。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &TaskManager::tasksChanged);
}

TaskManager* TaskManager::instance()
{
    static TaskManager manager;
    return &manager;
}

void TaskManager::reportFailure(const QString& message) const
{
    emit const_cast<TaskManager*>(this)->operationFailed(message);
}

bool TaskManager::addTask(const QString& title, const QVariant& dateValue, const QString& category)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to add task: title is empty after trimming";
        return false;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to add task: title exceeds" << kMaxTitleLength << "characters";
        return false;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to add task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add task: database is not open";
        return false;
    }

    QString normalizedCategory = category.trimmed();
    QVariant categoryIdValue;
    if (!normalizedCategory.isEmpty()) {
        QSqlQuery categoryQuery(db);
        categoryQuery.prepare(QStringLiteral("SELECT id FROM categories WHERE name = :name"));
        categoryQuery.bindValue(QStringLiteral(":name"), normalizedCategory);
        if (!categoryQuery.exec()) {
            qWarning() << "Failed to look up task category:" << categoryQuery.lastError().text();
            return false;
        }
        if (categoryQuery.next()) {
            categoryIdValue = categoryQuery.value(0).toInt();
        }
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, date, completed) "
        "VALUES (:title, :category, :categoryId, :date, 0)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), normalizedCategory);
    query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::addTask(const QString& title, const QVariant& dateValue, int categoryId)
{
    return addTask(title, dateValue, categoryId, 0);
}

bool TaskManager::addTask(const QString& title, const QVariant& dateValue,
                          int categoryId, int estimatedMinutes)
{
    return addTask(title, dateValue, categoryId, estimatedMinutes, QString());
}

bool TaskManager::addTask(const QString& title, const QVariant& dateValue,
                          int categoryId, int estimatedMinutes, const QString& notes)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to add task: title is empty after trimming";
        return false;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to add task: title exceeds" << kMaxTitleLength << "characters";
        return false;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to add task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add task: database is not open";
        return false;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (categoryId > 0) {
        QSqlQuery categoryQuery(db);
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName)) {
            return false;
        }
        categoryIdValue = categoryId;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, date, completed, "
        "estimated_minutes, notes, display_order) "
        // display_order 取当天最大值 +1：新任务排在末尾，不会插到用户排好的序列中间。
        // 该日期还没有任务时 MAX 返回 NULL，COALESCE 回落到 0。
        // 占位符不能重名：Qt 对同名具名占位符的处理依赖驱动，SQLite 下只会绑上第一处，
        // 第二处留空导致整条 INSERT 失败。子查询里的日期单独取名。
        "VALUES (:title, :category, :categoryId, :date, 0, :estimated, :notes, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), categoryName);
    query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":orderDate"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":estimated"), clampEstimatedMinutes(estimatedMinutes));
    // 空 QString 是 null，直接绑会写成 NULL 并撞上 notes 的 NOT NULL 约束。
    // 新建任务不带备注是常态，这里统一收敛成空串。
    const QString trimmedNotes = notes.left(kMaxNotesLength);
    query.bindValue(QStringLiteral(":notes"),
                    trimmedNotes.isNull() ? QStringLiteral("") : trimmedNotes);

    if (!query.exec()) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::completeTask(int taskId)
{
    return setTaskCompleted(taskId, true);
}

bool TaskManager::setTaskCompleted(int taskId, bool completed)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task completion: invalid task id" << taskId;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task completion: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE tasks SET completed = :completed WHERE id = :id"));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task completion:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update task completion: task not found" << taskId;
        return false;
    }

    emit tasksChanged();
    return true;
}

TaskManager::TargetCompletionResult TaskManager::completeTaskIfEstimateReached(
    int taskId, int justCompletedSeconds)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to auto-complete task: invalid task id" << taskId;
        return TargetCompletionResult::Failed;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to auto-complete task: database is not open";
        return TargetCompletionResult::Failed;
    }

    // 判据是「本次会话把累计时长推过了门槛」：
    //   累计秒数 >= 预计用时  且  扣掉本次之后 < 预计用时
    // 第二个条件不能省。只判「累计已超」的话，用户重新打开一个早已超额的任务后，
    // 下一次专注会立刻把它又关掉——换成分钟之前那条「精确相等」写法守的就是这个性质。
    //
    // 累计时长走 focusedSecondsExpr（与任务行展示同一口径，不足 3 分钟的会话不计），
    // 且不区分番茄与自由计时：估的是「用时」，自由专注的时间同样是用时。
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE tasks SET completed = 1 "
        "WHERE id = :id AND completed = 0 AND estimated_minutes > 0 "
        "AND COALESCE((SELECT %1 FROM focus_sessions fs "
        "  WHERE fs.task_id = tasks.id AND fs.duration IS NOT NULL), 0) "
        "    >= estimated_minutes * 60 "
        "AND COALESCE((SELECT %1 FROM focus_sessions fs "
        "  WHERE fs.task_id = tasks.id AND fs.duration IS NOT NULL), 0) - :justCompleted "
        "    < estimated_minutes * 60")
        .arg(focusedSecondsExpr(QStringLiteral("fs"))));
    query.bindValue(QStringLiteral(":id"), taskId);
    query.bindValue(QStringLiteral(":justCompleted"), qMax(0, justCompletedSeconds));

    if (!query.exec()) {
        qWarning() << "Failed to auto-complete task at duration estimate:"
                   << query.lastError().text() << "taskId=" << taskId;
        return TargetCompletionResult::Failed;
    }

    if (query.numRowsAffected() == 0) {
        // 计划为 0、尚未达到、本次之前就已超额、或任务已完成，都属于正常的“不自动完成”。
        return TargetCompletionResult::NotReached;
    }

    emit tasksChanged();
    return TargetCompletionResult::Completed;
}

bool TaskManager::isRoutineGeneratedTask(int taskId) const
{
    if (!isValidTaskId(taskId)) {
        return false;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT routine_generated FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec() || !query.next()) {
        return false;
    }
    return query.value(0).toInt() == 1;
}

bool TaskManager::updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue)
{
    // 四参重命名/改期路径：预估番茄数用 -1 哨兵表示保持不变，避免重命名顺手清零用户的预估。
    return updateTask(taskId, title, categoryId, dateValue, -1);
}

bool TaskManager::updateTask(int taskId, const QString& title, int categoryId,
                             const QVariant& dateValue, int estimatedMinutes)
{
    // 五参路径不带备注：备注同样用「不传即保持不变」的语义，用空 QVariant 表达。
    return updateTask(taskId, title, categoryId, dateValue, estimatedMinutes, QString());
}

bool TaskManager::updateTask(int taskId, const QString& title, int categoryId,
                             const QVariant& dateValue, int estimatedMinutes,
                             const QString& notes)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task: invalid task id" << taskId;
        return false;
    }

    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update task: title is empty after trimming";
        return false;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to update task: title exceeds" << kMaxTitleLength << "characters";
        return false;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to update task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task: database is not open";
        return false;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (categoryId > 0) {
        QSqlQuery categoryQuery(db);
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName)) {
            return false;
        }
        categoryIdValue = categoryId;
    }

    // 预计用时为负视为“保持不变”，只有非负值才写入并夹紧到合法区间。
    const bool updateEstimate = estimatedMinutes >= 0;
    // 只有传了 null QString 才是“保持不变”——五参重载走的正是这条路，
    // 不能让一次不带备注的重命名把用户写的备注抹掉。空串是明确的“清空备注”，
    // 从 QML 传 "" 即可。两者的区别就靠 isNull 与 isEmpty 分开。
    const bool updateNotes = !notes.isNull();

    QString assignments = QStringLiteral(
        "title = :title, category = :category, category_id = :categoryId, date = :date");
    if (updateEstimate) {
        assignments += QStringLiteral(", estimated_minutes = :estimated");
    }
    if (updateNotes) {
        assignments += QStringLiteral(", notes = :notes");
    }

    QSqlQuery query(db);
    // category 文本仍要同步写入，保证旧导出和旧视图在 category_id 缺失时也能退回显示。
    query.prepare(QStringLiteral("UPDATE tasks SET %1 WHERE id = :id").arg(assignments));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), categoryName);
    query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    if (updateEstimate) {
        query.bindValue(QStringLiteral(":estimated"), clampEstimatedMinutes(estimatedMinutes));
    }
    if (updateNotes) {
        query.bindValue(QStringLiteral(":notes"), notes.left(kMaxNotesLength));
    }
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update task: task not found" << taskId;
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::deleteTask(int taskId)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to delete task: invalid task id" << taskId;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete task: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start delete task transaction:" << db.lastError().text();
        return false;
    }

    // 专注记录是历史数据，删除任务时只解除关联，不让记录跟着任务一起删除。
    QSqlQuery detachSessions(db);
    detachSessions.prepare(QStringLiteral("UPDATE focus_sessions SET task_id = NULL WHERE task_id = :id"));
    detachSessions.bindValue(QStringLiteral(":id"), taskId);
    if (!detachSessions.exec()) {
        qWarning() << "Failed to detach focus sessions before deleting task:" << detachSessions.lastError().text();
        db.rollback();
        return false;
    }

    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    deleteQuery.bindValue(QStringLiteral(":id"), taskId);
    if (!deleteQuery.exec()) {
        qWarning() << "Failed to delete task:" << deleteQuery.lastError().text();
        db.rollback();
        return false;
    }

    if (deleteQuery.numRowsAffected() == 0) {
        qWarning() << "Failed to delete task: task not found" << taskId;
        db.rollback();
        return false;
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit delete task transaction:" << db.lastError().text();
        db.rollback();
        return false;
    }

    // 先广播精确删除事实，让计时器在列表刷新前解绑当前任务 ID；这样订阅 tasksChanged
    // 的页面不会观察到“任务已删、计时器仍绑定旧 ID”的中间状态。
    emit taskDeleted(taskId);
    emit tasksChanged();
    return true;
}

QVariantList TaskManager::getTodayTasks() const
{
    return getTasksByDate(LogicalDay::today(AppSettings::instance()->dayStartHour()));
}

QVariantList TaskManager::getTasksByDate(const QDate& date) const
{
    QVariantList tasks;
    if (!date.isValid()) {
        qWarning() << "Failed to get tasks: invalid date";
        reportFailure(QStringLiteral("任务日期无效"));
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get tasks: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载任务"));
        return tasks;
    }

    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        // 手动排序优先：display_order = 0 表示"没排过"，统一排到已排项之后，
        // 再按创建时间保持与改版前一致的相对顺序。
        "WHERE t.date = :date ORDER BY t.completed ASC, "
        "CASE WHEN t.display_order = 0 THEN 1 ELSE 0 END ASC, "
        "t.display_order ASC, t.created_at ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get tasks:" << query.lastError().text();
        reportFailure(QStringLiteral("任务加载失败: %1").arg(query.lastError().text()));
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

QVariantList TaskManager::getWeekTasks(const QVariant& startDateValue) const
{
    QVariantList tasks;
    const QDate startDate = normalizeDate(startDateValue);
    if (!startDate.isValid()) {
        qWarning() << "Failed to get week tasks: invalid start date";
        reportFailure(QStringLiteral("周计划日期无效"));
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get week tasks: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载周计划"));
        return tasks;
    }

    // 周视图传入周一；这里取从周一开始的 7 天，与 UI 的 7 列保持一致。
    const QDate endDate = startDate.addDays(6);
    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE t.date >= :startDate AND t.date <= :endDate "
        "ORDER BY t.date ASC, t.completed ASC, "
        "CASE WHEN t.display_order = 0 THEN 1 ELSE 0 END ASC, "
        "t.display_order ASC, t.created_at ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get week tasks:" << query.lastError().text();
        reportFailure(QStringLiteral("周计划加载失败: %1").arg(query.lastError().text()));
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

QVariantList TaskManager::getMonthTasks(int year, int month) const
{
    QVariantList tasks;
    const QDate startDate(year, month, 1);
    if (!startDate.isValid()) {
        qWarning() << "Failed to get month tasks: invalid year/month" << year << month;
        reportFailure(QStringLiteral("月计划日期无效"));
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get month tasks: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载月计划"));
        return tasks;
    }

    // addMonths 会处理跨年；再减一天得到当月最后一天。
    const QDate endDate = startDate.addMonths(1).addDays(-1);
    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE t.date >= :startDate AND t.date <= :endDate "
        "ORDER BY t.date ASC, t.completed ASC, "
        "CASE WHEN t.display_order = 0 THEN 1 ELSE 0 END ASC, "
        "t.display_order ASC, t.created_at ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get month tasks:" << query.lastError().text();
        reportFailure(QStringLiteral("月计划加载失败: %1").arg(query.lastError().text()));
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

QVariantList TaskManager::getOverdueUncompletedTasks() const
{
    QVariantList tasks;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get overdue tasks: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载逾期任务"));
        return tasks;
    }

    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE t.date < :today AND t.completed = 0 AND t.routine_generated = 0 "
        "ORDER BY t.date ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":today"),
                    LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get overdue tasks:" << query.lastError().text();
        reportFailure(QStringLiteral("逾期任务加载失败: %1").arg(query.lastError().text()));
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

bool TaskManager::moveTasksToToday(const QVariantList& taskIds)
{
    if (taskIds.isEmpty()) {
        return true;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to move tasks: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start move tasks transaction:" << db.lastError().text();
        return false;
    }

    const QString today = LogicalDay::today(
                              AppSettings::instance()->dayStartHour()).toString(Qt::ISODate);
    for (const QVariant& idValue : taskIds) {
        const int taskId = idValue.toInt();
        if (!isValidTaskId(taskId)) {
            qWarning() << "Failed to move tasks: invalid task id" << idValue;
            db.rollback();
            return false;
        }

        QSqlQuery query(db);
        query.prepare(QStringLiteral("UPDATE tasks SET date = :today WHERE id = :id"));
        query.bindValue(QStringLiteral(":today"), today);
        query.bindValue(QStringLiteral(":id"), taskId);

        // 一键结转必须全成或全不成；部分成功会让提示数量和列表状态互相矛盾。
        if (!query.exec() || query.numRowsAffected() <= 0) {
            qWarning() << "Failed to move task" << taskId << ":" << query.lastError().text();
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit move tasks:" << db.lastError().text();
        db.rollback();
        return false;
    }

    emit tasksChanged();
    return true;
}

int TaskManager::getCompletedPomodorosForTask(int taskId) const
{
    if (!isValidTaskId(taskId)) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to count task pomodoros: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT ") + validPomodoroCountExpr()
        + QStringLiteral(" AS actual FROM focus_sessions WHERE task_id = :id AND duration IS NOT NULL"));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count task pomodoros:" << query.lastError().text();
        return 0;
    }
    return query.value(0).toInt();
}

int TaskManager::getFocusedMinutesForTask(int taskId) const
{
    if (!isValidTaskId(taskId)) {
        return 0;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to sum task focus minutes: database is not open";
        return 0;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT ") + focusedSecondsExpr()
        + QStringLiteral(" AS focused FROM focus_sessions WHERE task_id = :id AND duration IS NOT NULL"));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to sum task focus minutes:" << query.lastError().text();
        return 0;
    }
    return query.value(0).toInt() / 60;
}

bool TaskManager::reorderTasks(const QVariant& dateValue, const QVariantList& orderedTaskIds)
{
    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to reorder tasks: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to reorder tasks: database is not open";
        return false;
    }
    if (!db.transaction()) {
        qWarning() << "Failed to start reorder transaction:" << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE tasks SET display_order = :order WHERE id = :id AND date = :date"));

    for (int i = 0; i < orderedTaskIds.size(); ++i) {
        const int taskId = orderedTaskIds.at(i).toInt();
        if (!isValidTaskId(taskId)) {
            qWarning() << "Failed to reorder tasks: invalid task id" << taskId;
            db.rollback();
            return false;
        }
        // 序号从 1 开始：0 留给“从未排过”的行，让它们在同序时回落到 created_at。
        query.bindValue(QStringLiteral(":order"), i + 1);
        query.bindValue(QStringLiteral(":id"), taskId);
        query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
        if (!query.exec()) {
            qWarning() << "Failed to reorder tasks:" << query.lastError().text();
            db.rollback();
            return false;
        }
        // 日期不匹配的 id 不算错误也不写入——顺序数组可能包含刚被改期走的任务。
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit reorder:" << db.lastError().text();
        db.rollback();
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::moveTaskToDate(int taskId, const QVariant& dateValue)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to move task: invalid task id" << taskId;
        return false;
    }
    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to move task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to move task: database is not open";
        return false;
    }

    QSqlQuery query(db);
    // 落到新日期的末尾：插到中间会打乱目标日期上已排好的顺序。
    query.prepare(QStringLiteral(
        // 同上：占位符不重名。
        "UPDATE tasks SET date = :date, "
        "display_order = (SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks "
        "                 WHERE date = :orderDate AND id <> :selfId) "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":orderDate"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":selfId"), taskId);
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to move task:" << query.lastError().text();
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        qWarning() << "Failed to move task: task not found" << taskId;
        return false;
    }

    emit tasksChanged();
    return true;
}
