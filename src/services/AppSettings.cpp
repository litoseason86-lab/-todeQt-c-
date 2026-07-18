#include "AppSettings.h"

#include <QDate>

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
const auto kDashboardTimerVisibleKey = QStringLiteral("appearance/dashboardTimerVisible");
const auto kReduceTransparencyKey = QStringLiteral("appearance/reduceTransparency");
const auto kRaiseOnPhaseCompleteKey = QStringLiteral("focus/raiseOnPhaseComplete");
const auto kAutoStartBreakKey = QStringLiteral("focus/autoStartBreak");
const auto kAutoStartNextPomodoroKey = QStringLiteral("focus/autoStartNextPomodoro");
const auto kLongBreakEnabledKey = QStringLiteral("focus/longBreakEnabled");
const auto kLongBreakMinutesKey = QStringLiteral("focus/longBreakMinutes");
const auto kLongBreakIntervalKey = QStringLiteral("focus/longBreakInterval");
const auto kDailyFocusGoalDateKey = QStringLiteral("focus/dailyGoalDate");
const auto kDailyFocusGoalMinutesKey = QStringLiteral("focus/dailyGoalMinutes");
const auto kLegacyDailyFocusGoalHoursKey = QStringLiteral("focus/dailyGoalHours");

QString settingsErrorMessage(QSettings::Status status)
{
    switch (status) {
    case QSettings::AccessError:
        return QStringLiteral("设置文件不可写");
    case QSettings::FormatError:
        return QStringLiteral("设置文件格式无效");
    case QSettings::NoError:
        break;
    }
    return QStringLiteral("设置保存失败");
}
}

AppSettings* AppSettings::instance()
{
    static AppSettings settings;
    return &settings;
}

AppSettings::AppSettings(const QString& settingsFilePath, QObject* parent)
    : QObject(parent)
    , m_settingsFilePath(settingsFilePath)
{
    recreateSettingsBackend();
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
    if (writeValue(kLastModeKey, mode)) {
        emit lastModeChanged();
    }
}

int AppSettings::workMinutes() const
{
    return normalizeWorkMinutes(m_settings->value(kWorkMinutesKey, 25).toInt());
}

void AppSettings::setWorkMinutes(int minutes)
{
    const int normalized = normalizeWorkMinutes(minutes);
    if (workMinutes() == normalized) {
        return;
    }
    if (writeValue(kWorkMinutesKey, normalized)) {
        emit workMinutesChanged();
    }
}

int AppSettings::breakMinutes() const
{
    return normalizeBreakMinutes(m_settings->value(kBreakMinutesKey, 5).toInt());
}

void AppSettings::setBreakMinutes(int minutes)
{
    const int normalized = normalizeBreakMinutes(minutes);
    if (breakMinutes() == normalized) {
        return;
    }
    if (writeValue(kBreakMinutesKey, normalized)) {
        emit breakMinutesChanged();
    }
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
    if (writeValue(kSoundEnabledKey, enabled)) {
        emit soundEnabledChanged();
    }
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

    if (writeValue(kReduceMotionKey, enabled)) {
        emit reduceMotionChanged();
    }
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

    if (writeValue(kSlimClockFontKey, enabled)) {
        emit slimClockFontChanged();
    }
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

    if (writeValue(kRolloverIgnoredDateKey, date)) {
        emit rolloverIgnoredDateChanged();
    }
}

QString AppSettings::backgroundTheme() const
{
    // 只存取字符串、不校验合法性：主题定义的唯一来源在 Theme.qml。
    // 未知 id 的回落由 BackgroundWallpaper 负责，避免 C++ 和 QML 两处维护主题列表。
    return m_settings->value(kBackgroundThemeKey, QStringLiteral("warm")).toString();
}

void AppSettings::setBackgroundTheme(const QString& themeId)
{
    if (backgroundTheme() == themeId) {
        return;
    }

    if (writeValue(kBackgroundThemeKey, themeId)) {
        emit backgroundThemeChanged();
    }
}

int AppSettings::normalizeWorkMinutes(int minutes)
{
    // 专注时长与界面步进器使用同一边界；坏配置回默认值，不能悄悄夹到极端值。
    return (minutes >= 5 && minutes <= 180) ? minutes : 25;
}

int AppSettings::normalizeBreakMinutes(int minutes)
{
    return (minutes >= 1 && minutes <= 60) ? minutes : 5;
}

int AppSettings::normalizeDayStartHour(int hour)
{
    // 越界值代表配置损坏，统一回默认值；不能 clamp 成 0 或 6 改变用户的日期口径。
    return (hour >= 0 && hour <= 6) ? hour : 4;
}

int AppSettings::normalizeLongBreakMinutes(int minutes)
{
    // 长休息 5–60 分钟；坏值回默认 15，不静默夹到极端值。
    return (minutes >= 5 && minutes <= 60) ? minutes : 15;
}

int AppSettings::normalizeLongBreakInterval(int count)
{
    // 每 2–8 个番茄一次长休息；坏值回默认 4。
    return (count >= 2 && count <= 8) ? count : 4;
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

    if (writeValue(kDayStartHourKey, normalized)) {
        emit dayStartHourChanged();
    }
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

    if (writeValue(kNicknameKey, normalized)) {
        emit nicknameChanged();
    }
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

    if (writeValue(kSidebarVisibleKey, visible)) {
        emit sidebarVisibleChanged();
    }
}

bool AppSettings::dashboardTimerVisible() const
{
    return m_settings->value(kDashboardTimerVisibleKey, true).toBool();
}

void AppSettings::setDashboardTimerVisible(bool visible)
{
    if (dashboardTimerVisible() == visible) {
        return;
    }

    if (writeValue(kDashboardTimerVisibleKey, visible)) {
        emit dashboardTimerVisibleChanged();
    }
}

bool AppSettings::reduceTransparency() const
{
    return m_settings->value(kReduceTransparencyKey, false).toBool();
}

void AppSettings::setReduceTransparency(bool enabled)
{
    if (reduceTransparency() == enabled) {
        return;
    }
    if (writeValue(kReduceTransparencyKey, enabled)) {
        emit reduceTransparencyChanged();
    }
}

bool AppSettings::raiseOnPhaseComplete() const
{
    // 默认开启：保持“阶段结束把窗口拉回前台”的既有提醒行为，用户可关闭。
    return m_settings->value(kRaiseOnPhaseCompleteKey, true).toBool();
}

void AppSettings::setRaiseOnPhaseComplete(bool enabled)
{
    if (raiseOnPhaseComplete() == enabled) {
        return;
    }
    if (writeValue(kRaiseOnPhaseCompleteKey, enabled)) {
        emit raiseOnPhaseCompleteChanged();
    }
}

bool AppSettings::autoStartBreak() const
{
    return m_settings->value(kAutoStartBreakKey, false).toBool();
}

void AppSettings::setAutoStartBreak(bool enabled)
{
    if (autoStartBreak() == enabled) {
        return;
    }
    if (writeValue(kAutoStartBreakKey, enabled)) {
        emit autoStartBreakChanged();
    }
}

bool AppSettings::autoStartNextPomodoro() const
{
    return m_settings->value(kAutoStartNextPomodoroKey, false).toBool();
}

void AppSettings::setAutoStartNextPomodoro(bool enabled)
{
    if (autoStartNextPomodoro() == enabled) {
        return;
    }
    if (writeValue(kAutoStartNextPomodoroKey, enabled)) {
        emit autoStartNextPomodoroChanged();
    }
}

bool AppSettings::longBreakEnabled() const
{
    // 默认开启：契合番茄工作法“每 4 个后长休息”的经典节奏，用户可关闭。
    return m_settings->value(kLongBreakEnabledKey, true).toBool();
}

void AppSettings::setLongBreakEnabled(bool enabled)
{
    if (longBreakEnabled() == enabled) {
        return;
    }
    if (writeValue(kLongBreakEnabledKey, enabled)) {
        emit longBreakEnabledChanged();
    }
}

int AppSettings::longBreakMinutes() const
{
    return normalizeLongBreakMinutes(m_settings->value(kLongBreakMinutesKey, 15).toInt());
}

void AppSettings::setLongBreakMinutes(int minutes)
{
    const int normalized = normalizeLongBreakMinutes(minutes);
    if (longBreakMinutes() == normalized) {
        return;
    }
    if (writeValue(kLongBreakMinutesKey, normalized)) {
        emit longBreakMinutesChanged();
    }
}

int AppSettings::longBreakInterval() const
{
    return normalizeLongBreakInterval(m_settings->value(kLongBreakIntervalKey, 4).toInt());
}

void AppSettings::setLongBreakInterval(int count)
{
    const int normalized = normalizeLongBreakInterval(count);
    if (longBreakInterval() == normalized) {
        return;
    }
    if (writeValue(kLongBreakIntervalKey, normalized)) {
        emit longBreakIntervalChanged();
    }
}

int AppSettings::dailyFocusGoalMinutesForDate(const QString& isoDate) const
{
    const QDate requestedDate = QDate::fromString(isoDate, Qt::ISODate);
    if (!requestedDate.isValid() || requestedDate.toString(Qt::ISODate) != isoDate) {
        return 0;
    }

    if (m_settings->value(kDailyFocusGoalDateKey).toString() != isoDate) {
        return 0;
    }

    const int minutes = m_settings->value(kDailyFocusGoalMinutesKey, 0).toInt();
    // 损坏配置按“当天未设置”处理，不能把异常值带进百分比计算。
    return (minutes >= 1 && minutes <= 24 * 60) ? minutes : 0;
}

bool AppSettings::setDailyFocusGoal(const QString& isoDate, int minutes)
{
    const QDate requestedDate = QDate::fromString(isoDate, Qt::ISODate);
    if (!requestedDate.isValid() || requestedDate.toString(Qt::ISODate) != isoDate
            || minutes < 1 || minutes > 24 * 60) {
        return false;
    }

    if (m_settings->status() != QSettings::NoError) {
        recreateSettingsBackend();
    }

    if (m_settings->value(kDailyFocusGoalDateKey).toString() == isoDate
            && m_settings->value(kDailyFocusGoalMinutesKey).toInt() == minutes) {
        return true;
    }

    // 日期与分钟必须作为一项设置写入；旧整小时值没有日期语义，成功保存新目标后清理。
    m_settings->setValue(kDailyFocusGoalDateKey, isoDate);
    m_settings->setValue(kDailyFocusGoalMinutesKey, minutes);
    m_settings->remove(kLegacyDailyFocusGoalHoursKey);
    m_settings->sync();
    if (m_settings->status() != QSettings::NoError) {
        const QString message = settingsErrorMessage(m_settings->status());
        // QSettings::status 是粘滞状态：一次 AccessError 后，即使路径恢复可写，同一对象仍会继续报错。
        // 重建后端既丢弃未落盘缓存，也允许用户修复权限后在本次进程内直接重试。
        recreateSettingsBackend();
        emit settingsWriteFailed(QStringLiteral("focus/dailyGoal"), message);
        return false;
    }

    emit dailyFocusGoalChanged();
    emit settingsWriteSucceeded(QStringLiteral("focus/dailyGoal"));
    return true;
}

bool AppSettings::writeValue(const QString& key, const QVariant& value)
{
    // 刚发生过错误时，构造阶段本身也可能再次把状态置成 AccessError。
    // 每次新写入前再建一次后端，用户修复权限/路径后无需重启进程即可恢复。
    if (m_settings->status() != QSettings::NoError) {
        recreateSettingsBackend();
    }

    // changed 信号只能表示“已持久化”。先同步并检查状态，失败时重建后端并丢弃缓存，
    // 避免界面显示伪成功，也避免错误状态污染后续重试。
    m_settings->setValue(key, value);
    m_settings->sync();
    if (m_settings->status() == QSettings::NoError) {
        emit settingsWriteSucceeded(key);
        return true;
    }

    const QString message = settingsErrorMessage(m_settings->status());
    recreateSettingsBackend();
    emit settingsWriteFailed(key, message);
    return false;
}

void AppSettings::recreateSettingsBackend()
{
    delete m_settings;
    m_settings = m_settingsFilePath.isEmpty()
        ? new QSettings(this)
        : new QSettings(m_settingsFilePath, QSettings::IniFormat, this);
}
