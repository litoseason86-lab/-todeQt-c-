#include "PendingDeletion.h"

#include "FocusHistoryService.h"
#include "TaskManager.h"

#include <QScopeGuard>

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

void PendingDeletion::setAutomaticCommitSuspended(bool suspended)
{
    if (m_automaticCommitSuspended == suspended) {
        return;
    }
    m_automaticCommitSuspended = suspended;
    if (suspended) {
        m_timer.stop();
    } else if (active()) {
        // 恢复完整撤销窗口，不能让读屏结束后的剩余时间短到无法操作；沿用这次请求的时长。
        m_timer.start(m_activeDelayMs);
    }
}

bool PendingDeletion::requestTask(int taskId, const QString& title)
{
    if (m_committing || taskId <= 0) {
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
    ++m_generation;
    m_activeDelayMs = m_delayMs;
    if (!m_automaticCommitSuspended) {
        m_timer.start(m_activeDelayMs);
    }
    emit changed();
    return true;
}

bool PendingDeletion::requestSession(int sessionId, const QString& title, bool isRest)
{
    if (m_committing || sessionId <= 0) {
        return false;
    }
    if (!commit()) {
        return false;
    }
    m_taskId = -1;
    m_sessionId = sessionId;
    m_sessionIsRest = isRest;
    m_title = title;
    ++m_generation;
    m_activeDelayMs = m_delayMs;
    if (!m_automaticCommitSuspended) {
        m_timer.start(m_activeDelayMs);
    }
    emit changed();
    return true;
}

bool PendingDeletion::commit()
{
    // 防止 retired() 回调重入 commit() 导致重复触库或对已失效槽位误报失败。
    if (m_committing) {
        return false;
    }
    if (!active()) {
        return true;
    }

    const int taskId = m_taskId;
    const int sessionId = m_sessionId;
    const bool sessionIsRest = m_sessionIsRest;
    const QString title = m_title;

    bool deleted = false;
    QString reason;
    {
        m_committing = true;
        const auto resetCommitting = qScopeGuard([this] { m_committing = false; });
        m_timer.stop();
        // 先递增代次再发 retired()：即使槽回调拿着旧代次重入 commitGeneration/cancelGeneration 也会静默忽略。
        ++m_generation;
        // 先收起撤销条再触库：删除一旦触库就不能撤销了，不论成败都不能让用户再点到一个已经失效的「撤销」。
        emit retired();

        // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录的关联也不会提前丢失。
        // 任务和专注/休息记录共用这一个槽，避免切页后遗失尚未提交的删除。
        const QString prefix = sessionId > 0
            ? (sessionIsRest ? QStringLiteral("删除休息记录失败：") : QStringLiteral("删除专注记录失败："))
            : QStringLiteral("删除任务失败：");
        const auto collect = [&reason, &prefix](const QString& message) {
            if (reason.isEmpty() && message.startsWith(prefix)) reason = message.mid(prefix.size());
        };
        // 只收集这次底层调用；连接在清槽、刷新和提交失败回调之前撤销，不能串入后一次操作。
        QMetaObject::Connection connection;
        if (sessionId > 0) {
            if (m_history) {
                connection = connect(m_history, &FocusHistoryService::operationFailed, this, collect);
                const auto disconnectFailure = qScopeGuard([&] { disconnect(connection); });
                deleted = sessionIsRest ? m_history->deleteRestSession(sessionId)
                                        : m_history->deleteSession(sessionId);
            } else reason = QStringLiteral("记录删除服务不可用");
        } else if (m_tasks) {
            connection = connect(m_tasks, &TaskManager::operationFailed, this, collect);
            const auto disconnectFailure = qScopeGuard([&] { disconnect(connection); });
            deleted = m_tasks->deleteTask(taskId);
        } else reason = QStringLiteral("任务删除服务不可用");
    }

    // 触库之后才清槽：触库期间各页继续隐藏那一行，不会先闪出来再消失。
    // 失败时清槽就是让那一行重新出现，不能把数据库失败伪装成「已删除」。
    clearSlot();
    emit changed();

    if (!deleted) {
        emit commitFailed(title, reason.isEmpty() ? QStringLiteral("删除服务未提供失败原因，请重试") : reason);
        return false;
    }
    return true;
}

void PendingDeletion::cancel()
{
    if (m_committing) {
        return;
    }
    m_timer.stop();
    if (!active()) {
        return;
    }
    ++m_generation;
    clearSlot();
    emit changed();
}

bool PendingDeletion::commitGeneration(qint64 generation)
{
    if (generation <= 0 || generation != m_generation || !active()) {
        return true;
    }
    return commit();
}

void PendingDeletion::cancelGeneration(qint64 generation)
{
    if (generation <= 0 || generation != m_generation || !active()) {
        return;
    }
    cancel();
}

void PendingDeletion::retireForExternalReset()
{
    if (m_committing) {
        return;
    }
    m_timer.stop();
    ++m_generation;
    if (!active()) {
        return;
    }
    // 先停计时、递增代次并清槽，再通知退场与变更：确保外部回调中任何旧代次动作均已失效且不触库。
    clearSlot();
    emit retired();
    emit changed();
}

void PendingDeletion::handleTaskDeleted(int taskId)
{
    // 自己提交时 deleteTask 也会同步发 taskDeleted，那一发由 commit() 自己收尾，这里不能再退场一次。
    if (m_committing || m_taskId <= 0 || taskId != m_taskId) {
        return;
    }
    // 待删任务被别的路径先删掉了：先停计时、递增代次并清槽，再通知退场与变更，防回调重入。
    m_timer.stop();
    ++m_generation;
    clearSlot();
    emit retired();
    emit changed();
}

void PendingDeletion::clearSlot()
{
    m_taskId = -1;
    m_sessionId = -1;
    m_sessionIsRest = false;
    m_title.clear();
}
