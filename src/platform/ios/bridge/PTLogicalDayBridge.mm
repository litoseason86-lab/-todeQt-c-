#import "PTLogicalDayBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/LogicalDay.h"
#include "../../../services/LogicalDayService.h"
#include "../../../services/AppSettings.h"
#include "../../../services/StatisticsPeriod.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTPeriodDates ()
- (instancetype)initWithPeriod:(const StatisticsPeriod::Period &)period;
@end
@implementation PTPeriodDates
- (instancetype)initWithPeriod:(const StatisticsPeriod::Period &)period {
    if ((self = [super init])) {
        _start = date(period.start); _end = date(period.end); _year = period.start.year(); _month = period.start.month();
        _comparisonDistance = period.comparisonDistance; _current = period.current; _canAdvance = period.canAdvance;
    }
    return self;
}
@end
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
// 日期比较不接触墙钟；逻辑日已由 today 生成，不能在这里再次减日界。
- (NSInteger)relationOfDate:(NSString *)value toDate:(NSString *)reference error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"日期读取必须在主线程");
    const QDate left = date(value), right = date(reference);
    if (!left.isValid() || !right.isValid()) { fail(error, QStringLiteral("日期无效")); return 0; }
    return left < right ? -1 : left > right ? 1 : 0;
}
// 周期范围与三个标志由 StatisticsPeriod 计算，这里只转换类型；调用方传同一份逻辑今日，不另读时钟。
- (PTPeriodDates *)periodForAnchor:(NSString *)anchor range:(NSString *)range shift:(NSInteger)shift logicalToday:(NSString *)logicalToday error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"日期读取必须在主线程");
    const QDate anchorDate = date(anchor), today = date(logicalToday);
    int step;
    if (!anchorDate.isValid() || !today.isValid() || !integer(shift, &step)) { fail(error, QStringLiteral("日期或翻页参数无效")); return nil; }
    StatisticsPeriod::Range kind = StatisticsPeriod::Range::Day;
    if (!StatisticsPeriod::parseRange(string(range), &kind)) { fail(error, QStringLiteral("统计范围无效")); return nil; }
    const StatisticsPeriod::Period period = StatisticsPeriod::forAnchor(anchorDate, kind, step, today);
    if (!period.isValid()) { fail(error, QStringLiteral("日期范围无效")); return nil; }
    return [[PTPeriodDates alloc] initWithPeriod:period];
}
- (NSString *)today { NSAssert(NSThread.isMainThread, @"逻辑日读取必须在主线程"); return date(LogicalDay::today(AppSettings::instance()->dayStartHour())); }
- (NSInteger)dayStartHour { NSAssert(NSThread.isMainThread, @"日界读取必须在主线程"); return AppSettings::instance()->dayStartHour(); }
@end
