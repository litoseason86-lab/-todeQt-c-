#include "FocusSessionController.h"

#include <QScopeGuard>
#include <QtMath>

#include "AppSettings.h"
#include "FocusTimer.h"
#include "LogicalDay.h"
#include "PendingDeletion.h"
#include "TaskManager.h"

namespace {

constexpr int kDefaultWarningHours = 8;

QVariantMap makeEndResult(const QString& result, const QString& kind = QString(),
                          bool discarded = false, const QString& error = QString())
{
    return {
        {QStringLiteral("result"), result},
        {QStringLiteral("kind"), kind},
        {QStringLiteral("discarded"), discarded},
        {QStringLiteral("error"), error},
    };
}

} // namespace

FocusSessionController::FocusSessionController(FocusTimer* timer, TaskManager* tasks,
                                               AppSettings* settings,
                                               PendingDeletion* pendingDeletion, QObject* parent)
    : QObject(parent)
    , m_timer(timer)
    , m_tasks(tasks)
    , m_settings(settings)
    , m_pendingDeletion(pendingDeletion)
{
}

int FocusSessionController::freeTimerWarningHours() const
{
    const double configured = m_settings ? m_settings->freeTimerWarningHours() : kDefaultWarningHours;
    return (configured >= 1 && configured <= 24) ? qRound(configured) : kDefaultWarningHours;
}

int FocusSessionController::nextBreakMinutes(int selectedBreakMinutes) const
{
    if (m_settings && m_timer && m_settings->longBreakDueAfter(m_timer->completedPomodoros())) {
        return m_settings->longBreakMinutes();
    }
    return selectedBreakMinutes;
}

bool FocusSessionController::autoAdvanceAfter(int completedPhase) const
{
    if (!m_settings) {
        return false;
    }
    if (completedPhase == FocusTimer::WorkPhase) {
        return m_settings->autoStartBreak();
    }
    if (completedPhase == FocusTimer::BreakPhase) {
        return m_settings->autoStartNextPomodoro();
    }
    return false;
}

bool FocusSessionController::needsLongFreeStopConfirmation() const
{
    if (!m_timer || !m_timer->hasActiveSession() || m_timer->mode() != FocusTimer::FreeMode) {
        return false;
    }
    return m_timer->requiresFreeFocusStopConfirmation(freeTimerWarningHours());
}

QVariantMap FocusSessionController::endCurrent()
{
    return endCurrentImpl(false);
}

QVariantMap FocusSessionController::endCurrentImpl(bool resetCycle)
{
    if (!m_timer || (!m_timer->hasActiveSession() && m_timer->phase() == FocusTimer::NoPhase)) {
        if (m_timer && resetCycle) {
            return m_timer->resetPomodoroCount()
                ? makeEndResult(QStringLiteral("ended"), QStringLiteral("pomodoro"))
                : makeEndResult(QStringLiteral("failed"), QStringLiteral("pomodoro"), false,
                                QStringLiteral("番茄循环保存失败，请重试"));
        }
        return makeEndResult(QStringLiteral("none"));
    }

    // sessionDiscarded 在 stopFocus 过程中同步发出，必须在调用前接上；
    // 出口一律断开（含提前 return），避免悬挂的连接捕获到之后别处的丢弃。
    bool discarded = false;
    const QMetaObject::Connection connection = connect(
        m_timer, &FocusTimer::sessionDiscarded, this, [&discarded](int) { discarded = true; });
    const auto disconnector = qScopeGuard([&] { disconnect(connection); });

    // 以下三路用的是计时器的真实模式。主动休息 mode 2、phase 3；番茄 mode 1（含番茄间的休息段，
    // 那时没有数据库会话，hasActiveSession 为假，仍必须允许结束）；其余按自由专注处理。
    if (m_timer->mode() == FocusTimer::ManualRestMode && m_timer->phase() == FocusTimer::ManualRestPhase) {
        if (!(resetCycle ? m_timer->stopAndResetPomodoroCycle() : m_timer->stopFocus())) {
            return makeEndResult(QStringLiteral("failed"), QStringLiteral("manualRest"), false,
                                 QStringLiteral("结束休息失败，请重试"));
        }
        return makeEndResult(QStringLiteral("ended"), QStringLiteral("manualRest"), discarded);
    }

    if (m_timer->mode() == FocusTimer::PomodoroMode) {
        if (!m_timer->stopAndResetPomodoroCycle()) {
            return makeEndResult(QStringLiteral("failed"), QStringLiteral("pomodoro"), false,
                                 QStringLiteral("番茄结束失败，请重试"));
        }
        // 完全结束番茄循环：连续计数归零，下一轮长休息节奏从头开始。
        return makeEndResult(QStringLiteral("ended"), QStringLiteral("pomodoro"), discarded);
    }

    if (needsLongFreeStopConfirmation()) {
        return makeEndResult(QStringLiteral("needsConfirmation"), QStringLiteral("free"));
    }
    if (!(resetCycle ? m_timer->stopAndResetPomodoroCycle() : m_timer->stopFocus())) {
        return makeEndResult(QStringLiteral("failed"), QStringLiteral("free"), false,
                             QStringLiteral("专注保存失败，请重试"));
    }
    return makeEndResult(QStringLiteral("ended"), QStringLiteral("free"), discarded);
}

QVariantMap FocusSessionController::endPomodoroCycle()
{
    // 清零意图必须进入计时器事务，不能结束记录提交后另写一次计数。
    return endCurrentImpl(true);
}

QVariantMap FocusSessionController::handleTaskCompleted(int taskId)
{
    if (!m_timer || !m_timer->hasActiveSession() || m_timer->currentTaskId() != taskId) {
        return {
            {QStringLiteral("focusResult"), QStringLiteral("none")},
            {QStringLiteral("kind"), QString()},
            {QStringLiteral("discarded"), false},
            {QStringLiteral("error"), QString()},
        };
    }
    const QVariantMap ended = endCurrent();
    return {
        {QStringLiteral("focusResult"), ended.value(QStringLiteral("result"))},
        {QStringLiteral("kind"), ended.value(QStringLiteral("kind"))},
        {QStringLiteral("discarded"), ended.value(QStringLiteral("discarded"))},
        {QStringLiteral("error"), ended.value(QStringLiteral("error"))},
    };
}

QVariantMap FocusSessionController::finishLongFree(bool recordSession, int correctedSeconds)
{
    bool succeeded = false;
    if (m_timer) {
        if (recordSession) {
            succeeded = correctedSeconds > 0 ? m_timer->stopFreeFocusWithDuration(correctedSeconds)
                                             : m_timer->stopFocus();
        } else {
            succeeded = m_timer->discardFreeFocus();
        }
    }
    return {
        {QStringLiteral("ok"), succeeded},
        {QStringLiteral("error"), succeeded ? QString()
            : (recordSession ? QStringLiteral("专注保存失败，请重试")
                             : QStringLiteral("专注丢弃失败，请重试"))},
    };
}

QVariantMap FocusSessionController::planTaskEntry(int taskId, const QString& title) const
{
    const QString trimmed = title.trimmed();
    QString kind;
    if (!m_timer || taskId <= 0 || trimmed.isEmpty()) {
        kind = QStringLiteral("invalid");
    } else if (m_timer->hasActiveSession() && m_timer->currentTaskId() == taskId) {
        // 点的正是正在计时的任务：回到当前计时即可，不看记住的模式。
        kind = QStringLiteral("returnToCurrent");
    } else if (m_timer->hasActiveSession() || m_timer->phase() != FocusTimer::NoPhase) {
        kind = QStringLiteral("confirmSwitch");
    } else {
        kind = QStringLiteral("apply");
    }
    const bool freeAllowed = !m_timer || m_timer->freeTimingAllowed();
    return {
        {QStringLiteral("kind"), kind},
        {QStringLiteral("usePomodoro"), (m_settings && m_settings->lastMode() == 1) || !freeAllowed},
        {QStringLiteral("autoStart"), m_settings && m_settings->quickStartEnabled()},
        {QStringLiteral("title"), trimmed},
    };
}

QVariantMap FocusSessionController::switchConsequence() const
{
    const int minimumMinutes = m_timer ? m_timer->minimumValidMinutes() : 3;
    QString kind = QStringLiteral("saved");
    if (m_timer) {
        const int phase = m_timer->phase();
        if (phase == FocusTimer::BreakPhase || phase == FocusTimer::ManualRestPhase) {
            kind = QStringLiteral("restKept");
        } else if (m_timer->elapsedSeconds() < minimumMinutes * 60) {
            kind = QStringLiteral("notSaved");
        }
    }
    return {
        {QStringLiteral("kind"), kind},
        {QStringLiteral("minimumMinutes"), minimumMinutes},
    };
}

QVariantMap FocusSessionController::captureSwitchSource() const
{
    return {
        {QStringLiteral("taskId"), m_timer ? m_timer->currentTaskId() : -1},
        {QStringLiteral("mode"), m_timer ? m_timer->mode() : 0},
        {QStringLiteral("phase"), m_timer ? m_timer->phase() : 0},
    };
}

QString FocusSessionController::stopForSwitch(const QVariantMap& source)
{
    if (!m_timer) {
        emit operationFailed(QStringLiteral("切换计时失败：专注计时器不可用"));
        return QStringLiteral("stopFailed");
    }
    if (m_timer->currentTaskId() != source.value(QStringLiteral("taskId")).toInt()
        || m_timer->mode() != source.value(QStringLiteral("mode")).toInt()
        || m_timer->phase() != source.value(QStringLiteral("phase")).toInt()) {
        return QStringLiteral("stateChanged");
    }
    if (needsLongFreeStopConfirmation()) {
        return QStringLiteral("needsLongFreeConfirmation");
    }
    if (!m_timer->stopFocus()) {
        return QStringLiteral("stopFailed");
    }
    return QStringLiteral("stopped");
}

QVariantMap FocusSessionController::planModeSwitch(int selectedTaskId, const QString& selectedTitle) const
{
    const QVariantMap pageOnly{{QStringLiteral("kind"), QStringLiteral("pageOnly")}};
    if (!m_timer) {
        return pageOnly;
    }
    const bool busy = m_timer->hasActiveSession() || m_timer->phase() != FocusTimer::NoPhase;
    // 活动任务被删除后计时器会解绑任务编号：没有可继承的任务就退回页内切换，
    // 否则按「切换任务」处理只会原地失败。
    const int taskId = m_timer->currentTaskId() > 0 ? m_timer->currentTaskId() : selectedTaskId;
    const QString timerTitle = m_timer->currentTaskTitle();
    const QString title = (timerTitle.isEmpty() ? selectedTitle : timerTitle).trimmed();
    if (!busy || taskId <= 0 || title.isEmpty()) {
        return pageOnly;
    }
    return {
        {QStringLiteral("kind"), QStringLiteral("confirmSwitch")},
        {QStringLiteral("taskId"), taskId},
        {QStringLiteral("title"), title},
    };
}

QDate FocusSessionController::logicalToday() const
{
    const int hour = m_settings ? m_settings->dayStartHour() : 4;
    return LogicalDay::dateOf(m_now(), hour);
}

QVariantMap FocusSessionController::autoStartCandidate(int selectedTaskId, const QString& selectedTitle) const
{
    QVariantMap candidate{
        {QStringLiteral("id"), -1},
        {QStringLiteral("title"), QString()},
        {QStringLiteral("selectionStale"), false},
    };
    if (!m_tasks) {
        return candidate;
    }

    const QString title = selectedTitle.trimmed();
    if (selectedTaskId > 0 && !title.isEmpty()) {
        // 选中项只在少数路径里清空，在今日页删掉任务不会清它；拿已删除的编号去启动，
        // 服务端插入 0 行而失败，快捷键就既没启动也没展开选择器。所以先按编号回查。
        const QVariantMap found = m_tasks->getTask(selectedTaskId);
        if (found.value(QStringLiteral("id")).toInt() == selectedTaskId) {
            candidate[QStringLiteral("id")] = selectedTaskId;
            candidate[QStringLiteral("title")] = title;
            return candidate;
        }
        candidate[QStringLiteral("selectionStale")] = true;
    }

    const int pendingId = m_pendingDeletion ? m_pendingDeletion->taskId() : -1;
    // getTasksByDate 已按「未完成在前、display_order 升序」排好。
    const QVariantList today = m_tasks->getTasksByDate(logicalToday());
    for (const QVariant& value : today) {
        const QVariantMap task = value.toMap();
        const int id = task.value(QStringLiteral("id")).toInt();
        if (task.value(QStringLiteral("completed")).toBool() || (pendingId > 0 && id == pendingId)) {
            continue;
        }
        candidate[QStringLiteral("id")] = id;
        candidate[QStringLiteral("title")] = task.value(QStringLiteral("title")).toString();
        return candidate;
    }
    return candidate;
}

int FocusSessionController::createTodayTask(const QString& title)
{
    const QString trimmed = title.trimmed();
    if (!m_tasks) {
        emit operationFailed(QStringLiteral("新建专注任务失败：任务服务不可用"));
        return -1;
    }
    // 标题校验交给 TaskManager，空标题同样保留服务给出的具体原因。
    const int id = m_tasks->createTask(trimmed, logicalToday(), -1, 0, QString());
    return id > 0 ? id : -1;
}
