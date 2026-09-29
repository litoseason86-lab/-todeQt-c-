#import "AppleNotificationBackend.h"

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include <QDebug>

#include <utility>

// 通知中心委托：只处理「应用在前台时收到通知」这一种情况。
// 没有委托时，系统对前台应用的通知一律不弹横幅、不响声音，但投递回调照样报成功，
// 于是本地提示音降级也不会触发。阶段结束时应用默认先把窗口拉到前台再发通知，
// 等于每次番茄到点都悄无声息，所以前台也必须明确要求横幅和声音。
@interface PomodoroNotificationCenterDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation PomodoroNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    Q_UNUSED(center);
    Q_UNUSED(notification);
    // 声音选项只是「允许响」：用户关掉提示音时通知内容里本就没有声音，这里不会凭空出声。
    completionHandler(UNNotificationPresentationOptionBanner
                      | UNNotificationPresentationOptionList
                      | UNNotificationPresentationOptionSound);
}

@end

namespace {
AppleNotificationBackend::AuthorizationQuery makeAuthorizationQuery();
AppleNotificationBackend::NotificationSubmitter makeNotificationSubmitter();
void installForegroundPresentationDelegate();
}

AppleNotificationBackend::AppleNotificationBackend()
    : AppleNotificationBackend(makeAuthorizationQuery(), makeNotificationSubmitter())
{
    // 只有生产用的默认构造才接管系统通知中心；注入假实现的测试构造不碰系统对象。
    installForegroundPresentationDelegate();
}

AppleNotificationBackend::ForegroundPresentation AppleNotificationBackend::foregroundPresentationForTesting()
{
    // __block：block 默认按值捕获局部变量，不加这个修饰就写不回 result。
    __block ForegroundPresentation result;
    PomodoroNotificationCenterDelegate* delegate = [[PomodoroNotificationCenterDelegate alloc] init];
    // 系统通知对象无法手工构造（测试进程也拿不到通知中心），这里传 nil。
    // 委托实现不读这两个参数，所以只屏蔽这一处的 nonnull 警告，照常调用真实方法。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [delegate userNotificationCenter:nil
             willPresentNotification:nil
               withCompletionHandler:^(UNNotificationPresentationOptions options) {
        result.handled = true;
        result.banner = (options & UNNotificationPresentationOptionBanner) != 0;
        result.list = (options & UNNotificationPresentationOptionList) != 0;
        result.sound = (options & UNNotificationPresentationOptionSound) != 0;
    }];
#pragma clang diagnostic pop
    return result;
}

AppleNotificationBackend::AppleNotificationBackend(AuthorizationQuery authorizationQuery,
                                               NotificationSubmitter notificationSubmitter)
    : m_authState(std::make_shared<std::atomic<int>>(0))
    , m_authorizationQuery(std::move(authorizationQuery))
    , m_notificationSubmitter(std::move(notificationSubmitter))
{
}

AppleNotificationBackend::~AppleNotificationBackend() = default;

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

void installForegroundPresentationDelegate()
{
    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        return;
    }
    // 通知中心对 delegate 只做弱引用，委托对象必须由我们自己一直持有到进程结束。
    // Apple 要求在应用完成启动前设置：main 在 app.exec() 之前构造本后端，满足这个时机。
    static PomodoroNotificationCenterDelegate* delegate =
        [[PomodoroNotificationCenterDelegate alloc] init];
    center.delegate = delegate;
}

AppleNotificationBackend::AuthorizationQuery makeAuthorizationQuery()
{
    return [](AppleNotificationBackend::AuthorizationResultCallback callback) {
        UNUserNotificationCenter* center = safeNotificationCenter();
        if (center == nil) {
            callback(false, QStringLiteral("系统通知中心不可用"));
            return;
        }

        const auto completion =
            std::make_shared<AppleNotificationBackend::AuthorizationResultCallback>(std::move(callback));
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
            const bool allowed = settings.authorizationStatus == UNAuthorizationStatusAuthorized
                || settings.authorizationStatus == UNAuthorizationStatusProvisional;
            (*completion)(allowed, allowed ? QString() : QStringLiteral("系统通知权限不可用"));
        }];
    };
}

AppleNotificationBackend::NotificationSubmitter makeNotificationSubmitter()
{
    return [](const QString& title,
              const QString& body,
              bool playSound,
              NotificationBackend::DeliveryCallback callback) {
        UNUserNotificationCenter* center = safeNotificationCenter();
        if (center == nil) {
            callback(false, QStringLiteral("系统通知中心不可用"));
            return;
        }

        NSString* notificationTitle = [title.toNSString() copy];
        NSString* notificationBody = [body.toNSString() copy];
        const auto completion =
            std::make_shared<NotificationBackend::DeliveryCallback>(std::move(callback));

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
    };
}
}

void AppleNotificationBackend::requestAuthorization()
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

bool AppleNotificationBackend::isAuthorized() const
{
    return m_authState->load() != 2;
}

void AppleNotificationBackend::deliver(const QString& title,
                                     const QString& body,
                                     bool playSound,
                                     DeliveryCallback callback)
{
    const std::shared_ptr<std::atomic<int>> state = m_authState;
    const auto completion =
        std::make_shared<DeliveryCallback>(std::move(callback));

    // 不能用上一次“被拒绝”的缓存短路。用户可在系统设置中授权而不重启应用，
    // 每次投递前查询当前权限，才能在下一次阶段提醒时自动恢复。
    if (!m_authorizationQuery) {
        (*completion)(false, QStringLiteral("系统通知授权查询不可用"));
        return;
    }

    const NotificationSubmitter submitter = m_notificationSubmitter;
    m_authorizationQuery([state, submitter, title, body, playSound, completion](bool allowed,
                                                                                  const QString& error) {
        state->store(allowed ? 1 : 2);
        if (!allowed) {
            (*completion)(false, error.isEmpty()
                          ? QStringLiteral("系统通知权限不可用") : error);
            return;
        }
        if (!submitter) {
            (*completion)(false, QStringLiteral("系统通知投递不可用"));
            return;
        }
        // 投递失败不等于授权失效；缓存仍保留本次已观察到的 allowed 状态。
        submitter(title, body, playSound, [completion](bool success, const QString& reason) {
            (*completion)(success, reason);
        });
    });
}

void AppleNotificationBackend::schedule(const QString& id,
                                      int fireAfterSeconds,
                                      const QString& title,
                                      const QString& body,
                                      bool playSound,
                                      ScheduleCallback callback)
{
    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        callback(false, QStringLiteral("系统通知中心不可用"));
        return;
    }

    NSString* identifier = [id.toNSString() copy];
    NSString* notificationTitle = [title.toNSString() copy];
    NSString* notificationBody = [body.toNSString() copy];
    // 系统要求触发间隔大于 0；到点已过的段不会走到这里（协调器只预约剩余时间大于 0 的段）。
    const NSTimeInterval interval = static_cast<NSTimeInterval>(qMax(1, fireAfterSeconds));
    const std::shared_ptr<std::atomic<int>> state = m_authState;
    const auto completion = std::make_shared<ScheduleCallback>(std::move(callback));

    // 先查权限再预约：权限被拒时系统照样接受预约请求、只是到点不显示。若把那当成成功，
    // 进程内会以为「已由预约覆盖」而不再即时提醒，用户最后什么提醒都收不到。
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
        UNTimeIntervalNotificationTrigger* trigger =
            [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:interval repeats:NO];
        UNNotificationRequest* request =
            [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
        [center addNotificationRequest:request
                 withCompletionHandler:^(NSError* _Nullable error) {
            if (error != nil) {
                qWarning() << "预约通知失败:" << QString::fromNSString(error.localizedDescription);
                (*completion)(false, QString::fromNSString(error.localizedDescription));
                return;
            }
            (*completion)(true, QString());
        }];
    }];
}

void AppleNotificationBackend::cancelScheduled(const QString& prefix,
                                             const QString& keepId,
                                             ScheduleCallback callback)
{
    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        callback(false, QStringLiteral("系统通知中心不可用"));
        return;
    }

    NSString* idPrefix = [prefix.toNSString() copy];
    NSString* keep = keepId.isEmpty() ? nil : [keepId.toNSString() copy];
    const auto completion = std::make_shared<ScheduleCallback>(std::move(callback));
    // 系统只提供「按 id 删除」，所以先取待投递列表、按前缀挑出自己的，再一次性删除。
    // 调用方保证上一步预约的完成回调已经返回，那条预约此时一定在列表里。
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest*>* requests) {
        NSMutableArray<NSString*>* identifiers = [NSMutableArray array];
        for (UNNotificationRequest* request in requests) {
            if ([request.identifier hasPrefix:idPrefix]
                && (keep == nil || ![request.identifier isEqualToString:keep])) {
                [identifiers addObject:request.identifier];
            }
        }
        if (identifiers.count > 0) {
            [center removePendingNotificationRequestsWithIdentifiers:identifiers];
        }
        (*completion)(true, QString());
    }];
}

void AppleNotificationBackend::logScheduledNotifications(const QString& prefix)
{
    UNUserNotificationCenter* center = safeNotificationCenter();
    if (center == nil) {
        qInfo().noquote() << "[通知诊断] 系统通知中心不可用";
        return;
    }
    NSString* idPrefix = [prefix.toNSString() copy];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        qInfo().noquote() << "[通知诊断] 授权状态" << static_cast<int>(settings.authorizationStatus)
                          << "（2=已授权，1=已拒绝，0=未决定）";
    }];
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest*>* requests) {
        int count = 0;
        for (UNNotificationRequest* request in requests) {
            if (![request.identifier hasPrefix:idPrefix]) {
                continue;
            }
            ++count;
            UNTimeIntervalNotificationTrigger* trigger =
                (UNTimeIntervalNotificationTrigger*)request.trigger;
            NSDate* fireDate = [trigger nextTriggerDate];
            qInfo().noquote() << "[通知诊断] 待投递" << QString::fromNSString(request.identifier)
                              << QString::fromNSString(request.content.title)
                              << QString::fromNSString([fireDate description]);
        }
        qInfo().noquote() << "[通知诊断] 待投递合计" << count;
    }];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification*>* notifications) {
        int count = 0;
        for (UNNotification* notification in notifications) {
            NSString* identifier = notification.request.identifier;
            if (![identifier hasPrefix:idPrefix]) {
                continue;
            }
            ++count;
            qInfo().noquote() << "[通知诊断] 已投递" << QString::fromNSString(identifier)
                              << QString::fromNSString(notification.request.content.title)
                              << QString::fromNSString([notification.date description]);
        }
        qInfo().noquote() << "[通知诊断] 已投递合计" << count;
    }];
}
