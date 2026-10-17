#import "../src/platform/ios/bridge/PTFocusBridge.h"
#import "../src/platform/ios/bridge/PTGapReminderBridge.h"
#include "../src/platform/ios/bridge/PTBridgeSupport.h"
#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusSessionController.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/MonotonicClock.h"
#include "../src/services/NotificationService.h"
#include "../src/services/PhaseAlarmCoordinator.h"
#include "../src/services/PendingDeletion.h"
#include "../src/services/TaskManager.h"
#include <QSettings>
#include <QScopeGuard>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <QtTest>
#include <memory>

namespace {
class BridgeClock : public MonotonicClock {
public:
    qint64 ns = 0;
    qint64 utc = QDateTime::currentMSecsSinceEpoch();
    qint64 nowNsecs() const override { return ns; }
    QString bootSessionId() const override { return QStringLiteral("bridge-test"); }
    qint64 utcNowMsecs() const override { return utc; }
    void advance(int seconds) { ns += qint64(seconds) * 1000000000; utc += qint64(seconds) * 1000; }
};
}
// 复用 P2A 已有友元，仅在这个独立测试二进制注入单调时钟，不扩大生产接口。
class FocusSessionControllerTests {
public:
    static void reset(const MonotonicClock *clock) {
        auto *timer = FocusTimer::instance(); timer->m_timer.stop(); timer->resetSession();
        timer->m_clock = clock; timer->m_completedPomodoros = 0;
    }
    static void expire(bool offline) { FocusTimer::instance()->finishExpiredPhase(offline); }
    static void restoreClock() { FocusTimer::instance()->m_clock = SystemMonotonicClock::instance(); }
};

class PTFocusBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void actionRejectionKeepsSpecificReason_data();
    void actionRejectionKeepsSpecificReason();
    void partialGapFailureIsClaimedByReturnedSummary();
    void focusActionReasonsAreClaimed_data();
    void focusActionReasonsAreClaimed();
    void pendingDeletionDoesNotPolluteAnotherCall();
    void initTestCase();
    void init();
    void cleanup();
    void snapshotAndTimerActions();
    void taskEntryAndSwitchProjections();
    void endAndLongFreeBranches();
    void breakAndAutoAdvanceForwardController();
    void candidateCreationAndTaskCompletion();
    void failuresAndMissingController();
    void allSignalsAndLifetime();
    void backgroundSignalsReturnToMain();
    void reminderFailureSignals();
    void gapSummaryAndConversion();
    void gapPartialFailureAndReadFailure();
private:
    QTemporaryDir m_preferences, m_database;
    BridgeClock m_clock;
    std::unique_ptr<PendingDeletion> m_pending;
    std::unique_ptr<FocusSessionController> m_controller;
    int m_task = -1;
};
// 产品保证：桥接测试只写隔离设置目录和数据库，不干扰用户或其它工作区。
void PTFocusBridgeTests::initTestCase() {
    QVERIFY(m_preferences.isValid()); QVERIFY(m_database.isValid());
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
    QCoreApplication::setApplicationName(QStringLiteral("PTFocusBridgeTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
}
// 产品保证：每个场景从空库与空闲计时开始，长时段由可控时钟推进。
void PTFocusBridgeTests::init() {
    QSettings().clear(); AppSettings::instance()->reload();
    QFile::remove(m_database.filePath(QStringLiteral("focus.sqlite")));
    QVERIFY(DatabaseManager::instance()->initialize(m_database.filePath(QStringLiteral("focus.sqlite"))));
    m_clock.ns = 0; m_clock.utc = QDateTime::currentMSecsSinceEpoch();
    FocusSessionControllerTests::reset(&m_clock);
    FocusTimer::instance()->setFreeTimingAllowed(true); FocusTimer::instance()->setManualRestAllowed(true);
    m_pending = std::make_unique<PendingDeletion>(TaskManager::instance(), FocusHistoryService::instance());
    m_controller = std::make_unique<FocusSessionController>(FocusTimer::instance(), TaskManager::instance(), AppSettings::instance(), m_pending.get());
    PTBridgeSupport::registerService(QStringLiteral("focusController"), m_controller.get());
    m_task = TaskManager::instance()->createTask(QStringLiteral("桥接甲"), LogicalDay::today(AppSettings::instance()->dayStartHour()), -1, 0, QStringLiteral(""));
    QVERIFY(m_task > 0);
}
// 产品保证：失败用例也会撤销登记并恢复系统时钟，不留下悬空服务或活动计时。
void PTFocusBridgeTests::cleanup() {
    PTBridgeSupport::registerService(QStringLiteral("focusController"), nullptr);
    m_controller.reset(); m_pending.reset();
    FocusSessionControllerTests::reset(&m_clock); FocusSessionControllerTests::restoreClock();
    DatabaseManager::instance()->close(); QSettings().clear(); AppSettings::instance()->reload();
}
// 产品保证：快照保留真实模式、阶段、秒数、任务与逻辑日；暂停继续与带任务休息直达计时器。
void PTFocusBridgeTests::snapshotAndTimerActions() {
    @autoreleasepool {
        PTFocusBridge *bridge = [PTFocusBridge new]; NSError *error = nil;
        QVERIFY([bridge startPomodoro:m_task title:@"桥接甲" seconds:307 error:&error]); QVERIFY(error == nil);
        m_clock.advance(61);
        PTFocusSnapshot *value = bridge.snapshot;
        QCOMPARE(value.mode, NSInteger(1)); QCOMPARE(value.phase, NSInteger(1)); QVERIFY(value.running && value.hasActiveSession);
        QCOMPARE(value.elapsedSeconds, NSInteger(61)); QCOMPARE(value.remainingSeconds, NSInteger(246)); QCOMPARE(value.targetSeconds, NSInteger(307));
        QCOMPARE(value.currentTaskId, NSInteger(m_task)); QVERIFY([value.currentTaskTitle isEqualToString:@"桥接甲"]);
        QVERIFY([value.sessionLogicalDate isEqualToString:PTBridgeSupport::string(FocusTimer::instance()->sessionLogicalDate())]);
        QVERIFY(value.sessionStartTime.length > 0);
        QVERIFY([value.sessionStartTime isEqualToString:PTBridgeSupport::timestamp(FocusTimer::instance()->sessionStartTime())]);
        QCOMPARE(value.minimumValidMinutes, NSInteger(3)); QCOMPARE(value.completedPomodoros, NSInteger(0));
        QVERIFY(value.freeTimingAllowed && value.manualRestAllowed);
        QVERIFY([bridge pause:&error]); QVERIFY(!bridge.snapshot.running); QVERIFY([bridge resume:&error]);
        QVERIFY([bridge.endCurrent.result isEqualToString:@"ended"]);
        QCOMPARE(bridge.snapshot.sessionStartTime.length, NSUInteger(0));
        QVERIFY([bridge startBreak:89 taskId:m_task title:@"休息上下文" error:&error]);
        QCOMPARE(bridge.snapshot.phase, NSInteger(2)); QCOMPARE(bridge.snapshot.currentTaskId, NSInteger(m_task));
        QVERIFY([bridge.snapshot.currentTaskTitle isEqualToString:@"休息上下文"]);
        QVERIFY([bridge.endCurrent.kind isEqualToString:@"pomodoro"]);
        FocusTimer::instance()->setFreeTimingAllowed(false); FocusTimer::instance()->setManualRestAllowed(false);
        QVERIFY(!bridge.snapshot.freeTimingAllowed && !bridge.snapshot.manualRestAllowed);
    }
}
// 产品保证：入口和切换值对象逐字段传递控制器分支，确认期间状态变动不得停下新状态。
void PTFocusBridgeTests::taskEntryAndSwitchProjections() {
    @autoreleasepool {
        PTFocusBridge *b = [PTFocusBridge new]; NSError *error = nil;
        QVERIFY([[b planTaskEntry:0 title:@"甲"].kind isEqualToString:@"invalid"]);
        auto *settings = AppSettings::instance(); settings->setQuickStartEnabled(true); settings->setLastMode(1);
        PTFocusTaskEntry *entry = [b planTaskEntry:m_task title:@"  甲  "];
        QVERIFY(entry.valid && entry.autoStart && entry.usePomodoro); QVERIFY([entry.title isEqualToString:@"甲"]);
        settings->setQuickStartEnabled(false); settings->setLastMode(0);
        entry = [b planTaskEntry:m_task title:@"甲"]; QVERIFY(entry.valid && !entry.autoStart && !entry.usePomodoro);
        FocusTimer::instance()->setFreeTimingAllowed(false); QVERIFY([b planTaskEntry:m_task title:@"甲"].usePomodoro);
        FocusTimer::instance()->setFreeTimingAllowed(true);
        QVERIFY([b startFree:m_task title:@"桥接甲" error:&error]);
        QVERIFY([[b planTaskEntry:m_task title:@"甲"].kind isEqualToString:@"returnToCurrent"]);
        QVERIFY([[b planTaskEntry:m_task + 1 title:@"乙"].kind isEqualToString:@"confirmSwitch"]);
        PTFocusSwitchConsequence *c = b.switchConsequence; QVERIFY(c.valid); QCOMPARE(c.minimumMinutes, NSInteger(3));
        QVERIFY([c.kind isEqualToString:@"notSaved"]); m_clock.advance(180); QVERIFY([b.switchConsequence.kind isEqualToString:@"saved"]);
        PTFocusModeSwitch *mode = [b planModeSwitch:-1 title:@""];
        QVERIFY(mode.valid); QCOMPARE(mode.taskId, NSInteger(m_task)); QVERIFY([mode.title isEqualToString:@"桥接甲"]); QVERIFY([mode.kind isEqualToString:@"confirmSwitch"]);
        PTFocusSwitchSource *source = b.captureSwitchSource;
        QVERIFY(source.valid); QCOMPARE(source.taskId, NSInteger(m_task)); QCOMPARE(source.mode, NSInteger(0)); QCOMPARE(source.phase, NSInteger(0));
        QVERIFY([b.endCurrent.result isEqualToString:@"ended"]);
        QVERIFY([[b stopForSwitch:source error:&error] isEqualToString:@"stateChanged"]);
        QVERIFY([[b planModeSwitch:-1 title:@""].kind isEqualToString:@"pageOnly"]);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]);
        QVERIFY([[b stopForSwitch:b.captureSwitchSource error:&error] isEqualToString:@"stopped"]);
        QVERIFY([b startBreak:300 taskId:m_task title:@"甲" error:&error]); QVERIFY([b.switchConsequence.kind isEqualToString:@"restKept"]);
    }
}
// 产品保证：三种结束、超长确认、原时长与修正和丢弃都保持控制器语义，不被桥接合并分支。
void PTFocusBridgeTests::endAndLongFreeBranches() {
    @autoreleasepool {
        PTFocusBridge *b = [PTFocusBridge new]; NSError *error = nil;
        QVERIFY(b.endCurrent.valid); QVERIFY([b.endCurrent.result isEqualToString:@"none"]);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]);
        PTFocusEndResult *end = b.endCurrent; QVERIFY([end.result isEqualToString:@"ended"] && [end.kind isEqualToString:@"free"]); QVERIFY(end.discarded);
        AppSettings::instance()->setFreeTimerWarningHours(1);
        QCOMPARE([b freeTimerWarningHours:&error], NSInteger(1));
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(3601);
        QVERIFY([b needsLongFreeStopConfirmation:&error]);
        QVERIFY([[b stopForSwitch:b.captureSwitchSource error:&error] isEqualToString:@"needsLongFreeConfirmation"]);
        QVERIFY([b.endCurrent.result isEqualToString:@"needsConfirmation"]); QVERIFY(b.snapshot.hasActiveSession);
        PTFocusFinishResult *finish = [b finishLongFree:YES correctedSeconds:181]; QVERIFY(finish.valid && finish.ok); QVERIFY([finish.error isEqualToString:@""]);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(3601);
        QVERIFY([b finishLongFree:NO correctedSeconds:0].ok);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(180);
        QVERIFY([b finishLongFree:YES correctedSeconds:0].ok);
        QVERIFY([b startPomodoro:m_task title:@"甲" seconds:180 error:&error]); m_clock.advance(180);
        FocusSessionControllerTests::expire(false); QCOMPARE(b.snapshot.completedPomodoros, NSInteger(1));
        end = b.endPomodoroCycle; QVERIFY([end.result isEqualToString:@"ended"] && [end.kind isEqualToString:@"pomodoro"]);
        QCOMPARE(b.snapshot.completedPomodoros, NSInteger(0));
        QVERIFY(FocusTimer::instance()->startManualRest()); m_clock.advance(7);
        end = b.endCurrent; QVERIFY([end.result isEqualToString:@"ended"] && [end.kind isEqualToString:@"manualRest"]);
    }
}
// 产品保证：候选保留 stale 标记、创建按返回编号而非标题反查，完成结果四分支原样投影。
void PTFocusBridgeTests::candidateCreationAndTaskCompletion() {
    @autoreleasepool {
        PTFocusBridge *b = [PTFocusBridge new]; NSError *error = nil;
        PTFocusCandidate *candidate = [b autoStartCandidate:123456 title:@"被删" ];
        QVERIFY(candidate.valid && candidate.selectionStale); QCOMPARE(candidate.taskId, NSInteger(m_task)); QVERIFY([candidate.title isEqualToString:@"桥接甲"]);
        NSInteger newId = [b createTodayTask:@"  桥接甲  " error:&error]; QVERIFY(newId > 0 && newId != m_task); QVERIFY(error == nil);
        QCOMPARE([b createTodayTask:@"  " error:&error], NSInteger(-1)); QVERIFY(error != nil); error = nil;
        candidate = [b autoStartCandidate:newId title:@"桥接甲"]; QCOMPARE(candidate.taskId, newId); QVERIFY(!candidate.selectionStale);
        QVERIFY([[b handleTaskCompleted:m_task].focusResult isEqualToString:@"none"]);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]);
        PTFocusTaskCompletion *completed = [b handleTaskCompleted:m_task]; QVERIFY(completed.valid && completed.discarded);
        QVERIFY([completed.focusResult isEqualToString:@"ended"] && [completed.kind isEqualToString:@"free"]);
        AppSettings::instance()->setFreeTimerWarningHours(1);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(3601);
        completed = [b handleTaskCompleted:m_task]; QVERIFY([completed.focusResult isEqualToString:@"needsConfirmation"]);
        QSqlQuery q(DatabaseManager::instance()->database()); QVERIFY(q.exec("CREATE TRIGGER reject_stop BEFORE UPDATE ON focus_sessions BEGIN SELECT RAISE(ABORT, '失败'); END"));
        QVERIFY([b finishLongFree:YES correctedSeconds:180].ok == NO);
        QVERIFY(q.exec("DROP TRIGGER reject_stop"));
        QVERIFY([b finishLongFree:NO correctedSeconds:0].ok);
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(180);
        QVERIFY(q.exec("CREATE TRIGGER reject_stop BEFORE UPDATE ON focus_sessions BEGIN SELECT RAISE(ABORT, '失败'); END"));
        completed = [b handleTaskCompleted:m_task]; QVERIFY([completed.focusResult isEqualToString:@"failed"]);
        QVERIFY([completed.error containsString:@"结束专注失败：失败"]);
    }
}
// 产品保证：页面实际使用的计时动作能把参数或服务状态原因交给 Swift。
void PTFocusBridgeTests::actionRejectionKeepsSpecificReason_data()
{
    QTest::addColumn<QString>("action");
    QTest::addColumn<QString>("expected");
    for (const QString& action : {QStringLiteral("free"), QStringLiteral("pomodoro"), QStringLiteral("break")})
        QTest::newRow(qPrintable(action)) << action << QStringLiteral("专注参数越界");
    QTest::newRow("create") << QStringLiteral("create") << QStringLiteral("专注控制器不可用");
    QTest::newRow("resume") << QStringLiteral("resume") << QStringLiteral("没有进行中的专注或休息，无法继续");
}

// 产品保证：专注动作失败返回的 NSError 保留具体原因，调用方认领后不再回调背景失败。
void PTFocusBridgeTests::actionRejectionKeepsSpecificReason()
{
    @autoreleasepool {
        QFETCH(QString, action);
        QFETCH(QString, expected);
        PTFocusBridge* bridge = [PTFocusBridge new];
        __block int failures = 0;
        bridge.onFailure = ^(NSString*) { ++failures; };
        NSError* error = nil;
        if (action == QStringLiteral("free")) QVERIFY(![bridge startFree:NSIntegerMax title:@"任务" error:&error]);
        else if (action == QStringLiteral("pomodoro")) QVERIFY(![bridge startPomodoro:m_task title:@"任务" seconds:NSIntegerMax error:&error]);
        else if (action == QStringLiteral("break")) QVERIFY(![bridge startBreak:NSIntegerMax taskId:m_task title:@"任务" error:&error]);
        else if (action == QStringLiteral("create")) {
            m_controller.reset();
            QCOMPARE([bridge createTodayTask:@"草稿" error:&error], NSInteger(-1));
        } else {
            QVERIFY(!FocusTimer::instance()->hasActiveSession());
            QVERIFY(![bridge resume:&error]);
        }
        QVERIFY(error != nil);
        QCOMPARE(QString::fromNSString(error.localizedDescription), expected);
        QCOMPARE(failures, 0);
    }
}

// 产品保证：调用期错误只归当前返回值，宽整数越界不截断；登记失效后安全报错而非使用悬空指针。
void PTFocusBridgeTests::failuresAndMissingController() {
    @autoreleasepool {
        PTFocusBridge *b = [PTFocusBridge new]; __block int background = 0;
        b.onFailure = ^(NSString *) { ++background; }; NSError *error = nil;
        QVERIFY(![b startFree:NSIntegerMax title:@"甲" error:&error]); QVERIFY(error != nil); error = nil;
        QVERIFY(![b startPomodoro:m_task title:@"甲" seconds:NSIntegerMax error:&error]); QVERIFY(error != nil); error = nil;
        QVERIFY(![b startFree:123456 title:@"不存在" error:&error]); QVERIFY(error != nil); QCOMPARE(background, 0); error = nil;
        QVERIFY([b startFree:m_task title:@"甲" error:&error]); m_clock.advance(180);
        QSqlQuery q(DatabaseManager::instance()->database()); QVERIFY(q.exec("CREATE TRIGGER reject_stop BEFORE UPDATE ON focus_sessions BEGIN SELECT RAISE(ABORT, '失败'); END"));
        PTFocusEndResult *end = b.endCurrent; QVERIFY(end.valid); QVERIFY([end.result isEqualToString:@"failed"]); QVERIFY([end.error containsString:@"结束专注失败：失败"]); QCOMPARE(background, 0);
        QVERIFY([b stopForSwitch:b.captureSwitchSource error:&error] == nil);
        QVERIFY([error.localizedDescription containsString:@"结束专注失败：失败"]); error = nil;
        PTFocusFinishResult *finish = [b finishLongFree:YES correctedSeconds:180]; QVERIFY(!finish.ok); QVERIFY([finish.error containsString:@"结束专注失败：失败"]);
        QVERIFY(q.exec("DROP TRIGGER reject_stop"));
        QVERIFY(q.exec("CREATE TRIGGER reject_discard BEFORE DELETE ON focus_sessions BEGIN SELECT RAISE(ABORT, '失败'); END"));
        finish = [b finishLongFree:NO correctedSeconds:0]; QVERIFY(!finish.ok); QVERIFY([finish.error isEqualToString:@"专注丢弃失败，请重试"]);
        emit TaskManager::instance()->operationFailed(QStringLiteral("其它页面的任务失败")); QCOMPARE(background, 0);
        emit FocusTimer::instance()->operationFailed(QStringLiteral("背景失败")); QCOMPARE(background, 1);
        m_controller.reset(); QVERIFY(!b.endCurrent.valid); QVERIFY([b.endCurrent.error isEqualToString:@"专注控制器不可用"]);
        QVERIFY(![b planTaskEntry:m_task title:@"甲"].valid); QVERIFY(!b.captureSwitchSource.valid);
        QVERIFY(![b planModeSwitch:m_task title:@"甲"].valid); QVERIFY(![b autoStartCandidate:m_task title:@"甲"].valid);
        QVERIFY(![b handleTaskCompleted:m_task].valid); QVERIFY(![b finishLongFree:YES correctedSeconds:0].valid);
        QCOMPARE([b freeTimerWarningHours:&error], NSInteger(0)); QVERIFY(error != nil);
    }
}
// 产品保证：长休息时长与自动衔接原样转发控制器的判定（判定表在 FocusSessionControllerTests）：
// 所选休息时长原样传进去，两个开关各管各的阶段；控制器不可用时报错而不是给默认值。
void PTFocusBridgeTests::breakAndAutoAdvanceForwardController() {
    @autoreleasepool {
        PTFocusBridge *b = [PTFocusBridge new]; NSError *error = nil;
        AppSettings::instance()->setLongBreakEnabled(false);
        QCOMPARE([b nextBreakMinutes:13 error:&error], NSInteger(13)); QVERIFY(error == nil);
        AppSettings::instance()->setAutoStartBreak(true);
        AppSettings::instance()->setAutoStartNextPomodoro(false);
        QVERIFY([b autoAdvanceAfterPhase:1 error:&error]); QVERIFY(error == nil);
        QVERIFY(![b autoAdvanceAfterPhase:2 error:&error]); QVERIFY(error == nil);
        AppSettings::instance()->setAutoStartBreak(false);
        AppSettings::instance()->setAutoStartNextPomodoro(true);
        QVERIFY(![b autoAdvanceAfterPhase:1 error:&error]);
        QVERIFY([b autoAdvanceAfterPhase:2 error:&error]); QVERIFY(error == nil);
        m_controller.reset();
        QCOMPARE([b nextBreakMinutes:13 error:&error], NSInteger(0)); QVERIFY(error != nil); error = nil;
        QVERIFY(![b autoAdvanceAfterPhase:2 error:&error]); QVERIFY(error != nil);
    }
}
// 产品保证：全部计时信号的载荷保留，桥接释放后无保留环且不再回调。
void PTFocusBridgeTests::allSignalsAndLifetime() {
    @autoreleasepool {
        __block int plain = 0; __block NSInteger focus = -1, phase = -1, discarded = -1, offline = -1, failedTask = -1;
        __weak PTFocusBridge *released;
        auto *timer = FocusTimer::instance();
        {
            PTFocusBridge *b = [PTFocusBridge new]; released = b;
            b.onTick = ^{ ++plain; }; b.onRunningStateChanged = ^{ ++plain; }; b.onPhaseChanged = ^{ ++plain; };
            b.onModeChanged = ^{ ++plain; }; b.onCurrentTaskChanged = ^{ ++plain; }; b.onRestCompleted = ^{ ++plain; };
            b.onCompletedPomodorosChanged = ^{ ++plain; }; b.onSessionLogicalDateChanged = ^{ ++plain; };
            b.onFreeTimingAllowedChanged = ^{ ++plain; }; b.onManualRestAllowedChanged = ^{ ++plain; };
            b.onFocusCompleted = ^(NSInteger v) { focus = v; }; b.onPhaseCompleted = ^(NSInteger v) { phase = v; };
            b.onSessionDiscarded = ^(NSInteger v) { discarded = v; }; b.onPhaseSettledOffline = ^(NSInteger v) { offline = v; };
            b.onTaskAutoCompleteFailed = ^(NSInteger v) { failedTask = v; };
            emit timer->tick(); emit timer->runningStateChanged(); emit timer->phaseChanged(); emit timer->modeChanged(); emit timer->currentTaskChanged();
            emit timer->restCompleted(); emit timer->completedPomodorosChanged(); emit timer->sessionLogicalDateChanged(); emit timer->freeTimingAllowedChanged(); emit timer->manualRestAllowedChanged();
            emit timer->focusCompleted(243); emit timer->phaseCompleted(2); emit timer->sessionDiscarded(119); emit timer->phaseSettledOffline(1); emit timer->taskAutoCompleteFailed(m_task);
            QCOMPARE(plain, 10); QCOMPARE(focus, NSInteger(243)); QCOMPARE(phase, NSInteger(2)); QCOMPARE(discarded, NSInteger(119)); QCOMPARE(offline, NSInteger(1)); QCOMPARE(failedTask, NSInteger(m_task));
        }
        QVERIFY(released == nil); emit timer->tick(); QCOMPARE(plain, 10);
    }
}
// 产品保证：后台发出的计时与缺口信号排队回主线程，释放前未处理的回调不会越过生命周期。
void PTFocusBridgeTests::backgroundSignalsReturnToMain() {
    @autoreleasepool {
        __block int count = 0; __block bool main = true;
        PTFocusBridge *focus = [PTFocusBridge new]; PTGapReminderBridge *gap = [PTGapReminderBridge new];
        focus.onTick = ^{ ++count; main = main && NSThread.isMainThread; };
        gap.onChanged = ^{ ++count; main = main && NSThread.isMainThread; };
        std::unique_ptr<QThread> worker(QThread::create([] { emit FocusTimer::instance()->tick(); emit KnowledgeGapService::instance()->gapsChanged(); }));
        worker->start(); QVERIFY(worker->wait()); QTRY_COMPARE(count, 2); QVERIFY(main);
        __weak PTGapReminderBridge *released = gap; gap = nil; QVERIFY(released == nil);
        emit KnowledgeGapService::instance()->gapsChanged(); QCOMPARE(count, 2);
    }
}
// 产品保证：到点提醒没预约成功、系统通知没发出这两类失败原样转给界面做前台提示；
// 预约协调器没登记（Mac 不创建它）时只转通知失败，桥接释放后不再回调。
void PTFocusBridgeTests::reminderFailureSignals() {
    @autoreleasepool {
        NotificationService notifications;
        PhaseAlarmCoordinator alarms(FocusTimer::instance(), &notifications);
        __block NSString *alarmReason = nil, *deliveryReason = nil; __block int alarmCount = 0, deliveryCount = 0;
        // 先不登记协调器：只应收到通知失败，预约失败的信号没有来源。
        __weak PTFocusBridge *released;
        {
            PTFocusBridge *without = [PTFocusBridge new]; released = without;
            without.onAlarmUnavailable = ^(NSString *r) { alarmReason = r; ++alarmCount; };
            without.onNotificationDeliveryFailed = ^(NSString *r) { deliveryReason = r; ++deliveryCount; };
            emit alarms.alarmUnavailable(QStringLiteral("未登记"));
            QCOMPARE(alarmCount, 0);
            emit NotificationService::instance()->notificationDeliveryFailed(QStringLiteral("没有权限"));
            QCOMPARE(deliveryCount, 1); QVERIFY([deliveryReason isEqualToString:@"没有权限"]);
        }
        QVERIFY(released == nil);
        emit NotificationService::instance()->notificationDeliveryFailed(QStringLiteral("释放后"));
        QCOMPARE(deliveryCount, 1);
        PTBridgeSupport::registerService(QStringLiteral("phaseAlarms"), &alarms);
        PTFocusBridge *with = [PTFocusBridge new];
        with.onAlarmUnavailable = ^(NSString *r) { alarmReason = r; ++alarmCount; };
        with.onNotificationDeliveryFailed = ^(NSString *r) { deliveryReason = r; ++deliveryCount; };
        emit alarms.alarmUnavailable(QStringLiteral("通知权限未开"));
        QCOMPARE(alarmCount, 1); QVERIFY([alarmReason isEqualToString:@"通知权限未开"]);
        emit NotificationService::instance()->notificationDeliveryFailed(QStringLiteral("系统拒绝"));
        QCOMPARE(deliveryCount, 2); QVERIFY([deliveryReason isEqualToString:@"系统拒绝"]);
        with = nil;
        emit alarms.alarmUnavailable(QStringLiteral("释放后"));
        QCOMPARE(alarmCount, 1);
        PTBridgeSupport::registerService(QStringLiteral("phaseAlarms"), nullptr);
    }
}
// 产品保证：提醒五个数字与转换计数来自服务，转任务后两个变化信号都有投递。
void PTFocusBridgeTests::gapSummaryAndConversion() {
    @autoreleasepool {
        auto *service = KnowledgeGapService::instance(); const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        QVERIFY(service->addGap(QStringLiteral("今天"), -1, "", 0, today, -1) > 0);
        QVERIFY(service->addGap(QStringLiteral("逾期"), -1, "", 0, today.addDays(-4), -1) > 0);
        QVERIFY(service->captureGap(QStringLiteral("未排期"), -1, -1) > 0);
        PTGapReminderBridge *b = [PTGapReminderBridge new]; __block int changed = 0, affected = 0;
        b.onChanged = ^{ ++changed; }; b.onTasksAffected = ^{ ++affected; };
        PTGapReminderSummary *summary = b.reminderSummary; QVERIFY(summary.valid); QCOMPARE(summary.dueToday, NSInteger(1)); QCOMPARE(summary.overdue, NSInteger(1));
        QCOMPARE(summary.unscheduled, NSInteger(1)); QCOMPARE(summary.openTotal, NSInteger(3)); QCOMPARE(summary.oldestOverdueDays, NSInteger(4));
        PTGapConversionResult *result = b.convertDueGapsToTasks; QVERIFY(result.valid); QCOMPARE(result.converted, NSInteger(2)); QCOMPARE(result.failed, NSInteger(0)); QVERIFY([result.reason isEqualToString:@""]);
        QCOMPARE(changed, 2); QCOMPARE(affected, 2);
    }
}
// 产品保证：批量部分失败仍保留已成功任务与失败原因，读取失败不伪装成零条提醒。
void PTFocusBridgeTests::gapPartialFailureAndReadFailure() {
    @autoreleasepool {
        auto *service = KnowledgeGapService::instance(); const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        QVERIFY(service->addGap(QStringLiteral("成功"), -1, "", 0, today, -1) > 0);
        QVERIFY(service->addGap(QStringLiteral("失败"), -1, "", 0, today, -1) > 0);
        QSqlQuery q(DatabaseManager::instance()->database()); QVERIFY(q.exec("CREATE TRIGGER reject_gap BEFORE INSERT ON tasks WHEN NEW.title = '失败' BEGIN SELECT RAISE(ABORT, '拒绝第二条'); END"));
        PTGapReminderBridge *b = [PTGapReminderBridge new]; __block int failures = 0; b.onFailure = ^(NSString *) { ++failures; };
        PTGapConversionResult *result = b.convertDueGapsToTasks;
        QVERIFY(result.valid); QCOMPARE(result.converted, NSInteger(1)); QCOMPARE(result.failed, NSInteger(1)); QVERIFY(result.reason.length > 0); QCOMPARE(failures, 0);
        const auto tasks = TaskManager::instance()->getTodayTasks(); QCOMPARE(tasks.size(), 2);
        QVERIFY(q.exec("DROP TABLE knowledge_gaps"));
        PTGapReminderSummary *summary = b.reminderSummary; QVERIFY(!summary.valid); QVERIFY(summary.error.length > 0); QCOMPARE(failures, 0);
        result = b.convertDueGapsToTasks; QVERIFY(!result.valid); QVERIFY(result.error.length > 0);
        emit service->operationFailed(QStringLiteral("异步失败")); QCOMPARE(failures, 1);
    }
}
// 产品保证：缺口转换的部分失败由汇总返回给调用方，外壳不重复显示同一条失败。
void PTFocusBridgeTests::partialGapFailureIsClaimedByReturnedSummary()
{
    @autoreleasepool {
        QObject owner;
        int unclaimed = 0;
        PTBridgeSupport::registerUnclaimedFailureHandler(&owner, [&](const QString&) { ++unclaimed; });
        const auto unregister = qScopeGuard([&] { PTBridgeSupport::unregisterUnclaimedFailureHandler(&owner); });
        auto* gaps = KnowledgeGapService::instance();
        const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
        QVERIFY(gaps->addGap(QStringLiteral("认领成功"), -1, "", 0, today, -1) > 0);
        QVERIFY(gaps->addGap(QStringLiteral("认领失败"), -1, "", 0, today, -1) > 0);
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec("CREATE TRIGGER reject_claimed_gap BEFORE INSERT ON tasks WHEN NEW.title = '认领失败' BEGIN SELECT RAISE(ABORT, '第二条失败'); END"));
        const auto removeTrigger = qScopeGuard([&] { query.exec("DROP TRIGGER reject_claimed_gap"); });
        PTGapReminderBridge* bridge = [PTGapReminderBridge new];
        QSignalSpy failuresSpy(gaps, &KnowledgeGapService::operationFailed);
        const auto result = bridge.convertDueGapsToTasks;
        QVERIFY(result.valid);
        QCOMPARE(result.converted, NSInteger(1));
        QCOMPARE(result.failed, NSInteger(1));
        QVERIFY(result.reason.length > 0);
        QVERIFY(failuresSpy.count() > 0);
        QCOMPARE(unclaimed, 0);
    }
}


// 产品保证：专注启动、停表和新建失败时，调用方拿到具体原因，旁观桥接和外壳不重复收到。
void PTFocusBridgeTests::focusActionReasonsAreClaimed_data()
{
    QTest::addColumn<QString>("action");
    for (const QString& action : QStringList{"free", "pomodoro", "break", "switch", "create", "blank"})
        QTest::newRow(qPrintable(action)) << action;
}

// 产品保证：当前失败只归本次调用，失败计时不结束，新建失败不留下任务。
void PTFocusBridgeTests::focusActionReasonsAreClaimed()
{
    @autoreleasepool {
        QFETCH(QString, action);
        PTFocusBridge* bridge = [PTFocusBridge new]; PTFocusBridge* observer = [PTFocusBridge new];
        __block int ownerFailures = 0, observerFailures = 0;
        bridge.onFailure = ^(NSString*) { ++ownerFailures; }; observer.onFailure = ^(NSString*) { ++observerFailures; };
        QObject shell; int shellFailures = 0;
        PTBridgeSupport::registerUnclaimedFailureHandler(&shell, [&](const QString&) { ++shellFailures; });
        const auto cleanup = qScopeGuard([&] { PTBridgeSupport::unregisterUnclaimedFailureHandler(&shell); });
        if (action == "switch") { QVERIFY(FocusTimer::instance()->startFocus(m_task, "桥接甲")); m_clock.advance(240); }
        if (action != "blank") DatabaseManager::instance()->close();
        NSError* error = nil;
        if (action == "free") QVERIFY(![bridge startFree:m_task title:@"桥接甲" error:&error]);
        else if (action == "pomodoro") QVERIFY(![bridge startPomodoro:m_task title:@"桥接甲" seconds:1500 error:&error]);
        else if (action == "break") QVERIFY(![bridge startBreak:300 taskId:m_task title:@"桥接甲" error:&error]);
        else if (action == "switch") {
            QVERIFY([bridge stopForSwitch:bridge.captureSwitchSource error:&error] == nil);
            QVERIFY(FocusTimer::instance()->hasActiveSession());
        } else QCOMPARE([bridge createTodayTask:action == "blank" ? @"  " : @"新任务" error:&error], NSInteger(-1));
        QVERIFY(error != nil);
        QVERIFY2([error.localizedDescription containsString:action == "blank" ? @"标题" : @"数据库未打开"], error.localizedDescription.UTF8String);
        QCOMPARE(ownerFailures, 0); QCOMPARE(observerFailures, 0); QCOMPARE(shellFailures, 0);
    }
}


// 产品保证：专注桥接旁观到待删失败时不把原因塞进另一接口的调用，标题提示仍由待删槽负责。
void PTFocusBridgeTests::pendingDeletionDoesNotPolluteAnotherCall()
{
    @autoreleasepool {
        PTFocusBridge* bridge = [PTFocusBridge new]; __block int failures = 0;
        bridge.onFailure = ^(NSString*) { ++failures; };
        QVERIFY(m_pending->requestTask(m_task, "原标题"));
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec("CREATE TEMP TRIGGER t33_failure BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT, 'T33-2 focus observer blocked'); END"));
        QSignalSpy pendingFailure(m_pending.get(), &PendingDeletion::commitFailed);
        PTBridgeSupport::FailureCollector unrelated;
        PTBridgeSupport::FailureCollector::Call call(unrelated);
        QVERIFY(!m_pending->commit());
        const QString error = call.error();
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QCOMPARE(pendingFailure.count(), 1); QCOMPARE(failures, 0);
    }
}

QTEST_GUILESS_MAIN(PTFocusBridgeTests)
#include "PTFocusBridgeTests.moc"
