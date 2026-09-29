#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/ApplicationActivity.h"
#include "../src/services/DatabaseManager.h"
// FocusTimer 声明 friend class TimingRobustnessTests，测试可直接注入时钟并触发内部计时器。
#include "../src/services/FocusTimer.h"
#include "../src/services/MonotonicClock.h"

namespace {

// 可控单调时钟：手动推进纳秒，用来确定性地模拟“系统休眠期间流逝的时间”和时钟冻结，
// 无需真的让机器睡眠或真实等待。
class FakeMonotonicClock : public MonotonicClock
{
public:
    qint64 ns = 0;
    // 墙钟（UTC 毫秒）。正常流逝时与单调时钟同步前进；单独改它就等于「用户改了系统时间」。
    qint64 utcMs = 1700000000000LL;
    // 开机会话标识：改它就等于「中途重启过」，单调时钟读数不再可比。
    QString boot = QStringLiteral("boot-A");
    void advanceMs(qint64 ms) { ns += ms * 1000000; utcMs += ms; }
    void advanceSecs(qint64 s) { ns += s * 1000000000LL; utcMs += s * 1000; }
    qint64 nowNsecs() const override { return ns; }
    QString bootSessionId() const override { return boot; }
    qint64 utcNowMsecs() const override { return utcMs; }
};

// 可控的前后台状态：goBackground / comeForeground 模拟锁屏、切到别的应用、再回来。
// 回到前台的时刻取假时钟当前读数，与 FocusTimer 用同一个时间基准。
class FakeActivity : public ApplicationActivity
{
public:
    explicit FakeActivity(const FakeMonotonicClock* clock) : m_clock(clock) {}
    bool foreground = true;
    qint64 lastForeground = 0;
    void goBackground() { foreground = false; }
    void comeForeground()
    {
        foreground = true;
        lastForeground = m_clock->nowNsecs();
    }
    bool isForeground() const override { return foreground; }
    qint64 lastForegroundNsecs() const override { return lastForeground; }

private:
    const FakeMonotonicClock* m_clock;
};

int queryInt(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(sql) || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

int insertTask(const QString& title)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed) VALUES (:t, :d, 0)"));
    query.bindValue(QStringLiteral(":t"), title);
    query.bindValue(QStringLiteral(":d"), QDate::currentDate().toString(Qt::ISODate));
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

int countFocusSessions()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")) || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

} // namespace

class TimingRobustnessTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void normalRunTracksMonotonicClock();
    void pauseDoesNotConsumeTime();
    void sleepDuringRunCountsTowardElapsed();
    void sleepPastEndCompletesExactlyOnce();
    void manuallyStoppedPomodoroPreservesElapsedPastTarget();
    void freeModeCountsUpAcrossSleep();
    void elapsedIgnoresWallClockAdvance();
    void recoveryFreezesAtCheckpointNotOfflineTime();
    void recoveredOverdueSessionCompletesOnceOnResume();
    void breakSleepPastEndCompletesOnce();

    // iOS（CatchUpOffline 策略）：挂起返回与重启恢复走同一条离线结算路径。
    void suspendedAcrossExpirySettlesOnlyCurrentPhase();
    void tickBeforeForegroundEventStillSettlesOffline();
    void foregroundExpiryStaysNormalCompletion();
    void breakExpiredInBackgroundSettlesOffline();
    void killedAndRelaunchedAfterExpirySettlesOffline();
    void killedAndRelaunchedBeforeExpiryKeepsRunning();
    void relaunchAfterRebootRestoresPaused();
    void relaunchWithoutBootIdCatchesUpWhenClocksAgree();
    void rebootWithoutBootIdIsDetectedByClockDisagreement();
    void wallClockChangedWhileAwayRestoresPaused();
    void freeFocusIsCaughtUpAfterRelaunch();
    void freeFocusAfterRebootRestoresPaused();
    void manualRestIsNotCaughtUpAfterRelaunch();
    void shutdownOnCatchUpKeepsRunningAnchor();
    void pausePersistFailureKeepsRunningAndAnchor();
    void resumePersistFailureStaysPaused();
    void freeTimingDisallowedRejectsOnlyFreeFocus();
    void manualRestDisallowedRejectsOnlyManualRest();

private:
    void tick() { QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection)); }
    void useFakeClock() { FocusTimer::instance()->m_clock = &m_clock; }
    void useMobilePolicy()
    {
        FocusTimer::instance()->setRecoveryPolicy(FocusTimer::RecoveryPolicy::CatchUpOffline);
        FocusTimer::instance()->setApplicationActivity(&m_activity);
    }
    // 模拟 iOS 在后台直接结束进程：不会调用 prepareForShutdown，内存全部丢失，
    // 数据库里只剩最后一次写入的活动快照。
    void simulateProcessKilled() { FocusTimer::instance()->resetSession(); }

    QTemporaryDir* m_tempDir = nullptr;
    FakeMonotonicClock m_clock;
    FakeActivity m_activity{&m_clock};
};

void TimingRobustnessTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("timing.sqlite")));
    m_clock.ns = 0;
    m_clock.utcMs = 1700000000000LL;
    m_clock.boot = QStringLiteral("boot-A");
    m_activity.foreground = true;
    m_activity.lastForeground = 0;
    useFakeClock();
}

void TimingRobustnessTests::cleanup()
{
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    // 复位为真实系统时钟，避免注入的假时钟泄漏到其它测试。
    FocusTimer::instance()->m_clock = SystemMonotonicClock::instance();
    // 平台策略同样复位成桌面默认，避免移动端用例影响后面的桌面用例。
    FocusTimer::instance()->setRecoveryPolicy(FocusTimer::RecoveryPolicy::PauseOnRestore);
    FocusTimer::instance()->setApplicationActivity(nullptr);
    FocusTimer::instance()->setFreeTimingAllowed(true);
    FocusTimer::instance()->setManualRestAllowed(true);
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void TimingRobustnessTests::normalRunTracksMonotonicClock()
{
    const int taskId = insertTask(QStringLiteral("正常计时"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("正常计时"), 25 * 60));

    m_clock.advanceSecs(10);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 10);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 25 * 60 - 10);
}

void TimingRobustnessTests::pauseDoesNotConsumeTime()
{
    const int taskId = insertTask(QStringLiteral("暂停不计时"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("暂停不计时"), 25 * 60));

    m_clock.advanceSecs(10);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 10);

    FocusTimer::instance()->pauseFocus();
    // 暂停期间时钟推进 10 分钟（含“合盖”），恢复后这段不得计入。
    m_clock.advanceSecs(600);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 10);

    m_clock.advanceSecs(5);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 15);
}

void TimingRobustnessTests::sleepDuringRunCountsTowardElapsed()
{
    const int taskId = insertTask(QStringLiteral("休眠计时"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("休眠计时"), 25 * 60));

    // 关键回归：运行中系统休眠 5 分钟（单调时钟含休眠 → 前进 5 分钟），唤醒后剩余应减少 5 分钟。
    m_clock.advanceSecs(5 * 60);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 5 * 60);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 20 * 60);
}

void TimingRobustnessTests::sleepPastEndCompletesExactlyOnce()
{
    const int taskId = insertTask(QStringLiteral("休眠越界"));
    QSignalSpy phaseSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("休眠越界"), 5 * 60));

    // 休眠跨过了结束时刻（睡了 10 分钟，目标 5 分钟）。
    m_clock.advanceSecs(10 * 60);
    tick();

    QCOMPARE(phaseSpy.count(), 1);
    QCOMPARE(countFocusSessions(), 1);
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);

    QSqlQuery savedSession(DatabaseManager::instance()->database());
    QVERIFY(savedSession.exec(QStringLiteral(
        "SELECT duration, pomodoro_completed FROM focus_sessions")));
    QVERIFY(savedSession.next());
    // 合盖超过目标后自然完成，落库时长必须是目标 5 分钟而不是实际跨越的 10 分钟。
    QCOMPARE(savedSession.value(0).toInt(), 5 * 60);
    QCOMPARE(savedSession.value(1).toInt(), 1);
    savedSession.finish();

    // 时长截成了目标，占用的区间也必须跟着收：结束时间写成唤醒时刻的话，记录会画成
    // 「14:00–17:00 · 25 分钟」，而补录按区间判重叠，这 3 小时里的专注全都补不进去。
    // 这里的假单调时钟走了 10 分钟、墙钟几乎没动，区间只能靠「开始 + 时长」撑起来。
    QSqlQuery interval(DatabaseManager::instance()->database());
    QVERIFY(interval.exec(QStringLiteral("SELECT start_time, end_time FROM focus_sessions")));
    QVERIFY(interval.next());
    const QDateTime start = QDateTime::fromString(interval.value(0).toString(), Qt::ISODate);
    const QDateTime end = QDateTime::fromString(interval.value(1).toString(), Qt::ISODate);
    QVERIFY(start.isValid() && end.isValid());
    QVERIFY2(qAbs(start.secsTo(end) - 5 * 60) <= 1,
             qPrintable(QStringLiteral("区间 %1 秒与时长 300 秒不一致").arg(start.secsTo(end))));
    interval.finish();

    // 再次 tick 不得二次完成（会话已复位，守卫拦截）。
    m_clock.advanceSecs(60);
    tick();
    QCOMPARE(phaseSpy.count(), 1);
}

void TimingRobustnessTests::manuallyStoppedPomodoroPreservesElapsedPastTarget()
{
    const int taskId = insertTask(QStringLiteral("手动结束不截断"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("手动结束不截断"), 5 * 60));

    // 不触发 timeout，模拟用户在事件循环恢复后主动结束；手动结束不是自然到点，
    // 即使已超过番茄目标也必须保存真实经过时长。
    m_clock.advanceSecs(10 * 60);
    QVERIFY(FocusTimer::instance()->stopFocus());

    QSqlQuery savedSession(DatabaseManager::instance()->database());
    QVERIFY(savedSession.exec(QStringLiteral(
        "SELECT duration, pomodoro_completed FROM focus_sessions")));
    QVERIFY(savedSession.next());
    QCOMPARE(savedSession.value(0).toInt(), 10 * 60);
    QCOMPARE(savedSession.value(1).toInt(), 0);
}

void TimingRobustnessTests::freeModeCountsUpAcrossSleep()
{
    const int taskId = insertTask(QStringLiteral("自由跨休眠"));
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由跨休眠")));

    m_clock.advanceSecs(10 * 60);
    tick();
    // 自由计时是正计时、无目标；休眠时长照常累加。
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 10 * 60);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);

    QVERIFY(FocusTimer::instance()->stopFocus());
    QSqlQuery savedSession(DatabaseManager::instance()->database());
    QVERIFY(savedSession.exec(QStringLiteral("SELECT duration FROM focus_sessions")));
    QVERIFY(savedSession.next());
    QCOMPARE(savedSession.value(0).toInt(), 10 * 60);
}

void TimingRobustnessTests::elapsedIgnoresWallClockAdvance()
{
    const int taskId = insertTask(QStringLiteral("抗改钟"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("抗改钟"), 25 * 60));

    // 单调时钟冻结、真实墙钟流逝 1.1 秒：经过时间只认单调时钟，故不变。
    // 这等价于“用户把系统时间向前/向后跳”不会污染专注时长。
    QTest::qSleep(1100);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);

    // 单调时钟真正前进才计入。
    m_clock.advanceSecs(60);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 60);
}

void TimingRobustnessTests::recoveryFreezesAtCheckpointNotOfflineTime()
{
    const int taskId = insertTask(QStringLiteral("崩溃恢复不计离线"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("崩溃恢复不计离线"), 25 * 60));
    m_clock.advanceSecs(185);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 185);

    FocusTimer::instance()->prepareForShutdown();
    FocusTimer::instance()->resetSession();

    // 模拟应用未运行期间时钟又走了很久：恢复只应回到检查点（185s），不计离线时间，且为暂停态。
    m_clock.advanceSecs(9999);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 185);
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->currentTaskId(), taskId);
}

void TimingRobustnessTests::recoveredOverdueSessionCompletesOnceOnResume()
{
    const int taskId = insertTask(QStringLiteral("恢复即超时"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("恢复即超时"), 5 * 60));

    // 时钟越过目标但期间不 tick（模拟“崩溃发生在到点保存之前”）：不会在运行中完成。
    m_clock.advanceSecs(5 * 60 + 20);
    FocusTimer::instance()->prepareForShutdown(); // 冻结并写检查点于 320s（已超时、未完成）
    FocusTimer::instance()->resetSession();

    QSignalSpy phaseSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);

    // 恢复为暂停，用户继续后应恰好完成一次。
    QVERIFY(FocusTimer::instance()->resumeFocus());
    tick();
    QCOMPARE(phaseSpy.count(), 1);
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
}

void TimingRobustnessTests::breakSleepPastEndCompletesOnce()
{
    QSignalSpy phaseSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QVERIFY(FocusTimer::instance()->startBreak(5 * 60));

    m_clock.advanceSecs(10 * 60); // 休息期间休眠越界
    tick();

    QCOMPARE(phaseSpy.count(), 1);
    QCOMPARE(countFocusSessions(), 0); // 休息不写会话
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
}

void TimingRobustnessTests::suspendedAcrossExpirySettlesOnlyCurrentPhase()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("锁屏跨过到点"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("锁屏跨过到点"), 25 * 60));
    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);

    m_clock.advanceSecs(10 * 60);
    tick();
    // 锁屏：进程被挂起，期间一次 tick 都没有，时钟越过到点 20 分钟。
    m_activity.goBackground();
    m_clock.advanceSecs(35 * 60);
    // 解锁回到前台，这一刻之后计时器才恢复运行。
    m_activity.comeForeground();
    tick();

    // 只结算这一段：发离线结算信号、不发正常完成信号（界面不会自动开始休息、不补发提醒）。
    QCOMPARE(offlineSpy.count(), 1);
    QCOMPARE(offlineSpy.at(0).at(0).toInt(), int(FocusTimer::WorkPhase));
    QCOMPARE(completedSpy.count(), 0);
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
    QCOMPARE(FocusTimer::instance()->phase(), int(FocusTimer::NoPhase));
    // 记为自然完成的一个番茄，时长是目标 25 分钟而不是解锁时的 45 分钟。
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 1);
    QCOMPARE(queryInt(QStringLiteral("SELECT duration FROM focus_sessions")), 25 * 60);
    QCOMPARE(queryInt(QStringLiteral("SELECT pomodoro_completed FROM focus_sessions")), 1);
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 1);

    // 结算后不会再重复结算。
    m_clock.advanceSecs(60);
    tick();
    QCOMPARE(offlineSpy.count(), 1);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 1);
}

void TimingRobustnessTests::tickBeforeForegroundEventStillSettlesOffline()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("先 tick 后回前台"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("先 tick 后回前台"), 5 * 60));
    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);

    m_activity.goBackground();
    m_clock.advanceSecs(9 * 60);
    // 进程恢复运行时，定时器回调可能先于「回到前台」的状态事件被处理：此刻仍算不在前台。
    tick();

    QCOMPARE(offlineSpy.count(), 1);
    QCOMPARE(completedSpy.count(), 0);
}

void TimingRobustnessTests::foregroundExpiryStaysNormalCompletion()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("前台到点"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("前台到点"), 5 * 60));
    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);

    // 中途离开过又回来，但到点时人在前台：仍是正常完成，照常自动衔接与提醒。
    m_clock.advanceSecs(60);
    m_activity.goBackground();
    m_clock.advanceSecs(60);
    m_activity.comeForeground();
    m_clock.advanceSecs(3 * 60);
    tick();

    QCOMPARE(completedSpy.count(), 1);
    QCOMPARE(offlineSpy.count(), 0);
}

void TimingRobustnessTests::breakExpiredInBackgroundSettlesOffline()
{
    useMobilePolicy();
    QVERIFY(FocusTimer::instance()->startBreak(5 * 60));
    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);

    m_activity.goBackground();
    m_clock.advanceSecs(30 * 60);
    m_activity.comeForeground();
    tick();

    // 休息同样只结算这一段，不会自动开始下一个番茄；休息时长按目标记，不把后台的 30 分钟算进去。
    QCOMPARE(offlineSpy.count(), 1);
    QCOMPARE(offlineSpy.at(0).at(0).toInt(), int(FocusTimer::BreakPhase));
    QCOMPARE(completedSpy.count(), 0);
    QCOMPARE(queryInt(QStringLiteral("SELECT duration FROM rest_sessions")), 5 * 60);
}

void TimingRobustnessTests::killedAndRelaunchedAfterExpirySettlesOffline()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("杀进程后到点"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("杀进程后到点"), 25 * 60));
    m_clock.advanceSecs(5 * 60);
    tick();

    m_activity.goBackground();
    simulateProcessKilled();
    // 进程不在期间时钟越过到点；重新启动后应用回到前台。
    m_clock.advanceSecs(40 * 60);
    m_activity.comeForeground();

    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    // 恢复为运行中（离线时段已补回），由第一次 tick 结算——与挂起后回到前台是同一条路径。
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(offlineSpy.count(), 0);
    tick();

    QCOMPARE(offlineSpy.count(), 1);
    QCOMPARE(completedSpy.count(), 0);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 1);
    QCOMPARE(queryInt(QStringLiteral("SELECT duration FROM focus_sessions")), 25 * 60);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM active_focus_state")), 0);
}

void TimingRobustnessTests::killedAndRelaunchedBeforeExpiryKeepsRunning()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("杀进程未到点"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("杀进程未到点"), 25 * 60));
    m_clock.advanceSecs(5 * 60);
    tick();

    m_activity.goBackground();
    simulateProcessKilled();
    m_clock.advanceSecs(10 * 60);
    m_activity.comeForeground();

    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    // 离线的 10 分钟照算：已走 15 分钟，继续倒计时，而不是停在被结束前的检查点。
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 15 * 60);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 10 * 60);

    QSignalSpy completedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QSignalSpy offlineSpy(FocusTimer::instance(), &FocusTimer::phaseSettledOffline);
    // 之后在前台到点：正常完成。
    m_clock.advanceSecs(10 * 60);
    tick();
    QCOMPARE(completedSpy.count(), 1);
    QCOMPARE(offlineSpy.count(), 0);
}

void TimingRobustnessTests::relaunchAfterRebootRestoresPaused()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("跨重启"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("跨重启"), 25 * 60));
    m_clock.advanceSecs(7 * 60);
    tick();

    simulateProcessKilled();
    // 设备重启：开机标识变了，单调时钟从头计数，两边读数不可比。
    m_clock.boot = QStringLiteral("boot-B");
    m_clock.ns = 0;
    m_clock.advanceSecs(30);
    m_activity.comeForeground();

    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    // 退回原语义：按最后检查点恢复为暂停，不凭墙钟自动记账。
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 7 * 60);
}

void TimingRobustnessTests::relaunchWithoutBootIdCatchesUpWhenClocksAgree()
{
    useMobilePolicy();
    // iOS 真机：沙盒不让读开机标识。离开期间单调时钟与墙钟走了同样长，说明是同一次开机，照常补算。
    m_clock.boot.clear();
    const int taskId = insertTask(QStringLiteral("读不到开机标识"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("读不到开机标识"), 25 * 60));
    m_clock.advanceSecs(6 * 60);
    tick();

    simulateProcessKilled();
    m_clock.advanceSecs(10 * 60);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 16 * 60);
}

void TimingRobustnessTests::rebootWithoutBootIdIsDetectedByClockDisagreement()
{
    useMobilePolicy();
    m_clock.boot.clear();
    const int taskId = insertTask(QStringLiteral("无标识也能认出重启"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("无标识也能认出重启"), 25 * 60));
    m_clock.advanceSecs(6 * 60);
    tick();

    simulateProcessKilled();
    // 设备重启：墙钟照常过了 20 分钟，单调时钟却从零开始，只走了开机后的 40 秒。
    m_clock.utcMs += 20 * 60 * 1000;
    m_clock.ns = 40LL * 1000000000LL;
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 6 * 60);
}

void TimingRobustnessTests::wallClockChangedWhileAwayRestoresPaused()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("离开时改了时间"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("离开时改了时间"), 25 * 60));
    m_clock.advanceSecs(5 * 60);
    tick();

    simulateProcessKilled();
    m_clock.advanceSecs(3 * 60);
    // 离开期间把系统时间往后拨了 2 小时：两边走过的时长对不上，无法确认，退回恢复为暂停。
    m_clock.utcMs += 2 * 60 * 60 * 1000;
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 5 * 60);
}

void TimingRobustnessTests::freeFocusIsCaughtUpAfterRelaunch()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("自由计时补算"));
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由计时补算")));
    m_clock.advanceSecs(4 * 60);
    tick();

    // 开着自由计时切到别的应用学习，期间系统回收了进程。
    m_activity.goBackground();
    simulateProcessKilled();
    m_clock.advanceSecs(8 * 60 * 60);
    m_activity.comeForeground();
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    // 被系统结束不等于用户想停：同一次开机内补回离开的 8 小时并继续计时，
    // 与应用只被挂起时的结果一致。
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 4 * 60 + 8 * 60 * 60);
    // 忘了停表的兜底：超过默认 8 小时，结束前界面会要求确认或改短。
    QVERIFY(FocusTimer::instance()->requiresFreeFocusStopConfirmation(8));

    m_clock.advanceSecs(60);
    tick();
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 4 * 60 + 8 * 60 * 60 + 60);
}

void TimingRobustnessTests::freeFocusAfterRebootRestoresPaused()
{
    useMobilePolicy();
    m_clock.boot.clear();
    const int taskId = insertTask(QStringLiteral("自由计时遇重启"));
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由计时遇重启")));
    m_clock.advanceSecs(6 * 60);
    tick();

    simulateProcessKilled();
    // 设备重启：墙钟照常过了 20 分钟，单调时钟却从零开始，只走了开机后的 40 秒。
    // 离开期间的时长算不准，与番茄一样只会少补、不会多记：恢复为暂停。
    m_clock.utcMs += 20 * 60 * 1000;
    m_clock.ns = 40LL * 1000000000LL;
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 6 * 60);
}

void TimingRobustnessTests::manualRestIsNotCaughtUpAfterRelaunch()
{
    useMobilePolicy();
    QVERIFY(FocusTimer::instance()->startManualRest());
    m_clock.advanceSecs(4 * 60);
    tick();

    simulateProcessKilled();
    m_clock.advanceSecs(8 * 60 * 60);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    // 主动休息不补算，仍按原语义恢复为暂停：这条规则只对番茄与自由计时放开。
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 4 * 60);
}

void TimingRobustnessTests::shutdownOnCatchUpKeepsRunningAnchor()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("系统结束不等于暂停"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("系统结束不等于暂停"), 25 * 60));
    m_clock.advanceSecs(3 * 60);

    // iOS 前台被系统结束时也会走退出流程：不能借机暂停，否则恢复后番茄停在退出那一刻。
    FocusTimer::instance()->prepareForShutdown();
    QCOMPARE(queryInt(QStringLiteral("SELECT running FROM active_focus_state")), 1);
    QCOMPARE(queryInt(QStringLiteral("SELECT elapsed_seconds FROM active_focus_state")), 3 * 60);

    simulateProcessKilled();
    m_clock.advanceSecs(2 * 60);
    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 5 * 60);
}

void TimingRobustnessTests::pausePersistFailureKeepsRunningAndAnchor()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("暂停写入失败"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("暂停写入失败"), 25 * 60));
    m_clock.advanceSecs(60);
    tick();
    const int anchorBefore = queryInt(QStringLiteral("SELECT segment_start_ns IS NOT NULL FROM active_focus_state"));
    QCOMPARE(anchorBefore, 1);

    // 让活动快照的更新失败，模拟磁盘满、数据库被锁等情况。
    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER reject_state_update BEFORE UPDATE ON active_focus_state "
        "BEGIN SELECT RAISE(ABORT, 'rejected'); END")));

    QSignalSpy failedSpy(FocusTimer::instance(), &FocusTimer::operationFailed);
    QSignalSpy runningSpy(FocusTimer::instance(), &FocusTimer::runningStateChanged);
    QVERIFY(!FocusTimer::instance()->pauseFocus());

    // 保存失败不能表现为已经可靠暂停：仍在计时、提示重试、快照仍是原来的运行锚点。
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    QCOMPARE(failedSpy.count(), 1);
    QCOMPARE(runningSpy.count(), 0);
    QCOMPARE(queryInt(QStringLiteral("SELECT running FROM active_focus_state")), 1);
    m_clock.advanceSecs(30);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 90);

    // 修好之后可以正常暂停，快照随之变成暂停。
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER reject_state_update")));
    QVERIFY(FocusTimer::instance()->pauseFocus());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(queryInt(QStringLiteral("SELECT running FROM active_focus_state")), 0);
    QCOMPARE(queryInt(QStringLiteral("SELECT accumulated_ms FROM active_focus_state")), 90 * 1000);
}

void TimingRobustnessTests::resumePersistFailureStaysPaused()
{
    useMobilePolicy();
    const int taskId = insertTask(QStringLiteral("继续写入失败"));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("继续写入失败"), 25 * 60));
    m_clock.advanceSecs(60);
    QVERIFY(FocusTimer::instance()->pauseFocus());

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER reject_state_update BEFORE UPDATE ON active_focus_state "
        "BEGIN SELECT RAISE(ABORT, 'rejected'); END")));

    QSignalSpy failedSpy(FocusTimer::instance(), &FocusTimer::operationFailed);
    QVERIFY(!FocusTimer::instance()->resumeFocus());
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QCOMPARE(failedSpy.count(), 1);
    // 仍停在暂停值：界面没有走，快照也没有「运行中」锚点。
    m_clock.advanceSecs(120);
    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 60);
    QCOMPARE(queryInt(QStringLiteral("SELECT running FROM active_focus_state")), 0);
    QVERIFY(trigger.exec(QStringLiteral("DROP TRIGGER reject_state_update")));
}

void TimingRobustnessTests::freeTimingDisallowedRejectsOnlyFreeFocus()
{
    FocusTimer::instance()->setFreeTimingAllowed(false);
    const int taskId = insertTask(QStringLiteral("只关自由计时"));
    QSignalSpy failedSpy(FocusTimer::instance(), &FocusTimer::operationFailed);

    QVERIFY(!FocusTimer::instance()->startFocus(taskId, QStringLiteral("只关自由计时")));
    QCOMPARE(failedSpy.count(), 1);
    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM active_focus_state")), 0);

    // 主动休息有自己的开关，不受影响（两者曾共用一个开关）。
    QVERIFY(FocusTimer::instance()->startManualRest());
}

void TimingRobustnessTests::manualRestDisallowedRejectsOnlyManualRest()
{
    // iPad 的配置：主动休息关、自由计时开。
    FocusTimer::instance()->setManualRestAllowed(false);
    const int taskId = insertTask(QStringLiteral("只关主动休息"));
    QSignalSpy failedSpy(FocusTimer::instance(), &FocusTimer::operationFailed);

    QVERIFY(!FocusTimer::instance()->startManualRest());
    QCOMPARE(failedSpy.count(), 1);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM active_focus_state")), 0);

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("只关主动休息")));
    QCOMPARE(failedSpy.count(), 1);
}

QTEST_MAIN(TimingRobustnessTests)
#include "TimingRobustnessTests.moc"
