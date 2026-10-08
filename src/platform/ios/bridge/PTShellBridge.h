#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// 只读的外壳值对象。字段对应现有服务的统计与状态，Swift 不拆业务字典。
@interface PTShellSnapshot : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly) NSInteger todayPendingCount;
@property(nonatomic, readonly) NSInteger weekPendingCount;
@property(nonatomic, readonly) NSInteger todayFocusedSeconds;
@property(nonatomic, readonly) NSInteger dueGapCount;
@property(nonatomic, readonly) BOOL hasTimer;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) NSInteger mode;
@property(nonatomic, readonly) NSInteger phase;
@property(nonatomic, readonly) NSInteger elapsedSeconds;
@property(nonatomic, readonly) NSInteger remainingSeconds;
@property(nonatomic, readonly) NSInteger currentTaskId;
@property(nonatomic, readonly, copy) NSString *taskTitle;
@property(nonatomic, readonly) BOOL operationBlocksUi;
@property(nonatomic, readonly, copy) NSString *operationText;
@property(nonatomic, readonly, copy) NSArray<NSString *> *sidebarOrder;
@property(nonatomic, readonly, copy) NSString *backgroundTheme;
@property(nonatomic, readonly) BOOL useWallpaper;
@property(nonatomic, readonly, copy) NSString *selectedPage;
@property(nonatomic, readonly) NSInteger maxCaptureTitleLength;
@end

@interface PTShellBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTShellSnapshot *)readSnapshot NS_SWIFT_NAME(read());
- (BOOL)pause;
- (BOOL)resume;
- (NSInteger)captureTitle:(NSString *)title categoryId:(NSInteger)categoryId sourceTaskId:(NSInteger)sourceTaskId
    NS_SWIFT_NAME(capture(title:categoryID:sourceTaskID:));
- (void)selectPage:(NSString *)page NS_SWIFT_NAME(select(page:));
@end
NS_ASSUME_NONNULL_END
