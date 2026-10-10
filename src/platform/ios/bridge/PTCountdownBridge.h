#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTCountdownValue : NSObject
@property(nonatomic, readonly) NSInteger goalId;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *targetDate;
@property(nonatomic, readonly) NSInteger displayOrder;
@property(nonatomic, readonly) NSInteger daysRemaining;
@property(nonatomic, readonly, copy) NSString *createdAt;
@property(nonatomic, readonly, copy) NSString *updatedAt;
@end
@interface PTCountdownResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTCountdownValue *> *items;
@end
// 设过才入改动表；清空字符串和清空分类仍然是明确的改动。
@interface PTCountdownChanges : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, readonly) BOOL hasName;
@property(nonatomic, copy) NSString *targetDate;
@property(nonatomic, readonly) BOOL hasTargetDate;
@end
@interface PTCountdownBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
@property(nonatomic, copy, nullable) void (^onPrimaryGoalChanged)(void);
- (PTCountdownResult *)goals;
- (PTCountdownResult *)primaryGoal;
- (BOOL)addName:(NSString *)name date:(NSString *)date error:(NSError **)error;
- (BOOL)updateGoal:(NSInteger)goalId changes:(PTCountdownChanges *)changes error:(NSError **)error;
- (BOOL)deleteGoal:(NSInteger)goalId error:(NSError **)error;
- (BOOL)reorderFrom:(NSInteger)from to:(NSInteger)to error:(NSError **)error;
- (NSInteger)daysRemaining:(NSString *)date;
@end
NS_ASSUME_NONNULL_END
