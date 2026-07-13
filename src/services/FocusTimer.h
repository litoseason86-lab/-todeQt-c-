#ifndef FOCUSTIMER_H
#define FOCUSTIMER_H

#include <QDateTime>
#include <QElapsedTimer>
#include <QObject>
#include <QTimer>

class QSqlDatabase;

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
    Q_PROPERTY(int autoCompleteMinutes READ autoCompleteMinutes CONSTANT)

public:
    enum TimerMode {
        FreeMode = 0,
        PomodoroMode = 1
    };
    Q_ENUM(TimerMode)

    enum TimerPhase {
        NoPhase = 0,
        WorkPhase = 1,
        BreakPhase = 2
    };
    Q_ENUM(TimerPhase)

    static FocusTimer* instance();

    // 一个专注会话绑定一个任务；暂停只停止计时，stopFocus 才会写入数据库。
    Q_INVOKABLE bool startFocus(int taskId, const QString& taskTitle);
    Q_INVOKABLE bool startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds);
    Q_INVOKABLE bool startBreak(int breakSeconds);
    Q_INVOKABLE void pauseFocus();
    Q_INVOKABLE bool resumeFocus();
    Q_INVOKABLE bool stopFocus();

    // 数据库初始化后调用：中断的会话恢复为暂停状态，关闭应用期间不会被误算为专注时间。
    bool restoreInterruptedSession();
    // 应用退出前同步单调时钟到数据库；不结束会话，下一次启动仍可继续。
    void prepareForShutdown();

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
    int autoCompleteMinutes() const;

signals:
    void tick();
    void runningStateChanged();
    void currentTaskChanged();
    void modeChanged();
    void phaseChanged();
    void focusCompleted(int duration);
    void phaseCompleted(int phase);
    void sessionDiscarded(int duration);

private:
    explicit FocusTimer(QObject* parent = nullptr);

    bool startFocusSession(int taskId, const QString& taskTitle, TimerMode mode, TimerPhase phase, int targetSeconds);
    bool completeFocusSession();
    bool hasActiveTimer() const;
    // 保存失败时调用方会保留当前会话状态，避免用户误以为记录已经落库。
    bool saveFocusSession(int durationSeconds);
    bool discardFocusSession();
    bool persistActiveState();
    bool writeActiveState(QSqlDatabase& db);
    bool clearActiveState(QSqlDatabase& db);
    bool cleanupOrphanedSessions();
    qint64 currentElapsedMilliseconds() const;
    void syncElapsedTime();
    void freezeElapsedTime();
    void resetSession();

    // QTimer 只负责刷新界面；真实时长来自单调时钟，GUI 卡顿导致漏 tick 时也不会少算。
    QTimer m_timer;
    QElapsedTimer m_runClock;
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
};

#endif // FOCUSTIMER_H
