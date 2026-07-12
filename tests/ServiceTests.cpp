#include <QCoreApplication>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTimer>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/LogicalDayService.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/ExportService.h"
#include "../src/services/FocusHistoryService.h"
#define private public
#include "../src/services/FocusTimer.h"
#undef private
#include "../src/services/RoutineManager.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/TaskManager.h"

namespace {
constexpr int kTestMinimumValidDurationSeconds = 3 * 60;

QString dateTimeText(const QDate& date, const QString& time = QStringLiteral("12:00:00"))
{
    return QStringLiteral("%1T%2").arg(date.toString(Qt::ISODate), time);
}

int insertTaskRow(const QString& title,
                  const QDate& date,
                  const QString& category = QString(),
                  bool completed = false,
                  const QString& createdAt = QString())
{
    // 测试直接插入数据库，绕开服务层校验，方便构造边界数据。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, date, completed, created_at) "
        "VALUES (:title, :category, :date, :completed, :createdAt)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), category);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":createdAt"),
                    createdAt.isEmpty() ? dateTimeText(date) : createdAt);

    if (!query.exec()) {
        qWarning() << "Failed to insert test task:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

bool insertFocusSessionRow(int taskId, const QDate& date, int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, QStringLiteral("12:30:00")));
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert test focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertFocusSessionRowAt(int taskId,
                             const QDate& date,
                             const QString& startTime,
                             const QString& endTime,
                             int duration)
{
    // 起止时刻可控，用于构造日界点前后的固定 session，避免测试依赖真实时钟。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date, startTime));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, endTime));
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert boundary focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertFocusSessionWithNullDuration(int taskId, const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, NULL)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, QStringLiteral("12:30:00")));

    if (!query.exec()) {
        qWarning() << "Failed to insert test focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertUnfinishedFocusSessionRow(int taskId, const QDate& date, int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, NULL, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert unfinished focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

int countFocusSessions()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")) || !query.next()) {
        qWarning() << "Failed to count focus sessions:" << query.lastError().text();
        return -1;
    }

    return query.value(0).toInt();
}

bool taskCompletedById(int taskId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT completed FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to read test task completion:" << query.lastError().text()
                   << "taskId=" << taskId;
        return false;
    }

    return query.value(0).toBool();
}

int insertTaskRowWithCategoryId(const QString& title,
                                const QDate& date,
                                int categoryId,
                                const QString& legacyCategory,
                                bool completed,
                                const QString& createdAt)
{
    // 同时写 category_id 和旧版 category 文本，用来覆盖新旧数据混合场景。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, date, completed, created_at) "
        "VALUES (:title, :category, :categoryId, :date, :completed, :createdAt)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), legacyCategory);
    query.bindValue(QStringLiteral(":categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":createdAt"), createdAt);

    if (!query.exec()) {
        qWarning() << "Failed to insert category-aware test task:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

int insertFocusSessionRowWithTimes(int taskId,
                                   const QString& startTime,
                                   const QString& endTime,
                                   int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), startTime);
    query.bindValue(QStringLiteral(":endTime"), endTime);
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert timed focus session:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

QString readUtf8File(const QString& filePath)
{
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}

bool createLegacyVersion1Database(const QString& path)
{
    // 构造旧版本数据库，验证真实用户升级时的迁移路径。
    const QString connectionName = QStringLiteral("LegacyMigrationSetupConnection");
    {
        QSqlDatabase legacyDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        legacyDb.setDatabaseName(path);
        if (!legacyDb.open()) {
            qWarning() << "Failed to open legacy database:" << legacyDb.lastError().text();
            return false;
        }

        QSqlQuery query(legacyDb);
        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create legacy tasks table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE focus_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                start_time TEXT NOT NULL,
                end_time TEXT,
                duration INTEGER,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
            )
        )SQL"))) {
            qWarning() << "Failed to create legacy focus_sessions table:" << query.lastError().text();
            return false;
        }

        query.prepare(QStringLiteral(
            "INSERT INTO tasks (title, category, date, completed, created_at) "
            "VALUES (:title, :category, :date, 0, :createdAt)"));

        const QList<QPair<QString, QString>> rows = {
            {QStringLiteral("旧数学任务"), QStringLiteral("数学")},
            {QStringLiteral("旧自定义任务"), QStringLiteral("数据结构")},
            {QStringLiteral("旧空科目任务"), QString()}
        };

        for (const auto& row : rows) {
            query.bindValue(QStringLiteral(":title"), row.first);
            query.bindValue(QStringLiteral(":category"), row.second);
            query.bindValue(QStringLiteral(":date"), QStringLiteral("2026-06-10"));
            query.bindValue(QStringLiteral(":createdAt"), QStringLiteral("2026-06-10T08:00:00"));
            if (!query.exec()) {
                qWarning() << "Failed to insert legacy task:" << query.lastError().text();
                return false;
            }
        }

        if (!query.exec(QStringLiteral("PRAGMA user_version = 1"))) {
            qWarning() << "Failed to set legacy database version:" << query.lastError().text();
            return false;
        }

        legacyDb.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    return true;
}

bool createVersion2Database(const QString& path)
{
    // 构造已完成 v2 迁移的数据库，专门验证 v3 只新增 routines，不破坏已有科目结构。
    const QString connectionName = QStringLiteral("Version2MigrationSetupConnection");
    {
        QSqlDatabase version2Db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        version2Db.setDatabaseName(path);
        if (!version2Db.open()) {
            qWarning() << "Failed to open version 2 database:" << version2Db.lastError().text();
            return false;
        }

        QSqlQuery pragma(version2Db);
        if (!pragma.exec(QStringLiteral("PRAGMA foreign_keys = ON"))) {
            qWarning() << "Failed to enable version 2 foreign keys:" << pragma.lastError().text();
            return false;
        }

        QSqlQuery query(version2Db);
        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE CHECK(length(trim(name)) > 0),
                color TEXT NOT NULL,
                is_preset INTEGER NOT NULL DEFAULT 0,
                display_order INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 categories table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 tasks table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE focus_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                start_time TEXT NOT NULL,
                end_time TEXT,
                duration INTEGER,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 focus_sessions table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(
                "INSERT INTO categories (name, color, is_preset, display_order) "
                "VALUES ('数学', '#d4a574', 1, 1)"))) {
            qWarning() << "Failed to insert version 2 category:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(
                "INSERT INTO tasks (title, category, category_id, date, completed, created_at) "
                "VALUES ('v2 任务', '数学', 1, '2026-06-16', 0, '2026-06-16T08:00:00')"))) {
            qWarning() << "Failed to insert version 2 task:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral("PRAGMA user_version = 2"))) {
            qWarning() << "Failed to set version 2 database version:" << query.lastError().text();
            return false;
        }

        version2Db.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    return true;
}

QStringList taskTitles(const QVariantList& tasks)
{
    QStringList titles;
    for (const QVariant& taskValue : tasks) {
        titles.append(taskValue.toMap().value(QStringLiteral("title")).toString());
    }
    return titles;
}

QDate logicalToday()
{
    // 测试里所有“服务的今天”都必须与生产设置使用同一口径。
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}
}

class ServiceTests : public QObject {
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void appSettingsDefaultsAndRoundTrip();
    void appSettingsSameValueDoesNotEmit();
    void appSettingsReduceMotionRoundTrip();
    void appSettingsSlimClockFontRoundTrip();
    void appSettingsRolloverIgnoredDateRoundTrip();
    void appSettingsNicknameTrimsAndRoundTrips();
    void appSettingsDailyFocusGoalHoursNormalizeAndRoundTrip();
    void appSettingsSidebarVisibleRoundTrip();
    void appSettingsBackgroundThemeDefaultAndRoundTrip();
    void appSettingsDayStartHourNormalizeAndPersist();
    void appSettingsDayStartHourRejectsCorruptIniValue();
    void logicalDayDateOfBoundaries();
    void logicalDayMsUntilNextBoundary();
    void logicalDayServiceSchedulesTimerOnConstruction();
    void logicalDayServiceEmitsChangedOnDayStartHourChange();
    void logicalDayChangeMaterializesRoutineIdempotently();
    void addTaskRejectsBlankTitle();
    void addTaskPersistsTrimmedTitleAndEmitsChange();
    void addTaskAcceptsIsoDateStringFromQml();
    void deleteTaskPreservesFocusSessionHistory();
    void statisticsReturnsTodayCompletionAndDuration();
    void statisticsBucketsSessionsByLogicalDay();
    void statisticsTodayUsesLogicalToday();
    void getDayStatsUsesSpecifiedHistoricalDate();
    void getDayComparisonReturnsTrendTextAndRejectsInvalidDate();
    void focusHistoryBucketsSessionsByLogicalDay();
    void focusHistoryReturnsMonthSessionsWithinBoundaries();
    void focusHistoryReturnsDayTotalsAndFormattedDurations();
    void focusHistoryFallsBackWhenTaskWasDeleted();
    void focusHistoryDistinguishesEmptyResultFromQueryError();
    void focusHistorySkipsUnfinishedSessions();
    void focusHistorySkipsInvalidShortSessions();
    void focusHistoryCleansInvalidShortSessions();
    void getWeekStatsUsesCurrentNaturalWeek();
    void getWeekStatsUsesSpecifiedMondayAndRejectsInvalidStart();
    void getWeekComparisonSumsNaturalWeeksAndRejectsInvalidStart();
    void getWeekTasksReturnsInclusiveRangeAndRequiredOrder();
    void getMonthTasksReturnsInclusiveMonthRange();
    void getMonthTasksRejectsInvalidMonth();
    void getEffectiveDaysFiltersInvalidSessions();
    void getFocusSessionCountCountsOnlyValidFinishedSessions();
    void getStreakDaysCountsBackFromLogicalToday();
    void getStreakDaysStartsFromYesterdayWhenTodayHasNoFocus();
    void getTotalFocusDurationSumsOnlyValidSessions();
    void getMonthStatsUsesCurrentMonthAndTaskDate();
    void getMonthStatsUsesSpecifiedMonthAndRejectsInvalidYearMonth();
    void getMonthComparisonHandlesPreviousMonthAndInvalidYearMonth();
    void getMonthWeeklySummaryStaysInsideCurrentMonth();
    void getMonthWeeklySummaryUsesSpecifiedMonthAndRejectsInvalidYearMonth();
    void getCategoryStatsAggregatesDurationsAndPercentages();
    void statisticsIgnoresInvalidShortSessions();
    void routinesTableExistsAfterInitialize();
    void version2MigrationAddsRoutinesSchemaAndIndex();
    void routinesCategoryForeignKeyClearsWhenCategoryDeleted();
    void routineCrudAddsGetsUpdatesDeletes();
    void materializeTodayIsIdempotentAndDoesNotBackfill();
    void materializeTodayPreservesCategoryAndDoesNotEmitSignals();
    void materializeTodayStampsRoutineId();
    void materializeTodayRollsBackClaimWhenTaskInsertFails();
    void materializeTodayDoesNotResurrectDeletedTask();
    void materializeTodaySkipsInactiveRoutines();
    void freshDatabaseHasRoutineIdColumn();
    void migrationV4BackfillsRoutineIdAndIsIdempotent();
    void freshDatabaseCreatesVersion4PresetCategories();
    void migrationMapsLegacyCategoryTextToCategoryIds();
    void migrationCreatesDatabaseBackup();
    void customCategoryCrudValidatesAndEmitsChanges();
    void presetCategoriesCannotBeEditedOrDeleted();
    void deletingAssociatedCategoryDetachesTasks();
    void deletingLegacyTextCategoryClearsTaskCategoryText();
    void taskManagerReturnsFullCategoryInfo();
    void taskManagerTodayUsesLogicalToday();
    void legacyAddTaskWithTextCategoryRemainsCompatible();
    void updateTaskChangesTitleCategoryAndDate();
    void updateTaskRejectsBlankTitleAndInvalidId();
    void overdueQueryExcludesTodayCompletedAndRoutine();
    void moveTasksToTodayIsTransactional();
    void exportFocusSessionsUsesLogicalDayRange();
    void exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks();
    void exportFocusSessionsAndExportAllWriteExpectedCsvFiles();
    void exportFocusSessionsIgnoresInvalidShortSessions();
    void exportRejectsInvalidDateRangeAndUnwritablePath();
    void stopFocusCompletesTaskAfterFiveMinutes();
    void stopFocusUnderFiveMinutesKeepsTaskPending();
    void stopFocusUnderThreeMinutesDiscardsInvalidSession();
    void shortSessionEmitsSessionDiscarded();
    void validSessionDoesNotEmitSessionDiscarded();
    void focusTimerExposesRuleConstants();
    void pomodoroWorkCompletionSavesSessionAndAutoCompletesTask();
    void pomodoroBreakWritesNoSessionAndCompletes();
    void pomodoroWorkStoppedUnderMinimumIsDiscarded();
    void freeFocusStillCountsUpUnchanged();

private:
    QTemporaryDir* m_tempDir = nullptr;
};

void ServiceTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("test.sqlite")));
}

void ServiceTests::cleanup()
{
    // FocusTimer 是进程级单例；失败用例可能没走到 stopFocus，必须在关闭测试数据库前清掉活动阶段。
    FocusTimer::instance()->resetSession();
    AppSettings::instance()->setDayStartHour(4);
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void ServiceTests::appSettingsDefaultsAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.lastMode(), 0);
        QCOMPARE(settings.workMinutes(), 25);
        QCOMPARE(settings.breakMinutes(), 5);
        QCOMPARE(settings.soundEnabled(), true);

        QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
        QSignalSpy workSpy(&settings, &AppSettings::workMinutesChanged);
        settings.setLastMode(1);
        settings.setWorkMinutes(45);
        settings.setBreakMinutes(10);
        settings.setSoundEnabled(false);
        QCOMPARE(modeSpy.count(), 1);
        QCOMPARE(workSpy.count(), 1);
    }

    // 重新打开同一文件，验证写入的是持久化配置，不是对象内存缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.lastMode(), 1);
    QCOMPARE(reloaded.workMinutes(), 45);
    QCOMPARE(reloaded.breakMinutes(), 10);
    QCOMPARE(reloaded.soundEnabled(), false);
}

void ServiceTests::appSettingsSameValueDoesNotEmit()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    AppSettings settings(dir.filePath(QStringLiteral("settings.ini")));

    QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
    settings.setLastMode(0);
    QCOMPARE(modeSpy.count(), 0);
}

void ServiceTests::appSettingsReduceMotionRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.reduceMotion(), false);

        QSignalSpy spy(&settings, &AppSettings::reduceMotionChanged);
        settings.setReduceMotion(true);
        QCOMPARE(settings.reduceMotion(), true);
        QCOMPARE(spy.count(), 1);

        settings.setReduceMotion(true);
        QCOMPARE(spy.count(), 1);
    }

    // 重新构造对象验证 QSettings 已落盘，不只是当前对象缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.reduceMotion(), true);
}

void ServiceTests::appSettingsSlimClockFontRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.slimClockFont(), true);

        QSignalSpy spy(&settings, &AppSettings::slimClockFontChanged);
        settings.setSlimClockFont(false);
        QCOMPARE(settings.slimClockFont(), false);
        QCOMPARE(spy.count(), 1);

        settings.setSlimClockFont(false);
        QCOMPARE(spy.count(), 1);
    }

    // 重新构造对象验证 QSettings 已落盘，不只是当前对象缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.slimClockFont(), false);
}

void ServiceTests::appSettingsRolloverIgnoredDateRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.rolloverIgnoredDate(), QString());
        QSignalSpy spy(&settings, &AppSettings::rolloverIgnoredDateChanged);
        settings.setRolloverIgnoredDate(QStringLiteral("2026-07-06"));
        QCOMPARE(spy.count(), 1);
        settings.setRolloverIgnoredDate(QStringLiteral("2026-07-06"));
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.rolloverIgnoredDate(), QStringLiteral("2026-07-06"));
}

void ServiceTests::appSettingsNicknameTrimsAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.nickname(), QString());

        QSignalSpy spy(&settings, &AppSettings::nicknameChanged);
        settings.setNickname(QStringLiteral("  zjk  "));
        // 存储的是去空白后的昵称，问候语拼接不会出现悬空标点。
        QCOMPARE(settings.nickname(), QStringLiteral("zjk"));
        QCOMPARE(spy.count(), 1);

        // 语义同值（只差空白）不再发信号。
        settings.setNickname(QStringLiteral("zjk "));
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.nickname(), QStringLiteral("zjk"));
}

void ServiceTests::appSettingsSidebarVisibleRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认展开，与首次打开的可发现性一致。
        QCOMPARE(settings.sidebarVisible(), true);

        QSignalSpy spy(&settings, &AppSettings::sidebarVisibleChanged);
        settings.setSidebarVisible(false);
        QCOMPARE(settings.sidebarVisible(), false);
        QCOMPARE(spy.count(), 1);

        settings.setSidebarVisible(false);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.sidebarVisible(), false);
}

void ServiceTests::appSettingsDailyFocusGoalHoursNormalizeAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.dailyFocusGoalHours(), 3);

        QSignalSpy spy(&settings, &AppSettings::dailyFocusGoalHoursChanged);
        settings.setDailyFocusGoalHours(5);
        QCOMPARE(settings.dailyFocusGoalHours(), 5);
        QCOMPARE(spy.count(), 1);

        // 越界写入回默认 3，而不是被 clamp 成边界值。
        settings.setDailyFocusGoalHours(0);
        QCOMPARE(settings.dailyFocusGoalHours(), 3);
        settings.setDailyFocusGoalHours(24);
        QCOMPARE(settings.dailyFocusGoalHours(), 3);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dailyFocusGoalHours(), 3);
}

void ServiceTests::appSettingsBackgroundThemeDefaultAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认必须是暖纸：与 Theme.backgroundThemes 首位的回落约定一致。
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("warmPaper"));

        QSignalSpy spy(&settings, &AppSettings::backgroundThemeChanged);
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);

        // 同值写入不重复发信号（与其它偏好一致）。
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);
    }

    // 重建实例验证持久化。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.backgroundTheme(), QStringLiteral("celadon"));
}

void ServiceTests::appSettingsDayStartHourNormalizeAndPersist()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.dayStartHour(), 4);

        QSignalSpy spy(&settings, &AppSettings::dayStartHourChanged);
        settings.setDayStartHour(5);
        QCOMPARE(settings.dayStartHour(), 5);
        QCOMPARE(spy.count(), 1);

        // 归一化不是 clamp：越界配置视为损坏，一律回默认值 4。
        settings.setDayStartHour(99);
        QCOMPARE(settings.dayStartHour(), 4);
        settings.setDayStartHour(-1);
        QCOMPARE(settings.dayStartHour(), 4);

        const int countBefore = spy.count();
        settings.setDayStartHour(4);
        QCOMPARE(spy.count(), countBefore);

        settings.setDayStartHour(6);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dayStartHour(), 6);
}

void ServiceTests::appSettingsDayStartHourRejectsCorruptIniValue()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    // 坏值可能来自旧版本或手工编辑，读取入口必须统一归一化。
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("logic/dayStartHour"), 99);
        raw.sync();
    }

    AppSettings settings(path);
    QCOMPARE(settings.dayStartHour(), 4);
}

void ServiceTests::logicalDayDateOfBoundaries()
{
    const QDate day(2026, 7, 8);

    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(3, 59)), 4), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(4, 0)), 4), day);
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(0, 0)), 0), day);
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(5, 59)), 6), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(6, 0)), 6), day);

    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2026, 8, 1), QTime(1, 0)), 4),
             QDate(2026, 7, 31));
    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2027, 1, 1), QTime(2, 30)), 4),
             QDate(2026, 12, 31));

    // 用调用前后时刻包围薄包装结果，避免恰好跨过日界点时出现竞态假失败。
    const QDateTime before = QDateTime::currentDateTime();
    const QDate actualToday = LogicalDay::today(4);
    const QDateTime after = QDateTime::currentDateTime();
    const QDate expectedBefore = LogicalDay::dateOf(before, 4);
    const QDate expectedAfter = LogicalDay::dateOf(after, 4);
    QVERIFY(actualToday == expectedBefore || actualToday == expectedAfter);

    QCOMPARE(LogicalDay::sqlShift(4), QStringLiteral("-4 hours"));
    QCOMPARE(LogicalDay::sqlShift(0), QStringLiteral("-0 hours"));
}

void ServiceTests::logicalDayMsUntilNextBoundary()
{
    const QDate day(2026, 7, 8);

    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(2, 0)), 4),
             qint64(2) * 3600 * 1000);
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(5, 0)), 4),
             qint64(23) * 3600 * 1000);
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(4, 0)), 4),
             qint64(24) * 3600 * 1000);
}

void ServiceTests::logicalDayServiceSchedulesTimerOnConstruction()
{
    LogicalDayService service;
    auto* timer = service.findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(timer);
    QVERIFY(timer->isActive());
}

void ServiceTests::logicalDayServiceEmitsChangedOnDayStartHourChange()
{
    AppSettings::instance()->setDayStartHour(4);
    LogicalDayService service;
    QSignalSpy spy(&service, &LogicalDayService::changed);

    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);

    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);
}

void ServiceTests::logicalDayChangeMaterializesRoutineIdempotently()
{
    // 选择距下一界点最远的合法小时，避免测试执行中恰好跨日。
    const QDateTime now = QDateTime::currentDateTime();
    int safeHour = 0;
    qint64 longestDelay = -1;
    for (int hour = 0; hour <= 6; ++hour) {
        const qint64 delay = LogicalDay::msUntilNextBoundary(now, hour);
        if (delay > longestDelay) {
            longestDelay = delay;
            safeHour = hour;
        }
    }
    AppSettings::instance()->setDayStartHour(safeHour);
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("失效补例行"), -1));

    LogicalDayService service;
    connect(&service, &LogicalDayService::changed,
            RoutineManager::instance(), &RoutineManager::materializeToday);

    auto countRoutineTasks = []() {
        QSqlQuery query(DatabaseManager::instance()->database());
        if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '失效补例行'"))
            || !query.next()) {
            return -1;
        }
        return query.value(0).toInt();
    };

    QCOMPARE(countRoutineTasks(), 0);

    service.changed();
    QCOMPARE(countRoutineTasks(), 1);

    QSqlQuery taskDate(DatabaseManager::instance()->database());
    QVERIFY(taskDate.exec(QStringLiteral(
        "SELECT date FROM tasks WHERE title = '失效补例行'")));
    QVERIFY(taskDate.next());
    QCOMPARE(taskDate.value(0).toString(), logicalToday().toString(Qt::ISODate));

    QSqlQuery generatedDate(DatabaseManager::instance()->database());
    QVERIFY(generatedDate.exec(QStringLiteral(
        "SELECT last_generated_date FROM routines WHERE title = '失效补例行'")));
    QVERIFY(generatedDate.next());
    QCOMPARE(generatedDate.value(0).toString(), logicalToday().toString(Qt::ISODate));

    service.changed();
    QCOMPARE(countRoutineTasks(), 1);
}

void ServiceTests::addTaskRejectsBlankTitle()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(!TaskManager::instance()->addTask("   ", QVariant(logicalToday()), "数学"));

    QCOMPARE(spy.count(), 0);
    QCOMPARE(TaskManager::instance()->getTodayTasks().size(), 0);
}

void ServiceTests::addTaskPersistsTrimmedTitleAndEmitsChange()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(TaskManager::instance()->addTask("  数据结构第三章  ", QVariant(logicalToday()), "数据结构"));

    QCOMPARE(spy.count(), 1);
    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value("title").toString(), QString("数据结构第三章"));
    QCOMPARE(task.value("categoryText").toString(), QString("数据结构"));
    QCOMPARE(task.value("category").toMap().value("name").toString(), QString("数据结构"));
    QCOMPARE(task.value("completed").toBool(), false);
}

void ServiceTests::addTaskAcceptsIsoDateStringFromQml()
{
    const QString today = logicalToday().toString(Qt::ISODate);

    QVERIFY(TaskManager::instance()->addTask("政治选择题", today, "政治"));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value("title").toString(), QString("政治选择题"));
}

void ServiceTests::deleteTaskPreservesFocusSessionHistory()
{
    QVERIFY(TaskManager::instance()->addTask("操作系统真题", QVariant(logicalToday()), "操作系统"));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value("id").toInt();

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, 1200)"));
    insert.bindValue(QStringLiteral(":taskId"), taskId);
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(logicalToday()));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(logicalToday(), QStringLiteral("12:30:00")));
    QVERIFY(insert.exec());

    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec("SELECT task_id, duration FROM focus_sessions"));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());
    QCOMPARE(query.value(1).toInt(), 1200);
}

void ServiceTests::statisticsReturnsTodayCompletionAndDuration()
{
    const QDate today = logicalToday();
    QVERIFY(TaskManager::instance()->addTask("英语阅读", QVariant(today), "英语"));
    QVERIFY(TaskManager::instance()->addTask("数学错题", QVariant(today), "数学"));
    // TaskManager 的无参“今天”要到计划二才切换；本用例只验证 StatisticsService。
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QVERIFY(TaskManager::instance()->completeTask(tasks.first().toMap().value("id").toInt()));

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (NULL, :startTime, :endTime, 1800)"));
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(today));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(today, QStringLiteral("12:30:00")));
    QVERIFY(insert.exec());

    const QVariantMap stats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(stats.value("totalDuration").toInt(), 1800);
    QCOMPARE(stats.value("completedTasks").toInt(), 1);
    QCOMPARE(stats.value("totalTasks").toInt(), 2);
    QCOMPARE(stats.value("completionRate").toDouble(), 0.5);
}

void ServiceTests::statisticsBucketsSessionsByLogicalDay()
{
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("凌晨自习"), day, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:25:00"), 1500));
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("05:00:00"),
                                    QStringLiteral("05:15:00"), 900));

    QCOMPARE(service->getDayStats(day.addDays(-1)).value(QStringLiteral("totalDuration")).toInt(),
             1500);
    QCOMPARE(service->getDayStats(day).value(QStringLiteral("totalDuration")).toInt(), 900);

    QCOMPARE(service->getFocusSessionCount(day.addDays(-1), day.addDays(-1)), 1);
    QCOMPARE(service->getFocusSessionCount(day, day), 1);

    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day), 2);
    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day.addDays(-1)), 1);

    const QVariantMap categoryStats = service->getCategoryStats(
        day.addDays(-1).toString(Qt::ISODate), day.addDays(-1).toString(Qt::ISODate));
    QCOMPARE(categoryStats.value(QStringLiteral("totalDuration")).toInt(), 1500);
}

void ServiceTests::statisticsTodayUsesLogicalToday()
{
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    const QDate today = LogicalDay::today(4);
    const int taskId = insertTaskRow(QStringLiteral("今日等价"), today, QStringLiteral("英语"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, today, QStringLiteral("12:00:00"),
                                    QStringLiteral("12:30:00"), 1800));

    QCOMPARE(service->getTodayStats(), service->getDayStats(today));
}

void ServiceTests::getDayStatsUsesSpecifiedHistoricalDate()
{
    const QDate targetDate(2026, 6, 10);
    const QDate otherDate = targetDate.addDays(1);
    const int completedTaskId = insertTaskRow(QStringLiteral("历史完成任务"),
                                              targetDate,
                                              QStringLiteral("数学"),
                                              true);
    const int pendingTaskId = insertTaskRow(QStringLiteral("历史未完成任务"),
                                            targetDate,
                                            QStringLiteral("英语"));
    const int otherTaskId = insertTaskRow(QStringLiteral("其他日期任务"),
                                          otherDate,
                                          QStringLiteral("政治"),
                                          true);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);
    QVERIFY(otherTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, targetDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, targetDate, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(otherTaskId, otherDate, kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, targetDate, kTestMinimumValidDurationSeconds - 1));

    const QVariantMap stats = StatisticsService::instance()->getDayStats(targetDate);

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completionRate")).toDouble(), 0.5);

    const QVariantMap invalidStats = StatisticsService::instance()->getDayStats(QDate());
    QCOMPARE(invalidStats.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("totalTasks")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("completionRate")).toDouble(), 0.0);
}

void ServiceTests::getDayComparisonReturnsTrendTextAndRejectsInvalidDate()
{
    const QDate targetDate(2026, 6, 10);

    QVERIFY(insertTaskRow(QStringLiteral("昨天完成任务"),
                          targetDate.addDays(-1),
                          QStringLiteral("数学"),
                          true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天完成任务一"),
                          targetDate,
                          QStringLiteral("数学"),
                          true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天完成任务二"),
                          targetDate,
                          QStringLiteral("英语"),
                          true) > 0);
    QVERIFY(insertFocusSessionRow(-1, targetDate.addDays(-1), 1200));
    QVERIFY(insertFocusSessionRow(-1, targetDate, 1800));
    QVERIFY(insertFocusSessionRow(-1, targetDate, 600));
    QVERIFY(insertFocusSessionRow(-1, targetDate.addDays(10), 2400));

    const QVariantMap comparison = StatisticsService::instance()->getDayComparison(targetDate);
    const QVariantMap duration = comparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(), 2400);
    QCOMPARE(duration.value(QStringLiteral("previousValue")).toInt(), 1200);
    QCOMPARE(duration.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(duration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(duration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(duration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap sessionCount = comparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(sessionCount.value(QStringLiteral("currentValue")).toInt(), 2);
    QCOMPARE(sessionCount.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(sessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(sessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap taskCompletion = comparison.value(QStringLiteral("taskCompletion")).toMap();
    QCOMPARE(taskCompletion.value(QStringLiteral("currentValue")).toInt(), 2);
    QCOMPARE(taskCompletion.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(taskCompletion.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(taskCompletion.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(taskCompletion.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(taskCompletion.value(QStringLiteral("hasData")).toBool());

    const QVariantMap firstRecord = StatisticsService::instance()->getDayComparison(targetDate.addDays(10));
    const QVariantMap firstDuration = firstRecord.value(QStringLiteral("duration")).toMap();
    QCOMPARE(firstDuration.value(QStringLiteral("currentValue")).toInt(), 2400);
    QCOMPARE(firstDuration.value(QStringLiteral("previousValue")).toInt(), 0);
    QCOMPARE(firstDuration.value(QStringLiteral("changePercent")).toInt(), 0);
    QCOMPARE(firstDuration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(firstDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("首次记录"));
    QVERIFY(firstDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap noData = StatisticsService::instance()->getDayComparison(QDate(2026, 6, 30));
    QCOMPARE(noData.value(QStringLiteral("duration")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(noData.value(QStringLiteral("sessionCount")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(noData.value(QStringLiteral("taskCompletion")).toMap().value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalid = StatisticsService::instance()->getDayComparison(QDate());
    QCOMPARE(invalid.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::focusHistoryBucketsSessionsByLogicalDay()
{
    AppSettings::instance()->setDayStartHour(4);
    FocusHistoryService* service = FocusHistoryService::instance();

    const QDate monthFirst(2026, 8, 1);
    const int taskId = insertTaskRow(QStringLiteral("跨月凌晨"), monthFirst);
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, monthFirst, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:30:00"), 1800));

    const QVariantList julySessions = service->getMonthSessions(2026, 7);
    QCOMPARE(julySessions.size(), 1);
    QCOMPARE(julySessions.first().toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-07-31"));
    QVERIFY(service->getMonthSessions(2026, 8).isEmpty());

    QCOMPARE(service->getDaySessions(QDate(2026, 7, 31)).size(), 1);
    QVERIFY(service->getDaySessions(monthFirst).isEmpty());
}

void ServiceTests::focusHistoryReturnsMonthSessionsWithinBoundaries()
{
    const QDate targetDate(2026, 6, 10);
    const int mathTaskId = insertTaskRow(QStringLiteral("数学二"), targetDate, QStringLiteral("数学"));
    const int englishTaskId = insertTaskRow(QStringLiteral("英语阅读"), targetDate.addDays(1), QStringLiteral("英语"));
    QVERIFY(mathTaskId > 0);
    QVERIFY(englishTaskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-06-10T15:37:00"),
                QStringLiteral("2026-06-10T17:34:00"),
                7020) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                englishTaskId,
                QStringLiteral("2026-06-11T08:00:00"),
                QStringLiteral("2026-06-11T08:30:00"),
                1800) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-05-31T23:30:00"),
                QStringLiteral("2026-06-01T00:10:00"),
                2400) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-07-01T00:00:00"),
                QStringLiteral("2026-07-01T00:10:00"),
                600) > 0);

    const QVariantList sessions = FocusHistoryService::instance()->getMonthSessions(2026, 6);

    // 7月1日 00:00 在 4 点日界前，逻辑日仍是 6月30日，因此属于 6 月历史。
    QCOMPARE(sessions.size(), 3);
    const QVariantMap first = sessions.at(0).toMap();
    const QVariantMap second = sessions.at(1).toMap();
    const QVariantMap third = sessions.at(2).toMap();
    QCOMPARE(first.value(QStringLiteral("taskId")).toInt(), mathTaskId);
    QCOMPARE(first.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("数学二"));
    QCOMPARE(first.value(QStringLiteral("startTime")).toString(), QStringLiteral("2026-06-10T15:37:00"));
    QCOMPARE(first.value(QStringLiteral("endTime")).toString(), QStringLiteral("2026-06-10T17:34:00"));
    QCOMPARE(first.value(QStringLiteral("durationSeconds")).toInt(), 7020);
    QCOMPARE(first.value(QStringLiteral("date")).toString(), QStringLiteral("2026-06-10"));
    QCOMPARE(second.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("英语阅读"));
    QCOMPARE(third.value(QStringLiteral("startTime")).toString(), QStringLiteral("2026-07-01T00:00:00"));
    QCOMPARE(third.value(QStringLiteral("date")).toString(), QStringLiteral("2026-06-30"));
}

void ServiceTests::focusHistoryReturnsDayTotalsAndFormattedDurations()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("数学复盘"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T09:00:00"),
                QStringLiteral("2026-06-10T09:20:00"),
                1200) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T10:00:00"),
                QStringLiteral("2026-06-10T10:10:00"),
                600) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-11T10:00:00"),
                QStringLiteral("2026-06-11T10:30:00"),
                1800) > 0);

    const QVariantList daySessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(daySessions.size(), 2);
    QCOMPARE(FocusHistoryService::instance()->getDayTotalDuration(targetDate), 1800);
    QCOMPARE(FocusHistoryService::instance()->formatDuration(30), QStringLiteral("0分钟"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(43 * 60), QStringLiteral("43分钟"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(117 * 60), QStringLiteral("1小时57分"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(120 * 60), QStringLiteral("2小时"));
}

void ServiceTests::focusHistoryFallsBackWhenTaskWasDeleted()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("会被删除的任务"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T13:00:00"),
                QStringLiteral("2026-06-10T13:30:00"),
                1800) > 0);

    // 外键会把 focus_sessions.task_id 置空；历史页仍要展示这条专注记录。
    QSqlQuery deleteTask(DatabaseManager::instance()->database());
    deleteTask.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    deleteTask.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(deleteTask.exec());

    const QVariantList daySessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(daySessions.size(), 1);
    const QVariantMap session = daySessions.first().toMap();
    QVERIFY(session.value(QStringLiteral("taskId")).isNull()
            || !session.value(QStringLiteral("taskId")).isValid());
    QCOMPARE(session.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("未知任务"));
}

void ServiceTests::focusHistoryDistinguishesEmptyResultFromQueryError()
{
    QCOMPARE(FocusHistoryService::instance()->getMonthSessions(2026, 12).size(), 0);
    QCOMPARE(FocusHistoryService::instance()->lastError(), QString());

    QTest::ignoreMessage(QtWarningMsg,
                         "Failed to get month focus sessions: invalid year/month 2026 13");
    QCOMPARE(FocusHistoryService::instance()->getMonthSessions(2026, 13).size(), 0);
    QVERIFY(!FocusHistoryService::instance()->lastError().isEmpty());
}

void ServiceTests::focusHistorySkipsUnfinishedSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("进行中的专注"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:30:00"),
                1800) > 0);

    QSqlQuery unfinished(DatabaseManager::instance()->database());
    unfinished.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time) "
        "VALUES (:taskId, :startTime)"));
    unfinished.bindValue(QStringLiteral(":taskId"), taskId);
    unfinished.bindValue(QStringLiteral(":startTime"), QStringLiteral("2026-06-10T09:00:00"));
    QVERIFY(unfinished.exec());

    QVERIFY(insertFocusSessionWithNullDuration(taskId, targetDate));

    const QVariantList sessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(sessions.size(), 1);
    QCOMPARE(sessions.first().toMap().value(QStringLiteral("durationSeconds")).toInt(), 1800);
}

void ServiceTests::focusHistorySkipsInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("短时专注"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:00:00"),
                0) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:10:00"),
                QStringLiteral("2026-06-10T08:11:00"),
                60) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:20:00"),
                QStringLiteral("2026-06-10T08:22:59"),
                kTestMinimumValidDurationSeconds - 1) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:30:00"),
                QStringLiteral("2026-06-10T08:33:00"),
                kTestMinimumValidDurationSeconds) > 0);

    const QVariantList sessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(sessions.size(), 1);
    QCOMPARE(sessions.first().toMap().value(QStringLiteral("durationSeconds")).toInt(),
             kTestMinimumValidDurationSeconds);
    QCOMPARE(FocusHistoryService::instance()->getDayTotalDuration(targetDate),
             kTestMinimumValidDurationSeconds);
}

void ServiceTests::focusHistoryCleansInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("清理测试"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, targetDate, 0));
    QVERIFY(insertFocusSessionRow(taskId, targetDate, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionRow(taskId, targetDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, targetDate));

    QCOMPARE(FocusHistoryService::instance()->invalidSessionCount(), 2);
    QCOMPARE(FocusHistoryService::instance()->cleanupInvalidSessions(), 2);
    QCOMPARE(FocusHistoryService::instance()->invalidSessionCount(), 0);
    QCOMPARE(countFocusSessions(), 2);
    QCOMPARE(FocusHistoryService::instance()->getDaySessions(targetDate).size(), 1);
}

void ServiceTests::getWeekStatsUsesCurrentNaturalWeek()
{
    const QDate today = logicalToday();
    const QDate weekStart = today.addDays(1 - today.dayOfWeek());

    QVERIFY(insertFocusSessionRow(-1, weekStart, 120));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), 240));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), 999));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(7), 888));

    const QVariantList weekStats = StatisticsService::instance()->getWeekStats();

    QCOMPARE(weekStats.size(), 7);
    QCOMPARE(weekStats.first().toMap().value(QStringLiteral("date")).toDate(), weekStart);
    QCOMPARE(weekStats.last().toMap().value(QStringLiteral("date")).toDate(), weekStart.addDays(6));

    int totalDuration = 0;
    for (const QVariant& dayValue : weekStats) {
        totalDuration += dayValue.toMap().value(QStringLiteral("duration")).toInt();
    }
    QCOMPARE(totalDuration, 240);
}

void ServiceTests::getWeekStatsUsesSpecifiedMondayAndRejectsInvalidStart()
{
    const QDate weekStart(2026, 6, 8);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    QVERIFY(insertFocusSessionRow(-1, weekStart, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(7), kTestMinimumValidDurationSeconds * 10));

    const QVariantList weekStats = StatisticsService::instance()->getWeekStats(weekStart);

    QCOMPARE(weekStats.size(), 7);
    QCOMPARE(weekStats.first().toMap().value(QStringLiteral("date")).toDate(), weekStart);
    QCOMPARE(weekStats.last().toMap().value(QStringLiteral("date")).toDate(), weekStart.addDays(6));
    QCOMPARE(weekStats.at(0).toMap().value(QStringLiteral("duration")).toInt(),
             kTestMinimumValidDurationSeconds);
    QCOMPARE(weekStats.at(6).toMap().value(QStringLiteral("duration")).toInt(),
             kTestMinimumValidDurationSeconds * 2);

    int totalDuration = 0;
    for (const QVariant& dayValue : weekStats) {
        totalDuration += dayValue.toMap().value(QStringLiteral("duration")).toInt();
    }
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);

    QVERIFY(StatisticsService::instance()->getWeekStats(QDate()).isEmpty());
    QVERIFY(StatisticsService::instance()->getWeekStats(weekStart.addDays(1)).isEmpty());
}

void ServiceTests::getWeekComparisonSumsNaturalWeeksAndRejectsInvalidStart()
{
    const QDate weekStart(2026, 6, 8);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-7), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(-1, weekStart, kTestMinimumValidDurationSeconds * 4));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), kTestMinimumValidDurationSeconds * 8));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(3), kTestMinimumValidDurationSeconds));

    const QVariantMap comparison = StatisticsService::instance()->getWeekComparison(weekStart);
    const QVariantMap duration = comparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 13);
    QCOMPARE(duration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 5);
    QCOMPARE(duration.value(QStringLiteral("changePercent")).toInt(), 160);
    QCOMPARE(duration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(duration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +160% vs 上周"));
    QVERIFY(duration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap sessionCount = comparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(sessionCount.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(sessionCount.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(sessionCount.value(QStringLiteral("changePercent")).toInt(), 50);
    QCOMPARE(sessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +50% vs 上周"));
    QVERIFY(sessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap effectiveDays = comparison.value(QStringLiteral("effectiveDays")).toMap();
    QCOMPARE(effectiveDays.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(effectiveDays.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(effectiveDays.value(QStringLiteral("changePercent")).toInt(), 50);
    QCOMPARE(effectiveDays.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(effectiveDays.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +50% vs 上周"));
    QVERIFY(effectiveDays.value(QStringLiteral("hasData")).toBool());

    const QVariantMap invalidDate = StatisticsService::instance()->getWeekComparison(QDate());
    QCOMPARE(invalidDate.value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidWeekStart = StatisticsService::instance()->getWeekComparison(weekStart.addDays(1));
    QCOMPARE(invalidWeekStart.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::getWeekTasksReturnsInclusiveRangeAndRequiredOrder()
{
    const QDate startDate(2026, 6, 9);
    QVERIFY(insertTaskRow("范围前", startDate.addDays(-1), "数学") > 0);
    QVERIFY(insertTaskRow("周开始", startDate, "数学", false, "2026-06-09T08:00:00") > 0);
    QVERIFY(insertTaskRow("同创建时间低ID", startDate.addDays(1), "英语", false, "2026-06-10T07:00:00") > 0);
    QVERIFY(insertTaskRow("同创建时间高ID", startDate.addDays(1), "英语", false, "2026-06-10T07:00:00") > 0);
    QVERIFY(insertTaskRow("未完成较晚", startDate.addDays(1), "英语", false, "2026-06-10T08:00:00") > 0);
    QVERIFY(insertTaskRow("已完成较早", startDate.addDays(1), "英语", true, "2026-06-10T06:00:00") > 0);
    QVERIFY(insertTaskRow("周结束", startDate.addDays(6), "政治", false, "2026-06-15T08:00:00") > 0);
    QVERIFY(insertTaskRow("范围后", startDate.addDays(7), "数学") > 0);

    const QVariantList tasks = TaskManager::instance()->getWeekTasks(startDate.toString(Qt::ISODate));

    QCOMPARE(taskTitles(tasks), QStringList({
        "周开始",
        "同创建时间低ID",
        "同创建时间高ID",
        "未完成较晚",
        "已完成较早",
        "周结束"
    }));
    QCOMPARE(tasks.first().toMap().value("date").toDate(), startDate);
    QVERIFY(tasks.first().toMap().contains(QStringLiteral("createdAt")));
}

void ServiceTests::getMonthTasksReturnsInclusiveMonthRange()
{
    QVERIFY(insertTaskRow("一月最后一天", QDate(2026, 1, 31), "数学") > 0);
    QVERIFY(insertTaskRow("二月第一天", QDate(2026, 2, 1), "数学") > 0);
    QVERIFY(insertTaskRow("二月最后一天", QDate(2026, 2, 28), "英语") > 0);
    QVERIFY(insertTaskRow("三月第一天", QDate(2026, 3, 1), "政治") > 0);

    const QVariantList tasks = TaskManager::instance()->getMonthTasks(2026, 2);

    QCOMPARE(taskTitles(tasks), QStringList({"二月第一天", "二月最后一天"}));
}

void ServiceTests::getMonthTasksRejectsInvalidMonth()
{
    QVERIFY(insertTaskRow("有效任务", QDate(2026, 6, 1), "数学") > 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to get month tasks: invalid year/month 2026 0");
    QCOMPARE(TaskManager::instance()->getMonthTasks(2026, 0).size(), 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to get month tasks: invalid year/month 2026 13");
    QCOMPARE(TaskManager::instance()->getMonthTasks(2026, 13).size(), 0);
}

void ServiceTests::getEffectiveDaysFiltersInvalidSessions()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate = startDate.addDays(6);
    const int taskId = insertTaskRow(QStringLiteral("有效天数统计"), startDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, startDate.addDays(1)));
    QVERIFY(insertUnfinishedFocusSessionRow(taskId, startDate.addDays(2), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(3), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(taskId, endDate.addDays(1), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getEffectiveDays(startDate, endDate), 2);
}

void ServiceTests::getFocusSessionCountCountsOnlyValidFinishedSessions()
{
    const QDate startDate(2026, 7, 1);
    const QDate endDate = startDate.addDays(9);
    const int taskId = insertTaskRow(QStringLiteral("专注次数统计"), startDate, QStringLiteral("英语"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(1), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(2), kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, startDate.addDays(3)));
    QVERIFY(insertUnfinishedFocusSessionRow(taskId, startDate.addDays(4), kTestMinimumValidDurationSeconds * 4));
    QVERIFY(insertFocusSessionRow(taskId, endDate.addDays(1), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getFocusSessionCount(startDate, endDate), 3);
}

void ServiceTests::getStreakDaysCountsBackFromLogicalToday()
{
    const QDate today = logicalToday();

    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-2), kTestMinimumValidDurationSeconds));
    // 第 3 天断档；更早的记录不能透过断档续上连击。
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-4), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getStreakDays(), 3);
}

void ServiceTests::getStreakDaysStartsFromYesterdayWhenTodayHasNoFocus()
{
    const QDate today = logicalToday();
    QCOMPARE(StatisticsService::instance()->getStreakDays(), 0);

    QVERIFY(insertFocusSessionRow(-1, today.addDays(-1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-2), kTestMinimumValidDurationSeconds));
    // 今天只有无效短会话：不算今天，但也不打断从昨天起算的连击。
    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds - 1));

    QCOMPARE(StatisticsService::instance()->getStreakDays(), 2);
}

void ServiceTests::getTotalFocusDurationSumsOnlyValidSessions()
{
    const QDate today = logicalToday();
    QCOMPARE(StatisticsService::instance()->getTotalFocusDuration(), 0);

    const int taskId = insertTaskRow(QStringLiteral("累计时长任务"), today);
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-30), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds - 1));
    // NULL 时长辅助函数不转换 -1 任务号，这里必须挂在真实任务上才能通过外键。
    QVERIFY(insertFocusSessionWithNullDuration(taskId, today));

    QCOMPARE(StatisticsService::instance()->getTotalFocusDuration(), kTestMinimumValidDurationSeconds * 4);
}

void ServiceTests::getMonthStatsUsesCurrentMonthAndTaskDate()
{
    const QDate today = logicalToday();
    const QDate firstDay(today.year(), today.month(), 1);
    const QDate lastDay(today.year(), today.month(), today.daysInMonth());

    const int completedTaskId = insertTaskRow(QStringLiteral("本月完成任务"),
                                              firstDay,
                                              QStringLiteral("数学"),
                                              true,
                                              dateTimeText(firstDay.addDays(-1)));
    const int pendingTaskId = insertTaskRow(QStringLiteral("本月未完成任务"),
                                            lastDay,
                                            QStringLiteral("英语"),
                                            false,
                                            dateTimeText(firstDay));
    QVERIFY(insertTaskRow(QStringLiteral("日期在下月但创建于本月"),
                          lastDay.addDays(1),
                          QStringLiteral("政治"),
                          true,
                          dateTimeText(firstDay)) > 0);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertUnfinishedFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 5));

    const QVariantMap stats = StatisticsService::instance()->getMonthStats();

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("effectiveDays")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);
}

void ServiceTests::getMonthStatsUsesSpecifiedMonthAndRejectsInvalidYearMonth()
{
    const QDate firstDay(2026, 2, 1);
    const QDate lastDay(2026, 2, firstDay.daysInMonth());
    const int completedTaskId = insertTaskRow(QStringLiteral("二月完成任务"),
                                              firstDay,
                                              QStringLiteral("数学"),
                                              true,
                                              dateTimeText(firstDay.addDays(-1)));
    const int pendingTaskId = insertTaskRow(QStringLiteral("二月未完成任务"),
                                            lastDay,
                                            QStringLiteral("英语"),
                                            false,
                                            dateTimeText(firstDay));
    QVERIFY(insertTaskRow(QStringLiteral("三月任务"),
                          lastDay.addDays(1),
                          QStringLiteral("政治"),
                          true,
                          dateTimeText(firstDay)) > 0);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertUnfinishedFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 5));

    const QVariantMap stats = StatisticsService::instance()->getMonthStats(2026, 2);

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("effectiveDays")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);

    const QVariantMap invalidMonth = StatisticsService::instance()->getMonthStats(2026, 13);
    QCOMPARE(invalidMonth.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("effectiveDays")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("totalTasks")).toInt(), 0);

    const QVariantMap invalidYear = StatisticsService::instance()->getMonthStats(1999, 2);
    QCOMPARE(invalidYear.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("effectiveDays")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("totalTasks")).toInt(), 0);
}

void ServiceTests::getMonthComparisonHandlesPreviousMonthAndInvalidYearMonth()
{
    const QDate januaryFirst(2026, 1, 1);
    const QDate previousDecemberFirst(2025, 12, 1);
    const QDate februaryFirst(2026, 2, 1);

    QVERIFY(insertFocusSessionRow(-1, previousDecemberFirst, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, previousDecemberFirst.addDays(1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, januaryFirst, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst, kTestMinimumValidDurationSeconds * 5));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst.addDays(1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst.addDays(2), kTestMinimumValidDurationSeconds));

    const QVariantMap februaryComparison = StatisticsService::instance()->getMonthComparison(2026, 2);
    const QVariantMap februaryDuration = februaryComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(februaryDuration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 7);
    QCOMPARE(februaryDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(februaryDuration.value(QStringLiteral("changePercent")).toInt(), 250);
    QCOMPARE(februaryDuration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februaryDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +250% vs 上月"));
    QVERIFY(februaryDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap februarySessionCount = februaryComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(februarySessionCount.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(februarySessionCount.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(februarySessionCount.value(QStringLiteral("changePercent")).toInt(), 200);
    QCOMPARE(februarySessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februarySessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +200% vs 上月"));
    QVERIFY(februarySessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap februaryEffectiveDays = februaryComparison.value(QStringLiteral("effectiveDays")).toMap();
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("changePercent")).toInt(), 200);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +200% vs 上月"));
    QVERIFY(februaryEffectiveDays.value(QStringLiteral("hasData")).toBool());

    const QVariantMap januaryComparison = StatisticsService::instance()->getMonthComparison(2026, 1);
    const QVariantMap januaryDuration = januaryComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(januaryDuration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(januaryDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(januaryDuration.value(QStringLiteral("changePercent")).toInt(), 0);
    QCOMPARE(januaryDuration.value(QStringLiteral("trend")).toInt(), 0);
    QCOMPARE(januaryDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("→ 0% vs 上月"));
    QVERIFY(januaryDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap januarySessionCount = januaryComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(januarySessionCount.value(QStringLiteral("currentValue")).toInt(), 1);
    QCOMPARE(januarySessionCount.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(januarySessionCount.value(QStringLiteral("changePercent")).toInt(), -50);
    QCOMPARE(januarySessionCount.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(januarySessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -50% vs 上月"));
    QVERIFY(januarySessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap marchComparison = StatisticsService::instance()->getMonthComparison(2026, 3);
    const QVariantMap marchDuration = marchComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(marchDuration.value(QStringLiteral("currentValue")).toInt(), 0);
    QCOMPARE(marchDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 7);
    QCOMPARE(marchDuration.value(QStringLiteral("changePercent")).toInt(), -100);
    QCOMPARE(marchDuration.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(marchDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -100% vs 上月"));
    QVERIFY(marchDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap marchSessionCount = marchComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(marchSessionCount.value(QStringLiteral("currentValue")).toInt(), 0);
    QCOMPARE(marchSessionCount.value(QStringLiteral("previousValue")).toInt(), 3);
    QCOMPARE(marchSessionCount.value(QStringLiteral("changePercent")).toInt(), -100);
    QCOMPARE(marchSessionCount.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(marchSessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -100% vs 上月"));
    QVERIFY(marchSessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap equalZeroComparison = StatisticsService::instance()->getMonthComparison(2026, 4);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("duration")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("sessionCount")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("effectiveDays")).toMap().value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidMonth = StatisticsService::instance()->getMonthComparison(2026, 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidYear = StatisticsService::instance()->getMonthComparison(1999, 2);
    QCOMPARE(invalidYear.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::getMonthWeeklySummaryStaysInsideCurrentMonth()
{
    const QDate today = logicalToday();
    const QDate firstDay(today.year(), today.month(), 1);
    const QDate lastDay(today.year(), today.month(), today.daysInMonth());
    const int taskId = insertTaskRow(QStringLiteral("本月周汇总"), firstDay, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(taskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));

    const QVariantList summary = StatisticsService::instance()->getMonthWeeklySummary();

    QVERIFY(!summary.isEmpty());
    QDate expectedStart = firstDay;
    int totalDuration = 0;
    bool coversFirstDay = false;
    bool coversLastDay = false;

    for (int index = 0; index < summary.size(); ++index) {
        const QVariantMap week = summary.at(index).toMap();
        const QDate startDate = QDate::fromString(week.value(QStringLiteral("startDate")).toString(), Qt::ISODate);
        const QDate endDate = QDate::fromString(week.value(QStringLiteral("endDate")).toString(), Qt::ISODate);

        QVERIFY(startDate.isValid());
        QVERIFY(endDate.isValid());
        QVERIFY(startDate >= firstDay);
        QVERIFY(endDate <= lastDay);
        QVERIFY(startDate <= endDate);
        QCOMPARE(startDate, expectedStart);
        QCOMPARE(week.value(QStringLiteral("label")).toString(), QStringLiteral("第%1周").arg(index + 1));

        // 周桶不能跨出本月；如果不是最后一天，就应该停在自然周日。
        QVERIFY(endDate == lastDay || endDate.dayOfWeek() == Qt::Sunday);

        totalDuration += week.value(QStringLiteral("duration")).toInt();
        coversFirstDay = coversFirstDay || (startDate <= firstDay && firstDay <= endDate);
        coversLastDay = coversLastDay || (startDate <= lastDay && lastDay <= endDate);
        expectedStart = endDate.addDays(1);
    }

    QCOMPARE(summary.first().toMap().value(QStringLiteral("startDate")).toString(), firstDay.toString(Qt::ISODate));
    QCOMPARE(summary.last().toMap().value(QStringLiteral("endDate")).toString(), lastDay.toString(Qt::ISODate));
    QCOMPARE(expectedStart, lastDay.addDays(1));
    QVERIFY(coversFirstDay);
    QVERIFY(coversLastDay);
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);
}

void ServiceTests::getMonthWeeklySummaryUsesSpecifiedMonthAndRejectsInvalidYearMonth()
{
    const QDate firstDay(2026, 2, 1);
    const QDate lastDay(2026, 2, firstDay.daysInMonth());
    const int taskId = insertTaskRow(QStringLiteral("二月周汇总"), firstDay, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(taskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));

    const QVariantList summary = StatisticsService::instance()->getMonthWeeklySummary(2026, 2);

    QVERIFY(!summary.isEmpty());
    QDate expectedStart = firstDay;
    int totalDuration = 0;

    for (int index = 0; index < summary.size(); ++index) {
        const QVariantMap week = summary.at(index).toMap();
        const QDate startDate = QDate::fromString(week.value(QStringLiteral("startDate")).toString(), Qt::ISODate);
        const QDate endDate = QDate::fromString(week.value(QStringLiteral("endDate")).toString(), Qt::ISODate);

        QVERIFY(startDate.isValid());
        QVERIFY(endDate.isValid());
        QVERIFY(startDate >= firstDay);
        QVERIFY(endDate <= lastDay);
        QVERIFY(startDate <= endDate);
        QCOMPARE(startDate, expectedStart);
        QCOMPARE(week.value(QStringLiteral("label")).toString(), QStringLiteral("第%1周").arg(index + 1));
        QVERIFY(endDate == lastDay || endDate.dayOfWeek() == Qt::Sunday);

        totalDuration += week.value(QStringLiteral("duration")).toInt();
        expectedStart = endDate.addDays(1);
    }

    QCOMPARE(summary.first().toMap().value(QStringLiteral("startDate")).toString(), firstDay.toString(Qt::ISODate));
    QCOMPARE(summary.last().toMap().value(QStringLiteral("endDate")).toString(), lastDay.toString(Qt::ISODate));
    QCOMPARE(expectedStart, lastDay.addDays(1));
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);
    QVERIFY(StatisticsService::instance()->getMonthWeeklySummary(2026, 0).isEmpty());
    QVERIFY(StatisticsService::instance()->getMonthWeeklySummary(2101, 2).isEmpty());
}

void ServiceTests::getCategoryStatsAggregatesDurationsAndPercentages()
{
    const QDate startDate(2026, 6, 1);
    const QDate endDate(2026, 6, 30);
    const int mathTaskId = insertTaskRow("数学题", startDate, "数学");
    const int secondMathTaskId = insertTaskRow("高数复盘", startDate.addDays(1), "数学");
    const int englishTaskId = insertTaskRow("英语阅读", startDate.addDays(2), "英语");
    const int emptyCategoryTaskId = insertTaskRow("无分类", startDate.addDays(3), "");
    QVERIFY(mathTaskId > 0);
    QVERIFY(secondMathTaskId > 0);
    QVERIFY(englishTaskId > 0);
    QVERIFY(emptyCategoryTaskId > 0);

    QVERIFY(insertFocusSessionRow(mathTaskId, startDate, 1200));
    QVERIFY(insertFocusSessionRow(secondMathTaskId, startDate.addDays(1), 600));
    QVERIFY(insertFocusSessionRow(englishTaskId, startDate.addDays(2), 600));
    QVERIFY(insertFocusSessionWithNullDuration(englishTaskId, startDate.addDays(2)));
    QVERIFY(insertFocusSessionRow(emptyCategoryTaskId, startDate.addDays(3), 500));
    QVERIFY(insertFocusSessionRow(mathTaskId, startDate.addDays(-1), 900));
    QVERIFY(insertFocusSessionRow(-1, startDate, 700));

    const QVariantMap stats = StatisticsService::instance()->getCategoryStats(
        startDate.toString(Qt::ISODate),
        QVariant(endDate));
    const QVariantList categories = stats.value(QStringLiteral("categories")).toList();

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(), 2400);
    QCOMPARE(categories.size(), 2);

    const QVariantMap math = categories.at(0).toMap();
    QCOMPARE(math.value(QStringLiteral("name")).toString(), QString("数学"));
    QCOMPARE(math.value(QStringLiteral("color")).toString(), QStringLiteral("#d4a574"));
    QCOMPARE(math.value(QStringLiteral("duration")).toInt(), 1800);
    QCOMPARE(math.value(QStringLiteral("percentage")).toDouble(), 75.0);

    const QVariantMap english = categories.at(1).toMap();
    QCOMPARE(english.value(QStringLiteral("name")).toString(), QString("英语"));
    QCOMPARE(english.value(QStringLiteral("color")).toString(), QStringLiteral("#c9956e"));
    QCOMPARE(english.value(QStringLiteral("duration")).toInt(), 600);
    QCOMPARE(english.value(QStringLiteral("percentage")).toDouble(), 25.0);
}

void ServiceTests::statisticsIgnoresInvalidShortSessions()
{
    const QDate today = logicalToday();
    const int mathTaskId = insertTaskRow(QStringLiteral("数学短记录"), today, QStringLiteral("数学"));
    const int englishTaskId = insertTaskRow(QStringLiteral("英语有效记录"), today, QStringLiteral("英语"));
    QVERIFY(mathTaskId > 0);
    QVERIFY(englishTaskId > 0);

    QVERIFY(insertFocusSessionRow(mathTaskId, today, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionRow(englishTaskId, today, kTestMinimumValidDurationSeconds));

    const QVariantMap todayStats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(todayStats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds);

    const QVariantMap categoryStats = StatisticsService::instance()->getCategoryStats(today, today);
    QCOMPARE(categoryStats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds);
    const QVariantList categories = categoryStats.value(QStringLiteral("categories")).toList();
    QCOMPARE(categories.size(), 1);
    QCOMPARE(categories.first().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("英语"));
}

void ServiceTests::routinesTableExistsAfterInitialize()
{
    // init() 已用全新临时库初始化，迁移应已建好 routines 表。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY2(query.exec(QStringLiteral(
        "SELECT id, title, category_id, active, display_order, last_generated_date, created_at FROM routines")),
        qPrintable(query.lastError().text()));
}

void ServiceTests::version2MigrationAddsRoutinesSchemaAndIndex()
{
    DatabaseManager::instance()->close();
    const QString version2Path = m_tempDir->filePath(QStringLiteral("version2.sqlite"));
    QVERIFY(createVersion2Database(version2Path));
    QVERIFY(DatabaseManager::instance()->initialize(version2Path));

    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), 4);

    // v3 从真实 v2 库升级时必须补齐 routines 表和索引，不能只覆盖全新库。
    QSqlQuery tableQuery(DatabaseManager::instance()->database());
    QVERIFY2(tableQuery.exec(QStringLiteral(
                 "SELECT id, title, category_id, active, display_order, last_generated_date, created_at FROM routines")),
             qPrintable(tableQuery.lastError().text()));

    QSqlQuery indexQuery(DatabaseManager::instance()->database());
    indexQuery.prepare(QStringLiteral(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = :name"));
    indexQuery.bindValue(QStringLiteral(":name"), QStringLiteral("idx_routines_active"));
    QVERIFY(indexQuery.exec());
    QVERIFY(indexQuery.next());
    QCOMPARE(indexQuery.value(0).toString(), QStringLiteral("idx_routines_active"));

    QSqlQuery insertRoutine(DatabaseManager::instance()->database());
    QVERIFY2(insertRoutine.exec(QStringLiteral("INSERT INTO routines (title) VALUES ('v2 升级例行')")),
             qPrintable(insertRoutine.lastError().text()));

    QSqlQuery defaults(DatabaseManager::instance()->database());
    QVERIFY(defaults.exec(QStringLiteral(
        "SELECT active, display_order, created_at FROM routines WHERE title = 'v2 升级例行'")));
    QVERIFY(defaults.next());
    QCOMPARE(defaults.value(0).toInt(), 1);
    QCOMPARE(defaults.value(1).toInt(), 0);
    QVERIFY(!defaults.value(2).toString().isEmpty());
}

void ServiceTests::routinesCategoryForeignKeyClearsWhenCategoryDeleted()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("每日专业课"), QStringLiteral("#123456"));
    QVERIFY(categoryId > 0);

    QSqlQuery insertRoutine(DatabaseManager::instance()->database());
    insertRoutine.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id) VALUES (:title, :categoryId)"));
    insertRoutine.bindValue(QStringLiteral(":title"), QStringLiteral("每日复盘"));
    insertRoutine.bindValue(QStringLiteral(":categoryId"), categoryId);
    QVERIFY2(insertRoutine.exec(), qPrintable(insertRoutine.lastError().text()));

    // routines.category_id 使用 ON DELETE SET NULL，保持“删除科目只影响未来分类关联，不删除例行项”的语义。
    QVERIFY(manager->deleteCategory(categoryId));

    QSqlQuery routine(DatabaseManager::instance()->database());
    routine.prepare(QStringLiteral("SELECT category_id FROM routines WHERE title = :title"));
    routine.bindValue(QStringLiteral(":title"), QStringLiteral("每日复盘"));
    QVERIFY(routine.exec());
    QVERIFY(routine.next());
    QVERIFY(routine.value(0).isNull());
}

void ServiceTests::routineCrudAddsGetsUpdatesDeletes()
{
    RoutineManager* manager = RoutineManager::instance();
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("例行科目"), QStringLiteral("#123456"));
    QVERIFY(categoryId > 0);

    QSignalSpy spy(manager, &RoutineManager::routinesChanged);

    // 空标题被拒
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: title is empty");
    QVERIFY(!manager->addRoutine(QStringLiteral("   "), -1));
    QCOMPARE(spy.count(), 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: category not found 999999");
    QVERIFY(!manager->addRoutine(QStringLiteral("无效科目例行"), 999999));
    QCOMPARE(spy.count(), 0);

    // 正常新增（带前后空格，应被 trim）
    QVERIFY(manager->addRoutine(QStringLiteral("  背单词 list  "), -1));
    QCOMPARE(spy.count(), 1);

    QVariantList routines = manager->getRoutines();
    QCOMPARE(routines.size(), 1);
    QVariantMap r = routines.first().toMap();
    QCOMPARE(r.value(QStringLiteral("title")).toString(), QStringLiteral("背单词 list"));
    QCOMPARE(r.value(QStringLiteral("categoryId")).toInt(), -1);
    QCOMPARE(r.value(QStringLiteral("displayOrder")).toInt(), 1);
    QCOMPARE(r.value(QStringLiteral("active")).toBool(), true);
    const int id = r.value(QStringLiteral("id")).toInt();
    QVERIFY(id > 0);

    QVERIFY(manager->addRoutine(QStringLiteral("专业课复盘"), categoryId));
    QCOMPARE(spy.count(), 2);
    routines = manager->getRoutines();
    QCOMPARE(routines.size(), 2);
    const QVariantMap categoryRoutine = routines.at(1).toMap();
    QCOMPARE(categoryRoutine.value(QStringLiteral("title")).toString(), QStringLiteral("专业课复盘"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryName")).toString(), QStringLiteral("例行科目"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#123456"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("displayOrder")).toInt(), 2);
    const int categoryRoutineId = categoryRoutine.value(QStringLiteral("id")).toInt();
    QVERIFY(categoryRoutineId > 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to update routine: routine not found 999999");
    QVERIFY(!manager->updateRoutine(999999, QStringLiteral("不存在"), -1));
    QTest::ignoreMessage(QtWarningMsg, "Failed to set routine active: routine not found 999999");
    QVERIFY(!manager->setRoutineActive(999999, false));
    QTest::ignoreMessage(QtWarningMsg, "Failed to delete routine: routine not found 999999");
    QVERIFY(!manager->deleteRoutine(999999));
    QCOMPARE(spy.count(), 2);

    // 更新标题
    QVERIFY(manager->updateRoutine(id, QStringLiteral("背单词 list 2"), -1));
    QCOMPARE(spy.count(), 3);
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("背单词 list 2"));

    // 停用
    QVERIFY(manager->setRoutineActive(id, false));
    QCOMPARE(spy.count(), 4);
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("active")).toBool(), false);

    // 删除分类会让例行项的科目关联变成 NULL，RoutineManager 也要通知列表刷新。
    QVERIFY(CategoryManager::instance()->deleteCategory(categoryId));
    QCOMPARE(spy.count(), 5);
    routines = manager->getRoutines();
    QCOMPARE(routines.at(1).toMap().value(QStringLiteral("categoryId")).toInt(), -1);
    QCOMPARE(routines.at(1).toMap().value(QStringLiteral("categoryName")).toString(), QString());

    // 删除
    QVERIFY(manager->deleteRoutine(id));
    QCOMPARE(spy.count(), 6);
    QVERIFY(manager->deleteRoutine(categoryRoutineId));
    QCOMPARE(spy.count(), 7);
    QVERIFY(manager->getRoutines().isEmpty());
}

void ServiceTests::materializeTodayIsIdempotentAndDoesNotBackfill()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("背单词"), -1));

    const QString today = logicalToday().toString(Qt::ISODate);

    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);

    QCOMPARE(manager->materializeToday(), 0);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);

    QSqlQuery upd(DatabaseManager::instance()->database());
    QVERIFY2(upd.exec(QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")),
             qPrintable(upd.lastError().text()));
    QCOMPARE(manager->materializeToday(), 1);

    QSqlQuery check(DatabaseManager::instance()->database());
    QVERIFY2(check.exec(QStringLiteral("SELECT last_generated_date FROM routines")),
             qPrintable(check.lastError().text()));
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toString(), today);
}

void ServiceTests::materializeTodayPreservesCategoryAndDoesNotEmitSignals()
{
    RoutineManager* manager = RoutineManager::instance();
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("例行生成科目"), QStringLiteral("#654321"));
    QVERIFY(categoryId > 0);
    QVERIFY(manager->addRoutine(QStringLiteral("带科目例行"), categoryId));
    QVERIFY(manager->addRoutine(QStringLiteral("无科目例行"), -1));

    QSignalSpy taskSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QSignalSpy routineSpy(manager, &RoutineManager::routinesChanged);

    QCOMPARE(manager->materializeToday(), 2);
    QCOMPARE(taskSpy.count(), 0);
    QCOMPARE(routineSpy.count(), 0);

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(tasks.size(), 2);

    const QVariantMap categorized = tasks.at(0).toMap();
    QCOMPARE(categorized.value(QStringLiteral("title")).toString(), QStringLiteral("带科目例行"));
    QCOMPARE(categorized.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(categorized.value(QStringLiteral("categoryText")).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(categorized.value(QStringLiteral("categoryName")).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(categorized.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#654321"));

    const QVariantMap uncategorized = tasks.at(1).toMap();
    QCOMPARE(uncategorized.value(QStringLiteral("title")).toString(), QStringLiteral("无科目例行"));
    QVERIFY(uncategorized.value(QStringLiteral("categoryId")).isNull());
    QCOMPARE(uncategorized.value(QStringLiteral("categoryText")).toString(), QString());

    QSqlQuery rawTask(DatabaseManager::instance()->database());
    rawTask.prepare(QStringLiteral("SELECT category FROM tasks WHERE title = :title"));
    rawTask.bindValue(QStringLiteral(":title"), QStringLiteral("无科目例行"));
    QVERIFY(rawTask.exec());
    QVERIFY(rawTask.next());
    QCOMPARE(rawTask.value(0).toString(), QString());

    QSqlQuery rawCategorizedTask(DatabaseManager::instance()->database());
    rawCategorizedTask.prepare(QStringLiteral("SELECT category, category_id FROM tasks WHERE title = :title"));
    rawCategorizedTask.bindValue(QStringLiteral(":title"), QStringLiteral("带科目例行"));
    QVERIFY(rawCategorizedTask.exec());
    QVERIFY(rawCategorizedTask.next());
    QCOMPARE(rawCategorizedTask.value(0).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(rawCategorizedTask.value(1).toInt(), categoryId);
}

void ServiceTests::materializeTodayStampsRoutineId()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("晨间背单词"), -1));
    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT t.routine_id FROM tasks t JOIN routines r ON r.id = t.routine_id "
        "WHERE t.title = '晨间背单词'")));
    QVERIFY(query.next());
    QVERIFY(query.value(0).toInt() > 0);
}

void ServiceTests::materializeTodayRollsBackClaimWhenTaskInsertFails()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("失败例行"), -1));

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY2(trigger.exec(QStringLiteral(R"SQL(
        CREATE TRIGGER fail_routine_task_insert
        BEFORE INSERT ON tasks
        WHEN NEW.title = '失败例行'
        BEGIN
            SELECT RAISE(ABORT, 'forced routine insert failure');
        END
    )SQL")), qPrintable(trigger.lastError().text()));

    // 触发器模拟插入任务失败；事务必须回滚 last_generated_date 的抢占更新，
    // 否则用户当天会既没有任务，又被标记为已生成。
    QCOMPARE(manager->materializeToday(), 0);

    QSqlQuery routine(DatabaseManager::instance()->database());
    QVERIFY(routine.exec(QStringLiteral("SELECT last_generated_date FROM routines WHERE title = '失败例行'")));
    QVERIFY(routine.next());
    QVERIFY(routine.value(0).isNull());

    QSqlQuery countTasks(DatabaseManager::instance()->database());
    QVERIFY(countTasks.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '失败例行'")));
    QVERIFY(countTasks.next());
    QCOMPARE(countTasks.value(0).toInt(), 0);
}

void ServiceTests::materializeTodayDoesNotResurrectDeletedTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("数学真题"), -1));
    QCOMPARE(manager->materializeToday(), 1);

    QVariantList todays = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(todays.size(), 1);
    const int taskId = todays.first().toMap().value(QStringLiteral("id")).toInt();

    // 删掉今天生成的任务后再生成：last_generated_date 已是今天，所以当天不应复活。
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
}

void ServiceTests::materializeTodaySkipsInactiveRoutines()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("停用项"), -1));
    const int id = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(manager->setRoutineActive(id, false));

    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
}

void ServiceTests::freshDatabaseHasRoutineIdColumn()
{
    // 新库直建路径也必须带 routine_id 列，SELECT 不报错即证明列存在。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks LIMIT 1")));
}

void ServiceTests::migrationV4BackfillsRoutineIdAndIsIdempotent()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1));
    const QDate yesterday = QDate::currentDate().addDays(-1);
    const int routineLikeId = insertTaskRow(QStringLiteral("背单词"), yesterday);
    const int plainId = insertTaskRow(QStringLiteral("普通任务"), yesterday);
    QVERIFY(routineLikeId > 0);
    QVERIFY(plainId > 0);

    // 把版本拨回 3 重跑建表流程，模拟老库升级路径：
    // 列已存在时走幂等分支，回填逻辑仍要对存量行生效。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 3")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(routineLikeId)));
    QVERIFY(query.next());
    QVERIFY(!query.value(0).isNull());

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(plainId)));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 4);
}

void ServiceTests::freshDatabaseCreatesVersion4PresetCategories()
{
    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), 4);

    const QVariantList presets = CategoryManager::instance()->getPresetCategories();
    QCOMPARE(presets.size(), 5);

    const QStringList expectedNames = {
        QStringLiteral("数学"),
        QStringLiteral("英语"),
        QStringLiteral("政治"),
        QStringLiteral("专业课"),
        QStringLiteral("其他")
    };
    const QStringList expectedColors = {
        QStringLiteral("#d4a574"),
        QStringLiteral("#c9956e"),
        QStringLiteral("#be8568"),
        QStringLiteral("#b37562"),
        QStringLiteral("#a8655c")
    };

    for (int index = 0; index < presets.size(); ++index) {
        const QVariantMap category = presets.at(index).toMap();
        QCOMPARE(category.value(QStringLiteral("name")).toString(), expectedNames.at(index));
        QCOMPARE(category.value(QStringLiteral("color")).toString(), expectedColors.at(index));
        QCOMPARE(category.value(QStringLiteral("isPreset")).toBool(), true);
        QCOMPARE(category.value(QStringLiteral("displayOrder")).toInt(), index + 1);
    }
}

void ServiceTests::migrationMapsLegacyCategoryTextToCategoryIds()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), 4);

    QSqlQuery presetTask(DatabaseManager::instance()->database());
    presetTask.prepare(QStringLiteral(
        "SELECT t.category, t.category_id, c.name, c.color, c.is_preset "
        "FROM tasks t JOIN categories c ON t.category_id = c.id "
        "WHERE t.title = :title"));
    presetTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧数学任务"));
    QVERIFY(presetTask.exec());
    QVERIFY(presetTask.next());
    QCOMPARE(presetTask.value(0).toString(), QStringLiteral("数学"));
    QVERIFY(presetTask.value(1).toInt() > 0);
    QCOMPARE(presetTask.value(2).toString(), QStringLiteral("数学"));
    QCOMPARE(presetTask.value(3).toString(), QStringLiteral("#d4a574"));
    QCOMPARE(presetTask.value(4).toBool(), true);

    QSqlQuery customTask(DatabaseManager::instance()->database());
    customTask.prepare(QStringLiteral(
        "SELECT t.category, t.category_id, c.name, c.is_preset "
        "FROM tasks t JOIN categories c ON t.category_id = c.id "
        "WHERE t.title = :title"));
    customTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧自定义任务"));
    QVERIFY(customTask.exec());
    QVERIFY(customTask.next());
    QCOMPARE(customTask.value(0).toString(), QStringLiteral("数据结构"));
    QVERIFY(customTask.value(1).toInt() > 0);
    QCOMPARE(customTask.value(2).toString(), QStringLiteral("数据结构"));
    QCOMPARE(customTask.value(3).toBool(), false);

    QSqlQuery emptyTask(DatabaseManager::instance()->database());
    emptyTask.prepare(QStringLiteral("SELECT category, category_id FROM tasks WHERE title = :title"));
    emptyTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧空科目任务"));
    QVERIFY(emptyTask.exec());
    QVERIFY(emptyTask.next());
    QCOMPARE(emptyTask.value(0).toString(), QString());
    QVERIFY(emptyTask.value(1).isNull());
}

void ServiceTests::migrationCreatesDatabaseBackup()
{
    DatabaseManager::instance()->close();

    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-backup.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    const QStringList backups = QDir(m_tempDir->path()).entryList(
        QStringList{QStringLiteral("pomodoro_backup_*.db")},
        QDir::Files);
    QVERIFY(!backups.isEmpty());
}

void ServiceTests::customCategoryCrudValidatesAndEmitsChanges()
{
    CategoryManager* manager = CategoryManager::instance();
    QSignalSpy spy(manager, &CategoryManager::categoriesChanged);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add category: name is empty");
    QCOMPARE(manager->addCategory(QStringLiteral("   "), QStringLiteral("#112233")), -1);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add category: invalid color \"112233\"");
    QCOMPARE(manager->addCategory(QStringLiteral("算法"), QStringLiteral("112233")), -1);

    const int id = manager->addCategory(QStringLiteral("  算法  "), QStringLiteral("#112233"));
    QVERIFY(id > 0);
    QCOMPARE(spy.count(), 1);

    QVariantMap category = manager->getCategoryById(id);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("算法"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#112233"));
    QCOMPARE(category.value(QStringLiteral("isPreset")).toBool(), false);

    QTest::ignoreMessage(QtWarningMsg, "Failed to update category: invalid color \"red\"");
    QVERIFY(!manager->updateCategory(id, QStringLiteral("算法复盘"), QStringLiteral("red")));

    QVERIFY(manager->updateCategory(id, QStringLiteral("  算法复盘  "), QStringLiteral("#445566")));
    QCOMPARE(spy.count(), 2);
    category = manager->getCategoryById(id);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("算法复盘"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#445566"));

    QVERIFY(manager->canDeleteCategory(id));
    QVERIFY(manager->deleteCategory(id));
    QCOMPARE(spy.count(), 3);
    QVERIFY(manager->getCategoryById(id).isEmpty());
}

void ServiceTests::presetCategoriesCannotBeEditedOrDeleted()
{
    CategoryManager* manager = CategoryManager::instance();
    const QVariantMap preset = manager->getPresetCategories().first().toMap();
    const int presetId = preset.value(QStringLiteral("id")).toInt();

    QTest::ignoreMessage(QtWarningMsg, "Failed to update category: preset category cannot be edited");
    QVERIFY(!manager->updateCategory(presetId, QStringLiteral("数学改名"), QStringLiteral("#112233")));

    QTest::ignoreMessage(QtWarningMsg, "Failed to delete category: preset category cannot be deleted");
    QVERIFY(!manager->deleteCategory(presetId));

    const QVariantMap unchanged = manager->getCategoryById(presetId);
    QCOMPARE(unchanged.value(QStringLiteral("name")).toString(), preset.value(QStringLiteral("name")).toString());
    QCOMPARE(unchanged.value(QStringLiteral("color")).toString(), preset.value(QStringLiteral("color")).toString());
}

void ServiceTests::deletingAssociatedCategoryDetachesTasks()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("408"), QStringLiteral("#abcdef"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("计组错题"), QVariant(logicalToday()), categoryId));

    // 删除科目不应该删除任务，只应该把任务变成未分类。
    QVERIFY(manager->canDeleteCategory(categoryId));
    QVERIFY(manager->deleteCategory(categoryId));
    QVERIFY(manager->getCategoryById(categoryId).isEmpty());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("计组错题"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), 0);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QString());
    QVERIFY(task.value(QStringLiteral("category")).toMap().isEmpty());
}

void ServiceTests::deletingLegacyTextCategoryClearsTaskCategoryText()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("网络原理"), QStringLiteral("#778899"));
    QVERIFY(categoryId > 0);
    QVERIFY(insertTaskRowWithCategoryId(
                QStringLiteral("旧文本任务"),
                logicalToday(),
                -1,
                QStringLiteral("网络原理"),
                false,
                dateTimeText(logicalToday())) > 0);

    // 旧数据只有文本科目，也必须跟新 category_id 逻辑保持同样结果。
    QVERIFY(manager->canDeleteCategory(categoryId));
    QVERIFY(manager->deleteCategory(categoryId));
    QVERIFY(manager->getCategoryById(categoryId).isEmpty());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("旧文本任务"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), 0);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QString());
    QVERIFY(task.value(QStringLiteral("category")).toMap().isEmpty());
}

void ServiceTests::taskManagerReturnsFullCategoryInfo()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("数据结构"), QStringLiteral("#123abc"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("图论专题"), QVariant(logicalToday()), categoryId));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);

    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(task.value(QStringLiteral("categoryName")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(task.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#123abc"));

    const QVariantMap category = task.value(QStringLiteral("category")).toMap();
    QCOMPARE(category.value(QStringLiteral("id")).toInt(), categoryId);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#123abc"));

    const QVariantMap nestedCategory = task.value(QStringLiteral("categoryData")).toMap();
    QCOMPARE(nestedCategory.value(QStringLiteral("id")).toInt(), categoryId);
    QCOMPARE(nestedCategory.value(QStringLiteral("name")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(nestedCategory.value(QStringLiteral("color")).toString(), QStringLiteral("#123abc"));
}

void ServiceTests::taskManagerTodayUsesLogicalToday()
{
    AppSettings::instance()->setDayStartHour(4);
    TaskManager* manager = TaskManager::instance();

    QVERIFY(manager->addTask(QStringLiteral("逻辑今日任务"), QVariant(logicalToday()), QString()));
    QVERIFY(manager->addTask(QStringLiteral("逻辑昨日任务"),
                             QVariant(logicalToday().addDays(-1)), QString()));

    QCOMPARE(manager->getTodayTasks(), manager->getTasksByDate(logicalToday()));
    QCOMPARE(manager->getTodayTasks().size(), 1);

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 1);
    QCOMPARE(overdue.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("逻辑昨日任务"));

    QVERIFY(manager->moveTasksToToday(
        QVariantList{overdue.first().toMap().value(QStringLiteral("id"))}));
    QCOMPARE(manager->getTasksByDate(logicalToday()).size(), 2);
    QVERIFY(manager->getOverdueUncompletedTasks().isEmpty());
}

void ServiceTests::legacyAddTaskWithTextCategoryRemainsCompatible()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("政治选择题"), QVariant(logicalToday()), QStringLiteral("政治")));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);

    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("政治"));
    QVERIFY(task.value(QStringLiteral("categoryId")).toInt() > 0);
    QCOMPARE(task.value(QStringLiteral("categoryName")).toString(), QStringLiteral("政治"));
    QCOMPARE(task.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#be8568"));

    const QVariantMap nestedCategory = task.value(QStringLiteral("categoryData")).toMap();
    QCOMPARE(nestedCategory.value(QStringLiteral("name")).toString(), QStringLiteral("政治"));
}

void ServiceTests::updateTaskChangesTitleCategoryAndDate()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = QDate::currentDate();
    const int taskId = insertTaskRow(QStringLiteral("原标题"), today);
    QVERIFY(taskId > 0);

    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("数学编辑"), QStringLiteral("#d4a574"));
    QVERIFY(categoryId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    const QDate tomorrow = today.addDays(1);
    QVERIFY(manager->updateTask(taskId,
                                QStringLiteral("  新标题  "),
                                categoryId,
                                tomorrow.toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 1);

    const QVariantList todayTasks = manager->getTasksByDate(today);
    QVERIFY(todayTasks.isEmpty());

    const QVariantList tasks = manager->getTasksByDate(tomorrow);
    QCOMPARE(tasks.size(), 1);
    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("新标题"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("数学编辑"));
}

void ServiceTests::updateTaskRejectsBlankTitleAndInvalidId()
{
    TaskManager* manager = TaskManager::instance();
    const int taskId = insertTaskRow(QStringLiteral("保持不变"), logicalToday());
    QVERIFY(taskId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: title is empty after trimming");
    QVERIFY(!manager->updateTask(taskId,
                                 QStringLiteral("   "),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: invalid task id -5");
    QVERIFY(!manager->updateTask(-5,
                                 QStringLiteral("有效标题"),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: task not found 999999");
    QVERIFY(!manager->updateTask(999999,
                                 QStringLiteral("有效标题"),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 0);

    const QVariantList tasks = manager->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("保持不变"));
}

void ServiceTests::overdueQueryExcludesTodayCompletedAndRoutine()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = logicalToday();
    const QDate yesterday = today.addDays(-1);
    const QDate lastWeek = today.addDays(-6);

    const int oldPending = insertTaskRow(QStringLiteral("上周残留"), lastWeek);
    const int yesterdayPending = insertTaskRow(QStringLiteral("昨天残留"), yesterday);
    QVERIFY(oldPending > 0);
    QVERIFY(yesterdayPending > 0);
    QVERIFY(insertTaskRow(QStringLiteral("昨天已完成"), yesterday, QString(), true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天的任务"), today) > 0);

    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("结转排除例行"), -1));
    const int routineLeftover = insertTaskRow(QStringLiteral("结转排除例行"), yesterday);
    QVERIFY(routineLeftover > 0);

    QSqlQuery mark(DatabaseManager::instance()->database());
    QVERIFY2(mark.exec(QStringLiteral(
                  "UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE title = '结转排除例行') "
                  "WHERE id = %1").arg(routineLeftover)),
             qPrintable(mark.lastError().text()));

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 2);
    QCOMPARE(overdue.at(0).toMap().value(QStringLiteral("id")).toInt(), oldPending);
    QCOMPARE(overdue.at(1).toMap().value(QStringLiteral("id")).toInt(), yesterdayPending);
}

void ServiceTests::moveTasksToTodayIsTransactional()
{
    TaskManager* manager = TaskManager::instance();
    const QDate yesterday = logicalToday().addDays(-1);
    const int first = insertTaskRow(QStringLiteral("结转一"), yesterday);
    const int second = insertTaskRow(QStringLiteral("结转二"), yesterday);
    QVERIFY(first > 0);
    QVERIFY(second > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QTest::ignoreMessage(QtWarningMsg, "Failed to move task 999999 : \"\"");
    QVERIFY(!manager->moveTasksToToday(QVariantList{first, 999999}));
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 2);

    QVERIFY(manager->moveTasksToToday(QVariantList{first, second}));
    QCOMPARE(changedSpy.count(), 1);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 0);
    QCOMPARE(manager->getTodayTasks().size(), 2);
    QCOMPARE(manager->getOverdueUncompletedTasks().size(), 0);

    QVERIFY(manager->moveTasksToToday(QVariantList{}));
}

void ServiceTests::exportFocusSessionsUsesLogicalDayRange()
{
    AppSettings::instance()->setDayStartHour(4);
    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("导出边界"), day, QStringLiteral("政治"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:30:00"), 1800));

    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QString hitPath = dir.filePath(QStringLiteral("hit.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day.addDays(-1),
                                                           day.addDays(-1),
                                                           hitPath));
    QFile hitFile(hitPath);
    QVERIFY(hitFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(QString::fromUtf8(hitFile.readAll()).contains(QStringLiteral("导出边界")));

    const QString missPath = dir.filePath(QStringLiteral("miss.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day, day, missPath));
    QFile missFile(missPath);
    QVERIFY(missFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(!QString::fromUtf8(missFile.readAll()).contains(QStringLiteral("导出边界")));
}

void ServiceTests::exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate(2026, 6, 11);
    const int mathCategoryId = CategoryManager::instance()->addCategory(QStringLiteral("离散数学"), QStringLiteral("#123abc"));
    QVERIFY(mathCategoryId > 0);

    const int joinedTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("复习,总结,归纳"),
        startDate,
        mathCategoryId,
        QStringLiteral("旧科目不应导出"),
        true,
        QStringLiteral("2026-06-09T08:30:00"));
    const int legacyTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("学习\"关键点\""),
        endDate,
        -1,
        QStringLiteral("英语"),
        false,
        QStringLiteral("2026-06-09T09:00:00"));
    const int uncategorizedTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("换行\n标题"),
        endDate,
        -1,
        QString(),
        false,
        QStringLiteral("2026-06-09T10:00:00"));
    QVERIFY(joinedTaskId > 0);
    QVERIFY(legacyTaskId > 0);
    QVERIFY(uncategorizedTaskId > 0);

    QSignalSpy completedSpy(ExportService::instance(), &ExportService::exportCompleted);
    QSignalSpy progressSpy(ExportService::instance(), &ExportService::exportProgress);
    const QString filePath = m_tempDir->filePath(QStringLiteral("tasks.csv"));

    QVERIFY(ExportService::instance()->exportTasks(startDate, endDate, filePath));

    QCOMPARE(completedSpy.count(), 1);
    QCOMPARE(completedSpy.takeFirst().at(0).toBool(), true);
    QCOMPARE(progressSpy.count(), 3);
    QCOMPARE(progressSpy.last().at(0).toInt(), 3);
    QCOMPARE(progressSpy.last().at(1).toInt(), 3);
    QCOMPARE(readUtf8File(filePath),
             QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n"
                            "%1,\"复习,总结,归纳\",离散数学,2026-06-10,已完成,2026-06-09 08:30:00\n"
                            "%2,\"学习\"\"关键点\"\"\",英语,2026-06-11,未完成,2026-06-09 09:00:00\n"
                            "%3,\"换行\n标题\",未分类,2026-06-11,未完成,2026-06-09 10:00:00\n")
                 .arg(joinedTaskId)
                 .arg(legacyTaskId)
                 .arg(uncategorizedTaskId));
}

void ServiceTests::exportFocusSessionsAndExportAllWriteExpectedCsvFiles()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate(2026, 6, 10);
    const int politicsCategoryId = CategoryManager::instance()->addCategory(QStringLiteral("政治理论"), QStringLiteral("#445566"));
    QVERIFY(politicsCategoryId > 0);
    const int taskId = insertTaskRowWithCategoryId(
        QStringLiteral("真题\"精讲\",第一套"),
        startDate,
        politicsCategoryId,
        QString(),
        false,
        QStringLiteral("2026-06-10T08:00:00"));
    const int emptyCategoryTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("无科目任务"),
        startDate,
        -1,
        QString(),
        false,
        QStringLiteral("2026-06-10T08:10:00"));
    QVERIFY(taskId > 0);
    QVERIFY(emptyCategoryTaskId > 0);

    const int linkedSessionId = insertFocusSessionRowWithTimes(
        taskId,
        QStringLiteral("2026-06-10T09:00:00"),
        QStringLiteral("2026-06-10T10:30:00"),
        5400);
    const int uncategorizedSessionId = insertFocusSessionRowWithTimes(
        emptyCategoryTaskId,
        QStringLiteral("2026-06-10T11:00:00"),
        QStringLiteral("2026-06-10T11:30:00"),
        1800);
    const int unlinkedSessionId = insertFocusSessionRowWithTimes(
        -1,
        QStringLiteral("2026-06-10T12:00:00"),
        QStringLiteral("2026-06-10T12:20:00"),
        1200);
    QVERIFY(linkedSessionId > 0);
    QVERIFY(uncategorizedSessionId > 0);
    QVERIFY(unlinkedSessionId > 0);

    const QString sessionsPath = m_tempDir->filePath(QStringLiteral("sessions.csv"));
    QSignalSpy sessionProgressSpy(ExportService::instance(), &ExportService::exportProgress);
    QVERIFY(ExportService::instance()->exportFocusSessions(startDate, endDate, sessionsPath));
    QCOMPARE(sessionProgressSpy.count(), 3);
    QCOMPARE(sessionProgressSpy.last().at(0).toInt(), 3);
    QCOMPARE(sessionProgressSpy.last().at(1).toInt(), 3);
    QCOMPARE(readUtf8File(sessionsPath),
             QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n"
                            "%1,%2,\"真题\"\"精讲\"\",第一套\",政治理论,2026-06-10 09:00:00,2026-06-10 10:30:00,90\n"
                            "%3,%4,无科目任务,未分类,2026-06-10 11:00:00,2026-06-10 11:30:00,30\n"
                            "%5,-1,未关联任务,未分类,2026-06-10 12:00:00,2026-06-10 12:20:00,20\n")
                 .arg(linkedSessionId)
                 .arg(taskId)
                 .arg(uncategorizedSessionId)
                 .arg(emptyCategoryTaskId)
                 .arg(unlinkedSessionId));

    QSignalSpy allCompletedSpy(ExportService::instance(), &ExportService::exportCompleted);
    QVERIFY(ExportService::instance()->exportAll(startDate, endDate, m_tempDir->path()));
    QCOMPARE(allCompletedSpy.count(), 1);
    QCOMPARE(allCompletedSpy.takeFirst().at(0).toBool(), true);
    const QString tasksFileName = ExportService::instance()->generateFileName(QStringLiteral("tasks"), startDate, endDate);
    const QString sessionsFileName = ExportService::instance()->generateFileName(QStringLiteral("focus_sessions"), startDate, endDate);
    QCOMPARE(tasksFileName, QStringLiteral("tasks_20260610_20260610.csv"));
    QCOMPARE(sessionsFileName, QStringLiteral("focus_sessions_20260610_20260610.csv"));
    QVERIFY(QFile::exists(m_tempDir->filePath(tasksFileName)));
    QVERIFY(QFile::exists(m_tempDir->filePath(sessionsFileName)));
    QVERIFY(readUtf8File(m_tempDir->filePath(tasksFileName)).startsWith(QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n")));
    QVERIFY(readUtf8File(m_tempDir->filePath(sessionsFileName)).startsWith(QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n")));
}

void ServiceTests::exportFocusSessionsIgnoresInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("导出有效记录"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:02:59"),
                kTestMinimumValidDurationSeconds - 1) > 0);
    const int validSessionId = insertFocusSessionRowWithTimes(
        taskId,
        QStringLiteral("2026-06-10T08:10:00"),
        QStringLiteral("2026-06-10T08:13:00"),
        kTestMinimumValidDurationSeconds);
    QVERIFY(validSessionId > 0);

    const QString sessionsPath = m_tempDir->filePath(QStringLiteral("valid-sessions.csv"));
    QSignalSpy progressSpy(ExportService::instance(), &ExportService::exportProgress);

    QVERIFY(ExportService::instance()->exportFocusSessions(targetDate, targetDate, sessionsPath));

    QCOMPARE(progressSpy.count(), 1);
    QCOMPARE(progressSpy.last().at(0).toInt(), 1);
    QCOMPARE(progressSpy.last().at(1).toInt(), 1);
    QCOMPARE(readUtf8File(sessionsPath),
             QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n"
                            "%1,%2,导出有效记录,数学,2026-06-10 08:10:00,2026-06-10 08:13:00,3\n")
                 .arg(validSessionId)
                 .arg(taskId));
}

void ServiceTests::exportRejectsInvalidDateRangeAndUnwritablePath()
{
    QSignalSpy invalidDateSpy(ExportService::instance(), &ExportService::exportCompleted);
    const QString invalidDatePath = m_tempDir->filePath(QStringLiteral("invalid-date.csv"));

    QVERIFY(!ExportService::instance()->exportTasks(QDate(2026, 6, 11), QDate(2026, 6, 10), invalidDatePath));

    QCOMPARE(invalidDateSpy.count(), 1);
    QCOMPARE(invalidDateSpy.takeFirst().at(0).toBool(), false);
    QVERIFY(!QFile::exists(invalidDatePath));

    QSignalSpy unwritablePathSpy(ExportService::instance(), &ExportService::exportCompleted);
    const QString unwritablePath = m_tempDir->filePath(QStringLiteral("missing-dir/tasks.csv"));

    QVERIFY(!ExportService::instance()->exportTasks(QDate(2026, 6, 10), QDate(2026, 6, 10), unwritablePath));

    QCOMPARE(unwritablePathSpy.count(), 1);
    QCOMPARE(unwritablePathSpy.takeFirst().at(0).toBool(), false);
    QVERIFY(!QFile::exists(unwritablePath));
}

void ServiceTests::stopFocusCompletesTaskAfterFiveMinutes()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("五分钟任务"), logicalToday(), QString()));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("五分钟任务")));
    // 测试不应该真的等 5 分钟；这里直接推进内部累计秒数，只验证停止专注后的业务结果。
    FocusTimer::instance()->m_elapsedSeconds = 300;

    QSignalSpy tasksChangedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QVERIFY(FocusTimer::instance()->stopFocus());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), true);
    QVERIFY(tasksChangedSpy.count() >= 1);
}

void ServiceTests::stopFocusUnderFiveMinutesKeepsTaskPending()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("未满五分钟任务"), logicalToday(), QString()));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("未满五分钟任务")));
    FocusTimer::instance()->m_elapsedSeconds = 299;

    QVERIFY(FocusTimer::instance()->stopFocus());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), false);
}

void ServiceTests::stopFocusUnderThreeMinutesDiscardsInvalidSession()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("无效短专注"), logicalToday(), QString()));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("无效短专注")));
    FocusTimer::instance()->m_elapsedSeconds = kTestMinimumValidDurationSeconds - 1;

    QVERIFY(FocusTimer::instance()->stopFocus());

    QCOMPARE(countFocusSessions(), 0);
    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), false);
}

void ServiceTests::shortSessionEmitsSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("短会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("短会话任务")));
    timer->m_elapsedSeconds = 60;
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 1);
    QCOMPARE(discardSpy.takeFirst().at(0).toInt(), 60);
}

void ServiceTests::validSessionDoesNotEmitSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("有效会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("有效会话任务")));
    timer->m_elapsedSeconds = 300;
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 0);
}

void ServiceTests::focusTimerExposesRuleConstants()
{
    FocusTimer* timer = FocusTimer::instance();
    QCOMPARE(timer->minimumValidMinutes(), 3);
    QCOMPARE(timer->autoCompleteMinutes(), 5);
}

void ServiceTests::pomodoroWorkCompletionSavesSessionAndAutoCompletesTask()
{
    const int taskId = insertTaskRow(QStringLiteral("番茄专注任务"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QSignalSpy phaseCompletedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("番茄专注任务"), 300));
    QCOMPARE(FocusTimer::instance()->targetSeconds(), 300);
    FocusTimer::instance()->m_elapsedSeconds = 299;

    // 直接触发 timeout 信号，避免测试真实等待一秒；只验证状态机在边界秒的行为。
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(countFocusSessions(), 1);
    QCOMPARE(phaseCompletedSpy.count(), 1);

    QSqlQuery sessionQuery(DatabaseManager::instance()->database());
    QVERIFY(sessionQuery.exec(QStringLiteral("SELECT duration FROM focus_sessions")));
    QVERIFY(sessionQuery.next());
    QCOMPARE(sessionQuery.value(0).toInt(), 300);

    QCOMPARE(taskCompletedById(taskId), true);
}

void ServiceTests::pomodoroBreakWritesNoSessionAndCompletes()
{
    QSignalSpy phaseCompletedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);

    QVERIFY(FocusTimer::instance()->startBreak(5));
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
    QCOMPARE(FocusTimer::instance()->targetSeconds(), 5);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 5);
    FocusTimer::instance()->pauseFocus();
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    FocusTimer::instance()->m_elapsedSeconds = 4;

    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(phaseCompletedSpy.count(), 1);
}

void ServiceTests::pomodoroWorkStoppedUnderMinimumIsDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("番茄短专注"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("番茄短专注"), 300));
    FocusTimer::instance()->m_elapsedSeconds = kTestMinimumValidDurationSeconds - 1;

    QVERIFY(FocusTimer::instance()->stopFocus());

    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(taskCompletedById(taskId), false);
}

void ServiceTests::freeFocusStillCountsUpUnchanged()
{
    const int taskId = insertTaskRow(QStringLiteral("自由计时任务"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由计时任务")));
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);

    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 2);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);

    FocusTimer::instance()->m_elapsedSeconds = kTestMinimumValidDurationSeconds;
    QVERIFY(FocusTimer::instance()->stopFocus());
    QCOMPARE(countFocusSessions(), 1);
}

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"
