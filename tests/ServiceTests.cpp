#include <QCoreApplication>
#include <QDate>
#include <QSqlError>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/DatabaseManager.h"
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
    QCOMPARE(task.value("category").toString(), QString("数据结构"));
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
    QCOMPARE(math.value(QStringLiteral("duration")).toInt(), 1800);
    QCOMPARE(math.value(QStringLiteral("percentage")).toDouble(), 75.0);

    const QVariantMap english = categories.at(1).toMap();
    QCOMPARE(english.value(QStringLiteral("name")).toString(), QString("英语"));
    QCOMPARE(english.value(QStringLiteral("duration")).toInt(), 600);
    QCOMPARE(english.value(QStringLiteral("percentage")).toDouble(), 25.0);
}

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"
