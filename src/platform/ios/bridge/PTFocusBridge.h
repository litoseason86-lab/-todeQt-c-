#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

__attribute__((swift_attr("@MainActor")))
@interface PTFocusSnapshot : NSObject
@property(nonatomic, readonly) NSInteger mode;
@property(nonatomic, readonly) NSInteger phase;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) BOOL hasActiveSession;
@property(nonatomic, readonly) NSInteger elapsedSeconds;
@property(nonatomic, readonly) NSInteger remainingSeconds;
@property(nonatomic, readonly) NSInteger targetSeconds;
@property(nonatomic, readonly) NSInteger currentTaskId;
@property(nonatomic, readonly, copy) NSString * currentTaskTitle;
@property(nonatomic, readonly) NSInteger completedPomodoros;
@property(nonatomic, readonly) BOOL freeTimingAllowed;
@property(nonatomic, readonly) BOOL manualRestAllowed;
@property(nonatomic, readonly, copy) NSString * sessionLogicalDate;
@property(nonatomic, readonly) NSInteger minimumValidMinutes;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusTaskEntry : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly, copy) NSString * kind;
@property(nonatomic, readonly) BOOL usePomodoro;
@property(nonatomic, readonly) BOOL autoStart;
@property(nonatomic, readonly, copy) NSString * title;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusSwitchConsequence : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly, copy) NSString * kind;
@property(nonatomic, readonly) NSInteger minimumMinutes;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusSwitchSource : NSObject
- (instancetype)initWithTaskId:(NSInteger)taskId mode:(NSInteger)mode phase:(NSInteger)phase;
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly) NSInteger mode;
@property(nonatomic, readonly) NSInteger phase;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusModeSwitch : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly, copy) NSString * kind;
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString * title;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusCandidate : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString * title;
@property(nonatomic, readonly) BOOL selectionStale;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusEndResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly, copy) NSString * result;
@property(nonatomic, readonly, copy) NSString * kind;
@property(nonatomic, readonly) BOOL discarded;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusFinishResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly) BOOL ok;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusTaskCompletion : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString * error;
@property(nonatomic, readonly, copy) NSString * focusResult;
@property(nonatomic, readonly, copy) NSString * kind;
@property(nonatomic, readonly) BOOL discarded;
@end

__attribute__((swift_attr("@MainActor")))
@interface PTFocusBridge : NSObject
@property(nonatomic, readonly) PTFocusSnapshot *snapshot;
@property(nonatomic, copy, nullable) void (^onTick)(void);
@property(nonatomic, copy, nullable) void (^onRunningStateChanged)(void);
@property(nonatomic, copy, nullable) void (^onPhaseChanged)(void);
@property(nonatomic, copy, nullable) void (^onModeChanged)(void);
@property(nonatomic, copy, nullable) void (^onCurrentTaskChanged)(void);
@property(nonatomic, copy, nullable) void (^onCompletedPomodorosChanged)(void);
@property(nonatomic, copy, nullable) void (^onSessionLogicalDateChanged)(void);
@property(nonatomic, copy, nullable) void (^onFreeTimingAllowedChanged)(void);
@property(nonatomic, copy, nullable) void (^onManualRestAllowedChanged)(void);
@property(nonatomic, copy, nullable) void (^onFocusCompleted)(NSInteger duration);
@property(nonatomic, copy, nullable) void (^onRestCompleted)(void);
@property(nonatomic, copy, nullable) void (^onPhaseCompleted)(NSInteger phase);
@property(nonatomic, copy, nullable) void (^onSessionDiscarded)(NSInteger duration);
@property(nonatomic, copy, nullable) void (^onPhaseSettledOffline)(NSInteger phase);
@property(nonatomic, copy, nullable) void (^onTaskAutoCompleteFailed)(NSInteger taskId);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
// 到点提醒没能交给系统预约（PhaseAlarmCoordinator::alarmUnavailable）；协调器只在移动端创建，
// 登记处取不到时本信号永远不发。
@property(nonatomic, copy, nullable) void (^onAlarmUnavailable)(NSString *reason);
// 系统通知没有发出（NotificationService::notificationDeliveryFailed）。
@property(nonatomic, copy, nullable) void (^onNotificationDeliveryFailed)(NSString *reason);
- (BOOL)startFree:(NSInteger)taskId title:(NSString *)title error:(NSError **)error;
- (BOOL)startPomodoro:(NSInteger)taskId title:(NSString *)title seconds:(NSInteger)seconds error:(NSError **)error;
- (BOOL)pause:(NSError **)error;
- (BOOL)resume:(NSError **)error;
- (BOOL)startBreak:(NSInteger)seconds taskId:(NSInteger)taskId title:(NSString *)title error:(NSError **)error;
- (PTFocusTaskEntry *)planTaskEntry:(NSInteger)taskId title:(NSString *)title;
- (PTFocusSwitchConsequence *)switchConsequence;
- (PTFocusSwitchSource *)captureSwitchSource;
- (NSString * _Nullable)stopForSwitch:(PTFocusSwitchSource *)source error:(NSError **)error;
- (PTFocusModeSwitch *)planModeSwitch:(NSInteger)taskId title:(NSString *)title;
- (PTFocusCandidate *)autoStartCandidate:(NSInteger)taskId title:(NSString *)title;
- (NSInteger)createTodayTask:(NSString *)title error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTFocusTaskCompletion *)handleTaskCompleted:(NSInteger)taskId;
- (NSInteger)freeTimerWarningHours:(NSError **)error __attribute__((swift_error(nonnull_error)));
// false 是合法判断结果，错误另走 NSError，不能让 Swift 将 false 当成调用失败。
- (BOOL)needsLongFreeStopConfirmation:(NSError **)error __attribute__((swift_error(nonnull_error)));
// 长休息判定，见 FocusSessionController::nextBreakMinutes；selectedBreakMinutes 是页面当前选的休息时长。
- (NSInteger)nextBreakMinutes:(NSInteger)selectedBreakMinutes error:(NSError **)error __attribute__((swift_error(nonnull_error)));
// 阶段自然完成后要不要自动衔接，见 FocusSessionController::autoAdvanceAfter；延迟到点时要再问一次。
- (BOOL)autoAdvanceAfterPhase:(NSInteger)completedPhase error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTFocusEndResult *)endCurrent;
- (PTFocusEndResult *)endPomodoroCycle;
- (PTFocusFinishResult *)finishLongFree:(BOOL)recordSession correctedSeconds:(NSInteger)seconds;
@end
NS_ASSUME_NONNULL_END
