#import "MacPreferencesCleanup.h"

#import <CoreFoundation/CoreFoundation.h>

namespace MacPreferencesCleanup {

int removeValuesPinnedFromGlobalDomain(const QString& applicationDomain)
{
    if (applicationDomain.isEmpty()) {
        return 0;
    }

    // QSettings 的用户级原生偏好对应「当前用户 + 任意主机」这一组位置，这里必须与之一致，
    // 否则读到的是另一份偏好文件。CoreFoundation 的 Copy/Create 返回值都要手动 CFRelease。
    CFStringRef appId = applicationDomain.toCFString();
    CFArrayRef keys = CFPreferencesCopyKeyList(appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    int removed = 0;
    if (keys != nullptr) {
        const CFIndex count = CFArrayGetCount(keys);
        for (CFIndex i = 0; i < count; ++i) {
            const auto key = static_cast<CFStringRef>(CFArrayGetValueAtIndex(keys, i));
            // 指定具体域时 CFPreferencesCopyValue 只查这一个域，不会顺着回退链往下找。
            CFPropertyListRef appValue = CFPreferencesCopyValue(
                key, appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPropertyListRef globalValue = CFPreferencesCopyValue(
                key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            if (appValue != nullptr && globalValue != nullptr && CFEqual(appValue, globalValue)) {
                // 传空值 = 删除这个键。
                CFPreferencesSetValue(key, nullptr, appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
                ++removed;
            }
            if (appValue != nullptr) {
                CFRelease(appValue);
            }
            if (globalValue != nullptr) {
                CFRelease(globalValue);
            }
        }
        CFRelease(keys);
    }
    if (removed > 0) {
        CFPreferencesSynchronize(appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
    CFRelease(appId);
    return removed;
}

} // namespace MacPreferencesCleanup
