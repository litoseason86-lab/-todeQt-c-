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

public:
    static FocusTimer* instance();

    Q_INVOKABLE bool startFocus(int taskId, const QString& taskTitle);
    Q_INVOKABLE void pauseFocus();
    Q_INVOKABLE bool resumeFocus();
    Q_INVOKABLE bool stopFocus();

    int elapsedSeconds() const;
    bool isRunning() const;
    bool hasActiveSession() const;
    QString currentTaskTitle() const;

signals:
    void tick();
    void runningStateChanged();
    void currentTaskChanged();
    void focusCompleted(int duration);

private:
    explicit FocusTimer(QObject* parent = nullptr);

    bool saveFocusSession(int durationSeconds);
    void resetSession();

    QTimer m_timer;
    int m_currentTaskId = -1;
    QString m_currentTaskTitle;
    QDateTime m_startTime;
    int m_elapsedSeconds = 0;
    bool m_isRunning = false;
    int m_sessionId = -1;
};

#endif // FOCUSTIMER_H
