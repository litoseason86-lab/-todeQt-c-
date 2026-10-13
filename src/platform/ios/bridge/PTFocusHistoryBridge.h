#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTSessionValue : NSObject
@property(nonatomic, readonly) NSInteger sessionId;
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString *taskTitle;
@property(nonatomic, readonly, copy) NSString *startTime;
@property(nonatomic, readonly, copy) NSString *endTime;
@property(nonatomic, readonly) NSInteger durationSeconds;
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) BOOL isRest;
@end
@interface PTSessionTaskOption : NSObject
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString *title;
@end
@interface PTFocusHistoryResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTSessionValue *> *sessions;
@property(nonatomic, readonly, copy) NSArray<PTSessionTaskOption *> *taskOptions;
@property(nonatomic, readonly) NSInteger count;
@property(nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *dailyTotals;
@end
// has 标记区分未改与清空；时刻遵循 PTBridgeSupport 的带毫秒 ISO 约定。
@interface PTSessionChanges : NSObject
@property(nonatomic, copy) NSString *startTime;
@property(nonatomic) NSInteger durationSeconds;
@property(nonatomic) NSInteger taskId;
@property(nonatomic) BOOL isRest;
@property(nonatomic, readonly) BOOL hasStartTime;
@property(nonatomic, readonly) BOOL hasDurationSeconds;
@property(nonatomic, readonly) BOOL hasTaskId;
@property(nonatomic, readonly) BOOL hasIsRest;
@end
@interface PTFocusHistoryBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, readonly, copy) NSString *lastError;
- (PTFocusHistoryResult *)monthSessions:(NSInteger)year month:(NSInteger)month;
- (PTFocusHistoryResult *)daySessions:(NSString *)date;
- (PTFocusHistoryResult *)dayTimeline:(NSString *)date;
- (PTFocusHistoryResult *)monthDailyTotals:(NSInteger)year month:(NSInteger)month;
- (PTFocusHistoryResult *)dayTotalDuration:(NSString *)date;
- (PTFocusHistoryResult *)invalidSessionCount;
- (PTFocusHistoryResult *)taskOptions:(NSString *)date;
- (NSInteger)bandForMinutes:(double)minutes;
- (NSString *)formatDuration:(NSInteger)seconds;
- (NSInteger)cleanupInvalidSessions:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSInteger)addManualSession:(NSInteger)taskId startTime:(NSString *)startTime durationMinutes:(NSInteger)minutes error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)updateSession:(NSInteger)sessionId changes:(PTSessionChanges *)changes error:(NSError **)error;
- (BOOL)updateRestSession:(NSInteger)sessionId changes:(PTSessionChanges *)changes error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
