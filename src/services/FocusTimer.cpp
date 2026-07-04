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
        ++m_elapsedSeconds;
        emit tick();

        if (m_mode != PomodoroMode || m_targetSeconds <= 0 || m_elapsedSeconds < m_targetSeconds) {
            return;
        }

        // 到点后先保存当前 phase，因为 resetSession 会把阶段清空；信号必须告诉 QML 刚完成的是专注还是休息。
        const TimerPhase completedPhase = m_phase;
        const bool completed = completedPhase == BreakPhase ? stopFocus() : completeFocusSession();
        if (completed) {
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
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_startTime = QDateTime::currentDateTime();
    m_elapsedSeconds = 0;
    m_isRunning = true;
    m_sessionId = -1;
    m_mode = PomodoroMode;
    m_phase = BreakPhase;
    m_targetSeconds = breakSeconds;
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
    QSqlQuery query(db);
    query.prepare(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time) VALUES (:taskId, :startTime)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), now.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to create focus session:" << query.lastError().text()
                   << "taskId=" << taskId;
        return false;
    }

    m_sessionId = query.lastInsertId().toInt();
    m_currentTaskId = taskId;
    m_currentTaskTitle = normalizedTitle;
    m_startTime = now;
    m_elapsedSeconds = 0;
    m_isRunning = true;
    m_mode = mode;
    m_phase = phase;
    m_targetSeconds = targetSeconds;
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

    m_timer.stop();
    m_isRunning = false;
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

    m_timer.start();
    m_isRunning = true;
    emit runningStateChanged();
    return true;
}

bool FocusTimer::stopFocus()
{
    if (m_phase == BreakPhase) {
        // 休息段没有数据库行，到点或手动停止都只复位；不能走专注段的保存/丢弃逻辑。
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
        m_timer.stop();
    }

    const int duration = m_elapsedSeconds;
    if (duration < FocusSessionRules::kMinimumValidDurationSeconds) {
        // 低于 3 分钟的会话视为无效，直接删除 startFocus 预先插入的占位记录，避免历史页出现 0 分钟噪音。
        if (!discardFocusSession()) {
            if (wasRunning) {
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
            m_timer.start();
        }
        return false;
    }

    if (duration >= FocusSessionRules::kAutoCompleteTaskDurationSeconds) {
        // 一次有效专注代表任务已经被实际推进；达到 5 分钟后自动把任务标记完成。
        if (!TaskManager::instance()->setTaskCompleted(m_currentTaskId, true)) {
            qWarning() << "Failed to auto-complete task after focus session"
                       << "taskId=" << m_currentTaskId
                       << "duration=" << duration;
        }
    }

    resetSession();
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
    return m_elapsedSeconds;
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

    return qMax(0, m_targetSeconds - m_elapsedSeconds);
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

    // 保存实际计时秒数，而不是墙钟时间差，这样暂停/继续才会被正确计算。
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
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to save focus session: session row not found"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId
                   << "duration=" << durationSeconds;
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

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM focus_sessions WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), m_sessionId);

    if (!query.exec()) {
        qWarning() << "Failed to discard invalid focus session:" << query.lastError().text()
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId;
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to discard invalid focus session: session row not found"
                   << "sessionId=" << m_sessionId
                   << "taskId=" << m_currentTaskId;
        return false;
    }

    return true;
}

void FocusTimer::resetSession()
{
    m_timer.stop();
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_startTime = QDateTime();
    m_elapsedSeconds = 0;
    m_isRunning = false;
    m_sessionId = -1;
    m_mode = FreeMode;
    m_phase = NoPhase;
    m_targetSeconds = 0;
}
