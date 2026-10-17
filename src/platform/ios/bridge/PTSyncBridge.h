#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 值对象保留服务字段类型；键映射在 Objective-C++，Swift 只复制属性。
@interface PTSyncLogValue : NSObject
@property(nonatomic, readonly) int64_t entryId;
@property(nonatomic, readonly, copy) NSString *kind;
@property(nonatomic, readonly, copy) NSString *kindLabel;
@property(nonatomic, readonly, copy) NSString *time;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *summary;
@property(nonatomic, readonly, copy) NSString *detail;
@property(nonatomic, readonly, copy) NSString *fieldLabel;
@property(nonatomic, readonly, copy) NSString *lostValue;
@property(nonatomic, readonly, copy) NSString *keptValue;
@property(nonatomic, readonly) BOOL canCopyLostValue;
@end

@interface PTSyncLogReadResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTSyncLogValue *> *entries;
@end

@interface PTSyncBridge : NSObject
@property(nonatomic, copy, nullable) void (^onStatusChanged)(void);
@property(nonatomic, copy, nullable) void (^onFolderChanged)(void);
@property(nonatomic, copy, nullable) void (^onChoosingFolderChanged)(void);
@property(nonatomic, copy, nullable) void (^onLogChanged)(void);
@property(nonatomic, copy, nullable) void (^onNotice)(NSString *message);
@property(nonatomic, copy, nullable) void (^onCopyRequested)(NSString *text);
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly, copy) NSString *statusKey;
@property(nonatomic, readonly) BOOL hasProblem;
@property(nonatomic, readonly, copy) NSString *summaryText;
@property(nonatomic, readonly, copy) NSString *statusText;
@property(nonatomic, readonly, copy) NSString *statusDetail;
@property(nonatomic, readonly) NSInteger pendingCount;
@property(nonatomic, readonly, copy) NSString *lastSyncedAt;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL hasFolder;
@property(nonatomic, readonly, copy) NSString *folderDisplayPath;
@property(nonatomic, readonly) BOOL choosingFolder;
@property(nonatomic, readonly, copy) NSString *folderProblem;
@property(nonatomic, readonly) NSInteger logRevision;
@property(nonatomic, readonly) NSInteger logCount;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)confirmJoin:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)syncNow:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)chooseFolder:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)rebuildFolder:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (PTSyncLogReadResult *)syncLog:(NSInteger)limit;
- (NSInteger)readLogCount:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)copyLostValue:(NSString *)text error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSString *)restoreWarning;
@end
NS_ASSUME_NONNULL_END
