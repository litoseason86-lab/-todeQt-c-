#import "PTTaskBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/TaskManager.h"
#include <QVariantMap>
#include <memory>
using namespace PTBridgeSupport;

@interface PTTaskValue ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTTaskResult ()
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error;
@end
@implementation PTTaskValue
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _taskId = map.value(QStringLiteral("id")).toInt();
        _title = string(map.value(QStringLiteral("title")).toString());
        _categoryText = string(map.value(QStringLiteral("categoryText")).toString());
        _categoryId = map.value(QStringLiteral("categoryId")).isNull() ? -1 : map.value(QStringLiteral("categoryId")).toInt();
        _categoryName = string(map.value(QStringLiteral("categoryName")).toString());
        _categoryColor = string(map.value(QStringLiteral("categoryColor")).toString());
        _date = string(map.value(QStringLiteral("date")).toString());
        _completed = map.value(QStringLiteral("completed")).toBool();
        _createdAt = timestamp(map.value(QStringLiteral("createdAt")).toDateTime());
        _estimatedMinutes = map.value(QStringLiteral("estimatedMinutes")).toInt();
        _notes = string(map.value(QStringLiteral("notes")).toString());
        _completionNote = string(map.value(QStringLiteral("completionNote")).toString());
        _displayOrder = map.value(QStringLiteral("displayOrder")).toInt();
        _actualPomodoros = map.value(QStringLiteral("actualPomodoros")).toInt();
        _focusedSeconds = map.value(QStringLiteral("focusedSeconds")).toInt();
    }
    return self;
}
@end
@implementation PTTaskResult
- (instancetype)initWithRows:(const QVariantList &)rows error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray<PTTaskValue *> *values = [NSMutableArray array];
        if (_valid) for (const QVariant &row : rows) [values addObject:[[PTTaskValue alloc] initWithMap:row.toMap()]];
        _tasks = [values copy];
    }
    return self;
}
@end
@implementation PTTaskChanges
- (void)setTitle:(NSString *)value { _title = [value copy]; _hasTitle = YES; }
- (void)setCategoryId:(NSInteger)value { _categoryId = value; _hasCategoryId = YES; }
- (void)setDate:(NSString *)value { _date = [value copy]; _hasDate = YES; }
- (void)setEstimatedMinutes:(NSInteger)value { _estimatedMinutes = value; _hasEstimatedMinutes = YES; }
- (void)setNotes:(NSString *)value { _notes = [value copy]; _hasNotes = YES; }
- (void)setCompletionNote:(NSString *)value { _completionNote = [value copy]; _hasCompletionNote = YES; }
@end
@implementation PTTaskBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"任务桥接只能在主线程创建");
    if ((self = [super init])) {
        // 自有接收上下文随桥接析构断连；AutoConnection 将工作线程信号排队回主线程。
        _connections = std::make_unique<QObject>();
        __weak PTTaskBridge *weakSelf = self;
        auto *tasks = TaskManager::instance(); auto *context = _connections.get();
        QObject::connect(tasks, &TaskManager::tasksChanged, context, [weakSelf] { PTTaskBridge *b = weakSelf; if (b.onChanged) b.onChanged(); });
        QObject::connect(tasks, &TaskManager::taskDeleted, context, [weakSelf](int id) { PTTaskBridge *b = weakSelf; if (b.onDeleted) b.onDeleted(id); });
        QObject::connect(tasks, &TaskManager::taskRestored, context, [weakSelf](int id, const QList<int> &ids) {
            PTTaskBridge *b = weakSelf; NSMutableArray<NSNumber *> *values = [NSMutableArray array];
            for (int session : ids) [values addObject:@(session)];
            if (b.onRestored) b.onRestored(id, values);
        });
        QObject::connect(tasks, &TaskManager::operationFailed, context, [weakSelf](const QString &message) {
            PTTaskBridge *b = weakSelf;
            if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    }
    return self;
}
- (PTTaskResult *)tasksForDate:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    FailureCollector::Call call(_failures);
    auto rows = TaskManager::instance()->getTasksByDate(date(iso));
    return [[PTTaskResult alloc] initWithRows:rows error:call.error()];
}
- (PTTaskResult *)todayTasks {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    FailureCollector::Call call(_failures); auto rows = TaskManager::instance()->getTodayTasks();
    return [[PTTaskResult alloc] initWithRows:rows error:call.error()];
}
- (PTTaskResult *)weekTasks:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    FailureCollector::Call call(_failures); auto rows = TaskManager::instance()->getWeekTasks(date(iso));
    return [[PTTaskResult alloc] initWithRows:rows error:call.error()];
}
- (PTTaskResult *)overdueTasks {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    FailureCollector::Call call(_failures); auto rows = TaskManager::instance()->getOverdueUncompletedTasks();
    return [[PTTaskResult alloc] initWithRows:rows error:call.error()];
}
- (PTTaskResult *)task:(NSInteger)taskId {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    int id; if (!integer(taskId, &id)) return [[PTTaskResult alloc] initWithRows:{} error:QStringLiteral("任务编号越界")];
    const auto result = TaskManager::instance()->readTask(id);
    QString error;
    if (!result.ok()) error = result.error == ServiceReadError::NotFound ? QStringLiteral("任务已不存在") : QStringLiteral("读取任务失败");
    return [[PTTaskResult alloc] initWithRows:result.ok() ? QVariantList{result.value} : QVariantList{} error:error];
}
- (PTTaskResult *)search:(NSString *)text status:(NSInteger)status limit:(NSInteger)limit {
    NSAssert(NSThread.isMainThread, @"任务搜索必须在主线程");
    int s, l; if (!integer(status, &s) || !integer(limit, &l)) return [[PTTaskResult alloc] initWithRows:{} error:QStringLiteral("搜索参数越界")];
    FailureCollector::Call call(_failures); auto rows = TaskManager::instance()->searchTasks(string(text), s, l);
    return [[PTTaskResult alloc] initWithRows:rows error:call.error()];
}
- (NSInteger)createTask:(NSString *)title date:(NSString *)iso categoryId:(NSInteger)categoryId estimatedMinutes:(NSInteger)estimatedMinutes notes:(NSString *)notes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int category, minutes;
    if (!integer(categoryId, &category) || !integer(estimatedMinutes, &minutes)) { fail(error, QStringLiteral("任务参数越界")); return -1; }
    FailureCollector::Call call(_failures);
    const int id = TaskManager::instance()->createTask(string(title), date(iso), category, minutes, string(notes));
    if (id <= 0) fail(error, call.error());
    return id;
}
- (BOOL)updateTask:(NSInteger)taskId changes:(PTTaskChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    // 改动表仅含明确设置的字段；清空与未修改分开，保留同步期间其它设备写入的值。
    QVariantMap map;
    if (changes.hasTitle) map.insert(QStringLiteral("title"), string(changes.title));
    if (changes.hasCategoryId) { int value; if (!integer(changes.categoryId, &value)) return fail(error, QStringLiteral("任务字段越界")); map.insert(QStringLiteral("categoryId"), value); }
    if (changes.hasDate) map.insert(QStringLiteral("date"), QVariant(date(changes.date)));
    if (changes.hasEstimatedMinutes) { int value; if (!integer(changes.estimatedMinutes, &value)) return fail(error, QStringLiteral("任务字段越界")); map.insert(QStringLiteral("estimatedMinutes"), value); }
    if (changes.hasNotes) map.insert(QStringLiteral("notes"), string(changes.notes));
    if (changes.hasCompletionNote) map.insert(QStringLiteral("completionNote"), string(changes.completionNote));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->updateTaskChanges(id, map) || fail(error, call.error());
}
- (BOOL)setCompleted:(NSInteger)taskId completed:(BOOL)completed error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->setTaskCompleted(id, completed) || fail(error, call.error());
}
- (BOOL)completeTask:(NSInteger)taskId note:(NSString *)note error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->completeTaskWithNote(id, string(note)) || fail(error, call.error());
}
- (BOOL)moveTask:(NSInteger)taskId before:(NSInteger)beforeTaskId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id, before; if (!integer(taskId, &id) || !integer(beforeTaskId, &before)) return fail(error, QStringLiteral("任务编号越界"));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->moveTaskBefore(id, before) || fail(error, call.error());
}
- (BOOL)moveTask:(NSInteger)taskId toDate:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->moveTaskToDate(id, date(iso)) || fail(error, call.error());
}
- (BOOL)duplicateTask:(NSInteger)taskId date:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务写入必须在主线程");
    int id; if (!integer(taskId, &id)) return fail(error, QStringLiteral("任务编号越界"));
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->duplicateTask(id, date(iso)) || fail(error, call.error());
}
- (BOOL)moveTasks:(NSArray<NSNumber *> *)ids toDate:(NSString *)iso error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"批量任务写入必须在主线程");
    QVariantList values; for (NSNumber *number in ids) { int id; if (!integer(number.integerValue, &id)) return fail(error, QStringLiteral("任务编号越界")); values.append(id); }
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->moveTasksToDate(values, date(iso)) || fail(error, call.error());
}
- (BOOL)moveTasksToToday:(NSArray<NSNumber *> *)ids error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"批量任务写入必须在主线程");
    QVariantList values; for (NSNumber *number in ids) { int id; if (!integer(number.integerValue, &id)) return fail(error, QStringLiteral("任务编号越界")); values.append(id); }
    FailureCollector::Call call(_failures);
    return TaskManager::instance()->moveTasksToToday(values) || fail(error, call.error());
}
- (NSArray<NSNumber *> *)plannedMinutesFrom:(NSString *)start days:(NSInteger)days excludingTask:(NSInteger)excludedTaskId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    int count, excluded;
    if (!integer(days, &count) || !integer(excludedTaskId, &excluded)) { fail(error, QStringLiteral("已排时长参数越界")); return nil; }
    const auto result = TaskManager::instance()->readPlannedMinutesByDay(date(start), count, excluded);
    if (!result.ok()) {
        fail(error, result.error == ServiceReadError::InvalidArgument ? QStringLiteral("日期范围无效") : QStringLiteral("读取已排时长失败"));
        return nil;
    }
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(result.value.size())];
    for (int minutes : result.value) [values addObject:@(minutes)];
    return values;
}
- (BOOL)isRoutineGeneratedTask:(NSInteger)taskId {
    NSAssert(NSThread.isMainThread, @"任务读取必须在主线程");
    int id; return integer(taskId, &id) && TaskManager::instance()->isRoutineGeneratedTask(id);
}
@end
