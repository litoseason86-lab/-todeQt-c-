#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QUrl>

#include "services/DatabaseManager.h"
#include "services/AppSettings.h"
#include "services/BackupService.h"
#include "services/CategoryManager.h"
#include "services/CountdownService.h"
#include "services/GoalService.h"
#include "services/ExportService.h"
#include "services/FocusHistoryService.h"
#include "services/FocusTimer.h"
#include "services/LogicalDayService.h"
#include "services/NotificationService.h"
#include "services/PhaseSoundService.h"
#include "services/RoutineManager.h"
#include "services/StatisticsService.h"
#include "services/TaskManager.h"
#include "services/TrayController.h"
#include "services/SingleInstanceGuard.h"

#include "platform/macos/MacNotificationBackend.h"
#include "platform/macos/MacStatusBarController.h"

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

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodo"));
    QCoreApplication::setApplicationName(QStringLiteral("PomodoroTodo"));
    // 关于页直接读取 Qt.application.version；由 CMake 项目版本注入，避免 UI 手写两份版本号。
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));

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

    if (!DatabaseManager::instance()->initialize()) {
        return -1;
    }
    // v8 历史回填与新版本自然到点规则口径不同；只在本次启动原本就有数据库且
    // 用户尚未确认时注入说明上下文。这里不查询历史会话，也不参与 schema 判断。
    const bool naturalCompletionNoticeRequired =
        DatabaseManager::instance()->openedExistingDatabase()
        && !AppSettings::instance()->naturalCompletionNoticeShown();

    if (!FocusTimer::instance()->restoreInterruptedSession()) {
        qWarning() << "活动专注会话恢复失败";
    }
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     FocusTimer::instance(), &FocusTimer::prepareForShutdown);
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     BackupService::instance(), &BackupService::prepareForShutdown);
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     DatabaseManager::instance(), &DatabaseManager::close);

    // 关闭主窗口时隐藏到菜单栏而不退出：菜单栏计时器让应用在无可见窗口时仍需存活。
    app.setQuitOnLastWindowClosed(false);

    // 菜单栏与系统通知：平台无关的 TrayController/NotificationService 负责逻辑，
    // macOS 后端负责 NSStatusItem 与 UNUserNotificationCenter。全部在 app 之后创建，
    // 生命周期与 main 同长；showWindow/quit 意图交给 QML 落实（复用窗口与待删提交逻辑）。
    TrayController trayController(FocusTimer::instance());
    QObject::connect(&instanceGuard, &SingleInstanceGuard::activationRequested,
                     &trayController, &TrayController::requestShowWindow);
    MacStatusBarController statusBar(&trayController);
    trayController.setView(&statusBar);

    MacNotificationBackend notificationBackend;
    NotificationService::instance()->setBackend(&notificationBackend);
    NotificationService::instance()->requestAuthorization();

    // 启动即生成今天的例行任务，保证 QML 首次读取今日任务时已经能看到它们。
    RoutineManager::instance()->materializeToday();

    // 失效信号同步派发时先补新逻辑日例行，再由后接入的 QML 视图重查。
    // 连接必须早于 engine.load，否则视图槽可能先看到尚未补齐的数据。
    QObject::connect(LogicalDayService::instance(), &LogicalDayService::changed,
                     RoutineManager::instance(), &RoutineManager::materializeToday);

    // 长期目标的里程碑判定必须在 C++ 侧完成：目标页大概率没打开，甚至可能正处在专注沉浸态，
    // 放到 QML 里比较前后进度必然漏触发。这里接在专注结束之后重算，跨页面都能拿到庆祝信号。
    //
    // focusCompleted 在“已保存”和“时长不足被丢弃”两个分支都会发，
    // 但 refreshMilestones 是幂等的（只按当前进度补位掩码），无效会话不会产生任何副作用。
    //
    // 连接写在这里而不是 GoalService 构造函数里，是为了不让目标服务反向依赖 FocusTimer；
    // 与上面 LogicalDayService → RoutineManager 是同一种装配方式。
    QObject::connect(FocusTimer::instance(), &FocusTimer::focusCompleted,
                     GoalService::instance(), &GoalService::refreshMilestones);

    QQmlApplicationEngine engine;
    // QML 通过单例上下文对象访问服务，视图层保持声明式和轻量。
    engine.rootContext()->setContextProperty(QStringLiteral("categoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("CategoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("exportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("ExportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskManager"), TaskManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusTimer"), FocusTimer::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("statisticsService"), StatisticsService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusHistoryService"), FocusHistoryService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("countdownService"), CountdownService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("goalService"), GoalService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("routineManager"), RoutineManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("appSettings"), AppSettings::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("logicalDayService"), LogicalDayService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("phaseSoundService"), PhaseSoundService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("trayController"), &trayController);
    engine.rootContext()->setContextProperty(QStringLiteral("notificationService"), NotificationService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("backupService"), BackupService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("naturalCompletionNoticeRequired"),
                                             naturalCompletionNoticeRequired);

    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
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
    // 平台后端是 main 栈对象；事件循环结束后先清空非拥有指针，再进入局部对象析构。
    NotificationService::instance()->setBackend(nullptr);
    return exitCode;
}
