#include <QCoreApplication>
#include <QDate>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/TaskManager.h"

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
    insert.prepare("INSERT INTO focus_sessions (task_id, start_time, end_time, duration) VALUES (?, datetime('now'), datetime('now'), 1200)");
    insert.addBindValue(taskId);
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
    QVERIFY(insert.exec("INSERT INTO focus_sessions (task_id, start_time, end_time, duration) VALUES (NULL, datetime('now'), datetime('now'), 1800)"));

    const QVariantMap stats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(stats.value("totalDuration").toInt(), 1800);
    QCOMPARE(stats.value("completedTasks").toInt(), 1);
    QCOMPARE(stats.value("totalTasks").toInt(), 2);
    QCOMPARE(stats.value("completionRate").toDouble(), 0.5);
}

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"
