#include "FocusTimer.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"
#include "MonotonicClock.h"
#include "TaskManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QtGlobal>

namespace {
bool isCompletedPomodoroSession(bool naturalCompletion,
                                FocusTimer::TimerMode mode,
                                FocusTimer::TimerPhase phase,
                                int durationSeconds)
{
    // 写入事实与结束后的自动完成判定共用这一处，避免一边记成有效番茄、另一边却不推进任务。
    return naturalCompletion
        && mode == FocusTimer::PomodoroMode
        && phase == FocusTimer::WorkPhase
        && durationSeconds >= FocusSessionRules::kMinimumValidDurationSeconds;
}
}

FocusTimer::FocusTimer(QObject* parent)
    : QObject(parent)
    , m_clock(SystemMonotonicClock::instance())
{
    m_timer.setInterval(1000);
    connect(AppSettings::instance(), &AppSettings::dayStartHourChanged,
            this, &FocusTimer::sessionLogicalDateChanged);
    // 删除信号携带已提交的任务 ID。不能在计时器内查询任务是否存在：查询与删除之间
    // 会产生竞态，且跨线程/换库时可能读到另一份数据库；只按这条事实信号解绑内存状态。
    connect(TaskManager::instance(), &TaskManager::taskDeleted,
            this, &FocusTimer::handleTaskDeleted);
    connect(&m_timer, &QTimer::timeout, this, [this]() {
        syncElapsedTime();
        // 每五秒保存一次活动进度；崩溃最多损失一个检查点区间，正常退出会再做一次同步。
        if (m_elapsedSeconds - m_lastCheckpointSeconds >= 5) {
            if (persistActiveState()) {
                m_lastCheckpointSeconds = m_elapsedSeconds;
            }
        }
        emit tick();

        if (m_mode != PomodoroMode || m_targetSeconds <= 0 || m_elapsedSeconds < m_targetSeconds) {
            return;
        }

        // 到点后先保存当前 phase，因为 resetSession 会把阶段清空；信号必须告诉 QML 刚完成的是专注还是休息。
        const TimerPhase completedPhase = m_phase;
        const bool completed = completedPhase == BreakPhase
            ? stopFocus()
            : completeFocusSession(true);
        if (completed) {
            m_completionFailureNotified = false;
            // 只有自然到点的番茄专注段才计入连续数（此分支已被上面的 PomodoroMode 守卫圈定）；
            // 手动提前结束走 stopFocus，不经过这里，不应算作完成一个番茄。计数先于 phaseCompleted，
            // 让 QML 的长休息判定读到已更新的值。
            if (completedPhase == WorkPhase) {
                ++m_completedPomodoros;
                emit completedPomodorosChanged();
            }
            emit phaseCompleted(completedPhase);
        } else if (!m_completionFailureNotified) {
            // 保存失败时计时器继续走并在下一次 tick 重试；这里只在进入失败状态的
            // 第一刻通知界面，避免每秒一条提示刷屏。
            m_completionFailureNotified = true;
            emit operationFailed(QStringLiteral("专注记录保存失败，正在自动重试"));
        }
    });
}

FocusTimer* FocusTimer::instance()
{
    static FocusTimer timer;
    return &timer;
}

bool FocusTimer::startFocus(int taskId, const QString& taskTitle)
{
    return startFocusSession(taskId, taskTitle, FreeMode, NoPhase, 0);
}

bool FocusTimer::startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds)
{
    if (workSeconds <= 0) {
        qWarning() << "Failed to start pomodoro work: invalid target seconds" << workSeconds;
        return false;
    }

    return startFocusSession(taskId, taskTitle, PomodoroMode, WorkPhase, workSeconds);
}

bool FocusTimer::startBreak(int breakSeconds)
{
    return startBreakSession(breakSeconds, -1, QString());
}

bool FocusTimer::startBreakForTask(int breakSeconds, int taskId, const QString& taskTitle)
{
    return startBreakSession(breakSeconds, taskId, taskTitle);
}

bool FocusTimer::startBreakSession(int breakSeconds, int taskId, const QString& taskTitle)
{
    if (hasActiveTimer()) {
        qWarning() << "Failed to start break: focus timer already has an active session"
                   << "sessionId=" << m_sessionId << "phase=" << m_phase;
        return false;
    }

    if (breakSeconds <= 0) {
        qWarning() << "Failed to start break: invalid target seconds" << breakSeconds;
        return false;
    }

    // 休息段只占用计时器状态，不创建 focus_sessions；否则历史、统计、导出都会把休息误当专注。
    // 任务字段仅作为下一轮番茄的恢复上下文，不参与休息统计。
    const QString normalizedTitle = taskTitle.trimmed();
    const bool hasTaskContext = taskId > 0 && !normalizedTitle.isEmpty();
    m_currentTaskId = hasTaskContext ? taskId : -1;
    m_currentTaskTitle = hasTaskContext ? normalizedTitle : QString();
    m_startTime = QDateTime::currentDateTime();
    m_elapsedSeconds = 0;
    m_accumulatedMilliseconds = 0;
    m_lastCheckpointSeconds = 0;
    m_isRunning = true;
    m_sessionId = -1;
    m_mode = PomodoroMode;
    m_phase = BreakPhase;
    m_targetSeconds = breakSeconds;
    m_runSegmentStartNsecs = m_clock->nowNsecs();

    if (!persistActiveState()) {
        resetSession();
        return false;
    }
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
    emit sessionLogicalDateChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
}

bool FocusTimer::startFocusSession(int taskId, const QString& taskTitle, TimerMode mode, TimerPhase phase, int targetSeconds)
{
    // 同一时间只允许一个活动会话，否则专注时长统计会被重叠记录污染。
    if (hasActiveTimer()) {
        qWarning() << "Failed to start focus: focus timer already has an active session"
                   << "sessionId=" << m_sessionId << "taskId=" << m_currentTaskId
                   << "phase=" << m_phase;
        return false;
    }

    if (taskId <= 0) {
        qWarning() << "Failed to start focus: invalid task id" << taskId;
        return false;
    }

    const QString normalizedTitle = taskTitle.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to start focus: task title is empty after trimming";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to start focus: database is not open";
        return false;
    }

    const QDateTime now = QDateTime::currentDateTime();
    if (!db.transaction()) {
        qWarning() << "Failed to start focus: could not begin transaction" << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    // 会话一开始就固化科目，不等结束时再查。这样任务在计时中被改科目或删除，
    // 历史仍归属于开始专注时的科目。快照不设外键，科目本身删除后也能保留名称与颜色。
    query.prepare(QStringLiteral(R"SQL(
        INSERT INTO focus_sessions (
            task_id, start_time, mode,
            category_id_snapshot, category_name_snapshot, category_color_snapshot
        )
        SELECT :taskId, :startTime, :mode,
               COALESCE(t.category_id, legacy_category.id),
               COALESCE(current_category.name, legacy_category.name, t.category, ''),
               COALESCE(current_category.color, legacy_category.color, '')
        FROM tasks t
        LEFT JOIN categories current_category ON t.category_id = current_category.id
        LEFT JOIN categories legacy_category
               ON t.category_id IS NULL AND legacy_category.name = t.category
        WHERE t.id = :taskId
    )SQL"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), now.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":mode"), static_cast<int>(mode));

    if (!query.exec() || query.numRowsAffected() != 1) {
        qWarning() << "Failed to create focus session:" << query.lastError().text()
                   << "taskId=" << taskId;
        db.rollback();
        return false;
    }

    m_sessionId = query.lastInsertId().toInt();
    if (m_sessionId <= 0) {
        qWarning() << "Failed to create focus session: invalid inserted id"
                   << "taskId=" << taskId;
        db.rollback();
        return false;
    }
    m_currentTaskId = taskId;
    m_currentTaskTitle = normalizedTitle;
    m_startTime = now;
    m_elapsedSeconds = 0;
    m_accumulatedMilliseconds = 0;
    m_lastCheckpointSeconds = 0;
    m_isRunning = true;
    m_mode = mode;
    m_phase = phase;
    m_targetSeconds = targetSeconds;
    m_runSegmentStartNsecs = m_clock->nowNsecs();

    if (!writeActiveState(db) || !db.commit()) {
        qWarning() << "Failed to persist active focus state:" << db.lastError().text()
                   << "taskId=" << taskId;
        db.rollback();
        resetSession();
        return false;
    }
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
    emit sessionLogicalDateChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
}

void FocusTimer::pauseFocus()
{
    if (!m_isRunning) {
        return;
    }

    freezeElapsedTime();
    m_timer.stop();
    m_isRunning = false;
    if (!persistActiveState()) {
        qWarning() << "Failed to checkpoint focus while pausing"
                   << "sessionId=" << m_sessionId;
    } else {
        m_lastCheckpointSeconds = m_elapsedSeconds;
    }
    emit tick();
    emit runningStateChanged();
}

bool FocusTimer::resumeFocus()
{
    const bool canResumeBreak = m_mode == PomodoroMode && m_phase == BreakPhase;
    if (m_sessionId == -1 && !canResumeBreak) {
        qWarning() << "Failed to resume focus: no active focus session";
        return false;
    }

    if (m_isRunning) {
        return true;
    }

    m_isRunning = true;
    m_runSegmentStartNsecs = m_clock->nowNsecs();
    m_timer.start();
    emit runningStateChanged();
    return true;
}

bool FocusTimer::stopFocus()
{
    if (m_phase == BreakPhase) {
        // 休息段没有数据库行，到点或手动停止都只复位；不能走专注段的保存/丢弃逻辑。
        const bool wasRunning = m_isRunning;
        if (wasRunning) {
            freezeElapsedTime();
            m_timer.stop();
        }
        QSqlDatabase db = DatabaseManager::instance()->database();
        if (!db.isOpen() || !clearActiveState(db)) {
            if (wasRunning) {
                m_isRunning = true;
                m_runSegmentStartNsecs = m_clock->nowNsecs();
                m_timer.start();
            }
            return false;
        }
        resetSession();
        emit runningStateChanged();
        emit currentTaskChanged();
        emit modeChanged();
        emit phaseChanged();
        emit tick();
        return true;
    }

    return completeFocusSession(false);
}

bool FocusTimer::requiresFreeFocusStopConfirmation(int thresholdHours) const
{
    const int normalizedHours = (thresholdHours >= 1 && thresholdHours <= 24)
        ? thresholdHours : 8;
    return m_sessionId != -1
        && m_mode == FreeMode
        && m_phase == NoPhase
        && elapsedSeconds() > normalizedHours * 60 * 60;
}

bool FocusTimer::discardFreeFocus()
{
    if (m_sessionId == -1 || m_mode != FreeMode || m_phase != NoPhase) {
        qWarning() << "Failed to discard free focus: no active free-focus session";
        return false;
    }

    const bool wasRunning = m_isRunning;
    if (wasRunning) {
        freezeElapsedTime();
        m_timer.stop();
    }

    // discardFocusSession 在同一事务中删除会话行和活动快照；失败时恢复计时，不能造成界面已结束但脏行仍在。
    if (!discardFocusSession()) {
        if (wasRunning) {
            m_isRunning = true;
            m_runSegmentStartNsecs = m_clock->nowNsecs();
            m_timer.start();
        }
        return false;
    }

    resetSession();
    emit runningStateChanged();
    emit currentTaskChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
}

bool FocusTimer::completeFocusSession(bool naturalCompletion)
{
    if (m_sessionId == -1) {
        return false;
    }

    const bool wasRunning = m_isRunning;
    if (wasRunning) {
        freezeElapsedTime();
        m_timer.stop();
    }

    int duration = m_elapsedSeconds;
    if (naturalCompletion && m_mode == PomodoroMode && m_phase == WorkPhase
        && m_targetSeconds > 0) {
        // 单调时钟会把合盖期间一并计入；自然到点的番茄应记录配置目标，而不是
        // 唤醒后才处理 timeout 所造成的超额时间。手动停止和自由计时不走此分支，
        // 仍完整保留用户实际专注时长。
        duration = qMin(duration, m_targetSeconds);
    }
    if (duration < FocusSessionRules::kMinimumValidDurationSeconds) {
        // 低于 3 分钟的会话视为无效，直接删除 startFocus 预先插入的占位记录，避免历史页出现 0 分钟噪音。
        if (!discardFocusSession()) {
            if (wasRunning) {
                m_runSegmentStartNsecs = m_clock->nowNsecs();
                m_timer.start();
            }
            return false;
        }

        resetSession();
        // 静默丢弃会让用户误以为已记录；界面靠这个信号弹出未计入提示。
        emit sessionDiscarded(duration);
        emit focusCompleted(duration);
        emit runningStateChanged();
        emit currentTaskChanged();
        emit modeChanged();
        emit phaseChanged();
        emit tick();
        return true;
    }

    // 保存失败时恢复计时器，不假装会话已经正常结束。
    if (!saveFocusSession(duration, naturalCompletion)) {
        if (wasRunning) {
            m_runSegmentStartNsecs = m_clock->nowNsecs();
            m_timer.start();
        }
        return false;
    }

    const int completedTaskId = m_currentTaskId;
    const bool completedPomodoro = isCompletedPomodoroSession(
        naturalCompletion, m_mode, m_phase, duration);
    // 任务可能在会话进行中被删除（外键置空后恢复的会话 task_id 为 -1）；
    // 没有可完成的任务时跳过自动完成，而不是制造一次必然失败的告警。
    const bool shouldCheckTaskTarget = completedTaskId > 0 && completedPomodoro;

    // 会话已经持久化后先清空活动态，再触发 TaskManager::tasksChanged。否则订阅方会在同一刷新中
    // 同时看到“已完成数据库记录”和“仍活动的计时器”，把最后一段时长重复计入界面统计。
    resetSession();

    bool taskChangeAlreadyEmitted = false;
    if (shouldCheckTaskTarget) {
        // 只有本次自然到点的工作番茄入账后，实际数恰好等于正数计划值才完成任务。
        // 已超额时保持原状态，防止用户重新打开任务后又被下一颗番茄强行完成。
        const TaskManager::TargetCompletionResult result =
            TaskManager::instance()->completeTaskIfPomodoroTargetReached(completedTaskId);
        taskChangeAlreadyEmitted = result == TaskManager::TargetCompletionResult::Completed;
        if (result == TaskManager::TargetCompletionResult::Failed) {
            emit taskAutoCompleteFailed(completedTaskId);
        }
    }
    if (completedTaskId > 0 && !taskChangeAlreadyEmitted) {
        // 未到计划数、自由计时或手动停止仍可能改变专注秒数；只监听 tasksChanged 的页面也必须刷新。
        emit TaskManager::instance()->tasksChanged();
    }

    emit focusCompleted(duration);
    emit runningStateChanged();
    emit currentTaskChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
}

int FocusTimer::elapsedSeconds() const
{
    return static_cast<int>(currentElapsedMilliseconds() / 1000);
}

bool FocusTimer::isRunning() const
{
    return m_isRunning;
}

bool FocusTimer::hasActiveSession() const
{
    return m_sessionId != -1;
}

QString FocusTimer::currentTaskTitle() const
{
    return m_currentTaskTitle;
}

int FocusTimer::currentTaskId() const
{
    return m_currentTaskId;
}

int FocusTimer::mode() const
{
    return m_mode;
}

int FocusTimer::phase() const
{
    return m_phase;
}

int FocusTimer::targetSeconds() const
{
    return m_targetSeconds;
}

int FocusTimer::remainingSeconds() const
{
    if (m_mode != PomodoroMode || m_targetSeconds <= 0) {
        // 自由模式是正计时，没有目标秒数；QML 读取剩余时间时固定返回 0，避免出现伪倒计时。
        return 0;
    }

    return qMax(0, m_targetSeconds - elapsedSeconds());
}

int FocusTimer::minimumValidMinutes() const
{
    // 界面规则文案的数据源；换算自秒级常量，规则改动时文案自动跟随。
    return FocusSessionRules::kMinimumValidDurationSeconds / 60;
}

int FocusTimer::completedPomodoros() const
{
    return m_completedPomodoros;
}

QString FocusTimer::sessionLogicalDate() const
{
    if (m_sessionId <= 0 || !m_startTime.isValid()) {
        return QString();
    }
    return LogicalDay::dateOf(m_startTime, AppSettings::instance()->dayStartHour())
        .toString(Qt::ISODate);
}

void FocusTimer::resetPomodoroCount()
{
    if (m_completedPomodoros == 0) {
        return;
    }
    m_completedPomodoros = 0;
    if (hasActiveTimer() && !persistActiveState()) {
        qWarning() << "Failed to persist reset pomodoro count";
    }
    emit completedPomodorosChanged();
}

bool FocusTimer::hasActiveTimer() const
{
    return m_sessionId != -1 || m_isRunning || m_phase != NoPhase;
}

bool FocusTimer::saveFocusSession(int durationSeconds, bool naturalCompletion)
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to save focus session: database is not open"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId
                   << "duration=" << durationSeconds
                   << "startTime=" << m_startTime.toString(Qt::ISODate);
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to save focus session: could not begin transaction"
                   << db.lastError().text();
        return false;
    }

    // 保存单调时钟累计秒数，而不是墙钟时间差，这样暂停、系统改时钟和 GUI 卡顿都不会污染时长。
    const QDateTime endTime = QDateTime::currentDateTime();
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE focus_sessions SET end_time = :endTime, duration = :duration, "
        "pomodoro_completed = :pomodoroCompleted WHERE id = :id"));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":duration"), durationSeconds);
    const bool completedPomodoro = isCompletedPomodoroSession(
        naturalCompletion, m_mode, m_phase, durationSeconds);
    query.bindValue(QStringLiteral(":pomodoroCompleted"), completedPomodoro ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), m_sessionId);

    if (!query.exec()) {
        qWarning() << "Failed to save focus session:" << query.lastError().text()
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId
                   << "duration=" << durationSeconds
                   << "startTime=" << m_startTime.toString(Qt::ISODate)
                   << "endTime=" << endTime.toString(Qt::ISODate);
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to save focus session: session row not found"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId
                   << "duration=" << durationSeconds;
        db.rollback();
        return false;
    }

    if (!clearActiveState(db) || !db.commit()) {
        qWarning() << "Failed to finish focus session transaction:" << db.lastError().text()
                   << "sessionId=" << m_sessionId;
        db.rollback();
        return false;
    }

    return true;
}

bool FocusTimer::discardFocusSession()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to discard invalid focus session: database is not open"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId;
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to discard invalid focus session: could not begin transaction"
                   << db.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM focus_sessions WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), m_sessionId);

    if (!query.exec()) {
        qWarning() << "Failed to discard invalid focus session:" << query.lastError().text()
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId;
        db.rollback();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to discard invalid focus session: session row not found"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId;
        db.rollback();
        return false;
    }

    if (!clearActiveState(db) || !db.commit()) {
        qWarning() << "Failed to discard focus session transaction:" << db.lastError().text()
                   << "sessionId=" << m_sessionId;
        db.rollback();
        return false;
    }

    return true;
}

bool FocusTimer::persistActiveState()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to persist active focus state: database is not open";
        return false;
    }

    return writeActiveState(db);
}

bool FocusTimer::writeActiveState(QSqlDatabase& db)
{
    QSqlQuery query(db);
    query.prepare(QStringLiteral(R"SQL(
        INSERT INTO active_focus_state (
            singleton_id, session_id, task_id, task_title, elapsed_seconds,
            mode, phase, target_seconds, completed_pomodoros, updated_at
        ) VALUES (
            1, :sessionId, :taskId, :taskTitle, :elapsedSeconds,
            :mode, :phase, :targetSeconds, :completedPomodoros, :updatedAt
        )
        ON CONFLICT(singleton_id) DO UPDATE SET
            session_id = excluded.session_id,
            task_id = excluded.task_id,
            task_title = excluded.task_title,
            elapsed_seconds = excluded.elapsed_seconds,
            mode = excluded.mode,
            phase = excluded.phase,
            target_seconds = excluded.target_seconds,
            completed_pomodoros = excluded.completed_pomodoros,
            updated_at = excluded.updated_at
    )SQL"));
    query.bindValue(QStringLiteral(":sessionId"), m_sessionId > 0 ? QVariant(m_sessionId) : QVariant());
    query.bindValue(QStringLiteral(":taskId"), m_currentTaskId > 0 ? QVariant(m_currentTaskId) : QVariant());
    query.bindValue(QStringLiteral(":taskTitle"),
                    m_currentTaskTitle.isNull() ? QStringLiteral("") : m_currentTaskTitle);
    query.bindValue(QStringLiteral(":elapsedSeconds"), elapsedSeconds());
    query.bindValue(QStringLiteral(":mode"), static_cast<int>(m_mode));
    query.bindValue(QStringLiteral(":phase"), static_cast<int>(m_phase));
    query.bindValue(QStringLiteral(":targetSeconds"), m_targetSeconds);
    query.bindValue(QStringLiteral(":completedPomodoros"), m_completedPomodoros);
    query.bindValue(QStringLiteral(":updatedAt"), QDateTime::currentDateTime().toString(Qt::ISODateWithMs));

    if (!query.exec()) {
        qWarning() << "Failed to write active focus state:" << query.lastError().text()
                   << "sessionId=" << m_sessionId << "phase=" << m_phase;
        return false;
    }
    return true;
}

bool FocusTimer::clearActiveState(QSqlDatabase& db)
{
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("DELETE FROM active_focus_state WHERE singleton_id = 1"))) {
        qWarning() << "Failed to clear active focus state:" << query.lastError().text();
        return false;
    }
    return true;
}

bool FocusTimer::cleanupOrphanedSessions()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return false;
    }

    QSqlQuery query(db);
    // 只有被活动状态引用的 NULL 会话才可恢复；其余都是旧版本或异常中断遗留的不可见垃圾。
    if (!query.exec(QStringLiteral(R"SQL(
        DELETE FROM focus_sessions
        WHERE end_time IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM active_focus_state
              WHERE active_focus_state.session_id = focus_sessions.id
          )
    )SQL"))) {
        qWarning() << "Failed to clean orphaned focus sessions:" << query.lastError().text();
        return false;
    }
    return true;
}

void FocusTimer::handleTaskDeleted(int taskId)
{
    if (taskId <= 0 || m_currentTaskId != taskId) {
        return;
    }

    // 删除事务已完成，外键已把数据库中的 task_id 设为 NULL；这里同步内存并再次
    // 写入活动快照，保证恢复路径也不会带回已删除的 ID。标题是会话快照，必须保留。
    m_currentTaskId = -1;
    if (hasActiveTimer() && !persistActiveState()) {
        qWarning() << "Failed to detach deleted task from active focus state"
                   << "taskId=" << taskId << "sessionId=" << m_sessionId;
    }
    emit currentTaskChanged();
}

bool FocusTimer::restoreInterruptedSession()
{
    if (hasActiveTimer()) {
        qWarning() << "Failed to restore focus state: timer already active";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return false;
    }

    QSqlQuery stateQuery(db);
    if (!stateQuery.exec(QStringLiteral(R"SQL(
        SELECT session_id, task_id, task_title, elapsed_seconds, mode, phase, target_seconds,
               completed_pomodoros
        FROM active_focus_state WHERE singleton_id = 1
    )SQL"))) {
        qWarning() << "Failed to read active focus state:" << stateQuery.lastError().text();
        return false;
    }

    if (!stateQuery.next()) {
        // 换库或恢复不含活动状态的备份时，内存可能还保留上一库的番茄循环计数。
        // 数据库没有活动状态就没有可继承的计数，必须清零并通知 QML 更新长休息判定。
        const bool pomodoroCountChanged = m_completedPomodoros != 0;
        m_completedPomodoros = 0;
        const bool cleanupSucceeded = cleanupOrphanedSessions();
        if (pomodoroCountChanged) {
            emit completedPomodorosChanged();
        }
        return cleanupSucceeded;
    }

    const int restoredSessionId = stateQuery.value(0).isNull() ? -1 : stateQuery.value(0).toInt();
    const int restoredTaskId = stateQuery.value(1).isNull() ? -1 : stateQuery.value(1).toInt();
    const QString restoredTitle = stateQuery.value(2).toString().trimmed();
    const int restoredElapsed = qMax(0, stateQuery.value(3).toInt());
    const int restoredMode = stateQuery.value(4).toInt();
    const int restoredPhase = stateQuery.value(5).toInt();
    const int restoredTarget = qMax(0, stateQuery.value(6).toInt());
    const int restoredPomodoros = qMax(0, stateQuery.value(7).toInt());

    // 任务可能在会话进行中被删除：外键把 task_id 置空，但标题快照仍在。
    // 已经计入的进行中会话必须照常恢复（与休息段同一宽容口径），
    // 只是结束后因 task_id 无效不再自动完成任务。
    const bool isFreeFocus = restoredMode == FreeMode && restoredPhase == NoPhase
        && restoredSessionId > 0 && !restoredTitle.isEmpty();
    const bool isPomodoroWork = restoredMode == PomodoroMode && restoredPhase == WorkPhase
        && restoredSessionId > 0 && !restoredTitle.isEmpty() && restoredTarget > 0;
    const bool isPomodoroBreak = restoredMode == PomodoroMode && restoredPhase == BreakPhase
        && restoredSessionId == -1 && restoredTarget > 0
        // 休息期间任务可能被删除，外键会把 task_id 置空但保留标题；休息计时仍应恢复，
        // 只是下一轮因缺少有效任务 id 而保持不可启动。
        && (restoredTaskId == -1 || !restoredTitle.isEmpty());

    QDateTime restoredStartTime;
    bool sessionRowValid = isPomodoroBreak;
    if (restoredSessionId > 0) {
        QSqlQuery sessionQuery(db);
        sessionQuery.prepare(QStringLiteral(
            "SELECT start_time FROM focus_sessions WHERE id = :id AND end_time IS NULL"));
        sessionQuery.bindValue(QStringLiteral(":id"), restoredSessionId);
        if (!sessionQuery.exec()) {
            qWarning() << "Failed to validate interrupted focus session:"
                       << sessionQuery.lastError().text();
            return false;
        }
        if (sessionQuery.next()) {
            restoredStartTime = QDateTime::fromString(sessionQuery.value(0).toString(), Qt::ISODate);
            sessionRowValid = restoredStartTime.isValid();
        }
    }

    if (!(isFreeFocus || isPomodoroWork || isPomodoroBreak) || !sessionRowValid) {
        qWarning() << "Discarding invalid active focus state"
                   << "sessionId=" << restoredSessionId << "mode=" << restoredMode
                   << "phase=" << restoredPhase;
        if (!clearActiveState(db)) {
            return false;
        }
        return cleanupOrphanedSessions();
    }

    m_sessionId = restoredSessionId;
    m_currentTaskId = restoredTaskId;
    m_currentTaskTitle = restoredTitle;
    m_startTime = isPomodoroBreak ? QDateTime::currentDateTime() : restoredStartTime;
    m_elapsedSeconds = restoredElapsed;
    m_accumulatedMilliseconds = static_cast<qint64>(restoredElapsed) * 1000;
    m_lastCheckpointSeconds = restoredElapsed;
    m_isRunning = false;
    m_mode = static_cast<TimerMode>(restoredMode);
    m_phase = static_cast<TimerPhase>(restoredPhase);
    m_targetSeconds = restoredTarget;
    m_completedPomodoros = restoredPomodoros;
    m_runSegmentStartNsecs = -1;
    m_timer.stop();

    if (!cleanupOrphanedSessions()) {
        resetSession();
        return false;
    }

    emit runningStateChanged();
    emit currentTaskChanged();
    emit sessionLogicalDateChanged();
    emit modeChanged();
    emit phaseChanged();
    emit completedPomodorosChanged();
    emit tick();
    return true;
}

void FocusTimer::prepareForShutdown()
{
    if (!hasActiveTimer()) {
        return;
    }

    if (m_isRunning) {
        freezeElapsedTime();
        m_timer.stop();
        m_isRunning = false;
    }

    if (!persistActiveState()) {
        qWarning() << "Failed to checkpoint active focus state before shutdown"
                   << "sessionId=" << m_sessionId << "phase=" << m_phase;
    }
}

qint64 FocusTimer::currentElapsedMilliseconds() const
{
    // 运行段起点为 -1 表示当前没有活动段（暂停/恢复/复位后），此时只返回已累计时长。
    // 运行段时长来自单调时钟差值：mach_continuous_time 含系统休眠，合盖唤醒后自动补上休眠时长。
    if (m_isRunning && m_runSegmentStartNsecs >= 0) {
        const qint64 segmentMs = (m_clock->nowNsecs() - m_runSegmentStartNsecs) / 1000000;
        return m_accumulatedMilliseconds + qMax<qint64>(0, segmentMs);
    }
    return m_accumulatedMilliseconds;
}

void FocusTimer::syncElapsedTime()
{
    m_elapsedSeconds = static_cast<int>(currentElapsedMilliseconds() / 1000);
}

void FocusTimer::freezeElapsedTime()
{
    // 把当前运行段折进累计时长，并标记运行段结束（-1），避免暂停/结束瞬间被重复计入。
    if (m_isRunning && m_runSegmentStartNsecs >= 0) {
        const qint64 segmentMs = (m_clock->nowNsecs() - m_runSegmentStartNsecs) / 1000000;
        m_accumulatedMilliseconds += qMax<qint64>(0, segmentMs);
        m_runSegmentStartNsecs = -1;
    }
    syncElapsedTime();
}

void FocusTimer::resetSession()
{
    m_timer.stop();
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_startTime = QDateTime();
    m_elapsedSeconds = 0;
    m_accumulatedMilliseconds = 0;
    m_lastCheckpointSeconds = 0;
    m_isRunning = false;
    m_sessionId = -1;
    m_mode = FreeMode;
    m_phase = NoPhase;
    m_targetSeconds = 0;
    m_completionFailureNotified = false;
    m_runSegmentStartNsecs = -1;
    emit sessionLogicalDateChanged();
}
