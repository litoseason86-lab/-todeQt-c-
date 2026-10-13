#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// 日期为 yyyy-MM-dd；时刻为带毫秒和时区偏移的 ISO 字符串。未关联编号为 -1。
@interface PTTaskValue : NSObject
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString * title;
@property(nonatomic, readonly, copy) NSString * categoryText;
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString * categoryName;
@property(nonatomic, readonly, copy) NSString * categoryColor;
@property(nonatomic, readonly, copy) NSString * date;
@property(nonatomic, readonly) BOOL completed;
@property(nonatomic, readonly, copy) NSString * createdAt;
@property(nonatomic, readonly) NSInteger estimatedMinutes;
@property(nonatomic, readonly, copy) NSString * notes;
@property(nonatomic, readonly, copy) NSString * completionNote;
@property(nonatomic, readonly) NSInteger displayOrder;
@property(nonatomic, readonly) NSInteger actualPomodoros;
@property(nonatomic, readonly) NSInteger focusedSeconds;
@end
@interface PTTaskResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTTaskValue *> *tasks;
@end
// 只交设过的键；空串表示清空文本，categoryId = -1 表示清空科目。
@interface PTTaskChanges : NSObject
@property(nonatomic, readonly) BOOL hasTitle;
@property(nonatomic, copy) NSString * title;
@property(nonatomic, readonly) BOOL hasCategoryId;
@property(nonatomic) NSInteger categoryId;
@property(nonatomic, readonly) BOOL hasDate;
@property(nonatomic, copy) NSString * date;
@property(nonatomic, readonly) BOOL hasEstimatedMinutes;
@property(nonatomic) NSInteger estimatedMinutes;
@property(nonatomic, readonly) BOOL hasNotes;
@property(nonatomic, copy) NSString * notes;
@property(nonatomic, readonly) BOOL hasCompletionNote;
@property(nonatomic, copy) NSString * completionNote;
@end
@interface PTTaskBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onDeleted)(NSInteger taskId);
@property(nonatomic, copy, nullable) void (^onRestored)(NSInteger taskId, NSArray<NSNumber *> *sessionIds);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTTaskResult *)tasksForDate:(NSString *)date;
- (PTTaskResult *)todayTasks;
- (PTTaskResult *)weekTasks:(NSString *)startDate;
- (PTTaskResult *)overdueTasks;
- (PTTaskResult *)task:(NSInteger)taskId;
- (PTTaskResult *)search:(NSString *)text status:(NSInteger)status limit:(NSInteger)limit;
- (NSInteger)createTask:(NSString *)title date:(NSString *)date categoryId:(NSInteger)categoryId estimatedMinutes:(NSInteger)estimatedMinutes notes:(NSString *)notes error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)updateTask:(NSInteger)taskId changes:(PTTaskChanges *)changes error:(NSError **)error;
- (BOOL)setCompleted:(NSInteger)taskId completed:(BOOL)completed error:(NSError **)error;
- (BOOL)completeTask:(NSInteger)taskId note:(NSString *)note error:(NSError **)error;
- (BOOL)moveTask:(NSInteger)taskId before:(NSInteger)beforeTaskId error:(NSError **)error;
- (BOOL)moveTask:(NSInteger)taskId toDate:(NSString *)date error:(NSError **)error;
- (BOOL)moveTasks:(NSArray<NSNumber *> *)taskIds toDate:(NSString *)date error:(NSError **)error;
- (BOOL)moveTasksToToday:(NSArray<NSNumber *> *)taskIds error:(NSError **)error;
- (BOOL)setTasksCompleted:(NSArray<NSNumber *> *)taskIds completed:(BOOL)completed error:(NSError **)error;
- (BOOL)deleteTasks:(NSArray<NSNumber *> *)taskIds error:(NSError **)error;
- (BOOL)duplicateTask:(NSInteger)taskId date:(NSString *)date error:(NSError **)error;
- (BOOL)isRoutineGeneratedTask:(NSInteger)taskId;
// 结转窗口天数（TaskManager 的常量，只读转发）；结转提示用它说明「回看了几天」。
@property(nonatomic, readonly) NSInteger overdueRolloverDays;
// 从 start 起连续 days 天、每天「已排」分钟，口径见 TaskManager::readPlannedMinutesByDay；
// excludedTaskId 是撤销窗口里待删的任务，没有时传 -1。
- (nullable NSArray<NSNumber *> *)plannedMinutesFrom:(NSString *)start days:(NSInteger)days excludingTask:(NSInteger)excludedTaskId error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
