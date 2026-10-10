#import "PTMemoBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/MemoService.h"
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
@interface PTMemoValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTMemoResult ()
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error;
@end
@implementation PTMemoValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _memoId = map.value("id").toInt();
        _title = string(map.value("title").toString());
        _body = string(map.value("body").toString());
        _displayTitle = string(map.value("displayTitle").toString());
        _preview = string(map.value("preview").toString());
        _categoryId = map.value("categoryId").toInt();
        _categoryName = string(map.value("categoryName").toString());
        _categoryColor = string(map.value("categoryColor").toString());
        _sortOrder = map.value("sortOrder").toInt();
        _createdAt = storedTime(map.value("createdAt"));
        _updatedAt = storedTime(map.value("updatedAt"));
    }
    return self;
}
@end
@implementation PTMemoResult
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray *items = [NSMutableArray array];
        if (_valid) for (const auto &row : rows) [items addObject:[[PTMemoValue alloc] initWithMap:row.toMap()]];
        _items = [items copy];
    }
    return self;
}
@end
@implementation PTMemoChanges
- (void)setTitle:(NSString *)value { _title = [value copy]; _hasTitle = YES; }
- (void)setBody:(NSString *)value { _body = [value copy]; _hasBody = YES; }
- (void)setCategoryId:(NSInteger )value { _categoryId = value; _hasCategoryId = YES; }
@end
@implementation PTMemoBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文与弱引用保证释放断连；后台信号由 Qt 排队回主线程。
        _connections = std::make_unique<QObject>(); __weak PTMemoBridge *weakSelf = self;
        auto *service = MemoService::instance();
        QObject::connect(service, &MemoService::memosChanged, _connections.get(), [weakSelf] { PTMemoBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
        QObject::connect(service, &MemoService::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTMemoBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
// 调用期间的失败只归当前 NSError；界面收到同步变化时可以延后重读。
- (PTMemoResult *)memos {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    const auto result = MemoService::instance()->readMemos();
    return [[PTMemoResult alloc] initWithRows:result.value("memos").toList() error:result.value("ok").toBool() ? QString() : result.value("error").toString()];
}
- (PTMemoResult *)memo:(NSInteger)memoId {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    FailureCollector::Call call(_failures);
    int id; if (!integer(memoId, &id)) return [[PTMemoResult alloc] initWithRows:{} error:QStringLiteral("编号越界")];
    const auto value = MemoService::instance()->getMemo(id);
    return [[PTMemoResult alloc] initWithRows:value.isEmpty() ? QVariantList{} : QVariantList{value} error:!call.error().isEmpty() ? call.error() : value.isEmpty() ? QStringLiteral("备忘录已不存在") : QString()];
}
- (NSInteger)createTitle:(NSString *)title body:(NSString *)body categoryId:(NSInteger)categoryId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int category; if (!integer(categoryId, &category)) { fail(error, QStringLiteral("编号越界")); return -1; }
    FailureCollector::Call call(_failures); const int id = MemoService::instance()->createMemo(string(title), string(body), category);
    if (id <= 0) { fail(error, call.error().isEmpty() ? QStringLiteral("新建备忘录失败") : call.error()); return -1; } return id;
}
- (BOOL)deleteMemo:(NSInteger)memoId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int memoIdValue; if (!integer(memoId, &memoIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return MemoService::instance()->deleteMemo(memoIdValue) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)reorderCategory:(NSInteger)categoryId ids:(NSArray<NSNumber *> *)ids error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int category; if (!integer(categoryId, &category)) return fail(error, QStringLiteral("编号越界"));
    QVariantList values; for (NSNumber *number in ids) { int id; if (!integer(number.integerValue, &id)) return fail(error, QStringLiteral("编号越界")); values.append(id); }
    FailureCollector::Call call(_failures);
    return MemoService::instance()->reorderMemos(category, values) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("排序失败") : call.error());
}
- (BOOL)updateMemo:(NSInteger)memoId changes:(PTMemoChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int id; if (!integer(memoId, &id)) return fail(error, QStringLiteral("编号越界"));
    QVariantMap map;
    if (changes.hasTitle) map.insert("title", string(changes.title));
    if (changes.hasBody) map.insert("body", string(changes.body));
    if (changes.hasCategoryId) { int value; if (!integer(changes.categoryId, &value)) return fail(error, QStringLiteral("字段越界")); map.insert("categoryId", value); }
    FailureCollector::Call call(_failures);
    return MemoService::instance()->updateMemo(id, map) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存失败") : call.error());
}
@end
