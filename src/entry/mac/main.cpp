#include <QCoreApplication>
#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QSettings>
#include <QStandardPaths>
#include <QTimeZone>
#include <QUrl>

#include <memory>

#include "app/SharedApp.h"
#include "qmlfacade/QmlFacade.h"
#include "services/DatabaseManager.h"
#include "services/AppSettings.h"
#include "services/BackupService.h"
#include "services/CategoryManager.h"
#include "services/KnowledgeGapService.h"
#include "services/LogicalDay.h"
#include "services/ShortcutRegistry.h"
#include "services/StatisticsService.h"
#include "services/TaskManager.h"
#include "services/TaskInteractionCoordinator.h"
#include "services/TrayController.h"

#include "mcp/common/McpPaths.h"
#include "services/SingleInstanceGuard.h"
#include "mcp/bridge/McpAccessController.h"
#include "mcp/bridge/McpToolDispatcher.h"

#include "platform/macos/MacGlobalHotkeyBackend.h"
#include "platform/macos/MacBackupExecutor.h"
#include "platform/macos/MacPreferencesCleanup.h"
#include "platform/macos/MacStatusBarController.h"
#include "platform/macos/MacSyncFolder.h"
#include "platform/macos/SqliteRuntime.h"
#include "platform/apple/AppleNotificationBackend.h"

int main(int argc, char *argv[])
{
    // 1. 固定运行时控件风格，避免平台原生控件差异影响布局和测试。在创建 QGuiApplication 之前。
    QmlFacade::setupQuickStyle();

    // 2. 创建 QGuiApplication。
    QGuiApplication app(argc, argv);

    // 3. 注册打包字体。
    QmlFacade::registerBundledFonts();

    // 4. McpPaths::applyApplicationIdentity()，设置组织名与应用名。
    McpPaths::applyApplicationIdentity();

    // 5. 设置应用版本。
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));

    // 6. Mac：偏好域清理、单实例守卫。
    {
        const auto kPinnedPreferencesCleanupKey =
            QStringLiteral("migration/globalPreferencesUnpinned");
        QString preferencesDomain;
        {
            QSettings settings;
            if (!settings.value(kPinnedPreferencesCleanupKey).toBool()) {
                // 原生偏好的 fileName() 是 ~/Library/Preferences/<域名>.plist。
                preferencesDomain = QFileInfo(settings.fileName()).completeBaseName();
            }
        }
        if (!preferencesDomain.isEmpty()) {
            MacPreferencesCleanup::removeValuesPinnedFromGlobalDomain(preferencesDomain);
            QSettings settings;
            settings.setValue(kPinnedPreferencesCleanupKey, true);
        }
    }

    const QString instanceLockDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(instanceLockDir);
    SingleInstanceGuard instanceGuard(
        QDir(instanceLockDir).filePath(QStringLiteral("pomodoro-todo.lock")),
        QStringLiteral("com.zerionlito.PomodoroTodo"));
    const SingleInstanceGuard::StartResult instanceResult = instanceGuard.start();
    if (instanceResult == SingleInstanceGuard::SecondaryInstanceNotified) {
        return 0;
    }
    if (instanceResult == SingleInstanceGuard::SecondaryInstanceUnreachable) {
        qWarning() << "番茄Todo 已在运行，但无法召回现有窗口";
        return 0;
    }
    if (instanceResult == SingleInstanceGuard::LockUnavailable) {
        // 无法取得排他锁时继续运行就是故意放行多实例，数据库可写不能证明安全。
        qCritical() << "无法创建单实例锁，拒绝启动:" << instanceLockDir;
        return -1;
    }

    // 首个数据库连接前固定SQLite工厂；驱动缺失时阻断，避免退回内嵌运行时再破坏写锁。
    QString sqliteRuntimeError;
    const QString sqlitePluginPath = QDir(QCoreApplication::applicationDirPath()).filePath(
        QStringLiteral("../PlugIns/sqldrivers/libptqsqlite.dylib"));
    if (!MacSqliteRuntime::initialize(sqlitePluginPath, &sqliteRuntimeError)) {
        qCritical() << sqliteRuntimeError;
        return QmlFacade::showStartupErrorWindow(app, DatabaseManager::defaultDatabasePath());
    }

    // 备份后台文件操作与主进程隔离，退出时由 Mac 后端按停止和回收期限收尾。
    BackupService::instance()->setExecutor(std::make_shared<MacBackupExecutor>());

    // 7. 打开数据库。
    SharedApp::Options sharedAppOptions;
    sharedAppOptions.enableOfflineRecovery = false;
    sharedAppOptions.allowManualRest = true;
    sharedAppOptions.monitorApplicationActivity = false;
    sharedAppOptions.enablePhaseAlarms = false;
    SharedApp sharedApp(sharedAppOptions);

    if (!sharedApp.openDatabase()) {
        qCritical() << "数据库初始化失败，停止加载业务界面";
        return QmlFacade::showStartupErrorWindow(app, DatabaseManager::defaultDatabasePath());
    }

    sharedApp.restoreSession();

    // 显式装配接入生命周期；默认关闭，设置页显式授权后才启动端点。
    // 先于数据库关闭注册退出处理，避免队列在数据库关闭以后继续执行。
    QSettings mcpSettings;
    McpAccessController mcpAccess(McpPaths::resolveProduction(), mcpSettings, [] {
        const int dayStartHour = AppSettings::instance()->dayStartHour();
        return QJsonObject{{"app_version", QCoreApplication::applicationVersion()},
                           {"logical_today", LogicalDay::today(dayStartHour).toString(Qt::ISODate)},
                           {"time_zone", QString::fromUtf8(QTimeZone::systemTimeZoneId())},
                           {"day_start_hour", dayStartHour}};
    });
    QObject::connect(BackupService::instance(), &BackupService::restoreStarted,
                     &mcpAccess, &McpAccessController::beginRestore);
    QObject::connect(BackupService::instance(), &BackupService::operationBlocksUiChanged,
                     &mcpAccess, [&mcpAccess] {
        mcpAccess.setRestoreBlocked(BackupService::instance()->operationBlocksUi());
    });
    QObject::connect(BackupService::instance(), &BackupService::restoreCompleted,
                     &mcpAccess, [&mcpAccess](bool, const QString&) {
        // 同步恢复可能没有 operationBlocksUi 的状态变化，完成信号也必须释放阻断。
        mcpAccess.setRestoreBlocked(BackupService::instance()->operationBlocksUi());
    });
    sharedApp.lifecycle().setPreShutdownHook([&mcpAccess] {
        mcpAccess.shutdown();
    });
    McpToolDispatcher mcpDispatcher(TaskManager::instance(), CategoryManager::instance(),
        StatisticsService::instance(), KnowledgeGapService::instance(),
        sharedApp.services().taskInteractionCoordinator(), [&mcpAccess] {
            return McpToolDispatcher::Context{mcpAccess.sessionId(), QDateTime::currentDateTime(),
                                              AppSettings::instance()->dayStartHour()};
        });
    QObject::connect(&mcpAccess, &McpAccessController::sessionChanged,
                     &mcpDispatcher, &McpToolDispatcher::resetCreationSession);
    mcpAccess.setDataHandler([&mcpDispatcher](McpContracts::Tool tool, const QJsonObject& arguments) {
        return mcpDispatcher.dispatch(tool, arguments);
    });
    mcpAccess.setBlockProvider([&mcpDispatcher] { return mcpDispatcher.blocks(); });
    QObject::connect(sharedApp.services().taskInteractionCoordinator(), &TaskInteractionCoordinator::changed,
                     &mcpAccess, &McpAccessController::stateChanged);
    QObject::connect(&mcpAccess, &McpAccessController::copyRequested, &app, [](const QString& text) {
        QGuiApplication::clipboard()->setText(text);
    });
    mcpAccess.start();

    // 设备间同步（050）：Mac 与 iPad 的差别在这里注入，SyncController 与同步核心不做平台判断。
    // Mac 直接读写 iCloud 云盘里固定位置的「番茄Todo同步」，可以新建，常驻菜单栏所以后台照常同步。
    SyncController::Platform syncPlatform;
    syncPlatform.makeFolder = [](const QByteArray&, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<MacSyncFolder>());
    };
    syncPlatform.fixedFolderDisplayPath = QStringLiteral("iCloud 云盘/番茄Todo同步");
    syncPlatform.engine.mayCreateFolder = true;
    syncPlatform.engine.runInBackground = true;
    sharedApp.setUpSync(std::move(syncPlatform));

    // 关闭主窗口时隐藏到菜单栏而不退出：菜单栏计时器让应用在无可见窗口时仍需存活。
    app.setQuitOnLastWindowClosed(false);

    // 菜单栏与系统通知：平台无关的 TrayController/NotificationService 负责逻辑，
    // macOS 后端负责 NSStatusItem 与 UNUserNotificationCenter。全部在 app 之后创建，
    // 生命周期与 main 同长；showWindow/quit 意图交给 QML 落实（复用窗口与待删提交逻辑）。
    TrayController* trayController = sharedApp.services().trayController();
    QObject::connect(&instanceGuard, &SingleInstanceGuard::activationRequested,
                     trayController, &TrayController::requestShowWindow);
    MacStatusBarController statusBar(trayController);
    trayController->setView(&statusBar);

    AppleNotificationBackend notificationBackend;
    sharedApp.setUpNotifications(&notificationBackend);

    // 快捷键：应用内键位由 QML 的 Shortcut 直接消费 ShortcutRegistry 的清单；
    // 全局热键交给 Carbon 后端向系统注册。后端是 main 的栈对象，事件循环结束后
    // 显式解绑（见函数末尾），不依赖栈上声明顺序来保证注销先于析构。
    MacGlobalHotkeyBackend globalHotkeyBackend;
    ShortcutRegistry::instance()->setGlobalBackend(&globalHotkeyBackend);

    sharedApp.startDay();
    sharedApp.createInteractionServices();

    QQmlApplicationEngine engine;
    sharedApp.connectClipboard();

    // 草稿先同步保存，再结束计时、写同步、关库。
    sharedApp.lifecycle().setFlushDraftsHook([&engine] {
        if (!engine.rootObjects().isEmpty()) {
            QMetaObject::invokeMethod(engine.rootObjects().first(), "flushMemoEdits", Qt::DirectConnection);
        }
    });

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &sharedApp, [&sharedApp] {
        sharedApp.lifecycle().shutdown();
    });

    QmlFacade::Extras extras;
    extras.mcpAccessController = &mcpAccess;
    QmlFacade::install(engine, sharedApp.services(), extras);

    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *object, const QUrl &objectUrl) {
        if (!object && url == objectUrl) {
            QCoreApplication::exit(-1);
        }
    }, Qt::QueuedConnection);

    engine.load(url);

    // 自动备份放到后台线程。退出时不再重复执行重 I/O，避免应用长时间卡在关闭阶段。
    sharedApp.startBackgroundWork();
    const int exitCode = app.exec();

    sharedApp.cleanup();
    ShortcutRegistry::instance()->setGlobalBackend(nullptr);
    if (trayController) {
        trayController->setView(nullptr);
    }
    statusBar.detachController();

    return exitCode;
}
