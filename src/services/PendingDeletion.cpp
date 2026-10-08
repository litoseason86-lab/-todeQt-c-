#include "PendingDeletion.h"

#include "FocusHistoryService.h"
#include "TaskManager.h"

PendingDeletion::PendingDeletion(TaskManager* tasks, FocusHistoryService* history, QObject* parent)
    : QObject(parent)
    , m_tasks(tasks)
    , m_history(history)
    , m_timer(this)
{
    m_timer.setSingleShot(true);
    // 到点按提交处理，结果由 retired / commitFailed 信号体现，这里不需要返回值。
    connect(&m_timer, &QTimer::timeout, this, [this] { commit(); });
    if (m_tasks) {
        connect(m_tasks, &TaskManager::taskDeleted, this, [this](int taskId) { handleTaskDeleted(taskId); });
    }
}

void PendingDeletion::setDelayMs(int delayMs)
{
    // 只存下来给下一次请求用：进行中的那次已经按请求时的时长在走，不重启它。
    if (delayMs <= 0 || delayMs == m_delayMs) {
        return;
    }
    m_delayMs = delayMs;
    emit delayMsChanged();
}

bool PendingDeletion::requestTask(int taskId, const QString& title)
{
    if (taskId <= 0) {
        return false;
    }
    // 单槽：上一条先真正落库；它失败了，新请求不进槽（失败那次已经发过 retired、commitFailed）。
    if (!commit()) {
        return false;
    }
    m_taskId = taskId;
    m_sessionId = -1;
    m_sessionIsRest = false;
    m_title = title;
    m_timer.start(m_delayMs);
    emit changed();
    return true;
}

bool PendingDeletion::requestSession(int sessionId, const QString& title, bool isRest)
{
    if (sessionId <= 0) {
        return false;
    }
    if (!commit()) {
        return false;
    }
    m_taskId = -1;
    m_sessionId = sessionId;
    m_sessionIsRest = isRest;
    m_title = title;
    m_timer.start(m_delayMs);
    emit changed();
    return true;
}

bool PendingDeletion::commit()
{
    if (!active()) {
        return true;
    }

    m_committing = true;
    m_timer.stop();
    // 先收起撤销条再触库：删除一旦触库就不能撤销了，不论成败都不能让用户再点到一个已经失效的「撤销」。
    emit retired();

    // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录的关联也不会提前丢失。
    // 任务和专注/休息记录共用这一个槽，避免切页后遗失尚未提交的删除。
    bool deleted = false;
    if (m_sessionId > 0) {
        if (m_history) {
            deleted = m_sessionIsRest ? m_history->deleteRestSession(m_sessionId)
                                      : m_history->deleteSession(m_sessionId);
        }
    } else if (m_tasks) {
        deleted = m_tasks->deleteTask(m_taskId);
    }
    m_committing = false;

    // 触库之后才清槽：触库期间各页继续隐藏那一行，不会先闪出来再消失。
    // 失败时清槽就是让那一行重新出现，不能把数据库失败伪装成「已删除」。
    const QString title = m_title;
    clearSlot();
    emit changed();

    if (!deleted) {
        emit commitFailed(title);
        return false;
    }
    return true;
}

void PendingDeletion::cancel()
{
    m_timer.stop();
    if (!active()) {
        return;
    }
    clearSlot();
    emit changed();
}

void PendingDeletion::handleTaskDeleted(int taskId)
{
    // 自己提交时 deleteTask 也会同步发 taskDeleted，那一发由 commit() 自己收尾，这里不能再退场一次。
    if (m_committing || m_taskId <= 0 || taskId != m_taskId) {
        return;
    }
    // 待删任务被别的路径先删掉了：没有东西可提交，也没有东西可撤销。
    m_timer.stop();
    emit retired();
    clearSlot();
    emit changed();
}

void PendingDeletion::clearSlot()
{
    m_taskId = -1;
    m_sessionId = -1;
    m_sessionIsRest = false;
    m_title.clear();
}
