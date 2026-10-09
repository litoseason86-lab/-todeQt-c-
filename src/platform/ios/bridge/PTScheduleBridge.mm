#import "PTScheduleBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/ScheduleService.h"
#include "../../../services/AppSettings.h"
#include <memory>
using namespace PTBridgeSupport;

@interface PTScheduleEntry ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTSchedulePeriod ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTScheduleResult ()
- (instancetype)initWithEntries:(const QVariantList &)entries periods:(const QVariantList &)periods error:(const QString &)error;
@end
@interface PTScheduleSettings ()
- (instancetype)initWithSettings:(AppSettings *)settings;
@end
@interface PTScheduleBridge ()
// 只在 Mac 测试注入独立设置后端，公开头文件保持 Foundation 边界。
- (instancetype)initWithSettings:(AppSettings *)settings;
@end

@implementation PTScheduleEntry
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _entryId = map.value("id").toInt();
        _title = string(map.value("title").toString());
        _location = string(map.value("location").toString());
        _weekday = map.value("weekday").toInt();
        _startMinutes = map.value("startMinutes").toInt();
        _endMinutes = map.value("endMinutes").toInt();
        _weekStart = map.value("weekStart").toInt();
        _weekEnd = map.value("weekEnd").toInt();
        _weekParity = map.value("weekParity").toInt();
        _categoryId = map.value("categoryId").isNull() ? -1 : map.value("categoryId").toInt();
        _durationMinutes = map.value("durationMinutes").toInt();
        _categoryName = string(map.value("categoryName").toString());
        _categoryColor = string(map.value("categoryColor").toString());
    }
    return self;
}
@end
@implementation PTSchedulePeriod
- (instancetype)initWithStartMinutes:(NSInteger)start endMinutes:(NSInteger)end {
    if ((self = [super init])) { _index = 0; _startMinutes = start; _endMinutes = end; }
    return self;
}
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _index = map.value("index").toInt();
        _startMinutes = map.value("startMinutes").toInt();
        _endMinutes = map.value("endMinutes").toInt();
    }
    return self;
}
@end
@implementation PTScheduleResult
- (instancetype)initWithEntries:(const QVariantList &)entries periods:(const QVariantList &)periods error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        NSMutableArray *entryValues = [NSMutableArray array], *periodValues = [NSMutableArray array];
        if (_valid) {
            for (const auto &row : entries) [entryValues addObject:[[PTScheduleEntry alloc] initWithMap:row.toMap()]];
            for (const auto &row : periods) [periodValues addObject:[[PTSchedulePeriod alloc] initWithMap:row.toMap()]];
        }
        _entries = [entryValues copy]; _periods = [periodValues copy];
    }
    return self;
}
@end
@implementation PTScheduleSettings
- (instancetype)initWithSettings:(AppSettings *)settings {
    if ((self = [super init])) {
        _semesterStartDate = string(settings->semesterStartDate());
        _semesterWeeks = settings->semesterWeeks();
        _showWeekend = settings->scheduleShowWeekend();
    }
    return self;
}
@end
@implementation PTScheduleChanges
- (void)setTitle:(NSString *)value { _title = [value copy]; _hasTitle = YES; }
- (void)setLocation:(NSString *)value { _location = [value copy]; _hasLocation = YES; }
- (void)setWeekday:(NSInteger)value { _weekday = value; _hasWeekday = YES; }
- (void)setStartMinutes:(NSInteger)value { _startMinutes = value; _hasStartMinutes = YES; }
- (void)setEndMinutes:(NSInteger)value { _endMinutes = value; _hasEndMinutes = YES; }
- (void)setWeekStart:(NSInteger)value { _weekStart = value; _hasWeekStart = YES; }
- (void)setWeekEnd:(NSInteger)value { _weekEnd = value; _hasWeekEnd = YES; }
- (void)setWeekParity:(NSInteger)value { _weekParity = value; _hasWeekParity = YES; }
- (void)setCategoryId:(NSInteger)value { _categoryId = value; _hasCategoryId = YES; }
@end

static bool entryChanges(PTScheduleChanges *changes, QVariantMap *map, NSError **error) {
    // 未设置的字段不能进入跨层改动表；负科目编号是显式清空，不能省略。
    int number;
    if (changes.hasTitle) map->insert(QStringLiteral("title"), string(changes.title));
    if (changes.hasLocation) map->insert(QStringLiteral("location"), string(changes.location));
    if (changes.hasWeekday) {
        if (!integer(changes.weekday, &number)) return fail(error, QStringLiteral("课表字段越界：weekday"));
        map->insert(QStringLiteral("weekday"), number);
    }
    if (changes.hasStartMinutes) {
        if (!integer(changes.startMinutes, &number)) return fail(error, QStringLiteral("课表字段越界：startMinutes"));
        map->insert(QStringLiteral("startMinutes"), number);
    }
    if (changes.hasEndMinutes) {
        if (!integer(changes.endMinutes, &number)) return fail(error, QStringLiteral("课表字段越界：endMinutes"));
        map->insert(QStringLiteral("endMinutes"), number);
    }
    if (changes.hasWeekStart) {
        if (!integer(changes.weekStart, &number)) return fail(error, QStringLiteral("课表字段越界：weekStart"));
        map->insert(QStringLiteral("weekStart"), number);
    }
    if (changes.hasWeekEnd) {
        if (!integer(changes.weekEnd, &number)) return fail(error, QStringLiteral("课表字段越界：weekEnd"));
        map->insert(QStringLiteral("weekEnd"), number);
    }
    if (changes.hasWeekParity) {
        if (!integer(changes.weekParity, &number)) return fail(error, QStringLiteral("课表字段越界：weekParity"));
        map->insert(QStringLiteral("weekParity"), number);
    }
    if (changes.hasCategoryId) {
        if (!integer(changes.categoryId, &number)) return fail(error, QStringLiteral("课表字段越界：categoryId"));
        map->insert(QStringLiteral("categoryId"), number);
    }
    return true;
}

@implementation PTScheduleBridge {
    QPointer<AppSettings> _settings;
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init { return [self initWithSettings:AppSettings::instance()]; }
- (instancetype)initWithSettings:(AppSettings *)settings {
    NSAssert(NSThread.isMainThread, @"课表桥接只能在主线程创建");
    if ((self = [super init])) {
        // QObject 上下文把工作线程信号排回主线程，释放时自动断连；弱引用不反向保留桥接。
        _settings = settings; _connections = std::make_unique<QObject>();
        __weak PTScheduleBridge *weakSelf = self;
        QObject::connect(ScheduleService::instance(), &ScheduleService::scheduleChanged, _connections.get(), [weakSelf] {
            PTScheduleBridge *b = weakSelf; if (b.onScheduleChanged) b.onScheduleChanged();
        });
        QObject::connect(ScheduleService::instance(), &ScheduleService::periodsChanged, _connections.get(), [weakSelf] {
            PTScheduleBridge *b = weakSelf; if (b.onPeriodsChanged) b.onPeriodsChanged();
        });
        QObject::connect(ScheduleService::instance(), &ScheduleService::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTScheduleBridge *b = weakSelf;
            if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
        QObject::connect(settings, &AppSettings::settingsWriteFailed, _connections.get(), [weakSelf](const QString &key, const QString &message) {
            // 设置服务共用失败信号；其它页面的设置失败不归课表接收。
            if (!key.startsWith(QStringLiteral("schedule"))) return;
            PTScheduleBridge *b = weakSelf;
            if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
        QObject::connect(settings, &AppSettings::semesterStartDateChanged, _connections.get(), [weakSelf] {
            PTScheduleBridge *b = weakSelf; if (b.onSemesterStartDateChanged) b.onSemesterStartDateChanged();
        });
        QObject::connect(settings, &AppSettings::semesterWeeksChanged, _connections.get(), [weakSelf] {
            PTScheduleBridge *b = weakSelf; if (b.onSemesterWeeksChanged) b.onSemesterWeeksChanged();
        });
        QObject::connect(settings, &AppSettings::scheduleShowWeekendChanged, _connections.get(), [weakSelf] {
            PTScheduleBridge *b = weakSelf; if (b.onShowWeekendChanged) b.onShowWeekendChanged();
        });
    }
    return self;
}
- (PTScheduleResult *)entries {
    NSAssert(NSThread.isMainThread, @"课表读取必须在主线程");
    FailureCollector::Call call(_failures);
    const auto rows = ScheduleService::instance()->getEntries();
    return [[PTScheduleResult alloc] initWithEntries:rows periods:{} error:call.error()];
}
- (PTScheduleResult *)entriesForWeek:(NSInteger)week {
    NSAssert(NSThread.isMainThread, @"课表读取必须在主线程"); int converted;
    if (!integer(week, &converted)) return [[PTScheduleResult alloc] initWithEntries:{} periods:{} error:QStringLiteral("周次越界")];
    FailureCollector::Call call(_failures);
    const auto rows = ScheduleService::instance()->getEntriesForWeek(converted);
    return [[PTScheduleResult alloc] initWithEntries:rows periods:{} error:call.error()];
}
- (PTScheduleResult *)conflicts:(NSInteger)weekday startMinutes:(NSInteger)start endMinutes:(NSInteger)end
                     weekStart:(NSInteger)weekStart weekEnd:(NSInteger)weekEnd parity:(NSInteger)parity excluding:(NSInteger)entryId {
    NSAssert(NSThread.isMainThread, @"冲突读取必须在主线程");
    int d, s, e, ws, we, p, id;
    if (!integer(weekday, &d) || !integer(start, &s) || !integer(end, &e) || !integer(weekStart, &ws)
        || !integer(weekEnd, &we) || !integer(parity, &p) || !integer(entryId, &id))
        return [[PTScheduleResult alloc] initWithEntries:{} periods:{} error:QStringLiteral("冲突查询参数越界")];
    FailureCollector::Call call(_failures);
    const auto rows = ScheduleService::instance()->findConflicts(d, s, e, ws, we, p, id);
    return [[PTScheduleResult alloc] initWithEntries:rows periods:{} error:call.error()];
}
- (BOOL)addEntry:(NSString *)title weekday:(NSInteger)weekday startMinutes:(NSInteger)start endMinutes:(NSInteger)end
       location:(NSString *)location categoryId:(NSInteger)categoryId weekStart:(NSInteger)weekStart
        weekEnd:(NSInteger)weekEnd parity:(NSInteger)parity error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"课表写入必须在主线程");
    int d, s, e, c, ws, we, p;
    if (!integer(weekday, &d) || !integer(start, &s) || !integer(end, &e) || !integer(categoryId, &c)
        || !integer(weekStart, &ws) || !integer(weekEnd, &we) || !integer(parity, &p))
        return fail(error, QStringLiteral("课程参数越界"));
    FailureCollector::Call call(_failures);
    return ScheduleService::instance()->addEntry(string(title), d, s, e, string(location), c, ws, we, p)
        ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("新增课程失败") : call.error());
}
- (BOOL)updateEntry:(NSInteger)entryId changes:(PTScheduleChanges *)changes error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"课表写入必须在主线程"); int id;
    if (!integer(entryId, &id)) return fail(error, QStringLiteral("课程编号越界"));
    QVariantMap map; if (!entryChanges(changes, &map, error)) return NO;
    FailureCollector::Call call(_failures);
    return ScheduleService::instance()->updateEntryChanges(id, map)
        ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("修改课程失败") : call.error());
}
- (BOOL)deleteEntry:(NSInteger)entryId error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"课表写入必须在主线程"); int id;
    if (!integer(entryId, &id)) return fail(error, QStringLiteral("课程编号越界"));
    FailureCollector::Call call(_failures);
    return ScheduleService::instance()->deleteEntry(id)
        ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("删除课程失败") : call.error());
}
- (PTScheduleResult *)periods {
    NSAssert(NSThread.isMainThread, @"节次读取必须在主线程");
    FailureCollector::Call call(_failures); const auto rows = ScheduleService::instance()->getPeriods();
    return [[PTScheduleResult alloc] initWithEntries:{} periods:rows error:call.error()];
}
- (BOOL)savePeriods:(NSArray<PTSchedulePeriod *> *)periods error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"节次写入必须在主线程");
    QVariantList rows;
    for (PTSchedulePeriod *period in periods) {
        int start, end;
        if (!integer(period.startMinutes, &start) || !integer(period.endMinutes, &end)) return fail(error, QStringLiteral("节次时间越界"));
        rows.append(QVariantMap{{QStringLiteral("startMinutes"), start}, {QStringLiteral("endMinutes"), end}});
    }
    FailureCollector::Call call(_failures);
    return ScheduleService::instance()->setPeriods(rows)
        ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存节次失败") : call.error());
}
- (PTScheduleSettings *)settingsWithError:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"课表设置读取必须在主线程");
    if (!_settings) { fail(error, QStringLiteral("设置服务已释放")); return nil; }
    return [[PTScheduleSettings alloc] initWithSettings:_settings.data()];
}
- (BOOL)saveSettings:(NSString *)semesterStartDate weeks:(NSInteger)weeks showWeekend:(BOOL)showWeekend error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"课表设置写入必须在主线程");
    if (!_settings) return fail(error, QStringLiteral("设置服务已释放"));
    int converted; if (!integer(weeks, &converted)) return fail(error, QStringLiteral("学期周数越界"));
    // 三项只走一次服务原子写入，成功才发布变化信号；桥接不逐个设置属性。
    FailureCollector::Call call(_failures);
    return _settings->saveScheduleSettings(string(semesterStartDate), converted, bool(showWeekend))
        ? YES : fail(error, call.error().isEmpty() ? QStringLiteral("保存课表设置失败") : call.error());
}
- (NSString *)mondayOf:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"周次读取必须在主线程");
    return string(ScheduleService::instance()->mondayOf(string(iso)));
}
- (NSString *)parseSemesterStart:(NSString *)start {
    NSAssert(NSThread.isMainThread, @"周次读取必须在主线程");
    return string(ScheduleService::instance()->parseSemesterStart(string(start)));
}
- (NSInteger)weekIndexForDate:(NSString *)start date:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"周次读取必须在主线程");
    return ScheduleService::instance()->weekIndexForDate(string(start), string(iso));
}
- (NSString *)mondayOfWeek:(NSString *)start week:(NSInteger)week {
    NSAssert(NSThread.isMainThread, @"周次读取必须在主线程"); int converted;
    if (!integer(week, &converted)) return @"";
    return string(ScheduleService::instance()->mondayOfWeek(string(start), converted));
}
- (NSString *)dateOfWeekday:(NSString *)start week:(NSInteger)week weekday:(NSInteger)weekday {
    NSAssert(NSThread.isMainThread, @"周次读取必须在主线程"); int w, d;
    if (!integer(week, &w) || !integer(weekday, &d)) return @"";
    return string(ScheduleService::instance()->dateOfWeekday(string(start), w, d));
}
- (BOOL)overlaps:(double)aStart end:(double)aEnd otherStart:(double)bStart otherEnd:(double)bEnd {
    NSAssert(NSThread.isMainThread, @"区间读取必须在主线程");
    return ScheduleService::instance()->overlaps(aStart, aEnd, bStart, bEnd);
}
- (NSInteger)maxTitleLength { NSAssert(NSThread.isMainThread, @"课表读取必须在主线程"); return ScheduleService::instance()->maxTitleLength(); }
- (NSInteger)maxLocationLength { NSAssert(NSThread.isMainThread, @"课表读取必须在主线程"); return ScheduleService::instance()->maxLocationLength(); }
- (NSInteger)maxWeekIndex { NSAssert(NSThread.isMainThread, @"课表读取必须在主线程"); return ScheduleService::instance()->maxWeekIndex(); }
- (NSInteger)maxPeriodCount { NSAssert(NSThread.isMainThread, @"课表读取必须在主线程"); return ScheduleService::instance()->maxPeriodCount(); }
@end
