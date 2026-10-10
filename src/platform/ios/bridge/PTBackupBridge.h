#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 值对象保留服务字段类型；键映射在 Objective-C++，Swift 只复制属性。
@interface PTBackupInfoValue : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *reason;
@property(nonatomic, readonly, copy) NSString *createdAt;
@property(nonatomic, readonly, copy) NSString *appVersion;
@property(nonatomic, readonly) NSInteger taskCount;
@property(nonatomic, readonly) NSInteger sessionCount;
@end

@interface PTBackupEntryValue : NSObject
@property(nonatomic, readonly, copy) NSString *path;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *modified;
@property(nonatomic, readonly) int64_t sizeBytes;
@end

@interface PTBackupBridge : NSObject
@property(nonatomic, copy, nullable) void (^onBackupCompleted)(BOOL success, NSString *message);
@property(nonatomic, copy, nullable) void (^onBackupInfoReady)(NSString *path, PTBackupInfoValue *info);
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
- (PTBackupInfoValue *)readBackupInfo:(NSString *)path;
- (NSArray<PTBackupEntryValue *> *)readBackups:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSString *)suggestedBackupFileName;
- (NSString *)backupFileExtension;
@end
NS_ASSUME_NONNULL_END
