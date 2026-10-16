#import "PTPendingDeletionBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/PendingDeletion.h"
#include <memory>
using namespace PTBridgeSupport;
@implementation PTPendingDeletionBridge {
    std::unique_ptr<QObject> _connections;
    QPointer<PendingDeletion> _service;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"撤销桥接只能在主线程创建");
    if ((self = [super init])) {
        _service = service<PendingDeletion>(QStringLiteral("pendingDeletion"));
        _connections = std::make_unique<QObject>();
        // 登记服务不归桥接所有，QObject 上下文仅管理连接；弱引用阻断回调保留环。
        __weak PTPendingDeletionBridge *weakSelf = self;
        if (_service) {
            QObject::connect(_service, &PendingDeletion::changed, _connections.get(), [weakSelf] { PTPendingDeletionBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
            QObject::connect(_service, &PendingDeletion::retired, _connections.get(), [weakSelf] { PTPendingDeletionBridge *b = weakSelf; if (b.onRetired) b.onRetired(); });
            QObject::connect(_service, &PendingDeletion::commitFailed, _connections.get(), [weakSelf](const QString &title) { PTPendingDeletionBridge *b = weakSelf; if (b.onCommitFailed) b.onCommitFailed(string(title)); });
        }
    }
    return self;
}
- (BOOL)active { NSAssert(NSThread.isMainThread, @"撤销状态必须在主线程读取"); return _service && _service->active(); }
- (NSInteger)taskId { NSAssert(NSThread.isMainThread, @"撤销状态必须在主线程读取"); return _service ? _service->taskId() : -1; }
- (NSInteger)sessionId { NSAssert(NSThread.isMainThread, @"撤销状态必须在主线程读取"); return _service ? _service->sessionId() : -1; }
- (BOOL)sessionIsRest { NSAssert(NSThread.isMainThread, @"撤销状态必须在主线程读取"); return _service && _service->sessionIsRest(); }
- (NSString *)title { NSAssert(NSThread.isMainThread, @"撤销状态必须在主线程读取"); return _service ? string(_service->title()) : @""; }
- (BOOL)requestTask:(NSInteger)taskId title:(NSString *)title error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"删除请求必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    return (_service && _service->requestTask(id, string(title))) || fail(error, QStringLiteral("请求删除任务失败"));
}
- (BOOL)requestSession:(NSInteger)sessionId title:(NSString *)title isRest:(BOOL)isRest error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"删除请求必须在主线程");
    int id; if (!integer(sessionId, &id)) return fail(error, QStringLiteral("记录编号越界"));
    return (_service && _service->requestSession(id, string(title), isRest)) || fail(error, QStringLiteral("请求删除记录失败"));
}
- (BOOL)commit:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"删除提交必须在主线程");
    return (_service && _service->commit()) || fail(error, QStringLiteral("提交删除失败"));
}
- (void)cancel { NSAssert(NSThread.isMainThread, @"撤销必须在主线程"); if (_service) _service->cancel(); }
- (void)setAutomaticCommitSuspended:(BOOL)suspended {
    NSAssert(NSThread.isMainThread, @"暂停自动提交状态必须在主线程设置");
    if (_service) {
        _service->setAutomaticCommitSuspended(suspended);
    }
}
@end
