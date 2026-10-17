#import "PTExportBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/ExportService.h"
#include <memory>
using namespace PTBridgeSupport;
namespace {
bool synchronousExport(const std::function<bool()>& action, const QString& fallback, NSError** error)
{
    // 完成回调允许嵌套导出：共用最内层调用收集规则，内外两次失败不能互相覆盖。
    FailureCollector collector;
    FailureCollector::Call call(collector);
    // 接收上下文先于收集器销毁，排队中的后台完成回调不会在返回后访问栈对象。
    QObject context;
    QObject::connect(ExportService::instance(), &ExportService::exportCompleted,
        &context, [&collector](bool ok, const QString& message) {
            if (!ok) collector.collect(message);
        });
    if (action()) return true;
    const QString reason = call.error();
    return fail(error, reason.isEmpty() ? fallback : reason);
}
}
@implementation PTExportBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"导出桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTExportBridge *weakSelf = self; auto *service = ExportService::instance(); QObject::connect(service, &ExportService::exportProgress, _connections.get(), [weakSelf](int current, int total) { PTExportBridge *b = weakSelf; if (b.onProgress) b.onProgress(current, total); }); QObject::connect(service, &ExportService::exportCompleted, _connections.get(), [weakSelf](bool ok, const QString &message) { PTExportBridge *b = weakSelf; if (b.onCompleted) b.onCompleted(ok, string(message)); }); QObject::connect(service, &ExportService::busyChanged, _connections.get(), [weakSelf] { PTExportBridge *b = weakSelf; if (b.onBusyChanged) b.onBusyChanged(); }); } return self; }
- (BOOL)busy { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return ExportService::instance()->busy(); }
- (void)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); ExportService::instance()->requestExportTasks(string(startDate), string(endDate), string(path)); }
- (void)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); ExportService::instance()->requestExportFocusSessions(string(startDate), string(endDate), string(path)); }
- (void)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); ExportService::instance()->requestExportAll(string(startDate), string(endDate), string(directory)); }
- (BOOL)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    return synchronousExport([&] { return ExportService::instance()->exportTasks(string(startDate), string(endDate), string(path)); }, QStringLiteral("导出任务失败"), error);
}
- (BOOL)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    return synchronousExport([&] { return ExportService::instance()->exportFocusSessions(string(startDate), string(endDate), string(path)); }, QStringLiteral("导出专注记录失败"), error);
}
- (BOOL)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用");
    return synchronousExport([&] { return ExportService::instance()->exportAll(string(startDate), string(endDate), string(directory)); }, QStringLiteral("导出全部数据失败"), error);
}
- (NSString *)generateFileName:(NSString *)type startDate:(NSString *)startDate endDate:(NSString *)endDate { NSAssert(NSThread.isMainThread, @"桥接只能在主线程调用"); return string(ExportService::instance()->generateFileName(string(type), string(startDate), string(endDate))); }
@end
