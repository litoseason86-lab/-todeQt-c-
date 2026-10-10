#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTExportBridge : NSObject
@property(nonatomic, copy, nullable) void (^onProgress)(NSInteger current, NSInteger total);
@property(nonatomic, copy, nullable) void (^onCompleted)(BOOL success, NSString *message);
@property(nonatomic, copy, nullable) void (^onBusyChanged)(void);
@property(nonatomic, readonly) BOOL busy;
- (void)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path;
- (void)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path;
- (void)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory;
- (BOOL)exportTasksFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error;
- (BOOL)exportFocusSessionsFrom:(NSString *)startDate to:(NSString *)endDate path:(NSString *)path error:(NSError **)error;
- (BOOL)exportAllFrom:(NSString *)startDate to:(NSString *)endDate directory:(NSString *)directory error:(NSError **)error;
- (NSString *)generateFileName:(NSString *)type startDate:(NSString *)startDate endDate:(NSString *)endDate;
@end
NS_ASSUME_NONNULL_END
