#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 值对象保留服务字段类型；键映射在 Objective-C++，Swift 只复制属性。
@interface PTTrashDetailsValue : NSObject
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) BOOL completed;
@property(nonatomic, readonly) NSInteger estimatedMinutes;
@property(nonatomic, readonly, copy) NSString *startTime;
@property(nonatomic, readonly, copy) NSString *endTime;
@property(nonatomic, readonly) NSInteger durationSeconds;
@property(nonatomic, readonly) NSInteger mode;
@property(nonatomic, readonly, copy) NSString *taskTitle;
@property(nonatomic, readonly) BOOL manual;
@property(nonatomic, readonly, copy) NSString *dueDate;
@property(nonatomic, readonly) NSInteger status;
@property(nonatomic, readonly) NSInteger weekdays;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSInteger weekday;
@property(nonatomic, readonly, strong, nullable) NSNumber *startMinutes;
@property(nonatomic, readonly, strong, nullable) NSNumber *endMinutes;
@property(nonatomic, readonly) NSInteger weekStart;
@property(nonatomic, readonly) NSInteger weekEnd;
@property(nonatomic, readonly) NSInteger weekParity;
@property(nonatomic, readonly, copy) NSString *location;
@property(nonatomic, readonly, copy) NSString *targetDate;
@end

@interface PTTrashItemValue : NSObject
@property(nonatomic, readonly) NSInteger itemId;
@property(nonatomic, readonly, copy) NSString *kind;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *deletedAt;
@property(nonatomic, readonly, copy) NSString *deletedDate;
@property(nonatomic, readonly) NSInteger remainingDays;
@property(nonatomic, readonly, copy) NSString *originSyncId;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *categoryColor;
@property(nonatomic, readonly) BOOL restorable;
@property(nonatomic, readonly, copy) NSString *blockedReason;
@property(nonatomic, readonly, strong) PTTrashDetailsValue *details;
@end

@interface PTTrashActionValue : NSObject
@property(nonatomic, readonly) BOOL ok;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSString *code;
@property(nonatomic, readonly, copy) NSString *conflict;
@end

@interface PTTrashReadResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSString *today;
@property(nonatomic, readonly, copy) NSArray<PTTrashItemValue *> *items;
@end

@interface PTTrashBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
- (PTTrashReadResult *)readItems;
- (NSInteger)purgeExpired:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTTrashActionValue *)restoreItem:(NSInteger)trashId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTTrashActionValue *)deleteItem:(NSInteger)trashId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTTrashActionValue *)emptyTrash:(NSArray<NSNumber *> *)trashIds error:(NSError **)error __attribute__((swift_error(nonnull_error)));
@end
NS_ASSUME_NONNULL_END
