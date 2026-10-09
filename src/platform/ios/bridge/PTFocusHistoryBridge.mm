#import "PTFocusHistoryBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/FocusHistoryService.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTSessionValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTSessionTaskOption ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTFocusHistoryResult ()
- (instancetype)initWithSessions:(const QVariantList &)sessions options:(const QVariantList &)options count:(int)count error:(const QString &)error;
@end
@implementation PTSessionValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _sessionId = map.value("id").toInt(); _taskId = map.value("taskId").isNull() ? -1 : map.value("taskId").toInt();
        _taskTitle = string(map.value("taskTitle").toString());
        // 旧记录可能不含毫秒或时区，按 Qt 的本地时刻解析后统一输出，保留真实时刻精度。
        _startTime = timestamp(QDateTime::fromString(map.value("startTime").toString(), Qt::ISODate));
        _endTime = timestamp(QDateTime::fromString(map.value("endTime").toString(), Qt::ISODate));
        _durationSeconds = map.value("durationSeconds").toInt(); _date = string(map.value("date").toString());
        _isRest = map.value("isRest").toBool();
    } return self;
}
@end
@implementation PTSessionTaskOption
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) { _taskId = map.value("id").toInt(); _title = string(map.value("title").toString()); } return self;
}
@end
@implementation PTFocusHistoryResult
- (instancetype)initWithSessions:(const QVariantList &)sessions options:(const QVariantList &)options count:(int)count error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error); _count = _valid ? count : 0;
        NSMutableArray *sessionValues = [NSMutableArray array], *optionValues = [NSMutableArray array];
        if (_valid) {
            for (const auto &row : sessions) [sessionValues addObject:[[PTSessionValue alloc] initWithMap:row.toMap()]];
            for (const auto &row : options) [optionValues addObject:[[PTSessionTaskOption alloc] initWithMap:row.toMap()]];
        }
        _sessions = [sessionValues copy]; _taskOptions = [optionValues copy];
    } return self;
}
@end
@implementation PTSessionChanges
- (void)setStartTime:(NSString *)value { _startTime = [value copy]; _hasStartTime = YES; }
- (void)setDurationSeconds:(NSInteger)value { _durationSeconds = value; _hasDurationSeconds = YES; }
- (void)setTaskId:(NSInteger)value { _taskId = value; _hasTaskId = YES; }
- (void)setIsRest:(BOOL)value { _isRest = value; _hasIsRest = YES; }
@end
static bool sessionChanges(PTSessionChanges *changes, QVariantMap *map, NSError **error) {
    // 仅交用户改过的键；单改归属时不能把界面的整分钟舍入写回原始秒数。
    int number;
    if (changes.hasStartTime) map->insert(QStringLiteral("startTime"), timestamp(changes.startTime));
    if (changes.hasDurationSeconds) {
        if (!integer(changes.durationSeconds, &number)) return fail(error, QStringLiteral("时长越界"));
        map->insert(QStringLiteral("durationSeconds"), number);
    }
    if (changes.hasTaskId) {
        if (!integer(changes.taskId, &number)) return fail(error, QStringLiteral("任务编号越界"));
        map->insert(QStringLiteral("taskId"), number);
    }
    if (changes.hasIsRest) map->insert(QStringLiteral("isRest"), bool(changes.isRest));
    return true;
}
@implementation PTFocusHistoryBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"历史桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文随桥接释放断连，弱引用不保留桥接；历史变化从工作线程排回主线程。
        _connections = std::make_unique<QObject>(); __weak PTFocusHistoryBridge *weakSelf = self;
        QObject::connect(FocusHistoryService::instance(), &FocusHistoryService::historyChanged, _connections.get(), [weakSelf] {
            PTFocusHistoryBridge *b = weakSelf; if (b.onChanged) b.onChanged();
        });
    } return self;
}
- (NSString *)lastError { NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); return string(FocusHistoryService::instance()->lastError()); }
- (PTFocusHistoryResult *)monthSessions:(NSInteger)year month:(NSInteger)month {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程");
    int y, m; if (!integer(year, &y) || !integer(month, &m)) return [[PTFocusHistoryResult alloc] initWithSessions:{} options:{} count:0 error:QStringLiteral("年月参数越界")];
    auto *service = FocusHistoryService::instance(); const auto rows = service->getMonthSessions(y, m);
    return [[PTFocusHistoryResult alloc] initWithSessions:rows options:{} count:0 error:service->lastError()];
}
- (PTFocusHistoryResult *)daySessions:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); auto *service = FocusHistoryService::instance(); const auto rows = service->getDaySessions(date(iso));
    return [[PTFocusHistoryResult alloc] initWithSessions:rows options:{} count:0 error:service->lastError()];
}
- (PTFocusHistoryResult *)dayTimeline:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); auto *service = FocusHistoryService::instance(); const auto rows = service->getDayTimeline(date(iso));
    return [[PTFocusHistoryResult alloc] initWithSessions:rows options:{} count:0 error:service->lastError()];
}
- (PTFocusHistoryResult *)dayTotalDuration:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); auto *service = FocusHistoryService::instance(); const int value = service->getDayTotalDuration(date(iso));
    return [[PTFocusHistoryResult alloc] initWithSessions:{} options:{} count:value error:service->lastError()];
}
- (PTFocusHistoryResult *)invalidSessionCount {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); auto *service = FocusHistoryService::instance(); const int value = service->invalidSessionCount();
    return [[PTFocusHistoryResult alloc] initWithSessions:{} options:{} count:value error:service->lastError()];
}
- (PTFocusHistoryResult *)taskOptions:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); auto *service = FocusHistoryService::instance(); const auto rows = service->getTaskOptions(date(iso));
    return [[PTFocusHistoryResult alloc] initWithSessions:{} options:rows count:0 error:service->lastError()];
}
- (NSString *)formatDuration:(NSInteger)seconds {
    NSAssert(NSThread.isMainThread, @"历史读取必须在主线程"); int value;
    return integer(seconds, &value) ? string(FocusHistoryService::instance()->formatDuration(value)) : @"";
}
- (NSInteger)cleanupInvalidSessions:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"历史清理必须在主线程"); auto *service = FocusHistoryService::instance(); const int value = service->cleanupInvalidSessions();
    if (!service->lastError().isEmpty()) { fail(error, service->lastError()); return -1; } return value;
}
- (NSInteger)addManualSession:(NSInteger)taskId startTime:(NSString *)startTime durationMinutes:(NSInteger)minutes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"历史写入必须在主线程"); int id, duration;
    if (!integer(taskId, &id) || !integer(minutes, &duration)) { fail(error, QStringLiteral("补录参数越界")); return -1; }
    auto *service = FocusHistoryService::instance(); const int created = service->addManualSession(id, timestamp(startTime), duration);
    if (created < 0) { fail(error, service->lastError().isEmpty() ? QStringLiteral("补录失败") : service->lastError()); return -1; } return created;
}
- (BOOL)updateSession:(NSInteger)sessionId changes:(PTSessionChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"历史写入必须在主线程"); int id;
    if (!integer(sessionId, &id)) return fail(error, QStringLiteral("记录编号越界"));
    QVariantMap map; if (!sessionChanges(changes, &map, error)) return NO;
    auto *service = FocusHistoryService::instance(); return service->updateSessionFields(id, map) ? YES : fail(error, service->lastError().isEmpty() ? QStringLiteral("修改专注记录失败") : service->lastError());
}
- (BOOL)updateRestSession:(NSInteger)sessionId changes:(PTSessionChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"历史写入必须在主线程"); int id;
    if (!integer(sessionId, &id)) return fail(error, QStringLiteral("记录编号越界"));
    QVariantMap map; if (!sessionChanges(changes, &map, error)) return NO;
    auto *service = FocusHistoryService::instance(); return service->updateRestSessionFields(id, map) ? YES : fail(error, service->lastError().isEmpty() ? QStringLiteral("修改休息记录失败") : service->lastError());
}
@end
