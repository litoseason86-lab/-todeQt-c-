#include "PhaseAlarmCoordinator.h"

#include "AppSettings.h"
#include "FocusTimer.h"
#include "NotificationService.h"

#include <QDebug>
#include <QPointer>
#include <QUuid>

PhaseAlarmCoordinator::PhaseAlarmCoordinator(FocusTimer* timer,
                                             NotificationService* notifications,
                                             QObject* parent)
    : QObject(parent)
    , m_timer(timer)
    , m_notifications(notifications)
    , m_processToken(QUuid::createUuid().toString(QUuid::Id128).left(8))
{
    connect(m_timer, &FocusTimer::runningStateChanged, this, &PhaseAlarmCoordinator::requestReconcile);
    connect(m_timer, &FocusTimer::phaseChanged, this, &PhaseAlarmCoordinator::requestReconcile);
    connect(m_timer, &FocusTimer::modeChanged, this, &PhaseAlarmCoordinator::requestReconcile);
    // 完成信号在计时器结算的同一调用栈里发出，先于排队的对账，这里只记下「是自然到点」。
    const auto markNaturalEnd = [this](int) {
        m_naturalEndPending = true;
        requestReconcile();
    };
    connect(m_timer, &FocusTimer::phaseCompleted, this, markNaturalEnd);
    connect(m_timer, &FocusTimer::phaseSettledOffline, this, markNaturalEnd);
}

QString PhaseAlarmCoordinator::idPrefix()
{
    return QStringLiteral("pomodoro-phase-");
}

void PhaseAlarmCoordinator::start()
{
    if (m_started) {
        return;
    }
    m_started = true;
    // 上一个进程可能在到点前被结束，它的预约还挂在系统里；恢复后的这一段会重新预约。
    Operation cleanup;
    cleanup.kind = Operation::Kind::CancelAll;
    enqueue(cleanup);
    reconcile();
}

bool PhaseAlarmCoordinator::currentAlarmScheduled() const
{
    return m_hasCurrent && m_currentStatus == AlarmStatus::Scheduled;
}

bool PhaseAlarmCoordinator::coversPhase(int phase) const
{
    return currentAlarmScheduled() && m_currentPhase == phase;
}

void PhaseAlarmCoordinator::requestReconcile()
{
    if (m_reconcileQueued) {
        return;
    }
    m_reconcileQueued = true;
    QMetaObject::invokeMethod(this, &PhaseAlarmCoordinator::reconcile, Qt::QueuedConnection);
}

void PhaseAlarmCoordinator::reconcile()
{
    m_reconcileQueued = false;
    if (!m_started) {
        return;
    }

    // 只有「正在走、有到点时刻、还没到点」的番茄段需要预约。剩余为 0 说明这一段已经到期、
    // 正等下一次 tick 结算（例如重启后恢复出一段已过期的番茄），此时预约只会立刻多响一次。
    const bool wantAlarm = m_timer->isRunning()
        && m_timer->mode() == FocusTimer::PomodoroMode
        && m_timer->targetSeconds() > 0
        && m_timer->remainingSeconds() > 0;
    const bool naturalEnd = m_naturalEndPending;
    m_naturalEndPending = false;

    if (!wantAlarm) {
        if (m_hasCurrent) {
            // 暂停、提前结束、丢弃：撤销尚未投递的预约，否则用户停了表还会在原时刻被提醒。
            // 自然到点：预约的那条就是这次的提醒，不撤销。
            if (!naturalEnd) {
                Operation cancel;
                cancel.kind = Operation::Kind::CancelAll;
                enqueue(cancel);
            }
            clearCurrent();
        }
        return;
    }

    const quint64 segment = m_timer->runSegmentSerial();
    if (m_hasCurrent && m_currentSegment == segment) {
        // 同一段运行，到点时刻没变，已有的预约继续有效。
        return;
    }
    if (m_hasCurrent && !naturalEnd) {
        // 同一轮对账里既结束了旧段又开始了新段（例如很快地暂停再继续），旧段的预约必须作废。
        Operation cancel;
        cancel.kind = Operation::Kind::CancelAll;
        enqueue(cancel);
    }

    Operation schedule;
    schedule.kind = Operation::Kind::Schedule;
    if (!composeContent(&schedule.title, &schedule.body, &schedule.playSound)) {
        clearCurrent();
        return;
    }
    ++m_generation;
    schedule.generation = m_generation;
    schedule.id = idPrefix() + m_processToken + QLatin1Char('-') + QString::number(m_generation);
    schedule.fireAfterSeconds = qMax(1, m_timer->remainingSeconds());

    m_hasCurrent = true;
    m_currentGeneration = m_generation;
    m_currentSegment = segment;
    m_currentPhase = m_timer->phase();
    m_currentId = schedule.id;
    m_currentStatus = AlarmStatus::Pending;
    emit currentAlarmChanged();
    enqueue(schedule);
}

bool PhaseAlarmCoordinator::composeContent(QString* title, QString* body, bool* playSound) const
{
    const AppSettings* settings = AppSettings::instance();
    const int phase = m_timer->phase();
    *playSound = settings->soundEnabled();
    if (phase == FocusTimer::WorkPhase) {
        // 预约发生在这个番茄完成之前：到点那一刻它才计入连续数，文案要按「完成后」的数写。
        const int completedAfter = m_timer->completedPomodoros() + 1;
        const bool isLongBreak = settings->longBreakEnabled()
            && settings->longBreakInterval() > 0
            && completedAfter % settings->longBreakInterval() == 0;
        const int breakMinutes = isLongBreak ? settings->longBreakMinutes() : settings->breakMinutes();
        return NotificationService::phaseCompleteContent(
            phase, completedAfter, breakMinutes, isLongBreak, title, body);
    }
    if (phase == FocusTimer::BreakPhase) {
        // 与界面的长休息判定同一口径：开着长休息且本段时长正好等于长休息时长。
        const bool isLongBreak = settings->longBreakEnabled()
            && m_timer->targetSeconds() == settings->longBreakMinutes() * 60;
        return NotificationService::phaseCompleteContent(phase, 0, 0, isLongBreak, title, body);
    }
    return false;
}

void PhaseAlarmCoordinator::clearCurrent()
{
    if (!m_hasCurrent) {
        return;
    }
    m_hasCurrent = false;
    m_currentId.clear();
    emit currentAlarmChanged();
}

void PhaseAlarmCoordinator::enqueue(const Operation& operation)
{
    m_queue.append(operation);
    runNext();
}

void PhaseAlarmCoordinator::runNext()
{
    // 一次只让系统处理一个操作：撤销与预约交错执行时，「先预约、后撤销」可能被系统
    // 调换顺序，留下一条已经作废的提醒。
    if (m_operationRunning || m_queue.isEmpty()) {
        return;
    }
    m_operationRunning = true;
    const Operation operation = m_queue.takeFirst();
    const QPointer<PhaseAlarmCoordinator> self(this);
    const auto done = [self, operation](bool success, const QString& reason) {
        if (self) {
            self->finishOperation(operation, success, reason);
        }
    };
    if (operation.kind == Operation::Kind::CancelAll) {
        m_notifications->cancelScheduledNotifications(idPrefix(), QString(), done);
    } else {
        m_notifications->scheduleNotification(operation.id,
                                              operation.fireAfterSeconds,
                                              operation.title,
                                              operation.body,
                                              operation.playSound,
                                              done);
    }
}

void PhaseAlarmCoordinator::finishOperation(const Operation& operation, bool success, const QString& reason)
{
    m_operationRunning = false;
    if (operation.kind == Operation::Kind::Schedule) {
        // 只认当前代次的结果：旧代次的迟到回调即使报成功，也不能把「当前已预约」置真。
        if (m_hasCurrent && operation.generation == m_currentGeneration) {
            m_currentStatus = success ? AlarmStatus::Scheduled : AlarmStatus::Failed;
            emit currentAlarmChanged();
            if (!success) {
                qWarning() << "Failed to schedule phase alarm:" << reason;
                emit alarmUnavailable(reason);
            }
        }
    } else if (!success) {
        // 撤销失败只记录：遗留的预约最多多响一次，不能因此阻塞后面的预约。
        qWarning() << "Failed to cancel phase alarms:" << reason;
    }
    runNext();
}
