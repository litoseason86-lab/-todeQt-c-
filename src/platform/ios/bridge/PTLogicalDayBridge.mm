#import "PTLogicalDayBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/LogicalDay.h"
#include "../../../services/LogicalDayService.h"
#include "../../../services/AppSettings.h"
#include <memory>
using namespace PTBridgeSupport;
@implementation PTLogicalDayBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"逻辑日桥接只能在主线程创建");
    if ((self = [super init])) {
        // 只转发统一服务的失效通知；Swift 不另设日界定时器，也不自己换算日期。
        _connections = std::make_unique<QObject>(); __weak PTLogicalDayBridge *weakSelf = self;
        QObject::connect(LogicalDayService::instance(), &LogicalDayService::changed, _connections.get(), [weakSelf] {
            PTLogicalDayBridge *b = weakSelf; if (b.onChanged) b.onChanged();
        });
    }
    return self;
}
- (NSString *)today { NSAssert(NSThread.isMainThread, @"逻辑日读取必须在主线程"); return date(LogicalDay::today(AppSettings::instance()->dayStartHour())); }
- (NSInteger)dayStartHour { NSAssert(NSThread.isMainThread, @"日界读取必须在主线程"); return AppSettings::instance()->dayStartHour(); }
@end
