#include <QCoreApplication>
#include <QDate>
#include <QFile>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>
#include <QVariantMap>

#include "../src/services/AppSettings.h"
#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LogicalDay.h"

namespace {
QString nameAt(CountdownModel* model, int row)
{
    return model->data(model->index(row), CountdownModel::NameRole).toString();
}

int goalIdAt(CountdownModel* model, int row)
{
    return model->data(model->index(row), CountdownModel::IdRole).toInt();
}

bool isEmptyPrimaryGoal(const QVariant& value)
{
    // primaryGoal 需要给 QML 读取；空状态允许是无效 QVariant，也允许是空 map。
    return !value.isValid() || value.toMap().isEmpty();
}
}

class CountdownServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void addGoalPersistsTrimmedNameAndUsesMaxDisplayOrder();
    void rejectsInvalidNamesAndDates();
    void updateGoalValidatesAndUpdatesExistingGoal();
    void updateGoalIgnoredWriteKeepsModelUnchanged();
    void updateGoalChangesWritesOnlyGivenFields();
    void deleteGoalRemovesModelDatabaseAndRefreshesPrimary();
    void reorderMovesModelPersistsOrdersAndRefreshesPrimary();
    void reorderFailureKeepsOriginalModelOrder();
    void reorderIgnoredUpdateKeepsOriginalModelOrder();
    void reloadFailurePreservesModelAndRecoveryEmitsGoalsReloaded();
    void databaseChangeInitializationFailureReportsOperationFailed();
    void samePathReinitializeReloadsFreshDatabase();
    void routineMutationsDoNotResetModel();
    void primaryGoalReturnsQmlReadableMap();
    void calculateDaysRemainingHandlesPastAndInvalidDates();
    void modelReferenceDateDrivesDaysRemaining();
    void syncReferenceDateUpdatesBothPathsAndNotifies();

private:
    void clearGoals();

    QTemporaryDir* m_tempDir = nullptr;
    QString m_databasePath;
};

void CountdownServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("CountdownServiceTests"));
    m_databasePath = m_tempDir->filePath(QStringLiteral("countdown-test.sqlite"));
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
}

void CountdownServiceTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void CountdownServiceTests::init()
{
    // 有用例（samePathReinitializeReloadsFreshDatabase）会把库切到自己的临时文件上
    // 且不还原，之后每一条都跑在那个库上而不是 initTestCase 建的 fixture 库。
    // 目前不致失败——后面几条恰好与具体是哪个库无关；但这是个陷阱：
    // 将来任何一条依赖 fixture 种子数据的用例都会莫名其妙地坏，
    // 而线索指向的是「那条切库的用例」，与新用例本身毫无关系。
    // 本仓另外四个会切库的测试文件都在 init() 里复位，只有这里漏了。
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
    clearGoals();
    AppSettings::instance()->setDayStartHour(4);
    CountdownService::instance()->syncReferenceDateTo(
        LogicalDay::today(AppSettings::instance()->dayStartHour()));
}

void CountdownServiceTests::cleanup()
{
    clearGoals();
}

void CountdownServiceTests::clearGoals()
{
    CountdownService* service = CountdownService::instance();
    while (service->model()->rowCount() > 0) {
        const int id = goalIdAt(service->model(), 0);
        QVERIFY(service->deleteGoal(id));
    }

    // 清掉自增序列，避免测试之间因为历史 id 互相影响。
    QSqlQuery resetSequence(DatabaseManager::instance()->database());
    QVERIFY(resetSequence.exec(QStringLiteral("DELETE FROM sqlite_sequence WHERE name = 'countdown_goals'")));
}

void CountdownServiceTests::addGoalPersistsTrimmedNameAndUsesMaxDisplayOrder()
{
    CountdownService* service = CountdownService::instance();
    const QDate firstDate = QDate::currentDate().addDays(30);
    const QDate secondDate = QDate::currentDate().addDays(60);

    QVERIFY(service->addGoal(QStringLiteral("  研究生初试  "), firstDate));
    QCOMPARE(service->model()->rowCount(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("研究生初试"));
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::TargetDateRole).toDate(), firstDate);
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::DisplayOrderRole).toInt(), 0);

    QSqlQuery bumpOrder(DatabaseManager::instance()->database());
    bumpOrder.prepare(QStringLiteral("UPDATE countdown_goals SET display_order = 4 WHERE id = :id"));
    bumpOrder.bindValue(QStringLiteral(":id"), goalIdAt(service->model(), 0));
    QVERIFY(bumpOrder.exec());

    QVERIFY(service->addGoal(QStringLiteral("复试"), secondDate));
    QCOMPARE(service->model()->rowCount(), 2);
    QCOMPARE(service->model()->data(service->model()->index(1), CountdownModel::DisplayOrderRole).toInt(), 5);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT name, target_date, display_order FROM countdown_goals ORDER BY id ASC")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("研究生初试"));
    QCOMPARE(QDate::fromString(query.value(1).toString(), Qt::ISODate), firstDate);
    QCOMPARE(query.value(2).toInt(), 4);
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("复试"));
    QCOMPARE(QDate::fromString(query.value(1).toString(), Qt::ISODate), secondDate);
    QCOMPARE(query.value(2).toInt(), 5);
    QVERIFY(!query.next());
}

void CountdownServiceTests::rejectsInvalidNamesAndDates()
{
    CountdownService* service = CountdownService::instance();
    QSignalSpy errorSpy(service, &CountdownService::operationFailed);

    QVERIFY(!service->addGoal(QString(), QDate::currentDate()));
    QVERIFY(!service->addGoal(QStringLiteral("   "), QDate::currentDate()));
    QVERIFY(!service->addGoal(QString(51, QLatin1Char('a')), QDate::currentDate()));
    QVERIFY(!service->addGoal(QStringLiteral("有效名称"), QDate()));

    QCOMPARE(service->model()->rowCount(), 0);
    QCOMPARE(errorSpy.count(), 4);
}

void CountdownServiceTests::updateGoalValidatesAndUpdatesExistingGoal()
{
    CountdownService* service = CountdownService::instance();
    const QDate originalDate = QDate::currentDate().addDays(10);
    const QDate updatedDate = QDate::currentDate().addDays(45);

    QVERIFY(service->addGoal(QStringLiteral("原始目标"), originalDate));
    const int id = goalIdAt(service->model(), 0);

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(!service->updateGoal(id, QStringLiteral("  "), updatedDate));
    QVERIFY(!service->updateGoal(id, QStringLiteral("更新目标"), QDate()));
    QVERIFY(!service->updateGoal(9999, QStringLiteral("不存在目标"), updatedDate));
    QCOMPARE(errorSpy.count(), 3);

    QVERIFY(service->updateGoal(id, QStringLiteral("  更新目标  "), updatedDate));
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("更新目标"));
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::TargetDateRole).toDate(), updatedDate);
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::DaysRemainingRole).toInt(),
             LogicalDay::today(AppSettings::instance()->dayStartHour()).daysTo(updatedDate));

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT name, target_date, updated_at FROM countdown_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    QVERIFY(query.exec());
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("更新目标"));
    QCOMPARE(QDate::fromString(query.value(1).toString(), Qt::ISODate), updatedDate);
    QVERIFY(!query.value(2).toString().isEmpty());
}

// 产品保证：倒计时的字段级入口只改交进来的字段；没交的取库里现在的值。弹窗开着时另一台改了日期
// （这里直接写库，模拟同步写进来），这边只改名称后保存，日期还是另一台的。
// 不认识的键、类型不对、日期写错都整次拒绝且什么都不写；没有改动时只确认目标还在。
// 抓住的错误实现：按弹窗打开时的值整条写回（另一台改的日期被盖回旧值），或拿内存里过期的列表当当前值。
void CountdownServiceTests::updateGoalChangesWritesOnlyGivenFields()
{
    CountdownService* service = CountdownService::instance();
    const QDate originalDate = QDate::currentDate().addDays(10);
    QVERIFY(service->addGoal(QStringLiteral("初试"), originalDate));
    const int id = goalIdAt(service->model(), 0);
    const QDate remoteDate = QDate::currentDate().addDays(40);
    QSqlQuery remote(DatabaseManager::instance()->database());
    remote.prepare(QStringLiteral("UPDATE countdown_goals SET target_date = :date WHERE id = :id"));
    remote.bindValue(QStringLiteral(":date"), remoteDate.toString(Qt::ISODate));
    remote.bindValue(QStringLiteral(":id"), id);
    QVERIFY(remote.exec());

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(service->updateGoalChanges(id, {{QStringLiteral("name"), QStringLiteral("研究生初试")}}));
    QCOMPARE(errorSpy.count(), 0);
    QSqlQuery stored(DatabaseManager::instance()->database());
    stored.prepare(QStringLiteral("SELECT name, target_date FROM countdown_goals WHERE id = :id"));
    stored.bindValue(QStringLiteral(":id"), id);
    QVERIFY(stored.exec() && stored.next());
    QCOMPARE(stored.value(0).toString(), QStringLiteral("研究生初试"));
    QCOMPARE(QDate::fromString(stored.value(1).toString(), Qt::ISODate), remoteDate);
    stored.finish();

    QVERIFY(!service->updateGoalChanges(id, {{QStringLiteral("note"), QStringLiteral("x")}}));
    QVERIFY(!service->updateGoalChanges(id, {{QStringLiteral("name"), 5}}));
    QVERIFY(!service->updateGoalChanges(id, {{QStringLiteral("targetDate"), QStringLiteral("2026-02-31")},
                                             {QStringLiteral("name"), QStringLiteral("不该写进去")}}));
    QCOMPARE(errorSpy.count(), 3);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("研究生初试"));

    QVERIFY(service->updateGoalChanges(id, {}));
    QVERIFY(!service->updateGoalChanges(id + 999, {}));
    QCOMPARE(errorSpy.count(), 4);
}

void CountdownServiceTests::updateGoalIgnoredWriteKeepsModelUnchanged()
{
    CountdownService* service = CountdownService::instance();
    const QDate originalDate = QDate::currentDate().addDays(10);
    QVERIFY(service->addGoal(QStringLiteral("原始目标"), originalDate));
    const int id = goalIdAt(service->model(), 0);

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER ignore_countdown_update "
        "BEFORE UPDATE ON countdown_goals "
        "BEGIN SELECT RAISE(IGNORE); END")));

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(!service->updateGoal(id, QStringLiteral("不应写入"), originalDate.addDays(1)));
    QCOMPARE(errorSpy.count(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("原始目标"));
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::TargetDateRole).toDate(),
             originalDate);

    QSqlQuery dropTrigger(DatabaseManager::instance()->database());
    QVERIFY(dropTrigger.exec(QStringLiteral("DROP TRIGGER ignore_countdown_update")));
}

void CountdownServiceTests::deleteGoalRemovesModelDatabaseAndRefreshesPrimary()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10)));
    QVERIFY(service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20)));
    const int firstId = goalIdAt(service->model(), 0);

    QVERIFY(service->deleteGoal(firstId));
    QCOMPARE(service->model()->rowCount(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标2"));
    QCOMPARE(service->primaryGoal().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("目标2"));

    QSqlQuery countQuery(DatabaseManager::instance()->database());
    QVERIFY(countQuery.exec(QStringLiteral("SELECT COUNT(*) FROM countdown_goals")));
    QVERIFY(countQuery.next());
    QCOMPARE(countQuery.value(0).toInt(), 1);

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(!service->deleteGoal(9999));
    QCOMPARE(errorSpy.count(), 1);
}

void CountdownServiceTests::reorderMovesModelPersistsOrdersAndRefreshesPrimary()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10)));
    QVERIFY(service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20)));
    QVERIFY(service->addGoal(QStringLiteral("目标3"), QDate::currentDate().addDays(30)));

    QVERIFY(service->reorder(2, 0));
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标3"));
    QCOMPARE(nameAt(service->model(), 1), QStringLiteral("目标1"));
    QCOMPARE(nameAt(service->model(), 2), QStringLiteral("目标2"));
    QCOMPARE(service->primaryGoal().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("目标3"));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT name, display_order FROM countdown_goals ORDER BY display_order ASC")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("目标3"));
    QCOMPARE(query.value(1).toInt(), 0);
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("目标1"));
    QCOMPARE(query.value(1).toInt(), 1);
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("目标2"));
    QCOMPARE(query.value(1).toInt(), 2);
    QVERIFY(!query.next());

    QVERIFY(!service->reorder(-1, 0));
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标3"));
}

void CountdownServiceTests::reorderFailureKeepsOriginalModelOrder()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10)));
    QVERIFY(service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20)));
    QVERIFY(service->addGoal(QStringLiteral("目标3"), QDate::currentDate().addDays(30)));

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER fail_countdown_reorder "
        "BEFORE UPDATE OF display_order ON countdown_goals "
        "BEGIN SELECT RAISE(ABORT, 'blocked reorder'); END")));

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(!service->reorder(2, 0));
    QCOMPARE(errorSpy.count(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标1"));
    QCOMPARE(nameAt(service->model(), 1), QStringLiteral("目标2"));
    QCOMPARE(nameAt(service->model(), 2), QStringLiteral("目标3"));

    QSqlQuery dropTrigger(DatabaseManager::instance()->database());
    QVERIFY(dropTrigger.exec(QStringLiteral("DROP TRIGGER fail_countdown_reorder")));
}

void CountdownServiceTests::reorderIgnoredUpdateKeepsOriginalModelOrder()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10)));
    QVERIFY(service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20)));
    QVERIFY(service->addGoal(QStringLiteral("目标3"), QDate::currentDate().addDays(30)));

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(
        "CREATE TRIGGER ignore_countdown_reorder "
        "BEFORE UPDATE OF display_order ON countdown_goals "
        "WHEN OLD.name = '目标3' "
        "BEGIN SELECT RAISE(IGNORE); END")));

    QSignalSpy errorSpy(service, &CountdownService::operationFailed);
    QVERIFY(!service->reorder(2, 0));
    QCOMPARE(errorSpy.count(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标1"));
    QCOMPARE(nameAt(service->model(), 1), QStringLiteral("目标2"));
    QCOMPARE(nameAt(service->model(), 2), QStringLiteral("目标3"));

    QSqlQuery dropTrigger(DatabaseManager::instance()->database());
    QVERIFY(dropTrigger.exec(QStringLiteral("DROP TRIGGER ignore_countdown_reorder")));
}

void CountdownServiceTests::reloadFailurePreservesModelAndRecoveryEmitsGoalsReloaded()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("保留中的目标"), QDate::currentDate().addDays(12)));

    QSqlQuery dropTable(DatabaseManager::instance()->database());
    QVERIFY(dropTable.exec(QStringLiteral("DROP TABLE countdown_goals")));

    QSignalSpy failureSpy(service, &CountdownService::operationFailed);
    QSignalSpy reloadedSpy(service, &CountdownService::goalsReloaded);
    QVERIFY(!service->reload());
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(reloadedSpy.count(), 0);
    // 读取失败时 UI 仍需要可展示上一份完整数据，不能把错误伪装成空列表。
    QCOMPARE(service->model()->rowCount(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("保留中的目标"));

    // 关闭再打开会走 databaseChanged 的完整初始化链，重建倒计时表并产生成功重载信号。
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
    QCOMPARE(reloadedSpy.count(), 1);
    QCOMPARE(service->model()->rowCount(), 0);
}

void CountdownServiceTests::databaseChangeInitializationFailureReportsOperationFailed()
{
    CountdownService* service = CountdownService::instance();
    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery replaceTable(db);
    // 模拟只坏在倒计时服务自己那一步、不挡住主库打开的局部结构故障：用同名的表占住它要建的排序索引的名字，
    // CREATE INDEX IF NOT EXISTS 会明确失败，从而验证 databaseChanged 路径不会静默吞掉初始化错误。
    // （051 起倒计时表参与同步，由主库建表并加同步列；从前用同名 view 顶替整张表的做法，
    // 现在会让整个库打不开——那已经是核心表损坏，不再是倒计时自己的事。）
    QVERIFY(replaceTable.exec(QStringLiteral("DROP INDEX idx_display_order")));
    QVERIFY(replaceTable.exec(QStringLiteral("CREATE TABLE idx_display_order (x)")));

    QSignalSpy failureSpy(service, &CountdownService::operationFailed);
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
    QCOMPARE(failureSpy.count(), 1);

    QVERIFY(replaceTable.exec(QStringLiteral("DROP TABLE idx_display_order")));
    // 上一步失败会清除就绪标记；显式 reload 应重建表，供后续测试继续使用同一临时库。
    QVERIFY(service->reload());
}

void CountdownServiceTests::samePathReinitializeReloadsFreshDatabase()
{
    CountdownService* service = CountdownService::instance();
    const QString dbPath = m_tempDir->filePath(QStringLiteral("same-path-reinit.sqlite"));

    QVERIFY(DatabaseManager::instance()->initialize(dbPath));
    QVERIFY(service->addGoal(QStringLiteral("旧目标"), QDate::currentDate().addDays(10)));
    QCOMPARE(service->model()->rowCount(), 1);

    DatabaseManager::instance()->close();
    QVERIFY(QFile::remove(dbPath));
    QVERIFY(DatabaseManager::instance()->initialize(dbPath));

    // 服务是单例；同一路径换成新数据库后，模型必须从空表重新加载。
    QVERIFY(service->addGoal(QStringLiteral("新目标"), QDate::currentDate().addDays(20)));
    QCOMPARE(service->model()->rowCount(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("新目标"));
}

void CountdownServiceTests::routineMutationsDoNotResetModel()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(service->addGoal(QStringLiteral("目标A"), QDate::currentDate().addDays(5)));
    QVERIFY(service->addGoal(QStringLiteral("目标B"), QDate::currentDate().addDays(6)));

    // 常规增删改不允许全量 reset：否则 QML 列表每次操作都重建 delegate 并丢失滚动位置。
    // 换库重载（databaseChanged 信号路径）才允许 reset，由 samePathReinitialize 用例覆盖。
    QSignalSpy resetSpy(service->model(), &QAbstractItemModel::modelReset);

    QVERIFY(service->addGoal(QStringLiteral("目标C"), QDate::currentDate().addDays(7)));
    QCOMPARE(resetSpy.count(), 0);

    QVERIFY(service->updateGoal(goalIdAt(service->model(), 0),
                                QStringLiteral("目标A改"),
                                QDate::currentDate().addDays(8)));
    QCOMPARE(resetSpy.count(), 0);

    QVERIFY(service->deleteGoal(goalIdAt(service->model(), 2)));
    QCOMPARE(resetSpy.count(), 0);
    QCOMPARE(service->model()->rowCount(), 2);
}

void CountdownServiceTests::primaryGoalReturnsQmlReadableMap()
{
    CountdownService* service = CountdownService::instance();
    QVERIFY(isEmptyPrimaryGoal(service->primaryGoal()));

    const QDate firstDate = QDate::currentDate().addDays(7);
    const QDate secondDate = QDate::currentDate().addDays(14);
    QVERIFY(service->addGoal(QStringLiteral("目标1"), firstDate));
    QVERIFY(service->addGoal(QStringLiteral("目标2"), secondDate));

    QVariantMap primary = service->primaryGoal().toMap();
    QCOMPARE(primary.value(QStringLiteral("goalId")).toInt(), goalIdAt(service->model(), 0));
    QCOMPARE(primary.value(QStringLiteral("name")).toString(), QStringLiteral("目标1"));
    QCOMPARE(primary.value(QStringLiteral("targetDate")).toDate(), firstDate);
    QCOMPARE(primary.value(QStringLiteral("daysRemaining")).toInt(),
             LogicalDay::today(AppSettings::instance()->dayStartHour()).daysTo(firstDate));

    QVERIFY(service->reorder(1, 0));
    primary = service->primaryGoal().toMap();
    QCOMPARE(primary.value(QStringLiteral("goalId")).toInt(), goalIdAt(service->model(), 0));
    QCOMPARE(primary.value(QStringLiteral("name")).toString(), QStringLiteral("目标2"));
    QCOMPARE(primary.value(QStringLiteral("targetDate")).toDate(), secondDate);
    QCOMPARE(primary.value(QStringLiteral("daysRemaining")).toInt(),
             LogicalDay::today(AppSettings::instance()->dayStartHour()).daysTo(secondDate));

    QVERIFY(service->deleteGoal(goalIdAt(service->model(), 0)));
    QVERIFY(service->deleteGoal(goalIdAt(service->model(), 0)));
    QVERIFY(isEmptyPrimaryGoal(service->primaryGoal()));
}

void CountdownServiceTests::calculateDaysRemainingHandlesPastAndInvalidDates()
{
    CountdownService* service = CountdownService::instance();
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());

    QCOMPARE(service->calculateDaysRemaining(today), 0);
    QCOMPARE(service->calculateDaysRemaining(today.addDays(10)), 10);
    QCOMPARE(service->calculateDaysRemaining(today.addDays(-5)), -5);
    QCOMPARE(service->calculateDaysRemaining(QDate()), 0);
}

void CountdownServiceTests::modelReferenceDateDrivesDaysRemaining()
{
    CountdownService* service = CountdownService::instance();
    const QDate reference = LogicalDay::today(AppSettings::instance()->dayStartHour());
    QVERIFY(service->addGoal(QStringLiteral("参考日目标"), reference.addDays(10)));

    CountdownModel* model = service->model();
    QSignalSpy dataSpy(model, &QAbstractItemModel::dataChanged);

    model->setReferenceDate(reference.addDays(7));
    QCOMPARE(model->data(model->index(0), CountdownModel::DaysRemainingRole).toInt(), 3);
    QCOMPARE(dataSpy.count(), 1);

    model->setReferenceDate(reference.addDays(7));
    QCOMPARE(dataSpy.count(), 1);
}

void CountdownServiceTests::syncReferenceDateUpdatesBothPathsAndNotifies()
{
    CountdownService* service = CountdownService::instance();
    const QDate reference = LogicalDay::today(AppSettings::instance()->dayStartHour());
    QVERIFY(service->addGoal(QStringLiteral("双路径目标"), reference.addDays(30)));

    QSignalSpy primarySpy(service, &CountdownService::primaryGoalChanged);
    service->syncReferenceDateTo(reference.addDays(7));

    QCOMPARE(service->model()->data(service->model()->index(0),
                                    CountdownModel::DaysRemainingRole).toInt(), 23);
    QCOMPARE(service->primaryGoal().toMap().value(QStringLiteral("daysRemaining")).toInt(), 23);
    QCOMPARE(primarySpy.count(), 1);
}

QTEST_MAIN(CountdownServiceTests)
#include "CountdownServiceTests.moc"
