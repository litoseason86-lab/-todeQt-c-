#import "PTBackupBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/BackupService.h"
#include <memory>
using namespace PTBridgeSupport;
static NSError *backupError(NSString *message) { return [NSError errorWithDomain:@"PTBackupBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"备份操作失败"}]; }
@implementation PTBackupBridge { std::unique_ptr<QObject> _connections; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"备份桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTBackupBridge *weakSelf = self; auto *service = BackupService::instance(); QObject::connect(service, &BackupService::backupCompleted, _connections.get(), [weakSelf](bool ok, const QString &message) { PTBackupBridge *b = weakSelf; if (b.onBackupCompleted) b.onBackupCompleted(ok, string(message)); }); QObject::connect(service, &BackupService::backupInfoReady, _connections.get(), [weakSelf](const QString &path, const QVariantMap &info) { PTBackupBridge *b = weakSelf; if (b.onBackupInfoReady) b.onBackupInfoReady(string(path), dictionary(info)); }); QObject::connect(service, &BackupService::restoreStarted, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onRestoreStarted) b.onRestoreStarted(); }); QObject::connect(service, &BackupService::restoreCompleted, _connections.get(), [weakSelf](bool ok, const QString &message) { PTBackupBridge *b = weakSelf; if (b.onRestoreCompleted) b.onRestoreCompleted(ok, string(message)); }); QObject::connect(service, &BackupService::autoBackupEnabledChanged, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); QObject::connect(service, &BackupService::lastBackupTimeChanged, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); QObject::connect(service, &BackupService::busyChanged, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); QObject::connect(service, &BackupService::operationBlocksUiChanged, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); QObject::connect(service, &BackupService::operationTextChanged, _connections.get(), [weakSelf] { PTBackupBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); } return self; }
- (NSString *)lastError { return string(BackupService::instance()->lastError()); }
- (BOOL)autoBackupEnabled { return BackupService::instance()->autoBackupEnabled(); } - (NSString *)lastBackupTimeIso { return string(BackupService::instance()->lastBackupTimeIso()); } - (BOOL)busy { return BackupService::instance()->busy(); } - (BOOL)operationBlocksUi { return BackupService::instance()->operationBlocksUi(); } - (NSString *)operationText { return string(BackupService::instance()->operationText()); }
- (void)setAutoBackupEnabled:(BOOL)value error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"自动备份设置必须在主线程");
    BackupService *service = BackupService::instance();
    if (service->autoBackupEnabled() == bool(value)) return;
    // 服务只在偏好成功落盘后发变化信号；读回 QSettings 内存值无法证明写盘成功。
    bool saved = false;
    QObject context;
    QObject::connect(service, &BackupService::autoBackupEnabledChanged, &context, [&saved] { saved = true; });
    service->setAutoBackupEnabled(value);
    if (!saved && error) *error = backupError(string(service->lastError()));
}

- (void)requestBackup:(NSString *)path { BackupService::instance()->requestBackup(string(path)); } - (void)requestBackupInfo:(NSString *)path { BackupService::instance()->requestBackupInfo(string(path)); } - (void)requestRestore:(NSString *)path { BackupService::instance()->requestRestore(string(path)); }
- (NSDictionary *)readBackupInfo:(NSString *)path { return dictionary(BackupService::instance()->readBackupInfo(string(path))); }
- (NSArray<NSDictionary *> *)readBackups:(NSError **)error { const auto result = BackupService::instance()->readBackups(); if (!result.ok()) { if (error) *error = backupError(@"备份文件夹无法读取"); return @[]; } return array(result.value); }
- (NSString *)suggestedBackupFileName { return string(BackupService::instance()->suggestedBackupFileName()); } - (NSString *)backupFileExtension { return string(BackupService::instance()->backupFileExtension()); }
@end
