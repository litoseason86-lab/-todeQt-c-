#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QTemporaryDir>
#include <QtTest>
#include <QVariantList>
#include <QVariantMap>

#include "../src/models/LongGoal.h"
#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusSessionRules.h"
#include "../src/services/GoalService.h"

namespace {

// 一个稳稳达标的番茄时长：高于有效门槛即可，具体数值对断言没有意义。
constexpr int kValidPomodoroSeconds = FocusSessionRules::kMinimumValidDurationSeconds + 60;

}

class GoalServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();

    // 纯逻辑：里程碑档位换算不依赖数据库
    void milestoneMaskRoundsUpAndNeverCelebratesEarly();

    // 输入校验
    void rejectsEmptyOverlongTitlesAndInvalidTargets();
    void rejectsGoalWithoutCategory();
    void rejectsInvalidGoalIdsWithoutFallingBackToFirstGoal();
    void goalWithClearedCategoryStaysReadableAndRebindable();
    void addGoalRollsBackAfterCommitFailure();

    // 进度聚合口径
    void progressCountsOnlyValidPomodorosOfBoundCategory();
    void progressIgnoresSessionsBeforeStartDate();
    void progressFollowsLogicalDayBoundary();
    void deletingSessionsRollsProgressBack();
    void dailyCountsGroupByLogicalDay();
    void dailyCountsRespectStartDateAndCategory();

    // 完成预测
    void forecastIsUnknownWithoutSessionsAndZeroWhenAchieved();
    void forecastUsesActiveDaysNotCalendarDays();

    // 里程碑去重（核心：修掉 TRACK 100 的可刷 bug）
    void milestoneFiresOnceAndNotAgainOnRefresh();
    void progressRollbackThenRegainDoesNotRefire();
    void firstRefreshSeedsProgressCacheWithoutEmitting();
    void progressRollbackThenRegainEmitsProgressAgain();
    void databaseChangeClearsProgressCache();
    void categoryChangeInvalidatesGoalsExactlyOnce();
    void crossingSeveralMilestonesAtOnceReportsOnlyHighest();
    void newGoalWithBackfilledHistoryDoesNotCelebrate();
    void raisingTargetClearsStaleMilestonesSoTheyCanFireAgain();
    void loweringTargetFiresNewMilestoneAndSetsAchievedAt();
    void presentationOnlyEditPreservesMilestoneHistory();
    void updateGoalReseedsProgressCache();
    void refreshMilestonesInvalidatesGoalData();
    void updateGoalRollsBackWhenMilestoneWriteFails();

    // 删除与重排（阶段 3 的目标列表页会直接调用这两个写路径）
    void deleteGoalRemovesItAndLeavesOtherProgressIntact();
    void deleteGoalRejectsUnknownId();
    void reorderGoalMovesEntryAndRewritesDisplayOrder();
    void reorderGoalRejectsOutOfRangeIndexWithoutTouchingData();
    void reorderGoalWithSameIndexIsNoOp();

private:
    void clearAll();
    int addCategory(const QString& name);
    int addTask(const QString& title, int categoryId);
    void insertSession(int taskId, const QDateTime& startTime, int durationSeconds, int mode);
    int addGoalReturningId(const QString& title, int categoryId, int target, const QDate& startDate);

    QTemporaryDir* m_tempDir = nullptr;
};

void GoalServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("GoalServiceTests"));
    QVERIFY(DatabaseManager::instance()->initialize(
        m_tempDir->filePath(QStringLiteral("goal-test.sqlite"))));

    // 先建好库再首次触碰 GoalService：构造函数会在库已打开时直接建表。
    QVERIFY(GoalService::instance() != nullptr);
}

void GoalServiceTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void GoalServiceTests::init()
{
    clearAll();
    // GoalService 是进程单例；每个用例模拟一次换库，隔离只应活在进程内的进度缓存。
    DatabaseManager::instance()->databaseChanged();
    // 绝大多数用例把逻辑日对齐到物理日，避免断言受当前钟点影响；
    // 只有 progressFollowsLogicalDayBoundary 会单独改成 4 点。
    AppSettings::instance()->setDayStartHour(0);
}

void GoalServiceTests::clearAll()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DELETE FROM long_goals")));
    QVERIFY(query.exec(QStringLiteral("DELETE FROM focus_sessions")));
    QVERIFY(query.exec(QStringLiteral("DELETE FROM tasks")));
    // categories.name 有唯一约束，不清掉的话第二个用例插同名科目就会失败。
    // 预置科目由 DatabaseManager 建库时写入，本测试全程自己造科目，删掉不影响被测逻辑。
    QVERIFY(query.exec(QStringLiteral("DELETE FROM categories")));
    // 自增序列一并清掉，避免用例之间因为历史 id 相互影响。
    query.exec(QStringLiteral("DELETE FROM sqlite_sequence "
                              "WHERE name IN ('long_goals','focus_sessions','tasks','categories')"));
}

int GoalServiceTests::addCategory(const QString& name)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("INSERT INTO categories (name, color) VALUES (:name, :color)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":color"), QStringLiteral("#d4a574"));
    if (!query.exec()) {
        qWarning() << "插入科目失败:" << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

int GoalServiceTests::addTask(const QString& title, int categoryId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category_id, date, completed) "
        "VALUES (:title, :categoryId, :date, 0)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":categoryId"), categoryId);
    query.bindValue(QStringLiteral(":date"), QDate::currentDate().toString(Qt::ISODate));
    if (!query.exec()) {
        qWarning() << "插入任务失败:" << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

void GoalServiceTests::insertSession(int taskId,
                                     const QDateTime& startTime,
                                     int durationSeconds,
                                     int mode)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (:taskId, :start, :end, :duration, :mode, :pomodoroCompleted)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":start"), startTime.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":end"), startTime.addSecs(durationSeconds).toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":duration"), durationSeconds);
    query.bindValue(QStringLiteral(":mode"), mode);
    query.bindValue(QStringLiteral(":pomodoroCompleted"),
                    mode == FocusSessionRules::kPomodoroMode
                        && durationSeconds >= FocusSessionRules::kMinimumValidDurationSeconds ? 1 : 0);
    QVERIFY2(query.exec(), qPrintable(query.lastError().text()));
}

int GoalServiceTests::addGoalReturningId(const QString& title,
                                         int categoryId,
                                         int target,
                                         const QDate& startDate)
{
    GoalService* service = GoalService::instance();
    if (!service->addGoal(title, categoryId, target, startDate, QVariant())) {
        return -1;
    }
    const QVariantList goals = service->getGoals();
    if (goals.isEmpty()) {
        return -1;
    }
    return goals.last().toMap().value(QStringLiteral("id")).toInt();
}

void GoalServiceTests::milestoneMaskRoundsUpAndNeverCelebratesEarly()
{
    // 目标 10 个番茄：25% 需要 2.5 个，必须做满 3 个才算达标，宁可晚一个也不提前庆祝。
    QCOMPARE(LongGoal::milestonesForProgress(2, 10), 0);
    QCOMPARE(LongGoal::milestonesForProgress(3, 10), int(LongGoal::Milestone25));
    QCOMPARE(LongGoal::milestonesForProgress(5, 10),
             int(LongGoal::Milestone25 | LongGoal::Milestone50));

    // 目标 100：74 个不能算 75%，尽管四舍五入后百分比显示是 74%。
    QCOMPARE(LongGoal::milestonesForProgress(74, 100),
             int(LongGoal::Milestone25 | LongGoal::Milestone50));
    QCOMPARE(LongGoal::milestonesForProgress(75, 100),
             int(LongGoal::Milestone25 | LongGoal::Milestone50 | LongGoal::Milestone75));

    // 超额完成仍然只点亮四档，百分比也夹到 100。
    QCOMPARE(LongGoal::milestonesForProgress(130, 100),
             int(LongGoal::Milestone25 | LongGoal::Milestone50
                 | LongGoal::Milestone75 | LongGoal::Milestone100));
    QCOMPARE(LongGoal::percentOf(130, 100), 100);

    // 目标值非法时不点亮任何档位，避免除零后误判成已达成。
    QCOMPARE(LongGoal::milestonesForProgress(5, 0), 0);
    QCOMPARE(LongGoal::percentOf(5, 0), 0);
}

void GoalServiceTests::rejectsEmptyOverlongTitlesAndInvalidTargets()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(categoryId > 0);

    QVERIFY(!service->addGoal(QStringLiteral("   "), categoryId, 100, QVariant(), QVariant()));
    QVERIFY(!service->addGoal(QString(GoalService::kMaxTitleLength + 1, QChar(u'字')),
                              categoryId, 100, QVariant(), QVariant()));
    QVERIFY(!service->addGoal(QStringLiteral("零目标"), categoryId, 0, QVariant(), QVariant()));
    QVERIFY(!service->addGoal(QStringLiteral("超上限"), categoryId,
                              GoalService::kMaxTargetPomodoros + 1, QVariant(), QVariant()));
    QVERIFY(service->getGoals().isEmpty());

    // 标题两端空白被裁掉，而不是原样存进去。
    QVERIFY(service->addGoal(QStringLiteral("  英语精读  "), categoryId, 100, QVariant(), QVariant()));
    const QVariantList goals = service->getGoals();
    QCOMPARE(goals.size(), 1);
    QCOMPARE(goals.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("英语精读"));
}

void GoalServiceTests::rejectsGoalWithoutCategory()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(categoryId > 0);

    // 没有科目的目标进度恒为 0、里程碑永不触发，必须在写入时就拒绝。
    QVERIFY(!service->addGoal(QStringLiteral("无科目目标"), 0, 100, QVariant(), QVariant()));
    QVERIFY(!service->addGoal(QStringLiteral("负数科目"), -1, 100, QVariant(), QVariant()));
    QVERIFY(service->getGoals().isEmpty());

    // 已存在的目标也不允许把科目清空。
    QVERIFY(service->addGoal(QStringLiteral("英语精读"), categoryId, 100, QVariant(), QVariant()));
    const int goalId = service->getGoals().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(!service->updateGoal(goalId, QStringLiteral("英语精读"), 0, 100,
                                 QVariant(), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryId")).toInt(), categoryId);
}

void GoalServiceTests::rejectsInvalidGoalIdsWithoutFallingBackToFirstGoal()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int goalId = addGoalReturningId(QStringLiteral("不能被误读"), categoryId, 100,
                                          QDate::currentDate());
    QVERIFY(goalId > 0);

    // 0 和负数是未初始化/非法编号，绝不能被 loadGoals 的“读取全部”哨兵解释。
    QVERIFY(service->getGoal(0).isEmpty());
    QVERIFY(service->getGoal(-1).isEmpty());
    QVERIFY(!service->updateGoal(0, QStringLiteral("不应成功"), categoryId, 10,
                                 QDate::currentDate(), QVariant()));
    QVERIFY(!service->updateGoal(-1, QStringLiteral("不应成功"), categoryId, 10,
                                 QDate::currentDate(), QVariant()));

    const QVariantMap unchanged = service->getGoal(goalId);
    QCOMPARE(unchanged.value(QStringLiteral("title")).toString(), QStringLiteral("不能被误读"));
    QCOMPARE(unchanged.value(QStringLiteral("targetPomodoros")).toInt(), 100);
}

void GoalServiceTests::addGoalRollsBackAfterCommitFailure()
{
    GoalService* service = GoalService::instance();
    QSqlQuery pragma(DatabaseManager::instance()->database());
    QVERIFY(pragma.exec(QStringLiteral("PRAGMA foreign_keys = ON")));
    QVERIFY(pragma.exec(QStringLiteral("PRAGMA defer_foreign_keys = ON")));

    // 不存在的科目在延迟外键模式下会让 INSERT 成功、COMMIT 失败，
    // 用它稳定覆盖“提交失败后必须显式回滚”的连接状态。
    QVERIFY(!service->addGoal(QStringLiteral("必须回滚"), 999999, 100,
                              QDate::currentDate(), QVariant()));
    QVERIFY(service->getGoals().isEmpty());

    // 若失败事务仍挂在连接上，这次 addGoal 会报“事务内不能再次开启事务”。
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(service->addGoal(QStringLiteral("回滚后可继续"), categoryId, 100,
                             QDate::currentDate(), QVariant()));
}

void GoalServiceTests::goalWithClearedCategoryStaysReadableAndRebindable()
{
    GoalService* service = GoalService::instance();
    const int oldCategory = addCategory(QStringLiteral("旧科目"));
    const int newCategory = addCategory(QStringLiteral("新科目"));
    QVERIFY(oldCategory > 0 && newCategory > 0);

    QVERIFY(service->addGoal(QStringLiteral("待改绑目标"), oldCategory, 100,
                             QVariant(), QVariant()));
    const int goalId = service->getGoals().first().toMap().value(QStringLiteral("id")).toInt();

    // 模拟科目被删除后外键把 category_id 置空的存量数据。
    // 校验只在写入路径生效，否则这类目标无法读取，也就无法改绑。
    QSqlQuery clearCategory(DatabaseManager::instance()->database());
    clearCategory.prepare(QStringLiteral(
        "UPDATE long_goals SET category_id = NULL WHERE id = :id"));
    clearCategory.bindValue(QStringLiteral(":id"), goalId);
    QVERIFY(clearCategory.exec());

    const QVariantMap orphan = service->getGoal(goalId);
    QVERIFY2(!orphan.isEmpty(), "科目被清空的存量目标必须仍能读出来");
    QCOMPARE(orphan.value(QStringLiteral("doneCount")).toInt(), 0);

    QVERIFY(service->updateGoal(goalId, QStringLiteral("待改绑目标"), newCategory, 100,
                                QVariant(), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryId")).toInt(), newCategory);
}

void GoalServiceTests::progressCountsOnlyValidPomodorosOfBoundCategory()
{
    GoalService* service = GoalService::instance();
    const int englishId = addCategory(QStringLiteral("英语"));
    const int mathId = addCategory(QStringLiteral("数学"));
    const int englishTask = addTask(QStringLiteral("精读"), englishId);
    const int mathTask = addTask(QStringLiteral("刷题"), mathId);

    const QDateTime now = QDateTime::currentDateTime();
    // 计入：番茄模式且时长达标
    insertSession(englishTask, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(englishTask, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    // 不计入：自由计时（mode=0）只累计分钟，不折算番茄
    insertSession(englishTask, now, kValidPomodoroSeconds, 0);
    // 不计入：番茄模式但没到有效门槛
    insertSession(englishTask, now, FocusSessionRules::kMinimumValidDurationSeconds - 1,
                  FocusSessionRules::kPomodoroMode);
    // 不计入：别的科目
    insertSession(mathTask, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), englishId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    const QVariantMap goal = service->getGoal(goalId);
    QCOMPARE(goal.value(QStringLiteral("doneCount")).toInt(), 2);
    QCOMPARE(goal.value(QStringLiteral("percent")).toInt(), 2);
    QCOMPARE(goal.value(QStringLiteral("achieved")).toBool(), false);
}

void GoalServiceTests::progressIgnoresSessionsBeforeStartDate()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const QDateTime today = QDateTime(QDate::currentDate(), QTime(12, 0));
    insertSession(taskId, today.addDays(-10), kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, today.addDays(-2), kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, today, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);

    // 起始日定在 3 天前：10 天前那条被排除，另外两条计入。
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          QDate::currentDate().addDays(-3));
    QVERIFY(goalId > 0);
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 2);

    // 起始日就是当天：只剩今天那条。这也是“填过去的日期即可回填历史”的反向验证。
    const int todayGoalId = addGoalReturningId(QStringLiteral("今天起"), categoryId, 100,
                                               QDate::currentDate());
    QVERIFY(todayGoalId > 0);
    QCOMPARE(service->getGoal(todayGoalId).value(QStringLiteral("doneCount")).toInt(), 1);
}

void GoalServiceTests::progressFollowsLogicalDayBoundary()
{
    GoalService* service = GoalService::instance();
    // 一天从凌晨 4 点开始：02:00 的专注属于前一天，不属于当天。
    AppSettings::instance()->setDayStartHour(4);

    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const QDate anchor = QDate::currentDate();
    // 用固定日期而不是“现在”，避免用例在真实凌晨运行时结论翻转。
    insertSession(taskId, QDateTime(anchor, QTime(2, 0)), kValidPomodoroSeconds,
                  FocusSessionRules::kPomodoroMode);

    // 起始日 = anchor 当天：那条 02:00 记录逻辑上属于前一天，不该计入。
    const int strictId = addGoalReturningId(QStringLiteral("当天起"), categoryId, 100, anchor);
    QVERIFY(strictId > 0);
    QCOMPARE(service->getGoal(strictId).value(QStringLiteral("doneCount")).toInt(), 0);

    // 起始日 = 前一天：计入。
    const int looseId = addGoalReturningId(QStringLiteral("前一天起"), categoryId, 100,
                                           anchor.addDays(-1));
    QVERIFY(looseId > 0);
    QCOMPARE(service->getGoal(looseId).value(QStringLiteral("doneCount")).toInt(), 1);
}

void GoalServiceTests::deletingSessionsRollsProgressBack()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 5; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 5);

    // 进度是现算的：删掉记录后立刻回退，不需要任何补偿逻辑。
    QSqlQuery del(DatabaseManager::instance()->database());
    QVERIFY(del.exec(QStringLiteral("DELETE FROM focus_sessions WHERE id IN "
                                    "(SELECT id FROM focus_sessions LIMIT 2)")));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 3);
}

void GoalServiceTests::dailyCountsGroupByLogicalDay()
{
    GoalService* service = GoalService::instance();
    AppSettings::instance()->setDayStartHour(4);
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const QDate anchor(2026, 7, 2);

    // 4 点日界点下，凌晨 2 点属于前一逻辑日；中午仍属于当天。
    insertSession(taskId, QDateTime(anchor, QTime(2, 0)), kValidPomodoroSeconds,
                  FocusSessionRules::kPomodoroMode);
    insertSession(taskId, QDateTime(anchor, QTime(12, 0)), kValidPomodoroSeconds,
                  FocusSessionRules::kPomodoroMode);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          anchor.addDays(-1));
    QVERIFY(goalId > 0);

    const QVariantList counts = service->getGoalDailyCounts(goalId, 2026, 7);
    QCOMPARE(counts.size(), 2);
    QCOMPARE(counts.at(0).toMap().value(QStringLiteral("day")).toInt(), 1);
    QCOMPARE(counts.at(0).toMap().value(QStringLiteral("count")).toInt(), 1);
    QCOMPARE(counts.at(1).toMap().value(QStringLiteral("day")).toInt(), 2);
    QCOMPARE(counts.at(1).toMap().value(QStringLiteral("count")).toInt(), 1);
}

void GoalServiceTests::dailyCountsRespectStartDateAndCategory()
{
    GoalService* service = GoalService::instance();
    const int goalCategoryId = addCategory(QStringLiteral("英语"));
    const int otherCategoryId = addCategory(QStringLiteral("编程"));
    const int goalTaskId = addTask(QStringLiteral("精读"), goalCategoryId);
    const int otherTaskId = addTask(QStringLiteral("算法"), otherCategoryId);
    const QDate startDate(2026, 7, 10);

    insertSession(goalTaskId, QDateTime(startDate.addDays(-1), QTime(12, 0)),
                  kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(otherTaskId, QDateTime(startDate.addDays(1), QTime(12, 0)),
                  kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(goalTaskId, QDateTime(startDate.addDays(1), QTime(12, 0)),
                  kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), goalCategoryId, 100,
                                          startDate);
    QVERIFY(goalId > 0);

    const QVariantList counts = service->getGoalDailyCounts(goalId, 2026, 7);
    QCOMPARE(counts.size(), 1);
    QCOMPARE(counts.first().toMap().value(QStringLiteral("day")).toInt(), 11);
    QCOMPARE(counts.first().toMap().value(QStringLiteral("count")).toInt(), 1);
}

void GoalServiceTests::forecastIsUnknownWithoutSessionsAndZeroWhenAchieved()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const int emptyId = addGoalReturningId(QStringLiteral("还没开始"), categoryId, 100,
                                           QDate::currentDate());
    QVERIFY(emptyId > 0);
    // 没有任何记录时返回 -1，界面据此隐藏这一行，而不是显示编造的天数。
    QCOMPARE(service->getGoal(emptyId).value(QStringLiteral("forecastDays")).toInt(), -1);

    insertSession(taskId, QDateTime::currentDateTime(), kValidPomodoroSeconds,
                  FocusSessionRules::kPomodoroMode);
    const int doneId = addGoalReturningId(QStringLiteral("一个就够"), categoryId, 1,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(doneId > 0);
    const QVariantMap done = service->getGoal(doneId);
    QCOMPARE(done.value(QStringLiteral("achieved")).toBool(), true);
    QCOMPARE(done.value(QStringLiteral("forecastDays")).toInt(), 0);
}

void GoalServiceTests::forecastUsesActiveDaysNotCalendarDays()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const QDateTime noon = QDateTime(QDate::currentDate(), QTime(12, 0));
    // 跨度 20 天，但只在其中 2 天真的学过，共 4 个番茄 → 速度是 2 个/活跃日。
    for (int i = 0; i < 2; ++i) {
        insertSession(taskId, noon.addDays(-20), kValidPomodoroSeconds,
                      FocusSessionRules::kPomodoroMode);
        insertSession(taskId, noon, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 10,
                                          QDate::currentDate().addDays(-30));
    QVERIFY(goalId > 0);

    const QVariantMap goal = service->getGoal(goalId);
    QCOMPARE(goal.value(QStringLiteral("doneCount")).toInt(), 4);
    // 还差 6 个，速度 2 个/活跃日 → 3 天。若错用自然日 20 天当分母，结果会是 30 天。
    QCOMPARE(goal.value(QStringLiteral("forecastDays")).toInt(), 3);
}

void GoalServiceTests::milestoneFiresOnceAndNotAgainOnRefresh()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    QSignalSpy spy(service, &GoalService::milestoneReached);

    // 8 的 25% = 2 个番茄。
    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toInt(), goalId);
    QCOMPARE(spy.first().at(2).toInt(), 25);

    // 再刷新多少次都不会重复弹同一档。
    service->refreshMilestones();
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
}

void GoalServiceTests::progressRollbackThenRegainDoesNotRefire()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    QSignalSpy spy(service, &GoalService::milestoneReached);
    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);

    // 这是 TRACK 100 的可刷 bug：撤销一条再补回来，原版会重放庆祝。
    QSqlQuery del(DatabaseManager::instance()->database());
    QVERIFY(del.exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = "
                                    "(SELECT MAX(id) FROM focus_sessions)")));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 1);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    // 位掩码只增不减，所以补回来也不会再弹一次。
    QCOMPARE(spy.count(), 1);
}

void GoalServiceTests::firstRefreshSeedsProgressCacheWithoutEmitting()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);

    QSignalSpy spy(service, &GoalService::goalProgressed);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toInt(), goalId);
    QCOMPARE(spy.first().at(1).toString(), QStringLiteral("英语精读"));
    QCOMPARE(spy.first().at(2).toInt(), 3);
    QCOMPARE(spy.first().at(3).toInt(), 100);
}

void GoalServiceTests::progressRollbackThenRegainEmitsProgressAgain()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);
    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);

    QSignalSpy spy(service, &GoalService::goalProgressed);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    spy.clear();

    QSqlQuery del(DatabaseManager::instance()->database());
    QVERIFY(del.exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = "
                                    "(SELECT MAX(id) FROM focus_sessions)")));
    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 2);
}

void GoalServiceTests::databaseChangeClearsProgressCache()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);
    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();

    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    QSignalSpy spy(service, &GoalService::goalProgressed);
    // 恢复/换库路径会广播该信号；之后第一次刷新只能重建基线，不能把存量进度当新增。
    DatabaseManager::instance()->databaseChanged();
    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);
}

void GoalServiceTests::categoryChangeInvalidatesGoalsExactlyOnce()
{
    GoalService* service = GoalService::instance();
    CategoryManager* categories = CategoryManager::instance();
    const int categoryId = categories->addCategory(QStringLiteral("待删除科目"),
                                                   QStringLiteral("#123456"));
    QVERIFY(categoryId > 0);
    const int goalId = addGoalReturningId(QStringLiteral("会跟随科目变化的目标"), categoryId, 8,
                                          QDate::currentDate());
    QVERIFY(goalId > 0);

    QSignalSpy changedSpy(service, &GoalService::goalsChanged);
    QVERIFY(categories->updateCategory(categoryId, QStringLiteral("重命名科目"),
                                       QStringLiteral("#654321")));
    QCOMPARE(changedSpy.count(), 1);
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryName")).toString(),
             QStringLiteral("重命名科目"));

    changedSpy.clear();
    QVERIFY(categories->deleteCategory(categoryId));
    QCOMPARE(changedSpy.count(), 1);
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryId")).toInt(), 0);
}

void GoalServiceTests::crossingSeveralMilestonesAtOnceReportsOnlyHighest()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    QSignalSpy spy(service, &GoalService::milestoneReached);

    // 一次性补齐 8 个番茄，同时跨过 25/50/75/100 四档。
    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 8; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }
    service->refreshMilestones();

    // 只报最高一档，不连弹四个庆祝窗。
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 100);

    // 达成时间被记下来，之后再刷新不会被改写。
    const QVariantMap goal = service->getGoal(goalId);
    QVERIFY(goal.value(QStringLiteral("achievedAt")).toDateTime().isValid());
}

void GoalServiceTests::newGoalWithBackfilledHistoryDoesNotCelebrate()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 6; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }

    QSignalSpy spy(service, &GoalService::milestoneReached);

    // 起始日填在过去，历史记录被回填成进度。这是“建目标之前就完成的部分”，
    // 不该被当成刚刚达成而弹窗，所以新建时就把位掩码对齐到当前进度。
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 6);

    service->refreshMilestones();
    QCOMPARE(spy.count(), 0);

    // 但回填之后新做的番茄仍然正常触发下一档。
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 100);
}

void GoalServiceTests::raisingTargetClearsStaleMilestonesSoTheyCanFireAgain()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);

    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    QSignalSpy spy(service, &GoalService::milestoneReached);
    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 6; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 75);

    // 目标从 8 提到 24：6 个番茄只剩 25%，75% 那档不再成立，必须被清掉，
    // 否则用户真的做到 18 个时永远等不到 75% 的庆祝。
    QVERIFY(service->updateGoal(goalId, QStringLiteral("英语精读"), categoryId, 24,
                                QDate::currentDate().addDays(-1), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("percent")).toInt(), 25);

    spy.clear();
    service->refreshMilestones();
    // 25% 在改目标时已经对齐，不该因为改了个数字就重弹。
    QCOMPARE(spy.count(), 0);

    for (int i = 0; i < 12; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 75);
}

void GoalServiceTests::loweringTargetFiresNewMilestoneAndSetsAchievedAt()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 6; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds,
                      FocusSessionRules::kPomodoroMode);
    }
    QSignalSpy spy(service, &GoalService::milestoneReached);
    service->refreshMilestones();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(2).toInt(), 75);
    QVERIFY(!service->getGoal(goalId).value(QStringLiteral("achievedAt")).toDateTime().isValid());

    spy.clear();
    QVERIFY(service->updateGoal(goalId, QStringLiteral("英语精读"), categoryId, 6,
                                QDate::currentDate().addDays(-1), QVariant()));

    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toInt(), goalId);
    QCOMPARE(spy.first().at(2).toInt(), 100);
    const QVariantMap achieved = service->getGoal(goalId);
    QCOMPARE(achieved.value(QStringLiteral("achieved")).toBool(), true);
    QVERIFY(achieved.value(QStringLiteral("achievedAt")).toDateTime().isValid());
}

void GoalServiceTests::presentationOnlyEditPreservesMilestoneHistory()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    const int goalId = addGoalReturningId(QStringLiteral("原标题"), categoryId, 8,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    const QDateTime now = QDateTime::currentDateTime();
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    QSignalSpy milestoneSpy(service, &GoalService::milestoneReached);
    service->refreshMilestones();
    QCOMPARE(milestoneSpy.count(), 1);
    QCOMPARE(milestoneSpy.first().at(2).toInt(), 25);

    QSqlQuery remove(DatabaseManager::instance()->database());
    QVERIFY(remove.exec(QStringLiteral(
        "DELETE FROM focus_sessions WHERE id = (SELECT MAX(id) FROM focus_sessions)")));
    service->refreshMilestones();
    milestoneSpy.clear();

    // 进度回退后只改标题：这不改变进度定义，已经庆祝过的 25% 位必须保留。
    QVERIFY(service->updateGoal(goalId, QStringLiteral("新标题"), categoryId, 8,
                                QDate::currentDate().addDays(-1), QVariant()));
    insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(milestoneSpy.count(), 0);
}

void GoalServiceTests::updateGoalReseedsProgressCache()
{
    GoalService* service = GoalService::instance();
    const int oldCategoryId = addCategory(QStringLiteral("旧科目"));
    const int newCategoryId = addCategory(QStringLiteral("新科目"));
    const int oldTaskId = addTask(QStringLiteral("旧任务"), oldCategoryId);
    const int newTaskId = addTask(QStringLiteral("新任务"), newCategoryId);
    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 10; ++i) {
        insertSession(oldTaskId, now, kValidPomodoroSeconds,
                      FocusSessionRules::kPomodoroMode);
    }

    const int goalId = addGoalReturningId(QStringLiteral("改绑目标"), oldCategoryId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);
    service->refreshMilestones();

    QVERIFY(service->updateGoal(goalId, QStringLiteral("改绑目标"), newCategoryId, 100,
                                QDate::currentDate().addDays(-1), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("doneCount")).toInt(), 0);

    QSignalSpy progressedSpy(service, &GoalService::goalProgressed);
    insertSession(newTaskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    service->refreshMilestones();
    QCOMPARE(progressedSpy.count(), 1);
    QCOMPARE(progressedSpy.first().at(0).toInt(), goalId);
    QCOMPARE(progressedSpy.first().at(2).toInt(), 1);
}

void GoalServiceTests::refreshMilestonesInvalidatesGoalData()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(addGoalReturningId(QStringLiteral("进度目标"), categoryId, 100,
                               QDate::currentDate()) > 0);

    QSignalSpy changedSpy(service, &GoalService::goalsChanged);
    service->refreshMilestones();
    QCOMPARE(changedSpy.count(), 1);
}

void GoalServiceTests::updateGoalRollsBackWhenMilestoneWriteFails()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int goalId = addGoalReturningId(QStringLiteral("原目标"), categoryId, 8,
                                          QDate::currentDate());
    QVERIFY(goalId > 0);

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY2(trigger.exec(QStringLiteral(
        "CREATE TRIGGER fail_goal_milestone_update "
        "BEFORE UPDATE OF fired_milestones ON long_goals "
        "WHEN NEW.id = %1 BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
            .arg(goalId)), qPrintable(trigger.lastError().text()));

    QVERIFY(!service->updateGoal(goalId, QStringLiteral("不应落库"), categoryId, 4,
                                 QDate::currentDate(), QVariant()));

    // 第二步写入失败后，第一步已执行的标题和目标值也必须回滚。
    const QVariantMap unchanged = service->getGoal(goalId);
    QCOMPARE(unchanged.value(QStringLiteral("title")).toString(), QStringLiteral("原目标"));
    QCOMPARE(unchanged.value(QStringLiteral("targetPomodoros")).toInt(), 8);
}

void GoalServiceTests::deleteGoalRemovesItAndLeavesOtherProgressIntact()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    QVERIFY(categoryId > 0 && taskId > 0);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 3; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }

    const QDate start = QDate::currentDate().addDays(-1);
    const int firstId = addGoalReturningId(QStringLiteral("要删掉的"), categoryId, 100, start);
    const int secondId = addGoalReturningId(QStringLiteral("要保留的"), categoryId, 100, start);
    QVERIFY(firstId > 0 && secondId > 0);
    QCOMPARE(service->getGoals().size(), 2);

    QVERIFY(service->deleteGoal(firstId));
    const QVariantList remaining = service->getGoals();
    QCOMPARE(remaining.size(), 1);
    QCOMPARE(remaining.first().toMap().value(QStringLiteral("id")).toInt(), secondId);
    QVERIFY(service->getGoal(firstId).isEmpty());

    // 进度是从 focus_sessions 现算的，不存在目标行里，所以删掉一个目标
    // 绝不该影响另一个目标的进度。这条断言就是守住"进度不落库"这个设计前提。
    QCOMPARE(service->getGoal(secondId).value(QStringLiteral("doneCount")).toInt(), 3);
}

void GoalServiceTests::deleteGoalRejectsUnknownId()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int goalId = addGoalReturningId(QStringLiteral("唯一目标"), categoryId, 100,
                                          QDate::currentDate());
    QVERIFY(goalId > 0);

    // 删一个不存在的 id 必须失败，而不是静默"成功"，界面据此判断要不要刷新列表。
    QVERIFY(!service->deleteGoal(goalId + 999));
    QCOMPARE(service->getGoals().size(), 1);

    // 同一个 id 删两次：第二次也必须失败。
    QVERIFY(service->deleteGoal(goalId));
    QVERIFY(!service->deleteGoal(goalId));
    QVERIFY(service->getGoals().isEmpty());
}

void GoalServiceTests::reorderGoalMovesEntryAndRewritesDisplayOrder()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(categoryId > 0);

    const QDate start = QDate::currentDate();
    // 三个目标必须一次性建完再取顺序：addGoalReturningId 依赖"新目标排在末尾"，
    // 这个前提在重排之后就不再成立了。
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("乙"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("丙"), categoryId, 100, start, QVariant()));

    auto titlesInOrder = [service]() {
        QStringList titles;
        const QVariantList goals = service->getGoals();
        for (const QVariant& entry : goals) {
            titles.append(entry.toMap().value(QStringLiteral("title")).toString());
        }
        return titles;
    };

    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("甲"),
                                           QStringLiteral("乙"),
                                           QStringLiteral("丙")}));

    // move(0, 2)：把第 0 项移动到第 2 位，其余顺移 → 乙丙甲。不是"交换首尾"。
    QVERIFY(service->reorderGoal(0, 2));
    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("乙"),
                                           QStringLiteral("丙"),
                                           QStringLiteral("甲")}));

    // 重排后 display_order 必须是从 0 开始的连续整数，
    // 否则后续插入新目标时取 MAX(display_order)+1 会算出错位的序号。
    const QVariantList goals = service->getGoals();
    for (int i = 0; i < goals.size(); ++i) {
        QCOMPARE(goals.at(i).toMap().value(QStringLiteral("displayOrder")).toInt(), i);
    }

    // 反向移动一次，确认不是只在某个方向上正确。
    QVERIFY(service->reorderGoal(2, 0));
    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("甲"),
                                           QStringLiteral("乙"),
                                           QStringLiteral("丙")}));
}

void GoalServiceTests::reorderGoalRejectsOutOfRangeIndexWithoutTouchingData()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const QDate start = QDate::currentDate();
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("乙"), categoryId, 100, start, QVariant()));

    auto titlesInOrder = [service]() {
        QStringList titles;
        const QVariantList goals = service->getGoals();
        for (const QVariant& entry : goals) {
            titles.append(entry.toMap().value(QStringLiteral("title")).toString());
        }
        return titles;
    };
    const QStringList before = titlesInOrder();

    // 越界必须返回 false 并且分毫不动：拖拽 UI 传错下标时不能把顺序搅乱。
    QVERIFY(!service->reorderGoal(-1, 0));
    QVERIFY(!service->reorderGoal(0, -1));
    QVERIFY(!service->reorderGoal(2, 0));
    QVERIFY(!service->reorderGoal(0, 2));
    QVERIFY(!service->reorderGoal(99, 100));

    QCOMPARE(titlesInOrder(), before);
}

void GoalServiceTests::reorderGoalWithSameIndexIsNoOp()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100,
                             QDate::currentDate(), QVariant()));

    QSignalSpy changedSpy(service, &GoalService::goalsChanged);

    // 拖回原位是最常见的误操作，必须直接返回 true 且不写库、不发变更信号，
    // 否则界面会为一次无意义的操作整列表重建。
    QVERIFY(service->reorderGoal(0, 0));
    QCOMPARE(changedSpy.count(), 0);

    // from == to 比越界校验更早短路，即使下标越界也返回 true。
    QVERIFY(service->reorderGoal(5, 5));
    QCOMPARE(changedSpy.count(), 0);
}

QTEST_MAIN(GoalServiceTests)
#include "GoalServiceTests.moc"
