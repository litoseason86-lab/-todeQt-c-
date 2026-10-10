#import "PTTrashBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/TrashService.h"
#include <memory>
using namespace PTBridgeSupport;

static NSError *trashError(NSString *message) { return [NSError errorWithDomain:@"PTTrashBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"废纸篓操作失败"}]; }

@interface PTTrashReadResult () - (instancetype)initWithMap:(const QVariantMap &)map; @end
@implementation PTTrashReadResult
- (instancetype)initWithMap:(const QVariantMap &)map { if ((self = [super init])) { _valid = map.value("ok").toBool(); _error = string(map.value("error").toString()); _today = string(map.value("today").toString()); _items = array(map.value("items").toList()); } return self; }
@end

@implementation PTTrashBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"废纸篓桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTTrashBridge *weakSelf = self; QObject::connect(TrashService::instance(), &TrashService::trashChanged, _connections.get(), [weakSelf] { PTTrashBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); } return self; }
- (PTTrashReadResult *)readItems { NSAssert(NSThread.isMainThread, @"废纸篓读取必须在主线程"); return [[PTTrashReadResult alloc] initWithMap:TrashService::instance()->readItems()]; }
- (NSInteger)purgeExpired:(NSError **)error { const int count = TrashService::instance()->purgeExpired(); if (count < 0) { if (error) *error = trashError(@"清理过期废纸篓项目失败"); return -1; } return count; }
- (NSDictionary *)restoreItem:(NSInteger)trashId error:(NSError **)error { int id; if (!integer(trashId, &id)) { if (error) *error = trashError(@"废纸篓编号越界"); return @{}; } QVariantMap result = TrashService::instance()->restoreItem(id); if (!result.value("ok").toBool()) { if (error) *error = trashError(string(result.value("error").toString())); } return dictionary(result); }
- (NSDictionary *)deleteItem:(NSInteger)trashId error:(NSError **)error { int id; if (!integer(trashId, &id)) { if (error) *error = trashError(@"废纸篓编号越界"); return @{}; } QVariantMap result = TrashService::instance()->deleteItem(id); if (!result.value("ok").toBool()) { if (error) *error = trashError(string(result.value("error").toString())); } return dictionary(result); }
- (NSDictionary *)emptyTrash:(NSArray<NSNumber *> *)trashIds error:(NSError **)error { QVariantList ids; for (NSNumber *value in trashIds) ids.append(QVariant(value.intValue)); QVariantMap result = TrashService::instance()->emptyTrash(ids); if (!result.value("ok").toBool()) { if (error) *error = trashError(string(result.value("error").toString())); } return dictionary(result); }
@end
