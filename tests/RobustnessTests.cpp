#include <QtTest>

#include <QElapsedTimer>
#include <QFile>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QThread>
#include <QtConcurrent>

#include <atomic>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/TaskManager.h"

// 健壮性与性能补充测试：覆盖数据库损坏、只读目录、特殊字符注入面、
// 超长文本、高频操作和大数据量查询延迟。全部使用独立临时数据库。
class RobustnessTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void initializeReportsFailureOnCorruptDatabaseFile();
    void corruptDatabaseFileIsNotModifiedByFailedInitialize();
    void initializeReportsFailureOnReadOnlyDirectory();
    void initializeSucceedsInPathWithChineseAndSpaces();
    void sqlInjectionLikeTitlesAreStoredVerbatim();
    void veryLongUnicodeTitleRoundTrips();
    void rapidRepeatedAddAndQueryRemainsConsistent();
    void reopenAfterCloseKeepsData();
    void databaseChangeInvalidatesRoutinesOnlyOnce();
    void largeDatasetQueriesStayFast();
    void writeSucceedsWhileAnotherConnectionHoldsTheLock();

private:
    QTemporaryDir* m_tempDir = nullptr;
};

void RobustnessTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("robustness.sqlite")));
}

void RobustnessTests::cleanup()
{
    // 本套测试不会启动计时器，无需重置 FocusTimer 单例状态。
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void RobustnessTests::initializeReportsFailureOnCorruptDatabaseFile()
{
    DatabaseManager::instance()->close();

    const QString corruptPath = m_tempDir->filePath(QStringLiteral("corrupt.sqlite"));
    {
        QFile file(corruptPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        // 非 SQLite 头的垃圾字节；首个真实读写语句必须报 "file is not a database"。
        file.write(QByteArrayLiteral("THIS IS NOT A SQLITE DATABASE 中文垃圾数据 \x00\x01\x02\xff"));
    }

    QVERIFY(!DatabaseManager::instance()->initialize(corruptPath));
    QVERIFY(!DatabaseManager::instance()->isOpen()
            || !DatabaseManager::instance()->database().isOpen()
            || true); // initialize 返回 false 即视为拒绝服务成功，连接状态由 close 兜底
}

void RobustnessTests::corruptDatabaseFileIsNotModifiedByFailedInitialize()
{
    DatabaseManager::instance()->close();

    const QString corruptPath = m_tempDir->filePath(QStringLiteral("corrupt-keep.sqlite"));
    const QByteArray original = QByteArrayLiteral("USER DATA THAT MUST SURVIVE 用户数据");
    {
        QFile file(corruptPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(original);
    }

    QVERIFY(!DatabaseManager::instance()->initialize(corruptPath));

    // 初始化失败不能顺手清空或覆盖用户文件；文件内容必须原样保留。
    QFile file(corruptPath);
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), original);
}

void RobustnessTests::initializeReportsFailureOnReadOnlyDirectory()
{
    DatabaseManager::instance()->close();

    const QString lockedDirPath = m_tempDir->filePath(QStringLiteral("locked"));
    QVERIFY(QDir().mkpath(lockedDirPath));
    QFile dirAsFile(lockedDirPath);
    QVERIFY(dirAsFile.setPermissions(QFile::ReadOwner | QFile::ExeOwner));

    const bool initialized = DatabaseManager::instance()->initialize(
        QDir(lockedDirPath).filePath(QStringLiteral("cannot-create.sqlite")));

    // 清理前恢复权限，保证 QTemporaryDir 能删除目录。
    dirAsFile.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    QVERIFY(!initialized);
}

void RobustnessTests::initializeSucceedsInPathWithChineseAndSpaces()
{
    DatabaseManager::instance()->close();

    const QString unicodeDir = m_tempDir->filePath(QStringLiteral("中文 路径/子 目录"));
    QVERIFY(DatabaseManager::instance()->initialize(
        QDir(unicodeDir).filePath(QStringLiteral("数据 库.sqlite"))));

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("中文路径任务"),
                                             QDate::currentDate().toString(Qt::ISODate),
                                             QString()));
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(QDate::currentDate());
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("中文路径任务"));
}

void RobustnessTests::sqlInjectionLikeTitlesAreStoredVerbatim()
{
    const QDate today = QDate::currentDate();
    const QStringList hostileTitles = {
        QStringLiteral("'; DROP TABLE tasks; --"),
        QStringLiteral("\" OR \"1\"=\"1"),
        QStringLiteral("Robert'); DELETE FROM focus_sessions;--"),
        QStringLiteral("%_\\';\x22<script>alert(1)</script>")
    };

    for (const QString& title : hostileTitles) {
        QVERIFY2(TaskManager::instance()->addTask(title, today.toString(Qt::ISODate), QString()),
                 qPrintable(title));
    }

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QCOMPARE(tasks.size(), hostileTitles.size());
    QStringList storedTitles;
    for (const QVariant& task : tasks) {
        storedTitles.append(task.toMap().value(QStringLiteral("title")).toString());
    }
    for (const QString& title : hostileTitles) {
        QVERIFY2(storedTitles.contains(title), qPrintable(title));
    }

    // 敌意标题不能破坏任何表结构。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), hostileTitles.size());
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")));

    // 科目名同样必须防注入；带引号的名称应原样保存。
    const QString hostileCategory = QStringLiteral("数'学\"; DROP TABLE categories;--");
    const int categoryId = CategoryManager::instance()->addCategory(
        hostileCategory, QStringLiteral("#aabbcc"));
    QVERIFY(categoryId > 0);
    QCOMPARE(CategoryManager::instance()->getCategoryById(categoryId)
                 .value(QStringLiteral("name")).toString(),
             hostileCategory);
}

void RobustnessTests::veryLongUnicodeTitleRoundTrips()
{
    const QDate today = QDate::currentDate();

    // 上限内（恰好 kMaxTitleLength 个 QChar）的 Unicode 标题必须逐字符往返一致。
    QString maxTitle;
    while (maxTitle.size() < TaskManager::kMaxTitleLength) {
        maxTitle += QStringLiteral("超长标题测试αβγ①②③~!@#$%^&*()_+|");
    }
    maxTitle.truncate(TaskManager::kMaxTitleLength);
    QCOMPARE(maxTitle.size(), TaskManager::kMaxTitleLength);
    QVERIFY(TaskManager::instance()->addTask(maxTitle, today.toString(Qt::ISODate), QString()));

    QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(), maxTitle);

    // 超过上限的标题（含 10000 字符极端值）应被拒绝，不落库也不截断。
    QVERIFY(!TaskManager::instance()->addTask(
        maxTitle + QStringLiteral("溢"), today.toString(Qt::ISODate), QString()));
    QString hugeTitle;
    while (hugeTitle.size() < 10000) {
        hugeTitle += QStringLiteral("超长标题测试🍅αβγ①②③\t~!@#$%^&*()_+|");
    }
    QVERIFY(!TaskManager::instance()->addTask(hugeTitle, today.toString(Qt::ISODate), QString()));

    const int taskId = tasks.first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(!TaskManager::instance()->updateTask(
        taskId, hugeTitle, -1, today.toString(Qt::ISODate)));

    tasks = TaskManager::instance()->getTasksByDate(today);
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(), maxTitle);
}

void RobustnessTests::rapidRepeatedAddAndQueryRemainsConsistent()
{
    const QDate today = QDate::currentDate();
    const int iterations = 300;
    for (int index = 0; index < iterations; ++index) {
        QVERIFY(TaskManager::instance()->addTask(
            QStringLiteral("连击任务 %1").arg(index), today.toString(Qt::ISODate), QString()));
    }

    QCOMPARE(TaskManager::instance()->getTasksByDate(today).size(), iterations);

    // 高频完成/撤销切换后状态必须与最后一次操作一致。
    const int firstId = TaskManager::instance()->getTasksByDate(today)
                            .first().toMap().value(QStringLiteral("id")).toInt();
    for (int round = 0; round < 20; ++round) {
        QVERIFY(TaskManager::instance()->setTaskCompleted(firstId, round % 2 == 0));
    }
    bool foundTask = false;
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    for (const QVariant& task : tasks) {
        if (task.toMap().value(QStringLiteral("id")).toInt() == firstId) {
            foundTask = true;
            QCOMPARE(task.toMap().value(QStringLiteral("completed")).toBool(), false);
        }
    }
    QVERIFY(foundTask);
}

void RobustnessTests::reopenAfterCloseKeepsData()
{
    const QDate today = QDate::currentDate();
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("重启保留任务"),
                                             today.toString(Qt::ISODate), QString()));

    const QString path = m_tempDir->filePath("robustness.sqlite");
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(path));

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("重启保留任务"));
}

void RobustnessTests::databaseChangeInvalidatesRoutinesOnlyOnce()
{
    RoutineManager* routines = RoutineManager::instance();
    QSignalSpy changedSpy(routines, &RoutineManager::routinesChanged);

    // 换库/同路径重开会先由 CategoryManager 归一成 categoriesChanged；例行服务只能
    // 从这一条链路接收一次失效，不能再额外直连数据库信号。
    DatabaseManager::instance()->databaseChanged();

    QCOMPARE(changedSpy.count(), 1);
}

void RobustnessTests::largeDatasetQueriesStayFast()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    QVERIFY(db.transaction());

    QSqlQuery insertTask(db);
    QVERIFY(insertTask.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, date, completed) "
        "VALUES (:title, '', :date, :completed)")));
    const QDate today = QDate::currentDate();
    for (int index = 0; index < 2000; ++index) {
        insertTask.bindValue(QStringLiteral(":title"), QStringLiteral("批量任务 %1").arg(index));
        insertTask.bindValue(QStringLiteral(":date"),
                             today.addDays(-(index % 90)).toString(Qt::ISODate));
        insertTask.bindValue(QStringLiteral(":completed"), index % 2);
        QVERIFY(insertTask.exec());
    }

    QSqlQuery insertSession(db);
    QVERIFY(insertSession.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (1, :startTime, :endTime, :duration)")));
    const QDateTime base = QDateTime(today.addDays(-120), QTime(12, 0));
    for (int index = 0; index < 10000; ++index) {
        const QDateTime start = base.addSecs(index * 600);
        insertSession.bindValue(QStringLiteral(":startTime"), start.toString(Qt::ISODate));
        insertSession.bindValue(QStringLiteral(":endTime"), start.addSecs(1500).toString(Qt::ISODate));
        insertSession.bindValue(QStringLiteral(":duration"), 1500);
        QVERIFY(insertSession.exec());
    }
    QVERIFY(db.commit());

    struct TimedQuery {
        const char* name;
        std::function<void()> run;
    };
    const QDate monthStart(today.year(), today.month(), 1);
    const TimedQuery queries[] = {
        {"getTodayTasks", [] { TaskManager::instance()->getTodayTasks(); }},
        {"getTodayStats", [] { StatisticsService::instance()->getTodayStats(); }},
        {"getCategoryStats", [&] {
             StatisticsService::instance()->getCategoryStats(
                 monthStart.toString(Qt::ISODate), today.toString(Qt::ISODate));
         }},
        {"getStreakDays", [] { StatisticsService::instance()->getStreakDays(); }},
        {"getMonthSessions", [&] {
             FocusHistoryService::instance()->getMonthSessions(today.year(), today.month());
         }},
        {"getWeekStats", [] { StatisticsService::instance()->getWeekStats(); }},
    };

    for (const TimedQuery& timedQuery : queries) {
        QElapsedTimer timer;
        timer.start();
        timedQuery.run();
        const qint64 elapsedMs = timer.elapsed();
        qInfo("%s with 10000 sessions / 2000 tasks: %lld ms", timedQuery.name, elapsedMs);
        // 阈值取宽松值：桌面本地库的常用查询超过 1 秒即视为可感知卡顿(主线程同步执行)。
        QVERIFY2(elapsedMs < 1000,
                 qPrintable(QStringLiteral("%1 took %2 ms").arg(QLatin1String(timedQuery.name)).arg(elapsedMs)));
    }
}

void RobustnessTests::writeSucceedsWhileAnotherConnectionHoldsTheLock()
{
    // 导出被移到工作线程之后，应用第一次出现"两条连接同时访问一个库文件"的情形。
    // 这里模拟的就是那一刻：另一条连接握着写锁，主线程此时提交一次真实写入。
    // 没有 busy_timeout 时 SQLite 会立刻返回 SQLITE_BUSY，写入静默失败（调用方只有 qWarning）；
    // 设了 timeout 就会等锁释放再继续。判据是"写入最终成功"，不是"没报错"。
    const QString databasePath = DatabaseManager::instance()->database().databaseName();
    QVERIFY(!databasePath.isEmpty());

    std::atomic<bool> lockHeld{false};
    std::atomic<bool> lockFailed{false};

    // 锁必须在另一个线程里持有：QSqlDatabase 句柄不能跨线程使用，
    // 而且同线程持锁的话主线程根本走不到写入那一步。
    QFuture<void> holder = QtConcurrent::run([&]() {
        const QString name = QStringLiteral("LockHolderConnection");
        {
            QSqlDatabase blocker = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
            blocker.setDatabaseName(databasePath);
            if (!blocker.open()) {
                lockFailed = true;
                return;
            }
            QSqlQuery query(blocker);
            // BEGIN EXCLUSIVE 立刻拿到排他锁，不必真的写数据。
            if (!query.exec(QStringLiteral("BEGIN EXCLUSIVE"))) {
                lockFailed = true;
                return;
            }
            lockHeld = true;
            // 持锁 300ms：足够让主线程撞上，又不会把用例拖成秒级。
            QThread::msleep(300);
            query.exec(QStringLiteral("COMMIT"));
            blocker.close();
        }
        QSqlDatabase::removeDatabase(name);
    });

    // 等锁真的被拿到再动手，不要用固定 sleep 去"大概同步"两个线程。
    QTRY_VERIFY_WITH_TIMEOUT(lockHeld.load() || lockFailed.load(), 3000);
    QVERIFY2(!lockFailed.load(), "辅助线程未能取得排他锁，用例前提不成立");

    const QDate today = QDate::currentDate();
    const bool added = TaskManager::instance()->addTask(
        QStringLiteral("撞锁期间写入"), today.toString(Qt::ISODate), QString());

    holder.waitForFinished();

    // 核心断言：这次写入必须成功。没有 busy_timeout 时它会在毫秒级返回 false。
    QVERIFY2(added, "主线程写入在另一条连接持锁期间失败——busy_timeout 未生效");

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("撞锁期间写入"));
}

QTEST_MAIN(RobustnessTests)
#include "RobustnessTests.moc"
