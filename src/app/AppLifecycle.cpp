#include "AppLifecycle.h"

#include "services/BackupService.h"
#include "services/DatabaseManager.h"
#include "services/FocusTimer.h"
#include "services/PendingDeletion.h"
#include "services/SyncController.h"

#include <QDebug>

AppLifecycle::AppLifecycle(QObject* parent)
    : QObject(parent)
{
}

void AppLifecycle::setPreShutdownHook(std::function<void()> hook)
{
    m_preShutdownHook = std::move(hook);
}

void AppLifecycle::setFlushDraftsHook(std::function<void()> hook)
{
    m_flushDraftsHook = std::move(hook);
}

void AppLifecycle::setPendingDeletion(PendingDeletion* pendingDeletion)
{
    m_pendingDeletion = pendingDeletion;
}

void AppLifecycle::setSyncController(SyncController* syncController)
{
    m_syncController = syncController;
}

std::vector<AppLifecycle::ShutdownStep> AppLifecycle::shutdownSteps() const
{
    // 名称与实际动作共用同一份有序定义，防止测试锁定了名称而真实退出顺序已经漂移。
    // 草稿和待删项先触库，计时器再落盘；备份收尾、同步写出都必须在关库之前完成。
    std::vector<ShutdownStep> steps;
    if (m_preShutdownHook) {
        steps.push_back({QStringLiteral("preShutdown"), m_preShutdownHook});
    }
    if (m_flushDraftsHook) {
        steps.push_back({QStringLiteral("flushDrafts"), m_flushDraftsHook});
    }
    steps.push_back({QStringLiteral("commitPendingDeletion"), [this] {
        if (m_pendingDeletion && !m_pendingDeletion->commit()) {
            qWarning() << "退出时提交待删项失败，该项保留在库里";
        }
    }});
    steps.push_back({QStringLiteral("focusTimer"), [] {
        FocusTimer::instance()->prepareForShutdown();
    }});
    steps.push_back({QStringLiteral("backup"), [] {
        BackupService::instance()->prepareForShutdown();
    }});
    steps.push_back({QStringLiteral("sync"), [this] {
        if (m_syncController) {
            m_syncController->shutdown(3000);
        }
    }});
    steps.push_back({QStringLiteral("databaseClose"), [] {
        DatabaseManager::instance()->close();
    }});
    return steps;
}

QStringList AppLifecycle::shutdownStepNames() const
{
    QStringList names;
    for (const auto& step : shutdownSteps()) {
        names.append(step.name);
    }
    return names;
}

void AppLifecycle::shutdown()
{
    for (const auto& step : shutdownSteps()) {
        step.execute();
    }
}

void AppLifecycle::handleApplicationStateChanged(Qt::ApplicationState state)
{
    // 非活动状态（切后台、失焦锁屏、下拉控制中心）时先保存草稿，
    // 确保随后同步线程从数据库或服务队列中读到最新输入。
    if (state != Qt::ApplicationActive) {
        if (m_flushDraftsHook) {
            m_flushDraftsHook();
        }
    }

    // 对所有状态均通知同步控制器（包括回到 Active 恢复前台同步节奏）。
    if (m_syncController) {
        m_syncController->setApplicationState(state);
    }
}
