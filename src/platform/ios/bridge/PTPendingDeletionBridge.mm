#import "PTPendingDeletionBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/PendingDeletion.h"
#include <memory>
#include <QScopedValueRollback>
using namespace PTBridgeSupport;
@implementation PTPendingDeletionBridge {
    std::unique_ptr<QObject> _connections;
    QPointer<PendingDeletion> _service;
    FailureCollector _failures;
    bool _callingDeletion;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"撤销桥接只能在主线程创建");
    if ((self = [super init])) {
        _callingDeletion = false;
        _service = service<PendingDeletion>(QStringLiteral("pendingDeletion"));
        _connections = std::make_unique<QObject>();
        // 登记服务不归桥接所有，QObject 上下文仅管理连接；弱引用阻断回调保留环。
        __weak PTPendingDeletionBridge *weakSelf = self;
        if (_service) {
            QObject::connect(_service, &PendingDeletion::changed, _connections.get(), [weakSelf] { PTPendingDeletionBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
            QObject::connect(_service, &PendingDeletion::retired, _connections.get(), [weakSelf] { PTPendingDeletionBridge *b = weakSelf; if (b.onRetired) b.onRetired(); });
            QObject::connect(_service, &PendingDeletion::commitFailed, _connections.get(), [weakSelf](const QString& title, const QString& reason) {
                PTPendingDeletionBridge* b = weakSelf;
                if (!b) return;
                // 回调显示原标题；仅本桥接发起的同步调用把文案交给 NSError，自动到期不污染无关 Call。
                // Store 按回调序号避免随后抛错再弹一次。
                if (b->_callingDeletion) b->_failures.collect(QStringLiteral("删除「%1」失败：%2").arg(title, reason));
                if (b.onCommitFailed) b.onCommitFailed(string(title), string(reason));
            });
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
    // 参数与登记拒绝没有后续提交回调，必须直接返回原因，Swift 才能说明为何没有进入撤销槽。
    if (id <= 0) return fail(error, QStringLiteral("任务编号无效"));
    if (!_service) return fail(error, QStringLiteral("删除服务未登记或已释放"));
    QScopedValueRollback<bool> calling(_callingDeletion, true);
    FailureCollector::Call call(_failures);
    const bool ok = _service->requestTask(id, string(title));
    if (ok) return YES;
    const QString reason = call.error();
    return fail(error, reason.isEmpty() ? QStringLiteral("请求删除任务失败") : reason);
}
- (BOOL)requestSession:(NSInteger)sessionId title:(NSString *)title isRest:(BOOL)isRest error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"删除请求必须在主线程");
    int id; if (!integer(sessionId, &id)) return fail(error, QStringLiteral("记录编号越界"));
    if (id <= 0) return fail(error, QStringLiteral("记录编号无效"));
    if (!_service) return fail(error, QStringLiteral("删除服务未登记或已释放"));
    QScopedValueRollback<bool> calling(_callingDeletion, true);
    FailureCollector::Call call(_failures);
    const bool ok = _service->requestSession(id, string(title), isRest);
    if (ok) return YES;
    const QString reason = call.error();
    return fail(error, reason.isEmpty() ? QStringLiteral("请求删除记录失败") : reason);
}
- (BOOL)commit:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"删除提交必须在主线程");
    if (!_service) return fail(error, QStringLiteral("删除服务未登记或已释放"));
    QScopedValueRollback<bool> calling(_callingDeletion, true);
    FailureCollector::Call call(_failures);
    const bool ok = _service->commit();
    if (ok) return YES;
    const QString reason = call.error();
    return fail(error, reason.isEmpty() ? QStringLiteral("提交删除失败") : reason);
}
- (void)cancel { NSAssert(NSThread.isMainThread, @"撤销必须在主线程"); if (_service) _service->cancel(); }
- (void)setAutomaticCommitSuspended:(BOOL)suspended {
    NSAssert(NSThread.isMainThread, @"暂停自动提交状态必须在主线程设置");
    if (_service) {
        _service->setAutomaticCommitSuspended(suspended);
    }
}
@end
