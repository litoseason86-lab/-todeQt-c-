#include "qmlfacade/QmlFacade.h"

#include <QDebug>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>

#include "app/AppServices.h"
#include "models/PlainTextLayout.h"

#include "services/AppSettings.h"
#include "services/BackupService.h"
#include "services/CategoryManager.h"
#include "services/CountdownService.h"
#include "services/DatabaseManager.h"
#include "services/ExportService.h"
#include "services/FocusHistoryService.h"
#include "services/FocusSessionController.h"
#include "services/FocusTimer.h"
#include "services/KnowledgeGapService.h"
#include "services/LogicalDayService.h"
#include "services/MemoService.h"
#include "services/NotificationService.h"
#include "services/PendingDeletion.h"
#include "services/PhaseAlarmCoordinator.h"
#include "services/PhaseSoundService.h"
#include "services/RoutineManager.h"
#include "services/ScheduleService.h"
#include "services/ShortcutRegistry.h"
#include "services/StatisticsService.h"
#include "services/SyncController.h"
#include "services/TaskInteractionCoordinator.h"
#include "services/TaskManager.h"
#include "services/TrashService.h"
#include "services/TrayController.h"

void QmlFacade::setupQuickStyle()
{
    // 固定运行时控件风格，避免平台原生控件差异影响布局和测试。
    QQuickStyle::setStyle(QStringLiteral("Basic"));
}

void QmlFacade::registerBundledFonts()
{
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
}

int QmlFacade::showStartupErrorWindow(QGuiApplication& app, const QString& defaultDbPath)
{
    // 失败窗口独立于所有业务服务，避免在坏库上继续触发查询或备份。
    // 离屏自动验证只写日志，不进入等待用户操作的界面事件循环。
    if (QGuiApplication::platformName() == QStringLiteral("offscreen")) {
        return -1;
    }
    QQmlApplicationEngine failureEngine;
    // 用户第一步总是要找数据库和迁移快照在哪；这里直接把目录给出来，
    // 免得他们去猜 macOS 的 Application Support 路径。
    failureEngine.setInitialProperties(
        {{QStringLiteral("dataDirectory"),
          defaultDbPath.isEmpty() ? QString()
                                  : QFileInfo(defaultDbPath).absolutePath()}});
    failureEngine.load(QUrl(QStringLiteral("qrc:/qml/StartupErrorWindow.qml")));
    if (!failureEngine.rootObjects().isEmpty()) {
        app.exec();
    }
    return -1;
}

QStringList QmlFacade::install(QQmlApplicationEngine& engine,
                               const AppServices& services)
{
    return install(engine, services, Extras());
}

QStringList QmlFacade::install(QQmlApplicationEngine& engine,
                               const AppServices& services,
                               const Extras& extras)
{
    QStringList installed;
    auto* rootContext = engine.rootContext();

    auto registerProp = [&](const QString& name, QObject* object) {
        rootContext->setContextProperty(name, object);
        installed.append(name);
    };

    auto registerVariantProp = [&](const QString& name, const QVariant& value) {
        rootContext->setContextProperty(name, value);
        installed.append(name);
    };

    // 1. 共用 27 个上下文属性
    registerProp(QStringLiteral("categoryManager"), CategoryManager::instance());
    registerProp(QStringLiteral("CategoryManager"), CategoryManager::instance());
    registerProp(QStringLiteral("exportService"), ExportService::instance());
    registerProp(QStringLiteral("ExportService"), ExportService::instance());
    registerProp(QStringLiteral("taskManager"), TaskManager::instance());
    registerProp(QStringLiteral("taskInteractionCoordinator"), services.taskInteractionCoordinator());
    registerProp(QStringLiteral("pendingDeletion"), services.pendingDeletion());
    registerProp(QStringLiteral("focusTimer"), FocusTimer::instance());
    registerProp(QStringLiteral("focusSessionController"), services.focusSessionController());
    registerProp(QStringLiteral("statisticsService"), StatisticsService::instance());
    registerProp(QStringLiteral("focusHistoryService"), FocusHistoryService::instance());
    registerProp(QStringLiteral("countdownService"), CountdownService::instance());
    registerProp(QStringLiteral("memoService"), MemoService::instance());
    registerProp(QStringLiteral("trashService"), TrashService::instance());

    auto* memoTextLayout = new PlainTextLayout(&engine);
    registerProp(QStringLiteral("memoTextLayout"), memoTextLayout);

    registerProp(QStringLiteral("knowledgeGapService"), KnowledgeGapService::instance());
    registerProp(QStringLiteral("routineManager"), RoutineManager::instance());
    registerProp(QStringLiteral("scheduleService"), ScheduleService::instance());
    registerProp(QStringLiteral("appSettings"), AppSettings::instance());
    registerProp(QStringLiteral("logicalDayService"), LogicalDayService::instance());
    registerProp(QStringLiteral("phaseSoundService"), PhaseSoundService::instance());
    registerProp(QStringLiteral("trayController"), services.trayController());
    registerProp(QStringLiteral("notificationService"), NotificationService::instance());
    registerProp(QStringLiteral("backupService"), BackupService::instance());
    registerProp(QStringLiteral("shortcutRegistry"), ShortcutRegistry::instance());
    registerProp(QStringLiteral("syncController"), services.syncController());
    registerVariantProp(QStringLiteral("naturalCompletionNoticeRequired"),
                        services.naturalCompletionNoticeRequired());

    // 2. 平台附加属性
    if (extras.mcpAccessController) {
        registerProp(QStringLiteral("mcpAccessController"), extras.mcpAccessController);
    }
    if (extras.ipadUiPreferences) {
        registerProp(QStringLiteral("ipadUiPreferences"), extras.ipadUiPreferences);
    }
    if (extras.phaseAlarmCoordinator) {
        registerProp(QStringLiteral("phaseAlarmCoordinator"), extras.phaseAlarmCoordinator);
    }

    return installed;
}
