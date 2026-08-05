#include <QDate>
#include <QFile>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QUuid>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/NotificationService.h"
#include "../src/services/SingleInstanceGuard.h"
#include "../src/services/TaskManager.h"
#include "../src/services/TrayController.h"

namespace {

// macOS 上 QLocalServer 的名字长度上限会随 Qt 版本变化：Qt 6.9 只能接受 46 字符，
// 原测试的 53 字符名字在 Qt 6.11 能过、在 6.9 必然失败。短后缀保留并行测试所需的唯一性，
// 同时避免两个用例因复用固定端点而互相 removeServer。
QString uniqueShortServerName()
{
    return QStringLiteral("pt-%1").arg(
        QUuid::createUuid().toString(QUuid::Id128).left(8));
}

// 假菜单栏视图：只记录最近一次推送的展示状态与推送次数。
class FakeTrayView : public TrayView
{
public:
    TrayDisplay last;
    int updateCount = 0;

    void updateDisplay(const TrayDisplay& display) override
    {
        last = display;
        ++updateCount;
    }
};

// 假通知后端：可切换授权态，记录投递内容与次数。
class FakeNotificationBackend : public NotificationBackend
{
public:
    bool authorized = true;
    int deliveredCount = 0;
    QString lastTitle;
    QString lastBody;
    bool lastPlaySound = true;
    int authRequests = 0;

    void deliver(const QString& title,
                 const QString& body,
                 bool playSound,
                 DeliveryCallback callback) override
    {
        if (!authorized) {
            callback(false, QStringLiteral("测试后端未授权"));
            return;
        }
        lastTitle = title;
        lastBody = body;
        lastPlaySound = playSound;
        ++deliveredCount;
        callback(true, QString());
    }

    bool isAuthorized() const override { return authorized; }
    void requestAuthorization() override { ++authRequests; }
};

int insertTaskRow(const QString& title)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed) VALUES (:title, :date, 0)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), QDate::currentDate().toString(Qt::ISODate));
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

} // namespace

class PlatformControlTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void idleDisplayHasNoControls();
    void startingFocusDrivesMenuState();
    void menuActionsForwardToTimer();
    void menuStopRequestsConfirmationForLongFreeFocus();
    void pausedStateOffersResumeAndKeepsTiming();
    void breakStateIsDistinguished();
    void showAndQuitEmitIntentSignals();
    void repeatedLaunchRequestsExistingWindow();
    void unavailableInstanceLockFailsClosed();
    void restoredSessionIsReflectedInMenu();

    void phaseCompleteWorkNotificationDeliversOnce();
    void phaseCompleteBreakDistinguishesLongBreak();
    void silentNotificationReachesBackendWithoutSound();
    void unauthorizedNotificationFallsBack();
    void missingBackendReportsFailure();
    void freePhaseSendsNoNotification();

private:
    QTemporaryDir* m_tempDir = nullptr;
};

void PlatformControlTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("tray.sqlite")));
}

void PlatformControlTests::cleanup()
{
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void PlatformControlTests::idleDisplayHasNoControls()
{
    TrayController controller(FocusTimer::instance());
    FakeTrayView view;
    controller.setView(&view);

    const TrayDisplay display = controller.display();
    QCOMPARE(display.title, QString());
    QVERIFY(!display.canPause);
    QVERIFY(!display.canResume);
    QVERIFY(!display.canStop);
    QVERIFY(display.stateLine.contains(QStringLiteral("空闲")));
    // setView 后立即推送一次当前状态。
    QCOMPARE(view.updateCount, 1);
}

void PlatformControlTests::startingFocusDrivesMenuState()
{
    TrayController controller(FocusTimer::instance());
    FakeTrayView view;
    controller.setView(&view);

    const int taskId = insertTaskRow(QStringLiteral("英语阅读"));
    QVERIFY(taskId > 0);
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("英语阅读"), 25 * 60));

    const TrayDisplay display = controller.display();
    QVERIFY(display.canPause);
    QVERIFY(display.canStop);
    QVERIFY(!display.canResume);
    QVERIFY(display.taskLine.contains(QStringLiteral("英语阅读")));
    QVERIFY(display.stateLine.contains(QStringLiteral("专注中")));
    // 菜单栏标题就是剩余时间的即时格式化，与计时器同源。
    QCOMPARE(display.title, QStringLiteral("25:00"));
    // 状态从空闲变为专注，视图收到额外推送。
    QVERIFY(view.updateCount >= 2);
}

void PlatformControlTests::menuActionsForwardToTimer()
{
    TrayController controller(FocusTimer::instance());

    const int taskId = insertTaskRow(QStringLiteral("专注任务"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("专注任务"), 25 * 60));
    QVERIFY(FocusTimer::instance()->isRunning());

    controller.requestPause();
    QVERIFY(!FocusTimer::instance()->isRunning());

    controller.requestResume();
    QVERIFY(FocusTimer::instance()->isRunning());

    controller.requestStop();
    QVERIFY(!FocusTimer::instance()->hasActiveSession());
    QCOMPARE(FocusTimer::instance()->phase(), int(FocusTimer::NoPhase));
}

void PlatformControlTests::menuStopRequestsConfirmationForLongFreeFocus()
{
    TrayController controller(FocusTimer::instance());
    const int taskId = insertTaskRow(QStringLiteral("超长自由计时"));
    QVERIFY(taskId > 0);
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("超长自由计时")));

    const int thresholdHours = AppSettings::instance()->freeTimerWarningHours();
    FocusTimer::instance()->m_accumulatedMilliseconds =
        static_cast<qint64>(thresholdHours * 60 * 60 + 1) * 1000;
    // 固定累计值，不让真实时钟在断言之间继续增长；本用例只验证菜单动作路由。
    FocusTimer::instance()->m_runSegmentStartNsecs = -1;

    QSignalSpy showSpy(&controller, &TrayController::showWindowRequested);
    QSignalSpy confirmationSpy(&controller, &TrayController::longFreeFocusStopRequested);
    controller.requestStop();

    QCOMPARE(showSpy.count(), 1);
    QCOMPARE(confirmationSpy.count(), 1);
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), true);
}

void PlatformControlTests::pausedStateOffersResumeAndKeepsTiming()
{
    TrayController controller(FocusTimer::instance());
    FakeTrayView view;
    controller.setView(&view);

    const int taskId = insertTaskRow(QStringLiteral("会被暂停的任务"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("会被暂停的任务"), 25 * 60));
    controller.requestPause();

    const TrayDisplay display = controller.display();
    QVERIFY(display.canResume);
    QVERIFY(!display.canPause);
    QVERIFY(display.canStop);
    QVERIFY(display.stateLine.contains(QStringLiteral("已暂停")));
    QVERIFY(display.title.contains(QStringLiteral("⏸")));
    // 隐藏窗口/暂停都不会结束会话：计时状态仍然存在。
    QVERIFY(FocusTimer::instance()->hasActiveSession());
}

void PlatformControlTests::breakStateIsDistinguished()
{
    TrayController controller(FocusTimer::instance());

    QVERIFY(FocusTimer::instance()->startBreak(5 * 60));
    const TrayDisplay display = controller.display();
    QVERIFY(display.stateLine.contains(QStringLiteral("休息中")));
    QVERIFY(display.canStop);
}

void PlatformControlTests::showAndQuitEmitIntentSignals()
{
    TrayController controller(FocusTimer::instance());
    QSignalSpy showSpy(&controller, &TrayController::showWindowRequested);
    QSignalSpy quitSpy(&controller, &TrayController::quitRequested);

    controller.requestShowWindow();
    controller.requestQuit();

    QCOMPARE(showSpy.count(), 1);
    QCOMPARE(quitSpy.count(), 1);
}

void PlatformControlTests::repeatedLaunchRequestsExistingWindow()
{
    const QString lockPath = m_tempDir->filePath(QStringLiteral("instance.lock"));
    const QString serverName = uniqueShortServerName();

    SingleInstanceGuard primary(lockPath, serverName);
    QCOMPARE(primary.start(), SingleInstanceGuard::PrimaryInstance);
    QSignalSpy activationSpy(&primary, &SingleInstanceGuard::activationRequested);

    SingleInstanceGuard secondary(lockPath, serverName);
    QCOMPARE(secondary.start(), SingleInstanceGuard::SecondaryInstanceNotified);
    QTRY_COMPARE_WITH_TIMEOUT(activationSpy.count(), 1, 1000);
}

void PlatformControlTests::unavailableInstanceLockFailsClosed()
{
    // 把“父目录”造成普通文件，QLockFile 必然无法创建锁文件。
    // 这与锁被另一个进程占用不同：应用无法证明单实例，必须关闭失败。
    const QString blockedParent = m_tempDir->filePath(QStringLiteral("not-a-directory"));
    QFile blocker(blockedParent);
    QVERIFY(blocker.open(QIODevice::WriteOnly));
    QVERIFY(blocker.write("blocked") > 0);
    blocker.close();

    SingleInstanceGuard guard(
        blockedParent + QStringLiteral("/instance.lock"),
        uniqueShortServerName());
    QCOMPARE(guard.start(), SingleInstanceGuard::LockUnavailable);
}

void PlatformControlTests::restoredSessionIsReflectedInMenu()
{
    TrayController controller(FocusTimer::instance());

    const int taskId = insertTaskRow(QStringLiteral("崩溃前任务"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("崩溃前任务"), 25 * 60));

    // 模拟异常退出并重建：恢复后计时器会发信号，菜单栏据此刷新为暂停态。
    FocusTimer::instance()->prepareForShutdown();
    FocusTimer::instance()->resetSession();
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());

    const TrayDisplay display = controller.display();
    QVERIFY(display.taskLine.contains(QStringLiteral("崩溃前任务")));
    QVERIFY(display.canResume);
    QVERIFY(display.canStop);
    QVERIFY(display.stateLine.contains(QStringLiteral("已暂停")));
}

void PlatformControlTests::phaseCompleteWorkNotificationDeliversOnce()
{
    NotificationService service;
    FakeNotificationBackend backend;
    service.setBackend(&backend);

    QSignalSpy deliveredSpy(&service, &NotificationService::notificationDelivered);

    service.notifyPhaseComplete(FocusTimer::WorkPhase, 3, 5, false, true);
    QCOMPARE(backend.deliveredCount, 1);
    QCOMPARE(deliveredSpy.count(), 1);
    QCOMPARE(backend.lastTitle, QStringLiteral("专注完成"));
    QVERIFY(backend.lastBody.contains(QStringLiteral("第 3 个番茄")));
    QVERIFY(backend.lastBody.contains(QStringLiteral("5 分钟")));
}

void PlatformControlTests::phaseCompleteBreakDistinguishesLongBreak()
{
    NotificationService service;
    FakeNotificationBackend backend;
    service.setBackend(&backend);

    service.notifyPhaseComplete(FocusTimer::BreakPhase, 0, 0, false, true);
    QCOMPARE(backend.lastTitle, QStringLiteral("休息结束"));

    service.notifyPhaseComplete(FocusTimer::BreakPhase, 0, 0, true, true);
    QCOMPARE(backend.lastTitle, QStringLiteral("长休息结束"));
    QCOMPARE(backend.deliveredCount, 2);
}

void PlatformControlTests::silentNotificationReachesBackendWithoutSound()
{
    NotificationService service;
    FakeNotificationBackend backend;
    service.setBackend(&backend);

    service.notifyPhaseComplete(FocusTimer::WorkPhase, 4, 15, true, false);
    QCOMPARE(backend.deliveredCount, 1);
    QCOMPARE(backend.lastPlaySound, false);
    QVERIFY(backend.lastBody.contains(QStringLiteral("15 分钟")));
}

void PlatformControlTests::unauthorizedNotificationFallsBack()
{
    NotificationService service;
    FakeNotificationBackend backend;
    backend.authorized = false;
    service.setBackend(&backend);

    QSignalSpy suppressedSpy(&service, &NotificationService::notificationSuppressed);

    service.notifyPhaseComplete(FocusTimer::WorkPhase, 1, 5, false, true);
    // 权限不可用：异步失败信号要求调用方走提示音降级，且不崩溃。
    QCOMPARE(backend.deliveredCount, 0);
    QCOMPARE(suppressedSpy.count(), 1);
}

void PlatformControlTests::missingBackendReportsFailure()
{
    NotificationService service; // 未注入后端
    QSignalSpy suppressedSpy(&service, &NotificationService::notificationSuppressed);

    service.notify(QStringLiteral("标题"), QStringLiteral("正文"));
    QVERIFY(!service.isAuthorized());
    QCOMPARE(suppressedSpy.count(), 1);
}

void PlatformControlTests::freePhaseSendsNoNotification()
{
    NotificationService service;
    FakeNotificationBackend backend;
    service.setBackend(&backend);

    // 无相位（自由计时）不发系统通知，避免通知轰炸。
    service.notifyPhaseComplete(FocusTimer::NoPhase, 0, 0, false, true);
    QCOMPARE(backend.deliveredCount, 0);
}

QTEST_MAIN(PlatformControlTests)
#include "PlatformControlTests.moc"
