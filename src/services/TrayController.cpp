#include "TrayController.h"

#include "FocusTimer.h"

TrayController::TrayController(FocusTimer* timer, QObject* parent)
    : QObject(parent)
    , m_timer(timer)
{
    // 菜单栏状态完全由计时器状态驱动。这些信号覆盖了剩余时间、运行/暂停、任务、
    // 模式与相位的每一次变化；tick 每秒推动一次剩余时间刷新。
    connect(m_timer, &FocusTimer::tick, this, &TrayController::refresh);
    connect(m_timer, &FocusTimer::runningStateChanged, this, &TrayController::refresh);
    connect(m_timer, &FocusTimer::currentTaskChanged, this, &TrayController::refresh);
    connect(m_timer, &FocusTimer::modeChanged, this, &TrayController::refresh);
    connect(m_timer, &FocusTimer::phaseChanged, this, &TrayController::refresh);

    refresh();
}

void TrayController::setView(TrayView* view)
{
    m_view = view;
    if (m_view) {
        // 立即推送当前状态，避免菜单栏首次出现时停留在空白或旧值。
        m_view->updateDisplay(m_display);
    }
}

TrayDisplay TrayController::display() const
{
    return m_display;
}

QString TrayController::formatClock(int seconds)
{
    const int safe = seconds < 0 ? 0 : seconds;
    const int hours = safe / 3600;
    const int minutes = (safe % 3600) / 60;
    const int secs = safe % 60;
    if (hours > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QLatin1Char('0'))
            .arg(secs, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2")
        .arg(minutes, 2, 10, QLatin1Char('0'))
        .arg(secs, 2, 10, QLatin1Char('0'));
}

void TrayController::refresh()
{
    TrayDisplay next;

    const bool active = m_timer->hasActiveSession() || m_timer->phase() != FocusTimer::NoPhase;
    if (!active) {
        // 空闲：菜单栏只留图标/简称，菜单里给出可读状态，控制项全部禁用。
        next.taskLine = QStringLiteral("未在专注");
        next.stateLine = QStringLiteral("状态：空闲");
    } else {
        const bool running = m_timer->isRunning();
        const bool isBreak = m_timer->phase() == FocusTimer::BreakPhase;
        const bool isPomodoro = m_timer->mode() == FocusTimer::PomodoroMode;
        const QString task = m_timer->currentTaskTitle();

        int shownSeconds;
        QString timePrefix;
        if (isPomodoro && m_timer->targetSeconds() > 0) {
            // 番茄工作/休息段是倒计时。
            shownSeconds = m_timer->remainingSeconds();
            timePrefix = isBreak ? QStringLiteral("剩余休息：") : QStringLiteral("剩余：");
        } else {
            // 自由计时是正计时，没有目标时长。
            shownSeconds = m_timer->elapsedSeconds();
            timePrefix = QStringLiteral("已专注：");
        }

        const QString clock = formatClock(shownSeconds);
        // 暂停时标题加暂停符号，休息与专注在菜单状态行区分。
        next.title = running ? clock : (QStringLiteral("⏸ ") + clock);
        next.taskLine = task.isEmpty() ? QStringLiteral("未选择任务")
                                       : (QStringLiteral("当前任务：") + task);
        next.stateLine = QStringLiteral("状态：")
            + (!running ? QStringLiteral("已暂停")
                        : isBreak ? QStringLiteral("休息中") : QStringLiteral("专注中"));
        next.timeLine = timePrefix + clock;
        next.canPause = running;
        next.canResume = !running;
        next.canStop = true;
    }

    if (next == m_display) {
        return;
    }
    m_display = next;
    if (m_view) {
        m_view->updateDisplay(m_display);
    }
    emit displayChanged();
}

void TrayController::requestPause()
{
    m_timer->pauseFocus();
}

void TrayController::requestResume()
{
    m_timer->resumeFocus();
}

void TrayController::requestStop()
{
    m_timer->stopFocus();
}

void TrayController::requestShowWindow()
{
    emit showWindowRequested();
}

void TrayController::requestQuit()
{
    emit quitRequested();
}
