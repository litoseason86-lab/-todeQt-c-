#include "FocusSessionController.h"

#include <QScopeGuard>
#include <QtMath>

#include "AppSettings.h"
#include "FocusTimer.h"

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
