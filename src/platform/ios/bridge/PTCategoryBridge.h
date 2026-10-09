#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTCategoryValue : NSObject
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *color;
@property(nonatomic, readonly) BOOL isPreset;
@property(nonatomic, readonly) NSInteger displayOrder;
@property(nonatomic, readonly, copy) NSString *createdAt;
@end
@interface PTCategoryResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTCategoryValue *> *categories;
@end
@interface PTCategoryBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTCategoryResult *)allCategories;
- (PTCategoryResult *)category:(NSInteger)categoryId;
- (NSInteger)addCategory:(NSString *)name color:(NSString *)color error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)updateCategory:(NSInteger)categoryId name:(NSString *)name color:(NSString *)color error:(NSError **)error;
- (BOOL)deleteCategory:(NSInteger)categoryId error:(NSError **)error;
- (BOOL)canDeleteCategory:(NSInteger)categoryId;
- (BOOL)nameExists:(NSString *)name excluding:(NSInteger)categoryId;
@end
NS_ASSUME_NONNULL_END
