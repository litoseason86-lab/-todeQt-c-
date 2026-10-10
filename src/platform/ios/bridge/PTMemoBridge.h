#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTMemoValue : NSObject
@property(nonatomic, readonly) NSInteger memoId;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *body;
@property(nonatomic, readonly, copy) NSString *displayTitle;
@property(nonatomic, readonly, copy) NSString *preview;
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *categoryColor;
@property(nonatomic, readonly) NSInteger sortOrder;
@property(nonatomic, readonly, copy) NSString *createdAt;
@property(nonatomic, readonly, copy) NSString *updatedAt;
@end
@interface PTMemoResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTMemoValue *> *items;
@end
// 设过才入改动表；清空字符串和清空分类仍然是明确的改动。
@interface PTMemoChanges : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, readonly) BOOL hasTitle;
@property(nonatomic, copy) NSString *body;
@property(nonatomic, readonly) BOOL hasBody;
@property(nonatomic) NSInteger categoryId;
@property(nonatomic, readonly) BOOL hasCategoryId;
@end
@interface PTMemoBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTMemoResult *)memos;
- (PTMemoResult *)memo:(NSInteger)memoId;
- (NSInteger)createTitle:(NSString *)title body:(NSString *)body categoryId:(NSInteger)categoryId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)updateMemo:(NSInteger)memoId changes:(PTMemoChanges *)changes error:(NSError **)error;
- (BOOL)deleteMemo:(NSInteger)memoId error:(NSError **)error;
- (BOOL)reorderCategory:(NSInteger)categoryId ids:(NSArray<NSNumber *> *)ids error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
