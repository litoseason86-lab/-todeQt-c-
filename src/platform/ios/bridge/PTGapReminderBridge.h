#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
__attribute__((swift_attr("@MainActor")))
@interface PTGapReminderSummary : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly) NSInteger dueToday;
@property(nonatomic, readonly) NSInteger overdue;
@property(nonatomic, readonly) NSInteger unscheduled;
@property(nonatomic, readonly) NSInteger openTotal;
@property(nonatomic, readonly) NSInteger oldestOverdueDays;
@end
__attribute__((swift_attr("@MainActor")))
@interface PTGapConversionResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly) NSInteger converted;
@property(nonatomic, readonly) NSInteger failed;
@property(nonatomic, readonly, copy) NSString *reason;
@end
__attribute__((swift_attr("@MainActor")))
@interface PTGapReminderBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onTasksAffected)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTGapReminderSummary *)reminderSummary;
- (PTGapConversionResult *)convertDueGapsToTasks;
@end
NS_ASSUME_NONNULL_END
