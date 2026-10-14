#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/PendingDeletion.h"
#include "../src/services/TaskManager.h"

// 单槽「撤销删除」（计划 055 阶段 2 第 1 条）的行为用例。删除走真实的 TaskManager / FocusHistoryService，
// 数据库是真实建表逻辑的临时库；界面的撤销条接线由 tests/qml/tst_focus_start_flow.qml 负责。
class PendingDeletionTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void requestDefersDeletionUntilTheDelayPasses();
    void cancelKeepsTheTaskAndClearsTheSlot();
    void earlyCommitDeletesNowAndRetiresExactlyOnce();
    void secondRequestCommitsTheFirstImmediately();
    void taskDeletedElsewhereRetiresTheSlotWithoutDeletingAgain();
    void unrelatedDeletionKeepsTheSlot();
    void failedCommitClearsTheSlotAndReportsTheTitle();
    void failedCommitRejectsTheNewRequest();
    void sessionDeletionFollowsTheKind();
    void invalidRequestsChangeNothing();
    void delayMsIgnoresNonPositiveValuesAndOnlyAffectsTheNextRequest();

private:
    QTemporaryDir* m_tempDir = nullptr;
};

namespace {

QSqlDatabase db()
{
    return DatabaseManager::instance()->database();
}

// 某张表里这个编号的行数（0 或 1）；查询本身失败返回 -1，免得把「查不到」误读成「已删除」。
int rowCount(const QString& table, int id)
{
    QSqlQuery query(db());
    query.prepare(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE id = :id").arg(table));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec() || !query.next()) {
        qWarning() << "count failed:" << table << query.lastError().text();
        return -1;
    }
    const int count = query.value(0).toInt();
    query.finish();
    return count;
}

int makeTask(const QString& title)
{
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
    return TaskManager::instance()->createTask(title, today, -1, 0, QString());
}

// 已结束的专注记录与休息记录（两张表各自从 1 编号）。删除只认已结束的行。
int insertFocusSession()
{
    QSqlQuery query(db());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (NULL, '2026-10-03T14:05:00.000', '2026-10-03T14:50:00.000', 2700, 1, 1)"));
    if (!query.exec()) {
        qWarning() << "insert focus failed:" << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

int insertRestSession()
{
    QSqlQuery query(db());
    query.prepare(QStringLiteral(
        "INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
        "VALUES ('2026-10-03T21:10:00.000', '2026-10-03T21:25:00.000', 900, 1)"));
    if (!query.exec()) {
        qWarning() << "insert rest failed:" << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

} // namespace

void PendingDeletionTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("pending-deletion.sqlite"))));
    AppSettings::instance()->setDayStartHour(4);
}

void PendingDeletionTests::cleanup()
{
    AppSettings::instance()->setDayStartHour(4);
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

// 产品保证：请求删除不碰数据库，撤销窗口走完才真正删除；到点后槽清空，界面收到一次 retired，
// 另一条任务不受影响。
void PendingDeletionTests::requestDefersDeletionUntilTheDelayPasses()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(50);
    const int doomed = makeTask(QStringLiteral("待删任务"));
    const int bystander = makeTask(QStringLiteral("无关任务"));
    QVERIFY(doomed > 0 && bystander > 0 && doomed != bystander);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(pending.requestTask(doomed, QStringLiteral("待删任务")));
    // 窗口内数据库没有被碰过，槽里是它。
    QCOMPARE(rowCount(QStringLiteral("tasks"), doomed), 1);
    QCOMPARE(pending.taskId(), doomed);
    QCOMPARE(pending.sessionId(), -1);
    QCOMPARE(pending.title(), QStringLiteral("待删任务"));
    QVERIFY(pending.active());
    QCOMPARE(retiredSpy.count(), 0);

    QTRY_COMPARE_WITH_TIMEOUT(rowCount(QStringLiteral("tasks"), doomed), 0, 2000);
    QCOMPARE(pending.taskId(), -1);
    QCOMPARE(pending.title(), QString());
    QVERIFY(!pending.active());
    QCOMPARE(retiredSpy.count(), 1);
    QCOMPARE(failedSpy.count(), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), bystander), 1);
}

// 产品保证：撤销只清槽，数据库一次都不碰；窗口过去以后任务仍在，也不会发 retired（撤销条是用户自己点掉的）。
void PendingDeletionTests::cancelKeepsTheTaskAndClearsTheSlot()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(50);
    const int kept = makeTask(QStringLiteral("被撤销的任务"));
    const int bystander = makeTask(QStringLiteral("无关任务"));
    QVERIFY(kept > 0 && bystander > 0);
    QVERIFY(pending.requestTask(kept, QStringLiteral("被撤销的任务")));
    QCOMPARE(pending.taskId(), kept);
    QSignalSpy changedSpy(&pending, &PendingDeletion::changed);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    pending.cancel();
    QCOMPARE(pending.taskId(), -1);
    QCOMPARE(pending.title(), QString());
    QVERIFY(!pending.active());
    QCOMPARE(changedSpy.count(), 1);

    // 计时若没有一起停下，过 3 倍窗口时长必然已经删掉了。
    QTest::qWait(150);
    QCOMPARE(rowCount(QStringLiteral("tasks"), kept), 1);
    QCOMPARE(rowCount(QStringLiteral("tasks"), bystander), 1);
    QCOMPARE(retiredSpy.count(), 0);
    QCOMPARE(failedSpy.count(), 0);
}

// 产品保证：提前提交立刻删除，而且 retired 恰好发一次：deleteTask 会同步发 taskDeleted，
// 那一发是自己的提交造成的，不能再触发一次退场；计时也已经停了，之后不会再删一次。
void PendingDeletionTests::earlyCommitDeletesNowAndRetiresExactlyOnce()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(50);
    const int doomed = makeTask(QStringLiteral("提前落库的任务"));
    const int bystander = makeTask(QStringLiteral("无关任务"));
    QVERIFY(doomed > 0 && bystander > 0);
    QVERIFY(pending.requestTask(doomed, QStringLiteral("提前落库的任务")));
    QCOMPARE(rowCount(QStringLiteral("tasks"), doomed), 1);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(pending.commit());
    QCOMPARE(rowCount(QStringLiteral("tasks"), doomed), 0);
    QVERIFY(!pending.active());
    QCOMPARE(retiredSpy.count(), 1);

    // 已经没有待删项：再提交什么都不做，照样成功。
    QVERIFY(pending.commit());
    QCOMPARE(retiredSpy.count(), 1);

    // 计时若没有停，过了窗口会再删一次：任务已经不在，必然失败，会多出一次 retired 和 commitFailed。
    QTest::qWait(150);
    QCOMPARE(retiredSpy.count(), 1);
    QCOMPARE(failedSpy.count(), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), bystander), 1);
}

// 产品保证：单槽只保护最近一次删除——第二次请求到来时，第一条立刻真正落库，第二条进槽等撤销。
void PendingDeletionTests::secondRequestCommitsTheFirstImmediately()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(5000);
    const int first = makeTask(QStringLiteral("第一个"));
    const int second = makeTask(QStringLiteral("第二个"));
    QVERIFY(first > 0 && second > 0);
    QVERIFY(pending.requestTask(first, QStringLiteral("第一个")));
    QCOMPARE(rowCount(QStringLiteral("tasks"), first), 1);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);

    QVERIFY(pending.requestTask(second, QStringLiteral("第二个")));
    QCOMPARE(rowCount(QStringLiteral("tasks"), first), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), second), 1);
    QCOMPARE(pending.taskId(), second);
    QCOMPARE(pending.title(), QStringLiteral("第二个"));
    QCOMPARE(retiredSpy.count(), 1);

    pending.cancel();
    QCOMPARE(rowCount(QStringLiteral("tasks"), second), 1);
}

// 产品保证：待删任务被别处先删掉（删除或停用每日例行会顺带收回当天实例，外部 AI 接入也能删任务），
// 单槽立刻退场：撤销条收起（retired）、槽清空，窗口到期时不会再删一次而弹出假的「删除失败」。
void PendingDeletionTests::taskDeletedElsewhereRetiresTheSlotWithoutDeletingAgain()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(50);
    const int doomed = makeTask(QStringLiteral("随例行收回的任务"));
    const int bystander = makeTask(QStringLiteral("无关任务"));
    QVERIFY(doomed > 0 && bystander > 0);
    QVERIFY(pending.requestTask(doomed, QStringLiteral("随例行收回的任务")));
    QCOMPARE(pending.taskId(), doomed);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(TaskManager::instance()->deleteTask(doomed));
    QCOMPARE(pending.taskId(), -1);
    QVERIFY(!pending.active());
    QCOMPARE(retiredSpy.count(), 1);

    // 「没有再删一次」只能等过原定的提交时刻才观察得到。
    QTest::qWait(150);
    QCOMPARE(retiredSpy.count(), 1);
    QCOMPARE(failedSpy.count(), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), bystander), 1);
}

// 产品保证：只认槽里的那一条——别的任务被删掉时，撤销窗口原样保留，不发 retired。
void PendingDeletionTests::unrelatedDeletionKeepsTheSlot()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(5000);
    const int pendingId = makeTask(QStringLiteral("仍可撤销的任务"));
    const int other = makeTask(QStringLiteral("别处删掉的任务"));
    QVERIFY(pendingId > 0 && other > 0);
    QVERIFY(pending.requestTask(pendingId, QStringLiteral("仍可撤销的任务")));
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);

    QVERIFY(TaskManager::instance()->deleteTask(other));
    QCOMPARE(pending.taskId(), pendingId);
    QVERIFY(pending.active());
    QCOMPARE(retiredSpy.count(), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), pendingId), 1);

    pending.cancel();
    QCOMPARE(rowCount(QStringLiteral("tasks"), pendingId), 1);
}

// 产品保证：提交触库失败时，槽照样清空（隐藏的那一行回来，不把数据库失败伪装成已删除），
// 撤销条先收起（retired），再报 commitFailed 并带上标题。
void PendingDeletionTests::failedCommitClearsTheSlotAndReportsTheTitle()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    const int bystander = makeTask(QStringLiteral("无关任务"));
    QVERIFY(bystander > 0);
    // 请求本身不查库；这个编号在库里不存在，提交时删除必然失败。
    QCOMPARE(rowCount(QStringLiteral("tasks"), 999999), 0);
    QVERIFY(pending.requestTask(999999, QStringLiteral("失败任务")));
    QVERIFY(pending.active());
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(!pending.commit());
    QCOMPARE(pending.taskId(), -1);
    QCOMPARE(pending.title(), QString());
    QVERIFY(!pending.active());
    QCOMPARE(retiredSpy.count(), 1);
    QCOMPARE(failedSpy.count(), 1);
    QCOMPARE(failedSpy.first().first().toString(), QStringLiteral("失败任务"));
    QCOMPARE(rowCount(QStringLiteral("tasks"), bystander), 1);
}

// 产品保证：槽里的待删项提交失败时，新的请求不进槽、返回 false，也不会被安排删除——
// 用户看到的是上一条的失败提示，而不是一条悄悄排上队的新删除。
void PendingDeletionTests::failedCommitRejectsTheNewRequest()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(50);
    const int real = makeTask(QStringLiteral("乙"));
    QVERIFY(real > 0);
    QVERIFY(pending.requestTask(999999, QStringLiteral("失败任务")));
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(!pending.requestTask(real, QStringLiteral("乙")));
    QCOMPARE(pending.taskId(), -1);
    QVERIFY(!pending.active());
    QCOMPARE(rowCount(QStringLiteral("tasks"), real), 1);
    QCOMPARE(retiredSpy.count(), 1);
    QCOMPARE(failedSpy.count(), 1);

    // 新请求若悄悄进了槽，过了窗口它就被删掉了。
    QTest::qWait(150);
    QCOMPARE(rowCount(QStringLiteral("tasks"), real), 1);
}

// 产品保证：专注记录与休息记录按种类各删各的表。两张表各自从 1 编号，这里故意让两条记录编号相同：
// 按种类分派错了，就会删掉另一张表里的同号记录，或者在已经删掉的那张表里找不到。
void PendingDeletionTests::sessionDeletionFollowsTheKind()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(5000);
    const int focusId = insertFocusSession();
    const int restId = insertRestSession();
    QVERIFY(focusId > 0 && restId > 0);
    QCOMPARE(focusId, restId);
    const QString focusTable = QStringLiteral("focus_sessions");
    const QString restTable = QStringLiteral("rest_sessions");

    // 专注记录：提交后只有专注记录没了。
    QVERIFY(pending.requestSession(focusId, QStringLiteral("数学专注"), false));
    QCOMPARE(pending.sessionId(), focusId);
    QCOMPARE(pending.taskId(), -1);
    QVERIFY(!pending.sessionIsRest());
    QCOMPARE(pending.title(), QStringLiteral("数学专注"));
    QVERIFY(pending.active());
    QCOMPARE(rowCount(focusTable, focusId), 1);
    QVERIFY(pending.commit());
    QCOMPARE(rowCount(focusTable, focusId), 0);
    QCOMPARE(rowCount(restTable, restId), 1);
    QVERIFY(!pending.active());

    // 休息记录：撤销后仍在。
    QVERIFY(pending.requestSession(restId, QStringLiteral("午休"), true));
    QCOMPARE(pending.sessionId(), restId);
    QVERIFY(pending.sessionIsRest());
    pending.cancel();
    QVERIFY(!pending.active());
    QVERIFY(!pending.sessionIsRest());
    QCOMPARE(rowCount(restTable, restId), 1);

    // 再请求并提交：休息记录删了。
    QVERIFY(pending.requestSession(restId, QStringLiteral("午休"), true));
    QVERIFY(pending.commit());
    QCOMPARE(rowCount(restTable, restId), 0);
}

// 产品保证：编号不大于 0 的请求直接被拒绝，不改状态、不发信号——包括不能把窗口里已有的待删项提前提交。
void PendingDeletionTests::invalidRequestsChangeNothing()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    pending.setDelayMs(5000);
    const int kept = makeTask(QStringLiteral("窗口里的任务"));
    QVERIFY(kept > 0);
    QVERIFY(pending.requestTask(kept, QStringLiteral("窗口里的任务")));
    QSignalSpy changedSpy(&pending, &PendingDeletion::changed);
    QSignalSpy retiredSpy(&pending, &PendingDeletion::retired);
    QSignalSpy failedSpy(&pending, &PendingDeletion::commitFailed);

    QVERIFY(!pending.requestTask(0, QStringLiteral("零")));
    QVERIFY(!pending.requestTask(-3, QStringLiteral("负")));
    QVERIFY(!pending.requestSession(-1, QStringLiteral("负"), false));
    QVERIFY(!pending.requestSession(0, QStringLiteral("零"), true));

    QCOMPARE(pending.taskId(), kept);
    QCOMPARE(pending.sessionId(), -1);
    QCOMPARE(pending.title(), QStringLiteral("窗口里的任务"));
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(retiredSpy.count(), 0);
    QCOMPARE(failedSpy.count(), 0);
    QCOMPARE(rowCount(QStringLiteral("tasks"), kept), 1);

    pending.cancel();
}

// 产品保证：撤销窗口时长默认 5 秒；不大于 0 的值被忽略；改它只影响下一次请求，不重启进行中的计时。
void PendingDeletionTests::delayMsIgnoresNonPositiveValuesAndOnlyAffectsTheNextRequest()
{
    PendingDeletion pending(TaskManager::instance(), FocusHistoryService::instance());
    QCOMPARE(pending.delayMs(), 5000);
    QSignalSpy delaySpy(&pending, &PendingDeletion::delayMsChanged);
    pending.setDelayMs(0);
    pending.setDelayMs(-20);
    QCOMPARE(pending.delayMs(), 5000);
    QCOMPARE(delaySpy.count(), 0);

    const int first = makeTask(QStringLiteral("按旧时长的任务"));
    const int second = makeTask(QStringLiteral("按新时长的任务"));
    QVERIFY(first > 0 && second > 0);
    QVERIFY(pending.requestTask(first, QStringLiteral("按旧时长的任务")));
    pending.setDelayMs(50);
    QCOMPARE(pending.delayMs(), 50);
    QCOMPARE(delaySpy.count(), 1);

    // 进行中的这次还按请求时的 5 秒走：过 4 倍新时长它仍在窗口里。
    QTest::qWait(200);
    QCOMPARE(rowCount(QStringLiteral("tasks"), first), 1);
    QCOMPARE(pending.taskId(), first);

    // 下一次请求按新时长走：先提交上一条，再在 50ms 后到点。
    QVERIFY(pending.requestTask(second, QStringLiteral("按新时长的任务")));
    QCOMPARE(rowCount(QStringLiteral("tasks"), first), 0);
    QTRY_COMPARE_WITH_TIMEOUT(rowCount(QStringLiteral("tasks"), second), 0, 2000);
}

QTEST_GUILESS_MAIN(PendingDeletionTests)
#include "PendingDeletionTests.moc"
