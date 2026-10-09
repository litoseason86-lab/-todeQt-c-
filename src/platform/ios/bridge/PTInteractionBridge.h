#import <Foundation/Foundation.h>
#import "PTTaskBridge.h"
NS_ASSUME_NONNULL_BEGIN
// 令牌持有登记 owner，释放或 end 都会结束交互；最新任务只在编辑令牌中存在。
@interface PTInteractionToken : NSObject
@property(nonatomic, readonly, nullable) PTTaskValue *task;
- (void)end;
@end
@interface PTInteractionBridge : NSObject
@property(nonatomic, readonly) BOOL refreshBlocked;
@property(nonatomic, readonly, copy) NSString *lastError;
@property(nonatomic, copy, nullable) void (^onChanged)(void);
- (nullable PTInteractionToken *)beginEdit:(NSInteger)taskId source:(NSString *)source error:(NSError **)error;
- (nullable PTInteractionToken *)beginDrag:(NSInteger)taskId source:(NSString *)source error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
