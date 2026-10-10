#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface PTTrashReadResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSString *today;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *items;
@end

@interface PTTrashBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
- (PTTrashReadResult *)readItems;
- (NSInteger)purgeExpired:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSDictionary *)restoreItem:(NSInteger)trashId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSDictionary *)deleteItem:(NSInteger)trashId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (NSDictionary *)emptyTrash:(NSArray<NSNumber *> *)trashIds error:(NSError **)error __attribute__((swift_error(nonnull_error)));
@end
NS_ASSUME_NONNULL_END
