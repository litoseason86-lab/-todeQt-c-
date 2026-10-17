#import "PTSyncBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/SyncController.h"
#include <memory>
#include <QPointer>
using namespace PTBridgeSupport;

@interface PTSyncLogValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@implementation PTSyncLogValue
- (instancetype)initWithMap:(const QVariantMap &)map
{
    if ((self = [super init])) {
        _entryId = map.value(QStringLiteral("id")).toLongLong();
        _kind = string(map.value(QStringLiteral("kind")).toString());
        _kindLabel = string(map.value(QStringLiteral("kindLabel")).toString());
        _time = string(map.value(QStringLiteral("time")).toString());
        _title = string(map.value(QStringLiteral("title")).toString());
        _summary = string(map.value(QStringLiteral("summary")).toString());
        _detail = string(map.value(QStringLiteral("detail")).toString());
        _fieldLabel = string(map.value(QStringLiteral("fieldLabel")).toString());
        _lostValue = string(map.value(QStringLiteral("lostValue")).toString());
        _keptValue = string(map.value(QStringLiteral("keptValue")).toString());
        _canCopyLostValue = map.value(QStringLiteral("canCopyLostValue")).toBool();
    }
    return self;
}
@end

static NSError *syncError(NSString *message) { return [NSError errorWithDomain:@"PTSyncBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"同步读取失败"}]; }
static NSString *readError(ServiceReadError error) { return error == ServiceReadError::Database ? @"数据库未打开或同步日志读取失败" : @"同步日志读取失败"; }
@interface PTSyncLogReadResult () - (instancetype)initWithResult:(const ServiceReadResult<QVariantList> &)result; @end
@implementation PTSyncLogReadResult
- (instancetype)initWithResult:(const ServiceReadResult<QVariantList> &)result
{
    if ((self = [super init])) {
        _valid = result.ok();
        _error = result.ok() ? @"" : readError(result.error);
        NSMutableArray<PTSyncLogValue *> *entries = [NSMutableArray array];
        if (result.ok()) {
            for (const auto &item : result.value)
                [entries addObject:[[PTSyncLogValue alloc] initWithMap:item.toMap()]];
        }
        _entries = [entries copy];
    }
    return self;
}
@end

@implementation PTSyncBridge { QPointer<SyncController> _controller; std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"同步桥接只能在主线程创建"); if ((self = [super init])) { _controller = PTBridgeSupport::service<SyncController>(QStringLiteral("syncController")); _connections = std::make_unique<QObject>(); __weak PTSyncBridge *weakSelf = self; if (_controller) { QObject::connect(_controller.data(), &SyncController::statusChanged, _connections.get(), [weakSelf] { PTSyncBridge *b = weakSelf; if (b.onStatusChanged) b.onStatusChanged(); }); QObject::connect(_controller.data(), &SyncController::folderChanged, _connections.get(), [weakSelf] { PTSyncBridge *b = weakSelf; if (b.onFolderChanged) b.onFolderChanged(); }); QObject::connect(_controller.data(), &SyncController::choosingFolderChanged, _connections.get(), [weakSelf] { PTSyncBridge *b = weakSelf; if (b.onChoosingFolderChanged) b.onChoosingFolderChanged(); }); QObject::connect(_controller.data(), &SyncController::logChanged, _connections.get(), [weakSelf] { PTSyncBridge *b = weakSelf; if (b.onLogChanged) b.onLogChanged(); }); QObject::connect(_controller.data(), &SyncController::notice, _connections.get(), [weakSelf](const QString &text) { PTSyncBridge *b = weakSelf; if (b.onNotice) b.onNotice(string(text)); }); QObject::connect(_controller.data(), &SyncController::copyRequested, _connections.get(), [weakSelf](const QString &text) { PTSyncBridge *b = weakSelf; if (b.onCopyRequested) b.onCopyRequested(string(text)); }); } } return self; }
- (BOOL)enabled { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller && _controller->isEnabled(); }
- (NSString *)statusKey { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->statusKey() : QString()); }
- (BOOL)hasProblem { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller && _controller->hasProblem(); }
- (NSString *)summaryText { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->summaryText() : QString()); }
- (NSString *)statusText { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->statusText() : QString()); }
- (NSString *)statusDetail { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->statusDetail() : QString()); }
- (NSInteger)pendingCount { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller ? _controller->pendingCount() : 0; }
- (NSString *)lastSyncedAt { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return timestamp(_controller ? _controller->lastSyncedAt() : QDateTime()); }
- (BOOL)busy { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller && _controller->isBusy(); }
- (BOOL)hasFolder { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller && _controller->hasFolder(); }
- (NSString *)folderDisplayPath { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->folderDisplayPath() : QString()); }
- (BOOL)choosingFolder { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller && _controller->isChoosingFolder(); }
- (NSString *)folderProblem { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->folderProblem() : QString()); }
- (NSInteger)logRevision { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller ? _controller->logRevision() : 0; }
- (NSInteger)logCount { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return _controller ? _controller->logCount() : 0; }
// 登记指针失效时也必须返回原因，不能把用户动作静默丢掉；已派发动作的异步结果仍走原状态与通知。
- (BOOL)setEnabled:(BOOL)value error:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->setEnabled(value); return YES; }
- (BOOL)confirmJoin:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->confirmJoin(); return YES; }
- (BOOL)syncNow:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->syncNow(); return YES; }
- (BOOL)chooseFolder:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->chooseFolder(); return YES; }
- (BOOL)rebuildFolder:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->rebuildFolder(); return YES; }
- (PTSyncLogReadResult *)syncLog:(NSInteger)limit { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); int value; if (!integer(limit, &value)) value = 200; return [[PTSyncLogReadResult alloc] initWithResult:_controller ? _controller->readSyncLog(value) : ServiceReadResult<QVariantList>{QVariantList{}, ServiceReadError::Database}]; }
- (NSInteger)readLogCount:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); const auto result = _controller ? _controller->readLogCount() : ServiceReadResult<int>{0, ServiceReadError::Database}; if (!result.ok() && error) *error = syncError(readError(result.error)); return result.value; }
- (BOOL)copyLostValue:(NSString *)text error:(NSError **)error { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); if (!_controller) return fail(error, QStringLiteral("同步服务未登记或已释放")); _controller->copyLostValue(string(text)); return YES; }
- (NSString *)restoreWarning { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(_controller ? _controller->restoreWarning() : QString()); }
@end
