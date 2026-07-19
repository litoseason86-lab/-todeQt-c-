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
    void deleteGoalRemovesModelDatabaseAndRefreshesPrimary();
    void reorderMovesModelPersistsOrdersAndRefreshesPrimary();
    void reorderFailureKeepsOriginalModelOrder();
    void reorderIgnoredUpdateKeepsOriginalModelOrder();
    void samePathReinitializeReloadsFreshDatabase();
    void routineMutationsDoNotResetModel();
    void primaryGoalReturnsQmlReadableMap();
    void calculateDaysRemainingHandlesPastAndInvalidDates();
    void modelReferenceDateDrivesDaysRemaining();
    void syncReferenceDateUpdatesBothPathsAndNotifies();

private:
    void clearGoals();

    QTemporaryDir* m_tempDir = nullptr;
};

void CountdownServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("CountdownServiceTests"));
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("countdown-test.sqlite"))));
}

void CountdownServiceTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void CountdownServiceTests::init()
{
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
    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);

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

    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);
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

    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);
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

    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);
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

    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);
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

    QSignalSpy errorSpy(service, &CountdownService::errorOccurred);
    QVERIFY(!service->reorder(2, 0));
    QCOMPARE(errorSpy.count(), 1);
    QCOMPARE(nameAt(service->model(), 0), QStringLiteral("目标1"));
    QCOMPARE(nameAt(service->model(), 1), QStringLiteral("目标2"));
    QCOMPARE(nameAt(service->model(), 2), QStringLiteral("目标3"));

    QSqlQuery dropTrigger(DatabaseManager::instance()->database());
    QVERIFY(dropTrigger.exec(QStringLiteral("DROP TRIGGER ignore_countdown_reorder")));
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
