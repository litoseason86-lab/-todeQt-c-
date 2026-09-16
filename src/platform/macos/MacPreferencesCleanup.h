#ifndef MACPREFERENCESCLEANUP_H
#define MACPREFERENCESCLEANUP_H

#include <QString>

// 清理被旧版「恢复失败回滚」写进本应用偏好域的系统全局偏好。
//
// 旧版做设置快照时开着 QSettings 的全局域回退，快照里混进了 AppleLanguages、AppleLocale、
// 文本替换词典这类系统键；回滚时又把快照原样写回，这些值就被钉在了本应用的偏好域里——
// 之后用户改系统语言、地区，本应用读到的永远是旧值。
namespace MacPreferencesCleanup {

// 只删除一种键：在本应用域里存在、在系统全局域里也存在、而且两边值完全相同。
// 删掉之后本应用经回退读到的仍是同一个值，所以不会改变任何现有行为，只是恢复了
// 「跟随系统设置」；值不同的键可能是本应用自己的设置，一律不动。返回删除的键数。
int removeValuesPinnedFromGlobalDomain(const QString& applicationDomain);

} // namespace MacPreferencesCleanup

#endif // MACPREFERENCESCLEANUP_H
