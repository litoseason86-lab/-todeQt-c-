#import "PTGapReminderBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/KnowledgeGapService.h"
#include <memory>
using namespace PTBridgeSupport;
@interface PTGapReminderSummary ()
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error;
@end
@implementation PTGapReminderSummary
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        _dueToday = map.value("dueToday").toInt();
        _overdue = map.value("overdue").toInt();
        _unscheduled = map.value("unscheduled").toInt();
        _openTotal = map.value("openTotal").toInt();
        _oldestOverdueDays = map.value("oldestOverdueDays").toInt();
    }
    return self;
}
@end
@interface PTGapConversionResult ()
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error;
@end
@implementation PTGapConversionResult
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        _converted = map.value("converted").toInt();
        _failed = map.value("failed").toInt();
        _reason = string(map.value("reason").toString());
    }
    return self;
}
@end
@implementation PTGapReminderBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"缺口提醒桥接只能在主线程创建");
    if ((self = [super init])) {
        // 接收上下文随桥接断连，工作线程通知排队回主线程；弱回调不反向保留桥接。
        _connections = std::make_unique<QObject>(); __weak PTGapReminderBridge *weakSelf = self;
        auto *service = KnowledgeGapService::instance(); auto *context = _connections.get();
        QObject::connect(service, &KnowledgeGapService::gapsChanged, context, [weakSelf] { PTGapReminderBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
        QObject::connect(service, &KnowledgeGapService::tasksAffected, context, [weakSelf] { PTGapReminderBridge *b = weakSelf; if (b.onTasksAffected) b.onTasksAffected(); });
        QObject::connect(service, &KnowledgeGapService::operationFailed, context, [weakSelf](const QString &message) {
            PTGapReminderBridge *b = weakSelf;
            if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
- (PTGapReminderSummary *)reminderSummary {
    NSAssert(NSThread.isMainThread, @"缺口提醒读取必须在主线程");
    FailureCollector::Call call(_failures); const auto map = KnowledgeGapService::instance()->getReminderSummary();
    const QString error = map.value("valid").toBool() ? QString() : (call.error().isEmpty() ? QStringLiteral("知识缺口提醒读取失败，请重试") : call.error());
    return [[PTGapReminderSummary alloc] initWithMap:map error:error];
}
- (PTGapConversionResult *)convertDueGapsToTasks {
    NSAssert(NSThread.isMainThread, @"缺口转任务必须在主线程");
    FailureCollector::Call call(_failures); const auto map = KnowledgeGapService::instance()->convertDueGapsToTasks();
    // 每条转换独立事务；部分失败是合法汇总，不能把已成功的结果扔掉。候选读取失败才作为调用错误。
    // 部分失败已在结构化结果里交给调用方，仍须认领信号，避免外壳再提示同一次失败。
    const QString collected = call.error();
    const QString error = map.value("failed").toInt() > 0 ? QString() : collected;
    return [[PTGapConversionResult alloc] initWithMap:map error:error];
}
@end
