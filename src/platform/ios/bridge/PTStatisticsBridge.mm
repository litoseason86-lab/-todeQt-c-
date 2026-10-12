#import "PTStatisticsBridge.h"
#include "PTBridgeSupport.h"
#include "../../../services/StatisticsService.h"
#include <QVariantMap>
#include <memory>
using namespace PTBridgeSupport;
// 所有嵌套统计值逐字段投影；可选数字保留空值，不把不可比较的数据伪造成零。
@interface PTDayStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTMonthStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTComparisonMetric ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTStatisticsComparison ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTWeekDayStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTCategoryStatisticsRow ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTCategoryStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTTaskStatisticsRow ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTTaskStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTMonthWeekStatistics ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewGoalDay ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewGoal ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewTodayGoal ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewSubject ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewPlannedRow ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewPlannedTasks ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTReviewFact ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTWeeklyReview ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTFocusSummaryDay ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTFocusSummaryCategory ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@interface PTFocusSummary ()
- (instancetype)initWithMap:(const QVariantMap &)map;
@end
@implementation PTDayStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _totalDuration = map.value("totalDuration").toLongLong();
        _completedTasks = map.value("completedTasks").toLongLong();
        _totalTasks = map.value("totalTasks").toLongLong();
        _completionRate = map.value("completionRate").toDouble();
        _sessionCount = map.value("sessionCount").toLongLong();
        _pomodoroCount = map.value("pomodoroCount").toLongLong();
    } return self;
}
@end
@implementation PTMonthStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _totalDuration = map.value("totalDuration").toLongLong();
        _effectiveDays = map.value("effectiveDays").toLongLong();
        _sessionCount = map.value("sessionCount").toLongLong();
        _completedTasks = map.value("completedTasks").toLongLong();
        _totalTasks = map.value("totalTasks").toLongLong();
    } return self;
}
@end
@implementation PTComparisonMetric
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _hasData = map.value("hasData").toBool();
        _currentValue = map.value("currentValue").toLongLong();
        _previousValue = map.value("previousValue").toLongLong();
        _changePercent = map.value("changePercent").toDouble();
        _trend = map.value("trend").toLongLong();
        _displayText = string(map.value("displayText").toString());
    } return self;
}
@end
@implementation PTStatisticsComparison
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _hasData = map.value("hasData").toBool();
        _periodState = string(map.value("periodState").toString());
        _duration = [[PTComparisonMetric alloc] initWithMap:map.value("duration").toMap()];
        _sessionCount = [[PTComparisonMetric alloc] initWithMap:map.value("sessionCount").toMap()];
        _taskCompletion = [[PTComparisonMetric alloc] initWithMap:map.value("taskCompletion").toMap()];
        _effectiveDays = [[PTComparisonMetric alloc] initWithMap:map.value("effectiveDays").toMap()];
    } return self;
}
@end
@implementation PTWeekDayStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _date = string(map.value("date").toString());
        _duration = map.value("duration").toLongLong();
        _tasks = map.value("tasks").toLongLong();
        _completedTasks = map.value("completedTasks").toLongLong();
    } return self;
}
@end
@implementation PTCategoryStatisticsRow
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _name = string(map.value("name").toString());
        _color = string(map.value("color").toString());
        _duration = map.value("duration").toLongLong();
        _percentage = map.value("percentage").toDouble();
    } return self;
}
@end
@implementation PTCategoryStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        NSMutableArray *categories = [NSMutableArray array]; for (const auto &row : map.value("categories").toList()) [categories addObject:[[PTCategoryStatisticsRow alloc] initWithMap:row.toMap()]]; _categories = [categories copy];
        _totalDuration = map.value("totalDuration").toLongLong();
    } return self;
}
@end
@implementation PTTaskStatisticsRow
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _taskId = map.value("taskId").isNull() ? -1 : map.value("taskId").toInt();
        _title = string(map.value("title").toString());
        _completed = map.value("completed").toBool();
        _categoryName = string(map.value("categoryName").toString());
        _color = string(map.value("color").toString());
        _focusedSeconds = map.value("focusedSeconds").toLongLong();
        _pomodoros = map.value("pomodoros").toLongLong();
        _unassigned = map.value("unassigned").toBool();
    } return self;
}
@end
@implementation PTTaskStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        NSMutableArray *tasks = [NSMutableArray array]; for (const auto &row : map.value("tasks").toList()) [tasks addObject:[[PTTaskStatisticsRow alloc] initWithMap:row.toMap()]]; _tasks = [tasks copy];
        _totalDuration = map.value("totalDuration").toLongLong();
        _taskCount = map.value("taskCount").toLongLong();
    } return self;
}
@end
@implementation PTMonthWeekStatistics
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _label = string(map.value("label").toString());
        _duration = map.value("duration").toLongLong();
        _startDate = string(map.value("startDate").toString());
        _endDate = string(map.value("endDate").toString());
    } return self;
}
@end
@implementation PTReviewGoalDay
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _date = string(map.value("date").toString());
        _goalMinutes = map.value("goalMinutes").toLongLong();
        _actualSeconds = map.value("actualSeconds").toLongLong();
        _met = map.value("met").toBool();
    } return self;
}
@end
@implementation PTReviewGoal
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _goalDays = map.value("goalDays").toLongLong();
        _metDays = map.value("metDays").toLongLong();
        _goalMinutesTotal = map.value("goalMinutesTotal").toLongLong();
        _actualSecondsTotal = map.value("actualSecondsTotal").toLongLong();
        NSMutableArray *days = [NSMutableArray array]; for (const auto &row : map.value("days").toList()) [days addObject:[[PTReviewGoalDay alloc] initWithMap:row.toMap()]]; _days = [days copy];
    } return self;
}
@end
@implementation PTReviewTodayGoal
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _date = string(map.value("date").toString());
        _goalMinutes = map.value("goalMinutes").toLongLong();
        _actualSeconds = map.value("actualSeconds").toLongLong();
        _progressPercent = map.value("progressPercent").toDouble();
    } return self;
}
@end
@implementation PTReviewSubject
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _name = string(map.value("name").toString());
        _color = string(map.value("color").toString());
        _currentSeconds = map.value("currentSeconds").toLongLong();
        _currentSharePercent = map.value("currentSharePercent").toDouble();
        _pseudoSubject = map.value("pseudoSubject").toBool();
        _previousSeconds = map.value("previousSeconds").isNull() ? nil : @(map.value("previousSeconds").toLongLong());
        _deltaSeconds = map.value("deltaSeconds").isNull() ? nil : @(map.value("deltaSeconds").toLongLong());
        _previousSharePercent = map.value("previousSharePercent").isNull() ? nil : @(map.value("previousSharePercent").toDouble());
        _deltaPoints = map.value("deltaPoints").isNull() ? nil : @(map.value("deltaPoints").toDouble());
    } return self;
}
@end
@implementation PTReviewPlannedRow
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _subject = string(map.value("subject").toString());
        _color = string(map.value("color").toString());
        _plannedMinutes = map.value("plannedMinutes").toLongLong();
        _actualSeconds = map.value("actualSeconds").toLongLong();
        _actualDisplayMinutes = map.value("actualDisplayMinutes").toLongLong();
        _differenceDisplayMinutes = map.value("differenceDisplayMinutes").toLongLong();
        _investmentRatioPercent = map.value("investmentRatioPercent").toDouble();
    } return self;
}
@end
@implementation PTReviewPlannedTasks
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        NSMutableArray *rows = [NSMutableArray array]; for (const auto &row : map.value("rows").toList()) [rows addObject:[[PTReviewPlannedRow alloc] initWithMap:row.toMap()]]; _rows = [rows copy];
        _inProgress = map.value("inProgress").toBool();
        _totalPlannedMinutes = map.value("totalPlannedMinutes").toLongLong();
        _totalActualSeconds = map.value("totalActualSeconds").toLongLong();
        _totalActualDisplayMinutes = map.value("totalActualDisplayMinutes").toLongLong();
        _totalDifferenceDisplayMinutes = map.value("totalDifferenceDisplayMinutes").toLongLong();
        _totalInvestmentRatioPercent = map.value("totalInvestmentRatioPercent").isNull() ? nil : @(map.value("totalInvestmentRatioPercent").toDouble());
    } return self;
}
@end
@implementation PTReviewFact
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _type = string(map.value("type").toString());
        _date = string(map.value("date").toString());
        _subject = string(map.value("subject").toString());
        _goalMinutes = map.value("goalMinutes").isNull() ? nil : @(map.value("goalMinutes").toLongLong());
        _actualSeconds = map.value("actualSeconds").isNull() ? nil : @(map.value("actualSeconds").toLongLong());
        _ratioPercent = map.value("ratioPercent").isNull() ? nil : @(map.value("ratioPercent").toDouble());
        _currentSeconds = map.value("currentSeconds").isNull() ? nil : @(map.value("currentSeconds").toLongLong());
        _previousSeconds = map.value("previousSeconds").isNull() ? nil : @(map.value("previousSeconds").toLongLong());
        _currentSharePercent = map.value("currentSharePercent").isNull() ? nil : @(map.value("currentSharePercent").toDouble());
        _deltaPoints = map.value("deltaPoints").isNull() ? nil : @(map.value("deltaPoints").toDouble());
        _plannedMinutes = map.value("plannedMinutes").isNull() ? nil : @(map.value("plannedMinutes").toLongLong());
        _actualDisplayMinutes = map.value("actualDisplayMinutes").isNull() ? nil : @(map.value("actualDisplayMinutes").toLongLong());
        _shortfallDisplayMinutes = map.value("shortfallDisplayMinutes").isNull() ? nil : @(map.value("shortfallDisplayMinutes").toLongLong());
    } return self;
}
@end
@implementation PTWeeklyReview
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _weekStart = string(map.value("weekStart").toString());
        _weekEnd = string(map.value("weekEnd").toString());
        _logicalTodayIso = string(map.value("logicalTodayIso").toString());
        _periodState = string(map.value("periodState").toString());
        _loadState = string(map.value("loadState").toString());
        _errorMessage = string(map.value("errorMessage").toString());
        _hasData = map.value("hasData").toBool();
        _hasDisplayContent = map.value("hasDisplayContent").toBool();
        _goal = map.value("goal").toMap().isEmpty() ? nil : [[PTReviewGoal alloc] initWithMap:map.value("goal").toMap()];
        _todayGoal = map.value("todayGoal").toMap().isEmpty() ? nil : [[PTReviewTodayGoal alloc] initWithMap:map.value("todayGoal").toMap()];
        NSMutableArray *subjects = [NSMutableArray array]; for (const auto &row : map.value("subjects").toList()) [subjects addObject:[[PTReviewSubject alloc] initWithMap:row.toMap()]]; _subjects = [subjects copy];
        _plannedTasks = map.value("plannedTasks").toMap().isEmpty() ? nil : [[PTReviewPlannedTasks alloc] initWithMap:map.value("plannedTasks").toMap()];
        NSMutableArray *facts = [NSMutableArray array]; for (const auto &row : map.value("facts").toList()) [facts addObject:[[PTReviewFact alloc] initWithMap:row.toMap()]]; _facts = [facts copy];
    } return self;
}
@end
@implementation PTFocusSummaryDay
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _date = string(map.value("date").toString());
        _seconds = map.value("seconds").toLongLong();
        _pomodoros = map.value("pomodoros").toLongLong();
    } return self;
}
@end
@implementation PTFocusSummaryCategory
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _categoryId = map.value("id").isNull() ? -1 : map.value("id").toInt();
        _name = string(map.value("name").toString());
        _seconds = map.value("seconds").toLongLong();
    } return self;
}
@end
@implementation PTFocusSummary
- (instancetype)initWithMap:(const QVariantMap &)map {
    if ((self = [super init])) {
        _seconds = map.value("seconds").toLongLong();
        _pomodoros = map.value("pomodoros").toLongLong();
        NSMutableArray *days = [NSMutableArray array]; for (const auto &row : map.value("days").toList()) [days addObject:[[PTFocusSummaryDay alloc] initWithMap:row.toMap()]]; _days = [days copy];
        NSMutableArray *categories = [NSMutableArray array]; for (const auto &row : map.value("categories").toList()) [categories addObject:[[PTFocusSummaryCategory alloc] initWithMap:row.toMap()]]; _categories = [categories copy];
    } return self;
}
@end
@interface PTStatisticsResult ()
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error;
@end
@implementation PTStatisticsResult
- (instancetype)initWithMap:(const QVariantMap &)map error:(const QString &)error {
    if ((self = [super init])) {
        _valid = error.isEmpty(); _error = string(error);
        // 失败不附带半份报告；每个方法只填自己的类型字段，其余保持空值对象。
        const QVariantMap payload = _valid ? map : QVariantMap();
        _day = [[PTDayStatistics alloc] initWithMap:payload.value("day").toMap()];
        _month = [[PTMonthStatistics alloc] initWithMap:payload.value("month").toMap()];
        _comparison = [[PTStatisticsComparison alloc] initWithMap:payload.value("comparison").toMap()];
        NSMutableArray *weekDays = [NSMutableArray array]; for (const auto &row : payload.value("weekDays").toList()) [weekDays addObject:[[PTWeekDayStatistics alloc] initWithMap:row.toMap()]]; _weekDays = [weekDays copy];
        _categoryStats = [[PTCategoryStatistics alloc] initWithMap:payload.value("categoryStats").toMap()];
        _taskStats = [[PTTaskStatistics alloc] initWithMap:payload.value("taskStats").toMap()];
        NSMutableArray *monthWeeks = [NSMutableArray array]; for (const auto &row : payload.value("monthWeeks").toList()) [monthWeeks addObject:[[PTMonthWeekStatistics alloc] initWithMap:row.toMap()]]; _monthWeeks = [monthWeeks copy];
        _review = [[PTWeeklyReview alloc] initWithMap:payload.value("review").toMap()];
        _summary = [[PTFocusSummary alloc] initWithMap:payload.value("summary").toMap()];
        _count = payload.value("count").toLongLong();
    } return self;
}
@end
@implementation PTMonthStatisticsInput
@end
static QVariantMap monthMap(PTMonthStatisticsInput *value) {
    return {
        {QStringLiteral("totalDuration"), QVariant::fromValue<qlonglong>(value.totalDuration)},
        {QStringLiteral("effectiveDays"), QVariant::fromValue<qlonglong>(value.effectiveDays)},
        {QStringLiteral("sessionCount"), QVariant::fromValue<qlonglong>(value.sessionCount)},
        {QStringLiteral("completedTasks"), QVariant::fromValue<qlonglong>(value.completedTasks)},
        {QStringLiteral("totalTasks"), QVariant::fromValue<qlonglong>(value.totalTasks)}
    };
}
@implementation PTStatisticsBridge {
    std::unique_ptr<QObject> _connections;
    FailureCollector _failures;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"统计桥接只能在主线程创建");
    if ((self = [super init])) {
        // 弱引用与自有上下文保证释放即断连，工作线程信号回主线程；同步失败归当前读取。
        _connections = std::make_unique<QObject>(); __weak PTStatisticsBridge *weakSelf = self;
        QObject::connect(StatisticsService::instance(), &StatisticsService::operationFailed, _connections.get(), [weakSelf](const QString &message) {
            PTStatisticsBridge *b = weakSelf; if (b && !b->_failures.collect(message) && b.onFailure) b.onFailure(string(message));
        });
    } return self;
}
- (PTStatisticsResult *)dayStats:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getDayStats(date(iso));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("day"), value}} error:error];
}
- (PTStatisticsResult *)todayStats {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getTodayStats();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("day"), value}} error:error];
}
- (PTStatisticsResult *)dayComparison:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getDayComparison(date(iso));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("comparison"), value}} error:error];
}
- (PTStatisticsResult *)weekStats:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getWeekStats(date(iso));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("weekDays"), value}} error:error];
}
- (PTStatisticsResult *)currentWeekStats {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getWeekStats();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("weekDays"), value}} error:error];
}
- (PTStatisticsResult *)weekComparison:(NSString *)iso logicalToday:(NSString *)today {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getWeekComparison(date(iso), string(today));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("comparison"), value}} error:error];
}
- (PTStatisticsResult *)categoryStats:(NSString *)from to:(NSString *)to {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getCategoryStats(date(from), date(to));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("categoryStats"), value}} error:error];
}
- (PTStatisticsResult *)dayTaskStats:(NSString *)iso {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getDayTaskStats(date(iso));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("taskStats"), value}} error:error];
}
- (PTStatisticsResult *)todayTaskStats {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getTodayTaskStats();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("taskStats"), value}} error:error];
}
- (PTStatisticsResult *)monthStats:(NSInteger)year month:(NSInteger)month {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    int y, m; if (!integer(year, &y) || !integer(month, &m)) return [[PTStatisticsResult alloc] initWithMap:{} error:QStringLiteral("年月参数越界")];
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthStats(y, m);
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("month"), value}} error:error];
}
- (PTStatisticsResult *)currentMonthStats {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthStats();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("month"), value}} error:error];
}
- (PTStatisticsResult *)monthComparison:(NSInteger)year month:(NSInteger)month {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    int y, m; if (!integer(year, &y) || !integer(month, &m)) return [[PTStatisticsResult alloc] initWithMap:{} error:QStringLiteral("年月参数越界")];
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthComparison(y, m);
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("comparison"), value}} error:error];
}
- (PTStatisticsResult *)monthComparison:(NSInteger)year month:(NSInteger)month current:(PTMonthStatisticsInput *)current {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    int y, m; if (!integer(year, &y) || !integer(month, &m)) return [[PTStatisticsResult alloc] initWithMap:{} error:QStringLiteral("年月参数越界")];
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthComparison(y, m, monthMap(current));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("comparison"), value}} error:error];
}
- (PTStatisticsResult *)effectiveDays:(NSString *)from to:(NSString *)to {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getEffectiveDays(date(from), date(to));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)suggestedDailyGoal:(NSString *)logicalToday {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->suggestedDailyGoalMinutes(date(logicalToday));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)focusSessionCount:(NSString *)from to:(NSString *)to {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getFocusSessionCount(date(from), date(to));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)validPomodoroCount:(NSString *)from to:(NSString *)to {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getValidPomodoroCount(date(from), date(to));
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)streakDays {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getStreakDays();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)totalFocusDuration {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getTotalFocusDuration();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("count"), value}} error:error];
}
- (PTStatisticsResult *)monthWeeklySummary:(NSInteger)year month:(NSInteger)month {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    int y, m; if (!integer(year, &y) || !integer(month, &m)) return [[PTStatisticsResult alloc] initWithMap:{} error:QStringLiteral("年月参数越界")];
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthWeeklySummary(y, m);
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("monthWeeks"), value}} error:error];
}
- (PTStatisticsResult *)currentMonthWeeklySummary {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getMonthWeeklySummary();
    QString error = scope.error();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("monthWeeks"), value}} error:error];
}
- (PTStatisticsResult *)weeklyReview:(NSString *)iso logicalToday:(NSString *)today {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getWeeklyReview(date(iso), string(today));
    QString error = scope.error();
    if (value.value("loadState").toString() == QStringLiteral("error")) error = value.value("errorMessage").toString();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("review"), value}} error:error];
}
- (PTStatisticsResult *)currentWeeklyReview {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->getWeeklyReview();
    QString error = scope.error();
    if (value.value("loadState").toString() == QStringLiteral("error")) error = value.value("errorMessage").toString();
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("review"), value}} error:error];
}
- (PTStatisticsResult *)focusSummary:(NSString *)from to:(NSString *)to dayStartHour:(NSInteger)hour {
    NSAssert(NSThread.isMainThread, @"统计读取必须在主线程");
    int h; if (!integer(hour, &h)) return [[PTStatisticsResult alloc] initWithMap:{} error:QStringLiteral("日界参数越界")];
    FailureCollector::Call scope(_failures);
    const auto value = StatisticsService::instance()->readFocusSummary(date(from), date(to), h);
    QString error = scope.error();
    if (!value.ok()) error = QStringLiteral("专注汇总读取失败");
    return [[PTStatisticsResult alloc] initWithMap:QVariantMap{{QStringLiteral("summary"), value.value}} error:error];
}
@end
