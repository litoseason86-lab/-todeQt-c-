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
#include <QSet>
#include <QVariant>

#include <cmath>
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
        return -1;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to add task: title exceeds" << kMaxTitleLength << "characters";
        return -1;
    }
    if (notes.size() > kMaxNotesLength) {
        qWarning() << "Failed to add task: notes exceed" << kMaxNotesLength << "characters";
        return -1;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to add task: invalid date";
        return -1;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add task: database is not open";
        return -1;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (categoryId > 0) {
        QSqlQuery categoryQuery(db);
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName)) {
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
    // 只改 completed 一列，完成记录原样保留：取消完成（包括撤销条）多半是点错了，
    // 把用户刚写的记录一并抹掉就找不回来了。任务未完成时界面不显示这条记录，
    // 再次完成时弹窗会把它预填回来。
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

bool TaskManager::completeTaskWithNote(int taskId, const QString& note)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to complete task with note: invalid task id" << taskId;
        return false;
    }
    // 超长拒绝而不是截断，理由与备注相同：截断会让保存照常「成功」，丢的往往是结论那段。
    if (note.size() > kMaxNotesLength) {
        qWarning() << "Failed to complete task with note: note exceeds" << kMaxNotesLength
                   << "characters";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to complete task with note: database is not open";
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
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to complete task with note: task not found" << taskId;
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
            return false;
        }
        // 文本字段必须真是字符串：QML 的 undefined/null 不能被悄悄当成「清空」。
        if (textField && it.value().typeId() != QMetaType::QString) {
            qWarning() << "Failed to update task: field" << key << "must be text";
            return false;
        }
    }
    if (changes.isEmpty()) {
        return readTask(taskId).ok();
    }

    // QML 的数字以浮点数传入。科目编号、预计用时都要是整数，不能把 1.5 悄悄当成 1。
    auto integerOf = [&changes](const QString& key, int* result) {
        bool ok = false;
        const double number = changes.value(key).toDouble(&ok);
        if (!ok || number != std::floor(number) || number < -1
            || number > std::numeric_limits<int>::max()) {
            return false;
        }
        *result = static_cast<int>(number);
        return true;
    };
    int categoryId = -1;
    if (changes.contains(categoryKey) && !integerOf(categoryKey, &categoryId)) {
        qWarning() << "Failed to update task: invalid category id";
        return false;
    }
    int estimatedMinutes = -1; // -1 = 预计用时保持不变
    if (changes.contains(estimateKey) && (!integerOf(estimateKey, &estimatedMinutes) || estimatedMinutes < 0)) {
        qWarning() << "Failed to update task: invalid estimated minutes";
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
        return false;
    }

    // 保留标题时整句 SQL 都不碰 title 列，所以也不校验传进来的标题。
    const QString normalizedTitle = title.trimmed();
    if (!preserveTitle && normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update task: title is empty after trimming";
        return false;
    }
    if (!preserveTitle && normalizedTitle.size() > kMaxTitleLength) {
        qWarning() << "Failed to update task: title exceeds" << kMaxTitleLength << "characters";
        return false;
    }

    // 保留日期时同样不碰 date 列，也不校验传进来的日期。
    const QDate date = preserveDate ? QDate() : normalizeDate(dateValue);
    if (!preserveDate && !date.isValid()) {
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
    if (!preserveCategory && categoryId > 0) {
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
    if (updateNotes && notes.size() > kMaxNotesLength) {
        qWarning() << "Failed to update task: notes exceed" << kMaxNotesLength << "characters";
        return false;
    }
    // 完成记录与备注共用同一上限，超长同样整次拒绝，其它字段也不落库。
    if (completionNote && completionNote->size() > kMaxNotesLength) {
        qWarning() << "Failed to update task: completion note exceeds" << kMaxNotesLength
                   << "characters";
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
        return readTask(taskId).ok();
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
        return false;
    }

    if (query.numRowsAffected() != 1) {
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
    if (query.numRowsAffected() != 1) {
        qWarning() << "Failed to move task: task not found" << taskId;
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
