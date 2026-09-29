#ifndef PHASEALARMCOORDINATOR_H
#define PHASEALARMCOORDINATOR_H

#include <QList>
#include <QObject>
#include <QString>

class FocusTimer;
class NotificationService;

// 番茄到点提醒的系统预约。移动端的应用进入后台后很快被挂起，到点那一刻进程里的计时器
// 根本不会运行，只有提前交给系统的「预约通知」能按时提醒。这个协调器跟随 FocusTimer：
//   · 开始或继续一段番茄（专注或休息）时，按剩余秒数预约；
//   · 暂停、提前结束、丢弃时撤销尚未投递的预约；
//   · 自然到点时不撤销——预约的那条就是这次提醒，此时撤销可能恰好删掉还没投递的它。
// 系统接口全是异步的：预约与撤销排成队列一个接一个执行，每次预约带「代次」编号，
// 迟到的旧回调只能更新它自己那一代的记录，改不了当前状态。
class PhaseAlarmCoordinator : public QObject
{
    Q_OBJECT
    // 当前这一段的到点提醒是否已成功交给系统。
    Q_PROPERTY(bool currentAlarmScheduled READ currentAlarmScheduled NOTIFY currentAlarmChanged)

public:
    PhaseAlarmCoordinator(FocusTimer* timer, NotificationService* notifications, QObject* parent = nullptr);

    // 启动恢复之后调用一次：先撤销上一个进程遗留的全部预约，再按当前计时状态重新预约。
    // 进程被结束时来不及撤销；不清掉的话，它们会按旧的到点时刻再响一次。
    void start();

    bool currentAlarmScheduled() const;
    // phase 的到点提醒是否已由系统预约覆盖（当前代次预约成功且未被撤销）。
    // NotificationService 用它决定到点时还要不要即时投递一条。
    bool coversPhase(int phase) const;
    // 本协调器创建的预约 id 都以它开头，撤销时只动自己的预约。
    static QString idPrefix();

signals:
    void currentAlarmChanged();
    // 当前代次预约失败（未授权、平台不支持、系统报错）。界面据此在前台给出可见提示：
    // 到点时应用若不在前台，就不会有任何提醒。
    void alarmUnavailable(const QString& reason);

private:
    enum class AlarmStatus { Pending, Scheduled, Failed };

    struct Operation {
        enum class Kind { Schedule, CancelAll };
        Kind kind = Kind::Schedule;
        quint64 generation = 0;
        QString id;
        int fireAfterSeconds = 0;
        QString title;
        QString body;
        bool playSound = true;
    };

    // 计时器状态变化常常一次连发好几个信号（结束时依次改运行、阶段、模式）。
    // 合并到事件循环的下一轮统一对账，看到的才是这一串变化之后的最终状态。
    void requestReconcile();
    void reconcile();
    void enqueue(const Operation& operation);
    void runNext();
    void finishOperation(const Operation& operation, bool success, const QString& reason);
    void clearCurrent();
    bool composeContent(QString* title, QString* body, bool* playSound) const;

    FocusTimer* m_timer;
    NotificationService* m_notifications;
    // 每个进程一个随机片段，避免与上一个进程遗留、编号相同的预约混淆。
    QString m_processToken;
    quint64 m_generation = 0;

    // 当前代次：对应哪一段运行、哪个阶段，以及系统预约的结果。
    bool m_hasCurrent = false;
    quint64 m_currentGeneration = 0;
    quint64 m_currentSegment = 0;
    int m_currentPhase = 0;
    QString m_currentId;
    AlarmStatus m_currentStatus = AlarmStatus::Pending;

    // 最近一次结束是否为自然到点（含离线结算）。由完成信号同步置位，对账时消费。
    bool m_naturalEndPending = false;
    bool m_reconcileQueued = false;
    bool m_started = false;

    QList<Operation> m_queue;
    bool m_operationRunning = false;
};

#endif // PHASEALARMCOORDINATOR_H
