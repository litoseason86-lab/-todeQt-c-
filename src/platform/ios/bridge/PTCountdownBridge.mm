#import "PTCountdownBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/CountdownService.h"
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
@interface PTCountdownValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTCountdownResult ()
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error;
@end
@implementation PTCountdownValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _goalId = map.value("id").toInt();
        _name = string(map.value("name").toString());
        _targetDate = string(map.value("targetDate").toString());
        _displayOrder = map.value("displayOrder").toInt();
        _daysRemaining = map.value("daysRemaining").toInt();
        _createdAt = storedTime(map.value("createdAt"));
        _updatedAt = storedTime(map.value("updatedAt"));
    }
    return self;
}
@end
@implementation PTCountdownResult
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray *items = [NSMutableArray array];
        if (_valid) for (const auto &row : rows) [items addObject:[[PTCountdownValue alloc] initWithMap:row.toMap()]];
        _items = [items copy];
    }
    return self;
}
@end
@implementation PTCountdownChanges
- (void)setName:(NSString *)value { _name = [value copy]; _hasName = YES; }
- (void)setTargetDate:(NSString *)value { _targetDate = [value copy]; _hasTargetDate = YES; }
@end
@implementation PTCountdownBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有上下文与弱引用保证释放断连；后台信号由 Qt 排队回主线程。
        _connections = std::make_unique<QObject>(); __weak PTCountdownBridge *weakSelf = self;
        auto *service = CountdownService::instance();
        QObject::connect(service, &CountdownService::goalsReloaded, _connections.get(), [weakSelf] { PTCountdownBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
        auto changed = [weakSelf] { PTCountdownBridge *b = weakSelf; if (b.onChanged) b.onChanged(); };
        QObject::connect(service->model(), &QAbstractItemModel::modelReset, _connections.get(), changed);
        QObject::connect(service->model(), &QAbstractItemModel::rowsInserted, _connections.get(), changed);
        QObject::connect(service->model(), &QAbstractItemModel::rowsRemoved, _connections.get(), changed);
        QObject::connect(service->model(), &QAbstractItemModel::rowsMoved, _connections.get(), changed);
        QObject::connect(service->model(), &QAbstractItemModel::dataChanged, _connections.get(), changed);
        QObject::connect(service, &CountdownService::primaryGoalChanged, _connections.get(), [weakSelf] { PTCountdownBridge *b = weakSelf; if (b.onPrimaryGoalChanged) b.onPrimaryGoalChanged(); });
        QObject::connect(service, &CountdownService::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTCountdownBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
// 调用期间的失败只归当前 NSError；界面收到同步变化时可以延后重读。
- (PTCountdownResult *)goals {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    FailureCollector::Call call(_failures); auto *service = CountdownService::instance();
    if (!service->reload()) return [[PTCountdownResult alloc] initWithRows:{} error:call.error().isEmpty() ? QStringLiteral("读取目标失败") : call.error()];
    QVariantList rows; auto *model = service->model();
    for (int i = 0; i < model->rowCount(); ++i) {
        const auto index = model->index(i);
        const auto &goal = model->goals().at(i);
        rows.append(QVariantMap{{"id", goal.id()}, {"name", goal.name()}, {"targetDate", goal.targetDate().toString(Qt::ISODate)},
            {"displayOrder", goal.displayOrder()}, {"daysRemaining", model->data(index, CountdownModel::DaysRemainingRole)},
            {"createdAt", goal.createdAt()}, {"updatedAt", goal.updatedAt()}});
    }
    return [[PTCountdownResult alloc] initWithRows:rows error:call.error()];
}
- (PTCountdownResult *)primaryGoal {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    PTCountdownResult *all = [self goals];
    if (!all.valid) return all;
    auto value = CountdownService::instance()->primaryGoal().toMap();
    if (!value.isEmpty()) {
        // 主目标 map 的编号键是 goalId，列表角色是 id；在桥接统一，Swift 不处理这项差异。
        value.insert("id", value.take("goalId"));
        const auto &goal = CountdownService::instance()->model()->goals().first();
        value.insert("createdAt", goal.createdAt()); value.insert("updatedAt", goal.updatedAt());
    }
    return [[PTCountdownResult alloc] initWithRows:value.isEmpty() ? QVariantList{} : QVariantList{value} error:QString()];
}
- (BOOL)addName:(NSString *)name date:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    FailureCollector::Call call(_failures);
    return CountdownService::instance()->addGoal(string(name), date(iso)) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)deleteGoal:(NSInteger)goalId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int goalIdValue; if (!integer(goalId, &goalIdValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return CountdownService::instance()->deleteGoal(goalIdValue) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (BOOL)reorderFrom:(NSInteger)from to:(NSInteger)to error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int fromValue; if (!integer(from, &fromValue)) return fail(error, QStringLiteral("编号越界")); int toValue; if (!integer(to, &toValue)) return fail(error, QStringLiteral("编号越界")); FailureCollector::Call call(_failures);
    return CountdownService::instance()->reorder(fromValue, toValue) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("操作失败") : call.error());
}
- (NSInteger)daysRemaining:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    return CountdownService::instance()->calculateDaysRemaining(date(iso));
}
- (BOOL)updateGoal:(NSInteger)goalId changes:(PTCountdownChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"桥接调用必须在主线程");
    int id; if (!integer(goalId, &id)) return fail(error, QStringLiteral("编号越界"));
    QVariantMap map;
    if (changes.hasName) map.insert("name", string(changes.name));
    if (changes.hasTargetDate) map.insert("targetDate", string(changes.targetDate));
    FailureCollector::Call call(_failures);
    return CountdownService::instance()->updateGoalChanges(id, map) ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存失败") : call.error());
}
@end
