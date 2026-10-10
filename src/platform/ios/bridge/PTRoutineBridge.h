#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 值对象保留服务字段类型；键映射在 Objective-C++，Swift 只复制属性。
@interface PTRoutineValue : NSObject
@property(nonatomic, readonly) NSInteger routineId;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *categoryColor;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSInteger weekdays;
@end

@interface PTRoutineBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (NSArray<PTRoutineValue *> *)routines;
- (nullable NSArray<PTRoutineValue *> *)readRoutines:(NSError **)error;
- (BOOL)addTitle:(NSString *)title categoryId:(NSInteger)categoryId weekdays:(NSInteger)weekdays error:(NSError **)error;
- (BOOL)update:(NSInteger)routineId changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)deleteRoutine:(NSInteger)routineId error:(NSError **)error;
- (BOOL)setActive:(NSInteger)routineId active:(BOOL)active error:(NSError **)error;
- (BOOL)setWeekdays:(NSInteger)routineId weekdays:(NSInteger)weekdays error:(NSError **)error;
- (NSInteger)materializeToday;
@end
NS_ASSUME_NONNULL_END
