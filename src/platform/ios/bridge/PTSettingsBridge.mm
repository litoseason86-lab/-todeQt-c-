#import "PTSettingsBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/AppSettings.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTSettingsSnapshot ()
- (instancetype)initWithSettings:(AppSettings *)settings;
@end
@interface PTSettingsBridge ()
// 测试可注入独立设置后端；公开 Foundation 头文件不暴露 C++ 类型。
- (instancetype)initWithSettings:(AppSettings *)settings;
@end
@implementation PTSettingsSnapshot
- (instancetype)initWithSettings:(AppSettings *)settings {
    if ((self = [super init])) {
        _lastMode = settings->lastMode();
        _workMinutes = settings->workMinutes();
        _breakMinutes = settings->breakMinutes();
        _freeTimerWarningHours = settings->freeTimerWarningHours();
        _soundEnabled = settings->soundEnabled();
        _reduceMotion = settings->reduceMotion();
        _slimClockFont = settings->slimClockFont();
        _rolloverIgnoredDate = string(settings->rolloverIgnoredDate());
        _backgroundTheme = string(settings->backgroundTheme());
        _dayStartHour = settings->dayStartHour();
        _nickname = string(settings->nickname());
        _sidebarVisible = settings->sidebarVisible();
        NSMutableArray *sidebarOrder = [NSMutableArray array]; for (const auto &item : settings->sidebarOrder()) [sidebarOrder addObject:string(item)]; _sidebarOrder = [sidebarOrder copy];
        _sidebarOrderIsDefault = settings->sidebarOrderIsDefault();
        _dashboardTimerVisible = settings->dashboardTimerVisible();
        _reduceTransparency = settings->reduceTransparency();
        _naturalCompletionNoticeShown = settings->naturalCompletionNoticeShown();
        _autoStartBreak = settings->autoStartBreak();
        _autoStartNextPomodoro = settings->autoStartNextPomodoro();
        _quickStartEnabled = settings->quickStartEnabled();
        _longBreakEnabled = settings->longBreakEnabled();
        _longBreakMinutes = settings->longBreakMinutes();
        _longBreakInterval = settings->longBreakInterval();
        _semesterStartDate = string(settings->semesterStartDate());
        _semesterWeeks = settings->semesterWeeks();
        _scheduleDisplayMode = string(settings->scheduleDisplayMode());
        _scheduleShowWeekend = settings->scheduleShowWeekend();
    } return self;
}
@end
@implementation PTSettingsBridge {
    QPointer<AppSettings> _settings;
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init { return [self initWithSettings:AppSettings::instance()]; }
- (instancetype)initWithSettings:(AppSettings *)settings {
    NSAssert(NSThread.isMainThread, @"设置桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文断连；失败收集区分本次写入与背景失败，避免一条错误显示两次。
        _settings = settings; _connections = std::make_unique<QObject>(); __weak PTSettingsBridge *weakSelf = self;
        QObject::connect(settings, &AppSettings::settingsWriteSucceeded, _connections.get(), [weakSelf](const QString &key) {
            PTSettingsBridge *b = weakSelf; if (b.onWriteSucceeded) b.onWriteSucceeded(string(key));
        });
        QObject::connect(settings, &AppSettings::settingsWriteFailed, _connections.get(), [weakSelf](const QString &key, const QString &message) {
            PTSettingsBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onWriteFailed) b.onWriteFailed(string(key), string(message));
        });
        QObject::connect(settings, &AppSettings::lastModeChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onLastModeChanged) b.onLastModeChanged(); });
        QObject::connect(settings, &AppSettings::workMinutesChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onWorkMinutesChanged) b.onWorkMinutesChanged(); });
        QObject::connect(settings, &AppSettings::breakMinutesChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onBreakMinutesChanged) b.onBreakMinutesChanged(); });
        QObject::connect(settings, &AppSettings::freeTimerWarningHoursChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onFreeTimerWarningHoursChanged) b.onFreeTimerWarningHoursChanged(); });
        QObject::connect(settings, &AppSettings::soundEnabledChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSoundEnabledChanged) b.onSoundEnabledChanged(); });
        QObject::connect(settings, &AppSettings::reduceMotionChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onReduceMotionChanged) b.onReduceMotionChanged(); });
        QObject::connect(settings, &AppSettings::slimClockFontChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSlimClockFontChanged) b.onSlimClockFontChanged(); });
        QObject::connect(settings, &AppSettings::rolloverIgnoredDateChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onRolloverIgnoredDateChanged) b.onRolloverIgnoredDateChanged(); });
        QObject::connect(settings, &AppSettings::backgroundThemeChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onBackgroundThemeChanged) b.onBackgroundThemeChanged(); });
        QObject::connect(settings, &AppSettings::dayStartHourChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onDayStartHourChanged) b.onDayStartHourChanged(); });
        QObject::connect(settings, &AppSettings::nicknameChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onNicknameChanged) b.onNicknameChanged(); });
        QObject::connect(settings, &AppSettings::sidebarVisibleChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSidebarVisibleChanged) b.onSidebarVisibleChanged(); });
        QObject::connect(settings, &AppSettings::sidebarOrderChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSidebarOrderChanged) b.onSidebarOrderChanged(); });
        QObject::connect(settings, &AppSettings::sidebarOrderChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSidebarOrderIsDefaultChanged) b.onSidebarOrderIsDefaultChanged(); });
        QObject::connect(settings, &AppSettings::dashboardTimerVisibleChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onDashboardTimerVisibleChanged) b.onDashboardTimerVisibleChanged(); });
        QObject::connect(settings, &AppSettings::reduceTransparencyChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onReduceTransparencyChanged) b.onReduceTransparencyChanged(); });
        QObject::connect(settings, &AppSettings::naturalCompletionNoticeShownChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onNaturalCompletionNoticeShownChanged) b.onNaturalCompletionNoticeShownChanged(); });
        QObject::connect(settings, &AppSettings::autoStartBreakChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onAutoStartBreakChanged) b.onAutoStartBreakChanged(); });
        QObject::connect(settings, &AppSettings::autoStartNextPomodoroChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onAutoStartNextPomodoroChanged) b.onAutoStartNextPomodoroChanged(); });
        QObject::connect(settings, &AppSettings::quickStartEnabledChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onQuickStartEnabledChanged) b.onQuickStartEnabledChanged(); });
        QObject::connect(settings, &AppSettings::longBreakEnabledChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onLongBreakEnabledChanged) b.onLongBreakEnabledChanged(); });
        QObject::connect(settings, &AppSettings::longBreakMinutesChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onLongBreakMinutesChanged) b.onLongBreakMinutesChanged(); });
        QObject::connect(settings, &AppSettings::longBreakIntervalChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onLongBreakIntervalChanged) b.onLongBreakIntervalChanged(); });
        QObject::connect(settings, &AppSettings::semesterStartDateChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSemesterStartDateChanged) b.onSemesterStartDateChanged(); });
        QObject::connect(settings, &AppSettings::semesterWeeksChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onSemesterWeeksChanged) b.onSemesterWeeksChanged(); });
        QObject::connect(settings, &AppSettings::scheduleDisplayModeChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onScheduleDisplayModeChanged) b.onScheduleDisplayModeChanged(); });
        QObject::connect(settings, &AppSettings::scheduleShowWeekendChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onScheduleShowWeekendChanged) b.onScheduleShowWeekendChanged(); });
        QObject::connect(settings, &AppSettings::dailyFocusGoalChanged, _connections.get(), [weakSelf] { PTSettingsBridge *b = weakSelf; if (b.onDailyFocusGoalChanged) b.onDailyFocusGoalChanged(); });
    } return self;
}
- (PTSettingsSnapshot *)snapshot {
    NSAssert(NSThread.isMainThread, @"设置读取必须在主线程"); NSAssert(_settings, @"设置服务已释放");
    return [[PTSettingsSnapshot alloc] initWithSettings:_settings.data()];
}
- (BOOL)setLastMode:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setLastMode(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setWorkMinutes:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setWorkMinutes(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setBreakMinutes:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setBreakMinutes(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setFreeTimerWarningHours:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setFreeTimerWarningHours(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setSoundEnabled:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setSoundEnabled(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setReduceMotion:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setReduceMotion(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setSlimClockFont:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setSlimClockFont(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setRolloverIgnoredDate:(NSString *)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setRolloverIgnoredDate(string(value));
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setBackgroundTheme:(NSString *)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setBackgroundTheme(string(value));
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setDayStartHour:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setDayStartHour(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setNickname:(NSString *)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setNickname(string(value));
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setSidebarVisible:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setSidebarVisible(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setSidebarOrder:(NSArray<NSString *> *)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    QStringList converted; for (NSString *item in value) converted.append(string(item));
    FailureCollector::Call call(_failures); _settings->setSidebarOrder(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setDashboardTimerVisible:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setDashboardTimerVisible(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setReduceTransparency:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setReduceTransparency(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setNaturalCompletionNoticeShown:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setNaturalCompletionNoticeShown(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setAutoStartBreak:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setAutoStartBreak(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setAutoStartNextPomodoro:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setAutoStartNextPomodoro(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setQuickStartEnabled:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setQuickStartEnabled(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setLongBreakEnabled:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setLongBreakEnabled(value);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setLongBreakMinutes:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setLongBreakMinutes(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setLongBreakInterval:(NSInteger)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(value, &converted)) return fail(error, QStringLiteral("设置值越界"));
    FailureCollector::Call call(_failures); _settings->setLongBreakInterval(converted);
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)setScheduleDisplayMode:(NSString *)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->setScheduleDisplayMode(string(value));
    return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (BOOL)resetSidebarOrder:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"设置写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    FailureCollector::Call call(_failures); _settings->resetSidebarOrder(); return call.error().isEmpty() ? YES : fail(error, call.error());
}
- (NSInteger)dailyFocusGoal:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"目标读取必须在主线程"); return _settings ? _settings->dailyFocusGoalMinutesForDate(string(iso)) : 0;
}
- (BOOL)setDailyFocusGoal:(NSString *)iso minutes:(NSInteger)minutes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"目标写入必须在主线程"); if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int value; if (!integer(minutes, &value)) return fail(error, QStringLiteral("每日目标越界"));
    FailureCollector::Call call(_failures); const bool ok = _settings->setDailyFocusGoal(string(iso), value);
    return ok ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存每日目标失败") : call.error());
}
@end
