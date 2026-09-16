#ifndef MACNOTIFICATIONBACKEND_H
#define MACNOTIFICATIONBACKEND_H

#include "../../services/NotificationService.h"

#include <atomic>
#include <functional>
#include <memory>

// UNUserNotificationCenter 后端。头文件保持纯 C++，可被 main.cpp 直接包含；
// ObjC 细节都在 .mm 里。授权状态由异步回调写入、投递时读取，故用原子量。
class MacNotificationBackend : public NotificationBackend
{
public:
    using AuthorizationResultCallback = std::function<void(bool allowed, const QString& error)>;
    // 查询与提交边界只用 C++ 类型，测试无需触发真实授权框或系统通知。
    using AuthorizationQuery = std::function<void(AuthorizationResultCallback callback)>;
    using NotificationSubmitter = std::function<void(const QString& title,
                                                      const QString& body,
                                                      bool playSound,
                                                      DeliveryCallback callback)>;

    MacNotificationBackend();
    MacNotificationBackend(AuthorizationQuery authorizationQuery,
                           NotificationSubmitter notificationSubmitter);
    ~MacNotificationBackend() override;

    void deliver(const QString& title,
                 const QString& body,
                 bool playSound,
                 DeliveryCallback callback) override;
    bool isAuthorized() const override;
    void requestAuthorization() override;

    // 应用在前台时系统收到通知的展示方式（由通知中心委托决定）。
    // handled=false 表示委托没有调用完成回调，系统会按默认规则把前台通知静默掉。
    struct ForegroundPresentation {
        bool handled = false;
        bool banner = false;
        bool list = false;
        bool sound = false;
    };
    // 直接调用真实委托的 willPresent 方法并解码结果；测试进程没有 bundle 标识，
    // 拿不到系统通知中心，只能这样验证委托本身的行为。
    static ForegroundPresentation foregroundPresentationForTesting();

private:
    // 回调可能晚于后端析构，共享原子状态避免异步授权完成时写入已释放对象。
    std::shared_ptr<std::atomic<int>> m_authState;
    AuthorizationQuery m_authorizationQuery;
    NotificationSubmitter m_notificationSubmitter;
};

#endif // MACNOTIFICATIONBACKEND_H
