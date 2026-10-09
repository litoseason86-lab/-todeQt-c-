#import "PTInteractionBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/TaskInteractionCoordinator.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTTaskValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTInteractionToken ()
- (instancetype)initWithOwner:(std::unique_ptr<QObject>)owner task:(PTTaskValue *)task;
@end
@implementation PTInteractionToken {
    std::unique_ptr<QObject> _owner;
}
- (instancetype)initWithOwner:(std::unique_ptr<QObject>)owner task:(PTTaskValue *)task {
    if ((self = [super init])) { _owner = std::move(owner); _task = task; }
    return self;
}
- (void)end { NSAssert(NSThread.isMainThread, @"交互只能在主线程结束"); _owner.reset(); }
@end
@implementation PTInteractionBridge {
    std::unique_ptr<QObject> _connections;
    QPointer<TaskInteractionCoordinator> _service;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"交互桥接只能在主线程创建");
    if ((self = [super init])) {
        _service = service<TaskInteractionCoordinator>(QStringLiteral("taskInteractions"));
        _connections = std::make_unique<QObject>();
        // 信号接收上下文随桥接析构断连；令牌的 owner 独立存活到交互结束。
        __weak PTInteractionBridge *weakSelf = self;
        if (_service) QObject::connect(_service, &TaskInteractionCoordinator::changed, _connections.get(), [weakSelf] { PTInteractionBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
    }
    return self;
}
- (BOOL)refreshBlocked { NSAssert(NSThread.isMainThread, @"交互状态必须在主线程读取"); return _service && _service->refreshBlocked(); }
- (NSString *)lastError { NSAssert(NSThread.isMainThread, @"交互状态必须在主线程读取"); return _service ? string(_service->lastError()) : @"交互服务未登记"; }
- (PTInteractionToken *)beginEdit:(NSInteger)taskId source:(NSString *)source error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"编辑只能在主线程开始");
    int id; if (!integer(taskId, &id) || !_service) { fail(error, QStringLiteral("任务编号越界或交互服务未登记")); return nil; }
    auto owner = std::make_unique<QObject>();
    const auto map = _service->beginEdit(owner.get(), id, string(source));
    if (map.isEmpty()) { fail(error, _service->lastError()); return nil; }
    return [[PTInteractionToken alloc] initWithOwner:std::move(owner) task:[[PTTaskValue alloc] initWithMap:map]];
}
- (PTInteractionToken *)beginDrag:(NSInteger)taskId source:(NSString *)source error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"拖动只能在主线程开始");
    int id; if (!integer(taskId, &id) || !_service) { fail(error, QStringLiteral("任务编号越界或交互服务未登记")); return nil; }
    auto owner = std::make_unique<QObject>();
    if (!_service->beginDrag(owner.get(), id, string(source))) { fail(error, _service->lastError()); return nil; }
    return [[PTInteractionToken alloc] initWithOwner:std::move(owner) task:nil];
}
@end
