#include "AppServices.h"
#include "SharedApp.h"

AppServices::AppServices(SharedApp& app)
    : m_app(app)
{
}

TaskInteractionCoordinator* AppServices::taskInteractionCoordinator() const
{
    return m_app.taskInteractionCoordinator();
}

PendingDeletion* AppServices::pendingDeletion() const
{
    return m_app.pendingDeletion();
}

FocusSessionController* AppServices::focusSessionController() const
{
    return m_app.focusSessionController();
}

SyncController* AppServices::syncController() const
{
    return m_app.syncController();
}

TrayController* AppServices::trayController() const
{
    return m_app.trayController();
}

PhaseCompletionNotifier* AppServices::phaseCompletionNotifier() const
{
    return m_app.phaseCompletionNotifier();
}

PhaseAlarmCoordinator* AppServices::phaseAlarmCoordinator() const
{
    return m_app.phaseAlarmCoordinator();
}

bool AppServices::naturalCompletionNoticeRequired() const
{
    return m_app.naturalCompletionNoticeRequired();
}
