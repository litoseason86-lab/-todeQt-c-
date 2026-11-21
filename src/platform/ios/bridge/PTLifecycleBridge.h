#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// 原生外壳登记保存回调，退出、进入后台或应用远端快照之前在主线程同步调用。
@interface PTLifecycleBridge : NSObject
@property(class, nonatomic, copy, nullable) BOOL (^flushHandler)(void);
+ (BOOL)flush;
@end
NS_ASSUME_NONNULL_END
