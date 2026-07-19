#include <QtTest>

#include <QDate>
#include <QDir>
#include <QFile>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "../src/models/CountdownGoal.h"
#include "../src/models/CountdownModel.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/FocusTimer.h"
#include "../src/services/TaskManager.h"

// 核心逻辑补充测试：填补既有套件的覆盖缺口——纯模型边界、输入校验矩阵、
// 不存在数据与重复操作、备份清理策略和 databaseChanged 信号契约。
// 每个用例使用独立临时数据库，不依赖执行顺序。
class CoreLogicTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    // —— CountdownModel：纯模型边界（不触库）——
    void countdownModelRejectsOutOfRangeAccess();
    void countdownModelSignalsRowInsertUpdateRemove();
    void countdownModelMoveGoalValidatesIndexes();
    void countdownModelReferenceDateChangeSignalsDaysRemainingOnly();

    // —— DatabaseManager ——
    void databaseChangedSignalFiresOnEveryInitialize();
    void migrationBackupsArePrunedToThree();

    // —— CategoryManager：输入校验矩阵与重复数据 ——
    void categoryColorValidationMatrix();
    void categoryDuplicateNameRejectedAfterTrim();

    // —— TaskManager：不存在的数据与重复操作 ——
    void taskOperationsOnMissingIdReturnFalse();
    void repeatedTaskCompletionIsIdempotent();

    // —— FocusTimer：入参校验与重复启动 ——
    void focusTimerRejectsInvalidStartParameters();
    void focusTimerRejectsSecondSessionAndKeepsState();
    void resumeWithoutSessionFails();

    // —— FocusHistoryService：时长文案边界 ——
    void formatDurationBoundaries();

    // —— CountdownService：名称长度边界与重复语义 ——
    void countdownGoalNameLengthBoundary();
    void countdownDuplicateGoalNamesAreAllowed();

private:
    int addTaskAndFetchId(const QString& title);

    QTemporaryDir* m_tempDir = nullptr;
};

void CoreLogicTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("core-logic.sqlite")));
}

void CoreLogicTests::cleanup()
{
    // FocusTimer 是进程级单例；用公开 API 结束会话（短会话走丢弃路径），
    // 保证下一个用例从干净状态开始，也不依赖用例执行顺序。
    FocusTimer::instance()->stopFocus();
    FocusTimer::instance()->resetPomodoroCount();
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

int CoreLogicTests::addTaskAndFetchId(const QString& title)
{
    if (!TaskManager::instance()->addTask(title, QDate::currentDate().toString(Qt::ISODate),
                                          QString())) {
        return -1;
    }
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(QDate::currentDate());
    for (const QVariant& task : tasks) {
        if (task.toMap().value(QStringLiteral("title")).toString() == title) {
            return task.toMap().value(QStringLiteral("id")).toInt();
        }
    }
    return -1;
}

void CoreLogicTests::countdownModelRejectsOutOfRangeAccess()
{
    CountdownModel model;

    // 空模型：任何行访问都返回空值，不崩溃。
    QCOMPARE(model.rowCount(), 0);
    QVERIFY(!model.data(QModelIndex(), CountdownModel::NameRole).isValid());
    QVERIFY(!model.data(model.index(0), CountdownModel::NameRole).isValid());
    QVERIFY(!model.data(model.index(-1), CountdownModel::NameRole).isValid());

    model.addGoal(CountdownGoal(1, QStringLiteral("目标"), QDate::currentDate().addDays(3),
                                0, QDateTime::currentDateTime(), QDateTime::currentDateTime()));

    // 树形父索引下必须报 0 行，未知 role 返回空值。
    QCOMPARE(model.rowCount(model.index(0)), 0);
    QVERIFY(!model.data(model.index(0), Qt::UserRole + 99).isValid());
    QCOMPARE(model.data(model.index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("目标"));
}

void CoreLogicTests::countdownModelSignalsRowInsertUpdateRemove()
{
    CountdownModel model;
    QSignalSpy insertSpy(&model, &QAbstractItemModel::rowsInserted);
    QSignalSpy removeSpy(&model, &QAbstractItemModel::rowsRemoved);
    QSignalSpy dataSpy(&model, &QAbstractItemModel::dataChanged);

    const CountdownGoal goal(7, QStringLiteral("考试"), QDate::currentDate().addDays(30),
                             0, QDateTime::currentDateTime(), QDateTime::currentDateTime());
    model.addGoal(goal);
    QCOMPARE(insertSpy.count(), 1);

    // 越界 update/remove 是无操作：不发信号、不崩溃。
    model.updateGoal(5, goal);
    model.updateGoal(-1, goal);
    model.removeGoal(5);
    model.removeGoal(-1);
    QCOMPARE(dataSpy.count(), 0);
    QCOMPARE(removeSpy.count(), 0);
    QCOMPARE(model.rowCount(), 1);

    CountdownGoal renamed = goal;
    renamed.setName(QStringLiteral("考试改"));
    model.updateGoal(0, renamed);
    QCOMPARE(dataSpy.count(), 1);
    QCOMPARE(model.data(model.index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("考试改"));

    model.removeGoal(0);
    QCOMPARE(removeSpy.count(), 1);
    QCOMPARE(model.rowCount(), 0);
}

void CoreLogicTests::countdownModelMoveGoalValidatesIndexes()
{
    CountdownModel model;
    for (int i = 0; i < 3; ++i) {
        model.addGoal(CountdownGoal(i + 1, QStringLiteral("G%1").arg(i),
                                    QDate::currentDate().addDays(i + 1), i,
                                    QDateTime::currentDateTime(), QDateTime::currentDateTime()));
    }

    QSignalSpy moveSpy(&model, &QAbstractItemModel::rowsMoved);

    // 越界与原地移动都是无操作。
    model.moveGoal(-1, 1);
    model.moveGoal(0, 3);
    model.moveGoal(1, 1);
    QCOMPARE(moveSpy.count(), 0);

    // 向后移动：QAbstractItemModel 的 destinationChild 语义由模型内部换算。
    model.moveGoal(0, 2);
    QCOMPARE(moveSpy.count(), 1);
    QCOMPARE(model.data(model.index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("G1"));
    QCOMPARE(model.data(model.index(2), CountdownModel::NameRole).toString(),
             QStringLiteral("G0"));

    // 向前移动回原位。
    model.moveGoal(2, 0);
    QCOMPARE(moveSpy.count(), 2);
    QCOMPARE(model.data(model.index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("G0"));
}

void CoreLogicTests::countdownModelReferenceDateChangeSignalsDaysRemainingOnly()
{
    CountdownModel model;
    model.addGoal(CountdownGoal(1, QStringLiteral("目标"), QDate::currentDate().addDays(10),
                                0, QDateTime::currentDateTime(), QDateTime::currentDateTime()));
    model.setReferenceDate(QDate::currentDate());
    QCOMPARE(model.data(model.index(0), CountdownModel::DaysRemainingRole).toInt(), 10);

    QSignalSpy dataSpy(&model, &QAbstractItemModel::dataChanged);

    // 相同基准日不发信号。
    model.setReferenceDate(QDate::currentDate());
    QCOMPARE(dataSpy.count(), 0);

    // 基准日推进一天：只影响剩余天数角色。
    model.setReferenceDate(QDate::currentDate().addDays(1));
    QCOMPARE(dataSpy.count(), 1);
    const QVector<int> roles = dataSpy.takeFirst().at(2).value<QVector<int>>();
    QCOMPARE(roles, QVector<int>{CountdownModel::DaysRemainingRole});
    QCOMPARE(model.data(model.index(0), CountdownModel::DaysRemainingRole).toInt(), 9);
}

void CoreLogicTests::databaseChangedSignalFiresOnEveryInitialize()
{
    QSignalSpy changedSpy(DatabaseManager::instance(), &DatabaseManager::databaseChanged);

    // 同一已打开路径重复 initialize（早退分支）也必须发信号：
    // 缓存模型的服务依赖它判断“数据可能被重建”。
    const QString samePath = m_tempDir->filePath("core-logic.sqlite");
    QVERIFY(DatabaseManager::instance()->initialize(samePath));
    QCOMPARE(changedSpy.count(), 1);

    // 换库路径。
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("other.sqlite")));
    QCOMPARE(changedSpy.count(), 2);

    // 初始化失败不发信号。
    DatabaseManager::instance()->close();
    const QString corruptPath = m_tempDir->filePath("corrupt.sqlite");
    {
        QFile file(corruptPath);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(QByteArrayLiteral("NOT A DATABASE"));
    }
    QVERIFY(!DatabaseManager::instance()->initialize(corruptPath));
    QCOMPARE(changedSpy.count(), 2);
}

void CoreLogicTests::migrationBackupsArePrunedToThree()
{
    DatabaseManager::instance()->close();

    // 预置 5 份仿造的历史备份；随后的全新建库会走 v2..v6 迁移链并逐次清理。
    const QDir dir(m_tempDir->path());
    for (int i = 0; i < 5; ++i) {
        QFile fake(dir.filePath(QStringLiteral("pomodoro_backup_2020010%1_000000_000.db").arg(i)));
        QVERIFY(fake.open(QIODevice::WriteOnly));
        fake.write("legacy backup");
        fake.close();
    }

    QVERIFY(DatabaseManager::instance()->initialize(dir.filePath(QStringLiteral("pruned.sqlite"))));

    const QStringList backups = dir.entryList(
        QStringList{QStringLiteral("pomodoro_backup_*.db")}, QDir::Files);
    // 清理策略：任何时刻最多保留最近 3 份迁移备份，防止数据目录被悄悄塞满。
    QCOMPARE(backups.size(), 3);
}

void CoreLogicTests::categoryColorValidationMatrix()
{
    CategoryManager* manager = CategoryManager::instance();

    const QStringList invalidColors = {
        QStringLiteral(""),          // 空
        QStringLiteral("d4a574"),    // 缺 #
        QStringLiteral("#abc"),      // 三位缩写不接受
        QStringLiteral("#abcde"),    // 少一位
        QStringLiteral("#abcdef1"),  // 多一位
        QStringLiteral("#abcdeg"),   // 非法十六进制字符
        QStringLiteral("rgb(1,2,3)")
    };
    for (int i = 0; i < invalidColors.size(); ++i) {
        QCOMPARE(manager->addCategory(QStringLiteral("非法色%1").arg(i), invalidColors.at(i)), -1);
    }

    // 合法：大小写混合的 6 位十六进制，允许首尾空白（入库前 trim）。
    const int id = manager->addCategory(QStringLiteral("合法色"), QStringLiteral("  #AbCdEf  "));
    QVERIFY(id > 0);
    QCOMPARE(manager->getCategoryById(id).value(QStringLiteral("color")).toString(),
             QStringLiteral("#AbCdEf"));
}

void CoreLogicTests::categoryDuplicateNameRejectedAfterTrim()
{
    CategoryManager* manager = CategoryManager::instance();
    QSignalSpy changedSpy(manager, &CategoryManager::categoriesChanged);

    const int id = manager->addCategory(QStringLiteral("高数"), QStringLiteral("#112233"));
    QVERIFY(id > 0);
    QCOMPARE(changedSpy.count(), 1);

    // 名称重复（含首尾空白变体）必须拒绝，且不发变更信号。
    QCOMPARE(manager->addCategory(QStringLiteral("高数"), QStringLiteral("#445566")), -1);
    QCOMPARE(manager->addCategory(QStringLiteral("  高数  "), QStringLiteral("#445566")), -1);
    QCOMPARE(changedSpy.count(), 1);

    // 与预置科目重名同样拒绝。
    QCOMPARE(manager->addCategory(QStringLiteral("数学"), QStringLiteral("#445566")), -1);
}

void CoreLogicTests::taskOperationsOnMissingIdReturnFalse()
{
    TaskManager* manager = TaskManager::instance();
    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);

    // 合法但不存在的 id：完成/更新/删除都返回 false 且不发假信号。
    QVERIFY(!manager->completeTask(424242));
    QVERIFY(!manager->setTaskCompleted(424242, false));
    QVERIFY(!manager->updateTask(424242, QStringLiteral("改名"), -1,
                                 QDate::currentDate().toString(Qt::ISODate)));
    QVERIFY(!manager->deleteTask(424242));
    QCOMPARE(changedSpy.count(), 0);

    // 批量结转遇到不存在的 id 必须整体失败（全成或全不成）。
    const int realId = addTaskAndFetchId(QStringLiteral("结转任务"));
    QVERIFY(realId > 0);
    QVERIFY(!manager->moveTasksToToday(QVariantList{realId, 424242}));
}

void CoreLogicTests::repeatedTaskCompletionIsIdempotent()
{
    TaskManager* manager = TaskManager::instance();
    const int taskId = addTaskAndFetchId(QStringLiteral("重复完成任务"));
    QVERIFY(taskId > 0);

    // 重复标记完成是幂等操作：两次都成功，终态仍是已完成。
    QVERIFY(manager->completeTask(taskId));
    QVERIFY(manager->completeTask(taskId));

    QVariantList tasks = manager->getTasksByDate(QDate::currentDate());
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("completed")).toBool(), true);

    // 撤销完成同样幂等。
    QVERIFY(manager->setTaskCompleted(taskId, false));
    QVERIFY(manager->setTaskCompleted(taskId, false));
    tasks = manager->getTasksByDate(QDate::currentDate());
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("completed")).toBool(), false);
}

void CoreLogicTests::focusTimerRejectsInvalidStartParameters()
{
    FocusTimer* timer = FocusTimer::instance();

    QVERIFY(!timer->startFocus(0, QStringLiteral("任务")));
    QVERIFY(!timer->startFocus(-3, QStringLiteral("任务")));
    QVERIFY(!timer->startFocus(1, QStringLiteral("   ")));
    QVERIFY(!timer->startPomodoroWork(1, QStringLiteral("任务"), 0));
    QVERIFY(!timer->startPomodoroWork(1, QStringLiteral("任务"), -60));
    QVERIFY(!timer->startBreak(0));
    QVERIFY(!timer->startBreakForTask(-1, 1, QStringLiteral("任务")));

    // 全部拒绝后计时器保持待机。
    QCOMPARE(timer->hasActiveSession(), false);
    QCOMPARE(timer->isRunning(), false);
    QCOMPARE(timer->phase(), int(FocusTimer::NoPhase));
}

void CoreLogicTests::focusTimerRejectsSecondSessionAndKeepsState()
{
    FocusTimer* timer = FocusTimer::instance();
    const int taskId = addTaskAndFetchId(QStringLiteral("专注任务"));
    QVERIFY(taskId > 0);

    QSignalSpy runningSpy(timer, &FocusTimer::runningStateChanged);
    QVERIFY(timer->startFocus(taskId, QStringLiteral("专注任务")));
    QCOMPARE(runningSpy.count(), 1);

    // 会话进行中重复启动（含休息）一律拒绝，且不产生多余的状态信号。
    QVERIFY(!timer->startFocus(taskId, QStringLiteral("专注任务")));
    QVERIFY(!timer->startPomodoroWork(taskId, QStringLiteral("专注任务"), 25 * 60));
    QVERIFY(!timer->startBreak(5 * 60));
    QCOMPARE(runningSpy.count(), 1);
    QCOMPARE(timer->currentTaskId(), taskId);
    QCOMPARE(timer->isRunning(), true);

    // 数据库层同样只有一条进行中的会话。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NULL")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 1);
}

void CoreLogicTests::resumeWithoutSessionFails()
{
    FocusTimer* timer = FocusTimer::instance();
    QCOMPARE(timer->hasActiveSession(), false);
    QVERIFY(!timer->resumeFocus());
    QCOMPARE(timer->isRunning(), false);
}

void CoreLogicTests::formatDurationBoundaries()
{
    FocusHistoryService* service = FocusHistoryService::instance();

    QCOMPARE(service->formatDuration(0), QStringLiteral("0分钟"));
    QCOMPARE(service->formatDuration(-5), QStringLiteral("0分钟"));
    QCOMPARE(service->formatDuration(59), QStringLiteral("0分钟"));
    QCOMPARE(service->formatDuration(60), QStringLiteral("1分钟"));
    QCOMPARE(service->formatDuration(3599), QStringLiteral("59分钟"));
    QCOMPARE(service->formatDuration(3600), QStringLiteral("1小时"));
    QCOMPARE(service->formatDuration(3660), QStringLiteral("1小时1分"));
    QCOMPARE(service->formatDuration(7325), QStringLiteral("2小时2分"));
}

void CoreLogicTests::countdownGoalNameLengthBoundary()
{
    CountdownService* service = CountdownService::instance();
    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);

    // 恰好 50 字符（trim 后）允许。
    const QString name50(50, QChar(u'考'));
    QVERIFY(service->addGoal(QStringLiteral("  ") + name50 + QStringLiteral("  "),
                             QDate::currentDate().addDays(30)));
    QCOMPARE(errorSpy.count(), 0);

    // 51 字符拒绝并带用户可读错误。
    const QString name51(51, QChar(u'考'));
    QVERIFY(!service->addGoal(name51, QDate::currentDate().addDays(30)));
    QCOMPARE(errorSpy.count(), 1);

    // 无效日期同样拒绝。
    QVERIFY(!service->addGoal(QStringLiteral("目标"), QDate()));
    QCOMPARE(errorSpy.count(), 2);
}

void CoreLogicTests::countdownDuplicateGoalNamesAreAllowed()
{
    CountdownService* service = CountdownService::instance();

    // 现行规格：目标名不设唯一约束（同名考试的不同轮次是合理场景），
    // 两条都应入库并保持独立的 display_order。
    QVERIFY(service->addGoal(QStringLiteral("期末考"), QDate::currentDate().addDays(10)));
    QVERIFY(service->addGoal(QStringLiteral("期末考"), QDate::currentDate().addDays(40)));
    QCOMPARE(service->model()->rowCount(), 2);
    QCOMPARE(service->model()->data(service->model()->index(0),
                                    CountdownModel::DisplayOrderRole).toInt(), 0);
    QCOMPARE(service->model()->data(service->model()->index(1),
                                    CountdownModel::DisplayOrderRole).toInt(), 1);
}

QTEST_MAIN(CoreLogicTests)
#include "CoreLogicTests.moc"
