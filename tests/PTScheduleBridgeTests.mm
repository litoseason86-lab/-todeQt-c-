#import "../src/platform/ios/bridge/PTScheduleBridge.h"
#include "../src/platform/ios/bridge/PTBridgeSupport.h"
#include "../src/services/AppSettings.h"
#include "../src/services/ScheduleService.h"
#include "../src/services/DatabaseManager.h"
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QTemporaryDir>
#include <QThread>
#include <QtTest>
#include <memory>

@interface PTScheduleBridge (TestInjection)
- (instancetype)initWithSettings:(AppSettings *)settings;
@end

class PTScheduleBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase();
    void init();
    void cleanup();
    void entriesPreserveFieldsAndPartialChanges();
    void readsFilterWeeksAndConflicts();
    void periodWritesAreSortedAndRejectInvalidInput();
    void failuresPreserveReasonsAndRejectOverflow();
    void settingsAreAtomicAndFailuresRollBack();
    void signalsReturnToMainThreadAndDisconnect();
    void releasedSettingsFailSafely();
    void weekConversionsMatchCalibers();
private:
    QTemporaryDir m_preferences;
    QTemporaryDir m_database;
};

// 产品保证：课表测试不触碰真实偏好，多个 worktree 并行也不会互改课表设置。
void PTScheduleBridgeTests::initTestCase() {
    QVERIFY(m_preferences.isValid());
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
    QCoreApplication::setApplicationName(QStringLiteral("PTScheduleBridgeTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
}
// 产品保证：各场景从独立数据库开始，删除和冲突结果不继承上条用例。
void PTScheduleBridgeTests::init() {
    QVERIFY(m_database.isValid());
    QFile::remove(m_database.filePath(QStringLiteral("schedule.sqlite")));
    QVERIFY(DatabaseManager::instance()->initialize(m_database.filePath(QStringLiteral("schedule.sqlite"))));
}
// 产品保证：读取失败场景也会关库和清理隔离偏好，不污染下一条用例。
void PTScheduleBridgeTests::cleanup() {
    DatabaseManager::instance()->close();
    QSettings().clear(); AppSettings::instance()->reload();
}

// 产品保证：课程字段完整投影，字段级编辑保留未改值，明确清空与未编辑分开处理。
void PTScheduleBridgeTests::entriesPreserveFieldsAndPartialChanges() {
    @autoreleasepool {
        PTScheduleBridge *bridge = [PTScheduleBridge new]; NSError *error = nil;
        QVERIFY([bridge addEntry:@"量子物理🍅" weekday:3 startMinutes:481 endMinutes:573
                        location:@"教室甲" categoryId:1 weekStart:2 weekEnd:16 parity:2 error:&error]);
        QVERIFY(error == nil);
        PTScheduleResult *result = bridge.entries;
        QVERIFY(result.valid); QCOMPARE(result.entries.count, NSUInteger(1));
        PTScheduleEntry *entry = result.entries.firstObject;
        const auto map = ScheduleService::instance()->getEntries().first().toMap();
        QCOMPARE(entry.entryId, NSInteger(map.value("id").toInt()));
        QCOMPARE(PTBridgeSupport::string(entry.title), map.value("title").toString());
        QCOMPARE(PTBridgeSupport::string(entry.location), map.value("location").toString());
        QCOMPARE(entry.weekday, NSInteger(3));
        QCOMPARE(entry.startMinutes, NSInteger(481)); QCOMPARE(entry.endMinutes, NSInteger(573));
        QCOMPARE(entry.durationMinutes, NSInteger(92));
        QCOMPARE(entry.weekStart, NSInteger(2)); QCOMPARE(entry.weekEnd, NSInteger(16)); QCOMPARE(entry.weekParity, NSInteger(2));
        QCOMPARE(entry.categoryId, NSInteger(map.value("categoryId").toInt()));
        QCOMPARE(PTBridgeSupport::string(entry.categoryName), map.value("categoryName").toString());
        QCOMPARE(PTBridgeSupport::string(entry.categoryColor), map.value("categoryColor").toString());
        // 模拟表单打开后另一台设备更新地点，标题编辑不能回写旧地点。
        QVERIFY(ScheduleService::instance()->updateEntryChanges(int(entry.entryId), {{QStringLiteral("location"), QStringLiteral("远端教室")}}));
        PTScheduleChanges *changes = [PTScheduleChanges new]; changes.title = @"新标题";
        QVERIFY(changes.hasTitle && !changes.hasLocation && !changes.hasStartMinutes && !changes.hasCategoryId);
        QVERIFY([bridge updateEntry:entry.entryId changes:changes error:&error]);
        PTScheduleEntry *updated = bridge.entries.entries.firstObject;
        QVERIFY([updated.title isEqualToString:@"新标题"]); QVERIFY([updated.location isEqualToString:@"远端教室"]);
        QCOMPARE(updated.startMinutes, entry.startMinutes); QCOMPARE(updated.weekParity, entry.weekParity);
        changes = [PTScheduleChanges new]; changes.location = @""; changes.categoryId = -1;
        QVERIFY(changes.hasLocation && changes.hasCategoryId && !changes.hasTitle);
        QVERIFY([bridge updateEntry:entry.entryId changes:changes error:&error]);
        updated = bridge.entries.entries.firstObject;
        QCOMPARE(updated.categoryId, NSInteger(-1)); QVERIFY([updated.location isEqualToString:@""]);
        QVERIFY([updated.title isEqualToString:@"新标题"]);
        changes = [PTScheduleChanges new]; changes.weekday = 5; changes.startMinutes = 600; changes.endMinutes = 630;
        changes.weekStart = 1; changes.weekEnd = 13; changes.weekParity = 1; changes.categoryId = 2;
        QVERIFY(changes.hasWeekday && changes.hasStartMinutes && changes.hasEndMinutes
                && changes.hasWeekStart && changes.hasWeekEnd && changes.hasWeekParity);
        QVERIFY([bridge updateEntry:entry.entryId changes:changes error:&error]);
        updated = bridge.entries.entries.firstObject;
        QCOMPARE(updated.weekday, NSInteger(5)); QCOMPARE(updated.startMinutes, NSInteger(600));
        QCOMPARE(updated.endMinutes, NSInteger(630)); QCOMPARE(updated.durationMinutes, NSInteger(30));
        QCOMPARE(updated.weekStart, NSInteger(1)); QCOMPARE(updated.weekEnd, NSInteger(13));
        QCOMPARE(updated.weekParity, NSInteger(1)); QCOMPARE(updated.categoryId, NSInteger(2));
        QVERIFY([bridge deleteEntry:entry.entryId error:&error]); QCOMPARE(bridge.entries.entries.count, NSUInteger(0));
    }
}

// 产品保证：翻周筛选和冲突查询沿用服务规则，同名课程按编号排除而不互相误认。
void PTScheduleBridgeTests::readsFilterWeeksAndConflicts() {
    @autoreleasepool {
        PTScheduleBridge *bridge = [PTScheduleBridge new]; NSError *error = nil;
        QVERIFY(bridge.entries.valid); QCOMPARE(bridge.entries.entries.count, NSUInteger(0));
        QVERIFY([bridge addEntry:@"同名" weekday:1 startMinutes:540 endMinutes:600 location:@"乙" categoryId:-1 weekStart:1 weekEnd:20 parity:2 error:&error]);
        QVERIFY([bridge addEntry:@"同名" weekday:1 startMinutes:510 endMinutes:560 location:@"甲" categoryId:-1 weekStart:1 weekEnd:20 parity:1 error:&error]);
        PTScheduleResult *odd = [bridge entriesForWeek:3], *even = [bridge entriesForWeek:4];
        QVERIFY(odd.valid && even.valid); QCOMPARE(odd.entries.count, NSUInteger(1)); QCOMPARE(even.entries.count, NSUInteger(1));
        QVERIFY([odd.entries.firstObject.location isEqualToString:@"甲"]);
        QVERIFY([even.entries.firstObject.location isEqualToString:@"乙"]);
        const NSInteger oddID = odd.entries.firstObject.entryId;
        PTScheduleResult *conflicts = [bridge conflicts:1 startMinutes:550 endMinutes:590 weekStart:1 weekEnd:20 parity:1 excluding:-1];
        QVERIFY(conflicts.valid); QCOMPARE(conflicts.entries.count, NSUInteger(1)); QCOMPARE(conflicts.entries.firstObject.entryId, oddID);
        conflicts = [bridge conflicts:1 startMinutes:550 endMinutes:590 weekStart:1 weekEnd:20 parity:1 excluding:oddID];
        QVERIFY(conflicts.valid); QCOMPARE(conflicts.entries.count, NSUInteger(0));
        conflicts = [bridge conflicts:1 startMinutes:560 endMinutes:580 weekStart:1 weekEnd:20 parity:1 excluding:-1];
        QCOMPARE(conflicts.entries.count, NSUInteger(0));
        // 插入顺序不同于时间排序，保证读取不是偶然依赖插入顺序。
        const auto entries = bridge.entries.entries;
        QCOMPARE(entries.firstObject.entryId, oddID); QVERIFY(entries.firstObject.entryId != entries.lastObject.entryId);
    }
}

// 产品保证：节次排序、编号和失败后的旧表保留都由服务提供，桥接不保留用户输入顺序。
void PTScheduleBridgeTests::periodWritesAreSortedAndRejectInvalidInput() {
    @autoreleasepool {
        PTScheduleBridge *bridge = [PTScheduleBridge new]; NSError *error = nil;
        PTSchedulePeriod *late = [[PTSchedulePeriod alloc] initWithStartMinutes:600 endMinutes:645];
        PTSchedulePeriod *early = [[PTSchedulePeriod alloc] initWithStartMinutes:480 endMinutes:525];
        QVERIFY(([bridge savePeriods:@[late, early] error:&error]));
        const auto periods = bridge.periods; QVERIFY(periods.valid); QCOMPARE(periods.periods.count, NSUInteger(2));
        QCOMPARE(periods.periods.firstObject.index, NSInteger(1)); QCOMPARE(periods.periods.firstObject.startMinutes, NSInteger(480));
        QCOMPARE(periods.periods.lastObject.index, NSInteger(2)); QCOMPARE(periods.periods.lastObject.endMinutes, NSInteger(645));
        early = [[PTSchedulePeriod alloc] initWithStartMinutes:480 endMinutes:620];
        QVERIFY(([bridge savePeriods:@[late, early] error:&error] == NO)); QVERIFY(error != nil);
        QCOMPARE(bridge.periods.periods.firstObject.endMinutes, NSInteger(525));
        QVERIFY(![bridge savePeriods:@[] error:&error]);
        early = [[PTSchedulePeriod alloc] initWithStartMinutes:NSIntegerMax endMinutes:620]; error = nil;
        QVERIFY(([bridge savePeriods:@[early] error:&error] == NO)); QVERIFY(error != nil);
        QCOMPARE(bridge.maxTitleLength, NSInteger(ScheduleService::kMaxTitleLength));
        QCOMPARE(bridge.maxLocationLength, NSInteger(ScheduleService::kMaxLocationLength));
        QCOMPARE(bridge.maxWeekIndex, NSInteger(ScheduleService::kMaxWeekIndex));
        QCOMPARE(bridge.maxPeriodCount, NSInteger(ScheduleService::kMaxPeriodCount));
    }
}

// 产品保证：失败保留服务原文且只报告一次，空课表与读取失败分开，宽整数不能截断成有效编号。
void PTScheduleBridgeTests::failuresPreserveReasonsAndRejectOverflow() {
    @autoreleasepool {
        PTScheduleBridge *bridge = [PTScheduleBridge new]; __block int background = 0;
        bridge.onFailure = ^(NSString *) { ++background; };
        QSignalSpy spy(ScheduleService::instance(), &ScheduleService::operationFailed);
        NSError *error = nil;
        QVERIFY(![bridge addEntry:@"" weekday:1 startMinutes:480 endMinutes:525 location:@"" categoryId:-1 weekStart:1 weekEnd:20 parity:0 error:&error]);
        QCOMPARE(spy.count(), 1); QVERIFY(error != nil);
        QCOMPARE(PTBridgeSupport::string(error.localizedDescription), spy.last().first().toString()); QCOMPARE(background, 0);
        DatabaseManager::instance()->close();
        PTScheduleResult *result = bridge.entries;
        QVERIFY(!result.valid); QVERIFY(result.error.length > 0); QCOMPARE(result.entries.count, NSUInteger(0));
        QCOMPARE(PTBridgeSupport::string(result.error), spy.last().first().toString());
        QVERIFY(![bridge entriesForWeek:2].valid); QVERIFY(!bridge.periods.valid); QCOMPARE(background, 0);
        emit ScheduleService::instance()->operationFailed(QStringLiteral("背景课表失败")); QCOMPARE(background, 1);
        error = nil; QVERIFY(![bridge deleteEntry:NSIntegerMax error:&error]); QVERIFY(error != nil);
        QVERIFY(![bridge entriesForWeek:NSIntegerMax].valid);
        PTScheduleChanges *changes = [PTScheduleChanges new]; changes.weekday = NSIntegerMax;
        error = nil; QVERIFY(![bridge updateEntry:1 changes:changes error:&error]); QVERIFY(error != nil);
        QVERIFY(![bridge conflicts:NSIntegerMax startMinutes:0 endMinutes:1 weekStart:1 weekEnd:2 parity:0 excluding:-1].valid);
    }
}

// 产品保证：三项设置一次提交，所有变化回调只看完整新状态；写盘失败保留旧状态并显示服务原因。
void PTScheduleBridgeTests::settingsAreAtomicAndFailuresRollBack() {
    @autoreleasepool {
        QTemporaryDir dir; QVERIFY(dir.isValid()); AppSettings settings(dir.filePath("settings.ini"));
        PTScheduleBridge *bridge = [[PTScheduleBridge alloc] initWithSettings:&settings]; NSError *error = nil;
        const QString start = settings.semesterStartDate();
        const int weeks = settings.semesterWeeks(); const bool weekend = settings.scheduleShowWeekend();
        QVERIFY(start != QStringLiteral("2026-08-31")); QVERIFY(weeks != 17);
        __block int changes = 0; __block BOOL coherent = YES; __block int background = 0;
        auto *settingsPtr = &settings;
        void (^changed)(void) = ^{
            ++changes;
            coherent = coherent && settingsPtr->semesterStartDate() == QStringLiteral("2026-08-31")
                && settingsPtr->semesterWeeks() == 17 && settingsPtr->scheduleShowWeekend() == !weekend;
        };
        bridge.onSemesterStartDateChanged = changed; bridge.onSemesterWeeksChanged = changed; bridge.onShowWeekendChanged = changed;
        bridge.onFailure = ^(NSString *) { ++background; };
        QVERIFY([bridge saveSettings:@"2026-09-02" weeks:17 showWeekend:!weekend error:&error]);
        QCOMPARE(changes, 3); QVERIFY(coherent); QVERIFY(error == nil);
        PTScheduleSettings *value = [bridge settingsWithError:&error]; QVERIFY(value != nil);
        QVERIFY([value.semesterStartDate isEqualToString:@"2026-08-31"]); QCOMPARE(value.semesterWeeks, NSInteger(17)); QCOMPARE(bool(value.showWeekend), !weekend);
        QSignalSpy spy(&settings, &AppSettings::settingsWriteFailed);
        QVERIFY(![bridge saveSettings:@"2026-02-31" weeks:9 showWeekend:weekend error:&error]);
        QCOMPARE(changes, 3); QCOMPARE(background, 0); QCOMPARE(PTBridgeSupport::string(error.localizedDescription), spy.last().at(1).toString());
        QCOMPARE([bridge settingsWithError:&error].semesterWeeks, NSInteger(17));
        QVERIFY(![bridge saveSettings:@"2026-09-07" weeks:NSIntegerMax showWeekend:weekend error:&error]);
        // 父路径是一份普通文件，稳定触发 AccessError；不依赖当前进程权限或真实偏好。
        const QString blocker = dir.filePath("blocked"); QFile file(blocker); QVERIFY(file.open(QIODevice::WriteOnly)); file.close();
        AppSettings blocked(blocker + QStringLiteral("/settings.ini"));
        PTScheduleBridge *bad = [[PTScheduleBridge alloc] initWithSettings:&blocked];
        const auto old = [bad settingsWithError:&error]; __block int badChanges = 0; __block int badBackground = 0;
        bad.onSemesterStartDateChanged = ^{ ++badChanges; }; bad.onSemesterWeeksChanged = ^{ ++badChanges; }; bad.onShowWeekendChanged = ^{ ++badChanges; };
        bad.onFailure = ^(NSString *) { ++badBackground; }; QSignalSpy failed(&blocked, &AppSettings::settingsWriteFailed);
        error = nil; QVERIFY(![bad saveSettings:@"2026-08-31" weeks:13 showWeekend:!old.showWeekend error:&error]);
        QVERIFY(error != nil); QCOMPARE(PTBridgeSupport::string(error.localizedDescription), failed.last().at(1).toString());
        const auto after = [bad settingsWithError:&error]; QCOMPARE(after.semesterWeeks, old.semesterWeeks);
        QVERIFY([after.semesterStartDate isEqualToString:old.semesterStartDate]); QCOMPARE(after.showWeekend, old.showWeekend);
        QCOMPARE(badChanges, 0); QCOMPARE(badBackground, 0);
        emit blocked.settingsWriteFailed(QStringLiteral("schedule"), QStringLiteral("后台课表设置失败")); QCOMPARE(badBackground, 1);
        emit blocked.settingsWriteFailed(QStringLiteral("focus/workMinutes"), QStringLiteral("其它页面失败")); QCOMPARE(badBackground, 1);
    }
}

// 产品保证：所有课表及设置信号回主线程，释放桥接后排队信号不再回调。
void PTScheduleBridgeTests::signalsReturnToMainThreadAndDisconnect() {
    @autoreleasepool {
        PTScheduleBridge *bridge = [PTScheduleBridge new]; __weak PTScheduleBridge *weakBridge = bridge;
        __block int count = 0; __block BOOL onMain = YES;
        void (^changed)(void) = ^{ ++count; onMain = onMain && NSThread.isMainThread; };
        bridge.onScheduleChanged = changed; bridge.onPeriodsChanged = changed; bridge.onSemesterStartDateChanged = changed;
        bridge.onSemesterWeeksChanged = changed; bridge.onShowWeekendChanged = changed;
        bridge.onFailure = ^(NSString *) { ++count; onMain = onMain && NSThread.isMainThread; };
        auto *service = ScheduleService::instance(); auto *settings = AppSettings::instance();
        const auto send = [=] {
            emit service->scheduleChanged(); emit service->periodsChanged(); emit service->operationFailed(QStringLiteral("后台失败"));
            emit settings->semesterStartDateChanged(); emit settings->semesterWeeksChanged(); emit settings->scheduleShowWeekendChanged();
            emit settings->settingsWriteFailed(QStringLiteral("schedule"), QStringLiteral("后台设置失败"));
        };
        std::unique_ptr<QThread> worker(QThread::create(send)); worker->start(); QVERIFY(worker->wait(3000));
        QCOMPARE(count, 0); QTRY_COMPARE(count, 7); QVERIFY(onMain);
        worker.reset(QThread::create(send)); worker->start(); QVERIFY(worker->wait(3000));
        bridge = nil; QVERIFY(weakBridge == nil); QCoreApplication::processEvents(); QCOMPARE(count, 7);
        send(); QCoreApplication::processEvents(); QCOMPARE(count, 7);
    }
}

// 产品保证：注入设置已释放后读取与写入都报错，不解引用悬空服务。
void PTScheduleBridgeTests::releasedSettingsFailSafely() {
    @autoreleasepool {
        QTemporaryDir dir; QVERIFY(dir.isValid());
        auto settings = std::make_unique<AppSettings>(dir.filePath("settings.ini"));
        PTScheduleBridge *bridge = [[PTScheduleBridge alloc] initWithSettings:settings.get()];
        settings.reset(); NSError *error = nil;
        QVERIFY([bridge settingsWithError:&error] == nil); QVERIFY(error != nil);
        error = nil; QVERIFY(![bridge saveSettings:@"" weeks:20 showWeekend:YES error:&error]); QVERIFY(error != nil);
    }
}

// 产品保证：周次转换逐行匹配 P2B 对照表，跨年、闰日和相邻区间均不在桥接另算一遍。
void PTScheduleBridgeTests::weekConversionsMatchCalibers() {
    @autoreleasepool {
        QFile file(QStringLiteral(PT_CALIBERS_DIR "/schedule-weeks.json")); QVERIFY(file.open(QIODevice::ReadOnly));
        const auto rows = QJsonDocument::fromJson(file.readAll()).array(); QVERIFY(!rows.isEmpty());
        PTScheduleBridge *bridge = [PTScheduleBridge new];
        for (const auto &row : rows) {
            const auto object = row.toObject(); const auto input = object.value("input").toObject();
            const auto expected = object.value("expected"); const auto op = input.value("op").toString();
            const auto start = PTBridgeSupport::string(input.value("start").toString());
            const auto date = PTBridgeSupport::string(input.value("date").toString());
            NSString *actual = nil;
            if (op == "mondayOf") actual = [bridge mondayOf:date];
            else if (op == "parseSemesterStart") actual = [bridge parseSemesterStart:start];
            else if (op == "weekIndexForDate") { QCOMPARE([bridge weekIndexForDate:start date:date], NSInteger(expected.toInt())); continue; }
            else if (op == "mondayOfWeek") actual = [bridge mondayOfWeek:start week:input.value("week").toInt()];
            else if (op == "dateOfWeekday") actual = [bridge dateOfWeekday:start week:input.value("week").toInt() weekday:input.value("weekday").toInt()];
            else if (op == "overlaps") {
                QCOMPARE(bool([bridge overlaps:input.value("aStart").toDouble() end:input.value("aEnd").toDouble()
                                    otherStart:input.value("bStart").toDouble() otherEnd:input.value("bEnd").toDouble()]), expected.toBool()); continue;
            } else QFAIL("未知周次对照操作");
            QCOMPARE(PTBridgeSupport::string(actual), expected.isNull() ? QStringLiteral("") : expected.toString());
        }
        QVERIFY([[bridge mondayOfWeek:@"2026-09-02" week:NSIntegerMax] isEqualToString:@""]);
        QVERIFY([[bridge dateOfWeekday:@"2026-09-02" week:1 weekday:NSIntegerMax] isEqualToString:@""]);
    }
}
QTEST_GUILESS_MAIN(PTScheduleBridgeTests)
#include "PTScheduleBridgeTests.moc"
