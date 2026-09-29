#include "FocusTimer.h"

#include "AppSettings.h"
#include "ApplicationActivity.h"
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
// 恢复时单调时钟与墙钟「走过的时长」允许的误差。自动校时的微调通常不到一秒；
// 重启至少丢掉开机前的全部运行时长加上关机与开机时间，远大于这个值。
constexpr qint64 kClockAgreementToleranceMs = 10 * 1000;

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

        // 移动端：到点发生在后台（进程被挂起，或被结束后重新启动恢复）时只做离线结算。
        // 这一 tick 要等回到前台才跑到这里；此时若按正常到点处理，就会自动开始休息、
        // 再弹一次提醒，把用户不在场时发生的事当成眼前刚发生。判定必须在结算之前做，
        // 结算会清空运行段，之后就算不出到点时刻了。
        finishExpiredPhase(m_recoveryPolicy == RecoveryPolicy::CatchUpOffline
                           && expiredInBackground());
    });
}

void FocusTimer::finishExpiredPhase(bool settledOffline)
{
    // 到点后先保存当前 phase，因为 resetSession 会把阶段清空；信号必须告诉 QML 刚完成的是专注还是休息。
    const TimerPhase completedPhase = m_phase;
    bool countedAsPomodoro = false;
    const bool completed = completedPhase == BreakPhase
        ? stopFocus()
        : completeFocusSession(true, &countedAsPomodoro);
    if (completed) {
        m_completionFailureNotified = false;
        // 只有自然到点的番茄专注段才计入连续数（调用方已用 PomodoroMode 守卫圈定）；
        // 手动提前结束走 stopFocus，不经过这里，不应算作完成一个番茄。计数先于完成信号，
        // 让 QML 的长休息判定读到已更新的值。离线结算同样计数：这个番茄确实完成了。
        // 以结算结果为准，而不是只看阶段：时长不足被整条丢弃的会话不推进长休息节奏。
        if (completedPhase == WorkPhase && countedAsPomodoro) {
            ++m_completedPomodoros;
            emit completedPomodorosChanged();
        }
        if (settledOffline) {
            emit phaseSettledOffline(completedPhase);
        } else {
            emit phaseCompleted(completedPhase);
        }
    } else if (!m_completionFailureNotified) {
        // 保存失败时计时器继续走并在下一次 tick 重试；这里只在进入失败状态的
        // 第一刻通知界面，避免每秒一条提示刷屏。
        m_completionFailureNotified = true;
        emit operationFailed(completedPhase == BreakPhase
            ? QStringLiteral("休息记录保存失败，正在自动重试")
            : QStringLiteral("专注记录保存失败，正在自动重试"));
    }
}

bool FocusTimer::expiredInBackground() const
{
    // 没有前后台来源（桌面、测试默认）时一律视为在前台，走原有的正常到点。
    if (!m_activity) {
        return false;
    }
    if (!m_activity->isForeground()) {
        return true;
    }
    if (!m_isRunning || m_runSegmentStartNsecs < 0) {
        return false;
    }
    // 到点那一刻的单调时钟读数 = 本段起点 + 本段还要走的时长（目标 − 本段之前的累计）。
    // 它早于最近一次回到前台，说明到期时应用不在前台：挂起期间没有 tick，是回来后才补上的。
    const qint64 remainingAtSegmentStartMs =
        static_cast<qint64>(m_targetSeconds) * 1000 - m_accumulatedMilliseconds;
    const qint64 expiryNsecs = m_runSegmentStartNsecs + remainingAtSegmentStartMs * 1000000;
    const qint64 lastForeground = m_activity->lastForegroundNsecs();
    return lastForeground >= 0 && expiryNsecs < lastForeground;
}

void FocusTimer::setRecoveryPolicy(RecoveryPolicy policy)
{
    m_recoveryPolicy = policy;
}

FocusTimer::RecoveryPolicy FocusTimer::recoveryPolicy() const
{
    return m_recoveryPolicy;
}

void FocusTimer::setApplicationActivity(const ApplicationActivity* activity)
{
    m_activity = activity;
}

void FocusTimer::setFreeTimingAllowed(bool allowed)
{
    if (m_freeTimingAllowed == allowed) {
        return;
    }
    m_freeTimingAllowed = allowed;
    emit freeTimingAllowedChanged();
}

bool FocusTimer::freeTimingAllowed() const
{
    return m_freeTimingAllowed;
}

quint64 FocusTimer::runSegmentSerial() const
{
    return m_runSegmentSerial;
}

FocusTimer* FocusTimer::instance()
{
    static FocusTimer timer;
    return &timer;
}

bool FocusTimer::startFocus(int taskId, const QString& taskTitle)
{
    // 服务层兜底：界面入口已按平台隐藏，但任务页「开始专注」等路径仍可能按旧偏好走到自由计时。
    if (!m_freeTimingAllowed) {
        qWarning() << "Failed to start free focus: free timing is disabled on this platform";
        emit operationFailed(QStringLiteral("这台设备暂时只支持番茄专注"));
        return false;
    }
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

bool FocusTimer::startManualRest()
{
    // 主动休息是没有目标的正计时，移动端在后台无法预约到点提醒，验证期不开放。
    if (!m_freeTimingAllowed) {
        qWarning() << "Failed to start manual rest: free timing is disabled on this platform";
        emit operationFailed(QStringLiteral("这台设备暂时不支持主动休息"));
        return false;
    }
    if (hasActiveTimer()) {
        qWarning() << "Failed to start manual rest: focus timer already has an active session"
                   << "sessionId=" << m_sessionId << "phase=" << m_phase;
        return false;
    }

    // 主动休息只借用全局计时和恢复快照，不创建 focus_sessions。这样统计、历史和导出
    // 都不会把休息误算为专注；结束后另存休息历史，任务字段必须留空。
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_startTime = QDateTime::currentDateTime();
    m_elapsedSeconds = 0;
    m_accumulatedMilliseconds = 0;
    m_lastCheckpointSeconds = 0;
    m_isRunning = true;
    m_sessionId = -1;
    m_mode = ManualRestMode;
    m_phase = ManualRestPhase;
    m_targetSeconds = 0;
    beginRunSegment();

    if (!persistActiveState()) {
        resetSession();
        return false;
    }
    ++m_runSegmentSerial;
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
    emit sessionLogicalDateChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
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

    // 休息段不创建 focus_sessions，结束后写入独立休息历史，保持专注统计隔离。
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
    beginRunSegment();

    if (!persistActiveState()) {
        resetSession();
        return false;
    }
    ++m_runSegmentSerial;
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
    beginRunSegment();

    if (!writeActiveState(db) || !db.commit()) {
        qWarning() << "Failed to persist active focus state:" << db.lastError().text()
                   << "taskId=" << taskId;
        db.rollback();
        resetSession();
        return false;
    }
    ++m_runSegmentSerial;
    m_timer.start();

    emit runningStateChanged();
    emit currentTaskChanged();
    emit sessionLogicalDateChanged();
    emit modeChanged();
    emit phaseChanged();
    emit tick();
    return true;
}

bool FocusTimer::pauseFocus()
{
    if (!m_isRunning) {
        return true;
    }

    // 先落盘后生效：「已暂停」写进活动快照成功后，界面才看到暂停。
    // 写失败时若照样显示暂停，快照里留着的仍是「运行中」的旧锚点；移动端重启后
    // 会按它把暂停之后的时间也补算进去——界面说停了，记录却一直在走。
    const qint64 previousAccumulatedMs = m_accumulatedMilliseconds;
    const qint64 previousSegmentStart = m_runSegmentStartNsecs;
    const qint64 previousSegmentStartUtcMs = m_runSegmentStartUtcMs;
    freezeElapsedTime();
    m_isRunning = false;
    if (!persistActiveState()) {
        // 回滚到暂停前：累计时长与运行段起点原样放回，计时器从未停过。
        m_accumulatedMilliseconds = previousAccumulatedMs;
        m_runSegmentStartNsecs = previousSegmentStart;
        m_runSegmentStartUtcMs = previousSegmentStartUtcMs;
        m_isRunning = true;
        syncElapsedTime();
        qWarning() << "Failed to pause focus: could not persist paused state"
                   << "sessionId=" << m_sessionId;
        emit operationFailed(QStringLiteral("暂停没有保存成功，计时仍在继续，请重试"));
        return false;
    }
    m_timer.stop();
    m_lastCheckpointSeconds = m_elapsedSeconds;
    emit tick();
    emit runningStateChanged();
    return true;
}

bool FocusTimer::resumeFocus()
{
    const bool canResumeBreak = m_mode == PomodoroMode && m_phase == BreakPhase;
    const bool canResumeManualRest = m_mode == ManualRestMode && m_phase == ManualRestPhase;
    if (m_sessionId == -1 && !canResumeBreak && !canResumeManualRest) {
        qWarning() << "Failed to resume focus: no active focus session";
        return false;
    }

    if (m_isRunning) {
        return true;
    }

    m_isRunning = true;
    beginRunSegment();
    // 先落盘后生效：快照仍是「已暂停」时界面却在走，移动端重启后这段时间会凭空消失。
    if (!persistActiveState()) {
        m_isRunning = false;
        m_runSegmentStartNsecs = -1;
        m_runSegmentStartUtcMs = -1;
        syncElapsedTime();
        qWarning() << "Failed to resume focus: could not persist running state"
                   << "sessionId=" << m_sessionId;
        emit operationFailed(QStringLiteral("继续没有保存成功，请重试"));
        return false;
    }
    ++m_runSegmentSerial;
    m_timer.start();
    emit runningStateChanged();
    return true;
}

bool FocusTimer::stopFocus()
{
    if (m_phase == BreakPhase || m_phase == ManualRestPhase) {
        // 休息保存和活动快照清理必须在同一事务内，否则失败重试可能重复生成记录。
        const bool wasRunning = m_isRunning;
        if (wasRunning) {
            freezeElapsedTime();
            m_timer.stop();
        }
        QSqlDatabase db = DatabaseManager::instance()->database();
        bool saved = db.isOpen() && db.transaction();
        if (saved) {
            // 不套用专注最小时长门槛；仅忽略不足一秒的误触。
            const int duration = m_phase == BreakPhase
                ? qMin(m_elapsedSeconds, m_targetSeconds) : m_elapsedSeconds;
            if (duration > 0) {
                // 结束点按「起点 + 实际计时」写入，而不是当前时刻：暂停和关机期间并没有在休息，
                // 把它们记进区间会让时间轴显示一段远长于时长的休息，也会挡住这段时间的补录。
                const QDateTime restStart = m_startTime.isValid()
                    ? m_startTime : QDateTime::currentDateTime().addSecs(-duration);
                QSqlQuery query(db);
                query.prepare(QStringLiteral(
                    "INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                    "VALUES (:start, :end, :duration, :manual)"));
                query.bindValue(QStringLiteral(":start"), restStart.toString(Qt::ISODateWithMs));
                query.bindValue(QStringLiteral(":end"), restStart.addSecs(duration).toString(Qt::ISODateWithMs));
                query.bindValue(QStringLiteral(":duration"), duration);
                query.bindValue(QStringLiteral(":manual"), m_phase == ManualRestPhase ? 1 : 0);
                saved = query.exec();
                if (!saved) {
                    qWarning() << "Failed to save rest session:" << query.lastError().text();
                }
            }
            saved = saved && clearActiveState(db) && db.commit();
            if (!saved) {
                db.rollback();
            }
        }
        if (!saved) {
            if (wasRunning) {
                m_isRunning = true;
                beginRunSegment();
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
        emit restCompleted();
        return true;
    }

    return completeFocusSession(false);
}

bool FocusTimer::stopFreeFocusWithDuration(int durationSeconds)
{
    if (m_sessionId == -1 || m_mode != FreeMode || m_phase != NoPhase) {
        qWarning() << "Failed to correct free focus duration: no active free-focus session";
        return false;
    }
    if (durationSeconds < FocusSessionRules::kMinimumValidDurationSeconds) {
        qWarning() << "Failed to correct free focus duration: duration is below minimum"
                   << durationSeconds;
        return false;
    }
    // 修正只能往下调：人不可能专注得比计时器实际跑过的时间更久。少了这条上限，
    // 界面上把 09:01 手滑打成 90:01 就会静默写入一条 90 小时的专注记录，
    // 而 duration 正是统计的计算依据。前端有自己的提示，
    // 但数据边界必须由服务层守住。
    const int actualElapsedSeconds = static_cast<int>(currentElapsedMilliseconds() / 1000);
    if (durationSeconds > actualElapsedSeconds) {
        qWarning() << "Failed to correct free focus duration: duration exceeds elapsed time"
                   << durationSeconds << ">" << actualElapsedSeconds;
        return false;
    }

    // 修正值只在用户主动确认超长计时时用于落库；运行中的单调时钟仍保留原值，
    // 直到本次会话成功结算，避免输入校验失败时把活动计时器改成半截状态。
    return completeFocusSession(false, nullptr, durationSeconds);
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
            beginRunSegment();
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

bool FocusTimer::completeFocusSession(bool naturalCompletion,
                                      bool* countedAsPomodoro,
                                      int correctedDurationSeconds)
{
    if (countedAsPomodoro) {
        *countedAsPomodoro = false;
    }
    if (m_sessionId == -1) {
        return false;
    }

    const bool wasRunning = m_isRunning;
    if (wasRunning) {
        freezeElapsedTime();
        m_timer.stop();
    }

    int duration = correctedDurationSeconds >= 0 ? correctedDurationSeconds : m_elapsedSeconds;
    if (naturalCompletion && m_mode == PomodoroMode && m_phase == WorkPhase
        && m_targetSeconds > 0) {
        // 单调时钟会把合盖期间一并计入；自然到点的番茄应记录配置目标，而不是
        // 唤醒后才处理 timeout 所造成的超额时间。手动停止和自由计时不走此分支，
        // 仍完整保留用户实际专注时长。
        duration = qMin(duration, m_targetSeconds);
    }
    // 截断掉的那段（合盖、卡顿造成的超额）不在专注里：结束时刻要往回推这么多，
    // 否则记录占用的区间比时长长出一大截。
    const int overshootSeconds = qMax(0, m_elapsedSeconds - duration);
    if (duration < FocusSessionRules::kMinimumValidDurationSeconds) {
        // 低于 3 分钟的会话视为无效，直接删除 startFocus 预先插入的占位记录，避免历史页出现 0 分钟噪音。
        if (!discardFocusSession()) {
            if (wasRunning) {
                beginRunSegment();
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
    if (!saveFocusSession(duration, naturalCompletion, correctedDurationSeconds >= 0,
                          correctedDurationSeconds >= 0 ? 0 : overshootSeconds)) {
        if (wasRunning) {
            beginRunSegment();
            m_timer.start();
        }
        return false;
    }

    const int completedTaskId = m_currentTaskId;
    const bool completedPomodoro = isCompletedPomodoroSession(
        naturalCompletion, m_mode, m_phase, duration);
    if (countedAsPomodoro) {
        *countedAsPomodoro = completedPomodoro;
    }
    // 任务可能在会话进行中被删除（外键置空后恢复的会话 task_id 为 -1）；
    // 没有可完成的任务时跳过自动完成，而不是制造一次必然失败的告警。
    // 预计用时是时间口径，自由计时的时长同样是「用时」，所以不再只在自然到点的番茄后判定。
    // 只要这次会话真的入了库（时长达到有效门槛），就该看看它有没有把任务推过预计用时。
    const bool shouldCheckTaskTarget = completedTaskId > 0;

    // 会话已经持久化后先清空活动态，再触发 TaskManager::tasksChanged。否则订阅方会在同一刷新中
    // 同时看到“已完成数据库记录”和“仍活动的计时器”，把最后一段时长重复计入界面统计。
    resetSession();

    bool taskChangeAlreadyEmitted = false;
    if (shouldCheckTaskTarget) {
        // 本次会话把累计专注时长推过任务的预计用时时才完成它；
        // 「本次之前就已超额」由 TaskManager 侧的第二个条件挡住。
        const TaskManager::TargetCompletionResult result =
            TaskManager::instance()->completeTaskIfEstimateReached(completedTaskId, duration);
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

bool FocusTimer::saveFocusSession(int durationSeconds, bool naturalCompletion,
                                  bool durationWasCorrected,
                                  int overshootSeconds)
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
    //
    // 用户修正过时长时，记录占用的时间区间必须跟着缩短。end_time 仍写「现在」的话，
    // 一条被改成 45 分钟的记录会继续横跨 9 小时：时间轴上画成「08:59 - 17:59 / 45分钟」
    // 自相矛盾，更要命的是 FocusHistoryService 的重叠校验按 start_time…end_time 判定，
    // 那整段窗口会被锁死，用户没法再补录这段时间里真实发生的其它专注——而「忘了停、
    // 改完再补录」恰恰是这个修正功能最典型的下一步。区间只会收缩，不可能制造新的重叠。
    //
    // 自然到点时被截掉的超额（overshootSeconds）同理：结束时刻取「到点的那一刻」，
    // 也就是现在往回推超额秒数，不是唤醒后才处理到点的时刻。
    //
    // 最后再兜一层：结束时刻不早于「开始 + 时长」。时长来自单调时钟，不受改系统时钟影响，
    // 起止却是墙钟；计时中把时钟往回拨，写出来的结束会早于开始——这种倒置的记录不再占用
    // 时间线，之后连改归属都会被「开始或结束时间无效」挡住。
    QDateTime endTime = (durationWasCorrected && m_startTime.isValid())
        ? m_startTime.addSecs(durationSeconds)
        : QDateTime::currentDateTime().addSecs(-overshootSeconds);
    if (m_startTime.isValid() && endTime < m_startTime.addSecs(durationSeconds)) {
        endTime = m_startTime.addSecs(durationSeconds);
    }
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
            mode, phase, target_seconds, completed_pomodoros, updated_at, start_time,
            running, accumulated_ms, segment_start_ns, segment_start_wall_ms, boot_id
        ) VALUES (
            1, :sessionId, :taskId, :taskTitle, :elapsedSeconds,
            :mode, :phase, :targetSeconds, :completedPomodoros, :updatedAt, :startTime,
            :running, :accumulatedMs, :segmentStartNs, :segmentStartWallMs, :bootId
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
            updated_at = excluded.updated_at,
            start_time = excluded.start_time,
            running = excluded.running,
            accumulated_ms = excluded.accumulated_ms,
            segment_start_ns = excluded.segment_start_ns,
            segment_start_wall_ms = excluded.segment_start_wall_ms,
            boot_id = excluded.boot_id
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
    query.bindValue(QStringLiteral(":startTime"), m_startTime.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":updatedAt"), QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
    // 恢复锚点：运行中时记下「本段之前的累计」和「本段起点的单调时钟读数」，再加上开机标识。
    // 同一次开机里，恢复时用「现在 − 本段起点」就能算出离线期间走了多久，不依赖可被修改的墙钟。
    // 暂停时起点写空：暂停不会随时间增长，恢复只需要累计值。
    const bool anchorRunning = m_isRunning && m_runSegmentStartNsecs >= 0;
    const QString bootId = m_clock->bootSessionId();
    query.bindValue(QStringLiteral(":running"), anchorRunning ? 1 : 0);
    query.bindValue(QStringLiteral(":accumulatedMs"), m_accumulatedMilliseconds);
    query.bindValue(QStringLiteral(":segmentStartNs"),
                    anchorRunning ? QVariant(m_runSegmentStartNsecs) : QVariant());
    query.bindValue(QStringLiteral(":segmentStartWallMs"),
                    anchorRunning && m_runSegmentStartUtcMs >= 0 ? QVariant(m_runSegmentStartUtcMs) : QVariant());
    query.bindValue(QStringLiteral(":bootId"), bootId.isEmpty() ? QVariant() : QVariant(bootId));

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
               completed_pomodoros, start_time, updated_at,
               running, accumulated_ms, segment_start_ns, boot_id, segment_start_wall_ms
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
    // 恢复锚点（旧快照这几列为空或默认 0，按「未在运行」处理，不补任何离线时段）。
    const bool restoredRunning = stateQuery.value(10).toInt() == 1;
    const qint64 restoredAccumulatedMs = stateQuery.value(11).toLongLong();
    const bool restoredHasSegmentStart = !stateQuery.value(12).isNull();
    const qint64 restoredSegmentStart = stateQuery.value(12).toLongLong();
    const QString restoredBootId = stateQuery.value(13).toString();
    const bool restoredHasWallStart = !stateQuery.value(14).isNull();
    const qint64 restoredSegmentStartUtcMs = stateQuery.value(14).toLongLong();

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
    const bool isManualRest = restoredMode == ManualRestMode && restoredPhase == ManualRestPhase
        && restoredSessionId == -1 && restoredTaskId == -1 && restoredTitle.isEmpty()
        && restoredTarget == 0;

    QDateTime restoredStartTime = QDateTime::fromString(stateQuery.value(8).toString(), Qt::ISODate);
    if (!restoredStartTime.isValid()) {
        // 旧版休息快照没有起点，只能以最后检查点减去有效秒数兼容恢复。
        restoredStartTime = QDateTime::fromString(stateQuery.value(9).toString(), Qt::ISODate)
                                .addSecs(-restoredElapsed);
        if (!restoredStartTime.isValid()) {
            restoredStartTime = QDateTime::currentDateTime().addSecs(-restoredElapsed);
        }
    }
    bool sessionRowValid = isPomodoroBreak || isManualRest;
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

    if (!(isFreeFocus || isPomodoroWork || isPomodoroBreak || isManualRest) || !sessionRowValid) {
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
    // 保留原起点；累计时长仍只读取检查点，不追加离线时段。
    m_startTime = restoredStartTime;
    m_elapsedSeconds = restoredElapsed;
    m_accumulatedMilliseconds = static_cast<qint64>(restoredElapsed) * 1000;
    m_lastCheckpointSeconds = restoredElapsed;
    m_isRunning = false;
    m_mode = static_cast<TimerMode>(restoredMode);
    m_phase = static_cast<TimerPhase>(restoredPhase);
    m_targetSeconds = restoredTarget;
    m_completedPomodoros = restoredPomodoros;
    m_runSegmentStartNsecs = -1;
    m_runSegmentStartUtcMs = -1;
    m_timer.stop();

    // 移动端：同一次开机内被结束的番茄段，按单调时钟补回离线时段并继续计时。
    // 已经到期的段由第一次 tick 走离线结算——与「挂起后回到前台」是同一条路径。
    // 只有番茄（专注与休息）补算：它有到点时刻、有系统预约的提醒；自由计时与主动休息
    // 没有上限，补算会把忘了停表的一整晚都记进去，仍按原语义恢复为暂停。
    //
    // 「是不是同一次开机」怎么判断：单调时钟的读数只在同一次开机内可比。iOS 沙盒不允许读取
    // 开机会话标识（真机实测 sysctl kern.bootsessionuuid 返回失败），所以改为对账——
    // 离开期间单调时钟走过的时长必须与墙钟走过的时长一致（误差 kClockAgreementToleranceMs 以内）。
    // 重启后单调时钟从零计数、离开期间有人改了系统时间，两边都会对不上，此时一律恢复为暂停：
    // 只会少补，不会多记。离线时长本身始终只用单调时钟计算，墙钟只参与核对。
    // 两边都读得到开机标识（例如 macOS）时，标识不同同样视为换过开机。
    bool resumedRunning = false;
    if (m_recoveryPolicy == RecoveryPolicy::CatchUpOffline
        && (isPomodoroWork || isPomodoroBreak)
        && restoredRunning && restoredHasSegmentStart && restoredHasWallStart
        && restoredAccumulatedMs >= 0) {
        const QString currentBootId = m_clock->bootSessionId();
        const qint64 nowNsecs = m_clock->nowNsecs();
        const bool bootIdsDiffer = !restoredBootId.isEmpty() && !currentBootId.isEmpty()
            && restoredBootId != currentBootId;
        const qint64 monotonicAwayMs = (nowNsecs - restoredSegmentStart) / 1000000;
        const qint64 wallAwayMs = m_clock->utcNowMsecs() - restoredSegmentStartUtcMs;
        const bool clocksAgree = restoredSegmentStart >= 0 && restoredSegmentStart <= nowNsecs
            && qAbs(monotonicAwayMs - wallAwayMs) <= kClockAgreementToleranceMs;
        if (!bootIdsDiffer && clocksAgree) {
            m_accumulatedMilliseconds = restoredAccumulatedMs;
            m_runSegmentStartNsecs = restoredSegmentStart;
            m_runSegmentStartUtcMs = restoredSegmentStartUtcMs;
            m_isRunning = true;
            syncElapsedTime();
            m_lastCheckpointSeconds = m_elapsedSeconds;
            ++m_runSegmentSerial;
            resumedRunning = true;
        }
    }

    if (!cleanupOrphanedSessions()) {
        resetSession();
        return false;
    }
    if (resumedRunning) {
        m_timer.start();
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

    if (m_recoveryPolicy == RecoveryPolicy::CatchUpOffline) {
        // 移动端：系统结束进程不代表用户想暂停。保留「运行中」锚点，只刷新检查点，
        // 下次启动按离线时段补算；若在这里暂停，恢复后番茄会停在退出那一刻。
        checkpoint();
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

void FocusTimer::checkpoint()
{
    if (!hasActiveTimer()) {
        return;
    }
    syncElapsedTime();
    if (persistActiveState()) {
        m_lastCheckpointSeconds = m_elapsedSeconds;
    } else {
        qWarning() << "Failed to write focus checkpoint" << "sessionId=" << m_sessionId;
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

void FocusTimer::beginRunSegment()
{
    m_runSegmentStartNsecs = m_clock->nowNsecs();
    m_runSegmentStartUtcMs = m_clock->utcNowMsecs();
}

void FocusTimer::freezeElapsedTime()
{
    // 把当前运行段折进累计时长，并标记运行段结束（-1），避免暂停/结束瞬间被重复计入。
    if (m_isRunning && m_runSegmentStartNsecs >= 0) {
        const qint64 segmentMs = (m_clock->nowNsecs() - m_runSegmentStartNsecs) / 1000000;
        m_accumulatedMilliseconds += qMax<qint64>(0, segmentMs);
        m_runSegmentStartNsecs = -1;
        m_runSegmentStartUtcMs = -1;
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
    m_runSegmentStartUtcMs = -1;
    emit sessionLogicalDateChanged();
}
