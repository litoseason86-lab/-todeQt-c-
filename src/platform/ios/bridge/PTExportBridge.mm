#import "PTExportBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/ExportService.h"
#include <memory>
using namespace PTBridgeSupport;
static NSError *exportError(NSString *message) { return [NSError errorWithDomain:@"PTExportBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"导出失败"}]; }
@implementation PTExportBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"导出桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTExportBridge *weakSelf = self; auto *service = ExportService::instance(); QObject::connect(service, &ExportService::exportProgress, _connections.get(), [weakSelf](int current, int total) { PTExportBridge *b = weakSelf; if (b.onProgress) b.onProgress(current, total); }); QObject::connect(service, &ExportService::exportCompleted, _connections.get(), [weakSelf](bool ok, const QString &message) { PTExportBridge *b = weakSelf; if (b.onCompleted) b.onCompleted(ok, string(message)); }); QObject::connect(service, &ExportService::busyChanged, _connections.get(), [weakSelf] { PTExportBridge *b = weakSelf; if (b.onBusyChanged) b.onBusyChanged(); }); } return self; }
- (BOOL)busy { return ExportService::instance()->busy(); }
- (void)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path { ExportService::instance()->requestExportTasks(string(startDate), string(endDate), string(path)); }
- (void)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path { ExportService::instance()->requestExportFocusSessions(string(startDate), string(endDate), string(path)); }
- (void)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory { ExportService::instance()->requestExportAll(string(startDate), string(endDate), string(directory)); }
- (BOOL)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error { if (!ExportService::instance()->exportTasks(string(startDate), string(endDate), string(path))) { if (error) *error = exportError(@"导出任务失败"); return NO; } return YES; }
- (BOOL)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error { if (!ExportService::instance()->exportFocusSessions(string(startDate), string(endDate), string(path))) { if (error) *error = exportError(@"导出专注记录失败"); return NO; } return YES; }
- (BOOL)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory error:(NSError **)error { if (!ExportService::instance()->exportAll(string(startDate), string(endDate), string(directory))) { if (error) *error = exportError(@"导出全部数据失败"); return NO; } return YES; }
- (NSString *)generateFileName:(NSString *)type startDate:(NSString *)startDate endDate:(NSString *)endDate { return string(ExportService::instance()->generateFileName(string(type), string(startDate), string(endDate))); }
@end
