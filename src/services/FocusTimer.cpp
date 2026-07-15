#include "FocusTimer.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "TaskManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QtGlobal>

FocusTimer::FocusTimer(QObject* parent)
    : QObject(parent)
{
    m_timer.setInterval(1000);
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
        const bool completed = completedPhase == BreakPhase ? stopFocus() : completeFocusSession();
        if (completed) {
            // 只有自然到点的番茄专注段才计入连续数（此分支已被上面的 PomodoroMode 守卫圈定）；
            // 手动提前结束走 stopFocus，不经过这里，不应算作完成一个番茄。计数先于 phaseCompleted，
            // 让 QML 的长休息判定读到已更新的值。
            if (completedPhase == WorkPhase) {
                ++m_completedPomodoros;
                emit completedPomodorosChanged();
            }
            emit phaseCompleted(completedPhase);
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
    m_runClock.start();

    if (!persistActiveState()) {
        resetSession();
        return false;
    }
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
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
    query.prepare(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time) VALUES (:taskId, :startTime)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), now.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to create focus session:" << query.lastError().text()
                   << "taskId=" << taskId;
        db.rollback();
        return false;
    }

    m_sessionId = query.lastInsertId().toInt();
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
    m_runClock.start();

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
    m_runClock.start();
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
                m_runClock.start();
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

    return completeFocusSession();
}

bool FocusTimer::completeFocusSession()
{
    if (m_sessionId == -1) {
        return false;
    }

    const bool wasRunning = m_isRunning;
    if (wasRunning) {
        freezeElapsedTime();
        m_timer.stop();
    }

    const int duration = m_elapsedSeconds;
    if (duration < FocusSessionRules::kMinimumValidDurationSeconds) {
        // 低于 3 分钟的会话视为无效，直接删除 startFocus 预先插入的占位记录，避免历史页出现 0 分钟噪音。
        if (!discardFocusSession()) {
            if (wasRunning) {
                m_runClock.start();
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
    if (!saveFocusSession(duration)) {
        if (wasRunning) {
            m_runClock.start();
            m_timer.start();
        }
        return false;
    }

    const int completedTaskId = m_currentTaskId;
    const bool shouldAutoCompleteTask = duration >= FocusSessionRules::kAutoCompleteTaskDurationSeconds;

    // 会话已经持久化后先清空活动态，再触发 TaskManager::tasksChanged。否则订阅方会在同一刷新中
    // 同时看到“已完成数据库记录”和“仍活动的计时器”，把最后一段时长重复计入界面统计。
    resetSession();

    if (shouldAutoCompleteTask) {
        // 一次有效专注代表任务已经被实际推进；达到 5 分钟后自动把任务标记完成。
        if (!TaskManager::instance()->setTaskCompleted(completedTaskId, true)) {
            qWarning() << "Failed to auto-complete task after focus session"
                       << "taskId=" << completedTaskId
                       << "duration=" << duration;
            emit taskAutoCompleteFailed(completedTaskId);
        }
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

int FocusTimer::autoCompleteMinutes() const
{
    return FocusSessionRules::kAutoCompleteTaskDurationSeconds / 60;
}

int FocusTimer::completedPomodoros() const
{
    return m_completedPomodoros;
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

bool FocusTimer::saveFocusSession(int durationSeconds)
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
        "UPDATE focus_sessions SET end_time = :endTime, duration = :duration WHERE id = :id"));
    query.bindValue(QStringLiteral(":endTime"), endTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":duration"), durationSeconds);
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
        return cleanupOrphanedSessions();
    }

    const int restoredSessionId = stateQuery.value(0).isNull() ? -1 : stateQuery.value(0).toInt();
    const int restoredTaskId = stateQuery.value(1).isNull() ? -1 : stateQuery.value(1).toInt();
    const QString restoredTitle = stateQuery.value(2).toString().trimmed();
    const int restoredElapsed = qMax(0, stateQuery.value(3).toInt());
    const int restoredMode = stateQuery.value(4).toInt();
    const int restoredPhase = stateQuery.value(5).toInt();
    const int restoredTarget = qMax(0, stateQuery.value(6).toInt());
    const int restoredPomodoros = qMax(0, stateQuery.value(7).toInt());

    const bool isFreeFocus = restoredMode == FreeMode && restoredPhase == NoPhase
        && restoredSessionId > 0 && restoredTaskId > 0 && !restoredTitle.isEmpty();
    const bool isPomodoroWork = restoredMode == PomodoroMode && restoredPhase == WorkPhase
        && restoredSessionId > 0 && restoredTaskId > 0 && !restoredTitle.isEmpty() && restoredTarget > 0;
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
    m_runClock.invalidate();
    m_timer.stop();

    if (!cleanupOrphanedSessions()) {
        resetSession();
        return false;
    }

    emit runningStateChanged();
    emit currentTaskChanged();
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
    if (m_isRunning && m_runClock.isValid()) {
        return m_accumulatedMilliseconds + m_runClock.elapsed();
    }
    return m_accumulatedMilliseconds;
}

void FocusTimer::syncElapsedTime()
{
    m_elapsedSeconds = static_cast<int>(currentElapsedMilliseconds() / 1000);
}

void FocusTimer::freezeElapsedTime()
{
    if (m_isRunning && m_runClock.isValid()) {
        m_accumulatedMilliseconds += m_runClock.elapsed();
        m_runClock.invalidate();
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
    m_runClock.invalidate();
}
