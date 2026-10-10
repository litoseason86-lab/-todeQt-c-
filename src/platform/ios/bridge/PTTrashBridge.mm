#import "PTTrashBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/TrashService.h"
#include <memory>
#include <cmath>
#include <limits>
using namespace PTBridgeSupport;

static NSError *trashError(NSString *message) { return [NSError errorWithDomain:@"PTTrashBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"废纸篓操作失败"}]; }

@interface PTTrashReadResult () - (instancetype)initWithMap:(const QVariantMap &)map; @end
@implementation PTTrashReadResult
- (instancetype)initWithMap:(const QVariantMap &)map { if ((self = [super init])) { _valid = map.value("ok").toBool(); _error = string(map.value("error").toString()); _today = string(map.value("today").toString()); _items = array(map.value("items").toList()); } return self; }
@end

@implementation PTTrashBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"废纸篓桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTTrashBridge *weakSelf = self; QObject::connect(TrashService::instance(), &TrashService::trashChanged, _connections.get(), [weakSelf] { PTTrashBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); } return self; }
- (PTTrashReadResult *)readItems { NSAssert(NSThread.isMainThread, @"废纸篓读取必须在主线程"); return [[PTTrashReadResult alloc] initWithMap:TrashService::instance()->readItems()]; }
- (NSInteger)purgeExpired:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); const int count = TrashService::instance()->purgeExpired(); if (count < 0) { if (error) *error = trashError(@"清理过期废纸篓项目失败"); return -1; } return count; }
- (NSDictionary *)restoreItem:(NSInteger)trashId error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    int id;
    if (!integer(trashId, &id)) {
        if (error) *error = trashError(@"废纸篓编号越界");
        return @{};
    }
    // 服务失败保留结构化结果（含冲突和 gone），NSError 只用于无法转发的参数错误。
    return dictionary(TrashService::instance()->restoreItem(id));
}
- (NSDictionary *)deleteItem:(NSInteger)trashId error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    int id;
    if (!integer(trashId, &id)) {
        if (error) *error = trashError(@"废纸篓编号越界");
        return @{};
    }
    return dictionary(TrashService::instance()->deleteItem(id));
}
- (NSDictionary *)emptyTrash:(NSArray<NSNumber *> *)trashIds error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    QVariantList ids;
    // 转换前验证整个列表，避免 NSNumber 截断成有效编号后误删；这里不做服务的存在性判断。
    for (NSNumber *value in trashIds) {
        const double number = [value isKindOfClass:NSNumber.class] ? value.doubleValue : NAN;
        if (!std::isfinite(number) || number < std::numeric_limits<int>::min()
            || number > std::numeric_limits<int>::max() || std::floor(number) != number) {
            if (error) *error = trashError(@"废纸篓编号越界");
            return @{};
        }
        ids.append(static_cast<int>(number));
    }
    return dictionary(TrashService::instance()->emptyTrash(ids));
}
@end
