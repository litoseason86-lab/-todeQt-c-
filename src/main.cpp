#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>

#include "services/DatabaseManager.h"
#include "services/AppSettings.h"
#include "services/BackupService.h"
#include "services/CategoryManager.h"
#include "services/CountdownService.h"
#include "services/KnowledgeGapService.h"
#include "services/ExportService.h"
#include "services/FocusHistoryService.h"
#include "services/FocusTimer.h"
#include "services/LogicalDayService.h"
#include "services/NotificationService.h"
#include "services/PhaseSoundService.h"
#include "services/RoutineManager.h"
#include "services/ScheduleService.h"
#include "services/ShortcutRegistry.h"
#include "services/StatisticsService.h"
#include "services/SyncController.h"
#include "services/TaskManager.h"
#include "services/TrayController.h"

#include "mcp/common/McpPaths.h"
#include "services/TaskInteractionCoordinator.h"
#include "services/LogicalDay.h"

// 以下能力只在 macOS 存在：单实例守卫、外部 AI 接入、菜单栏、全局热键、系统通知后端。
// iOS 由系统保证单实例，也没有外部进程能连进来；这些源码在 iOS 构建里由 CMake 整体排除，
// 所以包含与装配都要一起圈在同一个平台条件里，漏一处就会在 iOS 上找不到头文件。
#if defined(Q_OS_MACOS)
#include "services/SingleInstanceGuard.h"
#include "mcp/bridge/McpAccessController.h"
#include <QClipboard>
#include "mcp/bridge/McpToolDispatcher.h"

#include "platform/macos/MacGlobalHotkeyBackend.h"
#include "platform/macos/MacPreferencesCleanup.h"
#include "platform/macos/MacStatusBarController.h"
#include "platform/macos/MacSyncFolder.h"
#endif

// 系统通知后端两个平台共用：UserNotifications 在 macOS 与 iOS 上是同一套接口。
#include "platform/apple/AppleNotificationBackend.h"

// iOS：计时恢复策略、前后台来源与系统预约通知。
#if defined(Q_OS_IOS)
#include <QScreen>
#include "services/ApplicationActivity.h"
#include "services/MonotonicClock.h"
#include "services/PhaseAlarmCoordinator.h"
#include "platform/ios/IosBackgroundTask.h"
#include "platform/ios/IosFolderPicker.h"
#include "platform/ios/IosSyncFolder.h"

namespace {
// 手机用随身伴侣页，平板用完整界面。启动时还没有窗口，只能按屏幕判定：
// 可用区域的短边小于 600pt 视为手机（横竖屏都一样）。iPad 的分屏与窗口模式里窗口可能更窄，
// 本期不在验证范围内，一律按屏幕走完整界面。
// 环境变量 POMODORO_TODO_LAYOUT=companion / full 可强制指定，便于在 iPad 上验证伴侣页。
bool useCompanionLayout()
{
    const QByteArray forced = qgetenv("POMODORO_TODO_LAYOUT");
    if (forced == "companion") {
        return true;
    }
    if (forced == "full") {
        return false;
    }
    const QScreen* screen = QGuiApplication::primaryScreen();
    if (!screen) {
        return false;
    }
    const QSize available = screen->availableGeometry().size();
    return qMin(available.width(), available.height()) < 600;
}
}
#endif

int main(int argc, char *argv[])
{
    // 固定运行时控件风格，避免平台原生控件差异影响布局和测试。
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QGuiApplication app(argc, argv);

    // 打包的数字字体：计时数字（Space Grotesk）与统计/倒计时数字（Bricolage）。
    // 注册失败仅告警、不阻断启动；字族解析不到时 Qt 会回退系统字，数字仍可读。
    const QStringList bundledFonts = {
        QStringLiteral(":/fonts/SpaceGrotesk-Light.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"),
        QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"),
    };
    for (const QString& fontPath : bundledFonts) {
        if (QFontDatabase::addApplicationFont(fontPath) == -1) {
            qWarning() << "字体注册失败，将回退系统字:" << fontPath;
        }
    }

    // 应用身份决定偏好域与 AppDataLocation。外部 AI 辅助程序要按同一组名字找接入目录，
    // 所以两个进程共用 McpPaths 里的定义，不各写一份字面量。
    McpPaths::applyApplicationIdentity();
    // 关于页直接读取 Qt.application.version；由 CMake 项目版本注入，避免 UI 手写两份版本号。
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));

#if defined(Q_OS_MACOS)
    // 偏好域清理和单实例锁只在 macOS 需要：iOS 的偏好存放在应用沙盒里，不会被钉进全局域；
    // 系统也保证同一应用只有一个进程，不存在两个进程争用同一数据库的问题。
    // 旧版恢复失败回滚时会把系统全局偏好（语言、地区等）钉进本应用的偏好域，
    // 之后改系统设置本应用也不跟着变。回滚已经改为只写本应用的键，这里把以前钉进来的清掉。
    // 只清与全局域值完全相同的键，读到的值不变，所以只需做一次，用迁移标记记住。
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

    // 单实例守卫：两个进程共享同一数据库时会互相覆盖 active_focus_state 检查点。
    // 重复启动不再静默退出，而是通过本地 IPC 召回现有窗口。
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
#endif

    if (!DatabaseManager::instance()->initialize()) {
        qCritical() << "数据库初始化失败，停止加载业务界面";
        // 失败窗口独立于所有业务服务，避免在坏库上继续触发查询或备份。
        // 离屏自动验证只写日志，不进入等待用户操作的界面事件循环。
        if (QGuiApplication::platformName() != QStringLiteral("offscreen")) {
            QQmlApplicationEngine failureEngine;
            // 用户第一步总是要找数据库和迁移快照在哪；这里直接把目录给出来，
            // 免得他们去猜 macOS 的 Application Support 路径。
            const QString defaultDbPath = DatabaseManager::defaultDatabasePath();
            failureEngine.setInitialProperties(
                {{QStringLiteral("dataDirectory"),
                  defaultDbPath.isEmpty() ? QString()
                                          : QFileInfo(defaultDbPath).absolutePath()}});
            failureEngine.load(QUrl(QStringLiteral("qrc:/qml/StartupErrorWindow.qml")));
            if (!failureEngine.rootObjects().isEmpty()) {
                app.exec();
            }
        }
        return -1;
    }
    // v8 历史回填与新版本自然到点规则口径不同；只在本次启动原本就有数据库且
    // 用户尚未确认时注入说明上下文。这里不查询历史会话，也不参与 schema 判断。
    const bool naturalCompletionNoticeRequired =
        DatabaseManager::instance()->openedExistingDatabase()
        && !AppSettings::instance()->naturalCompletionNoticeShown();

#if defined(Q_OS_IOS)
    // 必须在恢复之前设置：恢复逻辑按策略决定是否补回离线时段。
    // 移动端的进程常在后台被系统结束，并非用户想暂停，同一次开机内按单调时钟补算；
    // 番茄段在后台到期时只做离线结算（不自动衔接、不补发提醒）。
    FocusTimer::instance()->setRecoveryPolicy(FocusTimer::RecoveryPolicy::CatchUpOffline);
    // iPad 开放自由计时（用户的主要用法），被系统结束后同样按上面的策略补回离线时段。
    // 主动休息暂不开放：050 计划没有这个需求，入口隐藏、服务层拒绝。
    FocusTimer::instance()->setManualRestAllowed(false);
    GuiApplicationActivity applicationActivity(SystemMonotonicClock::instance());
    FocusTimer::instance()->setApplicationActivity(&applicationActivity);
    // 离开前台时补写一次检查点。锚点在开始、暂停、继续时已经落盘，这里只是让最后的进度更新鲜。
    QObject::connect(&applicationActivity, &GuiApplicationActivity::leftForeground,
                     FocusTimer::instance(), &FocusTimer::checkpoint);
#endif
    if (!FocusTimer::instance()->restoreInterruptedSession()) {
        qWarning() << "活动专注会话恢复失败";
    }
    // 任务交互协调器与平台无关（iOS 界面同样通过它串起完成、删除等交互），
    // 所以放在外部 AI 接入之前创建；接入层只是它的一个监听者。
    TaskInteractionCoordinator taskInteractions(TaskManager::instance());

#if defined(Q_OS_MACOS)
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
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     &mcpAccess, &McpAccessController::shutdown);
    McpToolDispatcher mcpDispatcher(TaskManager::instance(), CategoryManager::instance(),
        StatisticsService::instance(), KnowledgeGapService::instance(), &taskInteractions, [&mcpAccess] {
            return McpToolDispatcher::Context{mcpAccess.sessionId(), QDateTime::currentDateTime(),
                                              AppSettings::instance()->dayStartHour()};
        });
    QObject::connect(&mcpAccess, &McpAccessController::sessionChanged,
                     &mcpDispatcher, &McpToolDispatcher::resetCreationSession);
    mcpAccess.setDataHandler([&mcpDispatcher](McpContracts::Tool tool, const QJsonObject& arguments) {
        return mcpDispatcher.dispatch(tool, arguments);
    });
    mcpAccess.setBlockProvider([&mcpDispatcher] { return mcpDispatcher.blocks(); });
    QObject::connect(&taskInteractions, &TaskInteractionCoordinator::changed,
                     &mcpAccess, &McpAccessController::stateChanged);
    QObject::connect(&mcpAccess, &McpAccessController::copyRequested, &app, [](const QString& text) {
        QGuiApplication::clipboard()->setText(text);
    });
    mcpAccess.start();
#endif

    // 设备间同步（050）：Mac 与 iPad 的差别在这里注入，SyncController 与同步核心不做平台判断。
    // Mac 直接读写 iCloud 云盘里固定位置的「番茄Todo同步」，可以新建，常驻菜单栏所以后台照常同步；
    // iPad 要在「文件」里选文件夹、凭书签取得访问权，只在前台定时同步，切到后台时向系统要一点时间把改动写完。
    SyncController::Platform syncPlatform;
#if defined(Q_OS_MACOS)
    syncPlatform.makeFolder = [](const QByteArray&, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<MacSyncFolder>());
    };
    syncPlatform.fixedFolderDisplayPath = QStringLiteral("iCloud 云盘/番茄Todo同步");
    syncPlatform.engine.mayCreateFolder = true;
    syncPlatform.engine.runInBackground = true;
#elif defined(Q_OS_IOS)
    syncPlatform.makeFolder = [](const QByteArray& bookmark,
                                 std::function<void(const QByteArray&)> bookmarkRefreshed) {
        return std::unique_ptr<SyncFolder>(std::make_unique<IosSyncFolder>(bookmark, std::move(bookmarkRefreshed)));
    };
    syncPlatform.pickFolder = [](std::function<void(const QByteArray&, const QString&)> done) {
        presentSyncFolderPicker(std::move(done));
    };
    syncPlatform.backgroundTask = [] { return beginIosBackgroundTask(QStringLiteral("番茄Todo同步")); };
    syncPlatform.engine.mayCreateFolder = false;
    syncPlatform.engine.runInBackground = false;
#endif
    SyncController syncController(std::move(syncPlatform));
    // 第一次加入、另一台设备恢复了备份时，本机数据会被整体换掉：先做一份单独计数的自动备份，写成了才换。
    syncController.setSafetyBackup([](QString* error) {
        return BackupService::instance()->backupBeforeSyncReplace(error);
    });
    // 恢复备份 = 全局回滚：开始前停下同步并记下恢复前的纪元与设备标识，结束后开新纪元、给所有设备写全量快照。
    QObject::connect(BackupService::instance(), &BackupService::restoreStarted,
                     &syncController, &SyncController::prepareForRestore);
    QObject::connect(BackupService::instance(), &BackupService::restoreCompleted,
                     &syncController, [&syncController](bool success, const QString&) {
        syncController.finishRestore(success);
    });
#if defined(Q_OS_IOS)
    // 只有 iPad 接前后台：回到前台立即同步一轮，离开前台立即写出攒下的改动。
    // Mac 不接：切到别的应用很频繁，每次都立即写会拆出很多小文件，而 iPad 每读一个要约 1 秒。
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, &syncController,
                     [&syncController](Qt::ApplicationState state) {
        syncController.setForeground(state == Qt::ApplicationActive);
    });
#endif

    // 退出顺序：计时器先落盘（它结束的记录要随这次写出），备份的后台任务收尾，同步把攒下的改动写出去，最后关库。
    // 同一个信号的槽按连接先后调用，所以同步这一条必须连在 DatabaseManager::close 之前。
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     FocusTimer::instance(), &FocusTimer::prepareForShutdown);
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     BackupService::instance(), &BackupService::prepareForShutdown);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &syncController, [&syncController] {
        syncController.shutdown(3000);
    });
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     DatabaseManager::instance(), &DatabaseManager::close);

    // 关闭主窗口时隐藏到菜单栏而不退出：菜单栏计时器让应用在无可见窗口时仍需存活。
    app.setQuitOnLastWindowClosed(false);

    // 菜单栏与系统通知：平台无关的 TrayController/NotificationService 负责逻辑，
    // macOS 后端负责 NSStatusItem 与 UNUserNotificationCenter。全部在 app 之后创建，
    // 生命周期与 main 同长；showWindow/quit 意图交给 QML 落实（复用窗口与待删提交逻辑）。
    TrayController trayController(FocusTimer::instance());
#if defined(Q_OS_MACOS)
    QObject::connect(&instanceGuard, &SingleInstanceGuard::activationRequested,
                     &trayController, &TrayController::requestShowWindow);
    MacStatusBarController statusBar(&trayController);
    trayController.setView(&statusBar);

#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    AppleNotificationBackend notificationBackend;
    NotificationService::instance()->setBackend(&notificationBackend);
#endif
#if defined(Q_OS_IOS)
    // 番茄到点提醒交给系统预约：进程被挂起时进程内的计时器不会运行，只有预约的通知能按时响。
    // 预约成功时，到点那一刻进程内不再即时投递第二条（由协调器回答「是否已覆盖」）。
    PhaseAlarmCoordinator phaseAlarms(FocusTimer::instance(), NotificationService::instance());
    NotificationService::instance()->setPhaseAlarmCoverage([&phaseAlarms](int phase) {
        return phaseAlarms.coversPhase(phase);
    });
#endif
    NotificationService::instance()->requestAuthorization();
#if defined(Q_OS_IOS)
    // 恢复已经完成：先撤销上个进程遗留的预约，再按当前计时状态重新预约。
    phaseAlarms.start();
#endif

    // 快捷键：应用内键位由 QML 的 Shortcut 直接消费 ShortcutRegistry 的清单；
    // 全局热键交给 Carbon 后端向系统注册。后端是 main 的栈对象，事件循环结束后
    // 显式解绑（见函数末尾），不依赖栈上声明顺序来保证注销先于析构。
#if defined(Q_OS_MACOS)
    MacGlobalHotkeyBackend globalHotkeyBackend;
    ShortcutRegistry::instance()->setGlobalBackend(&globalHotkeyBackend);
#endif

    // 同步的启动核对放在生成例行之前：同步记下的逻辑日起点若和本机设置不一致，要先写回，
    // 「今天」是哪天才是对的。上次开着同步的话，这里接着开始（第一轮在事件循环里异步进行）。
    syncController.initialize();

    // 启动即生成今天的例行任务，保证 QML 首次读取今日任务时已经能看到它们。
    // 两个平台都生成：同一例行同一天的实例在所有设备上是同一条记录（身份 = 例行 sync_id + 日期），
    // 同步过来的不会再生成一份，见 RoutineManager::materializeToday。
    RoutineManager::instance()->materializeToday();

    // 失效信号同步派发时先补新逻辑日例行，再由后接入的 QML 视图重查。
    // 连接必须早于 engine.load，否则视图槽可能先看到尚未补齐的数据。
    QObject::connect(LogicalDayService::instance(), &LogicalDayService::changed,
                     RoutineManager::instance(), &RoutineManager::materializeToday);

    // 历史编辑会改变任务累计时长；在装配层广播刷新，避免服务互相依赖。
    QObject::connect(FocusHistoryService::instance(), &FocusHistoryService::historyChanged,
                     TaskManager::instance(), &TaskManager::tasksChanged);

    // 知识缺口转任务会往 tasks 里插一行。在装配层把它接到任务变更信号上，
    // 任务列表就能立刻刷新，而不必让 KnowledgeGapService 反向依赖 TaskManager。
    QObject::connect(KnowledgeGapService::instance(), &KnowledgeGapService::tasksAffected,
                     TaskManager::instance(), &TaskManager::tasksChanged);

    QQmlApplicationEngine engine;
    // QML 通过单例上下文对象访问服务，视图层保持声明式和轻量。
    engine.rootContext()->setContextProperty(QStringLiteral("categoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("CategoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("exportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("ExportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskManager"), TaskManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskInteractionCoordinator"), &taskInteractions);
#if defined(Q_OS_MACOS)
    engine.rootContext()->setContextProperty(QStringLiteral("mcpAccessController"), &mcpAccess);
#endif
    engine.rootContext()->setContextProperty(QStringLiteral("focusTimer"), FocusTimer::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("statisticsService"), StatisticsService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusHistoryService"), FocusHistoryService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("countdownService"), CountdownService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("knowledgeGapService"), KnowledgeGapService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("routineManager"), RoutineManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("scheduleService"), ScheduleService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("appSettings"), AppSettings::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("logicalDayService"), LogicalDayService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("phaseSoundService"), PhaseSoundService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("trayController"), &trayController);
    engine.rootContext()->setContextProperty(QStringLiteral("notificationService"), NotificationService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("backupService"), BackupService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("shortcutRegistry"), ShortcutRegistry::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("syncController"), &syncController);
#if defined(Q_OS_IOS)
    engine.rootContext()->setContextProperty(QStringLiteral("phaseAlarmCoordinator"), &phaseAlarms);
#endif
    engine.rootContext()->setContextProperty(QStringLiteral("naturalCompletionNoticeRequired"),
                                             naturalCompletionNoticeRequired);

#if defined(Q_OS_IOS)
    const QUrl url(useCompanionLayout() ? QStringLiteral("qrc:/qml/mobile/CompanionMain.qml")
                                        : QStringLiteral("qrc:/qml/main.qml"));
#else
    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
#endif
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *object, const QUrl &objectUrl) {
        if (!object && url == objectUrl) {
            QCoreApplication::exit(-1);
        }
    }, Qt::QueuedConnection);

    engine.load(url);
    // 自动备份放到后台线程。退出时不再重复执行重 I/O，避免应用长时间卡在关闭阶段。
    BackupService::instance()->requestAutoBackupIfDue();
    const int exitCode = app.exec();
#if defined(Q_OS_IOS)
    // 这些对象都是 main 的栈对象，事件循环结束后先解开单例对它们的引用，再进入析构。
    NotificationService::instance()->setPhaseAlarmCoverage({});
    NotificationService::instance()->setBackend(nullptr);
    FocusTimer::instance()->setApplicationActivity(nullptr);
#endif
#if defined(Q_OS_MACOS)
    // 平台后端是 main 栈对象；事件循环结束后先清空非拥有指针，再进入局部对象析构。
    NotificationService::instance()->setBackend(nullptr);
    // 同理：解绑会先把已注册的系统热键全部注销，避免进程退出后系统里残留热键登记。
    ShortcutRegistry::instance()->setGlobalBackend(nullptr);
    // 菜单栏与控制器互相持有裸指针，两个方向都要显式断开。此前正确性只靠
    // 「trayController 声明在 statusBar 之前所以析构更晚」这一条隐式约定支撑，
    // 而代码里没有任何地方写着这件事——挪一行声明就会变成悬垂指针。
    trayController.setView(nullptr);
    statusBar.detachController();
#endif
    return exitCode;
}
