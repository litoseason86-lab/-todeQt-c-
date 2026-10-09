#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTKnowledgeGapValue : NSObject
@property(nonatomic, readonly) NSInteger gapId;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *detail;
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *categoryColor;
@property(nonatomic, readonly) NSInteger sourceTaskId;
@property(nonatomic, readonly, copy) NSString *sourceTaskTitle;
@property(nonatomic, readonly) NSInteger priority;
@property(nonatomic, readonly) NSInteger status;
@property(nonatomic, readonly, copy) NSString *dueDate;
@property(nonatomic, readonly) BOOL scheduled;
@property(nonatomic, readonly) BOOL overdue;
@property(nonatomic, readonly) NSInteger overdueDays;
@property(nonatomic, readonly) BOOL dueToday;
@property(nonatomic, readonly, copy) NSString *resolution;
@property(nonatomic, readonly) NSInteger linkedTaskId;
@property(nonatomic, readonly) BOOL linkedTaskCompleted;
@property(nonatomic, readonly) BOOL linkedTaskOpen;
@property(nonatomic, readonly, copy) NSString *linkedTaskTitle;
@property(nonatomic, readonly, copy) NSString *createdAt;
@property(nonatomic, readonly, copy) NSString *updatedAt;
@property(nonatomic, readonly, copy) NSString *resolvedAt;
@end
@interface PTKnowledgeGapResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTKnowledgeGapValue *> *items;
@end
// 设过才入改动表；清空字符串和清空分类仍然是明确的改动。
@interface PTKnowledgeGapChanges : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, readonly) BOOL hasTitle;
@property(nonatomic) NSInteger categoryId;
@property(nonatomic, readonly) BOOL hasCategoryId;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, readonly) BOOL hasDetail;
@property(nonatomic) NSInteger priority;
@property(nonatomic, readonly) BOOL hasPriority;
@property(nonatomic, copy) NSString *dueDate;
@property(nonatomic, readonly) BOOL hasDueDate;
@end
@interface PTKnowledgeGapBridge : NSObject
@property(nonatomic, copy, nullable) void (^onChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
@property(nonatomic, copy, nullable) void (^onTasksAffected)(void);
- (PTKnowledgeGapResult *)gapsWithStatus:(NSInteger)status categoryId:(NSInteger)categoryId search:(NSString *)search;
- (PTKnowledgeGapResult *)gap:(NSInteger)gapId;
- (NSInteger)addTitle:(NSString *)title categoryId:(NSInteger)categoryId detail:(NSString *)detail priority:(NSInteger)priority dueDate:(NSString *)dueDate sourceTaskId:(NSInteger)sourceTaskId error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (BOOL)updateGap:(NSInteger)gapId changes:(PTKnowledgeGapChanges *)changes error:(NSError **)error;
- (BOOL)setDueDate:(NSInteger)gapId date:(NSString *)date error:(NSError **)error;
- (BOOL)moveGaps:(NSArray<NSNumber *> *)ids date:(NSString *)date error:(NSError **)error;
- (BOOL)resolveGap:(NSInteger)gapId resolution:(NSString *)resolution error:(NSError **)error;
- (BOOL)reopenGap:(NSInteger)gapId error:(NSError **)error;
- (BOOL)deleteGap:(NSInteger)gapId error:(NSError **)error;
- (NSInteger)convertGap:(NSInteger)gapId date:(NSString *)date error:(NSError **)error __attribute__((swift_error(nonnull_error)));
@end
NS_ASSUME_NONNULL_END
