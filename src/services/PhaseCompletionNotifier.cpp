#include "PhaseCompletionNotifier.h"

#include "AppSettings.h"
#include "FocusTimer.h"
#include "NotificationService.h"

PhaseCompletionNotifier::PhaseCompletionNotifier(FocusTimer* timer, AppSettings* settings,
                                                 NotificationService* notifications, ChimePlayer playChime,
                                                 QObject* parent)
    : QObject(parent)
    , m_timer(timer)
    , m_settings(settings)
    , m_notifications(notifications)
    , m_playChime(std::move(playChime))
{
    // 启动时恢复的会话可能正处在休息段，构造时先记一次，免得这段休息结束时按「普通休息」说。
    captureActiveBreakKind();
    if (m_timer) {
        connect(m_timer, &FocusTimer::phaseChanged, this, &PhaseCompletionNotifier::captureActiveBreakKind);
        connect(m_timer, &FocusTimer::phaseCompleted, this, &PhaseCompletionNotifier::handlePhaseCompleted);
    }
    if (m_notifications) {
        // 只有「投递失败」要求本地兜底；业务主动抑制（预约已覆盖）不会发这个信号，也就不会重复响铃。
        connect(m_notifications, &NotificationService::notificationDeliveryFailed, this,
                [this](const QString&) { playFallbackChime(); });
    }
}

void PhaseCompletionNotifier::captureActiveBreakKind()
{
    // 只在进入休息段时记；离开休息段（回到空闲）时保留，等完成信号用完再清。
    if (!m_timer || !m_settings || m_timer->phase() != FocusTimer::BreakPhase) {
        return;
    }
    m_activeBreakWasLong = m_settings->breakTargetIsLong(m_timer->targetSeconds());
}

void PhaseCompletionNotifier::handlePhaseCompleted(int phase)
{
    if (!m_timer || !m_settings) {
        return;
    }
    // 工作段完成：连续数此时已经计入这个番茄，按「完成后」的数判断下一段是不是长休息。
    const bool isLongBreak = phase == FocusTimer::WorkPhase
        ? m_settings->longBreakDueAfter(m_timer->completedPomodoros())
        : m_activeBreakWasLong;
    int breakMinutes = 0;
    if (phase == FocusTimer::WorkPhase) {
        breakMinutes = isLongBreak ? m_settings->longBreakMinutes() : m_settings->breakMinutes();
    }
    if (m_notifications) {
        m_notifications->notifyPhaseComplete(phase, m_timer->completedPomodoros(), breakMinutes, isLongBreak,
                                             m_settings->soundEnabled());
    } else {
        playFallbackChime();
    }
    if (phase == FocusTimer::BreakPhase) {
        m_activeBreakWasLong = false;
    }
}

void PhaseCompletionNotifier::playFallbackChime()
{
    if (m_settings && m_settings->soundEnabled() && m_playChime) {
        m_playChime();
    }
}
