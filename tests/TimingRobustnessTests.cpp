#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

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
    void advanceMs(qint64 ms) { ns += ms * 1000000; }
    void advanceSecs(qint64 s) { ns += s * 1000000000LL; }
    qint64 nowNsecs() const override { return ns; }
};

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
    void freeModeCountsUpAcrossSleep();
    void elapsedIgnoresWallClockAdvance();
    void recoveryFreezesAtCheckpointNotOfflineTime();
    void recoveredOverdueSessionCompletesOnceOnResume();
    void breakSleepPastEndCompletesOnce();

private:
    void tick() { QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection)); }
    void useFakeClock() { FocusTimer::instance()->m_clock = &m_clock; }

    QTemporaryDir* m_tempDir = nullptr;
    FakeMonotonicClock m_clock;
};

void TimingRobustnessTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("timing.sqlite")));
    m_clock.ns = 0;
    useFakeClock();
}

void TimingRobustnessTests::cleanup()
{
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    // 复位为真实系统时钟，避免注入的假时钟泄漏到其它测试。
    FocusTimer::instance()->m_clock = SystemMonotonicClock::instance();
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

    // 再次 tick 不得二次完成（会话已复位，守卫拦截）。
    m_clock.advanceSecs(60);
    tick();
    QCOMPARE(phaseSpy.count(), 1);
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

QTEST_MAIN(TimingRobustnessTests)
#include "TimingRobustnessTests.moc"
