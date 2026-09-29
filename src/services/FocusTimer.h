#ifndef FOCUSTIMER_H
#define FOCUSTIMER_H

#include <QDateTime>
#include <QObject>
#include <QTimer>

class QSqlDatabase;
class MonotonicClock;
class ApplicationActivity;

class FocusTimer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY tick)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY runningStateChanged)
    Q_PROPERTY(bool hasActiveSession READ hasActiveSession NOTIFY currentTaskChanged)
    Q_PROPERTY(QString currentTaskTitle READ currentTaskTitle NOTIFY currentTaskChanged)
    Q_PROPERTY(int currentTaskId READ currentTaskId NOTIFY currentTaskChanged)
    Q_PROPERTY(int mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(int phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(int targetSeconds READ targetSeconds NOTIFY phaseChanged)
    Q_PROPERTY(int remainingSeconds READ remainingSeconds NOTIFY tick)
    Q_PROPERTY(int minimumValidMinutes READ minimumValidMinutes CONSTANT)
    // 本轮连续完成的番茄数（自然到点才计），供长休息判定“每 N 个后休息更久”。
    Q_PROPERTY(int completedPomodoros READ completedPomodoros NOTIFY completedPomodorosChanged)
    // 会话归属日由开始时刻与当前逻辑日边界共同决定，页面用它避免跨日重复累加。
    Q_PROPERTY(QString sessionLogicalDate READ sessionLogicalDate NOTIFY sessionLogicalDateChanged)
    // 平台是否开放自由计时、主动休息。两者分开控制：iPad 开放自由计时，主动休息暂不开放。
    // 界面据此隐藏点了必失败的入口，服务层另有兜底拒绝。
    Q_PROPERTY(bool freeTimingAllowed READ freeTimingAllowed NOTIFY freeTimingAllowedChanged)
    Q_PROPERTY(bool manualRestAllowed READ manualRestAllowed NOTIFY manualRestAllowedChanged)

public:
    enum TimerMode : int {
        FreeMode = 0,
        PomodoroMode = 1,
        // 主动休息是全局正计时，不绑定任务且不写入 focus_sessions。
        ManualRestMode = 2
    };
    Q_ENUM(TimerMode)

    enum TimerPhase : int {
        NoPhase = 0,
        WorkPhase = 1,
        BreakPhase = 2,
        // 与番茄完成后的 BreakPhase 分开，避免自动衔接和倒计时规则误作用于主动休息。
        ManualRestPhase = 3
    };
    Q_ENUM(TimerPhase)

    // 进程被结束后，怎样恢复进行中的计时。
    enum class RecoveryPolicy {
        // 桌面：退出是用户的选择，恢复为暂停、不补离线时段（原有语义）。
        PauseOnRestore,
        // 移动端：进程常在后台被系统结束，并非用户想暂停。同一次开机内按单调时钟
        // 补回离线时段并继续计时（番茄与自由计时）；番茄段若已在后台到期，只做离线结算。
        CatchUpOffline
    };

    static FocusTimer* instance();

    // 平台装配：必须在 restoreInterruptedSession 之前设置，恢复逻辑按它决定是否补离线时段。
    void setRecoveryPolicy(RecoveryPolicy policy);
    RecoveryPolicy recoveryPolicy() const;
    // 前后台状态来源，不转移所有权。为空时视为始终在前台（桌面与多数测试的默认）。
    void setApplicationActivity(const ApplicationActivity* activity);
    void setFreeTimingAllowed(bool allowed);
    bool freeTimingAllowed() const;
    void setManualRestAllowed(bool allowed);
    bool manualRestAllowed() const;
    // 每开始一段新的运行（开始、继续、恢复为运行）加一。系统通知预约据此判断
    // 「还是不是同一段运行」：段变了，到点时刻就变了，旧预约必须作废。
    quint64 runSegmentSerial() const;

    // 一个专注会话绑定一个任务；暂停只停止计时，stopFocus 才会写入数据库。
    Q_INVOKABLE bool startFocus(int taskId, const QString& taskTitle);
    Q_INVOKABLE bool startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds);
    Q_INVOKABLE bool startBreak(int breakSeconds);
    // QML 在番茄休息阶段继续携带任务上下文，应用重启后才能自动开始同一任务的下一轮。
    Q_INVOKABLE bool startBreakForTask(int breakSeconds, int taskId, const QString& taskTitle);
    // 仅空闲时可启动。主动休息不属于任务专注，因此不会影响今日专注统计。
    Q_INVOKABLE bool startManualRest();
    // 先落盘后生效：暂停状态写进活动快照失败时保持计时并返回 false。
    Q_INVOKABLE bool pauseFocus();
    Q_INVOKABLE bool resumeFocus();
    Q_INVOKABLE bool stopFocus();
    // 超长自由计时经用户确认后，可用修正值结算。只允许当前自由会话调用，不能改写番茄或休息。
    // 修正值必须落在 [最小有效时长, 实际已计时长] 之间：只能往下修，不能凭空放大。
    Q_INVOKABLE bool stopFreeFocusWithDuration(int durationSeconds);
    Q_INVOKABLE bool requiresFreeFocusStopConfirmation(int thresholdHours) const;
    // 用户在超长自由计时确认框选择“不记录”时，删除会话及活动快照，不进入统计。
    Q_INVOKABLE bool discardFreeFocus();
    // 用户完全结束番茄循环时重置连续计数，下一轮长休息节奏从头开始。
    Q_INVOKABLE void resetPomodoroCount();

    // 数据库初始化后调用。默认（桌面）把中断的会话恢复为暂停状态，关闭应用期间不会被误算为专注时间；
    // CatchUpOffline 策略下，同一次开机内被结束的番茄段与自由计时改为按单调时钟补回离线时段并继续计时。
    bool restoreInterruptedSession();
    // 应用退出前同步单调时钟到数据库；不结束会话，下一次启动仍可继续。
    void prepareForShutdown();
    // 只把当前进度写入活动快照，不暂停、不改变任何状态。移动端进入后台时调用：
    // 进程随后可能被挂起乃至结束，最后一次检查点越新，恢复时越准确。
    void checkpoint();

    int elapsedSeconds() const;
    bool isRunning() const;
    bool hasActiveSession() const;
    QString currentTaskTitle() const;
    int currentTaskId() const;
    int mode() const;
    int phase() const;
    int targetSeconds() const;
    int remainingSeconds() const;
    int minimumValidMinutes() const;
    int completedPomodoros() const;
    QString sessionLogicalDate() const;

signals:
    void tick();
    void runningStateChanged();
    void currentTaskChanged();
    void modeChanged();
    void phaseChanged();
    void focusCompleted(int duration);
    void restCompleted();
    void phaseCompleted(int phase);
    // 番茄段在后台到期、等回到前台或重新启动后才结算时发出，代替 phaseCompleted。
    // 只结算这一段：界面不得据此自动开始下一阶段，也不补发系统通知（预约的通知已按时投递）。
    void phaseSettledOffline(int phase);
    void freeTimingAllowedChanged();
    void manualRestAllowedChanged();
    void sessionDiscarded(int duration);
    void completedPomodorosChanged();
    void sessionLogicalDateChanged();
    void taskAutoCompleteFailed(int taskId);
    // 到点保存失败进入每秒自动重试时提示一次；恢复成功或会话复位后允许再次提示。
    void operationFailed(const QString& message);

private:
    // 单元测试需要直接推进单调时钟和内部计数来模拟长时间运行；
    // 用受控友元替代测试侧 #define private public 的未定义行为写法。
    friend class ServiceTests;
    // 菜单栏控制器测试需要在用例间复位单例计时器状态。
    friend class PlatformControlTests;
    // 计时健壮性测试注入 FakeClock 模拟休眠/时钟跳变。
    friend class TimingRobustnessTests;
    // 到点提醒预约的测试同样需要注入时钟并直接触发 tick。
    friend class PhaseAlarmCoordinatorTests;

    explicit FocusTimer(QObject* parent = nullptr);

    bool startFocusSession(int taskId, const QString& taskTitle, TimerMode mode, TimerPhase phase, int targetSeconds);
    bool startBreakSession(int breakSeconds, int taskId, const QString& taskTitle);
    // countedAsPomodoro 回传「这次结算是否真的记成了一个有效番茄」。长休息的连续计数
    // 必须以它为准：到点结算里仍可能因为时长不足被整条丢弃，那种会话不该推进长休息节奏。
    // 此前计数只看「刚结束的是工作阶段」，与写入口径是两套判断，靠「UI 把时长下限锁在
    // 5 分钟」这个外部事实才不出错——而 startPomodoroWork 是 Q_INVOKABLE，边界并不在这里。
    bool completeFocusSession(bool naturalCompletion, bool* countedAsPomodoro = nullptr,
                              int correctedDurationSeconds = -1);
    // 番茄段到点后的统一结算。settledOffline 为真时发 phaseSettledOffline，否则发 phaseCompleted；
    // 保存、计数与失败重试完全相同，两条路径只差最后告诉界面的是哪种完成。
    void finishExpiredPhase(bool settledOffline);
    // 本段到点的时刻是否落在应用离开前台期间（此刻不在前台，或到点早于最近一次回到前台）。
    bool expiredInBackground() const;
    bool hasActiveTimer() const;
    // 保存失败时调用方会保留当前会话状态，避免用户误以为记录已经落库。
    // durationWasCorrected 为真时 end_time 按 start_time + durationSeconds 写入，
    // 让记录占用的区间与用户确认的时长一致，而不是继续横跨到「现在」。
    // overshootSeconds 是自然到点时被截掉的超额（合盖跨过到点），结束时刻往回推这么多。
    bool saveFocusSession(int durationSeconds, bool naturalCompletion,
                          bool durationWasCorrected = false,
                          int overshootSeconds = 0);
    bool discardFocusSession();
    bool persistActiveState();
    bool writeActiveState(QSqlDatabase& db);
    bool clearActiveState(QSqlDatabase& db);
    bool cleanupOrphanedSessions();
    // 任务删除提交后按 ID 解绑当前会话；标题是历史快照，不能随任务一起清空。
    void handleTaskDeleted(int taskId);
    qint64 currentElapsedMilliseconds() const;
    void syncElapsedTime();
    void freezeElapsedTime();
    void resetSession();
    // 开始一段新的运行：同时记下单调时钟与墙钟的起点（后者只用于恢复时的一致性核对）。
    void beginRunSegment();

    // QTimer 只负责刷新界面；真实时长来自单调时钟，GUI 卡顿导致漏 tick 时也不会少算。
    // 时钟基准可注入：默认 mach_continuous_time（含休眠、抗改钟），测试注入 FakeClock。
    QTimer m_timer;
    const MonotonicClock* m_clock;
    // 当前运行段的起点（纳秒，取自 m_clock）；仅在 m_isRunning 为真时有意义。
    qint64 m_runSegmentStartNsecs = 0;
    // 同一时刻的墙钟读数（UTC 毫秒）。恢复时拿它与单调时钟对账，判断「是否同一次开机、期间没人改钟」。
    qint64 m_runSegmentStartUtcMs = -1;
    int m_currentTaskId = -1;
    QString m_currentTaskTitle;
    QDateTime m_startTime;
    int m_elapsedSeconds = 0;
    qint64 m_accumulatedMilliseconds = 0;
    int m_lastCheckpointSeconds = 0;
    bool m_isRunning = false;
    int m_sessionId = -1;
    TimerMode m_mode = FreeMode;
    TimerPhase m_phase = NoPhase;
    int m_targetSeconds = 0;
    int m_completedPomodoros = 0;
    // 到点保存失败的“已提示”标记，防止每秒重试把提示刷成噪音。
    bool m_completionFailureNotified = false;
    RecoveryPolicy m_recoveryPolicy = RecoveryPolicy::PauseOnRestore;
    const ApplicationActivity* m_activity = nullptr;
    bool m_freeTimingAllowed = true;
    bool m_manualRestAllowed = true;
    quint64 m_runSegmentSerial = 0;
};

#endif // FOCUSTIMER_H
