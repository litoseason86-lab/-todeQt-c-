#include <QCoreApplication>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>
#include <QVariantList>
#include <QVariantMap>

#include "../src/services/DatabaseManager.h"
#include "../src/services/ScheduleService.h"

namespace {

// 课表项的默认参数集中在这里，单个测试只覆盖自己关心的那几个字段，
// 避免每次调用都写满 9 个实参、真正在测的差异被淹没。
struct EntryArgs {
    QString title = QStringLiteral("高等数学");
    int weekday = 1;
    int startMinutes = 8 * 60;
    int endMinutes = 9 * 60 + 40;
    QString location = QStringLiteral("A101");
    int categoryId = -1;
    int weekStart = 1;
    int weekEnd = 16;
    int weekParity = ScheduleService::EveryWeek;
};

bool addEntry(const EntryArgs& args)
{
    return ScheduleService::instance()->addEntry(
        args.title, args.weekday, args.startMinutes, args.endMinutes,
        args.location, args.categoryId, args.weekStart, args.weekEnd, args.weekParity);
}

QStringList titlesOf(const QVariantList& entries)
{
    QStringList titles;
    titles.reserve(entries.size());
    for (const QVariant& entry : entries) {
        titles.append(entry.toMap().value(QStringLiteral("title")).toString());
    }
    return titles;
}

int idOfFirst(const QVariantList& entries)
{
    return entries.isEmpty() ? -1 : entries.first().toMap().value(QStringLiteral("id")).toInt();
}

} // namespace

class ScheduleServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();

    void migrationCreatesTablesAndSeedsDefaultPeriods();
    void addEntryTrimsTextAndPersistsAllFields();
    void addEntryRejectsInvalidInput();
    void updateEntryRewritesFieldsAndRejectsMissingRow();
    void deleteEntryRemovesRowAndRejectsMissingRow();
    void weekRangeFiltersEntries();
    void weekParityFiltersEntries();
    void getEntriesForWeekRejectsNonPositiveWeekWithoutError();
    void findConflictsDetectsOverlapOnly();
    void findConflictsRespectsWeekRangeAndParity();
    void findConflictsExcludesEditedEntry();
    void setPeriodsSortsAndRenumbers();
    void setPeriodsRejectsInvalidInputAndKeepsOldTable();
    void deletingCategoryClearsEntryCategory();

private:
    void clearSchedule();

    QTemporaryDir* m_tempDir = nullptr;
    QString m_databasePath;
};

void ScheduleServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("ScheduleServiceTests"));
    m_databasePath = m_tempDir->filePath(QStringLiteral("schedule-test.sqlite"));
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
}

void ScheduleServiceTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void ScheduleServiceTests::init()
{
    clearSchedule();
}

void ScheduleServiceTests::clearSchedule()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DELETE FROM schedule_entries")));
    // 清掉自增序列，避免测试之间因为历史 id 互相影响。
    QVERIFY(query.exec(QStringLiteral(
        "DELETE FROM sqlite_sequence WHERE name = 'schedule_entries'")));
}

void ScheduleServiceTests::migrationCreatesTablesAndSeedsDefaultPeriods()
{
    QSqlQuery version(DatabaseManager::instance()->database());
    QVERIFY(version.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(version.next());
    QCOMPARE(version.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    // 迁移必须同时建好两张表并种入默认节次：只建空表会让「按节次」模式
    // 打开就是一张没有任何行的网格。
    const QVariantList periods = ScheduleService::instance()->getPeriods();
    QVERIFY(!periods.isEmpty());

    // 默认节次必须按时间顺序编号，且区间自身合法。
    int previousEnd = -1;
    for (int i = 0; i < periods.size(); ++i) {
        const QVariantMap period = periods.at(i).toMap();
        QCOMPARE(period.value(QStringLiteral("index")).toInt(), i + 1);
        const int start = period.value(QStringLiteral("startMinutes")).toInt();
        const int end = period.value(QStringLiteral("endMinutes")).toInt();
        QVERIFY(end > start);
        QVERIFY(start > previousEnd);
        previousEnd = end;
    }
}

void ScheduleServiceTests::addEntryTrimsTextAndPersistsAllFields()
{
    ScheduleService* service = ScheduleService::instance();
    QSignalSpy changedSpy(service, &ScheduleService::scheduleChanged);

    EntryArgs args;
    args.title = QStringLiteral("  高等数学  ");
    args.location = QStringLiteral("  A101  ");
    args.weekday = 3;
    args.startMinutes = 14 * 60;
    args.endMinutes = 15 * 60 + 40;
    args.weekStart = 2;
    args.weekEnd = 9;
    args.weekParity = ScheduleService::OddWeeks;
    QVERIFY(addEntry(args));
    QCOMPARE(changedSpy.count(), 1);

    const QVariantList entries = service->getEntries();
    QCOMPARE(entries.size(), 1);
    const QVariantMap entry = entries.first().toMap();
    QCOMPARE(entry.value(QStringLiteral("title")).toString(), QStringLiteral("高等数学"));
    QCOMPARE(entry.value(QStringLiteral("location")).toString(), QStringLiteral("A101"));
    QCOMPARE(entry.value(QStringLiteral("weekday")).toInt(), 3);
    QCOMPARE(entry.value(QStringLiteral("startMinutes")).toInt(), 14 * 60);
    QCOMPARE(entry.value(QStringLiteral("endMinutes")).toInt(), 15 * 60 + 40);
    // 时长由服务算好给 UI，网格靠它决定块高。
    QCOMPARE(entry.value(QStringLiteral("durationMinutes")).toInt(), 100);
    QCOMPARE(entry.value(QStringLiteral("weekStart")).toInt(), 2);
    QCOMPARE(entry.value(QStringLiteral("weekEnd")).toInt(), 9);
    QCOMPARE(entry.value(QStringLiteral("weekParity")).toInt(),
             static_cast<int>(ScheduleService::OddWeeks));
    // 未设科目时 categoryId 必须是无效值而不是 0，否则外键会指向一个不存在的科目。
    QVERIFY(!entry.value(QStringLiteral("categoryId")).isValid()
            || entry.value(QStringLiteral("categoryId")).isNull());
}

void ScheduleServiceTests::addEntryRejectsInvalidInput()
{
    ScheduleService* service = ScheduleService::instance();
    QSignalSpy failureSpy(service, &ScheduleService::operationFailed);

    EntryArgs blankTitle;
    blankTitle.title = QStringLiteral("   ");
    QVERIFY(!addEntry(blankTitle));

    EntryArgs longTitle;
    longTitle.title = QString(ScheduleService::kMaxTitleLength + 1, QChar(u'课'));
    QVERIFY(!addEntry(longTitle));

    EntryArgs badWeekday;
    badWeekday.weekday = 8;
    QVERIFY(!addEntry(badWeekday));

    EntryArgs badWeekdayLow;
    badWeekdayLow.weekday = 0;
    QVERIFY(!addEntry(badWeekdayLow));

    // 结束时间必须严格晚于开始时间：相等的零长条目在网格里高度为 0，画不出来。
    EntryArgs zeroLength;
    zeroLength.startMinutes = 9 * 60;
    zeroLength.endMinutes = 9 * 60;
    QVERIFY(!addEntry(zeroLength));

    EntryArgs reversed;
    reversed.startMinutes = 10 * 60;
    reversed.endMinutes = 9 * 60;
    QVERIFY(!addEntry(reversed));

    // 课表项不跨零点，超出一天分钟数的结束时间必须被拒。
    EntryArgs pastMidnight;
    pastMidnight.startMinutes = 23 * 60;
    pastMidnight.endMinutes = ScheduleService::kMinutesPerDay + 60;
    QVERIFY(!addEntry(pastMidnight));

    EntryArgs reversedWeeks;
    reversedWeeks.weekStart = 9;
    reversedWeeks.weekEnd = 2;
    QVERIFY(!addEntry(reversedWeeks));

    EntryArgs weekTooLarge;
    weekTooLarge.weekEnd = ScheduleService::kMaxWeekIndex + 1;
    QVERIFY(!addEntry(weekTooLarge));

    EntryArgs badParity;
    badParity.weekParity = 7;
    QVERIFY(!addEntry(badParity));

    // 每一次拒绝都必须给出可展示的原因，界面才有话可说。
    QCOMPARE(failureSpy.count(), 10);
    QVERIFY(ScheduleService::instance()->getEntries().isEmpty());
}

void ScheduleServiceTests::updateEntryRewritesFieldsAndRejectsMissingRow()
{
    ScheduleService* service = ScheduleService::instance();
    QVERIFY(addEntry(EntryArgs {}));
    const int id = idOfFirst(service->getEntries());
    QVERIFY(id > 0);

    QVERIFY(service->updateEntry(id, QStringLiteral("线性代数"), 5,
                                 10 * 60, 11 * 60 + 30,
                                 QStringLiteral("B203"), -1,
                                 3, 12, ScheduleService::EvenWeeks));

    const QVariantMap entry = service->getEntries().first().toMap();
    QCOMPARE(entry.value(QStringLiteral("title")).toString(), QStringLiteral("线性代数"));
    QCOMPARE(entry.value(QStringLiteral("weekday")).toInt(), 5);
    QCOMPARE(entry.value(QStringLiteral("startMinutes")).toInt(), 10 * 60);
    QCOMPARE(entry.value(QStringLiteral("location")).toString(), QStringLiteral("B203"));
    QCOMPARE(entry.value(QStringLiteral("weekParity")).toInt(),
             static_cast<int>(ScheduleService::EvenWeeks));

    // 改一条已经不存在的课程必须失败。语句本身会成功但影响 0 行，
    // 若据此返回 true，界面会显示「已保存」而实际什么都没写进去。
    QSignalSpy failureSpy(service, &ScheduleService::operationFailed);
    QVERIFY(!service->updateEntry(id + 999, QStringLiteral("不存在"), 1,
                                  8 * 60, 9 * 60, QString(), -1,
                                  1, 16, ScheduleService::EveryWeek));
    QCOMPARE(failureSpy.count(), 1);

    QVERIFY(!service->updateEntry(0, QStringLiteral("编号无效"), 1,
                                  8 * 60, 9 * 60, QString(), -1,
                                  1, 16, ScheduleService::EveryWeek));
}

void ScheduleServiceTests::deleteEntryRemovesRowAndRejectsMissingRow()
{
    ScheduleService* service = ScheduleService::instance();
    QVERIFY(addEntry(EntryArgs {}));
    const int id = idOfFirst(service->getEntries());

    QSignalSpy changedSpy(service, &ScheduleService::scheduleChanged);
    QVERIFY(service->deleteEntry(id));
    QCOMPARE(changedSpy.count(), 1);
    QVERIFY(service->getEntries().isEmpty());

    // 重复删除必须失败并给出原因，不能静默成功。
    QSignalSpy failureSpy(service, &ScheduleService::operationFailed);
    QVERIFY(!service->deleteEntry(id));
    QCOMPARE(failureSpy.count(), 1);
}

void ScheduleServiceTests::weekRangeFiltersEntries()
{
    ScheduleService* service = ScheduleService::instance();

    EntryArgs earlyHalf;
    earlyHalf.title = QStringLiteral("前八周");
    earlyHalf.weekStart = 1;
    earlyHalf.weekEnd = 8;
    QVERIFY(addEntry(earlyHalf));

    EntryArgs lateHalf;
    lateHalf.title = QStringLiteral("后八周");
    lateHalf.startMinutes = 10 * 60;
    lateHalf.endMinutes = 11 * 60;
    lateHalf.weekStart = 9;
    lateHalf.weekEnd = 16;
    QVERIFY(addEntry(lateHalf));

    QCOMPARE(titlesOf(service->getEntriesForWeek(1)), QStringList { QStringLiteral("前八周") });
    QCOMPARE(titlesOf(service->getEntriesForWeek(8)), QStringList { QStringLiteral("前八周") });
    // 边界必须是闭区间：第 9 周正是「后八周」的第一周。
    QCOMPARE(titlesOf(service->getEntriesForWeek(9)), QStringList { QStringLiteral("后八周") });
    QCOMPARE(titlesOf(service->getEntriesForWeek(16)), QStringList { QStringLiteral("后八周") });
    QVERIFY(service->getEntriesForWeek(17).isEmpty());
}

void ScheduleServiceTests::weekParityFiltersEntries()
{
    ScheduleService* service = ScheduleService::instance();

    EntryArgs everyWeek;
    everyWeek.title = QStringLiteral("每周");
    everyWeek.weekParity = ScheduleService::EveryWeek;
    QVERIFY(addEntry(everyWeek));

    EntryArgs oddOnly;
    oddOnly.title = QStringLiteral("单周");
    oddOnly.startMinutes = 10 * 60;
    oddOnly.endMinutes = 11 * 60;
    oddOnly.weekParity = ScheduleService::OddWeeks;
    QVERIFY(addEntry(oddOnly));

    EntryArgs evenOnly;
    evenOnly.title = QStringLiteral("双周");
    evenOnly.startMinutes = 13 * 60;
    evenOnly.endMinutes = 14 * 60;
    evenOnly.weekParity = ScheduleService::EvenWeeks;
    QVERIFY(addEntry(evenOnly));

    QCOMPARE(titlesOf(service->getEntriesForWeek(1)),
             (QStringList { QStringLiteral("每周"), QStringLiteral("单周") }));
    QCOMPARE(titlesOf(service->getEntriesForWeek(2)),
             (QStringList { QStringLiteral("每周"), QStringLiteral("双周") }));
    QCOMPARE(titlesOf(service->getEntriesForWeek(3)),
             (QStringList { QStringLiteral("每周"), QStringLiteral("单周") }));
}

void ScheduleServiceTests::getEntriesForWeekRejectsNonPositiveWeekWithoutError()
{
    ScheduleService* service = ScheduleService::instance();
    QVERIFY(addEntry(EntryArgs {}));

    // 用户往前翻到学期开始之前是正常操作，应该得到空课表而不是一条错误提示。
    QSignalSpy failureSpy(service, &ScheduleService::operationFailed);
    QVERIFY(service->getEntriesForWeek(0).isEmpty());
    QVERIFY(service->getEntriesForWeek(-3).isEmpty());
    QCOMPARE(failureSpy.count(), 0);
}

void ScheduleServiceTests::findConflictsDetectsOverlapOnly()
{
    ScheduleService* service = ScheduleService::instance();

    EntryArgs morning;              // 周一 08:00–09:40
    morning.title = QStringLiteral("已排课程");
    QVERIFY(addEntry(morning));

    // 真正相交才算冲突。
    QCOMPARE(service->findConflicts(1, 9 * 60, 10 * 60, 1, 16,
                                    ScheduleService::EveryWeek, -1).size(), 1);
    // 完全包住也算。
    QCOMPARE(service->findConflicts(1, 7 * 60, 12 * 60, 1, 16,
                                    ScheduleService::EveryWeek, -1).size(), 1);

    // 紧邻不算冲突：09:40 结束与 09:40 开始是连堂，不是撞车。
    QVERIFY(service->findConflicts(1, 9 * 60 + 40, 11 * 60, 1, 16,
                                   ScheduleService::EveryWeek, -1).isEmpty());
    QVERIFY(service->findConflicts(1, 7 * 60, 8 * 60, 1, 16,
                                   ScheduleService::EveryWeek, -1).isEmpty());
    // 不同星期不算冲突。
    QVERIFY(service->findConflicts(2, 8 * 60, 9 * 60 + 40, 1, 16,
                                   ScheduleService::EveryWeek, -1).isEmpty());
}

void ScheduleServiceTests::findConflictsRespectsWeekRangeAndParity()
{
    ScheduleService* service = ScheduleService::instance();

    EntryArgs oddEarly;             // 周一 08:00–09:40，第 1–8 周，仅单周
    oddEarly.weekStart = 1;
    oddEarly.weekEnd = 8;
    oddEarly.weekParity = ScheduleService::OddWeeks;
    QVERIFY(addEntry(oddEarly));

    // 周次区间不相交 → 永远不会在同一周出现，不算冲突。
    QVERIFY(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 9, 16,
                                   ScheduleService::OddWeeks, -1).isEmpty());

    // 周次相交但一个只在单周、另一个只在双周 → 同样永不相遇。
    QVERIFY(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 1, 8,
                                   ScheduleService::EvenWeeks, -1).isEmpty());

    // 周次相交且奇偶可能同时出现 → 冲突。
    QCOMPARE(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 1, 8,
                                    ScheduleService::OddWeeks, -1).size(), 1);
    // 「每周」与任何单双周都可能撞上。
    QCOMPARE(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 4, 20,
                                    ScheduleService::EveryWeek, -1).size(), 1);
}

void ScheduleServiceTests::findConflictsExcludesEditedEntry()
{
    ScheduleService* service = ScheduleService::instance();
    QVERIFY(addEntry(EntryArgs {}));
    const int id = idOfFirst(service->getEntries());

    // 编辑一条课程时，它必须不与自己冲突，否则每次保存都会弹一条假警告。
    QVERIFY(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 1, 16,
                                   ScheduleService::EveryWeek, id).isEmpty());
    QCOMPARE(service->findConflicts(1, 8 * 60, 9 * 60 + 40, 1, 16,
                                    ScheduleService::EveryWeek, -1).size(), 1);
}

void ScheduleServiceTests::setPeriodsSortsAndRenumbers()
{
    ScheduleService* service = ScheduleService::instance();
    QSignalSpy periodsSpy(service, &ScheduleService::periodsChanged);

    // 故意乱序传入：服务必须按开始时间排序后重新编号，
    // 否则「第 3 节」可能比「第 2 节」还早，网格行序与用户认知对不上。
    QVariantList input;
    const auto makePeriod = [](int start, int end) {
        QVariantMap period;
        period.insert(QStringLiteral("startMinutes"), start);
        period.insert(QStringLiteral("endMinutes"), end);
        return QVariant(period);
    };
    input.append(makePeriod(14 * 60, 14 * 60 + 45));
    input.append(makePeriod(8 * 60, 8 * 60 + 45));
    input.append(makePeriod(10 * 60, 10 * 60 + 45));

    QVERIFY(service->setPeriods(input));
    QCOMPARE(periodsSpy.count(), 1);

    const QVariantList periods = service->getPeriods();
    QCOMPARE(periods.size(), 3);
    QCOMPARE(periods.at(0).toMap().value(QStringLiteral("index")).toInt(), 1);
    QCOMPARE(periods.at(0).toMap().value(QStringLiteral("startMinutes")).toInt(), 8 * 60);
    QCOMPARE(periods.at(1).toMap().value(QStringLiteral("index")).toInt(), 2);
    QCOMPARE(periods.at(1).toMap().value(QStringLiteral("startMinutes")).toInt(), 10 * 60);
    QCOMPARE(periods.at(2).toMap().value(QStringLiteral("index")).toInt(), 3);
    QCOMPARE(periods.at(2).toMap().value(QStringLiteral("startMinutes")).toInt(), 14 * 60);
}

void ScheduleServiceTests::setPeriodsRejectsInvalidInputAndKeepsOldTable()
{
    ScheduleService* service = ScheduleService::instance();

    QVariantList valid;
    QVariantMap first;
    first.insert(QStringLiteral("startMinutes"), 8 * 60);
    first.insert(QStringLiteral("endMinutes"), 8 * 60 + 45);
    valid.append(first);
    QVERIFY(service->setPeriods(valid));
    QCOMPARE(service->getPeriods().size(), 1);

    QSignalSpy failureSpy(service, &ScheduleService::operationFailed);

    // 清空会让「按节次」模式变成一张空网格，与功能损坏无异。
    QVERIFY(!service->setPeriods(QVariantList {}));

    // 非法区间必须在写库之前就被拒，不能删掉旧表后才发现。
    QVariantList invalid;
    QVariantMap good;
    good.insert(QStringLiteral("startMinutes"), 9 * 60);
    good.insert(QStringLiteral("endMinutes"), 9 * 60 + 45);
    QVariantMap bad;
    bad.insert(QStringLiteral("startMinutes"), 11 * 60);
    bad.insert(QStringLiteral("endMinutes"), 10 * 60);
    invalid.append(good);
    invalid.append(bad);
    QVERIFY(!service->setPeriods(invalid));

    QCOMPARE(failureSpy.count(), 2);
    // 失败后旧节次表必须原样保留，不能留下半张表。
    const QVariantList periods = service->getPeriods();
    QCOMPARE(periods.size(), 1);
    QCOMPARE(periods.first().toMap().value(QStringLiteral("startMinutes")).toInt(), 8 * 60);
}

void ScheduleServiceTests::deletingCategoryClearsEntryCategory()
{
    ScheduleService* service = ScheduleService::instance();
    QSqlDatabase db = DatabaseManager::instance()->database();

    QSqlQuery insertCategory(db);
    QVERIFY(insertCategory.exec(QStringLiteral(
        "INSERT INTO categories (name, color) VALUES ('课表测试科目', '#ff8844')")));
    const int categoryId = insertCategory.lastInsertId().toInt();
    QVERIFY(categoryId > 0);

    EntryArgs args;
    args.categoryId = categoryId;
    QVERIFY(addEntry(args));

    const QVariantMap withCategory = service->getEntries().first().toMap();
    QCOMPARE(withCategory.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(withCategory.value(QStringLiteral("categoryName")).toString(),
             QStringLiteral("课表测试科目"));

    // 外键是 ON DELETE SET NULL：删掉科目只解除归属，课表项本身必须留下。
    // 外键约束在部分连接上默认关闭，这里显式打开再删，验证的是表定义而不是连接设置。
    QSqlQuery pragma(db);
    QVERIFY(pragma.exec(QStringLiteral("PRAGMA foreign_keys = ON")));
    QSqlQuery deleteCategory(db);
    deleteCategory.prepare(QStringLiteral("DELETE FROM categories WHERE id = :id"));
    deleteCategory.bindValue(QStringLiteral(":id"), categoryId);
    QVERIFY(deleteCategory.exec());

    const QVariantList remaining = service->getEntries();
    QCOMPARE(remaining.size(), 1);
    const QVariantMap cleared = remaining.first().toMap();
    QVERIFY(!cleared.value(QStringLiteral("categoryId")).isValid()
            || cleared.value(QStringLiteral("categoryId")).isNull());
    QCOMPARE(cleared.value(QStringLiteral("title")).toString(), QStringLiteral("高等数学"));
}

QTEST_MAIN(ScheduleServiceTests)
#include "ScheduleServiceTests.moc"
