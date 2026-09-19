#include "TaskInteractionCoordinator.h"
#include "TaskManager.h"

TaskInteractionCoordinator::TaskInteractionCoordinator(TaskManager* tasks, QObject* parent)
    : QObject(parent), m_tasks(tasks) {}

bool TaskInteractionCoordinator::begin(QObject* owner, Kind kind, int taskId, const QString& source)
{
    if (!owner || taskId <= 0) return false;
    if (kind != PendingDelete && pendingTaskIds().contains(taskId)) {
        m_error = QStringLiteral("任务正在等待删除，请先撤销或等待删除完成");
        emit changed();
        return false;
    }
    // 替换登记不经过中间的“空闲”状态，防止 changed 信号同步触发列表重建。
    auto old = m_entries.find(owner);
    if (old != m_entries.end()) QObject::disconnect(old->destroyed);
    const auto connection = connect(owner, &QObject::destroyed, this, [this, owner] { end(owner); });
    m_entries.insert(owner, {owner, kind, taskId, source, connection});
    m_error.clear();
    emit changed();
    return true;
}
QVariantMap TaskInteractionCoordinator::beginEdit(QObject* owner, int taskId, const QString& source)
{
    if (!begin(owner, Editing, taskId, source)) return {};
    const auto result = m_tasks->readTask(taskId);
    if (!result.ok()) {
        end(owner);
        m_error = result.error == ServiceReadError::NotFound ? QStringLiteral("任务已不存在") : QStringLiteral("读取最新任务失败");
        emit changed();
        return {};
    }
    return result.value;
}
bool TaskInteractionCoordinator::beginDrag(QObject* owner, int taskId, const QString& source)
{
    return begin(owner, Dragging, taskId, source);
}
void TaskInteractionCoordinator::setPendingDelete(QObject* owner, int taskId)
{
    if (taskId > 0) begin(owner, PendingDelete, taskId, QStringLiteral("main_window.pending_delete"));
    else end(owner);
}
void TaskInteractionCoordinator::end(QObject* owner)
{
    const auto it = m_entries.find(owner);
    if (it == m_entries.end()) return;
    QObject::disconnect(it->destroyed);
    m_entries.erase(it);
    emit changed();
}
bool TaskInteractionCoordinator::refreshBlocked() const
{
    for (const auto& entry : m_entries) if (entry.kind != PendingDelete) return true;
    return false;
}
QSet<int> TaskInteractionCoordinator::pendingTaskIds() const
{
    QSet<int> ids;
    for (const auto& entry : m_entries) if (entry.kind == PendingDelete) ids.insert(entry.taskId);
    return ids;
}
