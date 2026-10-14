#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QScreen>
#include <QSettings>
#include <QUrl>

#include "app/SharedApp.h"
#include "entry/ios/UiRouter.h"
#include "qmlfacade/QmlFacade.h"
#include "services/DatabaseManager.h"
#include "services/TaskInteractionCoordinator.h"
#include "services/PendingDeletion.h"
#include "services/FocusSessionController.h"
#include "services/PhaseAlarmCoordinator.h"
#include "services/SyncController.h"
#include "mcp/common/McpPaths.h"

#include "platform/ios/bridge/PTBridgeSupport.h"
#include "platform/ios/IosBackgroundTask.h"
#include "platform/ios/IosFolderPicker.h"
#include "platform/ios/IosSyncFolder.h"
#include "platform/ios/native/NativeRoot.h"
#include "platform/ios/native/IPadUiPreferences.h"
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

    // 6. （iOS 没有第 6 步）

    // 7. 打开数据库。
    SharedApp::Options sharedAppOptions;
    sharedAppOptions.enableOfflineRecovery = true;
    sharedAppOptions.allowManualRest = false;
    sharedAppOptions.monitorApplicationActivity = true;
    sharedAppOptions.enablePhaseAlarms = true;
    SharedApp sharedApp(sharedAppOptions);

    if (!sharedApp.openDatabase()) {
        qCritical() << "数据库初始化失败，停止加载业务界面";
        return QmlFacade::showStartupErrorWindow(app, DatabaseManager::defaultDatabasePath());
    }

    sharedApp.restoreSession();

    // 设备间同步（050）：iPad 在「文件」里选文件夹、凭书签取得访问权，只在前台定时同步，切到后台时向系统要一点时间把改动写完。
    SyncController::Platform syncPlatform;
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
    sharedApp.setUpSync(std::move(syncPlatform));

    app.setQuitOnLastWindowClosed(false);

    AppleNotificationBackend notificationBackend;
    sharedApp.setUpNotifications(&notificationBackend);

    sharedApp.startDay();
    sharedApp.createInteractionServices();

    QQmlApplicationEngine engine;
    sharedApp.connectClipboard();

    // 界面路由计算
    const bool isIpad = isIPadDevice();
    const QScreen* screen = QGuiApplication::primaryScreen();
    const int availableShortSide = screen ? qMin(screen->availableGeometry().width(), screen->availableGeometry().height()) : -1;
    const bool nativeUiPreference = QSettings().value(QStringLiteral("ipad/nativeUI"), true).toBool();

    const UiRoute route = UiRouter::route(
        isIpad,
        availableShortSide,
        QCoreApplication::arguments(),
        qgetenv("POMODORO_TODO_NATIVE_UI"),
        qgetenv("POMODORO_TODO_LAYOUT"),
        nativeUiPreference
    );
    const bool nativeRoot = (route == UiRoute::Native);

    // 草稿先同步保存，再结束计时、写同步、关库。原生路径没有 QML 根对象，调用它登记的保存钩子。
    sharedApp.lifecycle().setFlushDraftsHook([nativeRoot, &engine] {
        if (nativeRoot) {
            flushNativeEdits();
            return;
        }
        if (!engine.rootObjects().isEmpty()) {
            QMetaObject::invokeMethod(engine.rootObjects().first(), "flushMemoEdits", Qt::DirectConnection);
        }
    });

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &sharedApp, [&sharedApp] {
        sharedApp.lifecycle().shutdown();
    });

    // 只有 iPad 接前后台：回到前台立即同步一轮，进了后台立即写出攒下的改动。
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, &sharedApp,
                     [&sharedApp](Qt::ApplicationState state) {
        sharedApp.lifecycle().handleApplicationStateChanged(state);
    });

    IPadUiPreferences ipadUiPreferences(isIpad);
    QmlFacade::Extras extras;
    extras.ipadUiPreferences = &ipadUiPreferences;
    extras.phaseAlarmCoordinator = sharedApp.services().phaseAlarmCoordinator();
    QmlFacade::install(engine, sharedApp.services(), extras);

    const QUrl url(route == UiRoute::QmlCompanion ? QStringLiteral("qrc:/qml/mobile/CompanionMain.qml")
                                                  : QStringLiteral("qrc:/qml/main.qml"));

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *object, const QUrl &objectUrl) {
        if (!object && url == objectUrl) {
            QCoreApplication::exit(-1);
        }
    }, Qt::QueuedConnection);

    if (nativeRoot) {
        // 055-P3B：非单例仅登记弱引用，原生桥接不接管 main 栈服务的生命周期。
        PTBridgeSupport::registerService(QStringLiteral("pendingDeletion"),
                                         sharedApp.services().pendingDeletion());
        PTBridgeSupport::registerService(QStringLiteral("taskInteractions"),
                                         sharedApp.services().taskInteractionCoordinator());
        PTBridgeSupport::registerService(QStringLiteral("focusController"),
                                         sharedApp.services().focusSessionController());
        PTBridgeSupport::registerService(QStringLiteral("phaseAlarms"),
                                         sharedApp.services().phaseAlarmCoordinator());
        PTBridgeSupport::registerService(QStringLiteral("syncController"),
                                         sharedApp.services().syncController());
        installNativeRoot();
    } else {
        engine.load(url);
    }

    // 自动备份放到后台线程。退出时不再重复执行重 I/O，避免应用长时间卡在关闭阶段。
    sharedApp.startBackgroundWork();
    const int exitCode = app.exec();

    sharedApp.cleanup();
    return exitCode;
}
