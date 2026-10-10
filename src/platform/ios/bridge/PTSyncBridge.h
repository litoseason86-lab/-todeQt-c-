#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface PTSyncLogReadResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *entries;
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
- (void)setEnabled:(BOOL)enabled;
- (void)confirmJoin;
- (void)syncNow;
- (void)chooseFolder;
- (void)rebuildFolder;
- (PTSyncLogReadResult *)syncLog:(NSInteger)limit;
- (NSInteger)readLogCount:(NSError **)error;
- (void)copyLostValue:(NSString *)text;
- (NSString *)restoreWarning;
@end
NS_ASSUME_NONNULL_END
