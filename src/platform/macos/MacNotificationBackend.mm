#import "MacNotificationBackend.h"

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include <QDebug>

#include <utility>

MacNotificationBackend::MacNotificationBackend()
    : m_authState(std::make_shared<std::atomic<int>>(0))
{
}
MacNotificationBackend::~MacNotificationBackend() = default;

namespace {
// UNUserNotificationCenter 只在有合法 bundle 标识（正常打包/签名）时可用；否则
// currentNotificationCenter 会抛 NSInternalInconsistencyException 而非返回 nil，
// 未签名/裸二进制运行会直接崩溃。先校验再取，并用 @try 兜底，保证任何情况下不崩溃。
UNUserNotificationCenter* safeNotificationCenter()
{
    if ([[NSBundle mainBundle] bundleIdentifier] == nil) {
        return nil;
    }
    @try {
        return [UNUserNotificationCenter currentNotificationCenter];
    } @catch (NSException* exception) {
        return nil;
    }
}
}

void MacNotificationBackend::requestAuthorization()
{
    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        // 无合法 bundle/通知中心不可用：按未授权处理，走提示音降级，不崩溃。
        m_authState->store(2);
        return;
    }

    const std::shared_ptr<std::atomic<int>> state = m_authState;
    // 系统只会首次弹一次授权框；之后再调用只返回当前状态，不重复打扰用户。
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError* _Nullable error) {
        if (error != nil) {
            qWarning() << "通知权限申请出错:" << QString::fromNSString(error.localizedDescription);
        }
        state->store(granted ? 1 : 2);
    }];
}

bool MacNotificationBackend::isAuthorized() const
{
    return m_authState->load() != 2;
}

void MacNotificationBackend::deliver(const QString& title,
                                     const QString& body,
                                     bool playSound,
                                     DeliveryCallback callback)
{
    if (m_authState->load() == 2) {
        callback(false, QStringLiteral("系统通知权限已被拒绝"));
        return;
    }

    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        callback(false, QStringLiteral("系统通知中心不可用"));
        return;
    }

    NSString* notificationTitle = [title.toNSString() copy];
    NSString* notificationBody = [body.toNSString() copy];
    const std::shared_ptr<std::atomic<int>> state = m_authState;
    const auto completion =
        std::make_shared<DeliveryCallback>(std::move(callback));

    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        const bool allowed = settings.authorizationStatus == UNAuthorizationStatusAuthorized
            || settings.authorizationStatus == UNAuthorizationStatusProvisional;
        state->store(allowed ? 1 : 2);
        if (!allowed) {
            (*completion)(false, QStringLiteral("系统通知权限不可用"));
            return;
        }

        UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
        content.title = notificationTitle;
        content.body = notificationBody;
        content.sound = playSound ? [UNNotificationSound defaultSound] : nil;

        UNNotificationRequest* request =
            [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                 content:content
                                                 trigger:nil];
        [center addNotificationRequest:request
                 withCompletionHandler:^(NSError* _Nullable error) {
            if (error != nil) {
                qWarning() << "系统通知投递失败:"
                           << QString::fromNSString(error.localizedDescription);
                (*completion)(false, QString::fromNSString(error.localizedDescription));
                return;
            }
            (*completion)(true, QString());
        }];
    }];
}
