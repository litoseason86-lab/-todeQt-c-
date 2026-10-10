#import "PTRoutineBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/RoutineManager.h"
#include <memory>
using namespace PTBridgeSupport;
@implementation PTRoutineBridge { std::unique_ptr<QObject> _connections; FailureCollector _failures; }
- (instancetype)init { NSAssert(NSThread.isMainThread, @"例行桥接只能在主线程创建"); if ((self = [super init])) { _connections = std::make_unique<QObject>(); __weak PTRoutineBridge *weakSelf = self; auto *service = RoutineManager::instance(); QObject::connect(service, &RoutineManager::routinesChanged, _connections.get(), [weakSelf] { PTRoutineBridge *b = weakSelf; if (b.onChanged) b.onChanged(); }); QObject::connect(service, &RoutineManager::operationFailed, _connections.get(), [weakSelf](const QString &message) { PTRoutineBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message)); }); } return self; }
- (NSArray<NSDictionary *> *)routines { return [self readRoutines:nil] ?: @[]; }
- (NSArray<NSDictionary *> *)readRoutines:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"例行读取必须在主线程");
    FailureCollector::Call call(_failures);
    const auto values = RoutineManager::instance()->getRoutines();
    if (!call.error().isEmpty()) { fail(error, call.error()); return nil; }
    return array(values);
}
- (BOOL)addTitle:(NSString *)title categoryId:(NSInteger)categoryId weekdays:(NSInteger)weekdays error:(NSError **)error { int category; int mask; if (!integer(categoryId, &category) || !integer(weekdays, &mask)) return fail(error, QStringLiteral("例行参数越界")); FailureCollector::Call call(_failures); if (!RoutineManager::instance()->addRoutine(string(title), category, mask)) return fail(error, call.error().isEmpty() ? QStringLiteral("新增每日例行失败") : call.error()); return YES; }
- (BOOL)update:(NSInteger)routineId changes:(NSDictionary *)changes error:(NSError **)error { int routine; if (!integer(routineId, &routine)) return fail(error, QStringLiteral("例行编号越界")); QVariantMap map;
    // 字段编号按服务的整型契约转换，拒绝越界和未知字段，避免 NSNumber 经 double 丢失类型。
    for (NSString *key in changes) {
        id value = changes[key];
        if ([key isEqualToString:@"title"] && [value isKindOfClass:NSString.class]) {
            map.insert(QStringLiteral("title"), string((NSString *)value));
        } else if ([key isEqualToString:@"categoryId"] && [value isKindOfClass:NSNumber.class]) {
            int category;
            if (!integer([(NSNumber *)value integerValue], &category) || [(NSNumber *)value doubleValue] != category)
                return fail(error, QStringLiteral("科目编号越界"));
            map.insert(QStringLiteral("categoryId"), category);
        } else { return fail(error, QStringLiteral("例行字段无效")); }
    } FailureCollector::Call call(_failures); if (!RoutineManager::instance()->updateRoutineChanges(routine, map)) return fail(error, call.error().isEmpty() ? QStringLiteral("修改每日例行失败") : call.error()); return YES; }
- (BOOL)deleteRoutine:(NSInteger)routineId error:(NSError **)error { int id; if (!integer(routineId, &id)) return fail(error, QStringLiteral("例行编号越界")); FailureCollector::Call call(_failures); if (!RoutineManager::instance()->deleteRoutine(id)) return fail(error, call.error().isEmpty() ? QStringLiteral("删除每日例行失败") : call.error()); return YES; }
- (BOOL)setActive:(NSInteger)routineId active:(BOOL)active error:(NSError **)error { int id; if (!integer(routineId, &id)) return fail(error, QStringLiteral("例行编号越界")); FailureCollector::Call call(_failures); if (!RoutineManager::instance()->setRoutineActive(id, active)) return fail(error, call.error().isEmpty() ? QStringLiteral("修改每日例行状态失败") : call.error()); return YES; }
- (BOOL)setWeekdays:(NSInteger)routineId weekdays:(NSInteger)weekdays error:(NSError **)error { int id; int mask; if (!integer(routineId, &id) || !integer(weekdays, &mask)) return fail(error, QStringLiteral("例行参数越界")); FailureCollector::Call call(_failures); if (!RoutineManager::instance()->setRoutineWeekdays(id, mask)) return fail(error, call.error().isEmpty() ? QStringLiteral("修改例行星期失败") : call.error()); return YES; }
- (NSInteger)materializeToday { return RoutineManager::instance()->materializeToday(); }
@end
