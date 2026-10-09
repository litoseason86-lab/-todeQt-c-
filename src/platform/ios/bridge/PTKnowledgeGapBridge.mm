#import "PTKnowledgeGapBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/KnowledgeGapService.h"
#include <memory>
using namespace PTBridgeSupport;
namespace {
// 兼容服务返回的旧 SQLite 时间串，输出仍统一为带毫秒的 ISO 时刻。
NSString *storedTime(const QVariant &value) {
    QDateTime time = value.toDateTime();
    if (!time.isValid()) time = QDateTime::fromString(value.toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    return timestamp(time);
}
}
@interface PTKnowledgeGapValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTKnowledgeGapResult ()
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error;
@end
@implementation PTKnowledgeGapValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _gapId = map.value("id").toInt();
        _title = string(map.value("title").toString());
        _detail = string(map.value("detail").toString());
        _categoryId = map.value("categoryId").toInt();
        _categoryName = string(map.value("categoryName").toString());
        _categoryColor = string(map.value("categoryColor").toString());
        _sourceTaskId = (map.value("sourceTaskId").toInt() > 0 ? map.value("sourceTaskId").toInt() : -1);
        _sourceTaskTitle = string(map.value("sourceTaskTitle").toString());
        _priority = map.value("priority").toInt();
        _status = map.value("status").toInt();
        _dueDate = string(map.value("dueDate").toString());
        _scheduled = map.value("scheduled").toBool();
        _overdue = map.value("overdue").toBool();
        _overdueDays = map.value("overdueDays").toInt();
        _dueToday = map.value("dueToday").toBool();
        _resolution = string(map.value("resolution").toString());
        _linkedTaskId = (map.value("linkedTaskId").toInt() > 0 ? map.value("linkedTaskId").toInt() : -1);
        _linkedTaskCompleted = map.value("linkedTaskCompleted").toBool();
        _linkedTaskOpen = map.value("linkedTaskOpen").toBool();
        _linkedTaskTitle = string(map.value("linkedTaskTitle").toString());
        _createdAt = storedTime(map.value("createdAt"));
        _updatedAt = storedTime(map.value("updatedAt"));
        _resolvedAt = storedTime(map.value("resolvedAt"));
    }
    return self;
}
@end
@implementation PTKnowledgeGapResult
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray *items = [NSMutableArray array];
        if (_valid) for (const auto &row : rows) [items addObject:[[PTKnowledgeGapValue alloc] initWithMap:row.toMap()]];
        _items = [items copy];
    }
    return self;
}
@end
@implementation PTKnowledgeGapChanges
- (void)setTitle:(NSString *)value { _title = [value copy]; _hasTitle = YES; }
- (void)setCategoryId:(NSInteger )value { _categoryId = value; _hasCategoryId = YES; }
- (void)setDetail:(NSString *)value { _detail = [value copy]; _hasDetail = YES; }
- (void)setPriority:(NSInteger )value { _priority = value; _hasPriority = YES; }
- (void)setDueDate:(NSString *)value { _dueDate = [value copy]; _hasDueDate = YES; }
@end
@implementation PTKnowledgeGapBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文与弱引用保证释放断连；后台信号由 Qt 排队回主线程。
        _connections = std::make_unique<QObject>(); __weak PTKnowledgeGapBridge *weakSelf = self;
        auto *service = KnowledgeGapService::instance();
        QObject::connect(service, &KnowledgeGapService::gapsChanged, _connections.get(), [weakSelf] { PTKnowledgeGapBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
        QObject::connect(service, &KnowledgeGapService::tasksAffected, _connections.get(), [weakSelf] { PTKnowledgeGapBridge *b = weakSelf; if (b.onTasksAffected) b.onTasksAffected(); });
        QObject::connect(service, &KnowledgeGapService::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTKnowledgeGapBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
// 调用期间的失败只归当前 NSError；界面收到同步变化时可以延后重读。
- (PTKnowledgeGapResult *)gapsWithStatus:(NSInteger)status categoryId:(NSInteger)categoryId search:(NSString *)search {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    FailureCollector::Call call(_failures);
    int filter, category;
    if (!integer(status, &filter) || !integer(categoryId, &category)) return [[PTKnowledgeGapResult alloc] initWithRows:{} error:QStringLiteral("筛选编号越界")];
    const auto rows = KnowledgeGapService::instance()->listGaps(filter, category, string(search), 0);
    return [[PTKnowledgeGapResult alloc] initWithRows:rows error:call.error()];
}
- (PTKnowledgeGapResult *)gap:(NSInteger)gapId {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    FailureCollector::Call call(_failures);
    int id; if (!integer(gapId, &id)) return [[PTKnowledgeGapResult alloc] initWithRows:{} error:QStringLiteral("编号越界")];
    const auto value = KnowledgeGapService::instance()->getGap(id);
    return [[PTKnowledgeGapResult alloc] initWithRows:value.isEmpty() ? QVariantList{} : QVariantList{value} error:!call.error().isEmpty() ? call.error() : value.isEmpty() ? QStringLiteral("知识缺口已不存在") : QString()];
}
- (NSInteger)addTitle:(NSString *)title categoryId:(NSInteger)categoryId detail:(NSString *)detail priority:(NSInteger)priority dueDate:(NSString *)dueDate sourceTaskId:(NSInteger)sourceTaskId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int category, level, source;
    if (!integer(categoryId, &category) || !integer(priority, &level) || !integer(sourceTaskId, &source)) { fail(error, QStringLiteral("编号越界")); return -1; }
    if (dueDate.length && !date(dueDate).isValid()) { fail(error, QStringLiteral("到期日无效")); return -1; }
    FailureCollector::Call call(_failures);
    const int id = KnowledgeGapService::instance()->addGap(string(title), category, string(detail), level, string(dueDate), source);
    if (id <= 0) { fail(error, call.error().isEmpty() ? QStringLiteral("新增失败") : call.error()); return -1; } return id;
}
- (BOOL)setDueDate:(NSInteger)gapId date:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int gapIdValue; if (!integer(gapId, &gapIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->setDueDate(gapIdValue, string(iso)) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)resolveGap:(NSInteger)gapId resolution:(NSString *)resolution error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int gapIdValue; if (!integer(gapId, &gapIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->resolveGap(gapIdValue, string(resolution)) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)reopenGap:(NSInteger)gapId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int gapIdValue; if (!integer(gapId, &gapIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->reopenGap(gapIdValue) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)deleteGap:(NSInteger)gapId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int gapIdValue; if (!integer(gapId, &gapIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->deleteGap(gapIdValue) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)moveGaps:(NSArray<NSNumber *> *)ids date:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    QVariantList values; for (NSNumber *number in ids) { int id; if (!integer(number.integerValue, &id)) return fail(error, QStringLiteral("编号越界")); values.append(id); }
    FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->moveGapsToDate(values, string(iso)) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("改期失败") : call.error());
}
- (NSInteger)convertGap:(NSInteger)gapId date:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int id; if (!integer(gapId, &id)) { fail(error, QStringLiteral("编号越界")); return -1; }
    FailureCollector::Call call(_failures); const int task = KnowledgeGapService::instance()->convertToTask(id, string(iso));
    if (task <= 0) { fail(error, call.error().isEmpty() ? QStringLiteral("转任务失败") : call.error()); return -1; } return task;
}
- (BOOL)updateGap:(NSInteger)gapId changes:(PTKnowledgeGapChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int id; if (!integer(gapId, &id)) return fail(error, QStringLiteral("编号越界"));
    QVariantMap map;
    if (changes.hasTitle) map.insert("title", string(changes.title));
    if (changes.hasCategoryId) { int value; if (!integer(changes.categoryId, &value)) return fail(error, QStringLiteral("字段越界")); map.insert("categoryId", value); }
    if (changes.hasDetail) map.insert("detail", string(changes.detail));
    if (changes.hasPriority) { int value; if (!integer(changes.priority, &value)) return fail(error, QStringLiteral("字段越界")); map.insert("priority", value); }
    if (changes.hasDueDate) map.insert("dueDate", string(changes.dueDate));
    FailureCollector::Call call(_failures);
    return KnowledgeGapService::instance()->updateGapChanges(id, map) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存失败") : call.error());
}
@end
