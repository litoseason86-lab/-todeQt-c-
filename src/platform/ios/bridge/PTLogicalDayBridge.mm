#import "PTLogicalDayBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/LogicalDay.h"
#include "../../../services/LogicalDayService.h"
#include "../../../services/AppSettings.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTPeriodDates ()
- (instancetype)initWithStart:(QDate)start end:(QDate)end todayStart:(QDate)todayStart range:(NSString *)range;
@end
@implementation PTPeriodDates
- (instancetype)initWithStart:(QDate)start end:(QDate)end todayStart:(QDate)todayStart range:(NSString *)range {
    if ((self = [super init])) {
        _start = date(start); _end = date(end); _year = start.year(); _month = start.month();
        _comparisonDistance = [range isEqualToString:@"month"]
            ? (todayStart.year() - start.year()) * 12 + todayStart.month() - start.month() + 1
            : start.daysTo(todayStart) / ([range isEqualToString:@"week"] ? 7 : 1) + 1;
        _current = start == todayStart; _canAdvance = start < todayStart;
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
- (PTPeriodDates *)periodForAnchor:(NSString *)anchor range:(NSString *)range shift:(NSInteger)shift logicalToday:(NSString *)logicalToday error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"日期读取必须在主线程");
    QDate start = date(anchor), todayStart = date(logicalToday);
    int step;
    if (!start.isValid() || !todayStart.isValid() || !integer(shift, &step)) { fail(error, QStringLiteral("日期或翻页参数无效")); return nil; }
    QDate end;
    if ([range isEqualToString:@"day"]) {
        start = start.addDays(step); end = start;
    } else if ([range isEqualToString:@"week"]) {
        // QDate 周一为 1；先归到周一再偏移，跨月跨年与闰日都沿同一日历。
        start = start.addDays(1 - start.dayOfWeek()).addDays(qint64(step) * 7);
        todayStart = todayStart.addDays(1 - todayStart.dayOfWeek()); end = start.addDays(6);
    } else if ([range isEqualToString:@"month"]) {
        start = QDate(start.year(), start.month(), 1).addMonths(step);
        todayStart = QDate(todayStart.year(), todayStart.month(), 1); end = start.addMonths(1).addDays(-1);
    } else { fail(error, QStringLiteral("统计范围无效")); return nil; }
    if (!start.isValid() || !end.isValid() || start.year() < 2000 || end.year() > 2100) { fail(error, QStringLiteral("日期范围无效")); return nil; }
    return [[PTPeriodDates alloc] initWithStart:start end:end todayStart:todayStart range:range];
}
- (NSString *)today { NSAssert(NSThread.isMainThread, @"逻辑日读取必须在主线程"); return date(LogicalDay::today(AppSettings::instance()->dayStartHour())); }
- (NSInteger)dayStartHour { NSAssert(NSThread.isMainThread, @"日界读取必须在主线程"); return AppSettings::instance()->dayStartHour(); }
@end
