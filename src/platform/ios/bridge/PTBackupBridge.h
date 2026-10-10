#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTBackupBridge : NSObject
@property(nonatomic, copy, nullable) void (^onBackupCompleted)(BOOL success, NSString *message);
@property(nonatomic, copy, nullable) void (^onBackupInfoReady)(NSString *path, NSDictionary *info);
@property(nonatomic, copy, nullable) void (^onRestoreStarted)(void);
@property(nonatomic, copy, nullable) void (^onRestoreCompleted)(BOOL success, NSString *message);
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, readonly) BOOL autoBackupEnabled;
@property(nonatomic, readonly, copy) NSString *lastBackupTimeIso;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL operationBlocksUi;
@property(nonatomic, readonly, copy) NSString *operationText;
@property(nonatomic, readonly, copy) NSString *lastError;
- (void)setAutoBackupEnabled:(BOOL)value error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (void)requestBackup:(NSString *)path;
- (void)requestBackupInfo:(NSString *)path;
- (void)requestRestore:(NSString *)path;
- (NSDictionary *)readBackupInfo:(NSString *)path;
- (NSArray<NSDictionary *> *)readBackups:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSString *)suggestedBackupFileName;
- (NSString *)backupFileExtension;
@end
NS_ASSUME_NONNULL_END
