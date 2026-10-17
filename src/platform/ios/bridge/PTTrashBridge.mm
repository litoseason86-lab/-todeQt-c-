#import "PTTrashBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/TrashService.h"
#include <memory>
#include <QScopedValueRollback>
#include <cmath>
#include <limits>
using namespace PTBridgeSupport;

@interface PTTrashDetailsValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@implementation PTTrashDetailsValue
- (instancetype)initWithMap:(const QVariantMap &)map
{
    if ((self = [super init])) {
        _date = string(map.value(QStringLiteral("date")).toString());
        _completed = map.value(QStringLiteral("completed")).toBool();
        _estimatedMinutes = map.value(QStringLiteral("estimatedMinutes")).toInt();
        _startTime = string(map.value(QStringLiteral("startTime")).toString());
        _endTime = string(map.value(QStringLiteral("endTime")).toString());
        _durationSeconds = map.value(QStringLiteral("durationSeconds")).toInt();
        _mode = map.value(QStringLiteral("mode")).toInt();
        _taskTitle = string(map.value(QStringLiteral("taskTitle")).toString());
        _manual = map.value(QStringLiteral("manual")).toBool();
        _dueDate = string(map.value(QStringLiteral("dueDate")).toString());
        _status = map.value(QStringLiteral("status")).toInt();
        _weekdays = map.value(QStringLiteral("weekdays")).toInt();
        _active = map.value(QStringLiteral("active")).toBool();
        _weekday = map.value(QStringLiteral("weekday")).toInt();
        // 午夜的零分钟是有效课表时间；缺失或空字段必须保留为 nil，不能用零兜底。
        const QVariant startMinutes = map.value(QStringLiteral("startMinutes"));
        const QVariant endMinutes = map.value(QStringLiteral("endMinutes"));
        _startMinutes = startMinutes.isValid() && !startMinutes.isNull() ? @(startMinutes.toInt()) : nil;
        _endMinutes = endMinutes.isValid() && !endMinutes.isNull() ? @(endMinutes.toInt()) : nil;
        _weekStart = map.value(QStringLiteral("weekStart")).toInt();
        _weekEnd = map.value(QStringLiteral("weekEnd")).toInt();
        _weekParity = map.value(QStringLiteral("weekParity")).toInt();
        _location = string(map.value(QStringLiteral("location")).toString());
        _targetDate = string(map.value(QStringLiteral("targetDate")).toString());
    }
    return self;
}
@end

@interface PTTrashItemValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@implementation PTTrashItemValue
- (instancetype)initWithMap:(const QVariantMap &)map
{
    if ((self = [super init])) {
        _itemId = map.value(QStringLiteral("id")).toInt();
        _kind = string(map.value(QStringLiteral("kind")).toString());
        _title = string(map.value(QStringLiteral("title")).toString());
        _deletedAt = string(map.value(QStringLiteral("deletedAt")).toString());
        _deletedDate = string(map.value(QStringLiteral("deletedDate")).toString());
        _remainingDays = map.value(QStringLiteral("remainingDays")).toInt();
        _originSyncId = string(map.value(QStringLiteral("originSyncId")).toString());
        _categoryName = string(map.value(QStringLiteral("categoryName")).toString());
        _categoryColor = string(map.value(QStringLiteral("categoryColor")).toString());
        _restorable = map.value(QStringLiteral("restorable")).toBool();
        _blockedReason = string(map.value(QStringLiteral("blockedReason")).toString());
        _details = [[PTTrashDetailsValue alloc] initWithMap:map.value(QStringLiteral("details")).toMap()];
    }
    return self;
}
@end

@interface PTTrashActionValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@implementation PTTrashActionValue
- (instancetype)initWithMap:(const QVariantMap &)map
{
    if ((self = [super init])) {
        _ok = map.value(QStringLiteral("ok")).toBool();
        _title = string(map.value(QStringLiteral("title")).toString());
        _error = string(map.value(QStringLiteral("error")).toString());
        _code = string(map.value(QStringLiteral("code")).toString());
        _conflict = string(map.value(QStringLiteral("conflict")).toString());
    }
    return self;
}
@end

static NSError *trashError(NSString *message) { return [NSError errorWithDomain:@"PTTrashBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"废纸篓操作失败"}]; }

@interface PTTrashReadResult () - (instancetype)initWithMap:(const QVariantMap &)map; @end
@implementation PTTrashReadResult
- (instancetype)initWithMap:(const QVariantMap &)map
{
    if ((self = [super init])) {
        _valid = map.value(QStringLiteral("ok")).toBool();
        _error = string(map.value(QStringLiteral("error")).toString());
        _today = string(map.value(QStringLiteral("today")).toString());
        NSMutableArray<PTTrashItemValue *> *items = [NSMutableArray array];
        for (const auto &item : map.value(QStringLiteral("items")).toList())
            [items addObject:[[PTTrashItemValue alloc] initWithMap:item.toMap()]];
        _items = [items copy];
    }
    return self;
}
@end

@implementation PTTrashBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
    bool _purgingExpired;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"废纸篓桥接只能在主线程创建");
    if ((self = [super init])) {
        _purgingExpired = false;
        _connections = std::make_unique<QObject>();
        __weak PTTrashBridge* weakSelf = self;
        auto* service = TrashService::instance();
        QObject::connect(service, &TrashService::trashChanged, _connections.get(), [weakSelf] {
            PTTrashBridge* b = weakSelf; if (b.onChanged) b.onChanged();
        });
        // 启动和跨日清理沿用静默维护；只有桥接同步调用期间收集原因，不给外壳增加后台提示。
        QObject::connect(service, &TrashService::operationFailed, _connections.get(), [weakSelf](const QString& reason) {
            PTTrashBridge* b = weakSelf;
            if (b && b->_purgingExpired) b->_failures.collect(reason);
        });
    }
    return self;
}
- (PTTrashReadResult *)readItems { NSAssert(NSThread.isMainThread, @"废纸篓读取必须在主线程"); return [[PTTrashReadResult alloc] initWithMap:TrashService::instance()->readItems()]; }
- (NSInteger)purgeExpired:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    // 只认领本桥接显式发起的清理；其它桥接栈内的自动维护也必须保持静默。
    QScopedValueRollback<bool> purging(_purgingExpired, true);
    FailureCollector::Call call(_failures);
    const int count = TrashService::instance()->purgeExpired();
    if (count < 0) {
        const QString reason = call.error();
        fail(error, reason.isEmpty() ? QStringLiteral("清理过期废纸篓失败，请重试") : reason);
    }
    return count;
}
- (PTTrashActionValue *)restoreItem:(NSInteger)trashId error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    int id;
    if (!integer(trashId, &id)) {
        if (error) *error = trashError(@"废纸篓编号越界");
        return [[PTTrashActionValue alloc] initWithMap:QVariantMap{}];
    }
    // 服务失败保留结构化结果（含冲突和 gone），NSError 只用于无法转发的参数错误。
    return [[PTTrashActionValue alloc] initWithMap:TrashService::instance()->restoreItem(id)];
}
- (PTTrashActionValue *)deleteItem:(NSInteger)trashId error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    int id;
    if (!integer(trashId, &id)) {
        if (error) *error = trashError(@"废纸篓编号越界");
        return [[PTTrashActionValue alloc] initWithMap:QVariantMap{}];
    }
    return [[PTTrashActionValue alloc] initWithMap:TrashService::instance()->deleteItem(id)];
}
- (PTTrashActionValue *)emptyTrash:(NSArray<NSNumber *> *)trashIds error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    QVariantList ids;
    // 转换前验证整个列表，避免 NSNumber 截断成有效编号后误删；这里不做服务的存在性判断。
    for (NSNumber *value in trashIds) {
        const double number = [value isKindOfClass:NSNumber.class] ? value.doubleValue : NAN;
        if (!std::isfinite(number) || number < std::numeric_limits<int>::min()
            || number > std::numeric_limits<int>::max() || std::floor(number) != number) {
            if (error) *error = trashError(@"废纸篓编号越界");
            return [[PTTrashActionValue alloc] initWithMap:QVariantMap{}];
        }
        ids.append(static_cast<int>(number));
    }
    return [[PTTrashActionValue alloc] initWithMap:TrashService::instance()->emptyTrash(ids)];
}
@end
