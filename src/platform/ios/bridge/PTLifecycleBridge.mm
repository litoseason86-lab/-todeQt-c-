#import "PTLifecycleBridge.h"

static void (^sFlushHandler)(void);
@implementation PTLifecycleBridge
+ (void (^)(void))flushHandler { return sFlushHandler; }
+ (void)setFlushHandler:(void (^)(void))handler
{
    NSAssert(NSThread.isMainThread, @"原生保存回调只能在主线程登记");
    sFlushHandler = [handler copy];
}
+ (void)flush
{
    NSAssert(NSThread.isMainThread, @"原生草稿必须在主线程同步保存");
    if (sFlushHandler) sFlushHandler();
}
@end
