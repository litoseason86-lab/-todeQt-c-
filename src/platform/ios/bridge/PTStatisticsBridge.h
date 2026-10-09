#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PTDayStatistics : NSObject
@property(nonatomic, readonly) NSInteger totalDuration;
@property(nonatomic, readonly) NSInteger completedTasks;
@property(nonatomic, readonly) NSInteger totalTasks;
@property(nonatomic, readonly) double completionRate;
@property(nonatomic, readonly) NSInteger sessionCount;
@property(nonatomic, readonly) NSInteger pomodoroCount;
@end
@interface PTMonthStatistics : NSObject
@property(nonatomic, readonly) NSInteger totalDuration;
@property(nonatomic, readonly) NSInteger effectiveDays;
@property(nonatomic, readonly) NSInteger sessionCount;
@property(nonatomic, readonly) NSInteger completedTasks;
@property(nonatomic, readonly) NSInteger totalTasks;
@end
@interface PTComparisonMetric : NSObject
@property(nonatomic, readonly) BOOL hasData;
@property(nonatomic, readonly) NSInteger currentValue;
@property(nonatomic, readonly) NSInteger previousValue;
@property(nonatomic, readonly) double changePercent;
@property(nonatomic, readonly) NSInteger trend;
@property(nonatomic, readonly, copy) NSString *displayText;
@end
@interface PTStatisticsComparison : NSObject
@property(nonatomic, readonly) BOOL hasData;
@property(nonatomic, readonly, copy) NSString *periodState;
@property(nonatomic, readonly) PTComparisonMetric *duration;
@property(nonatomic, readonly) PTComparisonMetric *sessionCount;
@property(nonatomic, readonly) PTComparisonMetric *taskCompletion;
@property(nonatomic, readonly) PTComparisonMetric *effectiveDays;
@end
@interface PTWeekDayStatistics : NSObject
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) NSInteger duration;
@property(nonatomic, readonly) NSInteger tasks;
@property(nonatomic, readonly) NSInteger completedTasks;
@end
@interface PTCategoryStatisticsRow : NSObject
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *color;
@property(nonatomic, readonly) NSInteger duration;
@property(nonatomic, readonly) double percentage;
@end
@interface PTCategoryStatistics : NSObject
@property(nonatomic, readonly, copy) NSArray<PTCategoryStatisticsRow *> *categories;
@property(nonatomic, readonly) NSInteger totalDuration;
@end
@interface PTTaskStatisticsRow : NSObject
@property(nonatomic, readonly) NSInteger taskId;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL completed;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *color;
@property(nonatomic, readonly) NSInteger focusedSeconds;
@property(nonatomic, readonly) NSInteger pomodoros;
@property(nonatomic, readonly) BOOL unassigned;
@end
@interface PTTaskStatistics : NSObject
@property(nonatomic, readonly, copy) NSArray<PTTaskStatisticsRow *> *tasks;
@property(nonatomic, readonly) NSInteger totalDuration;
@property(nonatomic, readonly) NSInteger taskCount;
@end
@interface PTMonthWeekStatistics : NSObject
@property(nonatomic, readonly, copy) NSString *label;
@property(nonatomic, readonly) NSInteger duration;
@property(nonatomic, readonly, copy) NSString *startDate;
@property(nonatomic, readonly, copy) NSString *endDate;
@end
@interface PTReviewGoalDay : NSObject
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) NSInteger goalMinutes;
@property(nonatomic, readonly) NSInteger actualSeconds;
@property(nonatomic, readonly) BOOL met;
@end
@interface PTReviewGoal : NSObject
@property(nonatomic, readonly) NSInteger goalDays;
@property(nonatomic, readonly) NSInteger metDays;
@property(nonatomic, readonly) NSInteger goalMinutesTotal;
@property(nonatomic, readonly) NSInteger actualSecondsTotal;
@property(nonatomic, readonly, copy) NSArray<PTReviewGoalDay *> *days;
@end
@interface PTReviewTodayGoal : NSObject
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) NSInteger goalMinutes;
@property(nonatomic, readonly) NSInteger actualSeconds;
@property(nonatomic, readonly) double progressPercent;
@end
@interface PTReviewSubject : NSObject
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *color;
@property(nonatomic, readonly) NSInteger currentSeconds;
@property(nonatomic, readonly) double currentSharePercent;
@property(nonatomic, readonly) BOOL pseudoSubject;
@property(nonatomic, readonly, nullable) NSNumber *previousSeconds;
@property(nonatomic, readonly, nullable) NSNumber *deltaSeconds;
@property(nonatomic, readonly, nullable) NSNumber *previousSharePercent;
@property(nonatomic, readonly, nullable) NSNumber *deltaPoints;
@end
@interface PTReviewPlannedRow : NSObject
@property(nonatomic, readonly, copy) NSString *subject;
@property(nonatomic, readonly, copy) NSString *color;
@property(nonatomic, readonly) NSInteger plannedMinutes;
@property(nonatomic, readonly) NSInteger actualSeconds;
@property(nonatomic, readonly) NSInteger actualDisplayMinutes;
@property(nonatomic, readonly) NSInteger differenceDisplayMinutes;
@property(nonatomic, readonly) double investmentRatioPercent;
@end
@interface PTReviewPlannedTasks : NSObject
@property(nonatomic, readonly, copy) NSArray<PTReviewPlannedRow *> *rows;
@property(nonatomic, readonly) BOOL inProgress;
@property(nonatomic, readonly) NSInteger totalPlannedMinutes;
@property(nonatomic, readonly) NSInteger totalActualSeconds;
@property(nonatomic, readonly) NSInteger totalActualDisplayMinutes;
@property(nonatomic, readonly) NSInteger totalDifferenceDisplayMinutes;
@property(nonatomic, readonly, nullable) NSNumber *totalInvestmentRatioPercent;
@end
@interface PTReviewFact : NSObject
@property(nonatomic, readonly, copy) NSString *type;
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly, copy) NSString *subject;
@property(nonatomic, readonly, nullable) NSNumber *goalMinutes;
@property(nonatomic, readonly, nullable) NSNumber *actualSeconds;
@property(nonatomic, readonly, nullable) NSNumber *ratioPercent;
@property(nonatomic, readonly, nullable) NSNumber *currentSeconds;
@property(nonatomic, readonly, nullable) NSNumber *previousSeconds;
@property(nonatomic, readonly, nullable) NSNumber *currentSharePercent;
@property(nonatomic, readonly, nullable) NSNumber *deltaPoints;
@property(nonatomic, readonly, nullable) NSNumber *plannedMinutes;
@property(nonatomic, readonly, nullable) NSNumber *actualDisplayMinutes;
@property(nonatomic, readonly, nullable) NSNumber *shortfallDisplayMinutes;
@end
@interface PTWeeklyReview : NSObject
@property(nonatomic, readonly, copy) NSString *weekStart;
@property(nonatomic, readonly, copy) NSString *weekEnd;
@property(nonatomic, readonly, copy) NSString *logicalTodayIso;
@property(nonatomic, readonly, copy) NSString *periodState;
@property(nonatomic, readonly, copy) NSString *loadState;
@property(nonatomic, readonly, copy) NSString *errorMessage;
@property(nonatomic, readonly) BOOL hasData;
@property(nonatomic, readonly) BOOL hasDisplayContent;
@property(nonatomic, readonly, nullable) PTReviewGoal *goal;
@property(nonatomic, readonly, nullable) PTReviewTodayGoal *todayGoal;
@property(nonatomic, readonly, copy) NSArray<PTReviewSubject *> *subjects;
@property(nonatomic, readonly, nullable) PTReviewPlannedTasks *plannedTasks;
@property(nonatomic, readonly, copy) NSArray<PTReviewFact *> *facts;
@end
@interface PTFocusSummaryDay : NSObject
@property(nonatomic, readonly, copy) NSString *date;
@property(nonatomic, readonly) NSInteger seconds;
@property(nonatomic, readonly) NSInteger pomodoros;
@end
@interface PTFocusSummaryCategory : NSObject
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) NSInteger seconds;
@end
@interface PTFocusSummary : NSObject
@property(nonatomic, readonly) NSInteger seconds;
@property(nonatomic, readonly) NSInteger pomodoros;
@property(nonatomic, readonly, copy) NSArray<PTFocusSummaryDay *> *days;
@property(nonatomic, readonly, copy) NSArray<PTFocusSummaryCategory *> *categories;
@end
@interface PTStatisticsResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly) PTDayStatistics *day;
@property(nonatomic, readonly) PTMonthStatistics *month;
@property(nonatomic, readonly) PTStatisticsComparison *comparison;
@property(nonatomic, readonly, copy) NSArray<PTWeekDayStatistics *> *weekDays;
@property(nonatomic, readonly) PTCategoryStatistics *categoryStats;
@property(nonatomic, readonly) PTTaskStatistics *taskStats;
@property(nonatomic, readonly, copy) NSArray<PTMonthWeekStatistics *> *monthWeeks;
@property(nonatomic, readonly) PTWeeklyReview *review;
@property(nonatomic, readonly) PTFocusSummary *summary;
@property(nonatomic, readonly) NSInteger count;
@end
@interface PTMonthStatisticsInput : NSObject
@property(nonatomic) NSInteger totalDuration;
@property(nonatomic) NSInteger effectiveDays;
@property(nonatomic) NSInteger sessionCount;
@property(nonatomic) NSInteger completedTasks;
@property(nonatomic) NSInteger totalTasks;
@end
@interface PTStatisticsBridge : NSObject
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTStatisticsResult *)dayStats:(NSString *)iso NS_SWIFT_NAME(dayStats(date:));
- (PTStatisticsResult *)todayStats NS_SWIFT_NAME(todayStats());
- (PTStatisticsResult *)dayComparison:(NSString *)iso NS_SWIFT_NAME(dayComparison(date:));
- (PTStatisticsResult *)weekStats:(NSString *)iso NS_SWIFT_NAME(weekStats(startDate:));
- (PTStatisticsResult *)currentWeekStats NS_SWIFT_NAME(currentWeekStats());
- (PTStatisticsResult *)weekComparison:(NSString *)iso logicalToday:(NSString *)today NS_SWIFT_NAME(weekComparison(startDate:logicalToday:));
- (PTStatisticsResult *)categoryStats:(NSString *)from to:(NSString *)to NS_SWIFT_NAME(categoryStats(from:to:));
- (PTStatisticsResult *)dayTaskStats:(NSString *)iso NS_SWIFT_NAME(dayTaskStats(date:));
- (PTStatisticsResult *)todayTaskStats NS_SWIFT_NAME(todayTaskStats());
- (PTStatisticsResult *)monthStats:(NSInteger)year month:(NSInteger)month NS_SWIFT_NAME(monthStats(year:month:));
- (PTStatisticsResult *)currentMonthStats NS_SWIFT_NAME(currentMonthStats());
- (PTStatisticsResult *)monthComparison:(NSInteger)year month:(NSInteger)month NS_SWIFT_NAME(monthComparison(year:month:));
- (PTStatisticsResult *)monthComparison:(NSInteger)year month:(NSInteger)month current:(PTMonthStatisticsInput *)current NS_SWIFT_NAME(monthComparison(year:month:current:));
- (PTStatisticsResult *)effectiveDays:(NSString *)from to:(NSString *)to NS_SWIFT_NAME(effectiveDays(from:to:));
- (PTStatisticsResult *)focusSessionCount:(NSString *)from to:(NSString *)to NS_SWIFT_NAME(focusSessionCount(from:to:));
- (PTStatisticsResult *)validPomodoroCount:(NSString *)from to:(NSString *)to NS_SWIFT_NAME(validPomodoroCount(from:to:));
- (PTStatisticsResult *)streakDays NS_SWIFT_NAME(streakDays());
- (PTStatisticsResult *)totalFocusDuration NS_SWIFT_NAME(totalFocusDuration());
- (PTStatisticsResult *)monthWeeklySummary:(NSInteger)year month:(NSInteger)month NS_SWIFT_NAME(monthWeeklySummary(year:month:));
- (PTStatisticsResult *)currentMonthWeeklySummary NS_SWIFT_NAME(currentMonthWeeklySummary());
- (PTStatisticsResult *)weeklyReview:(NSString *)iso logicalToday:(NSString *)today NS_SWIFT_NAME(weeklyReview(startDate:logicalToday:));
- (PTStatisticsResult *)currentWeeklyReview NS_SWIFT_NAME(currentWeeklyReview());
- (PTStatisticsResult *)focusSummary:(NSString *)from to:(NSString *)to dayStartHour:(NSInteger)hour NS_SWIFT_NAME(focusSummary(from:to:dayStartHour:));
@end
NS_ASSUME_NONNULL_END
