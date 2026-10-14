#include <QTest>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSet>
#include <QTemporaryDir>
#include <QSettings>

#include "app/SharedApp.h"
#include "qmlfacade/QmlFacade.h"
#include "services/DatabaseManager.h"
#include "services/PhaseAlarmCoordinator.h"
#include "mcp/common/McpPaths.h"

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
    // 保证 Mac 环境下 QmlFacade::install 正确安装全部 27 个共用属性和 1 个平台附加属性 mcpAccessController，且不注册 iOS 专属属性。
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

    for (const QString& name : expectedMac) {
        const QVariant prop = engine.rootContext()->contextProperty(name);
        QVERIFY2(prop.isValid(), qPrintable(QStringLiteral("Mac 属性缺失有效值: ") + name));
    }

    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("ipadUiPreferences")).isValid());
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("phaseAlarmCoordinator")).isValid());

    sharedApp.cleanup();
    DatabaseManager::instance()->close();
}

void QmlFacadeTests::iosContextPropertiesMatchExpected()
{
    // 保证 iOS 环境下 QmlFacade::install 正确安装全部 27 个共用属性和 2 个平台附加属性 ipadUiPreferences 与 phaseAlarmCoordinator，且不注册 Mac 专属属性。
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

    for (const QString& name : expectedIos) {
        const QVariant prop = engine.rootContext()->contextProperty(name);
        QVERIFY2(prop.isValid(), qPrintable(QStringLiteral("iOS 属性缺失有效值: ") + name));
    }

    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("mcpAccessController")).isValid());

    sharedApp.cleanup();
    DatabaseManager::instance()->close();
}

void QmlFacadeTests::bundledFontsRegistrationDoesNotCrash()
{
    // 保证打包字体注册流程可重复执行且不崩溃。
    QmlFacade::registerBundledFonts();
}

QTEST_MAIN(QmlFacadeTests)
#include "QmlFacadeTests.moc"
