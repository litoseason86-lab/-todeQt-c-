#ifndef APPLIFECYCLE_H
#define APPLIFECYCLE_H

#include <QObject>
#include <QStringList>
#include <QtGlobal>

#include <functional>
#include <vector>

class PendingDeletion;
class SyncController;

// 负责应用退出的有序步骤与前后台生命周期状态流转。
// 整个应用只由装配层连接一次 aboutToQuit 与 applicationStateChanged，由本类统筹调用，
// 避免跨层散落各种优先级难以预测的隐式槽函数。
class AppLifecycle : public QObject
{
    Q_OBJECT

public:
    explicit AppLifecycle(QObject* parent = nullptr);
    ~AppLifecycle() override = default;

    // 设置外部 AI 接入等平台专用的最优先关闭钩子（例如 macOS 的 McpAccessController::shutdown）
    void setPreShutdownHook(std::function<void()> hook);

    // 设置界面草稿持久化钩子（QML 根对象的 flushMemoEdits 或 iPad 原生的 flushNativeEdits）
    void setFlushDraftsHook(std::function<void()> hook);

    // 装配层设置由 SharedApp 持有的业务对象指针（弱引用，不接管生命周期）
    void setPendingDeletion(PendingDeletion* pendingDeletion);
    void setSyncController(SyncController* syncController);

    // 获取当前配置下的退出步骤名称列表（按调用先后排序，供测试锁定顺序）
    QStringList shutdownStepNames() const;

    // 执行退出全流程
    void shutdown();

    // 处理系统应用状态流转（iOS 由系统事件驱动；非 Active 保存草稿，所有状态均通知 SyncController）
    void handleApplicationStateChanged(Qt::ApplicationState state);

private:
    struct ShutdownStep {
        QString name;
        std::function<void()> execute;
    };
    std::vector<ShutdownStep> shutdownSteps() const;

    std::function<void()> m_preShutdownHook;
    std::function<void()> m_flushDraftsHook;
    PendingDeletion* m_pendingDeletion = nullptr;
    SyncController* m_syncController = nullptr;
};

#endif // APPLIFECYCLE_H
