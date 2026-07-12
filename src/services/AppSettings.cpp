#include "AppSettings.h"

namespace {
const auto kLastModeKey = QStringLiteral("focus/lastMode");
const auto kWorkMinutesKey = QStringLiteral("focus/workMinutes");
const auto kBreakMinutesKey = QStringLiteral("focus/breakMinutes");
const auto kSoundEnabledKey = QStringLiteral("focus/soundEnabled");
const auto kReduceMotionKey = QStringLiteral("appearance/reduceMotion");
const auto kSlimClockFontKey = QStringLiteral("appearance/slimClockFont");
const auto kRolloverIgnoredDateKey = QStringLiteral("rollover/lastIgnoredDate");
const auto kBackgroundThemeKey = QStringLiteral("appearance/backgroundTheme");
const auto kDayStartHourKey = QStringLiteral("logic/dayStartHour");
const auto kNicknameKey = QStringLiteral("profile/nickname");
const auto kSidebarVisibleKey = QStringLiteral("appearance/sidebarVisible");
}

AppSettings* AppSettings::instance()
{
    static AppSettings settings;
    return &settings;
}

AppSettings::AppSettings(const QString& settingsFilePath, QObject* parent)
    : QObject(parent)
    , m_settings(settingsFilePath.isEmpty()
                     ? new QSettings(this)
                     : new QSettings(settingsFilePath, QSettings::IniFormat, this))
{
}

int AppSettings::lastMode() const
{
    return m_settings->value(kLastModeKey, 0).toInt();
}

void AppSettings::setLastMode(int mode)
{
    if (lastMode() == mode) {
        return;
    }
    m_settings->setValue(kLastModeKey, mode);
    // 偏好写入后立即落盘，避免应用被强制退出时丢掉用户刚选择的启动模式。
    m_settings->sync();
    emit lastModeChanged();
}

int AppSettings::workMinutes() const
{
    return m_settings->value(kWorkMinutesKey, 25).toInt();
}

void AppSettings::setWorkMinutes(int minutes)
{
    if (workMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kWorkMinutesKey, minutes);
    m_settings->sync();
    emit workMinutesChanged();
}

int AppSettings::breakMinutes() const
{
    return m_settings->value(kBreakMinutesKey, 5).toInt();
}

void AppSettings::setBreakMinutes(int minutes)
{
    if (breakMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kBreakMinutesKey, minutes);
    m_settings->sync();
    emit breakMinutesChanged();
}

bool AppSettings::soundEnabled() const
{
    return m_settings->value(kSoundEnabledKey, true).toBool();
}

void AppSettings::setSoundEnabled(bool enabled)
{
    if (soundEnabled() == enabled) {
        return;
    }
    m_settings->setValue(kSoundEnabledKey, enabled);
    m_settings->sync();
    emit soundEnabledChanged();
}

bool AppSettings::reduceMotion() const
{
    return m_settings->value(kReduceMotionKey, false).toBool();
}

void AppSettings::setReduceMotion(bool enabled)
{
    if (reduceMotion() == enabled) {
        return;
    }

    // 减少动效属于无障碍偏好，写入后立即落盘，避免下次启动又恢复动画。
    m_settings->setValue(kReduceMotionKey, enabled);
    m_settings->sync();
    emit reduceMotionChanged();
}

bool AppSettings::slimClockFont() const
{
    return m_settings->value(kSlimClockFontKey, true).toBool();
}

void AppSettings::setSlimClockFont(bool enabled)
{
    if (slimClockFont() == enabled) {
        return;
    }

    // 计时数字字重属于即时可见的外观偏好，写入后立即落盘，保持设置项行为一致。
    m_settings->setValue(kSlimClockFontKey, enabled);
    m_settings->sync();
    emit slimClockFontChanged();
}

QString AppSettings::rolloverIgnoredDate() const
{
    return m_settings->value(kRolloverIgnoredDateKey, QString()).toString();
}

void AppSettings::setRolloverIgnoredDate(const QString& date)
{
    if (rolloverIgnoredDate() == date) {
        return;
    }

    // 这里只保存调用方传入的 ISO 日期字符串；空字符串用于将来需要清除忽略状态的场景。
    m_settings->setValue(kRolloverIgnoredDateKey, date);
    m_settings->sync();
    emit rolloverIgnoredDateChanged();
}

QString AppSettings::backgroundTheme() const
{
    // 只存取字符串、不校验合法性：主题定义的唯一来源在 Theme.qml。
    // 未知 id 的回落由 BackgroundWallpaper 负责，避免 C++ 和 QML 两处维护主题列表。
    return m_settings->value(kBackgroundThemeKey, QStringLiteral("warmPaper")).toString();
}

void AppSettings::setBackgroundTheme(const QString& themeId)
{
    if (backgroundTheme() == themeId) {
        return;
    }

    m_settings->setValue(kBackgroundThemeKey, themeId);
    m_settings->sync();
    emit backgroundThemeChanged();
}

int AppSettings::normalizeDayStartHour(int hour)
{
    // 越界值代表配置损坏，统一回默认值；不能 clamp 成 0 或 6 改变用户的日期口径。
    return (hour >= 0 && hour <= 6) ? hour : 4;
}

int AppSettings::dayStartHour() const
{
    // 读取时也归一化，拦住旧版本或手工编辑遗留的坏值。
    return normalizeDayStartHour(m_settings->value(kDayStartHourKey, 4).toInt());
}

void AppSettings::setDayStartHour(int hour)
{
    const int normalized = normalizeDayStartHour(hour);
    if (dayStartHour() == normalized) {
        return;
    }

    m_settings->setValue(kDayStartHourKey, normalized);
    m_settings->sync();
    emit dayStartHourChanged();
}

QString AppSettings::nickname() const
{
    return m_settings->value(kNicknameKey, QString()).toString();
}

void AppSettings::setNickname(const QString& name)
{
    // 首尾空白一律去掉：昵称用于问候语拼接，尾随空格会让标点悬空。
    const QString normalized = name.trimmed();
    if (nickname() == normalized) {
        return;
    }

    m_settings->setValue(kNicknameKey, normalized);
    m_settings->sync();
    emit nicknameChanged();
}

bool AppSettings::sidebarVisible() const
{
    return m_settings->value(kSidebarVisibleKey, true).toBool();
}

void AppSettings::setSidebarVisible(bool visible)
{
    if (sidebarVisible() == visible) {
        return;
    }

    // 侧栏显隐是即时布局偏好，落盘避免下次启动又弹出已收起的侧栏。
    m_settings->setValue(kSidebarVisibleKey, visible);
    m_settings->sync();
    emit sidebarVisibleChanged();
}
