#import "PTShellBridge.h"
#include "PTBridgeSupport.h"
#include "../native/IPadUiPreferences.h"
#include "../native/IPadShellPreferences.h"

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
#include <QDebug>
#include <QSqlDatabase>
#include <QVariantMap>
#include <limits>
#include <memory>

@interface PTShellSnapshot ()
- (instancetype)initWithSummary:(const QVariantMap &)summary
                           gaps:(const QVariantMap &)gaps
                          error:(const QString &)error;
@end
@interface PTShellTimerSnapshot ()
- (instancetype)initWithError:(const QString &)error;
@end
@implementation PTShellSnapshot
- (instancetype)initWithSummary:(const QVariantMap &)summary
                           gaps:(const QVariantMap &)gaps
                          error:(const QString &)error
{
    if ((self = [super init])) {
        _valid = error.isEmpty();
        _error = error.toNSString();
        // 只投影统计服务已经计算的摘要与缺口数；逻辑日、有效专注和到期条件均由原服务决定。
        _todayPendingCount = summary.value(QStringLiteral("todayPendingCount")).toInt();
        _weekPendingCount = summary.value(QStringLiteral("weekPendingCount")).toInt();
        _todayFocusedSeconds = summary.value(QStringLiteral("todayFocusedSeconds")).toInt();
        _dueGapCount = gaps.value(QStringLiteral("dueCount")).toInt();
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
        const auto preferences = IPadShellPreferences::readSnapshot();
        _useWallpaper = preferences.useWallpaper;
        _selectedPage = preferences.selectedPage.toNSString();
        _appearance = preferences.appearance.toNSString();
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
    PTBridgeSupport::FailureCollector _failures;
}
- (instancetype)init
{
    NSAssert(NSThread.isMainThread, @"外壳桥接只能在主线程创建");
    if ((self = [super init])) {
        // QObject 是 Qt 信号的接收上下文，随桥接对象析构自动断连；弱引用防止回调块形成保留环。
        _connections = std::make_unique<QObject>();
        __weak PTShellBridge *weakSelf = self;
        // 外壳负责调用方未认领的失败；登记不保留桥接，析构时撤销接收上下文。
        PTBridgeSupport::registerUnclaimedFailureHandler(_connections.get(), [weakSelf](const QString &message) {
            PTShellBridge *bridge = weakSelf;
            if (bridge.onFailure) bridge.onFailure(message.toNSString());
        });
        const auto changed = [weakSelf] {
            PTShellBridge *bridge = weakSelf;
            if (bridge.onChanged) bridge.onChanged();
        };
        const auto failed = [weakSelf](const QString &message) {
            PTShellBridge *bridge = weakSelf;
            if (!bridge) return;
            if (!bridge->_failures.collect(message))
                PTBridgeSupport::reportUnclaimedFailure(message, bridge->_connections.get());
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
- (void)dealloc
{
    PTBridgeSupport::unregisterUnclaimedFailureHandler(_connections.get());
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
    PTBridgeSupport::FailureCollector::Call call(_failures);
    QString readError;
    QVariantMap summary;
    QVariantMap gaps;
    if (!DatabaseManager::instance()->database().isOpen()) {
        readError = QStringLiteral("数据库未打开");
    } else {
        summary = StatisticsService::instance()->getTaskSummary();
        gaps = KnowledgeGapService::instance()->getReminderSummary();
    }
    const QString collected = call.error();
    if (readError.isEmpty()) readError = collected;
    if (readError.isEmpty() && !gaps.value(QStringLiteral("valid")).toBool())
        readError = QStringLiteral("读取知识缺口失败");
    return [[PTShellSnapshot alloc] initWithSummary:summary gaps:gaps error:readError];
}
- (PTShellTimerSnapshot *)readTimerSnapshot
{
    NSAssert(NSThread.isMainThread, @"读取计时状态必须在主线程");
    return [[PTShellTimerSnapshot alloc] initWithError:QString()];
}
- (BOOL)setUseWallpaper:(BOOL)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"外观设置必须在主线程");
    QString message;
    if (!IPadShellPreferences::setUseWallpaper(value, &message)) {
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message.toNSString()}];
        return NO;
    }
    if (self.onChanged) self.onChanged();
    return YES;
}
- (BOOL)selectTheme:(NSString *)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"主题设置必须在主线程");
    QString message;
    bool needsRefresh = false;
    if (!IPadShellPreferences::selectTheme(QString::fromNSString(value), &message, &needsRefresh)) {
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message.toNSString()}];
        return NO;
    }
    // 主题变化已从 Qt 服务信号转发；C++ 要求补刷新时，才通知原生外壳，避免重复广播。
    if (needsRefresh && self.onChanged) self.onChanged();
    return YES;
}
- (BOOL)setAppearance:(NSString *)value error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"外观设置必须在主线程");
    QString message;
    if (!IPadShellPreferences::setAppearance(QString::fromNSString(value), &message)) {
        if (error) *error = [NSError errorWithDomain:@"PTShellBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message.toNSString()}];
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
- (BOOL)pause:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"计时动作必须在主线程");
    // Swift 必须认领本次失败原因，不能在外壳收到信号后又按 bool 另显示一次通用提示。
    PTBridgeSupport::FailureCollector::Call call(_failures);
    return FocusTimer::instance()->pauseFocus() || PTBridgeSupport::fail(error, call.error());
}
- (BOOL)resume:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"计时动作必须在主线程");
    PTBridgeSupport::FailureCollector::Call call(_failures);
    return FocusTimer::instance()->resumeFocus() || PTBridgeSupport::fail(error, call.error());
}
- (NSInteger)captureTitle:(NSString *)title categoryId:(NSInteger)categoryId sourceTaskId:(NSInteger)sourceTaskId error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"快速记录必须在主线程");
    // Objective-C 的 NSInteger 比服务编号宽；越界拒绝，避免截断后关联到另一条记录。
    if (categoryId < -1 || categoryId > std::numeric_limits<int>::max()) {
        PTBridgeSupport::fail(error, QStringLiteral("科目编号无效"));
        return -1;
    }
    if (sourceTaskId < -1 || sourceTaskId > std::numeric_limits<int>::max()) {
        PTBridgeSupport::fail(error, QStringLiteral("来源编号无效"));
        return -1;
    }
    // 参数拒绝与服务拒绝都从 NSError 返回，不依赖上一次外壳错误或后台失败回调。
    PTBridgeSupport::FailureCollector::Call call(_failures);
    const int id = KnowledgeGapService::instance()->captureGap(QString::fromNSString(title),
        static_cast<int>(categoryId), static_cast<int>(sourceTaskId));
    if (id <= 0) PTBridgeSupport::fail(error, call.error());
    return id;
}
- (BOOL)selectPage:(NSString *)page error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"页面状态必须在主线程保存");
    QString message;
    if (!IPadShellPreferences::setSelectedPage(QString::fromNSString(page), &message)) {
        qWarning().noquote() << message;
        return PTBridgeSupport::fail(error, message);
    }
    return YES;
}
@end
