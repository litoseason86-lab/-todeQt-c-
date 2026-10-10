#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTLogicalDayBridge : NSObject
@property(nonatomic, readonly, copy) NSString *today;
@property(nonatomic, readonly) NSInteger dayStartHour;
@property(nonatomic, copy, nullable) void (^onChanged)(void);
- (NSInteger)relationOfDate:(NSString *)value toDate:(NSString *)reference error:(NSError **)error __attribute__((swift_error(nonnull_error)));
@end
NS_ASSUME_NONNULL_END
