#include <QTest>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QMap>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSet>
#include <QTemporaryDir>
#include <QSettings>

#include "app/SharedApp.h"
#include "models/PlainTextLayout.h"
#include "qmlfacade/QmlFacade.h"
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
#include "services/LocalSyncFolder.h"
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
#include "mcp/common/McpPaths.h"

namespace {
// 隔离的同步平台装配，使用本地临时目录，防止测试触及真实用户云盘
SyncController::Platform makeTestPlatform(const QString& folder)
{
    SyncController::Platform platform;
    platform.makeFolder = [folder](const QByteArray&, std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<LocalSyncFolder>(folder));
    };
    platform.fixedFolderDisplayPath = QStringLiteral("测试云盘/番茄Todo同步");
    platform.engine.mayCreateFolder = true;
    platform.engine.runInBackground = false;
    platform.engine.tickMs = 3600000;
    platform.engine.publishIntervalMs = 3600000;
    return platform;
}
} // namespace

class QmlFacadeTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();

    void macContextPropertiesMatchExpected();
    void iosContextPropertiesMatchExpected();
    void bundledFontsRegistrationDoesNotCrash();

private:
    std::unique_ptr<QTemporaryDir> m_tempDir;
    QString m_oldConfigPath;
};

void QmlFacadeTests::initTestCase()
{
    m_tempDir = std::make_unique<QTemporaryDir>();
    QVERIFY(m_tempDir->isValid());
    m_oldConfigPath = qgetenv("XDG_CONFIG_HOME");
    qputenv("XDG_CONFIG_HOME", m_tempDir->path().toUtf8());
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_tempDir->path());
    McpPaths::applyApplicationIdentity();
}

void QmlFacadeTests::cleanupTestCase()
{
    if (m_oldConfigPath.isEmpty()) {
        qunsetenv("XDG_CONFIG_HOME");
    } else {
        qputenv("XDG_CONFIG_HOME", m_oldConfigPath.toUtf8());
    }
}

void QmlFacadeTests::macContextPropertiesMatchExpected()
{
    // 保证 Mac 环境下 QmlFacade::install 正确安装全部 27 个共用属性和 1 个平台附加属性 mcpAccessController，且对象指针及类型准确、排除 iOS 专属属性。
    const QString dbPath = m_tempDir->filePath(QStringLiteral("mac_qml_facade.db"));
    SharedApp::Options options;
    options.databasePath = dbPath;
    options.enableOfflineRecovery = false;
    options.allowManualRest = true;
    options.monitorApplicationActivity = false;
    options.enablePhaseAlarms = false;

    SharedApp sharedApp(options);
    QVERIFY(sharedApp.openDatabase());
    sharedApp.restoreSession();
    sharedApp.setUpSync(makeTestPlatform(m_tempDir->filePath(QStringLiteral("mac_sync"))));
    sharedApp.setUpNotifications(nullptr);
    sharedApp.createInteractionServices();

    QQmlApplicationEngine engine;
    QObject dummyMcpAccess;
    QmlFacade::Extras extras;
    extras.mcpAccessController = &dummyMcpAccess;

    const QStringList installed = QmlFacade::install(engine, sharedApp.services(), extras);

    const QStringList expectedMac = {
        QStringLiteral("categoryManager"),
        QStringLiteral("CategoryManager"),
        QStringLiteral("exportService"),
        QStringLiteral("ExportService"),
        QStringLiteral("taskManager"),
        QStringLiteral("taskInteractionCoordinator"),
        QStringLiteral("pendingDeletion"),
        QStringLiteral("focusTimer"),
        QStringLiteral("focusSessionController"),
        QStringLiteral("statisticsService"),
        QStringLiteral("focusHistoryService"),
        QStringLiteral("countdownService"),
        QStringLiteral("memoService"),
        QStringLiteral("trashService"),
        QStringLiteral("memoTextLayout"),
        QStringLiteral("knowledgeGapService"),
        QStringLiteral("routineManager"),
        QStringLiteral("scheduleService"),
        QStringLiteral("appSettings"),
        QStringLiteral("logicalDayService"),
        QStringLiteral("phaseSoundService"),
        QStringLiteral("trayController"),
        QStringLiteral("notificationService"),
        QStringLiteral("backupService"),
        QStringLiteral("shortcutRegistry"),
        QStringLiteral("syncController"),
        QStringLiteral("naturalCompletionNoticeRequired"),
        QStringLiteral("mcpAccessController")
    };

    QCOMPARE(installed.size(), 28);
    QCOMPARE(QSet<QString>(installed.begin(), installed.end()),
             QSet<QString>(expectedMac.begin(), expectedMac.end()));

    // 1. 单独校验布尔值属性 naturalCompletionNoticeRequired
    const QVariant noticeProp = engine.rootContext()->contextProperty(QStringLiteral("naturalCompletionNoticeRequired"));
    QVERIFY2(noticeProp.isValid(), "缺少 naturalCompletionNoticeRequired 属性");
    QCOMPARE(noticeProp.typeId(), QMetaType::Bool);
    QCOMPARE(noticeProp.toBool(), false);

    // 2. 校验 memoTextLayout 类型与合理所有权（engine 为父对象）
    const QVariant memoProp = engine.rootContext()->contextProperty(QStringLiteral("memoTextLayout"));
    QVERIFY2(memoProp.isValid(), "缺少 memoTextLayout 属性");
    auto* memoTextLayout = qobject_cast<PlainTextLayout*>(memoProp.value<QObject*>());
    QVERIFY2(memoTextLayout != nullptr, "memoTextLayout 必须是 PlainTextLayout 类型实例");
    QCOMPARE(memoTextLayout->parent(), &engine);

    // 3. 校验各 QObject* 属性非空及对象身份严格匹配
    const QMap<QString, QObject*> expectedObjects = {
        {QStringLiteral("categoryManager"), CategoryManager::instance()},
        {QStringLiteral("CategoryManager"), CategoryManager::instance()},
        {QStringLiteral("exportService"), ExportService::instance()},
        {QStringLiteral("ExportService"), ExportService::instance()},
        {QStringLiteral("taskManager"), TaskManager::instance()},
        {QStringLiteral("taskInteractionCoordinator"), sharedApp.services().taskInteractionCoordinator()},
        {QStringLiteral("pendingDeletion"), sharedApp.services().pendingDeletion()},
        {QStringLiteral("focusTimer"), FocusTimer::instance()},
        {QStringLiteral("focusSessionController"), sharedApp.services().focusSessionController()},
        {QStringLiteral("statisticsService"), StatisticsService::instance()},
        {QStringLiteral("focusHistoryService"), FocusHistoryService::instance()},
        {QStringLiteral("countdownService"), CountdownService::instance()},
        {QStringLiteral("memoService"), MemoService::instance()},
        {QStringLiteral("trashService"), TrashService::instance()},
        {QStringLiteral("knowledgeGapService"), KnowledgeGapService::instance()},
        {QStringLiteral("routineManager"), RoutineManager::instance()},
        {QStringLiteral("scheduleService"), ScheduleService::instance()},
        {QStringLiteral("appSettings"), AppSettings::instance()},
        {QStringLiteral("logicalDayService"), LogicalDayService::instance()},
        {QStringLiteral("phaseSoundService"), PhaseSoundService::instance()},
        {QStringLiteral("trayController"), sharedApp.services().trayController()},
        {QStringLiteral("notificationService"), NotificationService::instance()},
        {QStringLiteral("backupService"), BackupService::instance()},
        {QStringLiteral("shortcutRegistry"), ShortcutRegistry::instance()},
        {QStringLiteral("syncController"), sharedApp.services().syncController()},
        {QStringLiteral("mcpAccessController"), &dummyMcpAccess}
    };

    for (auto it = expectedObjects.cbegin(); it != expectedObjects.cend(); ++it) {
        const QString& propName = it.key();
        QObject* expectedObj = it.value();
        QVERIFY2(expectedObj != nullptr, qPrintable(QStringLiteral("期望对象未创建: ") + propName));
        const QVariant prop = engine.rootContext()->contextProperty(propName);
        QVERIFY2(prop.isValid(), qPrintable(QStringLiteral("Mac 缺少属性值: ") + propName));
        QObject* actualObj = prop.value<QObject*>();
        QVERIFY2(actualObj != nullptr, qPrintable(QStringLiteral("Mac 属性对象为空: ") + propName));
        QCOMPARE(actualObj, expectedObj);
    }

    // 4. 平台互斥属性不存在
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("ipadUiPreferences")).isValid());
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("phaseAlarmCoordinator")).isValid());

    sharedApp.cleanup();
    DatabaseManager::instance()->close();
}

void QmlFacadeTests::iosContextPropertiesMatchExpected()
{
    // 保证 iOS 环境下 QmlFacade::install 正确安装全部 27 个共用属性和 2 个平台附加属性 ipadUiPreferences 与 phaseAlarmCoordinator，且对象身份及类型准确、排除 Mac 专属属性。
    const QString dbPath = m_tempDir->filePath(QStringLiteral("ios_qml_facade.db"));
    SharedApp::Options options;
    options.databasePath = dbPath;
    options.enableOfflineRecovery = true;
    options.allowManualRest = false;
    options.monitorApplicationActivity = true;
    options.enablePhaseAlarms = true;

    SharedApp sharedApp(options);
    QVERIFY(sharedApp.openDatabase());
    sharedApp.restoreSession();
    sharedApp.setUpSync(makeTestPlatform(m_tempDir->filePath(QStringLiteral("ios_sync"))));
    sharedApp.setUpNotifications(nullptr);
    sharedApp.createInteractionServices();

    QQmlApplicationEngine engine;
    QObject dummyIpadUiPreferences;
    QmlFacade::Extras extras;
    extras.ipadUiPreferences = &dummyIpadUiPreferences;
    extras.phaseAlarmCoordinator = sharedApp.services().phaseAlarmCoordinator();

    const QStringList installed = QmlFacade::install(engine, sharedApp.services(), extras);

    const QStringList expectedIos = {
        QStringLiteral("categoryManager"),
        QStringLiteral("CategoryManager"),
        QStringLiteral("exportService"),
        QStringLiteral("ExportService"),
        QStringLiteral("taskManager"),
        QStringLiteral("taskInteractionCoordinator"),
        QStringLiteral("pendingDeletion"),
        QStringLiteral("focusTimer"),
        QStringLiteral("focusSessionController"),
        QStringLiteral("statisticsService"),
        QStringLiteral("focusHistoryService"),
        QStringLiteral("countdownService"),
        QStringLiteral("memoService"),
        QStringLiteral("trashService"),
        QStringLiteral("memoTextLayout"),
        QStringLiteral("knowledgeGapService"),
        QStringLiteral("routineManager"),
        QStringLiteral("scheduleService"),
        QStringLiteral("appSettings"),
        QStringLiteral("logicalDayService"),
        QStringLiteral("phaseSoundService"),
        QStringLiteral("trayController"),
        QStringLiteral("notificationService"),
        QStringLiteral("backupService"),
        QStringLiteral("shortcutRegistry"),
        QStringLiteral("syncController"),
        QStringLiteral("naturalCompletionNoticeRequired"),
        QStringLiteral("ipadUiPreferences"),
        QStringLiteral("phaseAlarmCoordinator")
    };

    QCOMPARE(installed.size(), 29);
    QCOMPARE(QSet<QString>(installed.begin(), installed.end()),
             QSet<QString>(expectedIos.begin(), expectedIos.end()));

    // 1. 单独校验布尔值属性 naturalCompletionNoticeRequired
    const QVariant noticeProp = engine.rootContext()->contextProperty(QStringLiteral("naturalCompletionNoticeRequired"));
    QVERIFY2(noticeProp.isValid(), "缺少 naturalCompletionNoticeRequired 属性");
    QCOMPARE(noticeProp.typeId(), QMetaType::Bool);
    QCOMPARE(noticeProp.toBool(), sharedApp.services().naturalCompletionNoticeRequired());

    // 2. 校验 memoTextLayout 类型与合理所有权（engine 为父对象）
    const QVariant memoProp = engine.rootContext()->contextProperty(QStringLiteral("memoTextLayout"));
    QVERIFY2(memoProp.isValid(), "缺少 memoTextLayout 属性");
    auto* memoTextLayout = qobject_cast<PlainTextLayout*>(memoProp.value<QObject*>());
    QVERIFY2(memoTextLayout != nullptr, "memoTextLayout 必须是 PlainTextLayout 类型实例");
    QCOMPARE(memoTextLayout->parent(), &engine);

    // 3. 校验各 QObject* 属性非空及对象身份严格匹配
    const QMap<QString, QObject*> expectedObjects = {
        {QStringLiteral("categoryManager"), CategoryManager::instance()},
        {QStringLiteral("CategoryManager"), CategoryManager::instance()},
        {QStringLiteral("exportService"), ExportService::instance()},
        {QStringLiteral("ExportService"), ExportService::instance()},
        {QStringLiteral("taskManager"), TaskManager::instance()},
        {QStringLiteral("taskInteractionCoordinator"), sharedApp.services().taskInteractionCoordinator()},
        {QStringLiteral("pendingDeletion"), sharedApp.services().pendingDeletion()},
        {QStringLiteral("focusTimer"), FocusTimer::instance()},
        {QStringLiteral("focusSessionController"), sharedApp.services().focusSessionController()},
        {QStringLiteral("statisticsService"), StatisticsService::instance()},
        {QStringLiteral("focusHistoryService"), FocusHistoryService::instance()},
        {QStringLiteral("countdownService"), CountdownService::instance()},
        {QStringLiteral("memoService"), MemoService::instance()},
        {QStringLiteral("trashService"), TrashService::instance()},
        {QStringLiteral("knowledgeGapService"), KnowledgeGapService::instance()},
        {QStringLiteral("routineManager"), RoutineManager::instance()},
        {QStringLiteral("scheduleService"), ScheduleService::instance()},
        {QStringLiteral("appSettings"), AppSettings::instance()},
        {QStringLiteral("logicalDayService"), LogicalDayService::instance()},
        {QStringLiteral("phaseSoundService"), PhaseSoundService::instance()},
        {QStringLiteral("trayController"), sharedApp.services().trayController()},
        {QStringLiteral("notificationService"), NotificationService::instance()},
        {QStringLiteral("backupService"), BackupService::instance()},
        {QStringLiteral("shortcutRegistry"), ShortcutRegistry::instance()},
        {QStringLiteral("syncController"), sharedApp.services().syncController()},
        {QStringLiteral("ipadUiPreferences"), &dummyIpadUiPreferences},
        {QStringLiteral("phaseAlarmCoordinator"), sharedApp.services().phaseAlarmCoordinator()}
    };

    for (auto it = expectedObjects.cbegin(); it != expectedObjects.cend(); ++it) {
        const QString& propName = it.key();
        QObject* expectedObj = it.value();
        QVERIFY2(expectedObj != nullptr, qPrintable(QStringLiteral("期望对象未创建: ") + propName));
        const QVariant prop = engine.rootContext()->contextProperty(propName);
        QVERIFY2(prop.isValid(), qPrintable(QStringLiteral("iOS 缺少属性值: ") + propName));
        QObject* actualObj = prop.value<QObject*>();
        QVERIFY2(actualObj != nullptr, qPrintable(QStringLiteral("iOS 属性对象为空: ") + propName));
        QCOMPARE(actualObj, expectedObj);
    }

    // 4. 平台互斥属性不存在
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("mcpAccessController")).isValid());

    sharedApp.cleanup();
    DatabaseManager::instance()->close();
}

void QmlFacadeTests::bundledFontsRegistrationDoesNotCrash()
{
    // 保证打包字体注册流程可重复执行且不崩溃，且注册后所需字体族均可用。
    QmlFacade::registerBundledFonts();
    const QStringList firstFamilies = QFontDatabase::families();
    QVERIFY2(firstFamilies.contains(QStringLiteral("Space Grotesk")),
             "首次注册后缺少 Space Grotesk 字体族");
    QVERIFY2(firstFamilies.contains(QStringLiteral("Bricolage Grotesque")),
             "首次注册后缺少 Bricolage Grotesque 字体族");

    // 再次调用以验证幂等性与可重复执行性
    QmlFacade::registerBundledFonts();
    const QStringList secondFamilies = QFontDatabase::families();
    QVERIFY2(secondFamilies.contains(QStringLiteral("Space Grotesk")),
             "重复注册后缺少 Space Grotesk 字体族");
    QVERIFY2(secondFamilies.contains(QStringLiteral("Bricolage Grotesque")),
             "重复注册后缺少 Bricolage Grotesque 字体族");
}

QTEST_MAIN(QmlFacadeTests)
#include "QmlFacadeTests.moc"
