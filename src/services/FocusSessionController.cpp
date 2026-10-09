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

bool FocusSessionController::needsLongFreeStopConfirmation() const
{
    if (!m_timer || !m_timer->hasActiveSession() || m_timer->mode() != FocusTimer::FreeMode) {
        return false;
    }
    return m_timer->requiresFreeFocusStopConfirmation(freeTimerWarningHours());
}

QVariantMap FocusSessionController::endCurrent()
{
    if (!m_timer || (!m_timer->hasActiveSession() && m_timer->phase() == FocusTimer::NoPhase)) {
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
        if (!m_timer->stopFocus()) {
            return makeEndResult(QStringLiteral("failed"), QStringLiteral("manualRest"), false,
                                 QStringLiteral("结束休息失败，请重试"));
        }
        return makeEndResult(QStringLiteral("ended"), QStringLiteral("manualRest"), discarded);
    }

    if (m_timer->mode() == FocusTimer::PomodoroMode) {
        if (!m_timer->stopFocus()) {
            return makeEndResult(QStringLiteral("failed"), QStringLiteral("pomodoro"), false,
                                 QStringLiteral("番茄结束失败，请重试"));
        }
        // 完全结束番茄循环：连续计数归零，下一轮长休息节奏从头开始。
        m_timer->resetPomodoroCount();
        return makeEndResult(QStringLiteral("ended"), QStringLiteral("pomodoro"), discarded);
    }

    if (needsLongFreeStopConfirmation()) {
        return makeEndResult(QStringLiteral("needsConfirmation"), QStringLiteral("free"));
    }
    if (!m_timer->stopFocus()) {
        return makeEndResult(QStringLiteral("failed"), QStringLiteral("free"), false,
                             QStringLiteral("专注保存失败，请重试"));
    }
    return makeEndResult(QStringLiteral("ended"), QStringLiteral("free"), discarded);
}

QVariantMap FocusSessionController::endPomodoroCycle()
{
    const QVariantMap outcome = endCurrent();
    // 没有计时器时 endCurrent 也报 none，这里不能再去解引用。
    if (!m_timer) {
        return outcome;
    }
    const QString result = outcome.value(QStringLiteral("result")).toString();
    if (result == QLatin1String("none")) {
        m_timer->resetPomodoroCount();
        return makeEndResult(QStringLiteral("ended"), QStringLiteral("pomodoro"));
    }
    if (result == QLatin1String("ended")) {
        // endCurrent 在番茄模式下已归零；会话若是按自由模式结束的，这里补上。
        m_timer->resetPomodoroCount();
    }
    return outcome;
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
    if (!m_tasks || trimmed.isEmpty()) {
        return -1;
    }
    const int id = m_tasks->createTask(trimmed, logicalToday(), -1, 0, QString());
    return id > 0 ? id : -1;
}
