#include <QSignalSpy>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QDir>
#include <QDateTime>
#include <QSqlDatabase>
#include <QtTest>

#include "../src/services/DatabaseManager.h"
#include "../src/services/MemoService.h"

class MemoServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();
    void createReadUpdateDeletePreservePlainText();
    void emptyDraftAndUnicodeLengthBoundaries();
    void invalidFieldsIdsAndCategoriesAreRejected();
    void listGroupsAndFiltersByCategoryOrder();
    void creationAndCategoryMoveAppendToDestination();
    void overflowingSortOrderIsRejectedUntilReordered();
    void deletingCategoryKeepsMemoUnclassified();
    void reorderValidatesFullSameCategorySelection();
    void reorderRollsBackAfterRealSqlFailure();
    void failedInsertAndUpdateLeaveDataAndSignalsIntact();
    void unchangedSaveAndReorderDoNotChangeTimestamp();
    void movingMemosKeepsTheirUpdatedTime();
    void databaseReopenNotifiesAndClosedDatabaseFails();
    void readMemosReportsFailureInReturnValue();
    void version19MigrationPreservesDataAndSnapshot();
    void brokenMemoSchemaIsRejected_data();
    void brokenMemoSchemaIsRejected();
    void futureDatabaseIsRejectedBeforeWriting();

private:
    QTemporaryDir* m_tempDir = nullptr;
    int seedCategory(const QString& name, int order);
};

namespace {
QVariantList idsOf(const QVariantList& rows)
{
    QVariantList ids;
    for (const QVariant& row : rows) {
        ids.append(row.toMap().value(QStringLiteral("id")));
    }
    return ids;
}

int scalar(const QString& sql)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    return query.exec(sql) && query.next() ? query.value(0).toInt() : -1;
}
}

void MemoServiceTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("memos.db"))));
}

void MemoServiceTests::cleanup()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

int MemoServiceTests::seedCategory(const QString& name, int order)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("INSERT INTO categories (name, color, is_preset, display_order) VALUES (:name, '#567890', 0, :order)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":order"), order);
    return query.exec() ? query.lastInsertId().toInt() : -1;
}

void MemoServiceTests::createReadUpdateDeletePreservePlainText()
{
    // 产品保证：备忘的空标题和正文原样保存，创建时间有效，内容更新时间与同步版本一致。
    auto* service = MemoService::instance();
    QSignalSpy changed(service, &MemoService::memosChanged);
    const QString body = QStringLiteral("  第 8 讲做完\r\n1000 题第 3 章\n\n");
    const int id = service->createMemo(QString(), body);
    QVERIFY(id > 0);
    QCOMPARE(changed.count(), 1);
    auto memo = service->getMemo(id);
    QCOMPARE(memo.value(QStringLiteral("body")).toString(), body);
    QCOMPARE(memo.value(QStringLiteral("displayTitle")).toString(), QStringLiteral("  第 8 讲做完"));
    // 创建时间保留服务写下的实际时刻；更新时间会由同步触发器对齐到内容版本时间，可能相差毫秒。
    QVERIFY(QDateTime::fromString(memo.value(QStringLiteral("updatedAt")).toString(), Qt::ISODateWithMs).isValid());
    QSqlQuery version(DatabaseManager::instance()->database());
    version.prepare(QStringLiteral("SELECT v_time FROM sync_field_versions WHERE tbl='memos' "
                                   "AND field='body' AND sync_id=(SELECT sync_id FROM memos WHERE id=:id)"));
    version.bindValue(QStringLiteral(":id"), id);
    QVERIFY(version.exec() && version.next());
    QCOMPARE(QDateTime::fromString(memo.value(QStringLiteral("updatedAt")).toString(), Qt::ISODateWithMs).toMSecsSinceEpoch(),
             version.value(0).toLongLong());
    version.finish();
    QVERIFY(QDateTime::fromString(memo.value(QStringLiteral("createdAt")).toString(), Qt::ISODateWithMs).isValid());
    const QVariant createdAt = memo.value(QStringLiteral("createdAt"));
    QVERIFY(service->updateMemo(id, {{QStringLiteral("title"), QStringLiteral(" 数学 ")}}));
    memo = service->getMemo(id);
    QCOMPARE(memo.value(QStringLiteral("title")).toString(), QStringLiteral(" 数学 "));
    QCOMPARE(memo.value(QStringLiteral("body")).toString(), body);
    // 按字段保存：之后只改正文不能把已经保存的新标题写回旧值。
    QVERIFY(service->updateMemo(id, {{QStringLiteral("body"), QStringLiteral("新进度")}}));
    memo = service->getMemo(id);
    QCOMPARE(memo.value(QStringLiteral("title")).toString(), QStringLiteral(" 数学 "));
    QCOMPARE(memo.value(QStringLiteral("body")).toString(), QStringLiteral("新进度"));
    QCOMPARE(memo.value(QStringLiteral("createdAt")), createdAt);
    QVERIFY(service->deleteMemo(id));
    QCOMPARE(changed.count(), 4);
    QVERIFY(service->listMemos().isEmpty());
    QSignalSpy failure(service, &MemoService::operationFailed);
    QVERIFY(!service->deleteMemo(id));
    QVERIFY(service->getMemo(id).isEmpty());
    QCOMPARE(failure.count(), 2);
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 0);
}

void MemoServiceTests::emptyDraftAndUnicodeLengthBoundaries()
{
    auto* service = MemoService::instance();
    const int draft = service->createMemo(QString(), QString());
    QVERIFY(draft > 0);
    QCOMPARE(service->getMemo(draft).value(QStringLiteral("body")).toString(), QStringLiteral(""));
    const QString title(60, QChar(0x6570));
    const QString body(10000, QChar(0x6587));
    const int id = service->createMemo(title, body);
    QVERIFY(id > 0);
    QSignalSpy failed(service, &MemoService::operationFailed);
    QSignalSpy changed(service, &MemoService::memosChanged);
    QCOMPARE(service->createMemo(title + QLatin1Char('x'), body), -1);
    QCOMPARE(service->createMemo(title, body + QLatin1Char('x')), -1);
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("title"), title + QLatin1Char('x')}}));
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("body"), body + QLatin1Char('x')}}));
    QCOMPARE(service->getMemo(id).value(QStringLiteral("body")).toString(), body);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("title")).toString(), title);
    QCOMPARE(failed.count(), 4);
    QCOMPARE(changed.count(), 0);
    QString emojiTitle;
    for (int index = 0; index < 60; ++index) {
        emojiTitle += QString::fromUtf8("🍅");
    }
    QVERIFY(service->createMemo(emojiTitle, QString()) > 0);
    QCOMPARE(service->createMemo(emojiTitle + QString::fromUtf8("🍅"), QString()), -1);
    QCOMPARE(service->createMemo(QStringLiteral("空字符") + QChar::Null, QString()), -1);
}

void MemoServiceTests::invalidFieldsIdsAndCategoriesAreRejected()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("原文"), QStringLiteral("完整正文"));
    QVERIFY(id > 0);
    QSignalSpy changed(service, &MemoService::memosChanged);
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("sortOrder"), 5}}));
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("body"), 123}}));
    for (const QVariant& invalid : {QVariant(-1), QVariant(1.5), QVariant(true), QVariant(QStringLiteral("错误")), QVariant()}) {
        QVERIFY(!service->updateMemo(id, {{QStringLiteral("categoryId"), invalid}}));
    }
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("categoryId"), 999999}}));
    QVERIFY(!service->updateMemo(999999, {{QStringLiteral("body"), QStringLiteral("改动")}}));
    QVERIFY(!service->updateMemo(0, {}));
    QCOMPARE(service->createMemo(QString(), QString(), -1), -1);
    QCOMPARE(service->createMemo(QString(), QString(), 999999), -1);
    QVERIFY(service->listMemos(-2).isEmpty());
    QCOMPARE(changed.count(), 0);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("body")).toString(), QStringLiteral("完整正文"));
}

void MemoServiceTests::listGroupsAndFiltersByCategoryOrder()
{
    auto* service = MemoService::instance();
    const int lateCategory = seedCategory(QStringLiteral("靠后"), 20);
    const int earlyCategory = seedCategory(QStringLiteral("靠前"), 10);
    QVERIFY(lateCategory > 0 && earlyCategory > 0);
    const int unclassified = service->createMemo(QStringLiteral("未分类"), QString());
    const int late = service->createMemo(QStringLiteral("后科"), QString(), lateCategory);
    const int first = service->createMemo(QStringLiteral("前科第一"), QString(), earlyCategory);
    const int second = service->createMemo(QStringLiteral("前科第二"), QString(), earlyCategory);
    QCOMPARE(idsOf(service->listMemos()), (QVariantList{first, second, late, unclassified}));
    QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{unclassified}));
    QCOMPARE(idsOf(service->listMemos(earlyCategory)), (QVariantList{first, second}));
    QVERIFY(service->listMemos(999999).isEmpty());
    QCOMPARE(service->getMemo(late).value(QStringLiteral("categoryName")).toString(), QStringLiteral("靠后"));
    QCOMPARE(service->getMemo(late).value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#567890"));
}

void MemoServiceTests::creationAndCategoryMoveAppendToDestination()
{
    auto* service = MemoService::instance();
    const int category = seedCategory(QStringLiteral("移动目标科目"), 8);
    QVERIFY(category > 0);
    const int existing = service->createMemo(QStringLiteral("已有"), QString(), category);
    const int move = service->createMemo(QStringLiteral("移动"), QString());
    QVERIFY(service->updateMemo(move, {{QStringLiteral("categoryId"), category}}));
    QCOMPARE(idsOf(service->listMemos(category)), (QVariantList{existing, move}));
    QCOMPARE(service->getMemo(move).value(QStringLiteral("sortOrder")).toInt(), 2);
    const int last = service->createMemo(QStringLiteral("新建"), QString(), category);
    QCOMPARE(service->getMemo(last).value(QStringLiteral("sortOrder")).toInt(), 3);
    const int unclassified = service->createMemo(QStringLiteral("未分类已有"), QString());
    QVERIFY(service->updateMemo(move, {{QStringLiteral("categoryId"), 0}}));
    QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{unclassified, move}));
}

void MemoServiceTests::deletingCategoryKeepsMemoUnclassified()
{
    auto* service = MemoService::instance();
    const int category = seedCategory(QStringLiteral("删除的科目"), 10);
    const int id = service->createMemo(QStringLiteral("保留"), QStringLiteral("手写进度"), category);
    QVERIFY(id > 0);
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), category);
    QVERIFY(query.exec());
    QCOMPARE(service->getMemo(id).value(QStringLiteral("categoryId")).toInt(), 0);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("body")).toString(), QStringLiteral("手写进度"));
    QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{id}));
}

void MemoServiceTests::overflowingSortOrderIsRejectedUntilReordered()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("末尾"), QString());
    QSqlQuery query(DatabaseManager::instance()->database());
    // 人工改库或后续同步可能带来极大的顺序号；追加不能溢出成负数，也不能悄悄插到前面。
    QVERIFY(query.exec(QStringLiteral("UPDATE memos SET sort_order = 2147483647 WHERE id = %1").arg(id)));
    QSignalSpy changed(service, &MemoService::memosChanged);
    QCOMPARE(service->createMemo(QStringLiteral("不能追加"), QString()), -1);
    QCOMPARE(changed.count(), 0);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("sortOrder")).toInt(), 2147483647);
    QVERIFY(service->reorderMemos(0, {id}));
    const int last = service->createMemo(QStringLiteral("归一后追加"), QString());
    QVERIFY(last > 0);
    QCOMPARE(service->getMemo(last).value(QStringLiteral("sortOrder")).toInt(), 2);
}

void MemoServiceTests::reorderValidatesFullSameCategorySelection()
{
    auto* service = MemoService::instance();
    const int first = service->createMemo(QStringLiteral("一"), QString());
    const int second = service->createMemo(QStringLiteral("二"), QString());
    const int third = service->createMemo(QStringLiteral("三"), QString());
    const int category = seedCategory(QStringLiteral("其它"), 10);
    const int other = service->createMemo(QStringLiteral("其它科"), QString(), category);
    QSignalSpy changed(service, &MemoService::memosChanged);
    for (const QVariantList& invalid : {QVariantList{second, first}, QVariantList{second, first, first},
                                       QVariantList{second, first, other}, QVariantList{second, first, 999999},
                                       QVariantList{second, first, 1.5}}) {
        QVERIFY(!service->reorderMemos(0, invalid));
        QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{first, second, third}));
    }
    QVERIFY(!service->reorderMemos(-1, {first, second, third}));
    QCOMPARE(changed.count(), 0);
    QVERIFY(service->reorderMemos(0, {third, first, second}));
    QCOMPARE(changed.count(), 1);
    QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{third, first, second}));
    QCOMPARE(service->getMemo(first).value(QStringLiteral("sortOrder")).toInt(), 2);
    QCOMPARE(service->getMemo(other).value(QStringLiteral("sortOrder")).toInt(), 1);
}

void MemoServiceTests::reorderRollsBackAfterRealSqlFailure()
{
    auto* service = MemoService::instance();
    const int first = service->createMemo(QStringLiteral("一"), QString());
    const int second = service->createMemo(QStringLiteral("二"), QString());
    const int third = service->createMemo(QStringLiteral("三"), QString());
    const QVariantMap before = service->getMemo(third);
    QSqlQuery query(DatabaseManager::instance()->database());
    // 第一条更新成功，第二条由 SQLite 真的拒绝，才能测出事务是否撤销之前已经写入的行。
    QVERIFY(query.exec(QStringLiteral("CREATE TRIGGER fail_memo_reorder BEFORE UPDATE OF sort_order ON memos "
                                      "WHEN NEW.id = %1 BEGIN SELECT RAISE(ABORT, '测试排序失败'); END").arg(first)));
    QSignalSpy changed(service, &MemoService::memosChanged);
    QSignalSpy failed(service, &MemoService::operationFailed);
    QVERIFY(!service->reorderMemos(0, {third, first, second}));
    QCOMPARE(changed.count(), 0);
    QCOMPARE(failed.count(), 1);
    QCOMPARE(idsOf(service->listMemos(0)), (QVariantList{first, second, third}));
    QCOMPARE(service->getMemo(third), before);
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER fail_memo_reorder")));
    QVERIFY(service->reorderMemos(0, {third, first, second}));
}

void MemoServiceTests::failedInsertAndUpdateLeaveDataAndSignalsIntact()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("原文"), QStringLiteral("正文"));
    const QVariantMap before = service->getMemo(id);
    const int category = seedCategory(QStringLiteral("失败时的目标科目"), 10);
    QVERIFY(category > 0);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("CREATE TRIGGER fail_memo_insert BEFORE INSERT ON memos "
                                      "BEGIN SELECT RAISE(ABORT, '测试插入失败'); END")));
    QVERIFY(query.exec(QStringLiteral("CREATE TRIGGER fail_memo_update BEFORE UPDATE ON memos "
                                      "BEGIN SELECT RAISE(ABORT, '测试更新失败'); END")));
    QSignalSpy changed(service, &MemoService::memosChanged);
    QSignalSpy failed(service, &MemoService::operationFailed);
    QCOMPARE(service->createMemo(QStringLiteral("失败"), QString()), -1);
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("title"), QStringLiteral("修改")},
                                     {QStringLiteral("body"), QStringLiteral("正文修改")},
                                     {QStringLiteral("categoryId"), category}}));
    QCOMPARE(service->getMemo(id), before);
    QCOMPARE(changed.count(), 0);
    QCOMPARE(failed.count(), 2);
    QCOMPARE(service->listMemos().size(), 1);
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER fail_memo_insert")));
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER fail_memo_update")));
    QVERIFY(service->createMemo(QStringLiteral("恢复可写"), QString()) > 0);
    QVERIFY(service->updateMemo(id, {{QStringLiteral("body"), QStringLiteral("恢复保存")}}));
}

void MemoServiceTests::unchangedSaveAndReorderDoNotChangeTimestamp()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("不变"), QStringLiteral("正文"));
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("UPDATE memos SET updated_at = '2020-01-01T00:00:00Z' WHERE id = %1").arg(id)));
    QSignalSpy changed(service, &MemoService::memosChanged);
    QVERIFY(service->updateMemo(id, {}));
    QVERIFY(service->updateMemo(id, {{QStringLiteral("title"), QStringLiteral("不变")}, {QStringLiteral("categoryId"), 0}}));
    QVERIFY(service->reorderMemos(0, {id}));
    QCOMPARE(changed.count(), 0);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("updatedAt")).toString(), QStringLiteral("2020-01-01T00:00:00Z"));
    QVERIFY(service->updateMemo(id, {{QStringLiteral("body"), QStringLiteral("真的修改")}}));
    QCOMPARE(changed.count(), 1);
    QVERIFY(service->getMemo(id).value(QStringLiteral("updatedAt")).toString() != QStringLiteral("2020-01-01T00:00:00Z"));
}

void MemoServiceTests::movingMemosKeepsTheirUpdatedTime()
{
    // 上一条用例里只有一条备忘、位置没变，排序根本不会写库。这里两条真的互换位置：
    // 更新时间表示内容最后一次修改，被挪动的备忘也不能因此显示成「刚刚更新」。
    auto* service = MemoService::instance();
    const int first = service->createMemo(QStringLiteral("第一条"), QString());
    const int second = service->createMemo(QStringLiteral("第二条"), QString());
    QVERIFY(first > 0 && second > 0);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("UPDATE memos SET updated_at = '2020-01-01T00:00:00Z'")));
    QSignalSpy changed(service, &MemoService::memosChanged);

    QVERIFY(service->reorderMemos(0, {second, first}));

    // 位置确实换了，也通知了界面重读，否则这条用例测不到任何东西。
    QCOMPARE(changed.count(), 1);
    const QVariantList memos = service->listMemos(0);
    QCOMPARE(idsOf(memos), QVariantList({second, first}));
    for (const QVariant& memo : memos) {
        QCOMPARE(memo.toMap().value(QStringLiteral("updatedAt")).toString(), QStringLiteral("2020-01-01T00:00:00Z"));
    }
}

void MemoServiceTests::databaseReopenNotifiesAndClosedDatabaseFails()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("重开前"), QString());
    QVERIFY(id > 0);
    const QString path = DatabaseManager::instance()->database().databaseName();
    QSignalSpy changed(service, &MemoService::memosChanged);
    DatabaseManager::instance()->close();
    QSignalSpy failed(service, &MemoService::operationFailed);
    QVERIFY(service->listMemos().isEmpty());
    QVERIFY(service->getMemo(id).isEmpty());
    QCOMPARE(service->createMemo(QString(), QString()), -1);
    QVERIFY(!service->updateMemo(id, {{QStringLiteral("title"), QStringLiteral("改动")}}));
    QVERIFY(!service->deleteMemo(id));
    QVERIFY(!service->reorderMemos(0, {id}));
    QCOMPARE(failed.count(), 6);
    QCOMPARE(changed.count(), 0);
    QVERIFY(DatabaseManager::instance()->initialize(path));
    QCOMPARE(changed.count(), 1);
    QCOMPARE(service->getMemo(id).value(QStringLiteral("title")).toString(), QStringLiteral("重开前"));
}

// 产品保证：给界面的读取把成败放在返回值里：读到了 ok 为真、带全部备忘；数据库关着时 ok 为假、带原因，
// 而且不发共享的 operationFailed——页面不必再靠「正在读取」的标志去认领别处发来的失败。
// 抓住的错误实现：读失败时把空列表当成功返回（页面会以为一条备忘都没有），或者照旧只靠信号报错。
void MemoServiceTests::readMemosReportsFailureInReturnValue()
{
    auto* service = MemoService::instance();
    const int id = service->createMemo(QStringLiteral("读得到"), QString());
    QVERIFY(id > 0);
    QSignalSpy failed(service, &MemoService::operationFailed);
    QVariantMap read = service->readMemos();
    QVERIFY(read.value(QStringLiteral("ok")).toBool());
    QCOMPARE(idsOf(read.value(QStringLiteral("memos")).toList()), (QVariantList{id}));

    DatabaseManager::instance()->close();
    read = service->readMemos();
    QVERIFY(!read.value(QStringLiteral("ok")).toBool());
    QVERIFY(read.value(QStringLiteral("memos")).toList().isEmpty());
    QVERIFY(!read.value(QStringLiteral("error")).toString().isEmpty());
    QCOMPARE(failed.count(), 0);
}

void MemoServiceTests::version19MigrationPreservesDataAndSnapshot()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("INSERT INTO tasks (title, date) VALUES ('升级前任务', '2026-10-02')")));
    QVERIFY(query.exec(QStringLiteral("DROP TABLE memos")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 19")));
    const QDir dir(m_tempDir->path());
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const QStringList before = dir.entryList(pattern, QDir::Files);
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '升级前任务'")), 1);
    QVERIFY(DatabaseManager::memoSchemaIsValid(DatabaseManager::instance()->database()));
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM memos")), 0);
    QStringList added = dir.entryList(pattern, QDir::Files);
    for (const QString& name : before) {
        added.removeAll(name);
    }
    QCOMPARE(added.size(), 1);
    const QString connection = QStringLiteral("MemoMigrationSnapshot");
    {
        QSqlDatabase snapshot = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        snapshot.setDatabaseName(dir.filePath(added.first()));
        QVERIFY(snapshot.open());
        QSqlQuery check(snapshot);
        QVERIFY(check.exec(QStringLiteral("PRAGMA user_version")) && check.next());
        QCOMPARE(check.value(0).toInt(), 19);
        check.finish();
        QVERIFY(check.exec(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memos'")) && check.next());
        QCOMPARE(check.value(0).toInt(), 0);
        check.finish();
        snapshot.close();
    }
    QSqlDatabase::removeDatabase(connection);
    const int id = MemoService::instance()->createMemo(QStringLiteral("升级后"), QStringLiteral("不丢"));
    QVERIFY(id > 0);
    const QStringList after = dir.entryList(pattern, QDir::Files);
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(dir.entryList(pattern, QDir::Files), after);
    QCOMPARE(MemoService::instance()->getMemo(id).value(QStringLiteral("body")).toString(), QStringLiteral("不丢"));
}

void MemoServiceTests::brokenMemoSchemaIsRejected_data()
{
    QTest::addColumn<QString>("definition");
    const QString base = QStringLiteral("id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL DEFAULT '' CHECK(length(title) <= 60), "
                                        "body TEXT NOT NULL DEFAULT '' CHECK(length(body) <= 10000), "
                                        "category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL, "
                                        "sort_order INTEGER NOT NULL CHECK(sort_order >= 1), created_at TEXT NOT NULL, updated_at TEXT NOT NULL");
    QTest::newRow("cascade") << QString(base).replace(QStringLiteral("SET NULL"), QStringLiteral("CASCADE"));
    QTest::newRow("missing-body") << QString(base).replace(QStringLiteral("body TEXT NOT NULL DEFAULT '' CHECK(length(body) <= 10000), "), QString());
    QTest::newRow("wrong-primary-key") << QString(base).replace(QStringLiteral("id INTEGER PRIMARY KEY AUTOINCREMENT"), QStringLiteral("id INT PRIMARY KEY"));
    QTest::newRow("missing-length-limit") << QString(base).replace(QStringLiteral(" CHECK(length(body) <= 10000)"), QString());
    QTest::newRow("nullable-body") << QString(base).replace(QStringLiteral("body TEXT NOT NULL"), QStringLiteral("body TEXT"));
    QTest::newRow("extra-foreign-key") << base + QStringLiteral(", FOREIGN KEY(title) REFERENCES categories(name) ON DELETE CASCADE");
    QTest::newRow("composite-foreign-key") << QString(base).replace(QStringLiteral(" REFERENCES categories(id) ON DELETE SET NULL"), QString())
        + QStringLiteral(", FOREIGN KEY(category_id, sort_order) REFERENCES categories(id, id) ON DELETE SET NULL");
}

void MemoServiceTests::brokenMemoSchemaIsRejected()
{
    QFETCH(QString, definition);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DROP TABLE memos")));
    QVERIFY(query.exec(QStringLiteral("CREATE TABLE memos (%1)").arg(definition)));
    QVERIFY(!DatabaseManager::memoSchemaIsValid(DatabaseManager::instance()->database()));
    QVERIFY(!DatabaseManager::instance()->createTables());
}

void MemoServiceTests::futureDatabaseIsRejectedBeforeWriting()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DROP TABLE memos")));
    const int future = DatabaseManager::kCurrentSchemaVersion + 1;
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = %1").arg(future)));
    QVERIFY(!DatabaseManager::instance()->createTables());
    QCOMPARE(scalar(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'memos'")), 0);
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")), future);
}

QTEST_GUILESS_MAIN(MemoServiceTests)
#include "MemoServiceTests.moc"
