#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTRoutineBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (NSArray<NSDictionary *> *)routines;
- (BOOL)addTitle:(NSString *)title categoryId:(NSInteger)categoryId weekdays:(NSInteger)weekdays error:(NSError **)error;
- (BOOL)update:(NSInteger)routineId changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)deleteRoutine:(NSInteger)routineId error:(NSError **)error;
- (BOOL)setActive:(NSInteger)routineId active:(BOOL)active error:(NSError **)error;
- (BOOL)setWeekdays:(NSInteger)routineId weekdays:(NSInteger)weekdays error:(NSError **)error;
- (NSInteger)materializeToday;
@end
NS_ASSUME_NONNULL_END
