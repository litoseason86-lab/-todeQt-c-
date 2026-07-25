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
};

#endif // NOTIFICATIONSERVICE_H
