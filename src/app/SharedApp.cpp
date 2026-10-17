#include "SharedApp.h"

#include "services/ApplicationActivity.h"
#include "services/AppSettings.h"
#include "services/BackupService.h"
#include "services/DatabaseManager.h"
#include "services/FocusHistoryService.h"
#include "services/FocusSessionController.h"
#include "services/FocusTimer.h"
#include "services/KnowledgeGapService.h"
#include "services/LogicalDayService.h"
#include "services/MonotonicClock.h"
#include "services/NotificationService.h"
#include "services/PendingDeletion.h"
#include "services/PhaseAlarmCoordinator.h"
#include "services/PhaseCompletionNotifier.h"
#include "services/PhaseSoundService.h"
#include "services/RoutineManager.h"
#include "services/TaskInteractionCoordinator.h"
#include "services/TaskManager.h"
#include "services/TrashService.h"
#include "services/TrayController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>

SharedApp::SharedApp(QObject* parent)
    : SharedApp(Options{}, parent)
{
}

SharedApp::SharedApp(Options options, QObject* parent)
    : QObject(parent)
    , m_options(std::move(options))
    , m_lifecycle(this)
    , m_services(*this)
{
}

SharedApp::~SharedApp()
{
    cleanup();
}

bool SharedApp::openDatabase(QString* errorMessage)
{
    // 防呆：若组织名为空，说明入口尚未正确调用 McpPaths::applyApplicationIdentity()。
    // 这会导致 QSettings 用错偏好域，或者按平台规则创建出错误的数据库目录，必须拒绝打开。
    if (QCoreApplication::organizationName().isEmpty()) {
        const QString err = QStringLiteral("应用组织名为空，必须在打开数据库前设置应用身份");
        if (errorMessage) {
            *errorMessage = err;
        }
        qCritical() << err;
        return false;
    }

    const bool ok = DatabaseManager::instance()->initialize(m_options.databasePath);
    if (!ok) {
        const QString err = QStringLiteral("数据库初始化失败");
        if (errorMessage) {
            *errorMessage = err;
        }
        qCritical() << err;
        return false;
    }

    initializeRuntimeServices();

    m_naturalCompletionNoticeRequired =
        DatabaseManager::instance()->openedExistingDatabase()
        && !AppSettings::instance()->naturalCompletionNoticeShown();
    return true;
}

void SharedApp::initializeRuntimeServices()
{
    if (m_runtimeServicesInitialized) {
        return;
    }
    m_runtimeServicesInitialized = true;

    // 菜单栏控制器属于平台无关层，生命周期由 SharedApp 持有；必须在数据库成功打开后创建。
    m_trayController = std::make_unique<TrayController>(FocusTimer::instance());

    // 移动端/iOS 恢复策略与应用活动监控（必须早于专注会话恢复与前后台处理建立）。
    if (m_options.enableOfflineRecovery) {
        FocusTimer::instance()->setRecoveryPolicy(FocusTimer::RecoveryPolicy::CatchUpOffline);
    }
    FocusTimer::instance()->setManualRestAllowed(m_options.allowManualRest);

    if (m_options.monitorApplicationActivity) {
        m_applicationActivity = std::make_unique<GuiApplicationActivity>(SystemMonotonicClock::instance());
        FocusTimer::instance()->setApplicationActivity(m_applicationActivity.get());
        connect(m_applicationActivity.get(), &GuiApplicationActivity::leftForeground,
                FocusTimer::instance(), &FocusTimer::checkpoint);
    }
}

void SharedApp::restoreSession()
{
    if (!FocusTimer::instance()->restoreInterruptedSession()) {
        qWarning() << "活动专注会话恢复失败";
    }

    m_taskInteractions = std::make_unique<TaskInteractionCoordinator>(TaskManager::instance());
}

void SharedApp::setUpSync(SyncController::Platform platform)
{
    m_syncController = std::make_unique<SyncController>(std::move(platform));

    // 换库或首轮加入前先做安全备份。
    m_syncController->setSafetyBackup([](QString* error) {
        return BackupService::instance()->backupBeforeSyncReplace(error);
    });

    const QPointer<SyncController> controller = m_syncController.get();
    BackupService::instance()->setRestorePreparationCallback([controller](QString* error) {
        if (!controller) {
            if (error) {
                *error = QStringLiteral("同步控制器已失效，无法准备恢复");
            }
            return false;
        }
        return controller->prepareForRestore(error);
    });

    connect(BackupService::instance(), &BackupService::restoreSyncCompleted,
            m_syncController.get(), [this](bool success, bool safeToResume) {
        if (m_syncController) {
            m_syncController->finishRestore(success, safeToResume);
        }
    });

    m_lifecycle.setSyncController(m_syncController.get());
}

void SharedApp::setUpNotifications(NotificationBackend* backend)
{
    NotificationService::instance()->setBackend(backend);

    if (m_options.enablePhaseAlarms) {
        m_phaseAlarms = std::make_unique<PhaseAlarmCoordinator>(
            FocusTimer::instance(), NotificationService::instance());
        NotificationService::instance()->setPhaseAlarmCoverage([this](int phase) {
            return m_phaseAlarms ? m_phaseAlarms->coversPhase(phase) : false;
        });
    }

    NotificationService::instance()->requestAuthorization();

    m_phaseCompletion = std::make_unique<PhaseCompletionNotifier>(
        FocusTimer::instance(), AppSettings::instance(),
        NotificationService::instance(),
        [] { return PhaseSoundService::instance()->playPhaseCompleteChime(); });

    if (m_options.enablePhaseAlarms && m_phaseAlarms) {
        m_phaseAlarms->start();
    }
}

void SharedApp::startDay()
{
    if (m_syncController) {
        m_syncController->initialize();
    }

    RoutineManager::instance()->materializeToday();
    // 规则写入、科目转发和同步发布都汇入这里；排队等写操作完整返回，避免在其信号栈里重入生成事务。
    connect(RoutineManager::instance(), &RoutineManager::routinesChanged,
            this, &SharedApp::materializeTodayAndNotify, Qt::QueuedConnection);
    connect(LogicalDayService::instance(), &LogicalDayService::changed,
            this, &SharedApp::materializeTodayAndNotify);
    // 换库或恢复后重新检查当天规则，任务通知由生成结果决定，不依赖页面信号接收的先后顺序。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &SharedApp::materializeTodayAndNotify);

    auto* backup = BackupService::instance();
    connect(backup, &BackupService::restoreStarted, this, [this] {
        m_restoreMaintenanceBlocked = true;
    });
    connect(backup, &BackupService::restoreSyncCompleted, this, [this](bool success, bool safeToResume) {
        // 只接受已准入恢复的内部结果；UI 的拒绝通知可能属于另一次请求，不能解除当前保护。
        m_restoreMaintenanceBlocked = !success && !safeToResume;
        purgeTrashIfReady();
    });
    purgeTrashIfReady();
    connect(LogicalDayService::instance(), &LogicalDayService::changed,
            this, &SharedApp::purgeTrashIfReady);
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &SharedApp::purgeTrashIfReady);

    connect(FocusHistoryService::instance(), &FocusHistoryService::historyChanged,
            this, [] { emit TaskManager::instance()->tasksChanged(); });

    connect(KnowledgeGapService::instance(), &KnowledgeGapService::tasksAffected,
            this, [] { emit TaskManager::instance()->tasksChanged(); });
}

void SharedApp::materializeTodayAndNotify()
{
    // 生成服务只写库，共享装配层负责把新增任务通知到两端页面。生成零条不发信号，
    // 避免 Mac 页面刷新时再次生成，形成“刷新 → 生成 → 通知 → 刷新”的循环。
    if (RoutineManager::instance()->materializeToday() > 0) {
        emit TaskManager::instance()->tasksChanged();
    }
}

void SharedApp::purgeTrashIfReady()
{
    // 进程重启后没有 restoreStarted 信号，必须同时遵守持久化恢复日志的保护状态。
    if (!m_restoreMaintenanceBlocked
        && (!m_syncController || !m_syncController->isRestoreStateUncertain())) {
        TrashService::instance()->purgeExpired();
    }
}

void SharedApp::createInteractionServices()
{
    m_pendingDeletion = std::make_unique<PendingDeletion>(
        TaskManager::instance(), FocusHistoryService::instance());
    m_focusSessionController = std::make_unique<FocusSessionController>(
        FocusTimer::instance(), TaskManager::instance(),
        AppSettings::instance(), m_pendingDeletion.get());

    m_lifecycle.setPendingDeletion(m_pendingDeletion.get());
}

void SharedApp::connectClipboard()
{
    if (m_syncController) {
        connect(m_syncController.get(), &SyncController::copyRequested, this, [](const QString& text) {
            QGuiApplication::clipboard()->setText(text);
        });
    }
}

void SharedApp::startBackgroundWork()
{
    BackupService::instance()->requestAutoBackupIfDue();
}

void SharedApp::cleanup()
{
    if (m_options.enablePhaseAlarms) {
        NotificationService::instance()->setPhaseAlarmCoverage({});
    }
    NotificationService::instance()->setBackend(nullptr);
    if (m_applicationActivity) {
        FocusTimer::instance()->setApplicationActivity(nullptr);
    }
}
