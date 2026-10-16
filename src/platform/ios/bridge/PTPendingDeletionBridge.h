#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTPendingDeletionBridge : NSObject
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly) NSInteger sessionId;
@property(nonatomic, readonly) BOOL sessionIsRest;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onRetired)(void);
@property(nonatomic, copy, nullable) void (^onCommitFailed)(NSString *title);
- (BOOL)requestTask:(NSInteger)taskId title:(NSString *)title error:(NSError **)error;
- (BOOL)requestSession:(NSInteger)sessionId title:(NSString *)title isRest:(BOOL)isRest error:(NSError **)error;
- (BOOL)commit:(NSError **)error;
- (void)cancel;
- (void)setAutomaticCommitSuspended:(BOOL)suspended;
@end
NS_ASSUME_NONNULL_END
