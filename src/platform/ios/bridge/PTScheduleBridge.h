#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface PTScheduleEntry : NSObject
@property(nonatomic, readonly) NSInteger entryId;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *location;
@property(nonatomic, readonly) NSInteger weekday;
@property(nonatomic, readonly) NSInteger startMinutes;
@property(nonatomic, readonly) NSInteger endMinutes;
@property(nonatomic, readonly) NSInteger weekStart;
@property(nonatomic, readonly) NSInteger weekEnd;
@property(nonatomic, readonly) NSInteger weekParity;
@property(nonatomic, readonly) NSInteger categoryId;
@property(nonatomic, readonly) NSInteger durationMinutes;
@property(nonatomic, readonly, copy) NSString *categoryName;
@property(nonatomic, readonly, copy) NSString *categoryColor;
@end

@interface PTSchedulePeriod : NSObject
@property(nonatomic, readonly) NSInteger index;
@property(nonatomic, readonly) NSInteger startMinutes;
@property(nonatomic, readonly) NSInteger endMinutes;
- (instancetype)initWithStartMinutes:(NSInteger)start endMinutes:(NSInteger)end;
@end

// 每个 has 标记区分「未改」和明确清空；另一台设备的新值不被旧表单覆盖。
@interface PTScheduleChanges : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, readonly) BOOL hasTitle;
@property(nonatomic, copy) NSString *location;
@property(nonatomic, readonly) BOOL hasLocation;
@property(nonatomic) NSInteger weekday;
@property(nonatomic, readonly) BOOL hasWeekday;
@property(nonatomic) NSInteger startMinutes;
@property(nonatomic, readonly) BOOL hasStartMinutes;
@property(nonatomic) NSInteger endMinutes;
@property(nonatomic, readonly) BOOL hasEndMinutes;
@property(nonatomic) NSInteger weekStart;
@property(nonatomic, readonly) BOOL hasWeekStart;
@property(nonatomic) NSInteger weekEnd;
@property(nonatomic, readonly) BOOL hasWeekEnd;
@property(nonatomic) NSInteger weekParity;
@property(nonatomic, readonly) BOOL hasWeekParity;
@property(nonatomic) NSInteger categoryId;
@property(nonatomic, readonly) BOOL hasCategoryId;
@end

@interface PTScheduleResult : NSObject
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<PTScheduleEntry *> *entries;
@property(nonatomic, readonly, copy) NSArray<PTSchedulePeriod *> *periods;
@end

@interface PTScheduleSettings : NSObject
@property(nonatomic, readonly, copy) NSString *semesterStartDate;
@property(nonatomic, readonly) NSInteger semesterWeeks;
@property(nonatomic, readonly) BOOL showWeekend;
@end

@interface PTScheduleBridge : NSObject
@property(nonatomic, copy, nullable) void (^onScheduleChanged)(void);
@property(nonatomic, copy, nullable) void (^onPeriodsChanged)(void);
@property(nonatomic, copy, nullable) void (^onSemesterStartDateChanged)(void);
@property(nonatomic, copy, nullable) void (^onSemesterWeeksChanged)(void);
@property(nonatomic, copy, nullable) void (^onShowWeekendChanged)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
- (PTScheduleResult *)entries;
- (PTScheduleResult *)entriesForWeek:(NSInteger)week;
- (PTScheduleResult *)conflicts:(NSInteger)weekday startMinutes:(NSInteger)start endMinutes:(NSInteger)end
                     weekStart:(NSInteger)weekStart weekEnd:(NSInteger)weekEnd parity:(NSInteger)parity excluding:(NSInteger)entryId;
- (BOOL)addEntry:(NSString *)title weekday:(NSInteger)weekday startMinutes:(NSInteger)start endMinutes:(NSInteger)end
       location:(NSString *)location categoryId:(NSInteger)categoryId weekStart:(NSInteger)weekStart
        weekEnd:(NSInteger)weekEnd parity:(NSInteger)parity error:(NSError **)error;
- (BOOL)updateEntry:(NSInteger)entryId changes:(PTScheduleChanges *)changes error:(NSError **)error;
- (BOOL)deleteEntry:(NSInteger)entryId error:(NSError **)error;
- (PTScheduleResult *)periods;
- (BOOL)savePeriods:(NSArray<PTSchedulePeriod *> *)periods error:(NSError **)error;
- (nullable PTScheduleSettings *)settingsWithError:(NSError **)error NS_SWIFT_NAME(readSettings());
- (BOOL)saveSettings:(NSString *)semesterStartDate weeks:(NSInteger)weeks showWeekend:(BOOL)showWeekend error:(NSError **)error;
// 日期转换直接调用 P2B 的 C++ 包装；空串和零周次保留服务定义的无效结果。
- (NSString *)mondayOf:(NSString *)date;
- (NSString *)parseSemesterStart:(NSString *)start;
- (NSInteger)weekIndexForDate:(NSString *)start date:(NSString *)date;
- (NSString *)mondayOfWeek:(NSString *)start week:(NSInteger)week;
- (NSString *)dateOfWeekday:(NSString *)start week:(NSInteger)week weekday:(NSInteger)weekday;
- (BOOL)overlaps:(double)aStart end:(double)aEnd otherStart:(double)bStart otherEnd:(double)bEnd;
@property(nonatomic, readonly) NSInteger maxTitleLength;
@property(nonatomic, readonly) NSInteger maxLocationLength;
@property(nonatomic, readonly) NSInteger maxWeekIndex;
@property(nonatomic, readonly) NSInteger maxPeriodCount;
@end
NS_ASSUME_NONNULL_END
