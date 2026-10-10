#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/DatabaseManager.h"
// FocusTimer 声明 friend class PhaseAlarmCoordinatorTests，测试可注入时钟并直接触发 tick。
#include "../src/services/FocusTimer.h"
#include "../src/services/MonotonicClock.h"
#include "../src/services/AppSettings.h"
#include "../src/services/NotificationService.h"
#include "../src/services/PhaseAlarmCoordinator.h"
#include "../src/services/PhaseCompletionNotifier.h"

namespace {

class FakeMonotonicClock : public MonotonicClock
{
public:
    qint64 ns = 0;
    void advanceSecs(qint64 s) { ns += s * 1000000000LL; }
    qint64 nowNsecs() const override { return ns; }
};

// 假通知后端：预约与撤销都不立刻回调，由测试决定系统「什么时候、以什么结果」答复，
// 用来构造迟到回调、乱序完成等真实系统里难以稳定复现的时序。
// 同时模拟系统里「尚未投递的预约」集合，检验最终留下的是哪几条。
class FakeBackend : public NotificationBackend
{
public:
    struct Call {
        QString kind; // "schedule" 或 "cancel"
        QString id;   // 预约的 id，或撤销的前缀
        int fireAfterSeconds = 0;
        QString title;
        ScheduleCallback callback;
    };

    // 即时投递的内容；failDeliver 为真时系统「拒收」，用来验证提示音兜底。
    struct Delivery {
        QString title;
        QString body;
        bool playSound = false;
    };

    QList<Call> calls;
    QSet<QString> pending;
    int deliverCount = 0;
    QList<Delivery> delivered;
    bool failDeliver = false;

    void deliver(const QString& title, const QString& body, bool playSound, DeliveryCallback callback) override
    {
        ++deliverCount;
        delivered.append({title, body, playSound});
        callback(!failDeliver, failDeliver ? QStringLiteral("测试拒收") : QString());
    }
    bool isAuthorized() const override { return true; }
    void requestAuthorization() override {}

    void schedule(const QString& id, int fireAfterSeconds, const QString& title, const QString&,
                  bool, ScheduleCallback callback) override
    {
        calls.append({QStringLiteral("schedule"), id, fireAfterSeconds, title, std::move(callback)});
    }
    void cancelScheduled(const QString& prefix, const QString& keepId, ScheduleCallback callback) override
    {
        Q_UNUSED(keepId);
        calls.append({QStringLiteral("cancel"), prefix, 0, QString(), std::move(callback)});
    }

    // 以 success 答复第 index 次调用，并按结果更新「待投递」集合。
    void answer(int index, bool success, const QString& reason = QString())
    {
        Call& call = calls[index];
        if (success && call.kind == QLatin1String("schedule")) {
            pending.insert(call.id);
        } else if (success && call.kind == QLatin1String("cancel")) {
            for (auto it = pending.begin(); it != pending.end();) {
                it = it->startsWith(call.id) ? pending.erase(it) : std::next(it);
            }
        }
        call.callback(success, reason);
    }
};

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

} // namespace

class PhaseAlarmCoordinatorTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void startupCleansLeftoversBeforeScheduling();
    void operationsRunOneAtATime();
    void naturalExpiryDoesNotCancel();
    void offlineSettlementDoesNotCancel();
    void pauseCancelsAndResumeReschedules();
    void quickStartPauseResumeLeavesOnlyNewestAlarm();
    void lateCallbackOfOldGenerationDoesNotMarkCurrent();
    void scheduleFailureFallsBackToImmediateDelivery();
    void coveredExpiryDoesNotDeliverTwice();
    void stopBeforeExpiryCancels();
    void alreadyExpiredSegmentIsNotScheduled();
    void workCompletionNotifiesNextBreakKind();
    void breakCompletionRemembersLongBreakAndFallsBackToChime();

private:
    void tick() { QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection)); }
    // 协调器的对账与回调都排队到事件循环的下一轮；这里把排队的事件处理完。
    void settle() { QCoreApplication::processEvents(); QCoreApplication::processEvents(); }
    int startPomodoro(int minutes)
    {
        const int taskId = insertTask(QStringLiteral("预约测试"));
        if (!FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("预约测试"), minutes * 60)) {
            return -1;
        }
        return taskId;
    }

    QTemporaryDir* m_tempDir = nullptr;
    FakeMonotonicClock m_clock;
    FakeBackend* m_backend = nullptr;
    NotificationService* m_service = nullptr;
    PhaseAlarmCoordinator* m_coordinator = nullptr;
};

void PhaseAlarmCoordinatorTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("alarms.sqlite")));
    m_clock.ns = 0;
    FocusTimer::instance()->m_clock = &m_clock;

    m_backend = new FakeBackend();
    m_service = new NotificationService();
    m_service->setBackend(m_backend);
    m_coordinator = new PhaseAlarmCoordinator(FocusTimer::instance(), m_service);
    // 与 main.cpp 的移动端装配一致：到点提醒是否已由预约覆盖，由协调器回答。
    PhaseAlarmCoordinator* coordinator = m_coordinator;
    m_service->setPhaseAlarmCoverage([coordinator](int phase) { return coordinator->coversPhase(phase); });
}

void PhaseAlarmCoordinatorTests::cleanup()
{
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    FocusTimer::instance()->m_clock = SystemMonotonicClock::instance();
    delete m_coordinator;
    m_coordinator = nullptr;
    delete m_service;
    m_service = nullptr;
    delete m_backend;
    m_backend = nullptr;
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void PhaseAlarmCoordinatorTests::startupCleansLeftoversBeforeScheduling()
{
    // 上一个进程遗留的预约（被系统结束前来不及撤销）。
    m_backend->pending.insert(PhaseAlarmCoordinator::idPrefix() + QStringLiteral("old-1"));
    QVERIFY(startPomodoro(25) > 0);
    m_coordinator->start();
    settle();

    // 第一步一定是撤销遗留，预约要等撤销答复之后才发出。
    QCOMPARE(m_backend->calls.size(), 1);
    QCOMPARE(m_backend->calls.at(0).kind, QStringLiteral("cancel"));
    m_backend->answer(0, true);
    settle();
    QCOMPARE(m_backend->calls.size(), 2);
    QCOMPARE(m_backend->calls.at(1).kind, QStringLiteral("schedule"));
    QCOMPARE(m_backend->calls.at(1).fireAfterSeconds, 25 * 60);
    QCOMPARE(m_backend->calls.at(1).title, QStringLiteral("专注完成"));
    m_backend->answer(1, true);
    settle();
    QVERIFY(m_coordinator->currentAlarmScheduled());
    QCOMPARE(m_backend->pending.size(), 1);
}

void PhaseAlarmCoordinatorTests::operationsRunOneAtATime()
{
    m_coordinator->start();
    settle();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    // 撤销还没答复：即使对账已经要求预约，也不能同时交给系统。
    QCOMPARE(m_backend->calls.size(), 1);
    m_backend->answer(0, true);
    settle();
    QCOMPARE(m_backend->calls.size(), 2);
}

void PhaseAlarmCoordinatorTests::naturalExpiryDoesNotCancel()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, true);
    settle();
    const qsizetype callsBefore = m_backend->calls.size();

    m_clock.advanceSecs(25 * 60);
    tick();
    settle();

    // 自然到点：预约的那条就是这次提醒，此时撤销可能删掉还没来得及投递的它。
    QCOMPARE(m_backend->calls.size(), callsBefore);
    QCOMPARE(m_backend->pending.size(), 1);
    QVERIFY(!m_coordinator->currentAlarmScheduled());
}

void PhaseAlarmCoordinatorTests::offlineSettlementDoesNotCancel()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, true);
    settle();
    const qsizetype callsBefore = m_backend->calls.size();

    // 离线结算同样是「到点了」，与自然到点一样不撤销。
    emit FocusTimer::instance()->phaseSettledOffline(FocusTimer::WorkPhase);
    FocusTimer::instance()->resetSession();
    emit FocusTimer::instance()->runningStateChanged();
    settle();
    QCOMPARE(m_backend->calls.size(), callsBefore);
}

void PhaseAlarmCoordinatorTests::pauseCancelsAndResumeReschedules()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, true);
    settle();

    m_clock.advanceSecs(10 * 60);
    QVERIFY(FocusTimer::instance()->pauseFocus());
    settle();
    QCOMPARE(m_backend->calls.last().kind, QStringLiteral("cancel"));
    m_backend->answer(static_cast<int>(m_backend->calls.size()) - 1, true);
    settle();
    QVERIFY(m_backend->pending.isEmpty());
    QVERIFY(!m_coordinator->currentAlarmScheduled());

    // 暂停期间时间不计；继续后按剩余 15 分钟重新预约。
    m_clock.advanceSecs(60 * 60);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    settle();
    QCOMPARE(m_backend->calls.last().kind, QStringLiteral("schedule"));
    QCOMPARE(m_backend->calls.last().fireAfterSeconds, 15 * 60);
}

void PhaseAlarmCoordinatorTests::quickStartPauseResumeLeavesOnlyNewestAlarm()
{
    m_coordinator->start();
    settle();
    m_backend->answer(0, true); // 启动清理
    settle();

    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_clock.advanceSecs(2);
    QVERIFY(FocusTimer::instance()->pauseFocus());
    settle();
    m_clock.advanceSecs(1);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    settle();

    // 系统按顺序一个个答复；最后只能留下继续之后的那一条。
    for (int i = 1; i < m_backend->calls.size(); ++i) {
        m_backend->answer(i, true);
        settle();
    }
    QCOMPARE(m_backend->pending.size(), 1);
    QCOMPARE(*m_backend->pending.cbegin(), m_backend->calls.last().id);
    QCOMPARE(m_backend->calls.last().fireAfterSeconds, 25 * 60 - 2);
    QVERIFY(m_coordinator->currentAlarmScheduled());
}

void PhaseAlarmCoordinatorTests::lateCallbackOfOldGenerationDoesNotMarkCurrent()
{
    m_coordinator->start();
    settle();
    m_backend->answer(0, true);
    settle();

    QVERIFY(startPomodoro(25) > 0);
    settle();
    const int firstSchedule = static_cast<int>(m_backend->calls.size()) - 1;
    // 第一代预约还没答复，用户就暂停又继续：当前已换成第二代。
    QVERIFY(FocusTimer::instance()->pauseFocus());
    settle();
    m_clock.advanceSecs(5);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    settle();

    QSignalSpy unavailableSpy(m_coordinator, &PhaseAlarmCoordinator::alarmUnavailable);
    // 旧代次迟到的「成功」不能把当前状态置为已预约。
    m_backend->answer(firstSchedule, true);
    settle();
    QVERIFY(!m_coordinator->currentAlarmScheduled());

    // 随后的撤销与第二代预约按顺序执行；第二代失败，当前状态以它为准。
    m_backend->answer(firstSchedule + 1, true);
    settle();
    m_backend->answer(firstSchedule + 2, false, QStringLiteral("系统通知权限不可用"));
    settle();
    QVERIFY(!m_coordinator->currentAlarmScheduled());
    QVERIFY(!m_coordinator->coversPhase(FocusTimer::WorkPhase));
    QCOMPARE(unavailableSpy.count(), 1);
    QVERIFY(m_backend->pending.isEmpty());
}

void PhaseAlarmCoordinatorTests::scheduleFailureFallsBackToImmediateDelivery()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, false, QStringLiteral("系统通知权限不可用"));
    settle();

    m_clock.advanceSecs(25 * 60);
    tick();
    // 界面收到 phaseCompleted 后会请求即时提醒（PhaseCompletionCoordinator 的职责）。
    m_service->notifyPhaseComplete(FocusTimer::WorkPhase, 1, 5, false, true);
    // 预约没成功，不能当作已覆盖：照常即时投递，失败时还会走现有的降级提示。
    QCOMPARE(m_backend->deliverCount, 1);
}

void PhaseAlarmCoordinatorTests::coveredExpiryDoesNotDeliverTwice()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, true);
    settle();

    QSignalSpy suppressedSpy(m_service, &NotificationService::notificationSuppressed);
    m_clock.advanceSecs(25 * 60);
    tick();
    m_service->notifyPhaseComplete(FocusTimer::WorkPhase, 1, 5, false, true);
    // 系统预约的那条已经负责这次提醒；进程内不再即时投递第二条。
    QCOMPARE(m_backend->deliverCount, 0);
    QCOMPARE(suppressedSpy.count(), 1);
}

void PhaseAlarmCoordinatorTests::stopBeforeExpiryCancels()
{
    m_coordinator->start();
    QVERIFY(startPomodoro(25) > 0);
    settle();
    m_backend->answer(0, true);
    settle();
    m_backend->answer(1, true);
    settle();

    m_clock.advanceSecs(10 * 60);
    QVERIFY(FocusTimer::instance()->stopFocus());
    settle();
    QCOMPARE(m_backend->calls.last().kind, QStringLiteral("cancel"));
    m_backend->answer(static_cast<int>(m_backend->calls.size()) - 1, true);
    settle();
    QVERIFY(m_backend->pending.isEmpty());
}

void PhaseAlarmCoordinatorTests::alreadyExpiredSegmentIsNotScheduled()
{
    QVERIFY(startPomodoro(5) > 0);
    // 时钟越过到点但还没 tick（例如重启后恢复出一段已过期、等待离线结算的番茄）。
    m_clock.advanceSecs(6 * 60);
    m_coordinator->start();
    settle();
    m_backend->answer(0, true);
    settle();
    // 剩余时间为 0：只做启动清理，不预约一条会立刻响起的提醒。
    QCOMPARE(m_backend->calls.size(), 1);
}

void PhaseAlarmCoordinatorTests::workCompletionNotifiesNextBreakKind()
{
    // 保证：番茄自然完成时的即时通知说清下一段休息——连续数到了间隔的整数倍按长休息时长说「长休息」，
    // 否则按普通休息时长说；响铃跟随提示音设置。（原 QML PhaseCompletionCoordinator 的口径，055 下沉到 C++。）
    // 用独立的通知服务与临时设置文件，不受本文件预约协调器的覆盖判断影响。
    QTemporaryDir preferences;
    QVERIFY(preferences.isValid());
    AppSettings settings(preferences.filePath(QStringLiteral("settings.ini")));
    settings.setLongBreakEnabled(true);
    settings.setLongBreakInterval(2);
    settings.setLongBreakMinutes(20);
    settings.setBreakMinutes(7);
    settings.setSoundEnabled(true);
    FakeBackend backend;
    NotificationService service;
    service.setBackend(&backend);
    int chimes = 0;
    PhaseCompletionNotifier notifier(FocusTimer::instance(), &settings, &service, [&chimes] { ++chimes; return true; });

    // 完成后连续数 = 2：长休息。番茄要够 3 分钟，不足的会被当成无效丢弃、不计入连续数。
    FocusTimer::instance()->m_completedPomodoros = 1;
    QVERIFY(startPomodoro(5) > 0);
    m_clock.advanceSecs(5 * 60 + 1);
    tick();
    settle();
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 2);
    QString title;
    QString body;
    QVERIFY(NotificationService::phaseCompleteContent(1, 2, 20, true, &title, &body));
    QCOMPARE(backend.delivered.size(), 1);
    QCOMPARE(backend.delivered.at(0).title, title);
    QCOMPARE(backend.delivered.at(0).body, body);
    QVERIFY(backend.delivered.at(0).playSound);

    // 完成后连续数 = 3：普通休息，关了提示音就不响铃。
    FocusTimer::instance()->resetSession();
    settings.setSoundEnabled(false);
    QVERIFY(startPomodoro(5) > 0);
    m_clock.advanceSecs(5 * 60 + 1);
    tick();
    settle();
    QCOMPARE(FocusTimer::instance()->completedPomodoros(), 3);
    QVERIFY(NotificationService::phaseCompleteContent(1, 3, 7, false, &title, &body));
    QCOMPARE(backend.delivered.size(), 2);
    QCOMPARE(backend.delivered.at(1).body, body);
    QVERIFY(!backend.delivered.at(1).playSound);
    QCOMPARE(chimes, 0);
}

void PhaseAlarmCoordinatorTests::breakCompletionRemembersLongBreakAndFallsBackToChime()
{
    // 保证：长休息结束的通知说「长休息」——进入休息段时记下的口径，结束时计时器已空闲读不到目标时长；
    // 系统通知发不出去时用本地提示音兜底，关了提示音就不响；没有通知服务时直接响铃。
    QTemporaryDir preferences;
    QVERIFY(preferences.isValid());
    AppSettings settings(preferences.filePath(QStringLiteral("settings.ini")));
    settings.setLongBreakEnabled(true);
    settings.setLongBreakMinutes(20);
    settings.setSoundEnabled(true);
    FakeBackend backend;
    backend.failDeliver = true;
    NotificationService service;
    service.setBackend(&backend);
    int chimes = 0;
    PhaseCompletionNotifier notifier(FocusTimer::instance(), &settings, &service, [&chimes] { ++chimes; return true; });

    QVERIFY(FocusTimer::instance()->startBreakForTask(20 * 60, -1, QString()));
    m_clock.advanceSecs(20 * 60 + 1);
    tick();
    settle();
    QString title;
    QString body;
    QVERIFY(NotificationService::phaseCompleteContent(2, FocusTimer::instance()->completedPomodoros(), 0, true,
                                                      &title, &body));
    QCOMPARE(backend.delivered.size(), 1);
    // 长休息只体现在标题上（「长休息结束」），正文与普通休息相同，所以必须比标题。
    QCOMPARE(backend.delivered.at(0).title, QStringLiteral("长休息结束"));
    QCOMPARE(backend.delivered.at(0).title, title);
    QCOMPARE(backend.delivered.at(0).body, body);
    QCOMPARE(chimes, 1);

    // 普通休息（目标不是长休息时长）结束：按普通休息说；关了提示音，投递失败也不响。
    settings.setSoundEnabled(false);
    QVERIFY(FocusTimer::instance()->startBreakForTask(5 * 60, -1, QString()));
    m_clock.advanceSecs(5 * 60 + 1);
    tick();
    settle();
    QVERIFY(NotificationService::phaseCompleteContent(2, FocusTimer::instance()->completedPomodoros(), 0, false,
                                                      &title, &body));
    QCOMPARE(backend.delivered.size(), 2);
    QCOMPARE(backend.delivered.at(1).title, QStringLiteral("休息结束"));
    QCOMPARE(backend.delivered.at(1).body, body);
    QCOMPARE(chimes, 1);

    // 没有通知服务：直接用提示音。
    settings.setSoundEnabled(true);
    int directChimes = 0;
    PhaseCompletionNotifier bare(FocusTimer::instance(), &settings, nullptr, [&directChimes] { ++directChimes; return true; });
    QVERIFY(FocusTimer::instance()->startBreakForTask(5 * 60, -1, QString()));
    m_clock.advanceSecs(5 * 60 + 1);
    tick();
    settle();
    QCOMPARE(directChimes, 1);
}

QTEST_MAIN(PhaseAlarmCoordinatorTests)
#include "PhaseAlarmCoordinatorTests.moc"
