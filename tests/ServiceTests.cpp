#include <QCoreApplication>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/ExportService.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/TaskManager.h"

namespace {
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

int insertTaskRowWithCategoryId(const QString& title,
                                const QDate& date,
                                int categoryId,
                                const QString& legacyCategory,
                                bool completed,
                                const QString& createdAt)
{
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

QStringList taskTitles(const QVariantList& tasks)
{
    QStringList titles;
    for (const QVariant& taskValue : tasks) {
        titles.append(taskValue.toMap().value(QStringLiteral("title")).toString());
    }
    return titles;
}
}

class ServiceTests : public QObject {
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void addTaskRejectsBlankTitle();
    void addTaskPersistsTrimmedTitleAndEmitsChange();
    void addTaskAcceptsIsoDateStringFromQml();
    void deleteTaskPreservesFocusSessionHistory();
    void statisticsReturnsTodayCompletionAndDuration();
    void getWeekStatsUsesCurrentNaturalWeek();
    void getWeekTasksReturnsInclusiveRangeAndRequiredOrder();
    void getMonthTasksReturnsInclusiveMonthRange();
    void getMonthTasksRejectsInvalidMonth();
    void getCategoryStatsAggregatesDurationsAndPercentages();
    void freshDatabaseCreatesVersion2PresetCategories();
    void migrationMapsLegacyCategoryTextToCategoryIds();
    void migrationCreatesDatabaseBackup();
    void customCategoryCrudValidatesAndEmitsChanges();
    void presetCategoriesCannotBeEditedOrDeleted();
    void associatedCategoryCannotBeDeleted();
    void legacyTextCategoryAssociationPreventsDeletion();
    void taskManagerReturnsFullCategoryInfo();
    void legacyAddTaskWithTextCategoryRemainsCompatible();
    void exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks();
    void exportFocusSessionsAndExportAllWriteExpectedCsvFiles();
    void exportRejectsInvalidDateRangeAndUnwritablePath();

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
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void ServiceTests::addTaskRejectsBlankTitle()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(!TaskManager::instance()->addTask("   ", QVariant(QDate::currentDate()), "数学"));

    QCOMPARE(spy.count(), 0);
    QCOMPARE(TaskManager::instance()->getTodayTasks().size(), 0);
}

void ServiceTests::addTaskPersistsTrimmedTitleAndEmitsChange()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(TaskManager::instance()->addTask("  数据结构第三章  ", QVariant(QDate::currentDate()), "数据结构"));

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
    const QString today = QDate::currentDate().toString(Qt::ISODate);

    QVERIFY(TaskManager::instance()->addTask("政治选择题", today, "政治"));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value("title").toString(), QString("政治选择题"));
}

void ServiceTests::deleteTaskPreservesFocusSessionHistory()
{
    QVERIFY(TaskManager::instance()->addTask("操作系统真题", QVariant(QDate::currentDate()), "操作系统"));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value("id").toInt();

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, 1200)"));
    insert.bindValue(QStringLiteral(":taskId"), taskId);
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(QDate::currentDate()));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(QDate::currentDate(), QStringLiteral("12:30:00")));
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
    QVERIFY(TaskManager::instance()->addTask("英语阅读", QVariant(QDate::currentDate()), "英语"));
    QVERIFY(TaskManager::instance()->addTask("数学错题", QVariant(QDate::currentDate()), "数学"));
    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QVERIFY(TaskManager::instance()->completeTask(tasks.first().toMap().value("id").toInt()));

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (NULL, :startTime, :endTime, 1800)"));
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(QDate::currentDate()));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(QDate::currentDate(), QStringLiteral("12:30:00")));
    QVERIFY(insert.exec());

    const QVariantMap stats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(stats.value("totalDuration").toInt(), 1800);
    QCOMPARE(stats.value("completedTasks").toInt(), 1);
    QCOMPARE(stats.value("totalTasks").toInt(), 2);
    QCOMPARE(stats.value("completionRate").toDouble(), 0.5);
}

void ServiceTests::getWeekStatsUsesCurrentNaturalWeek()
{
    const QDate today = QDate::currentDate();
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
    QCOMPARE(totalDuration, 360);
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

void ServiceTests::freshDatabaseCreatesVersion2PresetCategories()
{
    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), 2);

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
    QCOMPARE(versionQuery.value(0).toInt(), 2);

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

void ServiceTests::associatedCategoryCannotBeDeleted()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("408"), QStringLiteral("#abcdef"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("计组错题"), QVariant(QDate::currentDate()), categoryId));

    QVERIFY(!manager->canDeleteCategory(categoryId));
    QTest::ignoreMessage(QtWarningMsg, "Failed to delete category: category has associated tasks");
    QVERIFY(!manager->deleteCategory(categoryId));
    QVERIFY(!manager->getCategoryById(categoryId).isEmpty());
}

void ServiceTests::legacyTextCategoryAssociationPreventsDeletion()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("网络原理"), QStringLiteral("#778899"));
    QVERIFY(categoryId > 0);
    QVERIFY(insertTaskRowWithCategoryId(
                QStringLiteral("旧文本任务"),
                QDate::currentDate(),
                -1,
                QStringLiteral("网络原理"),
                false,
                dateTimeText(QDate::currentDate())) > 0);

    QVERIFY(!manager->canDeleteCategory(categoryId));
    QTest::ignoreMessage(QtWarningMsg, "Failed to delete category: category has associated tasks");
    QVERIFY(!manager->deleteCategory(categoryId));
    QVERIFY(!manager->getCategoryById(categoryId).isEmpty());
}

void ServiceTests::taskManagerReturnsFullCategoryInfo()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("数据结构"), QStringLiteral("#123abc"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("图论专题"), QVariant(QDate::currentDate()), categoryId));

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

void ServiceTests::legacyAddTaskWithTextCategoryRemainsCompatible()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("政治选择题"), QVariant(QDate::currentDate()), QStringLiteral("政治")));

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

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"
