#import "PTCategoryBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/CategoryManager.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTCategoryValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTCategoryResult ()
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error;
@end
@implementation PTCategoryValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _categoryId = map.value("id").toInt(); _name = string(map.value("name").toString());
        _color = string(map.value("color").toString()); _isPreset = map.value("isPreset").toBool();
        _displayOrder = map.value("displayOrder").toInt(); _createdAt = timestamp(map.value("createdAt").toDateTime());
    }
    return self;
}
@end
@implementation PTCategoryResult
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray *values = [NSMutableArray array];
        if (_valid) for (const auto &row : rows) [values addObject:[[PTCategoryValue alloc] initWithMap:row.toMap()]];
        _categories = [values copy];
    }
    return self;
}
@end
@implementation PTCategoryBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"科目桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文断连；弱引用避免回调反向保留桥接，跨线程信号由 Qt 排队回主线程。
        _connections = std::make_unique<QObject>(); __weak PTCategoryBridge *weakSelf = self;
        QObject::connect(CategoryManager::instance(), &CategoryManager::categoriesChanged, _connections.get(), [weakSelf] {
            PTCategoryBridge *b = weakSelf; if (b.onChanged) b.onChanged();
        });
        QObject::connect(CategoryManager::instance(), &CategoryManager::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTCategoryBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
- (PTCategoryResult *)allCategories {
    NSAssert(NSThread.isMainThread, @"科目读取必须在主线程");
    const auto result = CategoryManager::instance()->readAllCategories();
    return [[PTCategoryResult alloc] initWithRows:result.value("categories").toList() error:result.value("ok").toBool() ? QString() : result.value("error").toString()];
}
- (PTCategoryResult *)category:(NSInteger)categoryId {
    NSAssert(NSThread.isMainThread, @"科目读取必须在主线程");
    int id; if (!integer(categoryId, &id)) return [[PTCategoryResult alloc] initWithRows:{} error:QStringLiteral("科目编号越界")];
    const auto result = CategoryManager::instance()->readCategory(id);
    return [[PTCategoryResult alloc] initWithRows:result.ok() ? QVariantList{result.value} : QVariantList{} error:result.ok() ? QString() : QStringLiteral("科目读取失败或已不存在")];
}
- (NSInteger)addCategory:(NSString *)name color:(NSString *)color error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"科目写入必须在主线程"); FailureCollector::Call call(_failures);
    int id = CategoryManager::instance()->addCategory(string(name), string(color));
    if (id < 0) { fail(error, call.error().isEmpty() ? QStringLiteral("新增科目失败") : call.error()); return -1; } return id;
}
- (BOOL)updateCategory:(NSInteger)categoryId name:(NSString *)name color:(NSString *)color error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"科目写入必须在主线程"); int id;
    if (!integer(categoryId, &id)) return fail(error, QStringLiteral("科目编号越界"));
    FailureCollector::Call call(_failures);
    return CategoryManager::instance()->updateCategory(id, string(name), string(color)) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("修改科目失败") : call.error());
}
- (BOOL)deleteCategory:(NSInteger)categoryId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"科目写入必须在主线程"); int id;
    if (!integer(categoryId, &id)) return fail(error, QStringLiteral("科目编号越界")); FailureCollector::Call call(_failures);
    return CategoryManager::instance()->deleteCategory(id) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("删除科目失败") : call.error());
}
- (BOOL)canDeleteCategory:(NSInteger)categoryId {
    NSAssert(NSThread.isMainThread, @"科目读取必须在主线程"); int id; return integer(categoryId, &id) && CategoryManager::instance()->canDeleteCategory(id);
}
- (BOOL)nameExists:(NSString *)name excluding:(NSInteger)categoryId {
    NSAssert(NSThread.isMainThread, @"科目读取必须在主线程"); int id; return integer(categoryId, &id) && CategoryManager::instance()->categoryNameExists(string(name), id);
}
@end
