#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// 保存回调由原生外壳登记，退出与后台同步之前由 main.cpp 在主线程同步调用。
@interface PTLifecycleBridge : NSObject
@property(class, nonatomic, copy, nullable) void (^flushHandler)(void);
+ (void)flush;
@end
NS_ASSUME_NONNULL_END
