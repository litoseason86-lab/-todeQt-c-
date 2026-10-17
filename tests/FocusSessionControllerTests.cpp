#include <QSettings>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
// FocusTimer 声明 friend class FocusSessionControllerTests，测试可注入时钟并直接触发内部计时器。
#include "../src/services/FocusSessionController.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/MonotonicClock.h"
#include "../src/services/PendingDeletion.h"
#include "../src/services/TaskManager.h"

namespace {

// 可控单调时钟：手动推进，确定性地模拟「已经专注了多久」，不用真等。
class FakeMonotonicClock : public MonotonicClock
{
public:
    qint64 ns = 0;
    qint64 utcMs = 1700000000000LL;
    void advanceSecs(qint64 s) { ns += s * 1000000000LL; utcMs += s * 1000; }
    qint64 nowNsecs() const override { return ns; }
    QString bootSessionId() const override { return QStringLiteral("boot-A"); }
    qint64 utcNowMsecs() const override { return utcMs; }
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
    query.prepare(QStringLiteral("INSERT INTO tasks (title, date, completed) VALUES (:t, :d, 0)"));
    query.bindValue(QStringLiteral(":t"), title);
    query.bindValue(QStringLiteral(":d"), QDate::currentDate().toString(Qt::ISODate));
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

// 按指定日期、完成状态与显示顺序造一条任务，返回编号。
int insertTaskOn(const QString& title, const QString& isoDate, bool completed, int displayOrder)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES (:t, :d, :c, :o)"));
    query.bindValue(QStringLiteral(":t"), title);
    query.bindValue(QStringLiteral(":d"), isoDate);
    query.bindValue(QStringLiteral(":c"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":o"), displayOrder);
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

constexpr int kHour = 3600;

} // namespace

class FocusSessionControllerTests : public QObject
{
    Q_OBJECT

private slots:
    void timerFailuresCarryOneSpecificReason_data();
    void timerFailuresCarryOneSpecificReason();
    void controllerAdmissionFailureHasSpecificReason();
    void successfulTimerActionsDoNotReportFailure();
    void automaticCompletionFailureReportsOnceWithReason();
    void init();
    void cleanup();

    void nextBreakUsesLongBreakOnEveryNthPomodoro();
    void autoAdvanceFollowsPerPhaseSwitch();

    void warningHoursUsesValidSettingValue();
    void warningHoursFallsBackToEightWhenOutOfRange();
    void longFreeConfirmationUsesStrictlyGreaterThanThreshold();
    void longFreeConfirmationFollowsConfiguredHours();
    void longFreeConfirmationOnlyForActiveFreeSession();

    void endCurrentWithoutSessionReportsNone();
    void endFreeSessionSavesAndReportsKind();
    void endFreeSessionUnderMinimumReportsDiscarded();
    void endFreeSessionPastThresholdAsksForConfirmationWithoutStopping();
    void endPomodoroResetsConsecutiveCount();
    void endPomodoroUnderMinimumReportsDiscarded();
    void endPomodoroBreakWithoutSessionStillStops();
    void endManualRestSavesRestAndReportsKind();
    void endPomodoroCycleInTheGapResetsCountWhileEndCurrentDoesNot();
    void endPomodoroCycleOnRunningPomodoroMatchesEndCurrentAndResetsCount();
    void endFailureReportsPerModeMessageAndKeepsTimer();

    void planTaskEntryFollowsQuickStartAndRememberedMode();
    void planTaskEntryReturnsToTheRunningTaskIgnoringRememberedMode();
    void planTaskEntryTreatsDisallowedFreeTimingAsPomodoro();
    void planTaskEntryRejectsInvalidTaskOrTitle();
    void switchConsequenceSeparatesRestSavedAndNotSaved();
    void stopForSwitchBlocksWhenTimerStateChanged();
    void stopForSwitchWaitsForLongFreeConfirmation();
    void stopForSwitchStopsMatchingSessionAndReportsFailure();
    void planModeSwitchInheritsTimerTaskBeforeSelection();
    void planModeSwitchStaysOnPageWithoutBusyTimerOrTask();

    void autoStartCandidatePrefersTheValidSelection();
    void autoStartCandidateFlagsADeletedSelectionAndFallsBack();
    void autoStartCandidateIsEmptyWhenEverythingIsCompleted();
    void autoStartCandidateFollowsDisplayOrderNotInsertionOrder();
    void autoStartCandidateSkipsTheTaskInTheUndoWindow();
    void autoStartCandidateOnlyLooksAtTheLogicalToday();
    void createTodayTaskLandsOnLogicalTodayAndIdentifiesTheNewRow();
    void createTodayTaskRejectsBlankTitleWithoutWriting();

    void completingTheTimedTaskEndsItsFocus();
    void completingAnotherTaskLeavesTheTimerRunning();
    void completingDuringARestDoesNotInterruptIt();
    void completingThePausedTimedTaskAlsoEndsIt();
    void completingTheTimedTaskUnderMinimumReportsDiscarded();
    void completingTheTimedTaskPastThresholdAsksForConfirmation();
    void completingTheTimedTaskReportsSaveFailure();

    void finishLongFreeWithCorrectionSavesCorrectedDuration();
    void finishLongFreeWithoutCorrectionSavesFullDuration();
    void finishLongFreeDiscardDropsSession();
    void finishLongFreeFailuresCarryDistinctMessages();

private:
    FocusTimer* timer() const { return FocusTimer::instance(); }
    void tick() { QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection)); }
    // 自由专注已跑 seconds 秒（校准过 elapsedSeconds）。
    int startFreeFor(int seconds)
    {
        const int taskId = insertTask(QStringLiteral("自由任务"));
        if (taskId <= 0 || !timer()->startFocus(taskId, QStringLiteral("自由任务"))) {
            return -1;
        }
        m_clock.advanceSecs(seconds);
        tick();
        return taskId;
    }
    void writeRawWarningHours(const QString& value)
    {
        {
            QSettings raw(m_settingsPath, QSettings::IniFormat);
            raw.setValue(QStringLiteral("focus/freeTimerWarningHours"), value);
            raw.sync();
        }
        m_settings->reload();
    }

    QTemporaryDir* m_tempDir = nullptr;
    QString m_settingsPath;
    AppSettings* m_settings = nullptr;
    FocusSessionController* m_controller = nullptr;
    PendingDeletion* m_pending = nullptr;
    FakeMonotonicClock m_clock;
};

void FocusSessionControllerTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("controller.sqlite")));
    m_settingsPath = m_tempDir->filePath("settings.ini");
    m_settings = new AppSettings(m_settingsPath);
    m_pending = new PendingDeletion(TaskManager::instance(), FocusHistoryService::instance());
    // 撤销窗口设得很大：用例里要的是「窗口还开着」，不能被计时器提前提交。
    m_pending->setDelayMs(10 * 60 * 1000);
    m_controller = new FocusSessionController(timer(), TaskManager::instance(), m_settings, m_pending);
    m_clock.ns = 0;
    m_clock.utcMs = 1700000000000LL;
    timer()->m_clock = &m_clock;
}

void FocusSessionControllerTests::cleanup()
{
    timer()->resetSession();
    timer()->m_resetCycleOnStop = false;
    timer()->resetPomodoroCount();
    // 复位为真实系统时钟，避免假时钟泄漏到别的用例。
    timer()->m_clock = SystemMonotonicClock::instance();
    delete m_controller;
    m_controller = nullptr;
    m_pending->cancel();
    delete m_pending;
    m_pending = nullptr;
    delete m_settings;
    m_settings = nullptr;
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void FocusSessionControllerTests::warningHoursUsesValidSettingValue()
{
    // 保证：用户设的提醒时长在 1–24 之间时原样生效（不被默认 8 盖掉）。
    for (const int hours : {1, 12, 24}) {
        writeRawWarningHours(QString::number(hours));
        QCOMPARE(m_settings->freeTimerWarningHours(), hours);
        QCOMPARE(m_controller->freeTimerWarningHours(), hours);
    }
}

void FocusSessionControllerTests::warningHoursFallsBackToEightWhenOutOfRange()
{
    // 保证：损坏或越界的设置值回落到 8 小时，而不是夹到边界 1 或 24。
    for (const QString& bad : {QStringLiteral("0"), QStringLiteral("25"), QStringLiteral("-3"),
                               QStringLiteral("100")}) {
        writeRawWarningHours(bad);
        QCOMPARE(m_controller->freeTimerWarningHours(), 8);
    }
}

void FocusSessionControllerTests::longFreeConfirmationUsesStrictlyGreaterThanThreshold()
{
    // 保证：恰好等于提醒时长不弹确认，多一秒才弹（严格大于）。
    QCOMPARE(m_controller->freeTimerWarningHours(), 8);
    QVERIFY(startFreeFor(8 * kHour) > 0);
    QCOMPARE(timer()->elapsedSeconds(), 8 * kHour);
    QVERIFY(!m_controller->needsLongFreeStopConfirmation());

    m_clock.advanceSecs(1);
    tick();
    QCOMPARE(timer()->elapsedSeconds(), 8 * kHour + 1);
    QVERIFY(m_controller->needsLongFreeStopConfirmation());
}

void FocusSessionControllerTests::longFreeConfirmationFollowsConfiguredHours()
{
    // 保证：阈值取自设置而不是写死 8 小时：设成 2 小时，3 小时的专注就要确认，而默认值下不会。
    writeRawWarningHours(QStringLiteral("2"));
    QVERIFY(startFreeFor(3 * kHour) > 0);
    QVERIFY(3 * kHour < 8 * kHour);
    QVERIFY(m_controller->needsLongFreeStopConfirmation());

    writeRawWarningHours(QStringLiteral("4"));
    QVERIFY(!m_controller->needsLongFreeStopConfirmation());
}

void FocusSessionControllerTests::longFreeConfirmationOnlyForActiveFreeSession()
{
    // 保证：没有会话、或在番茄里，即使时长超过阈值也不要求超长确认。
    QVERIFY(!m_controller->needsLongFreeStopConfirmation());

    const int taskId = insertTask(QStringLiteral("番茄任务"));
    // 目标时长设得比已跑时长更长，会话才不会在途中自然到点。
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄任务"), 10 * kHour));
    m_clock.advanceSecs(9 * kHour);
    tick();
    QVERIFY(timer()->elapsedSeconds() > m_controller->freeTimerWarningHours() * kHour);
    QVERIFY(timer()->hasActiveSession());
    QCOMPARE(timer()->mode(), int(FocusTimer::PomodoroMode));
    QVERIFY(!m_controller->needsLongFreeStopConfirmation());
}

void FocusSessionControllerTests::endCurrentWithoutSessionReportsNone()
{
    // 保证：没有会话且不在任何阶段时，「结束」什么都不做并如实说明 none。
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(timer()->phase(), int(FocusTimer::NoPhase));
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("none"));
    QCOMPARE(r.value("kind").toString(), QString());
    QVERIFY(!r.value("discarded").toBool());
    QCOMPARE(r.value("error").toString(), QString());
}

void FocusSessionControllerTests::endFreeSessionSavesAndReportsKind()
{
    // 保证：自由专注在阈值内结束即写入记录，kind 为 free，不算丢弃。
    QVERIFY(startFreeFor(10 * 60) > 0);
    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions WHERE duration > 0"), 0);
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("free"));
    QVERIFY(!r.value("discarded").toBool());
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 10 * 60);
}

void FocusSessionControllerTests::endFreeSessionUnderMinimumReportsDiscarded()
{
    // 保证：不足最小有效时长的自由专注被丢弃，discarded 为真且库里没有记录。
    QVERIFY(startFreeFor(2 * 60) > 0);
    QVERIFY(2 * 60 < timer()->minimumValidMinutes() * 60);
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QVERIFY(r.value("discarded").toBool());
    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions"), 0);

    // 对照：同样的流程，足够长时不应被标为丢弃（防止 discarded 恒真）。
    QVERIFY(startFreeFor(5 * 60) > 0);
    QVERIFY(!m_controller->endCurrent().value("discarded").toBool());
}

void FocusSessionControllerTests::endFreeSessionPastThresholdAsksForConfirmationWithoutStopping()
{
    // 保证：超长自由专注的「结束」只返回需要确认，计时与记录原样保留，等用户在确认框里选。
    QVERIFY(startFreeFor(8 * kHour + 5) > 0);
    QVERIFY(m_controller->needsLongFreeStopConfirmation());
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("needsConfirmation"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("free"));
    QVERIFY(timer()->hasActiveSession());
    QCOMPARE(timer()->elapsedSeconds(), 8 * kHour + 5);
}

void FocusSessionControllerTests::endPomodoroResetsConsecutiveCount()
{
    // 保证：用户结束番茄后，连续完成数归零，下一轮长休息节奏从头开始。
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(25 * 60);
    tick();
    QCOMPARE(timer()->completedPomodoros(), 1);

    // 第二轮番茄进行到一半时点结束（第一轮自然到点后计时器已回到空闲）。
    QVERIFY(!timer()->hasActiveSession());
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(6 * 60);
    tick();
    QCOMPARE(timer()->completedPomodoros(), 1);
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QCOMPARE(timer()->completedPomodoros(), 0);
}

void FocusSessionControllerTests::endPomodoroUnderMinimumReportsDiscarded()
{
    // 保证：番茄中途结束且不足最小有效时长，discarded 为真、不留记录。
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(90);
    tick();
    QVERIFY(90 < timer()->minimumValidMinutes() * 60);
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QVERIFY(r.value("discarded").toBool());
    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions"), 0);
}

void FocusSessionControllerTests::endPomodoroBreakWithoutSessionStillStops()
{
    // 保证：番茄休息段没有数据库会话，也必须能被「结束」停掉，并归零连续计数。
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(25 * 60);
    tick();
    QCOMPARE(timer()->completedPomodoros(), 1);
    // 自然到点后由界面启动休息段。
    if (timer()->phase() != int(FocusTimer::BreakPhase)) {
        QVERIFY(timer()->startBreakForTask(5 * 60, taskId, QStringLiteral("番茄")));
    }
    QCOMPARE(timer()->phase(), int(FocusTimer::BreakPhase));
    QVERIFY(!timer()->hasActiveSession());

    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QCOMPARE(timer()->phase(), int(FocusTimer::NoPhase));
    QCOMPARE(timer()->completedPomodoros(), 0);
}

void FocusSessionControllerTests::endManualRestSavesRestAndReportsKind()
{
    // 保证：主动休息按自己的路径结束：写休息记录，kind 为 manualRest，不触发超长确认。
    QVERIFY(timer()->startManualRest());
    m_clock.advanceSecs(9 * kHour);
    tick();
    QCOMPARE(timer()->mode(), int(FocusTimer::ManualRestMode));
    QVERIFY(!m_controller->needsLongFreeStopConfirmation());
    const QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("manualRest"));
    QVERIFY(!r.value("discarded").toBool());
    QCOMPARE(timer()->phase(), int(FocusTimer::NoPhase));
    QCOMPARE(queryInt("SELECT COUNT(*) FROM rest_sessions WHERE manual = 1"), 1);
}

void FocusSessionControllerTests::endPomodoroCycleInTheGapResetsCountWhileEndCurrentDoesNot()
{
    // 保证：番茄间的空档里（计时器已回到空闲、自由模式）点番茄页的「结束」，仍放弃整个循环、连续计数归零；
    // 而按计时器真实模式分发的 endCurrent 在这时只报 none、不动计数——两个入口的差别由此钉住。
    timer()->m_completedPomodoros = 3;
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(timer()->phase(), int(FocusTimer::NoPhase));
    QCOMPARE(timer()->mode(), int(FocusTimer::FreeMode));
    QCOMPARE(timer()->completedPomodoros(), 3);

    QCOMPARE(m_controller->endCurrent().value("result").toString(), QStringLiteral("none"));
    QCOMPARE(timer()->completedPomodoros(), 3);

    const QVariantMap r = m_controller->endPomodoroCycle();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QVERIFY(!r.value("discarded").toBool());
    QCOMPARE(r.value("error").toString(), QString());
    QCOMPARE(timer()->completedPomodoros(), 0);
}

void FocusSessionControllerTests::endPomodoroCycleOnRunningPomodoroMatchesEndCurrentAndResetsCount()
{
    // 保证：番茄正在进行时，番茄页的「结束」与 endCurrent 的结果相同（结算、discarded 一致），并让连续计数归零。
    const int taskId = insertTask(QStringLiteral("番茄"));
    timer()->m_completedPomodoros = 2;
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(10 * 60);
    tick();
    QCOMPARE(timer()->completedPomodoros(), 2);

    const QVariantMap r = m_controller->endPomodoroCycle();
    QCOMPARE(r.value("result").toString(), QStringLiteral("ended"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QVERIFY(!r.value("discarded").toBool());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 10 * 60);
    QCOMPARE(timer()->completedPomodoros(), 0);
}

void FocusSessionControllerTests::endFailureReportsPerModeMessageAndKeepsTimer()
{
    // 保证：保存失败时三种模式各报各的文案，计时仍在继续，连续计数不归零。
    struct Case { QString kind; QString message; };

    // 自由专注
    QVERIFY(startFreeFor(10 * 60) > 0);
    DatabaseManager::instance()->close();
    QVariantMap r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("failed"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("free"));
    QCOMPARE(r.value("error").toString(), QStringLiteral("专注保存失败，请重试"));
    QVERIFY(timer()->hasActiveSession());
    timer()->resetSession();

    // 番茄
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("controller2.sqlite")));
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startPomodoroWork(taskId, QStringLiteral("番茄"), 25 * 60));
    m_clock.advanceSecs(10 * 60);
    tick();
    DatabaseManager::instance()->close();
    r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("failed"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("pomodoro"));
    QCOMPARE(r.value("error").toString(), QStringLiteral("番茄结束失败，请重试"));
    QVERIFY(timer()->hasActiveSession());
    timer()->resetSession();

    // 主动休息
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("controller3.sqlite")));
    QVERIFY(timer()->startManualRest());
    m_clock.advanceSecs(60);
    tick();
    DatabaseManager::instance()->close();
    r = m_controller->endCurrent();
    QCOMPARE(r.value("result").toString(), QStringLiteral("failed"));
    QCOMPARE(r.value("kind").toString(), QStringLiteral("manualRest"));
    QCOMPARE(r.value("error").toString(), QStringLiteral("结束休息失败，请重试"));
    QCOMPARE(timer()->phase(), int(FocusTimer::ManualRestPhase));
}

void FocusSessionControllerTests::planTaskEntryFollowsQuickStartAndRememberedMode()
{
    // 保证：空闲时任务入口按「记住的模式」与「快速开始」开关分流，标题 trim 后交回。
    QVERIFY(timer()->freeTimingAllowed());
    QVERIFY(!timer()->hasActiveSession());
    struct Row { int lastMode; bool quick; };
    for (const Row row : {Row{0, false}, Row{0, true}, Row{1, false}, Row{1, true}}) {
        m_settings->setLastMode(row.lastMode);
        m_settings->setQuickStartEnabled(row.quick);
        QCOMPARE(m_settings->lastMode(), row.lastMode);
        QCOMPARE(m_settings->quickStartEnabled(), row.quick);
        const QVariantMap plan = m_controller->planTaskEntry(7, QStringLiteral("  高等数学 \n"));
        QCOMPARE(plan.value("kind").toString(), QStringLiteral("apply"));
        QCOMPARE(plan.value("usePomodoro").toBool(), row.lastMode == 1);
        QCOMPARE(plan.value("autoStart").toBool(), row.quick);
        QCOMPARE(plan.value("title").toString(), QStringLiteral("高等数学"));
    }
}

void FocusSessionControllerTests::planTaskEntryReturnsToTheRunningTaskIgnoringRememberedMode()
{
    // 保证：点正在计时的同一任务只回到当前计时，不看记住的模式；点别的任务才要确认；
    // 只有休息段（没有会话）时，即使任务编号相同也不是「回到当前」。
    m_settings->setLastMode(1);
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    QCOMPARE(timer()->currentTaskId(), taskId);
    QCOMPARE(m_controller->planTaskEntry(taskId, QStringLiteral("自由任务")).value("kind").toString(),
             QStringLiteral("returnToCurrent"));
    QCOMPARE(m_controller->planTaskEntry(taskId + 1, QStringLiteral("别的任务")).value("kind").toString(),
             QStringLiteral("confirmSwitch"));

    // 暂停也算进行中。
    QVERIFY(timer()->pauseFocus());
    QCOMPARE(m_controller->planTaskEntry(taskId, QStringLiteral("自由任务")).value("kind").toString(),
             QStringLiteral("returnToCurrent"));
    QVERIFY(m_controller->endCurrent().value("result").toString() == QStringLiteral("ended"));

    QVERIFY(timer()->startBreakForTask(5 * 60, taskId, QStringLiteral("自由任务")));
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(timer()->currentTaskId(), taskId);
    QCOMPARE(m_controller->planTaskEntry(taskId, QStringLiteral("自由任务")).value("kind").toString(),
             QStringLiteral("confirmSwitch"));
}

void FocusSessionControllerTests::planTaskEntryTreatsDisallowedFreeTimingAsPomodoro()
{
    // 保证：平台不开放自由计时时，即使记住的是自由模式，任务入口也按番茄处理。
    m_settings->setLastMode(0);
    QVERIFY(!m_controller->planTaskEntry(7, QStringLiteral("任务")).value("usePomodoro").toBool());
    timer()->setFreeTimingAllowed(false);
    QVERIFY(m_controller->planTaskEntry(7, QStringLiteral("任务")).value("usePomodoro").toBool());
    timer()->setFreeTimingAllowed(true);
    QVERIFY(!m_controller->planTaskEntry(7, QStringLiteral("任务")).value("usePomodoro").toBool());
}

void FocusSessionControllerTests::planTaskEntryRejectsInvalidTaskOrTitle()
{
    // 保证：编号不大于 0 或标题全是空白时判为无效；同样的流程里有效输入不会被误判。
    QCOMPARE(m_controller->planTaskEntry(7, QStringLiteral("任务")).value("kind").toString(),
             QStringLiteral("apply"));
    for (const int id : {0, -1}) {
        QCOMPARE(m_controller->planTaskEntry(id, QStringLiteral("任务")).value("kind").toString(),
                 QStringLiteral("invalid"));
    }
    for (const QString& title : {QString(), QStringLiteral("   "), QStringLiteral(" \t\n ")}) {
        QCOMPARE(m_controller->planTaskEntry(7, title).value("kind").toString(), QStringLiteral("invalid"));
    }
    // 忙碌时无效输入也优先判无效，不去确认切换。
    QVERIFY(startFreeFor(10 * 60) > 0);
    QCOMPARE(m_controller->planTaskEntry(0, QStringLiteral("任务")).value("kind").toString(),
             QStringLiteral("invalid"));
}

void FocusSessionControllerTests::switchConsequenceSeparatesRestSavedAndNotSaved()
{
    // 保证：被截断的是休息、会保存的专注还是不足门槛不保存的专注，三者分得清，且门槛上「恰好」算保存。
    const int minimumSeconds = timer()->minimumValidMinutes() * 60;
    QVERIFY(startFreeFor(minimumSeconds - 1) > 0);
    QVariantMap c = m_controller->switchConsequence();
    QCOMPARE(c.value("kind").toString(), QStringLiteral("notSaved"));
    QCOMPARE(c.value("minimumMinutes").toInt(), timer()->minimumValidMinutes());

    m_clock.advanceSecs(1);
    tick();
    QCOMPARE(timer()->elapsedSeconds(), minimumSeconds);
    QCOMPARE(m_controller->switchConsequence().value("kind").toString(), QStringLiteral("saved"));
    QVERIFY(m_controller->endCurrent().value("result").toString() == QStringLiteral("ended"));

    // 休息段：哪怕只跑了几秒（专注口径下会是 notSaved）也只说休息保留。
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startBreakForTask(5 * 60, taskId, QStringLiteral("番茄")));
    m_clock.advanceSecs(5);
    tick();
    QVERIFY(timer()->elapsedSeconds() < minimumSeconds);
    QCOMPARE(m_controller->switchConsequence().value("kind").toString(), QStringLiteral("restKept"));
    QVERIFY(m_controller->endCurrent().value("result").toString() == QStringLiteral("ended"));

    QVERIFY(timer()->startManualRest());
    QCOMPARE(timer()->phase(), int(FocusTimer::ManualRestPhase));
    QCOMPARE(m_controller->switchConsequence().value("kind").toString(), QStringLiteral("restKept"));
}

void FocusSessionControllerTests::stopForSwitchBlocksWhenTimerStateChanged()
{
    // 保证：确认期间任务、模式或阶段任一项变了，确认被拦下，计时器不被停（不会误停刚自动启动的下一段）。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    const QVariantMap source = m_controller->captureSwitchSource();
    QCOMPARE(source.value("taskId").toInt(), taskId);
    QCOMPARE(source.value("mode").toInt(), int(FocusTimer::FreeMode));
    QCOMPARE(source.value("phase").toInt(), int(FocusTimer::NoPhase));

    // 对照：状态没变时才会停（用另一份相同来源在最后验证）。
    timer()->m_currentTaskId = taskId + 100;
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("stateChanged"));
    QVERIFY(timer()->hasActiveSession());
    timer()->m_currentTaskId = taskId;

    timer()->m_mode = FocusTimer::PomodoroMode;
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("stateChanged"));
    QVERIFY(timer()->hasActiveSession());
    timer()->m_mode = FocusTimer::FreeMode;

    timer()->m_phase = FocusTimer::BreakPhase;
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("stateChanged"));
    QVERIFY(timer()->hasActiveSession());
    timer()->m_phase = FocusTimer::NoPhase;

    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions WHERE duration >= 600"), 0);
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("stopped"));
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 10 * 60);
}

void FocusSessionControllerTests::stopForSwitchWaitsForLongFreeConfirmation()
{
    // 保证：超长自由专注切换时先走超长确认，不直接停表。
    QVERIFY(startFreeFor(8 * kHour + 5) > 0);
    const QVariantMap source = m_controller->captureSwitchSource();
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("needsLongFreeConfirmation"));
    QVERIFY(timer()->hasActiveSession());
    QCOMPARE(timer()->elapsedSeconds(), 8 * kHour + 5);
}

void FocusSessionControllerTests::stopForSwitchStopsMatchingSessionAndReportsFailure()
{
    // 保证：停表失败时报 stopFailed 且计时保持；成功时报 stopped。
    QVERIFY(startFreeFor(10 * 60) > 0);
    const QVariantMap source = m_controller->captureSwitchSource();
    DatabaseManager::instance()->close();
    QCOMPARE(m_controller->stopForSwitch(source), QStringLiteral("stopFailed"));
    QVERIFY(timer()->hasActiveSession());
}

void FocusSessionControllerTests::planModeSwitchInheritsTimerTaskBeforeSelection()
{
    // 保证：计时器忙时切模式要确认，继承的是计时器的任务而不是页面选中的；计时器没有任务时才用选中项。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    QVariantMap plan = m_controller->planModeSwitch(taskId + 50, QStringLiteral("选中的任务"));
    QCOMPARE(plan.value("kind").toString(), QStringLiteral("confirmSwitch"));
    QCOMPARE(plan.value("taskId").toInt(), taskId);
    QCOMPARE(plan.value("title").toString(), QStringLiteral("自由任务"));
    QVERIFY(m_controller->endCurrent().value("result").toString() == QStringLiteral("ended"));

    // 休息段没有任务：用选中项。
    QVERIFY(timer()->startBreak(5 * 60));
    QCOMPARE(timer()->currentTaskId(), -1);
    plan = m_controller->planModeSwitch(42, QStringLiteral("  选中的任务 "));
    QCOMPARE(plan.value("kind").toString(), QStringLiteral("confirmSwitch"));
    QCOMPARE(plan.value("taskId").toInt(), 42);
    QCOMPARE(plan.value("title").toString(), QStringLiteral("选中的任务"));
}

void FocusSessionControllerTests::planModeSwitchStaysOnPageWithoutBusyTimerOrTask()
{
    // 保证：空闲时只换页签；忙但既没有计时器任务也没有选中项（休息段）时同样只换页签。
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(m_controller->planModeSwitch(42, QStringLiteral("选中的任务")).value("kind").toString(),
             QStringLiteral("pageOnly"));

    QVERIFY(timer()->startBreak(5 * 60));
    QCOMPARE(timer()->currentTaskId(), -1);
    QCOMPARE(m_controller->planModeSwitch(-1, QString()).value("kind").toString(), QStringLiteral("pageOnly"));
    QCOMPARE(m_controller->planModeSwitch(42, QStringLiteral("   ")).value("kind").toString(),
             QStringLiteral("pageOnly"));
    QCOMPARE(m_controller->planModeSwitch(0, QStringLiteral("标题")).value("kind").toString(),
             QStringLiteral("pageOnly"));
}

void FocusSessionControllerTests::autoStartCandidatePrefersTheValidSelection()
{
    // 保证：用户刚选中的任务优先于今日第一条（⌘↩ 不该把人换到别的任务上）。
    const QString today = m_controller->logicalToday().toString(Qt::ISODate);
    const int first = insertTaskOn(QStringLiteral("第一条"), today, false, 1);
    const int second = insertTaskOn(QStringLiteral("第二条"), today, false, 2);
    QVERIFY(first > 0 && second > first);

    const QVariantMap c = m_controller->autoStartCandidate(second, QStringLiteral("  第二条 "));
    QCOMPARE(c.value("id").toInt(), second);
    QCOMPARE(c.value("title").toString(), QStringLiteral("第二条"));
    QVERIFY(!c.value("selectionStale").toBool());
}

void FocusSessionControllerTests::autoStartCandidateFlagsADeletedSelectionAndFallsBack()
{
    // 保证：选中项已被删除时标记 stale 并回落到今日第一条未完成；
    // 选中编号有效但标题为空时不算「选中项」，也不标 stale。
    const QString today = m_controller->logicalToday().toString(Qt::ISODate);
    const int first = insertTaskOn(QStringLiteral("第一条"), today, false, 1);
    const int doomed = insertTaskOn(QStringLiteral("要删的"), today, false, 2);
    QSqlQuery del(DatabaseManager::instance()->database());
    QVERIFY(del.exec(QStringLiteral("DELETE FROM tasks WHERE id = %1").arg(doomed)));

    QVariantMap c = m_controller->autoStartCandidate(doomed, QStringLiteral("要删的"));
    QVERIFY(c.value("selectionStale").toBool());
    QCOMPARE(c.value("id").toInt(), first);
    QCOMPARE(c.value("title").toString(), QStringLiteral("第一条"));

    c = m_controller->autoStartCandidate(doomed, QStringLiteral("   "));
    QVERIFY(!c.value("selectionStale").toBool());
    QCOMPARE(c.value("id").toInt(), first);
}

void FocusSessionControllerTests::autoStartCandidateIsEmptyWhenEverythingIsCompleted()
{
    // 保证：今日任务全部完成（或今日没有任务）时没有候选，交给界面展开选择器，而不是随便挑一条。
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), -1);
    const QString today = m_controller->logicalToday().toString(Qt::ISODate);
    QVERIFY(insertTaskOn(QStringLiteral("做完了"), today, true, 1) > 0);
    QVERIFY(insertTaskOn(QStringLiteral("也做完了"), today, true, 2) > 0);
    const QVariantMap c = m_controller->autoStartCandidate(-1, QString());
    QCOMPARE(c.value("id").toInt(), -1);
    QVERIFY(!c.value("selectionStale").toBool());
}

void FocusSessionControllerTests::autoStartCandidateFollowsDisplayOrderNotInsertionOrder()
{
    // 保证：候选是今日页显示顺序里的第一条未完成，而不是最先插入的那条；已完成的不参选。
    const QString today = m_controller->logicalToday().toString(Qt::ISODate);
    const int inserted1 = insertTaskOn(QStringLiteral("插入最早但排第三"), today, false, 3);
    const int inserted2 = insertTaskOn(QStringLiteral("排第一"), today, false, 1);
    insertTaskOn(QStringLiteral("排第二"), today, false, 2);
    insertTaskOn(QStringLiteral("已完成但顺序最小"), today, true, 0);
    QVERIFY(inserted1 > 0 && inserted2 > inserted1);

    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("title").toString(),
             QStringLiteral("排第一"));
}

void FocusSessionControllerTests::autoStartCandidateSkipsTheTaskInTheUndoWindow()
{
    // 保证：撤销窗口里的任务（仍在库里）不会被挑作候选；撤销之后它又能参选。
    const QString today = m_controller->logicalToday().toString(Qt::ISODate);
    const int first = insertTaskOn(QStringLiteral("刚删的第一条"), today, false, 1);
    const int second = insertTaskOn(QStringLiteral("第二条"), today, false, 2);
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), first);

    QVERIFY(m_pending->requestTask(first, QStringLiteral("刚删的第一条")));
    QCOMPARE(m_pending->taskId(), first);
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), second);

    m_pending->cancel();
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), first);
}

void FocusSessionControllerTests::autoStartCandidateOnlyLooksAtTheLogicalToday()
{
    // 保证：候选只取逻辑今日。凌晨 02:00、日界 4 点时，逻辑今日是前一天：
    // 自然日上显示顺序更靠前的任务、以及更早日期的任务都不能入选。
    m_settings->setDayStartHour(4);
    m_controller->m_now = [] { return QDateTime(QDate(2026, 3, 10), QTime(2, 0)); };
    QCOMPARE(m_controller->logicalToday(), QDate(2026, 3, 9));

    insertTaskOn(QStringLiteral("自然日第一条"), QStringLiteral("2026-03-10"), false, 1);
    insertTaskOn(QStringLiteral("更早的一天"), QStringLiteral("2026-03-08"), false, 1);
    // 逻辑今日里只有顺序更靠后的一条，仍应入选。
    const int logical = insertTaskOn(QStringLiteral("逻辑今日"), QStringLiteral("2026-03-09"), false, 5);
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), logical);

    // 逻辑今日没有未完成任务时没有候选，哪怕别的日子有。
    QSqlQuery done(DatabaseManager::instance()->database());
    QVERIFY(done.exec(QStringLiteral("UPDATE tasks SET completed = 1 WHERE id = %1").arg(logical)));
    QCOMPARE(m_controller->autoStartCandidate(-1, QString()).value("id").toInt(), -1);
}

void FocusSessionControllerTests::createTodayTaskLandsOnLogicalTodayAndIdentifiesTheNewRow()
{
    // 保证：新任务建在逻辑今日（不是自然日），标题 trim 后入库，编号来自创建结果；
    // 已有同名任务时返回的是新行，不会绑到旧的那条。
    m_settings->setDayStartHour(4);
    m_controller->m_now = [] { return QDateTime(QDate(2026, 3, 10), QTime(2, 0)); };
    const int existing = insertTaskOn(QStringLiteral("同名任务"), QStringLiteral("2026-03-09"), false, 99);
    QVERIFY(existing > 0);

    const int created = m_controller->createTodayTask(QStringLiteral("  同名任务\n"));
    QVERIFY(created > 0);
    QVERIFY(created != existing);
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '同名任务'")), 2);
    QSqlQuery q(DatabaseManager::instance()->database());
    QVERIFY(q.exec(QStringLiteral("SELECT title, date FROM tasks WHERE id = %1").arg(created)));
    QVERIFY(q.next());
    QCOMPARE(q.value(0).toString(), QStringLiteral("同名任务"));
    QCOMPARE(q.value(1).toString(), QStringLiteral("2026-03-09"));
}

void FocusSessionControllerTests::createTodayTaskRejectsBlankTitleWithoutWriting()
{
    // 保证：空白标题返回 -1 且不写库（前提：库里本来一条任务都没有）。
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
    for (const QString& title : {QString(), QStringLiteral("   "), QStringLiteral(" \t\n ")}) {
        QCOMPARE(m_controller->createTodayTask(title), -1);
    }
    QCOMPARE(queryInt(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
}

void FocusSessionControllerTests::completingTheTimedTaskEndsItsFocus()
{
    // 保证：完成的正是正在计时的任务时，顺带结束这段专注并写入记录。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    QCOMPARE(timer()->currentTaskId(), taskId);
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("ended"));
    QVERIFY(!r.value("discarded").toBool());
    QCOMPARE(r.value("error").toString(), QString());
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 10 * 60);
}

void FocusSessionControllerTests::completingAnotherTaskLeavesTheTimerRunning()
{
    // 保证：完成的不是正在计时的任务（例如已完成的任务再练一轮时完成别的），计时器和会话原样继续。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    const int sessionId = timer()->m_sessionId;
    QVERIFY(sessionId > 0);
    const QVariantMap r = m_controller->handleTaskCompleted(taskId + 1);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("none"));
    QVERIFY(timer()->hasActiveSession());
    QVERIFY(timer()->isRunning());
    QCOMPARE(timer()->currentTaskId(), taskId);
    QCOMPARE(timer()->m_sessionId, sessionId);
}

void FocusSessionControllerTests::completingDuringARestDoesNotInterruptIt()
{
    // 保证：番茄休息段带着刚才的任务但没有会话，此时完成这个任务不打断休息。
    const int taskId = insertTask(QStringLiteral("番茄"));
    QVERIFY(timer()->startBreakForTask(5 * 60, taskId, QStringLiteral("番茄")));
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(timer()->currentTaskId(), taskId);
    QCOMPARE(timer()->phase(), int(FocusTimer::BreakPhase));
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("none"));
    QCOMPARE(timer()->phase(), int(FocusTimer::BreakPhase));
    QVERIFY(timer()->isRunning());
}

void FocusSessionControllerTests::completingThePausedTimedTaskAlsoEndsIt()
{
    // 保证：暂停中的计时也是进行中的专注，完成它同样结束。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    QVERIFY(timer()->pauseFocus());
    QVERIFY(timer()->hasActiveSession());
    QVERIFY(!timer()->isRunning());
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("ended"));
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 10 * 60);
}

void FocusSessionControllerTests::completingTheTimedTaskUnderMinimumReportsDiscarded()
{
    // 保证：不足最小有效时长时仍算结束，但 discarded 为真，界面据此说明「未计入记录」。
    const int taskId = startFreeFor(90);
    QVERIFY(taskId > 0);
    QVERIFY(90 < timer()->minimumValidMinutes() * 60);
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("ended"));
    QVERIFY(r.value("discarded").toBool());
    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions"), 0);
}

void FocusSessionControllerTests::completingTheTimedTaskPastThresholdAsksForConfirmation()
{
    // 保证：超长自由专注可能是忘了停，完成任务时不直接停表，原样告诉界面需要确认。
    const int taskId = startFreeFor(9 * kHour);
    QVERIFY(taskId > 0);
    QVERIFY(m_controller->needsLongFreeStopConfirmation());
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("needsConfirmation"));
    QVERIFY(timer()->hasActiveSession());
    QCOMPARE(timer()->elapsedSeconds(), 9 * kHour);
}

void FocusSessionControllerTests::completingTheTimedTaskReportsSaveFailure()
{
    // 保证：停表失败时如实带回失败和文案，计时仍在继续。
    const int taskId = startFreeFor(10 * 60);
    QVERIFY(taskId > 0);
    DatabaseManager::instance()->close();
    const QVariantMap r = m_controller->handleTaskCompleted(taskId);
    QCOMPARE(r.value("focusResult").toString(), QStringLiteral("failed"));
    QCOMPARE(r.value("error").toString(), QStringLiteral("专注保存失败，请重试"));
    QVERIFY(timer()->hasActiveSession());
}

void FocusSessionControllerTests::finishLongFreeWithCorrectionSavesCorrectedDuration()
{
    // 保证：用户在超长确认框里把时长往下修正后，记录的是修正值而不是实际跑过的时长。
    QVERIFY(startFreeFor(9 * kHour) > 0);
    const QVariantMap r = m_controller->finishLongFree(true, 30 * 60);
    QVERIFY(r.value("ok").toBool());
    QCOMPARE(r.value("error").toString(), QString());
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 30 * 60);
}

void FocusSessionControllerTests::finishLongFreeWithoutCorrectionSavesFullDuration()
{
    // 保证：选择记录但不修正时，按实际时长原样保存（修正秒数为 0 或负数都视为不修正）。
    QVERIFY(startFreeFor(9 * kHour) > 0);
    const QVariantMap r = m_controller->finishLongFree(true, -1);
    QVERIFY(r.value("ok").toBool());
    QCOMPARE(queryInt("SELECT duration FROM focus_sessions"), 9 * kHour);
}

void FocusSessionControllerTests::finishLongFreeDiscardDropsSession()
{
    // 保证：选择「不记录」会丢掉整段会话，不进入统计；即便同时带了修正秒数也不记录。
    QVERIFY(startFreeFor(9 * kHour) > 0);
    const QVariantMap r = m_controller->finishLongFree(false, 30 * 60);
    QVERIFY(r.value("ok").toBool());
    QVERIFY(!timer()->hasActiveSession());
    QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions"), 0);
}

void FocusSessionControllerTests::finishLongFreeFailuresCarryDistinctMessages()
{
    // 保证：修正与丢弃两条路失败时各给各的文案，且失败后会话原样保留。
    QVERIFY(startFreeFor(9 * kHour) > 0);

    // 修正值超过实际时长：服务层拒绝，保存失败。
    QVariantMap r = m_controller->finishLongFree(true, 10 * kHour);
    QVERIFY(!r.value("ok").toBool());
    QCOMPARE(r.value("error").toString(), QStringLiteral("专注保存失败，请重试"));
    QVERIFY(timer()->hasActiveSession());

    // 丢弃失败：数据库不可写。
    DatabaseManager::instance()->close();
    r = m_controller->finishLongFree(false, -1);
    QVERIFY(!r.value("ok").toBool());
    QCOMPARE(r.value("error").toString(), QStringLiteral("专注丢弃失败，请重试"));
    QVERIFY(timer()->hasActiveSession());
}

void FocusSessionControllerTests::nextBreakUsesLongBreakOnEveryNthPomodoro()
{
    // 保证：长休息只在连续完成数大于 0 且是间隔的整数倍时生效，其余用页面当前选的休息时长；关掉长休息一律用所选时长。
    // 三个时长互不相同（所选 7、默认 5、长休息 20），返回哪一个一眼可辨。
    m_settings->setLongBreakEnabled(true);
    m_settings->setLongBreakInterval(4);
    m_settings->setLongBreakMinutes(20);
    QVERIFY(m_settings->longBreakEnabled());
    QCOMPARE(m_settings->longBreakInterval(), 4);
    QCOMPARE(m_settings->longBreakMinutes(), 20);

    const QList<QPair<int, int>> table{{0, 7}, {3, 7}, {4, 20}, {6, 7}, {8, 20}};
    for (const auto& row : table) {
        timer()->m_completedPomodoros = row.first;
        QCOMPARE(m_controller->nextBreakMinutes(7), row.second);
    }

    m_settings->setLongBreakEnabled(false);
    timer()->m_completedPomodoros = 4;
    QCOMPARE(m_controller->nextBreakMinutes(7), 7);
}

void FocusSessionControllerTests::autoAdvanceFollowsPerPhaseSwitch()
{
    // 保证：工作段完成后只看「自动开始休息」，休息段完成后只看「自动开始下一个番茄」，两个开关不串用；其它阶段从不自动衔接。
    struct Row { bool autoBreak; bool autoNext; int phase; bool expected; };
    const QList<Row> table{
        {true, false, 1, true}, {false, true, 1, false},
        {false, true, 2, true}, {true, false, 2, false},
        {true, true, 0, false}, {true, true, 3, false},
    };
    for (const Row& row : table) {
        m_settings->setAutoStartBreak(row.autoBreak);
        m_settings->setAutoStartNextPomodoro(row.autoNext);
        QCOMPARE(m_settings->autoStartBreak(), row.autoBreak);
        QCOMPARE(m_settings->autoStartNextPomodoro(), row.autoNext);
        QCOMPARE(m_controller->autoAdvanceAfter(row.phase), row.expected);
    }
}


// 产品保证：启动和停表被拒绝时说明具体原因，保留原计时与数据库状态，一次调用只报一次。
void FocusSessionControllerTests::timerFailuresCarryOneSpecificReason_data()
{
    QTest::addColumn<QString>("action");
    QTest::addColumn<QString>("fault");
    QTest::addColumn<QString>("reason");
    for (const QString& action : {QStringLiteral("startFree"), QStringLiteral("startPomodoro"), QStringLiteral("startBreak"), QStringLiteral("startManual")}) {
        for (const QString& fault : {QStringLiteral("closed"), QStringLiteral("transaction"), QStringLiteral("snapshot"), QStringLiteral("busy")}) {
            // 休息快照沿用单条写入，没有显式事务；不能用外部事务假装其启动失败。
            if ((action == QLatin1String("startBreak") || action == QLatin1String("startManual")) && fault == QLatin1String("transaction")) continue;
            const QString reason = fault == QLatin1String("closed") ? QStringLiteral("未打开")
                : fault == QLatin1String("transaction") ? QStringLiteral("事务")
                : fault == QLatin1String("busy") ? QStringLiteral("正在进行") : QStringLiteral("T33 blocked");
            QTest::newRow(qPrintable(action + "-" + fault)) << action << fault << reason;
        }
    }
    for (const QString& action : {QStringLiteral("startFree"), QStringLiteral("startPomodoro")}) {
        for (const QString& fault : {QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("missing"), QStringLiteral("insert"), QStringLiteral("commit")}) {
            const QString reason = fault == QLatin1String("id") ? QStringLiteral("编号")
                : fault == QLatin1String("title") ? QStringLiteral("标题")
                : fault == QLatin1String("missing") ? QStringLiteral("不存在")
                : fault == QLatin1String("commit") ? QStringLiteral("FOREIGN KEY") : QStringLiteral("T33 blocked");
            QTest::newRow(qPrintable(action + "-" + fault)) << action << fault << reason;
        }
    }
    for (const QString& action : {QStringLiteral("startPomodoro"), QStringLiteral("startBreak")})
        QTest::newRow(qPrintable(action + "-duration")) << action << QStringLiteral("duration") << QStringLiteral("大于 0");
    QTest::newRow("stop-idle") << QStringLiteral("stopIdle") << QStringLiteral("idle") << QStringLiteral("没有进行中");
    for (const QString& action : {QStringLiteral("stopFree"), QStringLiteral("stopShort")}) {
        QTest::newRow(qPrintable(action + "-missing-row")) << action << QStringLiteral("missing-row") << QStringLiteral("不存在");
        QTest::newRow(qPrintable(action + "-missing-cycle")) << action << QStringLiteral("missing-cycle") << QStringLiteral("循环状态不存在");
    }
    for (const QString& action : {QStringLiteral("stopFree"), QStringLiteral("stopShort"), QStringLiteral("stopBreak"), QStringLiteral("stopManual")}) {
        for (const QString& fault : {QStringLiteral("closed"), QStringLiteral("transaction"), QStringLiteral("write"), QStringLiteral("clear"), QStringLiteral("commit"), QStringLiteral("cycle")}) {
            const QString reason = fault == QLatin1String("closed") ? QStringLiteral("未打开")
                : fault == QLatin1String("transaction") ? QStringLiteral("事务")
                : fault == QLatin1String("commit") ? QStringLiteral("FOREIGN KEY") : QStringLiteral("T33 blocked");
            QTest::newRow(qPrintable(action + "-" + fault)) << action << fault << reason;
        }
    }
}

// 产品保证：每个失败出口同时返回失败与一条具体原因，不把未落库的启动或结束显示成成功。
void FocusSessionControllerTests::timerFailuresCarryOneSpecificReason()
{
    QFETCH(QString, action); QFETCH(QString, fault); QFETCH(QString, reason);
    const int task = insertTask(QStringLiteral("失败后保留")); QVERIFY(task > 0);
    const bool stopping = action.startsWith("stop");
    const bool rest = action == QLatin1String("stopBreak") || action == QLatin1String("stopManual");
    if ((stopping && action != QLatin1String("stopIdle")) || fault == QLatin1String("busy")) {
        if (action == QLatin1String("stopBreak")) QVERIFY(timer()->startBreak(300));
        else if (action == QLatin1String("stopManual")) QVERIFY(timer()->startManualRest());
        else QVERIFY(timer()->startFocus(task, QStringLiteral("失败后保留")));
        m_clock.advanceSecs(action == QLatin1String("stopShort") ? 30 : 240);
    }
    QSqlDatabase database = DatabaseManager::instance()->database();
    QSqlQuery setup(database);
    QString target;
    QString verb;
    if (fault == QLatin1String("snapshot")) { target = "active_focus_state"; verb = "INSERT"; }
    if (fault == QLatin1String("insert")) { target = "focus_sessions"; verb = "INSERT"; }
    if (fault == QLatin1String("write")) {
        target = rest ? "rest_sessions" : "focus_sessions";
        verb = rest ? "INSERT" : action == QLatin1String("stopShort") ? "DELETE" : "UPDATE";
    }
    if (fault == QLatin1String("clear")) { target = "active_focus_state"; verb = "DELETE"; }
    if (fault == QLatin1String("cycle")) { target = "pomodoro_cycle_state"; verb = "UPDATE"; }
    if (!target.isEmpty()) QVERIFY2(setup.exec("CREATE TEMP TRIGGER t33_block BEFORE " + verb + " ON " + target
        + " BEGIN SELECT RAISE(ABORT, 'T33 blocked'); END"), qPrintable(setup.lastError().text()));
    if (fault == QLatin1String("commit")) {
        // 延迟外键只在 COMMIT 拒绝写入，验证原因在 rollback 清掉连接错误之前被保存。
        QVERIFY(setup.exec("CREATE TABLE t33_deferred(parent INTEGER REFERENCES tasks(id) DEFERRABLE INITIALLY DEFERRED)"));
        target = stopping ? (rest ? "rest_sessions" : "focus_sessions") : "focus_sessions";
        verb = stopping ? (rest ? "INSERT" : action == QLatin1String("stopShort") ? "DELETE" : "UPDATE") : "INSERT";
        QVERIFY(setup.exec("CREATE TEMP TRIGGER t33_commit AFTER " + verb + " ON " + target
            + " BEGIN INSERT INTO t33_deferred VALUES(-999); END"));
    }
    if (fault == QLatin1String("cycle") && rest) timer()->m_resetCycleOnStop = true;
    if (fault == QLatin1String("cycle") && action == QLatin1String("stopShort")) timer()->m_resetCycleOnStop = true;
    if (fault == QLatin1String("missing-row")) QVERIFY(setup.exec("DELETE FROM focus_sessions"));
    if (fault == QLatin1String("missing-cycle")) {
        QVERIFY(setup.exec("DELETE FROM pomodoro_cycle_state"));
        timer()->m_resetCycleOnStop = true;
    }
    if (fault == QLatin1String("transaction")) QVERIFY(database.transaction());
    const int beforeSessions = queryInt("SELECT COUNT(*) FROM focus_sessions");
    const int beforeSnapshots = queryInt("SELECT COUNT(*) FROM active_focus_state");
    const int beforeTask = timer()->currentTaskId(); const int beforePhase = timer()->phase();
    const int beforeMode = timer()->mode(); const int beforeElapsed = timer()->elapsedSeconds();
    const bool beforeRunning = timer()->isRunning(); const int beforeSession = timer()->m_sessionId;
    if (fault == QLatin1String("closed")) DatabaseManager::instance()->close();
    QSignalSpy failed(timer(), &FocusTimer::operationFailed);
    bool result;
    if (stopping) result = timer()->stopFocus();
    else if (action == QLatin1String("startFree")) result = timer()->startFocus(fault == "id" ? -1 : fault == "missing" ? task + 999 : task, fault == "title" ? "  " : "失败后保留");
    else if (action == QLatin1String("startPomodoro")) result = timer()->startPomodoroWork(fault == "id" ? -1 : fault == "missing" ? task + 999 : task, fault == "title" ? "  " : "失败后保留", fault == "duration" ? 0 : 1500);
    else if (action == QLatin1String("startManual")) result = timer()->startManualRest();
    else result = timer()->startBreak(fault == "duration" ? 0 : 300);
    QVERIFY(!result); QCOMPARE(failed.count(), 1);
    const QString message = failed.first().first().toString();
    QVERIFY2(message.contains(stopping ? QStringLiteral("结束") : QStringLiteral("启动")), qPrintable(message));
    QVERIFY2(message.contains(reason), qPrintable(message));
    QCOMPARE(timer()->currentTaskId(), beforeTask); QCOMPARE(timer()->phase(), beforePhase);
    QCOMPARE(timer()->mode(), beforeMode); QCOMPARE(timer()->isRunning(), beforeRunning);
    QCOMPARE(timer()->m_sessionId, beforeSession); QCOMPARE(timer()->elapsedSeconds(), beforeElapsed);
    if (fault != QLatin1String("closed")) {
        QCOMPARE(queryInt("SELECT COUNT(*) FROM focus_sessions"), beforeSessions);
        QCOMPARE(queryInt("SELECT COUNT(*) FROM active_focus_state"), beforeSnapshots);
        QCOMPARE(queryInt("SELECT COUNT(*) FROM rest_sessions"), 0);
    }
    if (fault == QLatin1String("transaction")) QVERIFY(database.rollback());
    timer()->m_resetCycleOnStop = false;
}


// 产品保证：专注控制器缺少必要服务时报告明确原因，不把无效新建或切换悄悄吞掉。
void FocusSessionControllerTests::controllerAdmissionFailureHasSpecificReason()
{
    FocusSessionController unavailable(nullptr, nullptr, m_settings, m_pending);
    QSignalSpy failure(&unavailable, &FocusSessionController::operationFailed);
    QCOMPARE(unavailable.stopForSwitch({}), QStringLiteral("stopFailed"));
    QCOMPARE(failure.count(), 1); QVERIFY(failure.takeFirst().first().toString().contains(QStringLiteral("计时器不可用")));
    QCOMPARE(unavailable.createTodayTask(QStringLiteral("任务")), -1);
    QCOMPARE(failure.count(), 1); QVERIFY(failure.takeFirst().first().toString().contains(QStringLiteral("任务服务不可用")));
    QSignalSpy taskFailure(TaskManager::instance(), &TaskManager::operationFailed);
    QSignalSpy controllerFailure(m_controller, &FocusSessionController::operationFailed);
    QCOMPARE(m_controller->createTodayTask(QStringLiteral("  ")), -1);
    QCOMPARE(taskFailure.count(), 1); QVERIFY(taskFailure.first().first().toString().contains(QStringLiteral("标题")));
    QCOMPARE(controllerFailure.count(), 0);
}

// 产品保证：成功启动与结束三类计时不误报失败，测试不依赖真实流逝时间。
void FocusSessionControllerTests::successfulTimerActionsDoNotReportFailure()
{
    const int task = insertTask(QStringLiteral("正常计时")); QVERIFY(task > 0);
    QSignalSpy failed(timer(), &FocusTimer::operationFailed);
    QVERIFY(timer()->startFocus(task, QStringLiteral("正常计时"))); m_clock.advanceSecs(240); QVERIFY(timer()->stopFocus());
    QVERIFY(timer()->startPomodoroWork(task, QStringLiteral("正常计时"), 1500)); m_clock.advanceSecs(240); QVERIFY(timer()->stopFocus());
    QVERIFY(timer()->startBreak(300)); m_clock.advanceSecs(20); QVERIFY(timer()->stopFocus());
    QCOMPARE(failed.count(), 0);
}

// 产品保证：自然到点保存失败包含底层原因，自动重试不重复提示，修复存储后能完成结算。
void FocusSessionControllerTests::automaticCompletionFailureReportsOnceWithReason()
{
    const int task = insertTask(QStringLiteral("自动结算")); QVERIFY(task > 0);
    QVERIFY(timer()->startPomodoroWork(task, QStringLiteral("自动结算"), 180));
    QSqlQuery setup(DatabaseManager::instance()->database());
    QVERIFY(setup.exec("CREATE TEMP TRIGGER t33_finish BEFORE UPDATE ON focus_sessions BEGIN SELECT RAISE(ABORT, 'T33 finish blocked'); END"));
    QSignalSpy failed(timer(), &FocusTimer::operationFailed);
    m_clock.advanceSecs(180);
    timer()->finishExpiredPhase(false); timer()->finishExpiredPhase(false);
    QCOMPARE(failed.count(), 1); QVERIFY(failed.first().first().toString().contains("T33 finish blocked"));
    QVERIFY(timer()->hasActiveSession());
    QVERIFY(setup.exec("DROP TRIGGER t33_finish")); timer()->finishExpiredPhase(false);
    QVERIFY(!timer()->hasActiveSession()); QCOMPARE(failed.count(), 1);
}

QTEST_GUILESS_MAIN(FocusSessionControllerTests)
#include "FocusSessionControllerTests.moc"
