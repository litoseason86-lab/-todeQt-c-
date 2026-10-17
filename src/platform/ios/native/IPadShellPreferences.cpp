#include "IPadShellPreferences.h"

#include "../../../services/AppSettings.h"

#include <QSettings>
#include <QStringList>
#include <QVariant>

#include <functional>

namespace {
const auto kWallpaperKey = QStringLiteral("ipad/useWallpaper");
const auto kAppearanceKey = QStringLiteral("ipad/appearance");
const auto kSelectedPageKey = QStringLiteral("ipad/selectedPage");

bool writePreference(const QString& key, const QVariant& value, const QString& failureMessage,
                     QString* error, const std::function<bool()>& completeWrite = {})
{
    if (error) error->clear();
    QSettings settings;
    const bool existed = settings.contains(key);
    const QVariant previous = settings.value(key);
    settings.setValue(key, value);
    settings.sync();
    if (settings.status() == QSettings::NoError && (!completeWrite || completeWrite())) {
        return true;
    }
    // QSettings（本机偏好后端）写失败仍会留下内存值；还原旧值或无键状态，防止外壳显示假成功。
    // 主题的第二步由服务提交，失败也在这里回退第一步的外观键；不向失败的磁盘承诺回退能落盘。
    if (existed) settings.setValue(key, previous); else settings.remove(key);
    settings.sync();
    if (error) *error = failureMessage;
    return false;
}
} // namespace

IPadShellPreferences::Snapshot IPadShellPreferences::readSnapshot()
{
    const QSettings settings;
    Snapshot snapshot;
    snapshot.useWallpaper = settings.value(kWallpaperKey, false).toBool();
    // 无外观键的旧设置只推导、不写回；首次主动选择才落键，保留旧壁纸体验。
    snapshot.appearance = settings.value(kAppearanceKey,
        snapshot.useWallpaper ? QStringLiteral("theme") : QStringLiteral("system")).toString();
    snapshot.selectedPage = settings.value(kSelectedPageKey, QStringLiteral("dashboard")).toString();
    return snapshot;
}

bool IPadShellPreferences::setUseWallpaper(bool value, QString* error)
{
    return writePreference(kWallpaperKey, value, QStringLiteral("壁纸设置保存失败"), error);
}

bool IPadShellPreferences::setAppearance(const QString& mode, QString* error)
{
    const QStringList modes = {QStringLiteral("system"), QStringLiteral("light"),
                              QStringLiteral("dark"), QStringLiteral("theme")};
    if (!modes.contains(mode)) {
        if (error) *error = QStringLiteral("无效的外观选项");
        return false;
    }
    return writePreference(kAppearanceKey, mode, QStringLiteral("外观设置保存失败"), error);
}

bool IPadShellPreferences::selectTheme(const QString& theme, QString* error, bool* needsRefresh)
{
    if (needsRefresh) *needsRefresh = false;
    if (theme.isEmpty()) {
        if (error) *error = QStringLiteral("无效的主题选项");
        return false;
    }
    QString oldTheme;
    const bool saved = writePreference(kAppearanceKey, QStringLiteral("theme"),
        QStringLiteral("主题设置保存失败"), error, [&] {
            // 服务负责主题刷盘、失败信号和后端重建；读回确认后才能保留本机主题模式。
            auto* settings = AppSettings::instance();
            oldTheme = settings->backgroundTheme();
            settings->setBackgroundTheme(theme);
            return settings->backgroundTheme() == theme;
        });
    // 主题未变时服务不发变化信号，即使只是外观切到主题，外壳仍需收到一次刷新。
    if (saved && needsRefresh) *needsRefresh = oldTheme == theme;
    return saved;
}

bool IPadShellPreferences::setSelectedPage(const QString& page, QString* error)
{
    return writePreference(kSelectedPageKey, page, QStringLiteral("页面状态保存失败"), error);
}
