#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>
#include <QVariantList>
#include <QVariantMap>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/TaskManager.h"

namespace {

QDate logicalToday()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

// 列表里按标题找一条，找不到返回空 map。断言具体某条的字段时用它，
// 比写死下标可靠：排序规则变了下标就会指向别的记录。
QVariantMap findByTitle(const QVariantList& rows, const QString& title)
{
    for (const QVariant& row : rows) {
        const QVariantMap map = row.toMap();
        if (map.value(QStringLiteral("title")).toString() == title) {
            return map;
        }
    }
    return QVariantMap();
}

QStringList titlesOf(const QVariantList& rows)
{
    QStringList titles;
    for (const QVariant& row : rows) {
        titles.append(row.toMap().value(QStringLiteral("title")).toString());
    }
    return titles;
}

// 批量转换的返回值必须三个键齐全：没有失败时 reason 也是空串而不是缺键，界面和桥接层都按键读。
bool hasBatchResultKeys(const QVariantMap& result)
{
    return result.contains(QStringLiteral("converted")) && result.contains(QStringLiteral("failed"))
           && result.contains(QStringLiteral("reason"));
}

int taskCount()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) || !query.next()) {
        return -1;
    }
    const int count = query.value(0).toInt();
    // 计数游标先合上：结果集开着时 SQLite 会一直持有 tasks 的表锁。
    query.finish();
    return count;
}

// SQLite 的 total_changes()：连接上累计的行写入数（含触发器写的记录）。前后相等才说明期间
// 一次库都没写过——只比较数据抓不到「写了一遍、值恰好没变」的实现。读不出来返回 -1。
qlonglong totalDbChanges()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("SELECT total_changes()")) || !query.next()) {
        return -1;
    }
    return query.value(0).toLongLong();
}

} // namespace

class KnowledgeGapServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();

    void captureStoresTrimmedTitleWithoutSchedule();
    void rejectsEmptyAndOverlongTitles();
    void rejectsOverlongDetailAndResolutionInsteadOfTruncating();
    void rejectsMalformedAndOutOfRangeDueDates();
    void clampsPriorityInsteadOfRejecting();
    void dueDatePresenceDrivesStatus();
    void sourceTaskTitleSurvivesTaskDeletion();
    void listOrdersUnresolvedFirstAndSinksUnscheduled();
    void listFiltersByStatusCategoryAndSearchText();
    void resolveKeepsFirstResolvedAtAndReopenKeepsResolution();
    void editingResolvedGapDoesNotReopenIt();
    void updateGapChangesWritesOnlyGivenFields();
    void schedulingResolvedGapIsRejected();
    void batchMoveRollsBackWholeSelectionOnBadId();
    void convertToTaskCreatesTaskAndLinksGap();
    void conversionRejectsOverlongNotesAndSearchIsLiteral();
    void convertToTaskLeavesGapUntouchedWhenTaskInsertFails();
    void convertToTaskReportsLinkedTaskCompletionWithoutResolving();
    void convertToTaskRefusesWhileLinkedTaskIsOpen();
    void convertToTaskKeepsOverdueDueDate();
    void reminderSummaryUsesLogicalDayBoundary();
    void reminderSummarySkipsGapsWhoseTaskIsStillOpen();
    void convertDueGapsToTasksConvertsOnlyDueUnresolvedWithoutOpenTask();
    void convertDueGapsToTasksKeepsSuccessesAndReportsTheLastFailure();
    void convertDueGapsToTasksWithNothingDueChangesNothing();
    void operationsFailSafelyWhenDatabaseIsClosed();

private:
    void clearGaps();
    int seedCategory(const QString& name);
    int seedTask(const QString& title, const QDate& date);

    QTemporaryDir* m_tempDir = nullptr;
    QString m_databasePath;
};

void KnowledgeGapServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("KnowledgeGapServiceTests"));
    m_databasePath = m_tempDir->filePath(QStringLiteral("knowledge-gap-test.sqlite"));
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
}

void KnowledgeGapServiceTests::cleanupTestCase()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void KnowledgeGapServiceTests::init()
{
    // 有用例会关库或换库，这里统一复位，避免单条失败污染后续用例。
    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
    AppSettings::instance()->setDayStartHour(4);
    clearGaps();
}

void KnowledgeGapServiceTests::clearGaps()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DELETE FROM knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral("DELETE FROM tasks")));
    QVERIFY(query.exec(QStringLiteral(
        "DELETE FROM sqlite_sequence WHERE name IN ('knowledge_gaps', 'tasks')")));
}

int KnowledgeGapServiceTests::seedCategory(const QString& name)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO categories (name, color, is_preset, display_order) "
        "VALUES (:name, '#ff8800', 0, 0)"));
    query.bindValue(QStringLiteral(":name"), name);
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

int KnowledgeGapServiceTests::seedTask(const QString& title, const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, date, completed, estimated_minutes, notes, display_order) "
        "VALUES (:title, '', :date, 0, 0, '', 1)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    if (!query.exec()) {
        return -1;
    }
    return query.lastInsertId().toInt();
}

void KnowledgeGapServiceTests::captureStoresTrimmedTitleWithoutSchedule()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    QSignalSpy changedSpy(service, &KnowledgeGapService::gapsChanged);

    const int id = service->captureGap(QStringLiteral("  线代第 3 章相似对角化没搞懂  "), 0, 0);
    QVERIFY(id > 0);
    QCOMPARE(changedSpy.count(), 1);

    const QVariantMap gap = service->getGap(id);
    QCOMPARE(gap.value(QStringLiteral("title")).toString(),
             QStringLiteral("线代第 3 章相似对角化没搞懂"));
    // 快速捕获刻意不问日期：捕获环节每多一个决策，这个功能被真正用起来的概率就低一分。
    QCOMPARE(gap.value(QStringLiteral("dueDate")).toString(), QString());
    QCOMPARE(gap.value(QStringLiteral("scheduled")).toBool(), false);
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));
    QCOMPARE(gap.value(QStringLiteral("priority")).toInt(), 1);
}

void KnowledgeGapServiceTests::rejectsEmptyAndOverlongTitles()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);

    QCOMPARE(service->captureGap(QString(), 0, 0), -1);
    QCOMPARE(service->captureGap(QStringLiteral("   "), 0, 0), -1);

    // 长度按 QChar 计数，用哪个字符不影响边界语义，这里取 ASCII 以免字面量越界。
    const QString overlong(KnowledgeGapService::kMaxTitleLength + 1, QLatin1Char('a'));
    QCOMPARE(service->captureGap(overlong, 0, 0), -1);

    // 恰好等于上限必须放行，否则边界会悄悄缩一格。
    const QString atLimit(KnowledgeGapService::kMaxTitleLength, QLatin1Char('a'));
    QVERIFY(service->captureGap(atLimit, 0, 0) > 0);

    QCOMPARE(failureSpy.count(), 3);
}

void KnowledgeGapServiceTests::rejectsOverlongDetailAndResolutionInsteadOfTruncating()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);

    // size() 数的是 UTF-16 码元，汉字在 BMP 内同样是一个码元，所以这里用 ASCII 填充
    // 与用汉字是同一个边界。
    const QString atLimit(KnowledgeGapService::kMaxDetailLength, QLatin1Char('a'));
    const QString overLimit(KnowledgeGapService::kMaxDetailLength + 1, QLatin1Char('a'));

    const int gapId = service->addGap(QStringLiteral("正文刚好到上限"), 0, atLimit, 1, QVariant(), 0);
    QVERIFY(gapId > 0);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("detail")).toString().size(),
             KnowledgeGapService::kMaxDetailLength);

    // 超一个字就必须拒绝，而不是截断后报成功。静默截断是最糟的失败方式：界面说「已保存」，
    // 用户重新打开才发现末尾几句不见了，而那几句往往正是他最想留下的部分。
    failureSpy.clear();
    QCOMPARE(service->addGap(QStringLiteral("正文超一个字"), 0, overLimit, 1, QVariant(), 0), -1);
    QCOMPARE(failureSpy.count(), 1);

    failureSpy.clear();
    QVERIFY(!service->updateGap(gapId, QStringLiteral("改过的标题"), 0, overLimit, 1, QVariant()));
    QCOMPARE(failureSpy.count(), 1);
    // 被拒绝的编辑不能留下任何痕迹：原正文和原标题都得原样在。
    const QVariantMap unchanged = service->getGap(gapId);
    QCOMPARE(unchanged.value(QStringLiteral("detail")).toString().size(),
             KnowledgeGapService::kMaxDetailLength);
    QCOMPARE(unchanged.value(QStringLiteral("title")).toString(), QStringLiteral("正文刚好到上限"));

    failureSpy.clear();
    QVERIFY(!service->resolveGap(gapId, overLimit));
    QCOMPARE(failureSpy.count(), 1);
    // 结论被拒绝时，状态也不能顺手变成已解决。
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));

    // 正好到上限的结论照常保存，证明拒绝的是「超出」而不是「接近上限」。
    QVERIFY(service->resolveGap(gapId, atLimit));
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("resolution")).toString().size(),
             KnowledgeGapService::kMaxDetailLength);
}

void KnowledgeGapServiceTests::rejectsMalformedAndOutOfRangeDueDates()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();

    // 传了内容却解析不出日期是错误，不能静默退化成「未排期」——
    // 那样用户再也等不到这条的提醒，而且完全看不出哪里出了问题。
    QCOMPARE(service->addGap(QStringLiteral("填错日期"), 0, QString(), 1,
                             QStringLiteral("2026-02-31"), 0), -1);
    QCOMPARE(service->addGap(QStringLiteral("非日期"), 0, QString(), 1,
                             QStringLiteral("下周三"), 0), -1);
    QCOMPARE(service->addGap(QStringLiteral("年份越界"), 0, QString(), 1,
                             QStringLiteral("1999-12-31"), 0), -1);
    QCOMPARE(service->addGap(QStringLiteral("年份越界"), 0, QString(), 1,
                             QStringLiteral("2101-01-01"), 0), -1);

    // 空值是合法输入，表示「还没想好什么时候处理」。
    QVERIFY(service->addGap(QStringLiteral("未排期"), 0, QString(), 1, QVariant(), 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("空串也算未排期"), 0, QString(), 1,
                            QStringLiteral("   "), 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("边界年份"), 0, QString(), 1,
                            QStringLiteral("2100-12-31"), 0) > 0);
}

void KnowledgeGapServiceTests::clampsPriorityInsteadOfRejecting()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();

    const int low = service->addGap(QStringLiteral("负优先级"), 0, QString(), -5, QVariant(), 0);
    const int high = service->addGap(QStringLiteral("超大优先级"), 0, QString(), 99, QVariant(), 0);
    QVERIFY(low > 0);
    QVERIFY(high > 0);
    // 夹紧而不是拒绝：不能因为一个次要字段填错，就让用户刚打下的那段内容整个存不进去。
    QCOMPARE(service->getGap(low).value(QStringLiteral("priority")).toInt(),
             KnowledgeGapService::kMinPriority);
    QCOMPARE(service->getGap(high).value(QStringLiteral("priority")).toInt(),
             KnowledgeGapService::kMaxPriority);
}

void KnowledgeGapServiceTests::dueDatePresenceDrivesStatus()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int id = service->captureGap(QStringLiteral("待排期"), 0, 0);
    QVERIFY(id > 0);
    QCOMPARE(service->getGap(id).value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));

    QVERIFY(service->setDueDate(id, logicalToday().addDays(2)));
    QCOMPARE(service->getGap(id).value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusScheduled));

    // 清空排期要能退回待处理，否则一条被取消安排的记录会永远显示成「已安排」。
    QVERIFY(service->setDueDate(id, QVariant()));
    QCOMPARE(service->getGap(id).value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));
    QCOMPARE(service->getGap(id).value(QStringLiteral("dueDate")).toString(), QString());
}

void KnowledgeGapServiceTests::sourceTaskTitleSurvivesTaskDeletion()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int taskId = seedTask(QStringLiteral("复习线代第 3 章"), logicalToday());
    QVERIFY(taskId > 0);

    const int gapId = service->captureGap(QStringLiteral("相似对角化"), 0, taskId);
    QVERIFY(gapId > 0);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("sourceTaskId")).toInt(), taskId);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("sourceTaskTitle")).toString(),
             QStringLiteral("复习线代第 3 章"));

    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    // 外键是 ON DELETE SET NULL，所以 id 会变空；但「这条是在复习线代第 3 章时记的」
    // 属于写这条时的现场，必须留在快照里。
    const QVariantMap afterDelete = service->getGap(gapId);
    QCOMPARE(afterDelete.value(QStringLiteral("sourceTaskId")).toInt(), 0);
    QCOMPARE(afterDelete.value(QStringLiteral("sourceTaskTitle")).toString(),
             QStringLiteral("复习线代第 3 章"));
}

void KnowledgeGapServiceTests::listOrdersUnresolvedFirstAndSinksUnscheduled()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();

    const int unscheduled = service->addGap(QStringLiteral("未排期"), 0, QString(), 2, QVariant(), 0);
    const int future = service->addGap(QStringLiteral("后天"), 0, QString(), 0, today.addDays(2), 0);
    const int overdue = service->addGap(QStringLiteral("已逾期"), 0, QString(), 0, today.addDays(-3), 0);
    const int dueToday = service->addGap(QStringLiteral("今天"), 0, QString(), 0, today, 0);
    const int resolved = service->addGap(QStringLiteral("已解决"), 0, QString(), 2, today.addDays(-1), 0);
    QVERIFY(unscheduled > 0 && future > 0 && overdue > 0 && dueToday > 0 && resolved > 0);
    QVERIFY(service->resolveGap(resolved, QStringLiteral("想明白了")));

    const QStringList titles = titlesOf(service->listGaps(KnowledgeGapService::kFilterAll, 0, QString(), 0));
    // 未排期必须沉到已排期之后。SQLite 默认把 NULL 排在最小值一侧，
    // 只按 due_date 排会让「未排期」冒到「今天到期」前面，正好和要的顺序相反。
    QCOMPARE(titles, (QStringList{QStringLiteral("已逾期"),
                                  QStringLiteral("今天"),
                                  QStringLiteral("后天"),
                                  QStringLiteral("未排期"),
                                  QStringLiteral("已解决")}));

    const QVariantMap overdueRow = findByTitle(
        service->listGaps(KnowledgeGapService::kFilterAll, 0, QString(), 0), QStringLiteral("已逾期"));
    QCOMPARE(overdueRow.value(QStringLiteral("overdue")).toBool(), true);
    QCOMPARE(overdueRow.value(QStringLiteral("overdueDays")).toInt(), 3);

    // 已解决的条目不该再被算成逾期：它已经不需要任何人停下来处理了。
    const QVariantMap resolvedRow = findByTitle(
        service->listGaps(KnowledgeGapService::kFilterAll, 0, QString(), 0), QStringLiteral("已解决"));
    QCOMPARE(resolvedRow.value(QStringLiteral("overdue")).toBool(), false);
    QCOMPARE(resolvedRow.value(QStringLiteral("overdueDays")).toInt(), 0);
}

void KnowledgeGapServiceTests::listFiltersByStatusCategoryAndSearchText()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int mathId = seedCategory(QStringLiteral("数学-%1").arg(QDateTime::currentMSecsSinceEpoch()));
    QVERIFY(mathId > 0);

    const int a = service->addGap(QStringLiteral("特征值怎么算"), mathId,
                                  QStringLiteral("第 87 页那道例题"), 1, QVariant(), 0);
    const int b = service->addGap(QStringLiteral("英语长难句断句"), 0, QString(), 1,
                                  logicalToday(), 0);
    const int c = service->addGap(QStringLiteral("政治时政部分"), 0, QString(), 1, QVariant(), 0);
    QVERIFY(a > 0 && b > 0 && c > 0);
    QVERIFY(service->resolveGap(c, QStringLiteral("看完了强化班")));

    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::StatusOpen, 0, QString(), 0)),
             (QStringList{QStringLiteral("特征值怎么算")}));
    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::StatusScheduled, 0, QString(), 0)),
             (QStringList{QStringLiteral("英语长难句断句")}));
    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::StatusResolved, 0, QString(), 0)),
             (QStringList{QStringLiteral("政治时政部分")}));
    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::kFilterUnresolved, 0, QString(), 0)),
             (QStringList{QStringLiteral("英语长难句断句"), QStringLiteral("特征值怎么算")}));

    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::kFilterAll, mathId, QString(), 0)),
             (QStringList{QStringLiteral("特征值怎么算")}));

    // 正文和结论一起参与搜索：想找回一条旧记录时，记得住的往往是当时写的细节
    // 或者后来写下的答案，而不是标题那几个字。
    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::kFilterAll, 0,
                                        QStringLiteral("第 87 页"), 0)),
             (QStringList{QStringLiteral("特征值怎么算")}));
    QCOMPARE(titlesOf(service->listGaps(KnowledgeGapService::kFilterAll, 0,
                                        QStringLiteral("强化班"), 0)),
             (QStringList{QStringLiteral("政治时政部分")}));
}

void KnowledgeGapServiceTests::resolveKeepsFirstResolvedAtAndReopenKeepsResolution()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int id = service->addGap(QStringLiteral("待想明白"), 0, QString(), 1,
                                   logicalToday().addDays(1), 0);
    QVERIFY(id > 0);

    QVERIFY(service->resolveGap(id, QStringLiteral("第一次的结论")));
    const QString firstResolvedAt = service->getGap(id).value(QStringLiteral("resolvedAt")).toString();
    QVERIFY(!firstResolvedAt.isEmpty());

    // 重复点「已解决」不能把首次想明白的时间抹掉。
    QVERIFY(service->resolveGap(id, QStringLiteral("补充一句")));
    QCOMPARE(service->getGap(id).value(QStringLiteral("resolvedAt")).toString(), firstResolvedAt);
    QCOMPARE(service->getGap(id).value(QStringLiteral("resolution")).toString(),
             QStringLiteral("补充一句"));

    QVERIFY(service->reopenGap(id));
    const QVariantMap reopened = service->getGap(id);
    // 重新打开保留 resolution：上次想到哪了是有价值的，清掉等于逼用户从头再来。
    QCOMPARE(reopened.value(QStringLiteral("resolution")).toString(), QStringLiteral("补充一句"));
    QCOMPARE(reopened.value(QStringLiteral("resolvedAt")).toString(), QString());
    // 有到期日就回到「已安排」，没有才回「待处理」。
    QCOMPARE(reopened.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusScheduled));

    // 不在已解决状态时重新打开应当被明确拒绝，而不是静默成功。
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    QVERIFY(!service->reopenGap(id));
    QCOMPARE(failureSpy.count(), 1);
}

void KnowledgeGapServiceTests::editingResolvedGapDoesNotReopenIt()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int id = service->addGap(QStringLiteral("已想明白"), 0, QString(), 1,
                                   logicalToday().addDays(1), 0);
    QVERIFY(id > 0);
    QVERIFY(service->resolveGap(id, QStringLiteral("结论")));

    // 回来改一下措辞不该把条目重新打开——重新打开必须是显式动作。
    QVERIFY(service->updateGap(id, QStringLiteral("已想明白（改过标题）"), 0,
                               QStringLiteral("补充上下文"), 2, QVariant()));
    const QVariantMap gap = service->getGap(id);
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusResolved));
    QCOMPARE(gap.value(QStringLiteral("title")).toString(),
             QStringLiteral("已想明白（改过标题）"));
    QCOMPARE(gap.value(QStringLiteral("resolution")).toString(), QStringLiteral("结论"));
}

// 产品保证：字段级入口只改交进来的字段；没交的字段取库里现在的值。弹窗开着时另一台改了正文和日期
// （这里直接写库，模拟同步写进来），这边只改内容后保存，另一台的正文和日期还在，低优先级也不被抬高。
// 不认识的键、类型不对的值整次拒绝且什么都不写；没有改动时只确认条目还在。
// 抓住的错误实现：按弹窗打开时的值整条写回（正文、日期被盖回旧值），或没交的字段写成默认值。
void KnowledgeGapServiceTests::updateGapChangesWritesOnlyGivenFields()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int categoryId = seedCategory(QStringLiteral("字段级科目"));
    QVERIFY(categoryId > 0);
    const QDate due = logicalToday().addDays(3);
    const int id = service->addGap(QStringLiteral("原内容"), categoryId, QStringLiteral("原正文"), 0, due, 0);
    QVERIFY(id > 0);

    const QDate remoteDue = logicalToday().addDays(5);
    QSqlQuery remote(DatabaseManager::instance()->database());
    remote.prepare(QStringLiteral("UPDATE knowledge_gaps SET detail = :detail, due_date = :due WHERE id = :id"));
    remote.bindValue(QStringLiteral(":detail"), QStringLiteral("另一台补的正文"));
    remote.bindValue(QStringLiteral(":due"), remoteDue.toString(Qt::ISODate));
    remote.bindValue(QStringLiteral(":id"), id);
    QVERIFY(remote.exec());

    QSignalSpy changed(service, &KnowledgeGapService::gapsChanged);
    QVERIFY(service->updateGapChanges(id, {{QStringLiteral("title"), QStringLiteral("改过的内容")}}));
    QCOMPARE(changed.count(), 1);
    QVariantMap gap = service->getGap(id);
    QCOMPARE(gap.value(QStringLiteral("title")).toString(), QStringLiteral("改过的内容"));
    QCOMPARE(gap.value(QStringLiteral("detail")).toString(), QStringLiteral("另一台补的正文"));
    QCOMPARE(gap.value(QStringLiteral("dueDate")).toString(), remoteDue.toString(Qt::ISODate));
    QCOMPARE(gap.value(QStringLiteral("priority")).toInt(), 0);
    QCOMPARE(gap.value(QStringLiteral("categoryId")).toInt(), categoryId);

    // 只改日期：清空成未排期，状态跟着回到待处理（和整条接口同一口径）。
    QVERIFY(service->updateGapChanges(id, {{QStringLiteral("dueDate"), QString()}}));
    gap = service->getGap(id);
    QCOMPARE(gap.value(QStringLiteral("dueDate")).toString(), QString());
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(), static_cast<int>(KnowledgeGapService::StatusOpen));
    QCOMPARE(gap.value(QStringLiteral("detail")).toString(), QStringLiteral("另一台补的正文"));

    // 整次拒绝，什么都不写。
    changed.clear();
    QVERIFY(!service->updateGapChanges(id, {{QStringLiteral("status"), 2},
                                            {QStringLiteral("title"), QStringLiteral("不该写进去")}}));
    QVERIFY(!service->updateGapChanges(id, {{QStringLiteral("detail"), 5}}));
    QVERIFY(!service->updateGapChanges(id, {{QStringLiteral("priority"), 1.5},
                                            {QStringLiteral("title"), QStringLiteral("不该写进去")}}));
    QCOMPARE(changed.count(), 0);
    QCOMPARE(service->getGap(id).value(QStringLiteral("title")).toString(), QStringLiteral("改过的内容"));

    // 没有改动：条目在就算成功，不在就失败；都不写库。
    QVERIFY(service->updateGapChanges(id, {}));
    QVERIFY(!service->updateGapChanges(id + 1000, {}));
    QCOMPARE(changed.count(), 0);
}

void KnowledgeGapServiceTests::schedulingResolvedGapIsRejected()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int id = service->addGap(QStringLiteral("已解决"), 0, QString(), 1, QVariant(), 0);
    QVERIFY(id > 0);
    QVERIFY(service->resolveGap(id, QStringLiteral("结论")));

    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    QVERIFY(!service->setDueDate(id, logicalToday()));
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(service->getGap(id).value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusResolved));
    QCOMPARE(service->getGap(id).value(QStringLiteral("dueDate")).toString(), QString());
}

void KnowledgeGapServiceTests::batchMoveRollsBackWholeSelectionOnBadId()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int first = service->captureGap(QStringLiteral("第一条"), 0, 0);
    const int second = service->captureGap(QStringLiteral("第二条"), 0, 0);
    QVERIFY(first > 0 && second > 0);

    const QDate target = logicalToday().addDays(3);
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);

    // 夹一个不存在的编号：整批必须退回，不能留下「前一条改了、后一条没改」的中间状态。
    QVERIFY(!service->moveGapsToDate(QVariantList{first, 999999, second}, target));
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(service->getGap(first).value(QStringLiteral("dueDate")).toString(), QString());
    QCOMPARE(service->getGap(second).value(QStringLiteral("dueDate")).toString(), QString());

    QVERIFY(service->moveGapsToDate(QVariantList{first, second}, target));
    QCOMPARE(service->getGap(first).value(QStringLiteral("dueDate")).toString(),
             target.toString(Qt::ISODate));
    QCOMPARE(service->getGap(second).value(QStringLiteral("dueDate")).toString(),
             target.toString(Qt::ISODate));
}

void KnowledgeGapServiceTests::convertToTaskCreatesTaskAndLinksGap()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int categoryId = seedCategory(QStringLiteral("数学-%1").arg(QDateTime::currentMSecsSinceEpoch()));
    QVERIFY(categoryId > 0);

    const int gapId = service->addGap(QStringLiteral("相似对角化"), categoryId,
                                      QStringLiteral("教材第 87 页"), 2, QVariant(), 0);
    QVERIFY(gapId > 0);

    // 当天已有任务时，新任务必须落在末尾，不能插进用户排好的顺序中间。
    const QDate target = logicalToday();
    QVERIFY(seedTask(QStringLiteral("既有任务"), target) > 0);

    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    const int taskId = service->convertToTask(gapId, target);
    QVERIFY(taskId > 0);
    QCOMPARE(tasksSpy.count(), 1);

    const QVariantMap task = TaskManager::instance()->getTask(taskId);
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("相似对角化"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
    // 任务备注带上缺口原文并注明来源：一周后在任务列表里只看标题，
    // 往往已经想不起来当初卡在哪了。
    QVERIFY(task.value(QStringLiteral("notes")).toString().contains(QStringLiteral("教材第 87 页")));
    QVERIFY(task.value(QStringLiteral("notes")).toString()
                .contains(QStringLiteral("来自知识缺口 #%1").arg(gapId)));

    QSqlQuery orderQuery(DatabaseManager::instance()->database());
    orderQuery.prepare(QStringLiteral("SELECT display_order FROM tasks WHERE id = :id"));
    orderQuery.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(orderQuery.exec() && orderQuery.next());
    QCOMPARE(orderQuery.value(0).toInt(), 2);

    const QVariantMap gap = service->getGap(gapId);
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusScheduled));
    QCOMPARE(gap.value(QStringLiteral("linkedTaskId")).toInt(), taskId);
    QCOMPARE(gap.value(QStringLiteral("dueDate")).toString(), target.toString(Qt::ISODate));
}

void KnowledgeGapServiceTests::convertToTaskLeavesGapUntouchedWhenTaskInsertFails()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int gapId = service->captureGap(QStringLiteral("需要安排"), 0, 0);
    QVERIFY(gapId > 0);

    // 制造一次真实的 INSERT 失败，而不是伪造错误码——只有这样测到的才是回滚本身。
    //
    // 能想到的几条自然约束都不好用：knowledge_gaps 和 tasks 的标题都带
    // CHECK(length(trim(title)) > 0)，所以连「把标题改成空格」这一步都会先被数据库挡住。
    // 这里临时加一条唯一索引，再种一条同名同日期的任务，让转任务时的 INSERT 真的撞上它。
    QSqlQuery index(DatabaseManager::instance()->database());
    QVERIFY(index.exec(QStringLiteral(
        "CREATE UNIQUE INDEX tmp_unique_task_title_date ON tasks(title, date)")));
    QVERIFY(seedTask(QStringLiteral("需要安排"), logicalToday()) > 0);

    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    QCOMPARE(service->convertToTask(gapId, logicalToday()), -1);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(tasksSpy.count(), 0);

    // 任务没建成，缺口的状态和关联就必须原样不动；否则会留下一条
    // 指向不存在任务的「已安排」记录，用户永远等不到它出现在任务列表里。
    const QVariantMap gap = service->getGap(gapId);
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));
    QCOMPARE(gap.value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(gap.value(QStringLiteral("dueDate")).toString(), QString());

    // 库里应当只剩预先种下的那条占位任务，转任务没有留下任何半成品。
    QSqlQuery count(DatabaseManager::instance()->database());
    QVERIFY(count.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) && count.next());
    QCOMPARE(count.value(0).toInt(), 1);
    // 计数游标必须先合上：结果集还开着时 SQLite 会一直持有 tasks 的表锁，
    // 紧接着的 DROP INDEX 会以“database table is locked”失败。
    count.finish();

    QSqlQuery dropIndex(DatabaseManager::instance()->database());
    QVERIFY2(dropIndex.exec(QStringLiteral("DROP INDEX tmp_unique_task_title_date")),
             qPrintable(dropIndex.lastError().text()));
}

void KnowledgeGapServiceTests::convertToTaskReportsLinkedTaskCompletionWithoutResolving()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int gapId = service->captureGap(QStringLiteral("需要安排"), 0, 0);
    QVERIFY(gapId > 0);
    const int taskId = service->convertToTask(gapId, logicalToday());
    QVERIFY(taskId > 0);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskCompleted")).toBool(), false);

    QVERIFY(TaskManager::instance()->completeTask(taskId));

    // 做完任务完全可能还是没搞懂，所以只把事实报给界面，由用户决定是否标记已解决。
    // 自动解决会悄悄把没解决的东西标成解决，是最坏的一类数据错误。
    const QVariantMap gap = service->getGap(gapId);
    QCOMPARE(gap.value(QStringLiteral("linkedTaskCompleted")).toBool(), true);
    QCOMPARE(gap.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusScheduled));
}

void KnowledgeGapServiceTests::reminderSummaryUsesLogicalDayBoundary()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();

    QVERIFY(service->addGap(QStringLiteral("今天到期"), 0, QString(), 1, today, 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("明天到期"), 0, QString(), 1, today.addDays(1), 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("逾期 5 天"), 0, QString(), 1, today.addDays(-5), 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("逾期 2 天"), 0, QString(), 1, today.addDays(-2), 0) > 0);
    QVERIFY(service->addGap(QStringLiteral("未排期"), 0, QString(), 1, QVariant(), 0) > 0);
    const int resolvedId = service->addGap(QStringLiteral("已解决的逾期"), 0, QString(), 1,
                                           today.addDays(-9), 0);
    QVERIFY(resolvedId > 0);
    QVERIFY(service->resolveGap(resolvedId, QStringLiteral("结论")));

    const QVariantMap summary = service->getReminderSummary();
    QCOMPARE(summary.value(QStringLiteral("valid")).toBool(), true);
    // 分桶的边界必须正好落在逻辑今天上：今天到期算 dueToday，明天到期两个桶都不进。
    QCOMPARE(summary.value(QStringLiteral("dueToday")).toInt(), 1);
    QCOMPARE(summary.value(QStringLiteral("overdue")).toInt(), 2);
    QCOMPARE(summary.value(QStringLiteral("unscheduled")).toInt(), 1);
    QCOMPARE(summary.value(QStringLiteral("openTotal")).toInt(), 5);
    // 最久的那条决定提示条上的天数；已解决的不参与，它不需要任何人停下来处理。
    QCOMPARE(summary.value(QStringLiteral("oldestOverdueDays")).toInt(), 5);

    // 改日界点会改变「今天」是哪一天，统计必须跟着走。
    //
    // dayStartHour 被 AppSettings 限制在 0–6，所以两个口径只有在凌晨那几个小时里
    // 才会真的指向不同日期。这里不写死期望值，而是按 LogicalDay 现算出应有的位移——
    // 白天跑时位移为 0（断言退化成「结果不变」），凌晨跑时位移为 1 天（断言真的发生重分桶）。
    // 两种情况都能挡住「服务偷偷用了 QDate::currentDate()」这个错误。
    AppSettings::instance()->setDayStartHour(6);
    const QDate shiftedToday = logicalToday();
    const int shiftDays = static_cast<int>(shiftedToday.daysTo(today));
    QVERIFY(shiftDays == 0 || shiftDays == 1);

    const QVariantMap shifted = service->getReminderSummary();
    QCOMPARE(shifted.value(QStringLiteral("dueToday")).toInt(), shiftDays == 0 ? 1 : 0);
    QCOMPARE(shifted.value(QStringLiteral("overdue")).toInt(), shiftDays == 0 ? 2 : 1);
    QCOMPARE(shifted.value(QStringLiteral("unscheduled")).toInt(), 1);
    QCOMPARE(shifted.value(QStringLiteral("oldestOverdueDays")).toInt(), 5 - shiftDays);

    AppSettings::instance()->setDayStartHour(4);
}

void KnowledgeGapServiceTests::convertToTaskRefusesWhileLinkedTaskIsOpen()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();
    const int gapId = service->captureGap(QStringLiteral("重复点今天做"), 0, 0);
    QVERIFY(gapId > 0);

    const int firstTaskId = service->convertToTask(gapId, today);
    QVERIFY(firstTaskId > 0);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskOpen")).toBool(), true);

    // 连点两次「今天做」、或提示条的「全部加到今天」点了又点，都不能建出第二条同名任务，
    // 更不能把关联改写到新任务上，让第一条任务变成没人认领的孤儿。
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    QCOMPARE(service->convertToTask(gapId, today), -1);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(tasksSpy.count(), 0);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskId")).toInt(), firstTaskId);

    QSqlQuery count(DatabaseManager::instance()->database());
    QVERIFY(count.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) && count.next());
    QCOMPARE(count.value(0).toInt(), 1);
    count.finish();

    // 任务做完了但还没想明白，允许再排一次，关联挪到新任务上。
    QVERIFY(TaskManager::instance()->completeTask(firstTaskId));
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskOpen")).toBool(), false);
    const int secondTaskId = service->convertToTask(gapId, today);
    QVERIFY(secondTaskId > 0);
    QVERIFY(secondTaskId != firstTaskId);
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskId")).toInt(), secondTaskId);

    // 关联任务被删掉同样等于没有关联，可以重新转。直接删行，走的是外键 SET NULL 那条路。
    QSqlQuery removeTask(DatabaseManager::instance()->database());
    removeTask.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    removeTask.bindValue(QStringLiteral(":id"), secondTaskId);
    QVERIFY(removeTask.exec());
    removeTask.finish();
    QCOMPARE(service->getGap(gapId).value(QStringLiteral("linkedTaskOpen")).toBool(), false);
    QVERIFY(service->convertToTask(gapId, today) > 0);
}

void KnowledgeGapServiceTests::convertToTaskKeepsOverdueDueDate()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();

    const int overdueId = service->addGap(QStringLiteral("拖了五天"), 0, QString(), 1, today.addDays(-5), 0);
    const int unscheduledId = service->captureGap(QStringLiteral("还没排期"), 0, 0);
    const int futureId = service->addGap(QStringLiteral("原定下周"), 0, QString(), 1, today.addDays(7), 0);
    QVERIFY(overdueId > 0);
    QVERIFY(unscheduledId > 0);
    QVERIFY(futureId > 0);

    QVERIFY(service->convertToTask(overdueId, today) > 0);
    QVERIFY(service->convertToTask(unscheduledId, today) > 0);
    QVERIFY(service->convertToTask(futureId, today) > 0);

    // 逾期不顺延：转成今天的任务不能把「拖了五天」清零。今日页的「全部加到今天」
    // 正是从逾期条目发起的，覆盖到期日等于每点一次就抹掉一批逾期记录。
    const QVariantMap overdue = service->getGap(overdueId);
    QCOMPARE(overdue.value(QStringLiteral("dueDate")).toString(),
             today.addDays(-5).toString(Qt::ISODate));
    QCOMPARE(overdue.value(QStringLiteral("overdue")).toBool(), true);
    QCOMPARE(overdue.value(QStringLiteral("overdueDays")).toInt(), 5);

    // 未排期补成任务日期：状态由到期日派生，「已安排」却没有到期日会让两者分家。
    const QVariantMap unscheduled = service->getGap(unscheduledId);
    QCOMPARE(unscheduled.value(QStringLiteral("dueDate")).toString(), today.toString(Qt::ISODate));
    QCOMPARE(unscheduled.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusScheduled));

    // 原定以后的提前到任务日期：提前处理不抹掉任何拖延记录。
    QCOMPARE(service->getGap(futureId).value(QStringLiteral("dueDate")).toString(),
             today.toString(Qt::ISODate));
}

void KnowledgeGapServiceTests::reminderSummarySkipsGapsWhoseTaskIsStillOpen()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();
    const int overdueId = service->addGap(QStringLiteral("逾期三天"), 0, QString(), 1, today.addDays(-3), 0);
    const int dueTodayId = service->addGap(QStringLiteral("今天到期"), 0, QString(), 1, today, 0);
    QVERIFY(overdueId > 0);
    QVERIFY(dueTodayId > 0);

    QVariantMap summary = service->getReminderSummary();
    QCOMPARE(summary.value(QStringLiteral("overdue")).toInt(), 1);
    QCOMPARE(summary.value(QStringLiteral("dueToday")).toInt(), 1);

    const int overdueTaskId = service->convertToTask(overdueId, today);
    QVERIFY(overdueTaskId > 0);
    QVERIFY(service->convertToTask(dueTodayId, today) > 0);

    // 已经变成任务、还没做完的条目由任务列表负责提醒。提示条若继续算上它们，
    // 「全部加到今天」就一直亮着，诱导用户一遍遍去点。
    summary = service->getReminderSummary();
    QCOMPARE(summary.value(QStringLiteral("overdue")).toInt(), 0);
    QCOMPARE(summary.value(QStringLiteral("dueToday")).toInt(), 0);
    QCOMPARE(summary.value(QStringLiteral("oldestOverdueDays")).toInt(), 0);
    // 总数照旧统计全部未解决条目：转成任务不等于解决。
    QCOMPARE(summary.value(QStringLiteral("openTotal")).toInt(), 2);

    // 任务做完但条目没标记解决：做完不等于想明白，重新回到提醒里，拖延天数仍按原到期日算。
    QVERIFY(TaskManager::instance()->completeTask(overdueTaskId));
    summary = service->getReminderSummary();
    QCOMPARE(summary.value(QStringLiteral("overdue")).toInt(), 1);
    QCOMPARE(summary.value(QStringLiteral("oldestOverdueDays")).toInt(), 3);
}

// 产品保证：「全部加到今天」只转今天到期和已逾期、未解决、还没有未完成关联任务的条目，
// 按 listGaps 的顺序逐条转成今天的任务；其余条目一条都不碰，逾期条目的到期日保持原样。
// 抓住的错误实现：不跳过已有未完成任务的条目（建出重复任务）、把明天到期或没排期的也转了、
// 把已解决的逾期条目转了、转完顺延逾期日期、按编号而不是 listGaps 的顺序转。
void KnowledgeGapServiceTests::convertDueGapsToTasksConvertsOnlyDueUnresolvedWithoutOpenTask()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();
    const QString titleA = QStringLiteral("A 今天到期");
    const QString titleB = QStringLiteral("B 逾期三天");
    const QString titleC = QStringLiteral("C 明天到期");
    const QString titleD = QStringLiteral("D 没排日期");
    const QString titleE = QStringLiteral("E 已解决的逾期");
    const QString titleF = QStringLiteral("F 逾期但任务没做完");
    const QString titleG = QStringLiteral("G 逾期且任务已做完");

    // 创建顺序是 A 到 G，listGaps 的顺序按到期日：G(-5) F(-4) B(-3) A(今天) C(明天) D(没排期)，
    // 转换顺序与创建顺序不同，按编号转的实现会得到另一个任务顺序。
    const int gapA = service->addGap(titleA, 0, QString(), 1, today, 0);
    const int gapB = service->addGap(titleB, 0, QString(), 1, today.addDays(-3), 0);
    const int gapC = service->addGap(titleC, 0, QString(), 1, today.addDays(1), 0);
    const int gapD = service->captureGap(titleD, 0, 0);
    const int gapE = service->addGap(titleE, 0, QString(), 1, today.addDays(-2), 0);
    const int gapF = service->addGap(titleF, 0, QString(), 1, today.addDays(-4), 0);
    const int gapG = service->addGap(titleG, 0, QString(), 1, today.addDays(-5), 0);
    QVERIFY(gapA > 0 && gapB > 0 && gapC > 0 && gapD > 0 && gapE > 0 && gapF > 0 && gapG > 0);
    QVERIFY(service->resolveGap(gapE, QStringLiteral("想明白了")));
    // F 已有一条没做完的任务；G 的任务做完了，但条目没标记解决，做完不等于想明白。
    const int taskF = service->convertToTask(gapF, today);
    const int taskG = service->convertToTask(gapG, today);
    QVERIFY(taskF > 0 && taskG > 0);
    QVERIFY(TaskManager::instance()->completeTask(taskG));

    // 前提：每一条在列表里的到期状态，和这条用例要验证的分类一致。
    const QVariantList rows = service->listGaps(KnowledgeGapService::kFilterUnresolved, 0, QString(), 0);
    QCOMPARE(titlesOf(rows), (QStringList{titleG, titleF, titleB, titleA, titleC, titleD}));
    QVERIFY(findByTitle(rows, titleE).isEmpty());
    struct Premise {
        QString title;
        bool dueToday;
        bool overdue;
        bool linkedTaskOpen;
    };
    const Premise premises[] = {
        {titleA, true, false, false},
        {titleB, false, true, false},
        {titleC, false, false, false},
        {titleD, false, false, false},
        {titleF, false, true, true},
        {titleG, false, true, false},
    };
    for (const Premise& premise : premises) {
        const QVariantMap row = findByTitle(rows, premise.title);
        QVERIFY2(!row.isEmpty(), qPrintable(premise.title));
        QVERIFY2(row.value(QStringLiteral("dueToday")).toBool() == premise.dueToday, qPrintable(premise.title));
        QVERIFY2(row.value(QStringLiteral("overdue")).toBool() == premise.overdue, qPrintable(premise.title));
        QVERIFY2(row.value(QStringLiteral("linkedTaskOpen")).toBool() == premise.linkedTaskOpen,
                 qPrintable(premise.title));
    }
    const int tasksBefore = taskCount();
    QCOMPARE(tasksBefore, 2);

    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    const QVariantMap result = service->convertDueGapsToTasks();

    QVERIFY(hasBatchResultKeys(result));
    QCOMPARE(result.value(QStringLiteral("converted")).toInt(), 3);
    QCOMPARE(result.value(QStringLiteral("failed")).toInt(), 0);
    QCOMPARE(result.value(QStringLiteral("reason")).toString(), QString());
    QCOMPARE(failureSpy.count(), 0);
    QVERIFY(tasksSpy.count() >= 1);

    // 新建的三条都在今天、未完成，标题与条目一致，顺序是 listGaps 的顺序 G、B、A，不是创建顺序 A、B、G。
    QSqlQuery created(DatabaseManager::instance()->database());
    created.prepare(QStringLiteral(
        "SELECT id, title, date, completed, display_order FROM tasks WHERE id > :last ORDER BY id"));
    created.bindValue(QStringLiteral(":last"), qMax(taskF, taskG));
    QVERIFY(created.exec());
    QStringList createdTitles;
    QList<int> createdIds;
    QList<int> createdOrders;
    while (created.next()) {
        createdIds.append(created.value(0).toInt());
        createdTitles.append(created.value(1).toString());
        QCOMPARE(created.value(2).toString(), today.toString(Qt::ISODate));
        QCOMPARE(created.value(3).toInt(), 0);
        createdOrders.append(created.value(4).toInt());
    }
    created.finish();
    QCOMPARE(createdTitles, (QStringList{titleG, titleB, titleA}));
    QVERIFY(createdOrders.at(0) < createdOrders.at(1) && createdOrders.at(1) < createdOrders.at(2));
    // 任务总数只多出这三条：F 没有生成第二条，C、D、E 也没有任务。
    QCOMPARE(taskCount(), tasksBefore + 3);

    QCOMPARE(service->getGap(gapG).value(QStringLiteral("linkedTaskId")).toInt(), createdIds.at(0));
    QCOMPARE(service->getGap(gapB).value(QStringLiteral("linkedTaskId")).toInt(), createdIds.at(1));
    QCOMPARE(service->getGap(gapA).value(QStringLiteral("linkedTaskId")).toInt(), createdIds.at(2));
    QCOMPARE(service->getGap(gapF).value(QStringLiteral("linkedTaskId")).toInt(), taskF);

    // 逾期不顺延：B 转成今天的任务后，到期日仍是三天前。
    QCOMPARE(service->getGap(gapB).value(QStringLiteral("dueDate")).toString(),
             today.addDays(-3).toString(Qt::ISODate));
    // 没转的条目原样不动：转了的话，明天到期的会被提前到今天，没排期的会被补成今天。
    const QVariantMap untouchedC = service->getGap(gapC);
    QCOMPARE(untouchedC.value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(untouchedC.value(QStringLiteral("dueDate")).toString(), today.addDays(1).toString(Qt::ISODate));
    const QVariantMap untouchedD = service->getGap(gapD);
    QCOMPARE(untouchedD.value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(untouchedD.value(QStringLiteral("dueDate")).toString(), QString());
    QCOMPARE(untouchedD.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusOpen));
    const QVariantMap untouchedE = service->getGap(gapE);
    QCOMPARE(untouchedE.value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(untouchedE.value(QStringLiteral("status")).toInt(),
             static_cast<int>(KnowledgeGapService::StatusResolved));
}

// 产品保证：批量转换里有的条目失败时，成功的照常保留，返回成功数、失败数和最后一条失败的原因；
// 每条失败仍照常播报 operationFailed，别的监听方行为不变。
// 抓住的错误实现：失败后整批回滚或提前返回（成功的被撤销、后面的没转）、reason 记成第一条而不是最后一条、
// 按编号而不是 listGaps 的顺序转（最后一条失败变成另一条）、吞掉逐条的失败播报。
void KnowledgeGapServiceTests::convertDueGapsToTasksKeepsSuccessesAndReportsTheLastFailure()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();
    const QString blockedTitle = QStringLiteral("触发器拦下的");
    const QString longTitle = QStringLiteral("正文太长的");
    const QString okTitle = QStringLiteral("能转成功的");

    // 创建顺序（触发器那条、长正文那条、能成功的那条）与 listGaps 的顺序（按到期日）不同：
    // 长正文(-5) 能成功的(-4) 触发器拦下的(-3)，成功的那条夹在两条失败之间。
    const int blockedId = service->addGap(blockedTitle, 0, QString(), 1, today.addDays(-3), 0);
    // 正文刚好到上限能存下来，但加上「来自知识缺口 #N」的来源说明就超过任务备注上限，转任务会被拒绝。
    const QString longDetail(KnowledgeGapService::kMaxDetailLength, QChar(0x6587));
    const int longId = service->addGap(longTitle, 0, longDetail, 1, today.addDays(-5), 0);
    const int okId = service->addGap(okTitle, 0, QString(), 1, today.addDays(-4), 0);
    QVERIFY(blockedId > 0 && longId > 0 && okId > 0);

    const QVariantList rows = service->listGaps(KnowledgeGapService::kFilterUnresolved, 0, QString(), 0);
    QCOMPARE(titlesOf(rows), (QStringList{longTitle, okTitle, blockedTitle}));
    for (const QVariant& row : rows) {
        QVERIFY(row.toMap().value(QStringLiteral("overdue")).toBool());
        QVERIFY(!row.toMap().value(QStringLiteral("linkedTaskOpen")).toBool());
    }

    // 第二种失败来自数据库本身：临时触发器让这一条任务的 INSERT 真的被 SQLite 拒绝。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY2(query.exec(QStringLiteral(
                 "CREATE TEMP TRIGGER fail_gap_task_insert BEFORE INSERT ON tasks "
                 "WHEN NEW.title = '%1' BEGIN SELECT RAISE(ABORT, '测试：磁盘已满'); END").arg(blockedTitle)),
             qPrintable(query.lastError().text()));
    const auto dropTrigger = qScopeGuard([] {
        QSqlQuery drop(DatabaseManager::instance()->database());
        drop.exec(QStringLiteral("DROP TRIGGER IF EXISTS fail_gap_task_insert"));
    });
    QCOMPARE(taskCount(), 0);

    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    const QVariantMap result = service->convertDueGapsToTasks();

    QVERIFY(hasBatchResultKeys(result));
    QCOMPARE(result.value(QStringLiteral("converted")).toInt(), 1);
    QCOMPARE(result.value(QStringLiteral("failed")).toInt(), 2);
    // 每条失败各播报一次，且顺序就是转换顺序：先是长正文，后是触发器拦下的。
    QCOMPARE(failureSpy.count(), 2);
    const QString firstFailure = failureSpy.at(0).at(0).toString();
    const QString lastFailure = failureSpy.at(1).at(0).toString();
    QVERIFY2(firstFailure.contains(QStringLiteral("备注上限")), qPrintable(firstFailure));
    QVERIFY2(lastFailure.contains(QStringLiteral("创建任务失败")), qPrintable(lastFailure));
    QVERIFY(firstFailure != lastFailure);
    // 返回的是最后一条失败的原因，不是第一条。
    QCOMPARE(result.value(QStringLiteral("reason")).toString(), lastFailure);

    // 成功的那条确实建了任务，没有因为它后面的失败被撤销；两条失败的条目没留下半成品。
    const int okTaskId = service->getGap(okId).value(QStringLiteral("linkedTaskId")).toInt();
    QVERIFY(okTaskId > 0);
    const QVariantMap okTask = TaskManager::instance()->getTask(okTaskId);
    QCOMPARE(okTask.value(QStringLiteral("title")).toString(), okTitle);
    QCOMPARE(okTask.value(QStringLiteral("date")).toDate(), today);
    QCOMPARE(okTask.value(QStringLiteral("completed")).toBool(), false);
    QCOMPARE(taskCount(), 1);
    QCOMPARE(service->getGap(longId).value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(service->getGap(blockedId).value(QStringLiteral("linkedTaskId")).toInt(), 0);
    QCOMPARE(tasksSpy.count(), 1);
}

// 产品保证：没有到期条目可转时「全部加到今天」什么都不做：返回 0、0、空原因，
// 不新建任务、不发 tasksAffected、不写库。
// 抓住的错误实现：没有可转的条目时仍去碰库、把明天到期或没排期的当成到期、
// 把已有未完成任务的逾期条目再转一次（被拒绝，白算一次失败）。
void KnowledgeGapServiceTests::convertDueGapsToTasksWithNothingDueChangesNothing()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const QDate today = logicalToday();

    // 四类看起来像、但不该转的条目：明天到期、没排期、已解决的逾期、逾期但已有没做完的任务。
    const int tomorrowId = service->addGap(QStringLiteral("明天到期"), 0, QString(), 1, today.addDays(1), 0);
    const int unscheduledId = service->captureGap(QStringLiteral("没排日期"), 0, 0);
    const int resolvedId = service->addGap(QStringLiteral("已解决的逾期"), 0, QString(), 1,
                                           today.addDays(-2), 0);
    const int openTaskId = service->addGap(QStringLiteral("逾期但任务没做完"), 0, QString(), 1,
                                           today.addDays(-4), 0);
    QVERIFY(tomorrowId > 0 && unscheduledId > 0 && resolvedId > 0 && openTaskId > 0);
    QVERIFY(service->resolveGap(resolvedId, QStringLiteral("想明白了")));
    QVERIFY(service->convertToTask(openTaskId, today) > 0);

    // 前提：提示条的摘要也认为没有到期条目，未解决的三条都不满足转换条件。
    const QVariantMap summary = service->getReminderSummary();
    QCOMPARE(summary.value(QStringLiteral("valid")).toBool(), true);
    QCOMPARE(summary.value(QStringLiteral("dueToday")).toInt(), 0);
    QCOMPARE(summary.value(QStringLiteral("overdue")).toInt(), 0);
    const QVariantList rows = service->listGaps(KnowledgeGapService::kFilterUnresolved, 0, QString(), 0);
    QCOMPARE(titlesOf(rows), (QStringList{QStringLiteral("逾期但任务没做完"), QStringLiteral("明天到期"),
                                          QStringLiteral("没排日期")}));
    const int tasksBefore = taskCount();
    QCOMPARE(tasksBefore, 1);

    QSignalSpy tasksSpy(service, &KnowledgeGapService::tasksAffected);
    QSignalSpy changedSpy(service, &KnowledgeGapService::gapsChanged);
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);
    const qlonglong writesBefore = totalDbChanges();
    QVERIFY(writesBefore >= 0);

    const QVariantMap result = service->convertDueGapsToTasks();

    QVERIFY(hasBatchResultKeys(result));
    QCOMPARE(result.value(QStringLiteral("converted")).toInt(), 0);
    QCOMPARE(result.value(QStringLiteral("failed")).toInt(), 0);
    QCOMPARE(result.value(QStringLiteral("reason")).toString(), QString());
    QCOMPARE(tasksSpy.count(), 0);
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(failureSpy.count(), 0);
    QCOMPARE(taskCount(), tasksBefore);
    QCOMPARE(totalDbChanges(), writesBefore);
}

void KnowledgeGapServiceTests::operationsFailSafelyWhenDatabaseIsClosed()
{
    KnowledgeGapService* service = KnowledgeGapService::instance();
    const int gapId = service->captureGap(QStringLiteral("关库前记下的"), 0, 0);
    QVERIFY(gapId > 0);

    DatabaseManager::instance()->close();
    QSignalSpy failureSpy(service, &KnowledgeGapService::operationFailed);

    // 查询失败不能伪装成「就是没有数据」：界面必须能把空结果和读取失败区分开。
    QVERIFY(service->listGaps(KnowledgeGapService::kFilterAll, 0, QString(), 0).isEmpty());
    QVERIFY(service->getGap(gapId).isEmpty());
    QCOMPARE(service->getReminderSummary().value(QStringLiteral("valid")).toBool(), false);

    QCOMPARE(service->captureGap(QStringLiteral("写不进去"), 0, 0), -1);
    QVERIFY(!service->updateGap(gapId, QStringLiteral("改不动"), 0, QString(), 1, QVariant()));
    QVERIFY(!service->setDueDate(gapId, logicalToday()));
    QVERIFY(!service->resolveGap(gapId, QString()));
    QVERIFY(!service->reopenGap(gapId));
    QVERIFY(!service->deleteGap(gapId));
    QCOMPARE(service->convertToTask(gapId, logicalToday()), -1);

    QVERIFY(failureSpy.count() >= 10);

    QVERIFY(DatabaseManager::instance()->initialize(m_databasePath));
}

QTEST_MAIN(KnowledgeGapServiceTests)
#include "KnowledgeGapServiceTests.moc"

void KnowledgeGapServiceTests::conversionRejectsOverlongNotesAndSearchIsLiteral()
{
    auto* service = KnowledgeGapService::instance();
    const int id = service->captureGap(QStringLiteral("百分号%与下划线_!"), 0, 0);
    QVERIFY(id > 0);
    QVERIFY(service->captureGap(QStringLiteral("普通条目"), 0, 0) > 0);
    for (const QString& needle : {QStringLiteral("%"), QStringLiteral("_"), QStringLiteral("!")}) {
        const QVariantList rows = service->listGaps(KnowledgeGapService::kFilterAll, 0, needle, 0);
        QCOMPARE(rows.size(), 1);
        QCOMPARE(rows.first().toMap().value(QStringLiteral("id")).toInt(), id);
    }
    const QString detail(2000, QChar(0x6587));
    QVERIFY(service->updateGap(id, QStringLiteral("完整原文"), 0, detail, 1, QVariant()));
    QVERIFY(service->convertToTask(id, logicalToday()) < 0);
    QCOMPARE(service->getGap(id).value(QStringLiteral("detail")).toString(), detail);
    QSqlQuery count(DatabaseManager::instance()->database());
    QVERIFY(count.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")));
    QVERIFY(count.next());
    QCOMPARE(count.value(0).toInt(), 0);
}
