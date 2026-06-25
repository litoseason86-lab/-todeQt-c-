#ifndef FOCUSTIMER_H
#define FOCUSTIMER_H

#include <QDateTime>
#include <QObject>
#include <QTimer>

class FocusTimer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY tick)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY runningStateChanged)
    Q_PROPERTY(bool hasActiveSession READ hasActiveSession NOTIFY currentTaskChanged)
    Q_PROPERTY(QString currentTaskTitle READ currentTaskTitle NOTIFY currentTaskChanged)
    Q_PROPERTY(int mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(int phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(int targetSeconds READ targetSeconds NOTIFY phaseChanged)
    Q_PROPERTY(int remainingSeconds READ remainingSeconds NOTIFY tick)

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

    int elapsedSeconds() const;
    bool isRunning() const;
    bool hasActiveSession() const;
    QString currentTaskTitle() const;
    int mode() const;
    int phase() const;
    int targetSeconds() const;
    int remainingSeconds() const;

signals:
    void tick();
    void runningStateChanged();
    void currentTaskChanged();
    void modeChanged();
    void phaseChanged();
    void focusCompleted(int duration);
    void phaseCompleted(int phase);

private:
    explicit FocusTimer(QObject* parent = nullptr);

    bool startFocusSession(int taskId, const QString& taskTitle, TimerMode mode, TimerPhase phase, int targetSeconds);
    bool completeFocusSession();
    bool hasActiveTimer() const;
    // 保存失败时调用方会保留当前会话状态，避免用户误以为记录已经落库。
    bool saveFocusSession(int durationSeconds);
    bool discardFocusSession();
    void resetSession();

    // m_elapsedSeconds 存真实累计秒数，暂停时间不会计入专注时长。
    QTimer m_timer;
    int m_currentTaskId = -1;
    QString m_currentTaskTitle;
    QDateTime m_startTime;
    int m_elapsedSeconds = 0;
    bool m_isRunning = false;
    int m_sessionId = -1;
    TimerMode m_mode = FreeMode;
    TimerPhase m_phase = NoPhase;
    int m_targetSeconds = 0;
};

#endif // FOCUSTIMER_H
