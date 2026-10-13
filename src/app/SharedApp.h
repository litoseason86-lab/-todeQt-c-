#ifndef SHAREDAPP_H
#define SHAREDAPP_H

#include <QObject>
#include <QString>

#include <memory>

#include "app/AppLifecycle.h"
#include "app/AppServices.h"
#include "services/SyncController.h"

class GuiApplicationActivity;
class TaskInteractionCoordinator;
class TrayController;
class PhaseAlarmCoordinator;
class PhaseCompletionNotifier;
class PendingDeletion;
class FocusSessionController;
class NotificationBackend;

// 跨平台共享装配与生命周期协调器。
// 负责在平台无关层逐句组织核心服务创建、信号跨层连线、退出与前后台调度；
// 不包含平台分支宏，平台差异均通过 Options 或参数注入。
class SharedApp : public QObject
{
    Q_OBJECT

public:
    struct Options
    {
        // 显式指定的数据库路径（若为空则使用 DatabaseManager::defaultDatabasePath()，测试隔离用）
        QString databasePath;
        // 是否启用离线时段补算策略（iOS 启用，Mac 关闭）
        bool enableOfflineRecovery = false;
        // 是否允许主动休息（iOS 禁用，Mac 允许）
        bool allowManualRest = true;
        // 是否创建 GuiApplicationActivity 监控应用前后台并补写检查点（iOS 启用）
        bool monitorApplicationActivity = false;
        // 是否启用 PhaseAlarmCoordinator 系统预约通知（iOS 启用）
        bool enablePhaseAlarms = false;
    };

    explicit SharedApp(Options options, QObject* parent = nullptr);
    explicit SharedApp(QObject* parent = nullptr);
    ~SharedApp() override;

    const Options& options() const { return m_options; }
    AppServices& services() { return m_services; }
    AppLifecycle& lifecycle() { return m_lifecycle; }

    // 1. 打开数据库。防呆：组织名为空时拒绝打开并给出原因。
    bool openDatabase(QString* errorMessage = nullptr);

    // 2. 恢复中断的专注会话，并创建 TaskInteractionCoordinator
    void restoreSession();

    // 3. 注入平台同步后端并装配同步控制器与安全备份
    void setUpSync(SyncController::Platform platform);

    // 4. 装配系统通知后端、预约通知与阶段完成通知
    void setUpNotifications(NotificationBackend* backend);

    // 5. 启动每日逻辑：同步核对、例行生成、废纸篓清理与跨服务信号接线
    void startDay();

    // 6. 创建界面交互服务（PendingDeletion, FocusSessionController），必须在界面加载前调用
    void createInteractionServices();

    // 7. 装配同步剪贴板连线（保持原有 SyncController::copyRequested -> QGuiApplication::clipboard()->setText）
    void connectClipboard();

    // 8. 触发后台自动备份
    void startBackgroundWork();

    // 9. 解绑事件循环中建立的单例弱引用（通知后端、预约覆盖、前后台监控）
    void cleanup();

    // 供 AppServices 访问内部对象
    TaskInteractionCoordinator* taskInteractionCoordinator() const { return m_taskInteractions.get(); }
    PendingDeletion* pendingDeletion() const { return m_pendingDeletion.get(); }
    FocusSessionController* focusSessionController() const { return m_focusSessionController.get(); }
    SyncController* syncController() const { return m_syncController.get(); }
    TrayController* trayController() const { return m_trayController.get(); }
    PhaseCompletionNotifier* phaseCompletionNotifier() const { return m_phaseCompletion.get(); }
    PhaseAlarmCoordinator* phaseAlarmCoordinator() const { return m_phaseAlarms.get(); }
    const GuiApplicationActivity* applicationActivity() const { return m_applicationActivity.get(); }
    bool naturalCompletionNoticeRequired() const { return m_naturalCompletionNoticeRequired; }

private:
    Options m_options;
    AppLifecycle m_lifecycle;
    AppServices m_services;

    std::unique_ptr<GuiApplicationActivity> m_applicationActivity;
    std::unique_ptr<TaskInteractionCoordinator> m_taskInteractions;
    std::unique_ptr<SyncController> m_syncController;
    std::unique_ptr<TrayController> m_trayController;
    std::unique_ptr<PhaseAlarmCoordinator> m_phaseAlarms;
    std::unique_ptr<PhaseCompletionNotifier> m_phaseCompletion;
    std::unique_ptr<PendingDeletion> m_pendingDeletion;
    std::unique_ptr<FocusSessionController> m_focusSessionController;
    bool m_naturalCompletionNoticeRequired = false;
};

#endif // SHAREDAPP_H
