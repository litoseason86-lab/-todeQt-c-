#ifndef TRASHSTORE_H
#define TRASHSTORE_H

#include <QObject>
#include <QSqlDatabase>
#include <QString>
#include <QVariant>

// 废纸篓的写入端（计划 054）。七个删除接口都要在自己的事务里、真正删除之前调用它，
// 所以这里刻意只依赖 Qt Core/Sql：不包含任何服务头文件，也不取 DatabaseManager 单例，
// 一切函数都接收调用方的连接并在调用方的事务内执行（写法同 RoutineManager 的 reclaimTodayTask）。
// 这样「写废纸篓」与「删除」同进同退：写入失败，调用方回滚，原记录还在。
namespace TrashStore {

// 类型常量。库里 kind 不加取值 CHECK（见 DatabaseManager::createTrashTable），
// 以后加了新类型，旧版收到也能列出来。
const QString kKindTask = QStringLiteral("task");
const QString kKindFocusSession = QStringLiteral("focus_session");
const QString kKindRestSession = QStringLiteral("rest_session");
const QString kKindKnowledgeGap = QStringLiteral("knowledge_gap");
const QString kKindMemo = QStringLiteral("memo");
const QString kKindRoutine = QStringLiteral("routine");
const QString kKindScheduleEntry = QStringLiteral("schedule_entry");
const QString kKindCountdownGoal = QStringLiteral("countdown_goal");

// capture* 在行不存在时写进 error 的原因。各服务据此区分「记录不存在」与「写废纸篓失败」，
// 引用同一个常量，避免多处各写一遍字符串。
const QString kMissingRecord = QStringLiteral("记录不存在");

// payload 格式版本；恢复时不认识的版本一律拒绝（提示需要更新应用）。
constexpr int kPayloadVersion = 1;

// 按 sync_id 找本机编号。目标已被同名合并掉的科目，顺着 sync_tombstones 里 kind = 'merge' 的记录
// 追到留下的那条（最多 16 跳，写法与跳数都同 SyncStore 的 resolveLocal）。找不到返回无效 QVariant。
// ok 可选：查询本身失败时置 false（与「找不到」区分）；恢复路径据此整体回滚，不能把查询失败当成没有这个科目或任务。
QVariant resolveSyncId(QSqlDatabase& db, const QString& table, const QString& syncId, bool* ok = nullptr);

// 以下 capture* 都是「读出整行与关联，写一行 trash_items」。行不存在返回 false 并写 error（kMissingRecord）；查关联的 SQL 失败同样返回 false 并带原因，调用方回滚、删除失败。
bool captureTask(QSqlDatabase& db, int taskId, QString* error);
// 只认已结束的记录，与删除条件一致；进行中的不进废纸篓（返回 false）。
bool captureFocusSession(QSqlDatabase& db, int sessionId, QString* error);
bool captureRestSession(QSqlDatabase& db, int sessionId, QString* error);
bool captureKnowledgeGap(QSqlDatabase& db, int gapId, QString* error);
// 标题与正文 trim 后都为空的备忘不进废纸篓：直接返回 true，不插入。
bool captureMemo(QSqlDatabase& db, int memoId, QString* error);
// reclaimedToday：删除例行时是否顺带收回了当日没动过的实例。是的话生成戳存 null，
// 恢复后当天补生成（与「停用后再启用」同一套语义）。
bool captureRoutine(QSqlDatabase& db, int routineId, bool reclaimedToday, QString* error);
bool captureScheduleEntry(QSqlDatabase& db, int entryId, QString* error);
bool captureCountdownGoal(QSqlDatabase& db, int goalId, QString* error);

} // namespace TrashStore

// 删除成功（事务已提交）后由各服务发出；TrashService 据此发 trashChanged。
// 单独放一个轻量对象，是为了让七个服务不必依赖 TrashService（它依赖各服务，会成环）。
class TrashNotifier : public QObject
{
    Q_OBJECT

public:
    static TrashNotifier* instance();

signals:
    void changed();

private:
    explicit TrashNotifier(QObject* parent = nullptr);
};

#endif // TRASHSTORE_H
