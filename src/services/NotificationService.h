#ifndef NOTIFICATIONSERVICE_H
#define NOTIFICATIONSERVICE_H

#include <QObject>
#include <QString>

#include <functional>

// 平台无关的通知后端接口。macOS 实现走 UNUserNotificationCenter；测试注入假后端。
// NotificationService 只负责决定“通知什么内容”，真正投递与权限交给后端。
class NotificationBackend
{
public:
    using DeliveryCallback = std::function<void(bool success, const QString& reason)>;

    virtual ~NotificationBackend() = default;

    // 系统投递是异步操作，完成回调才代表真正提交成功；playSound=false 时发送静默通知。
    virtual void deliver(const QString& title,
                         const QString& body,
                         bool playSound,
                         DeliveryCallback callback) = 0;
    // 权限是否已授权；未决时返回 true（乐观投递，失败再降级），已知拒绝时返回 false。
    virtual bool isAuthorized() const = 0;
    // 首次需要时申请权限；拒绝不得崩溃，后续投递按未授权处理。
    virtual void requestAuthorization() = 0;

    // 预约与撤销的结果回调；success=false 时 reason 说明原因（未授权、不支持、系统报错）。
    using ScheduleCallback = std::function<void(bool success, const QString& reason)>;
    // 预约 fireAfterSeconds 秒后由系统投递的通知：应用被挂起、甚至进程被结束也照常投递。
    // 同一 id 的旧预约会被替换。默认实现报告「不支持」——没有实现预约的平台必须明确失败，
    // 调用方据此改走进程内的即时提醒；若静默成功，到点时两边都以为对方会提醒，结果谁都没提醒。
    virtual void schedule(const QString& id,
                          int fireAfterSeconds,
                          const QString& title,
                          const QString& body,
                          bool playSound,
                          ScheduleCallback callback)
    {
        Q_UNUSED(id);
        Q_UNUSED(fireAfterSeconds);
        Q_UNUSED(title);
        Q_UNUSED(body);
        Q_UNUSED(playSound);
        callback(false, QStringLiteral("当前平台不支持预约通知"));
    }
    // 撤销 id 以 prefix 开头、尚未投递的预约；keepId 非空时保留这一条。已经投递的通知不受影响。
    virtual void cancelScheduled(const QString& prefix, const QString& keepId, ScheduleCallback callback)
    {
        Q_UNUSED(prefix);
        Q_UNUSED(keepId);
        callback(false, QStringLiteral("当前平台不支持预约通知"));
    }
};

class NotificationService : public QObject
{
    Q_OBJECT

public:
    static NotificationService* instance();
    explicit NotificationService(QObject* parent = nullptr);

    // 后端由平台层注入，不转移所有权；未注入时所有投递失败（返回 false，触发提示音降级）。
    void setBackend(NotificationBackend* backend);
    NotificationBackend* backend() const;

    Q_INVOKABLE void requestAuthorization();
    Q_INVOKABLE bool isAuthorized() const;

    // 阶段结束通知。phase 取 FocusTimer::TimerPhase（1=专注，2=休息）。
    // 文案在此组合，保持简短、不含敏感或冗长内容；真正结果通过信号异步返回。
    Q_INVOKABLE void notifyPhaseComplete(int phase,
                                         int completedPomodoros,
                                         int breakMinutes,
                                         bool isLongBreak,
                                         bool playSound);
    Q_INVOKABLE void notify(const QString& title,
                            const QString& body,
                            bool playSound = true);

    // 预约与撤销系统通知。结果回调一律排队切回服务对象所在线程：系统回调线程不确定，
    // 统一异步也让调用方不必处理「回调在调用返回前就到了」的重入。
    void scheduleNotification(const QString& id,
                              int fireAfterSeconds,
                              const QString& title,
                              const QString& body,
                              bool playSound,
                              NotificationBackend::ScheduleCallback callback);
    void cancelScheduledNotifications(const QString& prefix,
                                      const QString& keepId,
                                      NotificationBackend::ScheduleCallback callback);
    // 阶段结束的提醒是否已由预约通知覆盖。覆盖时 notifyPhaseComplete 不再即时投递，
    // 否则到点时预约的一条、进程内即时的一条会同时弹出。不设置时（桌面）一律即时投递。
    void setPhaseAlarmCoverage(std::function<bool(int phase)> coverage);
    // 阶段结束提醒的文案。预约通知与即时提醒共用这一处，两条路径说的是同一句话。
    // 返回 false 表示该阶段不发系统通知（自由计时等）。
    static bool phaseCompleteContent(int phase,
                                     int completedPomodoros,
                                     int breakMinutes,
                                     bool isLongBreak,
                                     QString* title,
                                     QString* body);

signals:
    // 投递成功/被抑制各发一次，供 UI 或日志观测；被抑制时 reason 说明原因。
    void notificationDelivered(const QString& title);
    void notificationSuppressed(const QString& reason);
    // 只有本信号要求调用方播放本地提示音降级；业务主动抑制通知不会触发。
    void notificationDeliveryFailed(const QString& reason);

private:
    void sendNotification(const QString& title,
                          const QString& body,
                          bool playSound,
                          bool requestFallback);
    NotificationBackend* m_backend = nullptr;
    std::function<bool(int phase)> m_phaseAlarmCoverage;
};

#endif // NOTIFICATIONSERVICE_H
