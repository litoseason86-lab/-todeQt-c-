#ifndef MACNOTIFICATIONBACKEND_H
#define MACNOTIFICATIONBACKEND_H

#include "../../services/NotificationService.h"

#include <atomic>
#include <memory>

// UNUserNotificationCenter 后端。头文件保持纯 C++，可被 main.cpp 直接包含；
// ObjC 细节都在 .mm 里。授权状态由异步回调写入、投递时读取，故用原子量。
class MacNotificationBackend : public NotificationBackend
{
public:
    MacNotificationBackend();
    ~MacNotificationBackend() override;

    void deliver(const QString& title,
                 const QString& body,
                 bool playSound,
                 DeliveryCallback callback) override;
    bool isAuthorized() const override;
    void requestAuthorization() override;

private:
    // 回调可能晚于后端析构，共享原子状态避免异步授权完成时写入已释放对象。
    std::shared_ptr<std::atomic<int>> m_authState;
};

#endif // MACNOTIFICATIONBACKEND_H
