#import "PTLifecycleBridge.h"

static BOOL (^sFlushHandler)(void);
@implementation PTLifecycleBridge
+ (BOOL (^)(void))flushHandler { return sFlushHandler; }
+ (void)setFlushHandler:(BOOL (^)(void))handler
{
    NSAssert(NSThread.isMainThread, @"原生保存回调只能在主线程登记");
    sFlushHandler = [handler copy];
}
+ (BOOL)flush
{
    NSAssert(NSThread.isMainThread, @"原生草稿必须在主线程同步保存");
    return !sFlushHandler || sFlushHandler();
}
@end
