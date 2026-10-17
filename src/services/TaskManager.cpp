#include "TaskManager.h"

#include "../models/Task.h"
#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"
#include "QmlValues.h"
#include "TrashStore.h"

#include <QDebug>
#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QSet>
#include <QVariant>

#include <limits>

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

// 在调用方已开启的事务里删掉一条任务，失败时把日志文案写进 failure、不回滚（回滚由调用方统一做）。
// 单条删除与批量删除共用这一份步骤：先把任务写进废纸篓，再解除专注记录关联——解除之后就查不到挂在它上面的
// 专注记录了，恢复时没法接回。写废纸篓失败整体回滚，宁可删不掉，也不能删了却没进废纸篓。
bool removeTaskInTransaction(QSqlDatabase& db, int taskId, QString* failure)
{
    QString trashError;
    if (!TrashStore::captureTask(db, taskId, &trashError)) {
        // 任务不存在时保持原有的日志文案；其余是写废纸篓失败。
        *failure = trashError == TrashStore::kMissingRecord
            ? QStringLiteral("Failed to delete task: task not found %1").arg(taskId)
            : QStringLiteral("Failed to move task to trash: %1").arg(trashError);
        return false;
    }

    // 专注记录是历史数据，删除任务时只解除关联，不让记录跟着任务一起删除。
    QSqlQuery detachSessions(db);
    detachSessions.prepare(QStringLiteral("UPDATE focus_sessions SET task_id = NULL WHERE task_id = :id"));
    detachSessions.bindValue(QStringLiteral(":id"), taskId);
    if (!detachSessions.exec()) {
        *failure = QStringLiteral("Failed to detach focus sessions before deleting task: %1")
                       .arg(detachSessions.lastError().text());
        return false;
    }

    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    deleteQuery.bindValue(QStringLiteral(":id"), taskId);
    if (!deleteQuery.exec()) {
        *failure = QStringLiteral("Failed to delete task: %1").arg(deleteQuery.lastError().text());
        return false;
    }
    if (deleteQuery.numRowsAffected() == 0) {
        *failure = QStringLiteral("Failed to delete task: task not found %1").arg(taskId);
        return false;
    }
    return true;
}

// 批量接口的编号清单：必须全是正整数且不重复，否则整批拒绝（不写库）。
bool collectTaskIds(const QVariantList& values, QList<int>* ids)
{
    QSet<int> seen;
    for (const QVariant& value : values) {
        bool valid = false;
        const int id = value.toInt(&valid);
        if (!valid || id <= 0 || seen.contains(id))
            return false;
        seen.insert(id);
        ids->append(id);
    }
    return true;
}

int clampEstimatedMinutes(int value)
{
    // 越界一律夹紧：负数当未设置，超上限压到上限，绝不因预估值让任务本体保存失败。
    return qBound(0, value, TaskManager::kMaxEstimatedMinutes);
}

// “有效番茄”的口径已上移到 FocusSessionRules，统计服务复用同一份定义。
// 这里保留一个同名薄封装，只是为了让本文件原有调用点不必逐个改写。
QString validPomodoroCountExpr(const QString& tableAlias = QString())
{
    return FocusSessionRules::validPomodoroCountExpr(tableAlias);
}

// “有效专注秒数”同样上移到 FocusSessionRules，口径只有这一份定义。
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
        "t.date, t.completed, t.created_at, t.estimated_minutes, t.notes, t.completion_note, "
        "t.display_order, t.category AS persisted_category, "
        "COALESCE((SELECT %1 FROM focus_sessions fs "
        "WHERE fs.task_id = t.id AND fs.duration IS NOT NULL), 0) AS actual_pomodoros, "
        "COALESCE((SELECT %2 FROM focus_sessions fs "
        "WHERE fs.task_id = t.id AND fs.duration IS NOT NULL), 0) AS focused_seconds "
        "FROM tasks t "
        "LEFT JOIN categories c ON t.category_id = c.id ")
        .arg(validPomodoroCountExpr(QStringLiteral("fs")), focusedSecondsExpr());
}

bool bindCategoryTextFromId(QSqlQuery& query, int categoryId, QString* categoryName, QString* failure)
{
    if (categoryId <= 0) {
        *categoryName = QString();
        return true;
    }

    query.prepare(QStringLiteral("SELECT name FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), categoryId);
    if (!query.exec()) {
        qWarning() << "Failed to look up category for task:" << query.lastError().text();
        *failure = QStringLiteral("科目读取失败：%1").arg(query.lastError().text());
        return false;
    }

    if (!query.next()) {
        qWarning() << "Failed to add task: category not found" << categoryId;
        *failure = QStringLiteral("科目不存在（编号 %1）").arg(categoryId);
        return false;
    }

    *categoryName = query.value(0).toString();
    return true;
}

// moveTaskBefore 的排序规则，不碰数据库。current 是当天全部任务此刻的显示顺序（未完成在前、
// 已完成在后），completed 是其中已完成的编号。成立时 *result 是移动后的全天新顺序（可能与
// current 相同）；不成立时返回 false，原因写进 *reason。
bool placeTaskBefore(const QList<int>& current, const QSet<int>& completed,
                     int taskId, int beforeTaskId, QList<int>* result, QString* reason)
{
    if (!current.contains(taskId)) {
        *reason = QStringLiteral("任务不存在");
        return false;
    }
    // 已完成的任务由显示口径固定排在未完成之后，不参与手动排序：
    // 允许拖它只会让人以为能把它插回未完成那一段。
    if (completed.contains(taskId)) {
        *reason = QStringLiteral("已完成的任务不参与排序");
        return false;
    }
    *result = current;
    if (beforeTaskId == taskId) {
        return true;
    }
    // 落点编号有效却不在当天的集合里：要么是另一天的任务，要么根本不存在。
    if (beforeTaskId > 0 && !current.contains(beforeTaskId)) {
        *reason = QStringLiteral("目标任务不在同一天或不存在");
        return false;
    }

    result->removeOne(taskId);
    // 默认落点是未完成组的末尾，即第一条已完成任务之前（没有已完成任务时就是全天末尾）。
    // 没有落点（beforeTaskId <= 0）或落点是已完成任务时都落在这里：已完成的固定在最后，
    // 把未完成任务插进它们中间或排到它们后面，写出的序号就和显示顺序对不上了。
    qsizetype insertAt = result->size();
    for (qsizetype i = 0; i < result->size(); ++i) {
        if (completed.contains(result->at(i))) {
            insertAt = i;
            break;
        }
    }
    if (beforeTaskId > 0 && !completed.contains(beforeTaskId)) {
        insertAt = result->indexOf(beforeTaskId);
    }
    result->insert(insertAt, taskId);
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
    // 写入拒绝必须携带原因：桥接据此返回本次错误，Mac 发起处也只显示这一份原文。
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
        "INSERT INTO tasks (title, category, category_id, date, completed, display_order) "
        "VALUES (:title, :category, :categoryId, :date, 0, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), normalizedCategory);
    query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":orderDate"), date.toString(Qt::ISODate));

    if (!query.exec() || query.numRowsAffected() != 1) {
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
    return createTask(title, dateValue, categoryId, estimatedMinutes, notes) > 0;
}

int TaskManager::createTask(const QString& title, const QVariant& dateValue,
                            int categoryId, int estimatedMinutes, const QString& notes)
{
    return createTaskWithOutcome(title, dateValue, categoryId, estimatedMinutes, notes, nullptr);
}

int TaskManager::createTaskWithOutcome(const QString& title, const QVariant& dateValue,
                                      int categoryId, int estimatedMinutes, const QString& notes, bool* committed)
{
    if (committed) *committed = false;
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to add task: title is empty after trimming";
        reportFailure(QStringLiteral("新建任务失败：标题不能为空"));
        return -1;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to add task: title exceeds" << kMaxTitleLength << "characters";
        reportFailure(QStringLiteral("新建任务失败：标题超长（最多 %1 字）").arg(kMaxTitleLength));
        return -1;
    }
    if (notes.size() > kMaxNotesLength) {
        qWarning() << "Failed to add task: notes exceed" << kMaxNotesLength << "characters";
        reportFailure(QStringLiteral("新建任务失败：备注超长（最多 %1 字）").arg(kMaxNotesLength));
        return -1;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to add task: invalid date";
        reportFailure(QStringLiteral("新建任务失败：日期无效"));
        return -1;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add task: database is not open";
        reportFailure(QStringLiteral("新建任务失败：数据库未打开"));
        return -1;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (categoryId > 0) {
        QSqlQuery categoryQuery(db);
        QString failure;
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName, &failure)) {
            reportFailure(QStringLiteral("新建任务失败：%1").arg(failure));
            return -1;
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
    query.bindValue(QStringLiteral(":notes"), notes.isNull() ? QStringLiteral("") : notes);

    if (!query.exec() || query.numRowsAffected() != 1) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        reportFailure(query.lastError().isValid()
            ? QStringLiteral("新建任务失败：数据库写入失败：%1").arg(query.lastError().text())
            : QStringLiteral("新建任务失败：任务未写入"));
        return -1;
    }

    if (committed) *committed = true;

    // id 是 INTEGER PRIMARY KEY AUTOINCREMENT，即 rowid 别名，SQLite 驱动据此给出新编号。
    // 取不到就当失败报给调用方：行确实已经写进去了（所以照常发 tasksChanged 让界面刷新），
    // 但这里绝不返回一个猜来的编号——调用方拿它去开专注会绑错任务。
    bool idOk = false;
    const int insertedId = query.lastInsertId().toInt(&idOk);
    emit tasksChanged();
    if (!idOk || insertedId <= 0) {
        qWarning() << "Task inserted but the new id is unavailable";
        reportFailure(QStringLiteral("新建任务失败：任务已保存，但未能取得新编号，请重新读取确认"));
        return -1;
    }
    return insertedId;
}

bool TaskManager::completeTask(int taskId)
{
    return setTaskCompleted(taskId, true);
}

bool TaskManager::setTaskCompleted(int taskId, bool completed)
{
    // iPad 从 operationFailed 收集本次调用的原因；只记日志会让桥接返回的错误退化成通用文案。
    const QString action = completed ? QStringLiteral("完成") : QStringLiteral("取消完成");
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task completion: invalid task id" << taskId;
        reportFailure(QStringLiteral("%1失败：任务编号无效").arg(action));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task completion: database is not open";
        reportFailure(QStringLiteral("%1失败：数据库未打开").arg(action));
        return false;
    }

    QSqlQuery query(db);
    // 只改 completed 一列，完成记录原样保留：取消完成（包括撤销条）多半是点错了，
    // 把用户刚写的记录一并抹掉就找不回来了。任务未完成时界面不显示这条记录，
    // 再次完成时弹窗会把它预填回来。
    query.prepare(QStringLiteral("UPDATE tasks SET completed = :completed WHERE id = :id"));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task completion:" << query.lastError().text();
        reportFailure(QStringLiteral("%1失败：数据库写入失败：%2").arg(action, query.lastError().text()));
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update task completion: task not found" << taskId;
        reportFailure(QStringLiteral("%1失败：任务不存在").arg(action));
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::completeTaskWithNote(int taskId, const QString& note)
{
    // 与单条完成保持一致：失败必须带原因发给 iPad，调用方认领后只显示一次。
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to complete task with note: invalid task id" << taskId;
        reportFailure(QStringLiteral("完成并记笔记失败：任务编号无效"));
        return false;
    }
    // 超长拒绝而不是截断，理由与备注相同：截断会让保存照常「成功」，丢的往往是结论那段。
    if (note.size() > kMaxNotesLength) {
        qWarning() << "Failed to complete task with note: note exceeds" << kMaxNotesLength
                   << "characters";
        reportFailure(QStringLiteral("完成并记笔记失败：笔记超长，最多 %1 字").arg(kMaxNotesLength));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to complete task with note: database is not open";
        reportFailure(QStringLiteral("完成并记笔记失败：数据库未打开"));
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE tasks SET completed = 1, completion_note = :note WHERE id = :id"));
    // QML 传来的空串可能是 null QString，直接绑会写成 NULL 并撞上 NOT NULL 约束；
    // 「没写记录」是合法的常态，统一收敛成空串。
    query.bindValue(QStringLiteral(":note"), note.isNull() ? QStringLiteral("") : note);
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to complete task with note:" << query.lastError().text();
        reportFailure(QStringLiteral("完成并记笔记失败：数据库写入失败：%1").arg(query.lastError().text()));
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to complete task with note: task not found" << taskId;
        reportFailure(QStringLiteral("完成并记笔记失败：任务不存在"));
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
    return updateTaskFields(taskId, title, categoryId, dateValue, estimatedMinutes, notes, false);
}

bool TaskManager::updateTask(int taskId, const QString& title, int categoryId,
                             const QVariant& dateValue, int estimatedMinutes,
                             const QString& notes, const QVariant& completionNote)
{
    // 按值的类型判断「写不写」，不按内容：QML 的 undefined 到这里是无效 QVariant，
    // null 是 nullptr 类型，只有真的传了字符串（哪怕是空串）才算要改。
    // 不能用 isNull 判断：Qt 6 里装着空 QString 的 QVariant 也不算 null。
    std::optional<QString> completionNoteValue;
    if (completionNote.typeId() == QMetaType::QString) {
        const QString text = completionNote.toString();
        // 空串同样要收敛成非 null，否则后面会被当成 NULL 绑定。
        completionNoteValue = text.isNull() ? QStringLiteral("") : text;
    }
    return updateTaskFields(taskId, title, categoryId, dateValue, estimatedMinutes, notes, false,
                            false, completionNoteValue);
}

bool TaskManager::updateTaskChanges(int taskId, const QVariantMap& changes)
{
    const QString titleKey = QStringLiteral("title");
    const QString categoryKey = QStringLiteral("categoryId");
    const QString dateKey = QStringLiteral("date");
    const QString estimateKey = QStringLiteral("estimatedMinutes");
    const QString notesKey = QStringLiteral("notes");
    const QString completionKey = QStringLiteral("completionNote");
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        const QString& key = it.key();
        const bool textField = key == titleKey || key == notesKey || key == completionKey;
        if (!textField && key != categoryKey && key != dateKey && key != estimateKey) {
            qWarning() << "Failed to update task: unknown field" << key;
            reportFailure(QStringLiteral("修改任务失败：未知字段 %1").arg(key));
            return false;
        }
        // 文本字段必须真是字符串：QML 的 undefined/null 不能被悄悄当成「清空」。
        if (textField && it.value().typeId() != QMetaType::QString) {
            qWarning() << "Failed to update task: field" << key << "must be text";
            reportFailure(QStringLiteral("修改任务失败：字段 %1 必须是文本").arg(key));
            return false;
        }
    }
    if (changes.isEmpty()) {
        const auto result = readTask(taskId);
        if (!result.ok()) {
            const QString reason = taskId <= 0 ? QStringLiteral("任务编号无效")
                : !DatabaseManager::instance()->database().isOpen() ? QStringLiteral("数据库未打开")
                : result.error == ServiceReadError::NotFound ? QStringLiteral("任务不存在")
                : QStringLiteral("数据库读取失败");
            reportFailure(QStringLiteral("修改任务失败：%1").arg(reason));
        }
        return result.ok();
    }

    // 科目编号 -1 或 0 表示不设科目。
    int categoryId = -1;
    if (changes.contains(categoryKey)
        && !QmlValues::integer(changes.value(categoryKey), -1, std::numeric_limits<int>::max(), &categoryId)) {
        qWarning() << "Failed to update task: invalid category id";
        reportFailure(QStringLiteral("修改任务失败：科目编号无效"));
        return false;
    }
    int estimatedMinutes = -1; // -1 = 预计用时保持不变
    if (changes.contains(estimateKey)
        && !QmlValues::integer(changes.value(estimateKey), 0, std::numeric_limits<int>::max(), &estimatedMinutes)) {
        qWarning() << "Failed to update task: invalid estimated minutes";
        reportFailure(QStringLiteral("修改任务失败：预计用时无效"));
        return false;
    }
    // null QString 表示「备注保持不变」；要改就收敛成非 null，空串才会被当成清空写入。
    const QString notes = changes.contains(notesKey)
        ? (changes.value(notesKey).toString().isNull() ? QStringLiteral("") : changes.value(notesKey).toString())
        : QString();
    std::optional<QString> completionNote;
    if (changes.contains(completionKey)) {
        const QString text = changes.value(completionKey).toString();
        completionNote = text.isNull() ? QStringLiteral("") : text;
    }
    return updateTaskFields(taskId, changes.value(titleKey).toString(), categoryId, changes.value(dateKey),
                            estimatedMinutes, notes, !changes.contains(categoryKey), !changes.contains(titleKey),
                            completionNote, !changes.contains(dateKey));
}

bool TaskManager::updateTaskFields(int taskId, const QString& title, int categoryId,
                                    const QVariant& dateValue, int estimatedMinutes,
                                    const QString& notes, bool preserveCategory, bool preserveTitle,
                                    const std::optional<QString>& completionNote, bool preserveDate)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task: invalid task id" << taskId;
        reportFailure(QStringLiteral("修改任务失败：任务编号无效"));
        return false;
    }

    // 保留标题时整句 SQL 都不碰 title 列，所以也不校验传进来的标题。
    const QString normalizedTitle = title.trimmed();
    if (!preserveTitle && normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update task: title is empty after trimming";
        reportFailure(QStringLiteral("修改任务失败：标题不能为空"));
        return false;
    }
    if (!preserveTitle && normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to update task: title exceeds" << kMaxTitleLength << "characters";
        reportFailure(QStringLiteral("修改任务失败：标题超长（最多 %1 字）").arg(kMaxTitleLength));
        return false;
    }

    // 保留日期时同样不碰 date 列，也不校验传进来的日期。
    const QDate date = preserveDate ? QDate() : normalizeDate(dateValue);
    if (!preserveDate && !date.isValid()) {
        qWarning() << "Failed to update task: invalid date";
        reportFailure(QStringLiteral("修改任务失败：日期无效"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task: database is not open";
        reportFailure(QStringLiteral("修改任务失败：数据库未打开"));
        return false;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (!preserveCategory && categoryId > 0) {
        QSqlQuery categoryQuery(db);
        QString failure;
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName, &failure)) {
            reportFailure(QStringLiteral("修改任务失败：%1").arg(failure));
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
    if (updateNotes && notes.size() > kMaxNotesLength) {
        qWarning() << "Failed to update task: notes exceed" << kMaxNotesLength << "characters";
        reportFailure(QStringLiteral("修改任务失败：备注超长（最多 %1 字）").arg(kMaxNotesLength));
        return false;
    }
    // 完成记录与备注共用同一上限，超长同样整次拒绝，其它字段也不落库。
    if (completionNote && completionNote->size() > kMaxNotesLength) {
        qWarning() << "Failed to update task: completion note exceeds" << kMaxNotesLength
                   << "characters";
        reportFailure(QStringLiteral("修改任务失败：完成记录超长（最多 %1 字）").arg(kMaxNotesLength));
        return false;
    }

    QStringList assignments;
    if (!preserveDate) {
        assignments.append(QStringLiteral(
            "date = :date, "
            "display_order = CASE WHEN date = :comparisonDate THEN display_order ELSE "
            "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks "
            " WHERE date = :orderDate AND id <> :selfId) END"));
    }
    if (!preserveTitle) assignments.append(QStringLiteral("title = :title"));
    if (!preserveCategory) assignments.append(QStringLiteral("category = :category, category_id = :categoryId"));
    if (updateEstimate) {
        assignments.append(QStringLiteral("estimated_minutes = :estimated"));
    }
    if (updateNotes) {
        assignments.append(QStringLiteral("notes = :notes"));
    }
    if (completionNote) {
        assignments.append(QStringLiteral("completion_note = :completionNote"));
    }
    // 什么都不改（只有字段级入口会走到这里）：不发 UPDATE，只确认任务还在。
    if (assignments.isEmpty()) {
        const auto result = readTask(taskId);
        if (!result.ok()) {
            const QString reason = taskId <= 0 ? QStringLiteral("任务编号无效")
                : !DatabaseManager::instance()->database().isOpen() ? QStringLiteral("数据库未打开")
                : result.error == ServiceReadError::NotFound ? QStringLiteral("任务不存在")
                : QStringLiteral("数据库读取失败");
            reportFailure(QStringLiteral("修改任务失败：%1").arg(reason));
        }
        return result.ok();
    }

    QSqlQuery query(db);
    // category 文本仍要同步写入，保证旧导出和旧视图在 category_id 缺失时也能退回显示。
    query.prepare(QStringLiteral("UPDATE tasks SET %1 WHERE id = :id").arg(assignments.join(QStringLiteral(", "))));
    if (!preserveTitle) query.bindValue(QStringLiteral(":title"), normalizedTitle);
    if (!preserveCategory) {
        query.bindValue(QStringLiteral(":category"), categoryName);
        query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    }
    if (!preserveDate) {
        query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
        query.bindValue(QStringLiteral(":comparisonDate"), date.toString(Qt::ISODate));
        query.bindValue(QStringLiteral(":orderDate"), date.toString(Qt::ISODate));
        query.bindValue(QStringLiteral(":selfId"), taskId);
    }
    if (updateEstimate) {
        query.bindValue(QStringLiteral(":estimated"), clampEstimatedMinutes(estimatedMinutes));
    }
    if (updateNotes) {
        query.bindValue(QStringLiteral(":notes"), notes);
    }
    if (completionNote) {
        // C++ 调用方可能传进 null QString；同样收敛成空串，免得撞上 NOT NULL 约束。
        query.bindValue(QStringLiteral(":completionNote"),
                        completionNote->isNull() ? QStringLiteral("") : *completionNote);
    }
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task:" << query.lastError().text();
        reportFailure(QStringLiteral("修改任务失败：数据库写入失败：%1").arg(query.lastError().text()));
        return false;
    }

    if (query.numRowsAffected() != 1) {
        qWarning() << "Failed to update task: task not found" << taskId;
        reportFailure(QStringLiteral("修改任务失败：任务不存在或未更新"));
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

    QString failure;
    if (!removeTaskInTransaction(db, taskId, &failure)) {
        qWarning().noquote() << failure;
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
    emit TrashNotifier::instance()->changed();
    return true;
}

bool TaskManager::deleteTasks(const QVariantList& taskIds)
{
    QList<int> ids;
    if (!collectTaskIds(taskIds, &ids)) {
        reportFailure(QStringLiteral("删除失败：任务编号无效或重复"));
        return false;
    }
    if (ids.isEmpty())
        return true;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen() || !db.transaction()) {
        reportFailure(QStringLiteral("删除失败：无法开始数据库事务"));
        return false;
    }
    // 整批在一个事务里：任何一条删不掉（已被另一台删掉、写废纸篓失败）就全部回滚，
    // 不会出现选中五条、删掉三条、剩两条还在列表里的半状态。
    for (const int id : ids) {
        QString failure;
        if (!removeTaskInTransaction(db, id, &failure)) {
            qWarning().noquote() << failure;
            db.rollback();
            reportFailure(QStringLiteral("删除失败：任务已变化，请刷新重试"));
            return false;
        }
    }
    if (!db.commit()) {
        db.rollback();
        reportFailure(QStringLiteral("删除失败：数据库提交失败"));
        return false;
    }
    // 与单条删除同一顺序：逐条发删除事实让计时器先解绑，再发一次列表刷新。
    for (const int id : ids)
        emit taskDeleted(id);
    emit tasksChanged();
    emit TrashNotifier::instance()->changed();
    return true;
}

bool TaskManager::setTasksCompleted(const QVariantList& taskIds, bool completed)
{
    const QString action = completed ? QStringLiteral("完成") : QStringLiteral("取消完成");
    QList<int> ids;
    if (!collectTaskIds(taskIds, &ids)) {
        reportFailure(QStringLiteral("%1失败：任务编号无效或重复").arg(action));
        return false;
    }
    if (ids.isEmpty())
        return true;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen() || !db.transaction()) {
        reportFailure(QStringLiteral("%1失败：无法开始数据库事务").arg(action));
        return false;
    }
    // 与 setTaskCompleted 同一口径：只改 completed 一列，完成记录原样保留。
    // 已经是目标状态的任务也算命中（SQLite 按 WHERE 命中行计数），不当失败；不存在的任务让整批回滚。
    for (const int id : ids) {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("UPDATE tasks SET completed = :completed WHERE id = :id"));
        query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
        query.bindValue(QStringLiteral(":id"), id);
        if (!query.exec() || query.numRowsAffected() != 1) {
            db.rollback();
            reportFailure(QStringLiteral("%1失败：任务已变化，请刷新重试").arg(action));
            return false;
        }
    }
    if (!db.commit()) {
        db.rollback();
        reportFailure(QStringLiteral("%1失败：数据库提交失败").arg(action));
        return false;
    }
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
        "WHERE t.date = :date ORDER BY t.completed ASC, "
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

    // 回看窗口按逻辑日算：凌晨日界点前仍属于前一天，窗口的两端跟着一起挪。
    // 日期列存的是 ISO 字符串（yyyy-MM-dd），按字符串比较就是按日期先后比较。
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE t.date >= :earliest AND t.date < :today "
        "AND t.completed = 0 AND t.routine_generated = 0 "
        "ORDER BY t.date ASC, t.display_order ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":earliest"),
                    today.addDays(-kOverdueRolloverDays).toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":today"), today.toString(Qt::ISODate));

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
    return moveTasksToDate(taskIds, LogicalDay::today(AppSettings::instance()->dayStartHour()));
}

bool TaskManager::moveTasksToDate(const QVariantList& taskIds, const QVariant& dateValue)
{
    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        reportFailure(QStringLiteral("改期失败：日期无效"));
        return false;
    }
    if (taskIds.isEmpty())
        return true;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen() || !db.transaction()) {
        reportFailure(QStringLiteral("改期失败：无法开始数据库事务"));
        return false;
    }
    QSet<int> seen;
    const QString iso = date.toString(Qt::ISODate);
    for (const QVariant& value : taskIds) {
        bool valid = false;
        const int id = value.toInt(&valid);
        if (!valid || id <= 0 || seen.contains(id)) {
            db.rollback();
            reportFailure(QStringLiteral("改期失败：任务编号无效或重复"));
            return false;
        }
        seen.insert(id);
        QSqlQuery query(db);
        // 已在目标日期的任务保持原排序；跨日任务按选择顺序追加。失败回滚整个批次。
        query.prepare(QStringLiteral(
            "UPDATE tasks SET display_order = CASE WHEN date = :date THEN display_order "
            "ELSE (SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :date) END, "
            "date = :date WHERE id = :id"));
        query.bindValue(QStringLiteral(":date"), iso);
        query.bindValue(QStringLiteral(":id"), id);
        if (!query.exec() || query.numRowsAffected() != 1) {
            db.rollback();
            reportFailure(QStringLiteral("改期失败：任务已变化，请刷新重试"));
            return false;
        }
    }
    if (!db.commit()) {
        db.rollback();
        reportFailure(QStringLiteral("改期失败：数据库提交失败"));
        return false;
    }
    emit tasksChanged();
    return true;
}

QVariantMap TaskManager::getTask(int taskId) const
{
    const auto result = readTask(taskId);
    if (result.error == ServiceReadError::Database) reportFailure(QStringLiteral("任务加载失败"));
    return result.value;
}

QVariantList TaskManager::searchTasks(const QString& text, int status, int limit) const
{
    QVariantList result;
    QSqlQuery query(DatabaseManager::instance()->database());
    // instr 按字面匹配，用户输入 %、_ 不会变成 SQL 通配符；标题、备注、科目跨日期查询。
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE (:status < 0 OR t.completed = :status) AND "
        "(:text = '' OR instr(lower(t.title), lower(:text)) > 0 "
        "OR instr(lower(t.notes), lower(:text)) > 0 "
        "OR instr(lower(COALESCE(c.name, t.category)), lower(:text)) > 0) "
        "ORDER BY t.date DESC, t.display_order ASC, t.id ASC LIMIT :limit"));
    query.bindValue(QStringLiteral(":text"), text.trimmed());
    query.bindValue(QStringLiteral(":status"), status == 0 || status == 1 ? status : -1);
    query.bindValue(QStringLiteral(":limit"), qBound(1, limit, 10000));
    if (!query.exec()) {
        reportFailure(QStringLiteral("任务搜索失败"));
        return result;
    }
    while (query.next())
        result.append(Task::fromQuery(query).toVariantMap());
    return result;
}

bool TaskManager::duplicateTask(int taskId, const QVariant& dateValue)
{
    const QDate date = normalizeDate(dateValue);
    if (taskId <= 0 || !date.isValid()) {
        reportFailure(QStringLiteral("复制失败：任务或日期无效"));
        return false;
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    // 单条 INSERT SELECT 原子复制定义，兼容旧版纯文本科目；其他列取默认值，
    // 不继承完成状态、完成记录、专注记录或例行生成标记，也不改变原任务。
    query.prepare(QStringLiteral(
        "INSERT INTO tasks(title, category, category_id, date, estimated_minutes, notes, display_order) "
        "SELECT title, category, category_id, :date, estimated_minutes, notes, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :date) "
        "FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec() || query.numRowsAffected() != 1) {
        reportFailure(QStringLiteral("复制失败：原任务不存在或数据库写入失败"));
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
        reportFailure(QStringLiteral("任务排序失败：日期无效"));
        return false;
    }
    if (orderedTaskIds.isEmpty()) {
        qWarning() << "Failed to reorder tasks: task list is empty";
        reportFailure(QStringLiteral("任务排序失败：顺序列表为空"));
        return false;
    }

    QSet<int> requestedIds;
    for (const QVariant& idValue : orderedTaskIds) {
        const int taskId = idValue.toInt();
        if (!isValidTaskId(taskId) || requestedIds.contains(taskId)) {
            qWarning() << "Failed to reorder tasks: invalid or duplicate task id" << idValue;
            reportFailure(QStringLiteral("任务排序失败：任务编号无效或重复"));
            return false;
        }
        requestedIds.insert(taskId);
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to reorder tasks: database is not open";
        reportFailure(QStringLiteral("任务排序失败：数据库未打开"));
        return false;
    }
    if (!db.transaction()) {
        qWarning() << "Failed to start reorder transaction:" << db.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法启动事务"));
        return false;
    }

    // UI 快照可能在拖动期间过期。必须在写入同一事务里重新读取完整集合，
    // 任何缺失、额外或跨日 ID 都拒绝，避免部分更新制造重复序号。
    QSqlQuery actualQuery(db);
    actualQuery.prepare(QStringLiteral("SELECT id FROM tasks WHERE date = :date"));
    actualQuery.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    if (!actualQuery.exec()) {
        qWarning() << "Failed to inspect tasks before reorder:" << actualQuery.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法校验当前任务集合"));
        db.rollback();
        return false;
    }
    QSet<int> actualIds;
    while (actualQuery.next()) {
        actualIds.insert(actualQuery.value(0).toInt());
    }
    actualQuery.finish();
    if (actualIds != requestedIds) {
        qWarning() << "Failed to reorder tasks: task set does not match date" << date;
        reportFailure(QStringLiteral("任务排序失败：任务列表已经变化，请刷新后重试"));
        db.rollback();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE tasks SET display_order = :order WHERE id = :id AND date = :date"));

    for (int i = 0; i < orderedTaskIds.size(); ++i) {
        const int taskId = orderedTaskIds.at(i).toInt();
        query.bindValue(QStringLiteral(":order"), i + 1);
        query.bindValue(QStringLiteral(":id"), taskId);
        query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
        if (!query.exec() || query.numRowsAffected() != 1) {
            qWarning() << "Failed to reorder tasks:" << query.lastError().text();
            reportFailure(QStringLiteral("任务排序失败：写入顺序失败"));
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit reorder:" << db.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法提交事务"));
        db.rollback();
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::moveTaskBefore(int taskId, int beforeTaskId)
{
    // 界面只交意图「把 X 移到 Y 之前」，整天的顺序由这里在库里重新算：iPad 的系统列表拖动
    // 只能表达这个意图；而且界面手里的列表是快照，拖动期间会过期（别的设备同步来了任务、
    // 撤销窗口里的任务还没真正删除）。让界面拼整天的 id 数组交上来，快照一过期整次排序就会被拒。
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to move task before another: invalid task id" << taskId;
        reportFailure(QStringLiteral("任务排序失败：任务编号无效"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to move task before another: database is not open";
        reportFailure(QStringLiteral("任务排序失败：数据库未打开"));
        return false;
    }
    // 读当天集合和写序号放在同一个事务里：写入基于的就是读到的那一版集合，读完之后别处增删任务，
    // 也不会让这次按旧集合写出撞号或漏号的序号；写到一半失败还能整体撤销。
    if (!db.transaction()) {
        qWarning() << "Failed to start move-before transaction:" << db.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法启动事务"));
        return false;
    }

    // 一条语句里先按 taskId 找到它所在的日期，再按今日页的显示口径读出当天全部任务
    // （与 getTasksByDate 的排序一致）；taskId 不存在时子查询为 NULL，读出的集合为空。
    QSqlQuery dayQuery(db);
    dayQuery.prepare(QStringLiteral(
        "SELECT id, completed FROM tasks "
        "WHERE date = (SELECT date FROM tasks WHERE id = :id) "
        "ORDER BY completed ASC, display_order ASC, created_at ASC, id ASC"));
    dayQuery.bindValue(QStringLiteral(":id"), taskId);
    if (!dayQuery.exec()) {
        qWarning() << "Failed to read tasks before move-before:" << dayQuery.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法读取当天任务"));
        db.rollback();
        return false;
    }
    QList<int> current;
    QSet<int> completed;
    while (dayQuery.next()) {
        const int id = dayQuery.value(0).toInt();
        current.append(id);
        if (dayQuery.value(1).toInt() != 0) {
            completed.insert(id);
        }
    }
    dayQuery.finish();

    QList<int> reordered;
    QString reason;
    if (!placeTaskBefore(current, completed, taskId, beforeTaskId, &reordered, &reason)) {
        qWarning() << "Failed to move task before another:" << reason
                   << "task" << taskId << "before" << beforeTaskId;
        reportFailure(QStringLiteral("任务排序失败：%1").arg(reason));
        db.rollback();
        return false;
    }

    // 顺序没变就不写：白写一遍会把历史遗留的重复或不连续序号全天重排成 1..N，
    // 同步出去的是一批没有意义的排序变化，还会触发各页一轮多余的刷新。
    // 到这里只读过，回滚只是结束事务。
    if (reordered == current) {
        db.rollback();
        return true;
    }

    QSqlQuery update(db);
    update.prepare(QStringLiteral("UPDATE tasks SET display_order = :order WHERE id = :id"));
    for (int i = 0; i < reordered.size(); ++i) {
        update.bindValue(QStringLiteral(":order"), i + 1);
        update.bindValue(QStringLiteral(":id"), reordered.at(i));
        // 恰好一行才算写成功：触发器静默跳过更新时影响行数是 0，不能当成成功提交。
        if (!update.exec() || update.numRowsAffected() != 1) {
            qWarning() << "Failed to move task before another: write failed for task" << reordered.at(i)
                       << "rows affected" << update.numRowsAffected() << update.lastError().text();
            reportFailure(QStringLiteral("任务排序失败：写入顺序失败"));
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit move-before:" << db.lastError().text();
        reportFailure(QStringLiteral("任务排序失败：无法提交事务"));
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
        reportFailure(QStringLiteral("任务改期失败：任务编号无效"));
        return false;
    }
    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to move task: invalid date";
        reportFailure(QStringLiteral("任务改期失败：日期无效"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to move task: database is not open";
        reportFailure(QStringLiteral("任务改期失败：数据库未打开"));
        return false;
    }

    // 改期到任务原来那天不算改期：直接成功，不写库、不发信号。照常写一次会把它挪到当天末尾，
    // 手排好的顺序就乱了，还白触发一轮刷新。Mac 周计划拖回原日和 iPad 的拖放都靠这里判断，
    // 界面不再各自比较日期；与 moveTasksToDate「已在目标日期的任务保持排序」同一口径。
    // 日期列存的是 ISO 字符串，按字符串比较，和 moveTasksToDate 里的 SQL 比较方式一致。
    QSqlQuery currentQuery(db);
    currentQuery.prepare(QStringLiteral("SELECT date FROM tasks WHERE id = :id"));
    currentQuery.bindValue(QStringLiteral(":id"), taskId);
    if (!currentQuery.exec()) {
        qWarning() << "Failed to move task:" << currentQuery.lastError().text();
        reportFailure(QStringLiteral("任务改期失败：数据库读取失败：%1").arg(currentQuery.lastError().text()));
        return false;
    }
    if (!currentQuery.next()) {
        qWarning() << "Failed to move task: task not found" << taskId;
        reportFailure(QStringLiteral("任务改期失败：任务不存在"));
        return false;
    }
    const bool alreadyOnTargetDate =
        currentQuery.value(0).toString() == date.toString(Qt::ISODate);
    currentQuery.finish();
    if (alreadyOnTargetDate) {
        return true;
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
        reportFailure(QStringLiteral("任务改期失败：数据库写入失败：%1").arg(query.lastError().text()));
        return false;
    }
    if (query.numRowsAffected() != 1) {
        qWarning() << "Failed to move task: task not found" << taskId;
        reportFailure(QStringLiteral("任务改期失败：任务不存在"));
        return false;
    }

    emit tasksChanged();
    return true;
}

ServiceReadResult<QVariantMap> TaskManager::readTask(int taskId) const
{
    if (taskId <= 0) return {{}, ServiceReadError::InvalidArgument};
    const auto db = DatabaseManager::instance()->database();
    if (!db.isOpen()) return {{}, ServiceReadError::Database};
    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral("WHERE t.id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);
    if (!query.exec()) return {{}, ServiceReadError::Database};
    if (!query.next()) return {{}, query.lastError().isValid() ? ServiceReadError::Database : ServiceReadError::NotFound};
    auto row = Task::fromQuery(query).toVariantMap();
    row.insert(QStringLiteral("persistedCategory"), query.value(QStringLiteral("persisted_category")));
    return {row};
}

ServiceReadResult<QVariantList> TaskManager::readTasks(const QDate& from, const QDate& to,
                                                       int completed, int limit, const QSet<int>& excluded) const
{
    if (!from.isValid() || !to.isValid() || from > to || from.daysTo(to) >= 31
        || completed < -1 || completed > 1 || limit < 1 || limit > 100)
        return {{}, ServiceReadError::InvalidArgument};
    const auto db = DatabaseManager::instance()->database();
    if (!db.isOpen()) return {{}, ServiceReadError::Database};
    QStringList placeholders;
    for (int i = 0; i < excluded.size(); ++i) placeholders.append(QStringLiteral(":excluded%1").arg(i));
    QString sql = taskSelectSql() + QStringLiteral("WHERE t.date BETWEEN :from AND :to AND (:completed < 0 OR t.completed = :completed) ");
    // 必须先排除撤销窗口里的任务再限量，不能把隐藏行占用的名额误报成查询溢出。
    if (!placeholders.isEmpty()) sql += QStringLiteral("AND t.id NOT IN (%1) ").arg(placeholders.join(','));
    sql += QStringLiteral("ORDER BY t.date, t.display_order, t.id LIMIT :limit");
    QSqlQuery query(db);
    query.prepare(sql);
    query.bindValue(QStringLiteral(":from"), from.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":to"), to.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":completed"), completed);
    query.bindValue(QStringLiteral(":limit"), limit + 1);
    int index = 0;
    for (int id : excluded) query.bindValue(placeholders.at(index++), id);
    if (!query.exec()) return {{}, ServiceReadError::Database};
    QVariantList rows;
    while (query.next()) {
        if (rows.size() == limit) return {{}, ServiceReadError::LimitExceeded};
        auto row = Task::fromQuery(query).toVariantMap();
        row.insert(QStringLiteral("persistedCategory"), query.value(QStringLiteral("persisted_category")));
        rows.append(row);
    }
    if (query.lastError().isValid()) return {{}, ServiceReadError::Database};
    return {rows};
}

ServiceReadResult<QList<int>> TaskManager::readPlannedMinutesByDay(const QDate& start, int days,
                                                                int excludedTaskId) const
{
    if (!start.isValid() || days < 1 || days > 31)
        return {{}, ServiceReadError::InvalidArgument};
    const auto db = DatabaseManager::instance()->database();
    if (!db.isOpen()) return {{}, ServiceReadError::Database};
    const QDate end = start.addDays(days - 1);
    QSqlQuery query(db);
    // 范围与 getWeekTasks / getTasksByDate 一样只按日期筛选，保证求和的就是页面上列出的那些任务。
    query.prepare(QStringLiteral(
        "SELECT date, SUM(MAX(estimated_minutes, 0)) FROM tasks "
        "WHERE date BETWEEN :from AND :to AND id <> :excluded GROUP BY date"));
    query.bindValue(QStringLiteral(":from"), start.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":to"), end.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":excluded"), excludedTaskId);
    if (!query.exec()) return {{}, ServiceReadError::Database};
    QList<int> minutes(days, 0);
    while (query.next()) {
        const qint64 index = start.daysTo(QDate::fromString(query.value(0).toString(), Qt::ISODate));
        if (index >= 0 && index < days)
            minutes[static_cast<qsizetype>(index)] = query.value(1).toInt();
    }
    if (query.lastError().isValid()) return {{}, ServiceReadError::Database};
    return {minutes};
}
