#import "PTShellBridge.h"
#include "../native/IPadUiPreferences.h"

#include "../../../services/AppSettings.h"
#include "../../../services/CountdownService.h"
#include "../../../services/BackupService.h"
#include "../../../services/DatabaseManager.h"
#include "../../../services/FocusHistoryService.h"
#include "../../../services/FocusTimer.h"
#include "../../../services/KnowledgeGapService.h"
#include "../../../services/LogicalDayService.h"
#include "../../../services/StatisticsService.h"
#include "../../../services/TaskManager.h"
#include <QFile>
#include <QObject>
#include <QSettings>
#include <QSqlDatabase>
#include <QVariantMap>
#include <limits>
#include <memory>

@interface PTShellSnapshot ()
- (instancetype)initWithToday:(const QVariantMap &)today week:(const QVariantList &)week
                         gaps:(const QVariantMap &)gaps error:(const QString &)error;
@end
@interface PTShellTimerSnapshot ()
- (instancetype)initWithError:(const QString &)error;
@end
@implementation PTShellSnapshot
- (instancetype)initWithToday:(const QVariantMap &)today week:(const QVariantList &)week
                         gaps:(const QVariantMap &)gaps error:(const QString &)error
{
    if ((self = [super init])) {
        _valid = error.isEmpty();
        _error = error.toNSString();
        // 只投影统计服务已经计算的总数与完成数；逻辑日、有效专注和到期条件均由原服务决定。
        _todayPendingCount = today.value(QStringLiteral("totalTasks")).toInt()
            - today.value(QStringLiteral("completedTasks")).toInt();
        for (const QVariant &value : week) {
            const auto day = value.toMap();
            _weekPendingCount += day.value(QStringLiteral("tasks")).toInt()
                - day.value(QStringLiteral("completedTasks")).toInt();
        }
        _todayFocusedSeconds = today.value(QStringLiteral("totalDuration")).toInt();
        _dueGapCount = gaps.value(QStringLiteral("dueToday")).toInt() + gaps.value(QStringLiteral("overdue")).toInt();
        const auto *timer = FocusTimer::instance();
        _hasTimer = timer->hasActiveSession() || timer->phase() != FocusTimer::NoPhase;
        _running = timer->isRunning();
        _mode = timer->mode();
        _phase = timer->phase();
        _elapsedSeconds = timer->elapsedSeconds();
        _remainingSeconds = timer->remainingSeconds();
        _currentTaskId = timer->currentTaskId();
        _taskTitle = timer->currentTaskTitle().toNSString();
        _operationBlocksUi = BackupService::instance()->operationBlocksUi();
        _operationText = BackupService::instance()->operationText().toNSString();
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (const QString &id : AppSettings::instance()->sidebarOrder()) [order addObject:id.toNSString()];
        _sidebarOrder = [order copy];
        _backgroundTheme = AppSettings::instance()->backgroundTheme().toNSString();
        // 原生默认采用系统背景。壁纸开关属于本机外观设置，P4 设置页接入同一键，不参与同步。
        const QSettings settings;
        _useWallpaper = settings.value(QStringLiteral("ipad/useWallpaper"), false).toBool();
        _selectedPage = settings.value(QStringLiteral("ipad/selectedPage"), QStringLiteral("dashboard")).toString().toNSString();
        // 无外观键的旧设置只推导、不写回；首次主动选择才落键，保留旧壁纸体验。
        _appearance = settings.value(QStringLiteral("ipad/appearance"),
            _useWallpaper ? QStringLiteral("theme") : QStringLiteral("system")).toString().toNSString();
        const auto goal = CountdownService::instance()->primaryGoal().toMap();
        _hasPrimaryGoal = !goal.isEmpty();
        _primaryGoalName = goal.value(QStringLiteral("name")).toString().toNSString();
        _primaryGoalDaysRemaining = goal.value(QStringLiteral("daysRemaining")).toInt();
        _maxCaptureTitleLength = KnowledgeGapService::instance()->maxTitleLength();
    }
    return self;
}
@end

@implementation PTShellTimerSnapshot
- (instancetype)initWithError:(const QString &)error
{
    if ((self = [super init])) {
        _valid = error.isEmpty();
        _error = error.toNSString();
        const auto *timer = FocusTimer::instance();
        _hasTimer = timer->hasActiveSession() || timer->phase() != FocusTimer::NoPhase;
        _running = timer->isRunning();
        _mode = timer->mode();
        _phase = timer->phase();
        _elapsedSeconds = timer->elapsedSeconds();
        _remainingSeconds = timer->remainingSeconds();
        _currentTaskId = timer->currentTaskId();
        _taskTitle = timer->currentTaskTitle().toNSString();
    }
    return self;
}
@end

@implementation PTShellBridge {
    std::unique_ptr<QObject> _connections;
    QString _readError;
    bool _reading;
}
- (instancetype)init
{
    NSAssert(NSThread.isMainThread, @"外壳桥接只能在主线程创建");
    if ((self = [super init])) {
        // QObject 是 Qt 信号的接收上下文，随桥接对象析构自动断连；弱引用防止回调块形成保留环。
        _connections = std::make_unique<QObject>();
        __weak PTShellBridge *weakSelf = self;
        const auto changed = [weakSelf] {
            PTShellBridge *bridge = weakSelf;
            if (bridge.onChanged) bridge.onChanged();
        };
        const auto failed = [weakSelf](const QString &message) {
            PTShellBridge *bridge = weakSelf;
            if (!bridge) return;
            if (bridge->_reading) bridge->_readError = message;
            else if (bridge.onFailure) bridge.onFailure(message.toNSString());
        };
        // 服务均属主线程；AutoConnection 在跨线程发信号时排队到此上下文，Swift 始终在主线程收到回调。
        QObject *context = _connections.get();
        auto *tasks = TaskManager::instance();
        auto *timer = FocusTimer::instance();
        auto *history = FocusHistoryService::instance();
        auto *gaps = KnowledgeGapService::instance();
        auto *settings = AppSettings::instance();
        auto *backup = BackupService::instance();
        QObject::connect(tasks, &TaskManager::tasksChanged, context, changed);
        const auto timerChanged = [weakSelf] {
            PTShellBridge *bridge = weakSelf;
            if (bridge && bridge.onTimerChanged) bridge.onTimerChanged();
        };
        QObject::connect(timer, &FocusTimer::tick, context, timerChanged);
        QObject::connect(timer, &FocusTimer::currentTaskChanged, context, timerChanged);
        QObject::connect(timer, &FocusTimer::runningStateChanged, context, timerChanged);
        QObject::connect(timer, &FocusTimer::phaseChanged, context, timerChanged);
        QObject::connect(timer, &FocusTimer::modeChanged, context, timerChanged);
        QObject::connect(history, &FocusHistoryService::historyChanged, context, changed);
        QObject::connect(gaps, &KnowledgeGapService::gapsChanged, context, changed);
        QObject::connect(CountdownService::instance(), &CountdownService::primaryGoalChanged, context, changed);
        QObject::connect(settings, &AppSettings::sidebarOrderChanged, context, changed);
        QObject::connect(settings, &AppSettings::backgroundThemeChanged, context, changed);
        QObject::connect(LogicalDayService::instance(), &LogicalDayService::changed, context, changed);
        QObject::connect(backup, &BackupService::operationBlocksUiChanged, context, changed);
        QObject::connect(backup, &BackupService::operationTextChanged, context, changed);
        QObject::connect(tasks, &TaskManager::operationFailed, context, failed);
        QObject::connect(timer, &FocusTimer::operationFailed, context, failed);
        QObject::connect(gaps, &KnowledgeGapService::operationFailed, context, failed);
        QObject::connect(StatisticsService::instance(), &StatisticsService::operationFailed, context, failed);
    }
    return self;
}
+ (NSData *)wallpaperDataForTheme:(NSString *)theme
{
    // 白名单只是资源名映射，不接受任意文件路径；图片和 QML 共用同一份 qrc 资源。
    const QString id = QString::fromNSString(theme);
    const QStringList themes = {QStringLiteral("warm"), QStringLiteral("pink"), QStringLiteral("jiangnan"),
        QStringLiteral("sword"), QStringLiteral("starry"), QStringLiteral("rainy"), QStringLiteral("moon")};
    if (!themes.contains(id)) return nil;
    QFile file(QStringLiteral(":/resources/wallpapers/%1.png").arg(id));
    if (!file.open(QIODevice::ReadOnly)) return nil;
    const QByteArray data = file.readAll();
    return [NSData dataWithBytes:data.constData() length:static_cast<NSUInteger>(data.size())];
}
- (PTShellSnapshot *)readSnapshot
{
    NSAssert(NSThread.isMainThread, @"读取外壳状态必须在主线程");
    _readError.clear();
    _reading = true;
    QVariantMap today;
    QVariantList week;
    QVariantMap gaps;
    if (!DatabaseManager::instance()->database().isOpen()) {
        _readError = QStringLiteral("数据库未打开");
    } else {
        today = StatisticsService::instance()->getTodayStats();
        week = StatisticsService::instance()->getWeekStats();
        gaps = KnowledgeGapService::instance()->getReminderSummary();
        if (!gaps.value(QStringLiteral("valid")).toBool() && _readError.isEmpty())
            _readError = QStringLiteral("读取知识缺口失败");
    }
    _reading = false;
    return [[PTShellSnapshot alloc] initWithToday:today week:week gaps:gaps error:_readError];
}
- (PTShellTimerSnapshot *)readTimerSnapshot
{
    NSAssert(NSThread.isMainThread, @"读取计时状态必须在主线程");
    return [[PTShellTimerSnapshot alloc] initWithError:QString()];
}
- (BOOL)setUseWallpaper:(BOOL)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"外观设置必须在主线程");
    QSettings settings;
    const QString key = QStringLiteral("ipad/useWallpaper");
    const bool existed = settings.contains(key);
    const QVariant previous = settings.value(key);
    settings.setValue(QStringLiteral("ipad/useWallpaper"), value);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        // QSettings 写失败仍保留内存值；还原它，随后外壳读取继续显示旧偏好。
        if (existed) settings.setValue(key, previous); else settings.remove(key);
        settings.sync();
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"壁纸设置保存失败"}];
        return NO;
    }
    if (self.onChanged) self.onChanged();
    return YES;
}
- (BOOL)selectTheme:(NSString *)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"主题设置必须在主线程");
    const QString theme = QString::fromNSString(value);
    const QStringList themes = {QStringLiteral("warm"), QStringLiteral("pink"), QStringLiteral("jiangnan"),
        QStringLiteral("sword"), QStringLiteral("starry"), QStringLiteral("rainy"), QStringLiteral("moon")};
    if (!themes.contains(theme)) {
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无效的主题选项"}];
        return NO;
    }
    QSettings settings;
    const QString appearanceKey = QStringLiteral("ipad/appearance");
    const QVariant oldAppearance = settings.value(appearanceKey);
    const bool hadAppearance = settings.contains(appearanceKey);
    // 两个键在同一 QSettings 缓存中一起刷盘；只在成功后转发原主题信号，避免半选择被页面读到。
    const QString themeKey = QStringLiteral("appearance/backgroundTheme");
    const QVariant oldTheme = settings.value(themeKey);
    const bool hadTheme = settings.contains(themeKey);
    settings.setValue(appearanceKey, QStringLiteral("theme"));
    settings.setValue(themeKey, theme);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        if (hadAppearance) settings.setValue(appearanceKey, oldAppearance); else settings.remove(appearanceKey);
        if (hadTheme) settings.setValue(themeKey, oldTheme); else settings.remove(themeKey);
        settings.sync();
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"主题设置保存失败"}];
        return NO;
    }
    emit AppSettings::instance()->backgroundThemeChanged();
    return YES;
}
- (BOOL)setAppearance:(NSString *)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"外观设置必须在主线程");
    const QString mode = QString::fromNSString(value);
    const QStringList modes = {QStringLiteral("system"), QStringLiteral("light"), QStringLiteral("dark"), QStringLiteral("theme")};
    if (!modes.contains(mode)) {
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无效的外观选项"}];
        return NO;
    }
    QSettings settings;
    const QString key = QStringLiteral("ipad/appearance");
    const bool existed = settings.contains(key);
    const QVariant previous = settings.value(key);
    settings.setValue(key, mode);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        // 写失败仍会改变 QSettings 内存缓存；恢复旧值或无键状态，不广播成功刷新。
        if (existed) settings.setValue(key, previous); else settings.remove(key);
        settings.sync();
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"外观设置保存失败"}];
        return NO;
    }
    if (self.onChanged) self.onChanged();
    return YES;
}
- (BOOL)setNativeUI:(BOOL)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"界面偏好必须在主线程保存");
    QString message;
    if (IPadUiPreferences::writeNativeUI(value, &message)) return YES;
    if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message.toNSString()}];
    return NO;
}
- (BOOL)pause
{
    NSAssert(NSThread.isMainThread, @"计时动作必须在主线程");
    return FocusTimer::instance()->pauseFocus();
}
- (BOOL)resume
{
    NSAssert(NSThread.isMainThread, @"计时动作必须在主线程");
    return FocusTimer::instance()->resumeFocus();
}
- (NSInteger)captureTitle:(NSString *)title categoryId:(NSInteger)categoryId sourceTaskId:(NSInteger)sourceTaskId
{
    NSAssert(NSThread.isMainThread, @"快速记录必须在主线程");
    // Objective-C 的 NSInteger 比服务编号宽；越界拒绝，避免截断后关联到另一条记录。
    if (categoryId < -1 || categoryId > std::numeric_limits<int>::max()
        || sourceTaskId < -1 || sourceTaskId > std::numeric_limits<int>::max()) return -1;
    return KnowledgeGapService::instance()->captureGap(QString::fromNSString(title),
        static_cast<int>(categoryId), static_cast<int>(sourceTaskId));
}
- (void)selectPage:(NSString *)page
{
    NSAssert(NSThread.isMainThread, @"页面状态必须在主线程保存");
    QSettings().setValue(QStringLiteral("ipad/selectedPage"), QString::fromNSString(page));
}
@end
