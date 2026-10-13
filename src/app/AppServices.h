#ifndef APPSERVICES_H
#define APPSERVICES_H

class SharedApp;
class TaskInteractionCoordinator;
class PendingDeletion;
class FocusSessionController;
class SyncController;
class TrayController;
class PhaseCompletionNotifier;
class PhaseAlarmCoordinator;

// 提供对 SharedApp 内部持有的非单例核心服务对象的类型化访问。
// 避免外部直接持有局部裸指针或依赖动态字符串查表。
class AppServices
{
public:
    explicit AppServices(SharedApp& app);

    TaskInteractionCoordinator* taskInteractionCoordinator() const;
    PendingDeletion* pendingDeletion() const;
    FocusSessionController* focusSessionController() const;
    SyncController* syncController() const;
    TrayController* trayController() const;
    PhaseCompletionNotifier* phaseCompletionNotifier() const;
    PhaseAlarmCoordinator* phaseAlarmCoordinator() const;

    bool naturalCompletionNoticeRequired() const;

private:
    SharedApp& m_app;
};

#endif // APPSERVICES_H
