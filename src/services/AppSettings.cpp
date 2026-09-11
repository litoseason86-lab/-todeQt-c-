#include "AppSettings.h"

#include <QDate>

namespace {
const auto kLastModeKey = QStringLiteral("focus/lastMode");
const auto kWorkMinutesKey = QStringLiteral("focus/workMinutes");
const auto kBreakMinutesKey = QStringLiteral("focus/breakMinutes");
const auto kFreeTimerWarningHoursKey = QStringLiteral("focus/freeTimerWarningHours");
const auto kSoundEnabledKey = QStringLiteral("focus/soundEnabled");
const auto kReduceMotionKey = QStringLiteral("appearance/reduceMotion");
const auto kSlimClockFontKey = QStringLiteral("appearance/slimClockFont");
const auto kRolloverIgnoredDateKey = QStringLiteral("rollover/lastIgnoredDate");
const auto kBackgroundThemeKey = QStringLiteral("appearance/backgroundTheme");
const auto kDayStartHourKey = QStringLiteral("logic/dayStartHour");
const auto kNicknameKey = QStringLiteral("profile/nickname");
const auto kSidebarVisibleKey = QStringLiteral("appearance/sidebarVisible");
const auto kSidebarOrderKey = QStringLiteral("appearance/sidebarOrder");
const auto kDashboardTimerVisibleKey = QStringLiteral("appearance/dashboardTimerVisible");
const auto kGoalViewModeKey = QStringLiteral("goals/viewMode");
const auto kReduceTransparencyKey = QStringLiteral("appearance/reduceTransparency");
const auto kRaiseOnPhaseCompleteKey = QStringLiteral("focus/raiseOnPhaseComplete");
const auto kCloseToTrayKey = QStringLiteral("window/closeToTray");
const auto kCloseToTrayHintShownKey = QStringLiteral("window/closeToTrayHintShown");
const auto kNaturalCompletionNoticeShownKey = QStringLiteral("migration/v8NaturalCompletionNoticeShown");
const auto kAutoStartBreakKey = QStringLiteral("focus/autoStartBreak");
const auto kAutoStartNextPomodoroKey = QStringLiteral("focus/autoStartNextPomodoro");
const auto kLongBreakEnabledKey = QStringLiteral("focus/longBreakEnabled");
const auto kLongBreakMinutesKey = QStringLiteral("focus/longBreakMinutes");
const auto kLongBreakIntervalKey = QStringLiteral("focus/longBreakInterval");
const auto kDailyFocusGoalDateKey = QStringLiteral("focus/dailyGoalDate");
const auto kDailyFocusGoalMinutesKey = QStringLiteral("focus/dailyGoalMinutes");
const auto kLegacyDailyFocusGoalHoursKey = QStringLiteral("focus/dailyGoalHours");
const auto kSemesterStartDateKey = QStringLiteral("schedule/semesterStartDate");
const auto kSemesterWeeksKey = QStringLiteral("schedule/semesterWeeks");
const auto kScheduleDisplayModeKey = QStringLiteral("schedule/displayMode");
const auto kScheduleShowWeekendKey = QStringLiteral("schedule/showWeekend");
// 快捷键覆盖值统一放在这个分组下，「全部恢复默认」才能一次 remove 掉整组。
const auto kShortcutGroup = QStringLiteral("shortcuts");

// 学期总周数的取值范围。上界必须与 ScheduleService::kMaxWeekIndex 相等：
// 课表项能填到第几周，学期就至少要能有多长，否则会出现「排了课却翻不到那一周」。
// AppSettings 不该反向依赖 ScheduleService，所以这里独立定义，
// 由 ScheduleServiceTests 里的一条用例把两个常量钉死在一起。
constexpr int kMinSemesterWeeks = 1;
constexpr int kMaxSemesterWeeks = 60;
constexpr int kDefaultSemesterWeeks = 20;

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

void AppSettings::reload()
{
    // 重新绑定磁盘存储（恢复流程刚覆盖过设置文件），再广播全部变更让 QML 绑定刷新。
    recreateSettingsBackend();
    emit lastModeChanged();
    emit workMinutesChanged();
    emit breakMinutesChanged();
    emit freeTimerWarningHoursChanged();
    emit soundEnabledChanged();
    emit reduceMotionChanged();
    emit slimClockFontChanged();
    emit rolloverIgnoredDateChanged();
    emit backgroundThemeChanged();
    emit dayStartHourChanged();
    emit nicknameChanged();
    emit sidebarVisibleChanged();
    emit dashboardTimerVisibleChanged();
    emit goalViewModeChanged();
    emit reduceTransparencyChanged();
    emit raiseOnPhaseCompleteChanged();
    emit closeToTrayChanged();
    emit closeToTrayHintShownChanged();
    emit naturalCompletionNoticeShownChanged();
    emit autoStartBreakChanged();
    emit autoStartNextPomodoroChanged();
    emit longBreakEnabledChanged();
    emit longBreakMinutesChanged();
    emit longBreakIntervalChanged();
    emit semesterStartDateChanged();
    emit semesterWeeksChanged();
    emit scheduleDisplayModeChanged();
    emit scheduleShowWeekendChanged();
    emit dailyFocusGoalChanged();
    emit shortcutOverridesChanged();
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

int AppSettings::freeTimerWarningHours() const
{
    return normalizeFreeTimerWarningHours(
        m_settings->value(kFreeTimerWarningHoursKey, 8).toInt());
}

void AppSettings::setFreeTimerWarningHours(int hours)
{
    const int normalized = normalizeFreeTimerWarningHours(hours);
    if (freeTimerWarningHours() == normalized) {
        return;
    }
    if (writeValue(kFreeTimerWarningHoursKey, normalized)) {
        emit freeTimerWarningHoursChanged();
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

int AppSettings::normalizeFreeTimerWarningHours(int hours)
{
    // 1–24 小时足以覆盖正常长时专注；坏配置回默认 8，不夹到边界制造意外提醒。
    return (hours >= 1 && hours <= 24) ? hours : 8;
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

QString AppSettings::normalizeSemesterStartDate(const QString& isoDate)
{
    const QString trimmed = isoDate.trimmed();
    if (trimmed.isEmpty()) {
        // 空串是「尚未设置」这个合法状态，不要替换成今天：
        // 课表页据此判断是否需要引导用户先定学期起始日。
        return QString();
    }

    const QDate parsed = QDate::fromString(trimmed, Qt::ISODate);
    if (!parsed.isValid()) {
        return QString();
    }

    // 回退到所在周的周一。周次按整周推进，锚点若停在周三，
    // 同一周里周一和周三会被算成相邻两个周次。
    // Qt 的 dayOfWeek() 是 1(周一)–7(周日)，减去它再加一天正好落到本周周一。
    return parsed.addDays(1 - parsed.dayOfWeek()).toString(Qt::ISODate);
}

int AppSettings::normalizeSemesterWeeks(int weeks)
{
    if (weeks < kMinSemesterWeeks || weeks > kMaxSemesterWeeks) {
        return kDefaultSemesterWeeks;
    }
    return weeks;
}

QString AppSettings::semesterStartDate() const
{
    // 读取时也归一化，拦住旧版本或手工编辑遗留的非周一日期。
    return normalizeSemesterStartDate(
        m_settings->value(kSemesterStartDateKey, QString()).toString());
}

void AppSettings::setSemesterStartDate(const QString& isoDate)
{
    // normalizeSemesterStartDate 对「没设置」和「格式不对」都返回空串，
    // 直接照写会让一个手滑的 "2026-13-45" 把用户已设好的学期锚点抹掉，
    // 整个课表页退回首次使用的引导态。这里把两者分开：
    // 只有显式传空才算清除，非空但解析不出来的一律拒绝写入。
    const QString trimmed = isoDate.trimmed();
    const QString normalized = normalizeSemesterStartDate(trimmed);
    if (!trimmed.isEmpty() && normalized.isEmpty()) {
        emit settingsWriteFailed(kSemesterStartDateKey,
                                 QStringLiteral("学期起始日格式无效"));
        return;
    }
    if (semesterStartDate() == normalized) {
        return;
    }
    if (writeValue(kSemesterStartDateKey, normalized)) {
        emit semesterStartDateChanged();
    }
}

int AppSettings::semesterWeeks() const
{
    return normalizeSemesterWeeks(
        m_settings->value(kSemesterWeeksKey, kDefaultSemesterWeeks).toInt());
}

void AppSettings::setSemesterWeeks(int weeks)
{
    const int normalized = normalizeSemesterWeeks(weeks);
    if (semesterWeeks() == normalized) {
        return;
    }
    if (writeValue(kSemesterWeeksKey, normalized)) {
        emit semesterWeeksChanged();
    }
}

QString AppSettings::scheduleDisplayMode() const
{
    // 只有两种可持久化版式；损坏配置和新增未知值都不能让课表进入空白态。
    const QString stored = m_settings->value(kScheduleDisplayModeKey,
                                             QStringLiteral("time")).toString();
    return stored == QStringLiteral("period") ? stored : QStringLiteral("time");
}

void AppSettings::setScheduleDisplayMode(const QString& mode)
{
    const QString normalized = mode == QStringLiteral("period")
        ? QStringLiteral("period")
        : QStringLiteral("time");
    if (scheduleDisplayMode() == normalized) {
        return;
    }
    if (writeValue(kScheduleDisplayModeKey, normalized)) {
        emit scheduleDisplayModeChanged();
    }
}

bool AppSettings::scheduleShowWeekend() const
{
    return m_settings->value(kScheduleShowWeekendKey, true).toBool();
}

void AppSettings::setScheduleShowWeekend(bool visible)
{
    if (scheduleShowWeekend() == visible) {
        return;
    }
    if (writeValue(kScheduleShowWeekendKey, visible)) {
        emit scheduleShowWeekendChanged();
    }
}

bool AppSettings::saveScheduleSettings(const QString& semesterStartDateValue,
                                       int semesterWeeksValue,
                                       bool showWeekendValue)
{
    const QString trimmedStart = semesterStartDateValue.trimmed();
    const QString normalizedStart = normalizeSemesterStartDate(trimmedStart);
    if (!trimmedStart.isEmpty() && normalizedStart.isEmpty()) {
        emit settingsWriteFailed(kSemesterStartDateKey,
                                 QStringLiteral("学期起始日格式无效"));
        return false;
    }
    if (semesterWeeksValue < kMinSemesterWeeks
        || semesterWeeksValue > kMaxSemesterWeeks) {
        emit settingsWriteFailed(kSemesterWeeksKey,
                                 QStringLiteral("学期总周数无效"));
        return false;
    }

    if (m_settings->status() != QSettings::NoError) {
        recreateSettingsBackend();
    }
    const QString oldStart = semesterStartDate();
    const int oldWeeks = semesterWeeks();
    const bool oldShowWeekend = scheduleShowWeekend();
    // 保留原始值及“键不存在”状态。QSettings 的文件缓存由多个实例共享，
    // 重建对象不能撤销失败写入，必须显式恢复缓存，才能安全重试。
    const QStringList keys = {kSemesterStartDateKey, kSemesterWeeksKey, kScheduleShowWeekendKey};
    QVariantList previousValues;
    QList<bool> previousPresence;
    for (const QString& key : keys) {
        previousValues.append(m_settings->value(key));
        previousPresence.append(m_settings->contains(key));
    }

    // 三个值先进同一份缓存，只在一次 sync 成功后才对外发送 changed，
    // 页面不会观察到半套课表设置；具体落盘方式由当前 QSettings 后端负责。
    m_settings->setValue(kSemesterStartDateKey, normalizedStart);
    m_settings->setValue(kSemesterWeeksKey, semesterWeeksValue);
    m_settings->setValue(kScheduleShowWeekendKey, showWeekendValue);
    m_settings->sync();
    if (m_settings->status() != QSettings::NoError) {
        const QString message = settingsErrorMessage(m_settings->status());
        for (qsizetype i = 0; i < keys.size(); ++i) {
            if (previousPresence.at(i)) {
                m_settings->setValue(keys.at(i), previousValues.at(i));
            } else {
                m_settings->remove(keys.at(i));
            }
        }
        recreateSettingsBackend();
        emit settingsWriteFailed(QStringLiteral("schedule"), message);
        return false;
    }

    emit settingsWriteSucceeded(QStringLiteral("schedule"));
    if (oldStart != normalizedStart) {
        emit semesterStartDateChanged();
    }
    if (oldWeeks != semesterWeeksValue) {
        emit semesterWeeksChanged();
    }
    if (oldShowWeekend != showWeekendValue) {
        emit scheduleShowWeekendChanged();
    }
    return true;
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

QStringList AppSettings::defaultSidebarOrder()
{
    // 出厂顺序，也是「当前版本有哪些可排序页面」的唯一清单。
    // 新增一个页面时必须同步这里，否则它既不出现在侧栏，也不出现在设置的排序列表里。
    // 「设置」不在其中：它不是视图，固定钉在侧栏底部。
    return {
        QStringLiteral("dashboard"),
        QStringLiteral("today"),
        QStringLiteral("todayFocus"),
        QStringLiteral("focus"),
        QStringLiteral("schedule"),
        QStringLiteral("week"),
        QStringLiteral("month"),
        QStringLiteral("stats"),
        QStringLiteral("countdown"),
        QStringLiteral("goals"),
        QStringLiteral("knowledgeGaps"),
    };
}

QStringList AppSettings::normalizeSidebarOrder(const QStringList& stored)
{
    const QStringList known = defaultSidebarOrder();

    QStringList result;
    for (const QString& id : stored) {
        // 丢掉不认识的 id（降级运行、手改配置文件、未来版本删掉的页面都会留下它们），
        // 同时去重——重复的 id 会让同一个入口在侧栏里出现两次。
        if (known.contains(id) && !result.contains(id)) {
            result.append(id);
        }
    }

    // 用户顺序里没有的页面补在末尾。这一步是整个函数存在的理由：
    // 新版本加了页面时，旧的顺序记录里当然没有它，若就此不显示，
    // 用户会认为这个版本没有这个功能，而且完全无从排查。
    for (const QString& id : known) {
        if (!result.contains(id)) {
            result.append(id);
        }
    }
    return result;
}

QStringList AppSettings::sidebarOrder() const
{
    // 以逗号分隔的单个字符串存储，而不是 QSettings 的 QStringList：
    // INI 后端对列表的读写要做引号和逗号转义，跨版本行为不如一个纯字符串可预期。
    // 视图 id 只含字母，不会和分隔符冲突。
    const QString raw = m_settings->value(kSidebarOrderKey, QString()).toString();
    const QStringList stored = raw.isEmpty()
        ? QStringList()
        : raw.split(QLatin1Char(','), Qt::SkipEmptyParts);
    return normalizeSidebarOrder(stored);
}

bool AppSettings::sidebarOrderIsDefault() const
{
    return sidebarOrder() == defaultSidebarOrder();
}

void AppSettings::setSidebarOrder(const QStringList& order)
{
    const QStringList normalized = normalizeSidebarOrder(order);
    if (sidebarOrder() == normalized) {
        return;
    }

    if (writeValue(kSidebarOrderKey, normalized.join(QLatin1Char(',')))) {
        emit sidebarOrderChanged();
    }
}

void AppSettings::resetSidebarOrder()
{
    setSidebarOrder(defaultSidebarOrder());
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

QString AppSettings::goalViewMode() const
{
    const QString stored = m_settings->value(kGoalViewModeKey, QStringLiteral("list")).toString();
    return stored == QStringLiteral("grid") ? stored : QStringLiteral("list");
}

void AppSettings::setGoalViewMode(const QString& mode)
{
    // 只有两种可持久化版式；损坏配置和新增未知值都不能让 QML 进入空白态。
    const QString normalized = mode == QStringLiteral("grid")
        ? QStringLiteral("grid")
        : QStringLiteral("list");
    if (goalViewMode() == normalized) {
        return;
    }
    if (writeValue(kGoalViewModeKey, normalized)) {
        emit goalViewModeChanged();
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

bool AppSettings::closeToTray() const
{
    // 未经用户明确选择，红色关闭按钮必须保持“退出应用”的普通语义。
    // 菜单栏驻留属于可选行为，不能用默认值把用户困在不可见进程里。
    return m_settings->value(kCloseToTrayKey, false).toBool();
}

void AppSettings::setCloseToTray(bool enabled)
{
    if (closeToTray() == enabled) {
        return;
    }
    if (writeValue(kCloseToTrayKey, enabled)) {
        emit closeToTrayChanged();
    }
}

bool AppSettings::closeToTrayHintShown() const
{
    return m_settings->value(kCloseToTrayHintShownKey, false).toBool();
}

void AppSettings::setCloseToTrayHintShown(bool shown)
{
    if (closeToTrayHintShown() == shown) {
        return;
    }
    if (writeValue(kCloseToTrayHintShownKey, shown)) {
        emit closeToTrayHintShownChanged();
    }
}

bool AppSettings::naturalCompletionNoticeShown() const
{
    return m_settings->value(kNaturalCompletionNoticeShownKey, false).toBool();
}

void AppSettings::setNaturalCompletionNoticeShown(bool shown)
{
    if (naturalCompletionNoticeShown() == shown) {
        return;
    }
    if (writeValue(kNaturalCompletionNoticeShownKey, shown)) {
        emit naturalCompletionNoticeShownChanged();
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

QString AppSettings::shortcutKey(const QString& actionId)
{
    return kShortcutGroup + QLatin1Char('/') + actionId;
}

bool AppSettings::hasShortcutOverride(const QString& actionId) const
{
    if (actionId.isEmpty()) {
        return false;
    }
    return m_settings->contains(shortcutKey(actionId));
}

QString AppSettings::shortcutOverride(const QString& actionId) const
{
    if (actionId.isEmpty()) {
        return QString();
    }
    return m_settings->value(shortcutKey(actionId)).toString();
}

bool AppSettings::setShortcutOverride(const QString& actionId, const QString& portableSequence)
{
    if (actionId.isEmpty()) {
        return false;
    }

    // 空串是有意义的值（= 停用该动作），所以这里不做“空就删除”的转换。
    if (!writeValue(shortcutKey(actionId), portableSequence)) {
        return false;
    }
    emit shortcutOverridesChanged();
    return true;
}

bool AppSettings::clearShortcutOverride(const QString& actionId)
{
    if (actionId.isEmpty()) {
        return false;
    }
    if (!m_settings->contains(shortcutKey(actionId))) {
        return true;
    }
    if (!removeValue(shortcutKey(actionId))) {
        return false;
    }
    emit shortcutOverridesChanged();
    return true;
}

bool AppSettings::clearAllShortcutOverrides()
{
    if (!removeValue(kShortcutGroup)) {
        return false;
    }
    emit shortcutOverridesChanged();
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

bool AppSettings::removeValue(const QString& key)
{
    // 与 writeValue 同一套错误处理：QSettings::status 是粘滞的，先重建再删，
    // 删完必须 sync 并检查状态，不能把“没写成盘”当成删除成功。
    if (m_settings->status() != QSettings::NoError) {
        recreateSettingsBackend();
    }

    m_settings->remove(key);
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

QStringList AppSettings::ownedSettingGroups()
{
    // 与本文件顶部的键常量、以及 kShortcutGroup 保持一致。
    // 新增一个分组时必须同步这里，否则该分组的设置在恢复备份后会丢失。
    return {
        QStringLiteral("focus"),
        QStringLiteral("appearance"),
        QStringLiteral("window"),
        QStringLiteral("logic"),
        QStringLiteral("profile"),
        QStringLiteral("goals"),
        QStringLiteral("rollover"),
        QStringLiteral("migration"),
        QStringLiteral("schedule"),
        kShortcutGroup,
    };
}

bool AppSettings::isOwnedSettingKey(const QString& key)
{
    if (key.isEmpty()) {
        return false;
    }
    // 只看第一段：shortcuts/focusStart 这类动态键靠分组通过，不必逐个登记。
    const QString group = key.section(QLatin1Char('/'), 0, 0);
    return ownedSettingGroups().contains(group);
}
