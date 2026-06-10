#include "FocusTimer.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "TaskManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

FocusTimer::FocusTimer(QObject* parent)
    : QObject(parent)
{
    m_timer.setInterval(1000);
    connect(&m_timer, &QTimer::timeout, this, [this]() {
        ++m_elapsedSeconds;
        emit tick();
    });
}

FocusTimer* FocusTimer::instance()
{
    static FocusTimer timer;
    return &timer;
}

bool FocusTimer::startFocus(int taskId, const QString& taskTitle)
{
    // 同一时间只允许一个活动会话，否则专注时长统计会被重叠记录污染。
    if (m_sessionId != -1 || m_isRunning) {
        qWarning() << "Failed to start focus: focus timer already has an active session"
                   << "sessionId=" << m_sessionId << "taskId=" << m_currentTaskId;
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
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
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
    if (m_sessionId == -1) {
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
        emit focusCompleted(duration);
        emit runningStateChanged();
        emit currentTaskChanged();
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
}
