#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
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
    void rejectsMalformedAndOutOfRangeDueDates();
    void clampsPriorityInsteadOfRejecting();
    void dueDatePresenceDrivesStatus();
    void sourceTaskTitleSurvivesTaskDeletion();
    void listOrdersUnresolvedFirstAndSinksUnscheduled();
    void listFiltersByStatusCategoryAndSearchText();
    void resolveKeepsFirstResolvedAtAndReopenKeepsResolution();
    void editingResolvedGapDoesNotReopenIt();
    void schedulingResolvedGapIsRejected();
    void batchMoveRollsBackWholeSelectionOnBadId();
    void convertToTaskCreatesTaskAndLinksGap();
    void convertToTaskLeavesGapUntouchedWhenTaskInsertFails();
    void convertToTaskReportsLinkedTaskCompletionWithoutResolving();
    void convertToTaskRefusesWhileLinkedTaskIsOpen();
    void convertToTaskKeepsOverdueDueDate();
    void reminderSummaryUsesLogicalDayBoundary();
    void reminderSummarySkipsGapsWhoseTaskIsStillOpen();
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
