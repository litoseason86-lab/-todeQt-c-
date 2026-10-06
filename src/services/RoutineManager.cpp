#include "RoutineManager.h"

#include "AppSettings.h"
#include "CategoryManager.h"
#include "DatabaseManager.h"
#include "LogicalDay.h"
#include "QmlValues.h"
#include "RoutineRules.h"
#include "SyncSchema.h"
#include "TaskManager.h"

#include <QDate>
#include <QDebug>
#include <QList>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariantMap>

#include <limits>

namespace {
struct DueRoutine {
    int id = 0;
    QString title;
    QVariant categoryId;
};

QVariant nullableCategoryId(int categoryId)
{
    // categoryId <= 0 是 QML 层传入的“未选择科目”哨兵值，数据库里必须落成 NULL，
    // 这样删除科目和左连接查询都能保持统一语义。
    return categoryId > 0 ? QVariant(categoryId) : QVariant();
}

bool routineWeekdaysAreValid(int weekdays, const char* action)
{
    // 掩码越界（含 0「一天都不选」）一律拒绝：存下去的话这条例行再也不会生成任务，
    // 用户只会看到「保存成功但任务没出现」，查不出原因。
    if (!RoutineRules::isValidWeekdayMask(weekdays)) {
        qWarning().noquote() << QStringLiteral("Failed to %1 routine: invalid weekday mask")
                                    .arg(QString::fromLatin1(action))
                             << weekdays;
        return false;
    }
    return true;
}

bool routineCategoryExists(QSqlDatabase& db, int categoryId, const char* action)
{
    if (categoryId <= 0) {
        return true;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT 1 FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), categoryId);
    if (!query.exec()) {
        qWarning() << "Failed to validate routine category:" << query.lastError().text();
        return false;
    }

    if (!query.next()) {
        qWarning().noquote() << QStringLiteral("Failed to %1 routine: category not found").arg(QString::fromLatin1(action)) << categoryId;
        return false;
    }

    return true;
}

// 例行的「今天」必须和 materializeToday 用同一口径：逻辑日把凌晨日界点之前算作前一天。
// 两处各算各的话，凌晨两点改例行会去动错一天的任务。
QDate logicalTodayDate()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

QString logicalTodayString()
{
    return logicalTodayDate().toString(Qt::ISODate);
}

// 把今天已经生成的那条实例同步成例行的新标题/新科目。
// 只认 routine_generated = 1 的行：routine_id 单独存在并不能证明任务由规则生成
// （旧库曾经按标题回填过这一列），据此改写会误伤用户自己建的同名任务。
// 当日实例即使已经完成也一起改：改名不破坏任何数据，而列表上摆着旧名字正是用户报的那个问题。
bool syncTodayTaskToRoutine(QSqlDatabase& db, int routineId, const QString& title,
                            int categoryId, const QString& today, bool* synced)
{
    QSqlQuery query(db);
    // category 这一列存的是科目名快照，写法必须和 materializeToday 的插入保持一致。
    // 漏掉它的话只有 category_id 悄悄变了，任务卡上的科目标签仍停在旧科目名。
    query.prepare(QStringLiteral(
        "UPDATE tasks "
        "SET title = :title, category_id = :categoryId, "
        "category = COALESCE((SELECT name FROM categories WHERE id = :categoryId), '') "
        "WHERE routine_id = :routineId AND routine_generated = 1 AND date = :today"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":categoryId"), nullableCategoryId(categoryId));
    query.bindValue(QStringLiteral(":routineId"), routineId);
    query.bindValue(QStringLiteral(":today"), today);

    if (!query.exec()) {
        qWarning() << "Failed to sync today's routine task:" << query.lastError().text();
        return false;
    }

    if (synced) {
        *synced = query.numRowsAffected() > 0;
    }
    return true;
}

// 规则不再要求今天做这件事时（删除、停用、把今天从重复日里去掉），收回今天生成的那条任务。
// 判据故意收得很紧，只收「未完成且一次专注都没开始过」的：
// - 已完成：那是今天确实做过的事实，删掉会让当天的完成记录和完成率凭空少一条。
// - 有 focus_sessions：专注记录在「开始专注」那一刻就已落库，所以这一条同时挡住了正在计时的
//   任务，不会出现计时器还在跑、任务行却已经消失的状态。
// 不满足判据的当日实例留在原地，由调用方按老办法退化成普通任务。
// 必须在调用方的事务里执行：先选出编号、再按编号删除，两步之间不能有别的写入插进来。
bool reclaimTodayTask(QSqlDatabase& db, int routineId, const QString& today,
                      QList<int>* reclaimedIds)
{
    QSqlQuery candidates(db);
    candidates.prepare(QStringLiteral(
        "SELECT t.id FROM tasks t "
        "WHERE t.routine_id = :routineId AND t.routine_generated = 1 "
        "AND t.date = :today AND t.completed = 0 "
        "AND NOT EXISTS (SELECT 1 FROM focus_sessions fs WHERE fs.task_id = t.id)"));
    candidates.bindValue(QStringLiteral(":routineId"), routineId);
    candidates.bindValue(QStringLiteral(":today"), today);

    if (!candidates.exec()) {
        qWarning() << "Failed to find reclaimable routine task:" << candidates.lastError().text();
        return false;
    }

    QList<int> ids;
    while (candidates.next()) {
        ids.append(candidates.value(0).toInt());
    }
    candidates.finish();

    // 同步：这些删除要记成「收回」，而不是用户删除。用户删掉的实例删除优先、永不复活；
    // 收回的实例在重新启用后还要能再生成出来，另一台设备收到时也按「收回」处理（没动过才删）。
    // 同步触发器读 sync_runtime.delete_kind 决定删除记录的类别；在调用方的事务里置位、删完立刻复位，
    // 中途失败整个事务回滚，标记也随之复原。
    QSqlQuery mark(db);
    if (!ids.isEmpty()
        && !mark.exec(QStringLiteral("UPDATE sync_runtime SET delete_kind = 'reclaim' WHERE singleton_id = 1"))) {
        qWarning() << "Failed to mark routine reclaim:" << mark.lastError().text();
        return false;
    }

    // 编号要先取出来，是因为删除之后得逐条广播 taskDeleted；一条 DELETE 带判据虽然也能删干净，
    // 却拿不到删掉了谁。专注记录不用解绑：判据已经保证这些任务一条专注记录都没有。
    for (int taskId : ids) {
        QSqlQuery remove(db);
        remove.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
        remove.bindValue(QStringLiteral(":id"), taskId);
        if (!remove.exec()) {
            qWarning() << "Failed to reclaim routine task:" << remove.lastError().text();
            return false;
        }
        if (remove.numRowsAffected() > 0 && reclaimedIds) {
            reclaimedIds->append(taskId);
        }
    }

    if (!ids.isEmpty()
        && !mark.exec(QStringLiteral("UPDATE sync_runtime SET delete_kind = NULL WHERE singleton_id = 1"))) {
        qWarning() << "Failed to clear routine reclaim mark:" << mark.lastError().text();
        return false;
    }
    return true;
}

// 把生成戳退回 NULL。调用方只在真的收回了当日实例时才调用它：
// 这样「停用后又启用」「取消今天后又勾回今天」都能把今天的任务补回来；
// 而用户自己删掉当日实例之后再停用，戳仍停在今天，重新启用也不会复活它——
// 「删不复活」是例行生成一直守着的性质，回收路径不能把它打破。
bool clearGenerationStamp(QSqlDatabase& db, int routineId)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE routines SET last_generated_date = NULL WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), routineId);
    if (!query.exec()) {
        qWarning() << "Failed to clear routine generation stamp:" << query.lastError().text();
        return false;
    }
    return true;
}
}

RoutineManager::RoutineManager(QObject* parent)
    : QObject(parent)
{
    // getRoutines() 左连 categories；分类改名、换色或删除都会改变返回值，
    // 因此把分类变化转发成 routinesChanged，避免 QML 列表停留在旧分类状态。
    connect(CategoryManager::instance(), &CategoryManager::categoriesChanged,
            this, &RoutineManager::routinesChanged);
    // CategoryManager 已经把换库事件归一为 categoriesChanged。不要再直连数据库，
    // 否则一次恢复/重开会沿两条同步链路刷新两遍例行列表。
}

RoutineManager* RoutineManager::instance()
{
    static RoutineManager manager;
    return &manager;
}

void RoutineManager::reportFailure(const QString& message) const
{
    emit const_cast<RoutineManager*>(this)->operationFailed(message);
}

void RoutineManager::notifyTasksReclaimed(const QList<int>& taskIds) const
{
    if (taskIds.isEmpty()) {
        return;
    }

    TaskManager* taskManager = TaskManager::instance();
    // 顺序与 TaskManager::deleteTask 保持一致：先逐条广播精确的删除事实，让计时器这类
    // 持有任务编号的服务先解绑，再发列表刷新信号。反过来的话，订阅 tasksChanged 的页面
    // 会先观察到「任务已删、计时器还绑着旧编号」的中间状态。
    for (int taskId : taskIds) {
        emit taskManager->taskDeleted(taskId);
    }
    emit taskManager->tasksChanged();
}

bool RoutineManager::addRoutine(const QString& title, int categoryId, int weekdays)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning("Failed to add routine: title is empty");
        return false;
    }
    // 例行标题会物化成任务标题，必须遵守同一上限。
    if (normalizedTitle.size() > TaskManager::kMaxTitleLength) {
        qWarning() << "Failed to add routine: title exceeds"
                   << TaskManager::kMaxTitleLength << "characters";
        return false;
    }

    if (!routineWeekdaysAreValid(weekdays, "add")) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add routine: database is not open";
        return false;
    }
    if (!routineCategoryExists(db, categoryId, "add")) {
        return false;
    }

    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), 0) + 1 FROM routines"))
        || !orderQuery.next()) {
        qWarning() << "Failed to calculate routine display order:" << orderQuery.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id, display_order, weekdays) "
        "VALUES (:title, :categoryId, :displayOrder, :weekdays)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":categoryId"), nullableCategoryId(categoryId));
    query.bindValue(QStringLiteral(":displayOrder"), orderQuery.value(0).toInt());
    query.bindValue(QStringLiteral(":weekdays"), weekdays);

    if (!query.exec()) {
        qWarning() << "Failed to add routine:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::updateRoutineChanges(int id, const QVariantMap& changes)
{
    const QString titleKey = QStringLiteral("title");
    const QString categoryKey = QStringLiteral("categoryId");
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        if (it.key() != titleKey && it.key() != categoryKey) {
            qWarning() << "Failed to update routine: unknown field" << it.key();
            return false;
        }
    }
    if (changes.contains(titleKey) && changes.value(titleKey).typeId() != QMetaType::QString) {
        qWarning() << "Failed to update routine: title must be text";
        return false;
    }
    int categoryId = 0;
    if (changes.contains(categoryKey)
        && !QmlValues::integer(changes.value(categoryKey), -1, std::numeric_limits<int>::max(), &categoryId)) {
        qWarning() << "Failed to update routine: invalid category id";
        return false;
    }
    if (id <= 0) {
        qWarning() << "Failed to update routine: invalid id" << id;
        return false;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update routine: database is not open";
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT title, category_id FROM routines WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        qWarning() << "Failed to read routine:" << query.lastError().text();
        return false;
    }
    if (!query.next()) {
        qWarning() << "Failed to update routine: routine not found" << id;
        return false;
    }
    const QString currentTitle = query.value(0).toString();
    const int currentCategoryId = query.value(1).isNull() ? 0 : query.value(1).toInt();
    query.finish();
    if (changes.isEmpty()) {
        return true;
    }
    // 没交的字段用库里现在的值再写一遍：值没变，同步就不会把它记成本机修改，也就不会盖掉另一台。
    // 前提是库里的值已按 updateRoutine 同一套规则规范化（标题裁剪空白）：现有写入入口和另一台同步过来的数据都满足。
    // 以后新增不经这套规则的写入路径，或改了规范化规则，要改成只更新交进来的列，否则会顺手改写没交的字段。
    // 数据库只在主线程读写，读和写之间同步插不进来。
    return updateRoutine(id, changes.contains(titleKey) ? changes.value(titleKey).toString() : currentTitle,
                         changes.contains(categoryKey) ? categoryId : currentCategoryId);
}

bool RoutineManager::updateRoutine(int id, const QString& title, int categoryId)
{
    if (id <= 0) {
        qWarning() << "Failed to update routine: invalid id" << id;
        return false;
    }

    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update routine: title is empty";
        return false;
    }
    if (normalizedTitle.size() > TaskManager::kMaxTitleLength) {
        qWarning() << "Failed to update routine: title exceeds"
                   << TaskManager::kMaxTitleLength << "characters";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update routine: database is not open";
        return false;
    }
    if (!routineCategoryExists(db, categoryId, "update")) {
        return false;
    }

    // 规则和今天那条实例要么一起改完，要么都不改：只改成功一半的话，
    // 列表里的规则已是新名字，今日任务却还挂着旧名字，用户无从判断哪个才算数。
    if (!db.transaction()) {
        qWarning() << "Failed to start routine update transaction:" << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    // 这条语句刻意不出现 weekdays：改标题/科目与改重复日是两个独立入口，
    // 谁也不该顺手覆盖对方。重复日走 setRoutineWeekdays。
    query.prepare(QStringLiteral(
        "UPDATE routines SET title = :title, category_id = :categoryId WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":categoryId"), nullableCategoryId(categoryId));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update routine:" << query.lastError().text();
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update routine: routine not found" << id;
        db.rollback();
        return false;
    }

    // 改规则的同时把今天已经生成的实例一并改掉：不改的话用户改完名字，
    // 今日任务列表里仍然是旧标题、旧科目，要等到明天生成新任务才对得上。
    bool taskSynced = false;
    if (!syncTodayTaskToRoutine(db, id, normalizedTitle, categoryId, logicalTodayString(),
                                &taskSynced)) {
        db.rollback();
        return false;
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit routine update:" << db.lastError().text();
        db.rollback();
        return false;
    }

    if (taskSynced) {
        // 当日实例被改过，任务列表也得刷新。跨服务发 TaskManager 的信号是本项目既有写法
        // （FocusTimer 写完会话后同样这么通知），只订阅 tasksChanged 的页面（周计划等）才不会掉队。
        // 与另外三个写入口一样，先发任务侧信号，再发规则侧信号。
        emit TaskManager::instance()->tasksChanged();
    }
    emit routinesChanged();
    return true;
}

bool RoutineManager::deleteRoutine(int id)
{
    if (id <= 0) {
        qWarning() << "Failed to delete routine: invalid id" << id;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete routine: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start routine delete transaction:" << db.lastError().text();
        return false;
    }

    // 先收回今天那条还没动过的实例，再处理其余任务。顺序不能反：detach 会把 routine_id 清成
    // NULL，先 detach 的话回收查询按 routine_id 就再也找不到这条任务了。
    QList<int> reclaimedTaskIds;
    if (!reclaimTodayTask(db, id, logicalTodayString(), &reclaimedTaskIds)) {
        db.rollback();
        return false;
    }

    // 删除规则后，历史任务必须退化成普通任务。只让外键把 routine_id 置空会留下
    // routine_generated=1，逾期结转仍把它当成受规则管理的任务，最终形成不可见黑洞。
    QSqlQuery detachTasks(db);
    detachTasks.prepare(QStringLiteral(
        "UPDATE tasks SET routine_id = NULL, routine_generated = 0 WHERE routine_id = :id"));
    detachTasks.bindValue(QStringLiteral(":id"), id);
    if (!detachTasks.exec()) {
        qWarning() << "Failed to detach tasks before deleting routine:"
                   << detachTasks.lastError().text();
        db.rollback();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM routines WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to delete routine:" << query.lastError().text();
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to delete routine: routine not found" << id;
        db.rollback();
        return false;
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit routine deletion:" << db.lastError().text();
        db.rollback();
        return false;
    }

    notifyTasksReclaimed(reclaimedTaskIds);
    emit routinesChanged();
    return true;
}

bool RoutineManager::setRoutineActive(int id, bool active)
{
    if (id <= 0) {
        qWarning() << "Failed to set routine active: invalid id" << id;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to set routine active: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start routine active transaction:" << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE routines SET active = :active WHERE id = :id"));
    query.bindValue(QStringLiteral(":active"), active ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to set routine active:" << query.lastError().text();
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to set routine active: routine not found" << id;
        db.rollback();
        return false;
    }

    // 停用表示「这件事先不做了」，今天那条还没动过的实例要跟着收回，
    // 否则开关关掉了，今日任务列表里还挂着它，用户只能再手动删一次。
    // 重新启用不在这里补发：停用时若收回过实例，戳已退回 NULL，下一次 materializeToday
    // 自然会把它生成回来；没收回过（用户已手动删掉，或实例已完成/专注过）则戳仍是今天，不会重复生成。
    QList<int> reclaimedTaskIds;
    if (!active) {
        if (!reclaimTodayTask(db, id, logicalTodayString(), &reclaimedTaskIds)) {
            db.rollback();
            return false;
        }
        if (!reclaimedTaskIds.isEmpty() && !clearGenerationStamp(db, id)) {
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit routine active change:" << db.lastError().text();
        db.rollback();
        return false;
    }

    notifyTasksReclaimed(reclaimedTaskIds);
    emit routinesChanged();
    return true;
}

bool RoutineManager::setRoutineWeekdays(int id, int weekdays)
{
    if (id <= 0) {
        qWarning() << "Failed to set routine weekdays: invalid id" << id;
        return false;
    }

    if (!routineWeekdaysAreValid(weekdays, "set weekdays of")) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to set routine weekdays: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start routine weekdays transaction:" << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE routines SET weekdays = :weekdays WHERE id = :id"));
    query.bindValue(QStringLiteral(":weekdays"), weekdays);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to set routine weekdays:" << query.lastError().text();
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to set routine weekdays: routine not found" << id;
        db.rollback();
        return false;
    }

    // 新的重复日里已经没有今天，就把今天那条还没动过的实例收回。
    // 反方向（今天刚被勾上）不在这里补发：只要戳不是今天，下一次 materializeToday 自然会生成；
    // 戳是今天（实例还在，或被用户手动删掉）则不会重复生成。两个方向因此是对称的。
    // 星期和日期字符串必须出自同一次取值：分两次取的话恰好跨过日界点，
    // 会按「新的一天」判星期、却去收「旧的一天」的任务。
    QList<int> reclaimedTaskIds;
    const QDate today = logicalTodayDate();
    const int todayBit = RoutineRules::maskForDayOfWeek(today.dayOfWeek());
    if ((weekdays & todayBit) == 0) {
        if (!reclaimTodayTask(db, id, today.toString(Qt::ISODate), &reclaimedTaskIds)) {
            db.rollback();
            return false;
        }
        if (!reclaimedTaskIds.isEmpty() && !clearGenerationStamp(db, id)) {
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit routine weekdays change:" << db.lastError().text();
        db.rollback();
        return false;
    }

    notifyTasksReclaimed(reclaimedTaskIds);
    // 列表要立刻显示新的重复日，所以照常发变更信号。
    emit routinesChanged();
    return true;
}

QVariantList RoutineManager::getRoutines() const
{
    QVariantList routines;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get routines: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载每日例行"));
        return routines;
    }

    QSqlQuery query(db);
    if (!query.exec(QStringLiteral(
            "SELECT r.id, r.title, r.category_id, c.name, c.color, r.active, r.display_order, "
            "r.weekdays "
            "FROM routines r "
            "LEFT JOIN categories c ON c.id = r.category_id "
            "ORDER BY r.display_order ASC, r.id ASC"))) {
        qWarning() << "Failed to get routines:" << query.lastError().text();
        reportFailure(QStringLiteral("每日例行加载失败: %1").arg(query.lastError().text()));
        return routines;
    }

    while (query.next()) {
        QVariantMap routine;
        routine.insert(QStringLiteral("id"), query.value(0).toInt());
        routine.insert(QStringLiteral("title"), query.value(1).toString());
        routine.insert(QStringLiteral("categoryId"), query.value(2).isNull() ? -1 : query.value(2).toInt());
        routine.insert(QStringLiteral("categoryName"), query.value(3));
        routine.insert(QStringLiteral("categoryColor"), query.value(4));
        routine.insert(QStringLiteral("active"), query.value(5).toBool());
        routine.insert(QStringLiteral("displayOrder"), query.value(6).toInt());
        // 重复日只把位掩码原样交给 QML；星期文案由界面层拼，服务层不生产展示字符串。
        routine.insert(QStringLiteral("weekdays"), query.value(7).toInt());
        routines.append(routine);
    }

    return routines;
}

int RoutineManager::materializeToday()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to materialize routines: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法生成每日例行"));
        return 0;
    }

    // 例行任务属于逻辑日；凌晨日界点前生成时仍应落在前一天。
    const QDate todayDate = logicalTodayDate();
    const QString today = todayDate.toString(Qt::ISODate);
    // 星期同样按逻辑日取：凌晨 2 点（默认日界前）做的例行属于昨天那一档，
    // 若改用自然日的星期，周一凌晨会错按「周一」去生成周日的例行。
    const int todayWeekdayMask = RoutineRules::maskForDayOfWeek(todayDate.dayOfWeek());

    QList<DueRoutine> dueRoutines;
    QSqlQuery dueQuery(db);
    dueQuery.prepare(QStringLiteral(
        "SELECT id, title, category_id "
        "FROM routines "
        "WHERE active = 1 "
        "AND (weekdays & :weekdayMask) != 0 "
        "AND (last_generated_date IS NULL OR last_generated_date < :today) "
        "ORDER BY display_order ASC, id ASC"));
    dueQuery.bindValue(QStringLiteral(":today"), today);
    dueQuery.bindValue(QStringLiteral(":weekdayMask"), todayWeekdayMask);

    if (!dueQuery.exec()) {
        qWarning() << "Failed to materialize routines:" << dueQuery.lastError().text();
        reportFailure(QStringLiteral("每日例行生成失败: %1").arg(dueQuery.lastError().text()));
        return 0;
    }

    while (dueQuery.next()) {
        DueRoutine routine;
        routine.id = dueQuery.value(0).toInt();
        routine.title = dueQuery.value(1).toString();
        routine.categoryId = dueQuery.value(2);
        dueRoutines.append(routine);
    }
    dueQuery.finish();

    if (dueRoutines.isEmpty()) {
        return 0;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to materialize routines: failed to start transaction" << db.lastError().text();
        reportFailure(QStringLiteral("每日例行生成失败: %1").arg(db.lastError().text()));
        return 0;
    }

    int generatedCount = 0;
    for (const DueRoutine& routine : dueRoutines) {
        QSqlQuery claimRoutine(db);
        claimRoutine.prepare(QStringLiteral(
            "UPDATE routines "
            "SET last_generated_date = :today "
            "WHERE id = :id "
            "AND active = 1 "
            "AND (weekdays & :weekdayMask) != 0 "
            "AND (last_generated_date IS NULL OR last_generated_date < :today)"));
        claimRoutine.bindValue(QStringLiteral(":today"), today);
        claimRoutine.bindValue(QStringLiteral(":weekdayMask"), todayWeekdayMask);
        claimRoutine.bindValue(QStringLiteral(":id"), routine.id);

        // 先用条件 UPDATE 抢占本次生成权。即使多个实例同时读到同一个 due routine，
        // 也只有真正把 last_generated_date 改到今天的实例才能继续插入任务。
        if (!claimRoutine.exec()) {
            qWarning() << "Failed to claim routine generation:" << claimRoutine.lastError().text();
            reportFailure(QStringLiteral("每日例行生成失败: %1").arg(claimRoutine.lastError().text()));
            db.rollback();
            return 0;
        }
        if (claimRoutine.numRowsAffected() == 0) {
            continue;
        }

        // 同步：同一例行同一天的实例在所有设备上是同一条记录，身份是「例行的 sync_id + 日期」。
        // 另一台设备已经生成并同步过来了，就不再生成一份；用户删掉过的（普通删除）删除优先，不复活。
        // 「收回」过的（停用后又启用、取消今天后又勾回）照常重新生成，触发器会用真实版本取代那条收回记录。
        // 生成权照样抢占（上面的戳已经写成今天），今天不会再来一遍。
        QSqlQuery identity(db);
        identity.prepare(QStringLiteral("SELECT sync_id FROM routines WHERE id = :id"));
        identity.bindValue(QStringLiteral(":id"), routine.id);
        if (!identity.exec() || !identity.next()) {
            qWarning() << "Failed to read routine sync id:" << identity.lastError().text();
            reportFailure(QStringLiteral("每日例行生成失败: %1").arg(identity.lastError().text()));
            db.rollback();
            return 0;
        }
        const QString routineSyncId = identity.value(0).toString();
        identity.finish();
        const QString instanceId = routineSyncId.isEmpty()
            ? QString() : SyncSchema::routineInstanceSyncId(routineSyncId, today);
        if (!instanceId.isEmpty()) {
            QSqlQuery existing(db);
            existing.prepare(QStringLiteral(
                "SELECT EXISTS (SELECT 1 FROM tasks WHERE sync_id = :id) "
                "OR EXISTS (SELECT 1 FROM sync_tombstones WHERE tbl = 'tasks' AND sync_id = :id2 "
                "AND kind <> 'reclaim')"));
            existing.bindValue(QStringLiteral(":id"), instanceId);
            existing.bindValue(QStringLiteral(":id2"), instanceId);
            if (!existing.exec() || !existing.next()) {
                qWarning() << "Failed to check routine instance:" << existing.lastError().text();
                reportFailure(QStringLiteral("每日例行生成失败: %1").arg(existing.lastError().text()));
                db.rollback();
                return 0;
            }
            if (existing.value(0).toInt() == 1) {
                continue;
            }
        }

        QSqlQuery insertTask(db);
        insertTask.prepare(QStringLiteral(
            "INSERT INTO tasks (title, category, category_id, date, completed, routine_id, "
            "routine_generated, display_order, sync_id) "
            "VALUES (:title, COALESCE((SELECT name FROM categories WHERE id = :categoryId), ''), "
            ":categoryId, :date, 0, :routineId, 1, "
            "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate), :syncId)"));
        insertTask.bindValue(QStringLiteral(":syncId"), instanceId.isEmpty() ? QVariant() : QVariant(instanceId));
        insertTask.bindValue(QStringLiteral(":title"), routine.title);
        insertTask.bindValue(QStringLiteral(":categoryId"), routine.categoryId);
        insertTask.bindValue(QStringLiteral(":date"), today);
        insertTask.bindValue(QStringLiteral(":orderDate"), today);
        // routine_generated 是可信来源标记；routine_id 单独存在不能证明任务由规则生成。
        insertTask.bindValue(QStringLiteral(":routineId"), routine.id);

        // 这里刻意直接写 SQL，而不调用 TaskManager::addTask：
        // TaskManager 会发 tasksChanged，应用启动时生成例行任务再触发刷新，容易形成递归刷新链。
        // 事务把“抢占生成权”和“插入任务”绑定成一个原子动作，避免只完成一半后下次重复生成。
        if (!insertTask.exec() || insertTask.numRowsAffected() != 1) {
            qWarning() << "Failed to materialize routine task:" << insertTask.lastError().text();
            reportFailure(QStringLiteral("每日例行生成失败: %1").arg(insertTask.lastError().text()));
            db.rollback();
            return 0;
        }

        ++generatedCount;
    }

    if (!db.commit()) {
        qWarning() << "Failed to materialize routines: failed to commit transaction" << db.lastError().text();
        reportFailure(QStringLiteral("每日例行生成失败: %1").arg(db.lastError().text()));
        db.rollback();
        return 0;
    }

    return generatedCount;
}
