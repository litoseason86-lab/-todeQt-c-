#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// 日期关系由 QDate 比较给出，周期范围由服务 StatisticsPeriod 计算；调用方传同一份逻辑今日，不在这些查询中另读时钟。
@interface PTPeriodDates : NSObject
@property(nonatomic, readonly, copy) NSString *start;
@property(nonatomic, readonly, copy) NSString *end;
@property(nonatomic, readonly) NSInteger year;
@property(nonatomic, readonly) NSInteger month;
@property(nonatomic, readonly) NSInteger comparisonDistance;
@property(nonatomic, readonly) BOOL current;
@property(nonatomic, readonly) BOOL canAdvance;
@end
@interface PTLogicalDayBridge : NSObject
@property(nonatomic, readonly, copy) NSString *today;
@property(nonatomic, readonly) NSInteger dayStartHour;
@property(nonatomic, copy, nullable) void (^onChanged)(void);
- (NSInteger)relationOfDate:(NSString *)value toDate:(NSString *)reference error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (nullable PTPeriodDates *)periodForAnchor:(NSString *)anchor range:(NSString *)range shift:(NSInteger)shift logicalToday:(NSString *)logicalToday error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
