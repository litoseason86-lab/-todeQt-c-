#import "PTFocusBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/FocusTimer.h"
#include "../../../services/FocusSessionController.h"
#include "../../../services/TaskManager.h"
#include "../../../services/NotificationService.h"
#include "../../../services/PhaseAlarmCoordinator.h"
#include <memory>
using namespace PTBridgeSupport;

@interface PTFocusSnapshot ()
- (instancetype)initWithValue:(FocusTimer *)value;
@end
@interface PTFocusTaskEntry ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusSwitchConsequence ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusSwitchSource ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusModeSwitch ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusCandidate ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusEndResult ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusFinishResult ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end
@interface PTFocusTaskCompletion ()
- (instancetype)initWithValue:(const QVariantMap &)value;
@end

@implementation PTFocusSnapshot
- (instancetype)initWithValue:(FocusTimer *)value {
    if ((self = [super init])) {
        _mode = value->mode();
        _phase = value->phase();
        _running = value->isRunning();
        _hasActiveSession = value->hasActiveSession();
        _elapsedSeconds = value->elapsedSeconds();
        _remainingSeconds = value->remainingSeconds();
        _targetSeconds = value->targetSeconds();
        _currentTaskId = value->currentTaskId();
        _currentTaskTitle = string(value->currentTaskTitle());
        _completedPomodoros = value->completedPomodoros();
        _freeTimingAllowed = value->freeTimingAllowed();
        _manualRestAllowed = value->manualRestAllowed();
        _sessionLogicalDate = string(value->sessionLogicalDate());
        _sessionStartTime = timestamp(value->sessionStartTime());
        _minimumValidMinutes = value->minimumValidMinutes();
    }
    return self;
}
@end

@implementation PTFocusTaskEntry
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _kind = string(value.value("kind").toString());
        _usePomodoro = value.value("usePomodoro").toBool();
        _autoStart = value.value("autoStart").toBool();
        _title = string(value.value("title").toString());
    }
    return self;
}
@end

@implementation PTFocusSwitchConsequence
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _kind = string(value.value("kind").toString());
        _minimumMinutes = value.value("minimumMinutes").toInt();
    }
    return self;
}
@end

@implementation PTFocusSwitchSource
- (instancetype)initWithTaskId:(NSInteger)taskId mode:(NSInteger)mode phase:(NSInteger)phase {
    if ((self = [super init])) {
        _valid = YES; _error = @""; _taskId = taskId; _mode = mode; _phase = phase;
    }
    return self;
}
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _taskId = value.value("taskId").toInt();
        _mode = value.value("mode").toInt();
        _phase = value.value("phase").toInt();
    }
    return self;
}
@end

@implementation PTFocusModeSwitch
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _kind = string(value.value("kind").toString());
        _taskId = value.value("taskId").toInt();
        _title = string(value.value("title").toString());
    }
    return self;
}
@end

@implementation PTFocusCandidate
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _taskId = value.value("id").toInt();
        _title = string(value.value("title").toString());
        _selectionStale = value.value("selectionStale").toBool();
    }
    return self;
}
@end

@implementation PTFocusEndResult
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _result = string(value.value("result").toString());
        _kind = string(value.value("kind").toString());
        _discarded = value.value("discarded").toBool();
    }
    return self;
}
@end

@implementation PTFocusFinishResult
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _ok = value.value("ok").toBool();
    }
    return self;
}
@end

@implementation PTFocusTaskCompletion
- (instancetype)initWithValue:(const QVariantMap &)value {
    if ((self = [super init])) {
        _valid = value.value("valid", true).toBool();
        _error = string(value.value("error").toString());
        _focusResult = string(value.value("focusResult").toString());
        _kind = string(value.value("kind").toString());
        _discarded = value.value("discarded").toBool();
    }
    return self;
}
@end

namespace {
FocusSessionController *controller() { return service<FocusSessionController>(QStringLiteral("focusController")); }
QVariantMap unavailable() { return {{"valid", false}, {"error", QStringLiteral("专注控制器不可用")}}; }
QVariantMap overflow() { return {{"valid", false}, {"error", QStringLiteral("专注参数越界")}}; }
QVariantMap claimReturnedFailure(const QVariantMap &value, const FailureCollector::Call &call) {
    // 控制器已把失败写进类型化结果，Swift 会按返回值提示，不能再由未认领出口重复上报。
    QVariantMap result = value;
    if (!value.value("valid", true).toBool() || !value.value("error").toString().isEmpty()) {
        const QString reason = call.error();
        if (!reason.isEmpty()) result[QStringLiteral("error")] = reason;
    }
    return result;
}
}
@implementation PTFocusBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"专注桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有接收上下文负责排队回主线程及析构断连；回调弱引用桥接，避免保留环。
        _connections = std::make_unique<QObject>();
        __weak PTFocusBridge *weakSelf = self;
        auto *timer = FocusTimer::instance(); auto *context = _connections.get();
        QObject::connect(timer, &FocusTimer::tick, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onTick) b.onTick(); });
        QObject::connect(timer, &FocusTimer::runningStateChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onRunningStateChanged) b.onRunningStateChanged(); });
        QObject::connect(timer, &FocusTimer::phaseChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onPhaseChanged) b.onPhaseChanged(); });
        QObject::connect(timer, &FocusTimer::modeChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onModeChanged) b.onModeChanged(); });
        QObject::connect(timer, &FocusTimer::currentTaskChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onCurrentTaskChanged) b.onCurrentTaskChanged(); });
        QObject::connect(timer, &FocusTimer::completedPomodorosChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onCompletedPomodorosChanged) b.onCompletedPomodorosChanged(); });
        QObject::connect(timer, &FocusTimer::sessionLogicalDateChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onSessionLogicalDateChanged) b.onSessionLogicalDateChanged(); });
        QObject::connect(timer, &FocusTimer::freeTimingAllowedChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onFreeTimingAllowedChanged) b.onFreeTimingAllowedChanged(); });
        QObject::connect(timer, &FocusTimer::manualRestAllowedChanged, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onManualRestAllowedChanged) b.onManualRestAllowedChanged(); });
        QObject::connect(timer, &FocusTimer::restCompleted, context, [weakSelf] { PTFocusBridge *b = weakSelf; if (b.onRestCompleted) b.onRestCompleted(); });
        QObject::connect(timer, &FocusTimer::focusCompleted, context, [weakSelf](int value) { PTFocusBridge *b = weakSelf; if (b.onFocusCompleted) b.onFocusCompleted(value); });
        QObject::connect(timer, &FocusTimer::phaseCompleted, context, [weakSelf](int value) { PTFocusBridge *b = weakSelf; if (b.onPhaseCompleted) b.onPhaseCompleted(value); });
        QObject::connect(timer, &FocusTimer::sessionDiscarded, context, [weakSelf](int value) { PTFocusBridge *b = weakSelf; if (b.onSessionDiscarded) b.onSessionDiscarded(value); });
        QObject::connect(timer, &FocusTimer::phaseSettledOffline, context, [weakSelf](int value) { PTFocusBridge *b = weakSelf; if (b.onPhaseSettledOffline) b.onPhaseSettledOffline(value); });
        QObject::connect(timer, &FocusTimer::taskAutoCompleteFailed, context, [weakSelf](int value) { PTFocusBridge *b = weakSelf; if (b.onTaskAutoCompleteFailed) b.onTaskAutoCompleteFailed(value); });
        // 调用中同步发出的失败由返回值承接，背景失败单独转发，避免重复提示。
        auto failure = [weakSelf](const QString &message) {
            PTFocusBridge *b = weakSelf;
            if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        };
        QObject::connect(timer, &FocusTimer::operationFailed, context, failure);
        if (auto* c = controller()) QObject::connect(c, &FocusSessionController::operationFailed, context, failure);
        // 提醒类信号只用于前台提示。预约协调器由 main.cpp 在移动端创建并按名字登记，桥接创建时取不到就不连；
        // 登记晚于桥接创建的话本桥接收不到，所以原生根必须在登记之后才创建桥接。
        if (auto *alarms = service<PhaseAlarmCoordinator>(QStringLiteral("phaseAlarms"))) {
            QObject::connect(alarms, &PhaseAlarmCoordinator::alarmUnavailable, context, [weakSelf](const QString &reason) {
                PTFocusBridge *b = weakSelf; if (b.onAlarmUnavailable) b.onAlarmUnavailable(string(reason));
            });
        }
        QObject::connect(NotificationService::instance(), &NotificationService::notificationDeliveryFailed, context, [weakSelf](const QString &reason) {
            PTFocusBridge *b = weakSelf; if (b.onNotificationDeliveryFailed) b.onNotificationDeliveryFailed(string(reason));
        });
        // 新建专注任务的错误仅在调用期收集；其它页面的任务错误由任务桥接处理，不串到专注页。
        QObject::connect(TaskManager::instance(), &TaskManager::operationFailed, context, [weakSelf](const QString &message) {
            PTFocusBridge *b = weakSelf; if (b) b->_failures.collect(message);
        });
    }
    return self;
}
- (PTFocusSnapshot *)snapshot {
    NSAssert(NSThread.isMainThread, @"专注快照必须在主线程读取");
    return [[PTFocusSnapshot alloc] initWithValue:FocusTimer::instance()];
}
- (BOOL)startFree:(NSInteger)taskId title:(NSString *)title error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"专注动作必须在主线程");
    int id;
    if (!integer(taskId, &id)) return fail(error, QStringLiteral("专注参数越界"));
    FailureCollector::Call call(_failures);
    const bool ok = FocusTimer::instance()->startFocus(id, string(title));
    return ok || fail(error, call.error().isEmpty() ? QStringLiteral("自由专注启动失败，请重试") : call.error());
}
- (BOOL)startPomodoro:(NSInteger)taskId title:(NSString *)title seconds:(NSInteger)seconds error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"专注动作必须在主线程");
    int id, duration;
    if (!integer(taskId, &id) || !integer(seconds, &duration)) return fail(error, QStringLiteral("专注参数越界"));
    FailureCollector::Call call(_failures);
    const bool ok = FocusTimer::instance()->startPomodoroWork(id, string(title), duration);
    return ok || fail(error, call.error().isEmpty() ? QStringLiteral("番茄专注启动失败") : call.error());
}
- (BOOL)pause:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"专注动作必须在主线程");
    FailureCollector::Call call(_failures);
    const bool ok = FocusTimer::instance()->pauseFocus();
    return ok || fail(error, call.error().isEmpty() ? QStringLiteral("专注暂停失败，请重试") : call.error());
}
- (BOOL)resume:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"专注动作必须在主线程");
    FailureCollector::Call call(_failures);
    const bool ok = FocusTimer::instance()->resumeFocus();
    return ok || fail(error, call.error().isEmpty() ? QStringLiteral("专注恢复失败") : call.error());
}
- (BOOL)startBreak:(NSInteger)seconds taskId:(NSInteger)taskId title:(NSString *)title error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"专注动作必须在主线程");
    int duration, id;
    if (!integer(seconds, &duration) || !integer(taskId, &id)) return fail(error, QStringLiteral("专注参数越界"));
    FailureCollector::Call call(_failures);
    const bool ok = FocusTimer::instance()->startBreakForTask(duration, id, string(title));
    return ok || fail(error, call.error().isEmpty() ? QStringLiteral("休息启动失败") : call.error());
}
- (PTFocusTaskEntry *)planTaskEntry:(NSInteger)taskId title:(NSString *)title {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    int id; if (!integer(taskId, &id)) return [[PTFocusTaskEntry alloc] initWithValue:overflow()];
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusTaskEntry alloc] initWithValue:claimReturnedFailure(c ? c->planTaskEntry(id, string(title)) : unavailable(), call)];
}
- (PTFocusSwitchConsequence *)switchConsequence {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusSwitchConsequence alloc] initWithValue:claimReturnedFailure(c ? c->switchConsequence() : unavailable(), call)];
}
- (PTFocusSwitchSource *)captureSwitchSource {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusSwitchSource alloc] initWithValue:claimReturnedFailure(c ? c->captureSwitchSource() : unavailable(), call)];
}
- (PTFocusModeSwitch *)planModeSwitch:(NSInteger)taskId title:(NSString *)title {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    int id; if (!integer(taskId, &id)) return [[PTFocusModeSwitch alloc] initWithValue:overflow()];
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusModeSwitch alloc] initWithValue:claimReturnedFailure(c ? c->planModeSwitch(id, string(title)) : unavailable(), call)];
}
- (PTFocusCandidate *)autoStartCandidate:(NSInteger)taskId title:(NSString *)title {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    int id; if (!integer(taskId, &id)) return [[PTFocusCandidate alloc] initWithValue:overflow()];
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusCandidate alloc] initWithValue:claimReturnedFailure(c ? c->autoStartCandidate(id, string(title)) : unavailable(), call)];
}
- (PTFocusTaskCompletion *)handleTaskCompleted:(NSInteger)taskId {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    int id; if (!integer(taskId, &id)) return [[PTFocusTaskCompletion alloc] initWithValue:overflow()];
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusTaskCompletion alloc] initWithValue:claimReturnedFailure(c ? c->handleTaskCompleted(id) : unavailable(), call)];
}
- (PTFocusEndResult *)endCurrent {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusEndResult alloc] initWithValue:claimReturnedFailure(c ? c->endCurrent() : unavailable(), call)];
}
- (PTFocusEndResult *)endPomodoroCycle {
    NSAssert(NSThread.isMainThread, @"专注控制器必须在主线程调用");
    auto *c = controller();
    FailureCollector::Call call(_failures);
    return [[PTFocusEndResult alloc] initWithValue:claimReturnedFailure(c ? c->endPomodoroCycle() : unavailable(), call)];
}
- (NSString *)stopForSwitch:(PTFocusSwitchSource *)source error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"切换确认必须在主线程");
    if (!source.valid) { fail(error, string(source.error)); return nil; }
    auto *c = controller(); if (!c) { fail(error, QStringLiteral("专注控制器不可用")); return nil; }
    // 只传确认打开时的原始三字段，不能在确认时重拍快照，否则会放过 stateChanged。
    int taskId, mode, phase;
    if (!integer(source.taskId, &taskId) || !integer(source.mode, &mode) || !integer(source.phase, &phase)) {
        fail(error, QStringLiteral("专注参数越界")); return nil;
    }
    QVariantMap map{{"taskId", taskId}, {"mode", mode}, {"phase", phase}};
    FailureCollector::Call call(_failures);
    const QString result = c->stopForSwitch(map);
    // 停表失败通过 NSError 保留本次原因；正常的状态变化/超长确认仍返回状态，不制造失败提示。
    if (result == QStringLiteral("stopFailed")) {
        const QString reason = call.error();
        fail(error, reason.isEmpty() ? QStringLiteral("切换计时失败，请重试") : reason);
        return nil;
    }
    return string(result);
}
- (NSInteger)createTodayTask:(NSString *)title error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"新建专注任务必须在主线程");
    auto *c = controller(); if (!c) { fail(error, QStringLiteral("专注控制器不可用")); return -1; }
    FailureCollector::Call call(_failures); const int id = c->createTodayTask(string(title));
    if (id <= 0) fail(error, call.error().isEmpty() ? QStringLiteral("任务创建失败，请重试") : call.error());
    return id;
}
- (NSInteger)freeTimerWarningHours:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"提醒阈值必须在主线程读取");
    auto *c = controller(); if (!c) { fail(error, QStringLiteral("专注控制器不可用")); return 0; }
    return c->freeTimerWarningHours();
}
- (BOOL)needsLongFreeStopConfirmation:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"超长判断必须在主线程调用");
    auto *c = controller(); if (!c) return fail(error, QStringLiteral("专注控制器不可用"));
    return c->needsLongFreeStopConfirmation();
}
- (NSInteger)nextBreakMinutes:(NSInteger)selectedBreakMinutes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"休息时长必须在主线程读取");
    int selected; if (!integer(selectedBreakMinutes, &selected)) { fail(error, QStringLiteral("休息时长越界")); return 0; }
    auto *c = controller(); if (!c) { fail(error, QStringLiteral("专注控制器不可用")); return 0; }
    return c->nextBreakMinutes(selected);
}
- (BOOL)autoAdvanceAfterPhase:(NSInteger)completedPhase error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"自动衔接判断必须在主线程调用");
    int phase; if (!integer(completedPhase, &phase)) return fail(error, QStringLiteral("阶段越界"));
    auto *c = controller(); if (!c) return fail(error, QStringLiteral("专注控制器不可用"));
    return c->autoAdvanceAfter(phase);
}
- (PTFocusFinishResult *)finishLongFree:(BOOL)recordSession correctedSeconds:(NSInteger)seconds {
    NSAssert(NSThread.isMainThread, @"超长确认收尾必须在主线程");
    int duration; if (!integer(seconds, &duration)) return [[PTFocusFinishResult alloc] initWithValue:overflow()];
    auto *c = controller(); FailureCollector::Call call(_failures);
    return [[PTFocusFinishResult alloc] initWithValue:claimReturnedFailure(c ? c->finishLongFree(recordSession, duration) : unavailable(), call)];
}
@end
