#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/MemoService.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/ScheduleService.h"
#include "../src/services/TaskManager.h"
#include "../src/services/TrashService.h"

// 废纸篓（计划 054 阶段 1）的数据层用例。全部用真实建表逻辑的临时库，不手写简化表。
class TrashServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    // 放进废纸篓
    void deletingEachKindMovesItIntoTheTrash_data();
    void deletingEachKindMovesItIntoTheTrash();
    void blankMemoIsNotTrashedAndBodyLineBecomesTitle();
    void failedTrashWriteRollsBackTheDeletion_data();
    void failedTrashWriteRollsBackTheDeletion();
    void failedDeletionAfterTrashWriteRemovesTheTrashRow_data();
    void failedDeletionAfterTrashWriteRemovesTheTrashRow();
    void failedAssociationLookupFailsTheDeletion();
    void routineReclaimedInstanceIsNotTrashed();
    void cleanupOfInvalidSessionsIsNotTrashed();

    // 恢复
    void restoreRebuildsEachKindWithItsOriginalFields_data();
    void restoreRebuildsEachKindWithItsOriginalFields();
    void restoredTaskGoesToTheEndOfItsOriginalDay();
    void restoredTaskReattachesOnlyUnclaimedSessionsAndGaps();
    void restoredMemoRoutineAndCountdownGoToTheEnd();
    void deletedCategoryFallsBackToNoneAndMergedCategoryFollowsTheSurvivor();
    void restoredRoutineGeneratesTodayOnlyWhenItsInstanceWasReclaimed();
    void restoredGeneratedInstanceIsAPlainTaskAndNotGeneratedAgain();
    void restoreRefusesWhenTheTimeIsOccupied_data();
    void restoreRefusesWhenTheTimeIsOccupied();
    void unknownKindOrFuturePayloadCannotBeRestored();
    void alreadyGoneItemIsReported();
    void corruptPayloadIsReportedAsCorruptedAndNotAsNeedingUpdate();
    void restoreFailsAsAWholeWhenReferenceLookupFails();
    void restoreEmitsRefreshSignalsForWhatChanged();

    // 列表、去重、清理
    void readItemsOrdersNewestFirstAndDescribesEachItem();
    void twinsSharingAnOriginAreListedOnceAndHandledTogether();
    void expiredRowsAreHiddenAndFutureDeletionTimesAreClamped();
    void deleteItemAndEmptyTrashRemoveRows();
    void retentionKeepsDay29AndPurgesDay30();
    void retentionFollowsTheLogicalDayBoundary();
    void readItemsFailsLoudlyWhenDatabaseIsClosed();

    // 迁移与契约
    void upgradingFromV20AddsAnEmptyTrashAndKeepsData();
    void brokenTrashSchemaIsRejected_data();
    void brokenTrashSchemaIsRejected();

private:
    QTemporaryDir* m_tempDir = nullptr;
    int m_category = 0;

    // —— 数据辅助 ——
    static QSqlDatabase db() { return DatabaseManager::instance()->database(); }
    bool exec(const QString& sql, const QVariantMap& binds = {});
    int insert(const QString& sql, const QVariantMap& binds = {});
    QVariant value(const QString& sql, const QVariantMap& binds = {});
    int count(const QString& sql, const QVariantMap& binds = {});
    int insertCategory(const QString& name, const QString& color);
    int insertTask(const QString& title, const QString& date, int order = 1, int category = 0);
    int insertFocus(int taskId, const QString& start, const QString& end, int duration);
    int insertRest(const QString& start, const QString& end, int duration, int manual = 0);
    int seedKind(const QString& kind);
    bool deleteKind(const QString& kind, int id);
    static QString tableOf(const QString& kind);
    static QStringList compareColumns(const QString& kind);
    QVariantMap row(const QString& table, int id, const QStringList& columns);
    QString syncIdOf(const QString& table, int id);
    QJsonObject payloadOfLast(QString* kind = nullptr, QString* title = nullptr, QString* origin = nullptr);
    int insertTrashRow(const QString& kind, const QString& origin, const QString& title,
                       const QString& payload, const QString& deletedAtUtc);
    static QString utcText(const QDateTime& local);
    int lastTrashId();
};

namespace {
const QStringList kAllKinds = {
    QStringLiteral("task"), QStringLiteral("focus_session"), QStringLiteral("rest_session"),
    QStringLiteral("knowledge_gap"), QStringLiteral("memo"), QStringLiteral("routine"),
    QStringLiteral("schedule_entry"), QStringLiteral("countdown_goal")};

QString today()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate);
}
} // namespace

void TrashServiceTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("trash.sqlite"))));
    AppSettings::instance()->setDayStartHour(4);
    TrashService::instance()->setNowForTesting(QDateTime());
    // 直接用出厂预设科目「数学」（名称唯一，不能再建同名的）。
    m_category = value(QStringLiteral("SELECT id FROM categories WHERE name = '数学'")).toInt();
    QVERIFY(m_category > 0);
}

void TrashServiceTests::cleanup()
{
    // 单例设置跨用例共享：复位逻辑日起点和注入的时钟，免得漏到下一条用例。
    AppSettings::instance()->setDayStartHour(4);
    TrashService::instance()->setNowForTesting(QDateTime());
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

bool TrashServiceTests::exec(const QString& sql, const QVariantMap& binds)
{
    QSqlQuery query(db());
    query.prepare(sql);
    for (auto it = binds.cbegin(); it != binds.cend(); ++it) {
        query.bindValue(QLatin1Char(':') + it.key(), it.value());
    }
    if (!query.exec()) {
        qWarning() << "exec failed:" << sql << query.lastError().text();
        return false;
    }
    return true;
}

int TrashServiceTests::insert(const QString& sql, const QVariantMap& binds)
{
    QSqlQuery query(db());
    query.prepare(sql);
    for (auto it = binds.cbegin(); it != binds.cend(); ++it) {
        query.bindValue(QLatin1Char(':') + it.key(), it.value());
    }
    if (!query.exec()) {
        qWarning() << "insert failed:" << sql << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

QVariant TrashServiceTests::value(const QString& sql, const QVariantMap& binds)
{
    QSqlQuery query(db());
    query.prepare(sql);
    for (auto it = binds.cbegin(); it != binds.cend(); ++it) {
        query.bindValue(QLatin1Char(':') + it.key(), it.value());
    }
    if (!query.exec() || !query.next()) {
        return QVariant();
    }
    return query.value(0);
}

int TrashServiceTests::count(const QString& sql, const QVariantMap& binds)
{
    const QVariant v = value(sql, binds);
    return v.isValid() ? v.toInt() : -1;
}

int TrashServiceTests::insertCategory(const QString& name, const QString& color)
{
    return insert(QStringLiteral("INSERT INTO categories (name, color, is_preset, display_order) "
                                 "VALUES (:n, :c, 0, 50)"),
                  {{QStringLiteral("n"), name}, {QStringLiteral("c"), color}});
}

int TrashServiceTests::insertTask(const QString& title, const QString& date, int order, int category)
{
    return insert(QStringLiteral(
                      "INSERT INTO tasks (title, category, category_id, date, display_order, completed) "
                      "VALUES (:t, :cat, :cid, :d, :o, 0)"),
                  {{QStringLiteral("t"), title},
                   {QStringLiteral("cat"), category > 0 ? value(QStringLiteral("SELECT name FROM categories WHERE id = %1").arg(category)) : QVariant()},
                   {QStringLiteral("cid"), category > 0 ? QVariant(category) : QVariant()},
                   {QStringLiteral("d"), date}, {QStringLiteral("o"), order}});
}

int TrashServiceTests::insertFocus(int taskId, const QString& start, const QString& end, int duration)
{
    return insert(QStringLiteral(
                      "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, "
                      "pomodoro_completed) VALUES (:task, :s, :e, :d, 1, 1)"),
                  {{QStringLiteral("task"), taskId > 0 ? QVariant(taskId) : QVariant()},
                   {QStringLiteral("s"), start},
                   {QStringLiteral("e"), end.isEmpty() ? QVariant() : QVariant(end)},
                   {QStringLiteral("d"), duration}});
}

int TrashServiceTests::insertRest(const QString& start, const QString& end, int duration, int manual)
{
    return insert(QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                 "VALUES (:s, :e, :d, :m)"),
                  {{QStringLiteral("s"), start}, {QStringLiteral("e"), end},
                   {QStringLiteral("d"), duration}, {QStringLiteral("m"), manual}});
}

QString TrashServiceTests::tableOf(const QString& kind)
{
    static const QHash<QString, QString> tables = {
        {QStringLiteral("task"), QStringLiteral("tasks")},
        {QStringLiteral("focus_session"), QStringLiteral("focus_sessions")},
        {QStringLiteral("rest_session"), QStringLiteral("rest_sessions")},
        {QStringLiteral("knowledge_gap"), QStringLiteral("knowledge_gaps")},
        {QStringLiteral("memo"), QStringLiteral("memos")},
        {QStringLiteral("routine"), QStringLiteral("routines")},
        {QStringLiteral("schedule_entry"), QStringLiteral("schedule_entries")},
        {QStringLiteral("countdown_goal"), QStringLiteral("countdown_goals")}};
    return tables.value(kind);
}

// 恢复前后必须逐列相等的业务列（不含编号、sync_id，也不含恢复时按规则重写的排序号与更新时间）。
QStringList TrashServiceTests::compareColumns(const QString& kind)
{
    static const QHash<QString, QStringList> columns = {
        {QStringLiteral("task"),
         {QStringLiteral("title"), QStringLiteral("category"), QStringLiteral("category_id"),
          QStringLiteral("estimated_minutes"), QStringLiteral("notes"), QStringLiteral("date"),
          QStringLiteral("completed"), QStringLiteral("created_at"), QStringLiteral("completion_note"),
          QStringLiteral("routine_id"), QStringLiteral("routine_generated")}},
        {QStringLiteral("focus_session"),
         {QStringLiteral("task_id"), QStringLiteral("start_time"), QStringLiteral("end_time"),
          QStringLiteral("duration"), QStringLiteral("mode"), QStringLiteral("pomodoro_completed"),
          QStringLiteral("category_id_snapshot"), QStringLiteral("category_name_snapshot"),
          QStringLiteral("category_color_snapshot")}},
        {QStringLiteral("rest_session"),
         {QStringLiteral("start_time"), QStringLiteral("end_time"), QStringLiteral("duration"),
          QStringLiteral("manual")}},
        {QStringLiteral("knowledge_gap"),
         {QStringLiteral("title"), QStringLiteral("detail"), QStringLiteral("category_id"),
          QStringLiteral("source_task_id"), QStringLiteral("source_task_title"), QStringLiteral("priority"),
          QStringLiteral("status"), QStringLiteral("due_date"), QStringLiteral("resolution"),
          QStringLiteral("linked_task_id"), QStringLiteral("created_at"), QStringLiteral("resolved_at")}},
        {QStringLiteral("memo"),
         {QStringLiteral("title"), QStringLiteral("body"), QStringLiteral("category_id"),
          QStringLiteral("created_at")}},
        {QStringLiteral("routine"),
         {QStringLiteral("title"), QStringLiteral("category_id"), QStringLiteral("active"),
          QStringLiteral("weekdays"), QStringLiteral("created_at"), QStringLiteral("last_generated_date")}},
        {QStringLiteral("schedule_entry"),
         {QStringLiteral("title"), QStringLiteral("location"), QStringLiteral("weekday"),
          QStringLiteral("start_minutes"), QStringLiteral("end_minutes"), QStringLiteral("week_start"),
          QStringLiteral("week_end"), QStringLiteral("week_parity"), QStringLiteral("category_id"),
          QStringLiteral("created_at")}},
        {QStringLiteral("countdown_goal"),
         {QStringLiteral("name"), QStringLiteral("target_date"), QStringLiteral("created_at")}}};
    return columns.value(kind);
}

QVariantMap TrashServiceTests::row(const QString& table, int id, const QStringList& columns)
{
    QSqlQuery query(db());
    query.prepare(QStringLiteral("SELECT %1 FROM %2 WHERE id = :id").arg(columns.join(QLatin1Char(',')), table));
    query.bindValue(QStringLiteral(":id"), id);
    QVariantMap result;
    if (!query.exec() || !query.next()) {
        return result;
    }
    for (int i = 0; i < columns.size(); ++i) {
        // NULL 与空串要能区分：用显式的「null」标记，免得 QVariant 比较把两者当成相等。
        result.insert(columns.at(i), query.value(i).isNull() ? QVariant(QStringLiteral("<NULL>"))
                                                             : query.value(i));
    }
    return result;
}

QString TrashServiceTests::syncIdOf(const QString& table, int id)
{
    return value(QStringLiteral("SELECT sync_id FROM %1 WHERE id = %2").arg(table).arg(id)).toString();
}

int TrashServiceTests::seedKind(const QString& kind)
{
    const QString cat = QString::number(m_category);
    if (kind == QLatin1String("task")) {
        return insert(QStringLiteral(
                          "INSERT INTO tasks (title, category, category_id, estimated_minutes, notes, "
                          "display_order, date, completed, created_at, completion_note) "
                          "VALUES ('线性代数', '数学', %1, 45, '带书', 3, '2026-10-03', 1, "
                          "'2026-10-01T08:00:00', '做完了')").arg(cat));
    }
    if (kind == QLatin1String("focus_session")) {
        const int task = insertTask(QStringLiteral("线性代数 第 4 讲"), QStringLiteral("2026-10-03"), 1, m_category);
        return insert(QStringLiteral(
                          "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, "
                          "pomodoro_completed, category_id_snapshot, category_name_snapshot, "
                          "category_color_snapshot) VALUES (%1, '2026-10-03T14:05:00.000', "
                          "'2026-10-03T14:50:00.000', 2700, 1, 1, %2, '数学', '#d4a574')")
                          .arg(task).arg(cat));
    }
    if (kind == QLatin1String("rest_session")) {
        return insertRest(QStringLiteral("2026-10-03T21:10:00.000"), QStringLiteral("2026-10-03T21:25:00.000"), 900, 1);
    }
    if (kind == QLatin1String("knowledge_gap")) {
        const int task = insertTask(QStringLiteral("来源任务"), QStringLiteral("2026-10-03"), 1, m_category);
        return insert(QStringLiteral(
                          "INSERT INTO knowledge_gaps (title, detail, category_id, source_task_id, "
                          "source_task_title, priority, status, due_date, resolution, linked_task_id, "
                          "created_at, updated_at, resolved_at) VALUES ('ε-δ 定义', '没吃透', %1, %2, "
                          "'来源任务', 2, 2, '2026-10-08', '想通了', %2, '2026-10-01T08:00:00', "
                          "'2026-10-04T08:00:00', '2026-10-05T10:00:00')").arg(cat).arg(task));
    }
    if (kind == QLatin1String("memo")) {
        return insert(QStringLiteral(
                          "INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                          "VALUES ('进度', '第一行\n第二行', %1, 4, '2026-10-01T08:00:00.000Z', "
                          "'2026-10-02T09:00:00.000Z')").arg(cat));
    }
    if (kind == QLatin1String("routine")) {
        return insert(QStringLiteral(
                          "INSERT INTO routines (title, category_id, active, display_order, "
                          "last_generated_date, created_at, weekdays) VALUES ('背单词', %1, 0, 2, "
                          "'2026-10-05', '2026-09-01T08:00:00', 21)").arg(cat));
    }
    if (kind == QLatin1String("schedule_entry")) {
        return insert(QStringLiteral(
                          "INSERT INTO schedule_entries (title, location, weekday, start_minutes, end_minutes, "
                          "week_start, week_end, week_parity, category_id, created_at) VALUES ('高等数学', "
                          "'教三 204', 4, 840, 940, 1, 16, 1, %1, '2026-09-01T08:00:00')").arg(cat));
    }
    const int goal = insert(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES ('考研', '2026-12-19', 0, '2026-09-01T08:00:00', '2026-09-01T08:00:00')"));
    // 倒计时服务把目标缓存在列表模型里，直接写库之后要让它重读，deleteGoal 才找得到。
    CountdownService::instance()->reload();
    return goal;
}

bool TrashServiceTests::deleteKind(const QString& kind, int id)
{
    if (kind == QLatin1String("task")) return TaskManager::instance()->deleteTask(id);
    if (kind == QLatin1String("focus_session")) return FocusHistoryService::instance()->deleteSession(id);
    if (kind == QLatin1String("rest_session")) return FocusHistoryService::instance()->deleteRestSession(id);
    if (kind == QLatin1String("knowledge_gap")) return KnowledgeGapService::instance()->deleteGap(id);
    if (kind == QLatin1String("memo")) return MemoService::instance()->deleteMemo(id);
    if (kind == QLatin1String("routine")) return RoutineManager::instance()->deleteRoutine(id);
    if (kind == QLatin1String("schedule_entry")) return ScheduleService::instance()->deleteEntry(id);
    return CountdownService::instance()->deleteGoal(id);
}

int TrashServiceTests::lastTrashId()
{
    return value(QStringLiteral("SELECT id FROM trash_items ORDER BY id DESC LIMIT 1")).toInt();
}

QJsonObject TrashServiceTests::payloadOfLast(QString* kind, QString* title, QString* origin)
{
    QSqlQuery query(db());
    if (!query.exec(QStringLiteral("SELECT kind, title, origin_sync_id, payload FROM trash_items ORDER BY id DESC LIMIT 1"))
        || !query.next()) {
        return {};
    }
    if (kind) *kind = query.value(0).toString();
    if (title) *title = query.value(1).toString();
    if (origin) *origin = query.value(2).toString();
    return QJsonDocument::fromJson(query.value(3).toString().toUtf8()).object();
}

int TrashServiceTests::insertTrashRow(const QString& kind, const QString& origin, const QString& title,
                                      const QString& payload, const QString& deletedAtUtc)
{
    return insert(QStringLiteral("INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
                                 "VALUES (:k, :o, :t, :p, :d)"),
                  // 空 QString 会绑成 NULL 而撞上 NOT NULL，要显式写成空串。
                  {{QStringLiteral("k"), kind}, {QStringLiteral("o"), origin.isNull() ? QStringLiteral("") : origin}, {QStringLiteral("t"), title},
                   {QStringLiteral("p"), payload}, {QStringLiteral("d"), deletedAtUtc}});
}

QString TrashServiceTests::utcText(const QDateTime& local)
{
    return local.toUTC().toString(Qt::ISODateWithMs);
}

// ───────────────────────── 放进废纸篓 ─────────────────────────

void TrashServiceTests::deletingEachKindMovesItIntoTheTrash_data()
{
    QTest::addColumn<QString>("kind");
    QTest::addColumn<QString>("title");
    for (const QString& kind : kAllKinds) {
        QString title;
        if (kind == QLatin1String("task")) title = QStringLiteral("线性代数");
        else if (kind == QLatin1String("focus_session")) title = QStringLiteral("线性代数 第 4 讲");
        else if (kind == QLatin1String("rest_session")) title = QStringLiteral("休息");
        else if (kind == QLatin1String("knowledge_gap")) title = QStringLiteral("ε-δ 定义");
        else if (kind == QLatin1String("memo")) title = QStringLiteral("进度");
        else if (kind == QLatin1String("routine")) title = QStringLiteral("背单词");
        else if (kind == QLatin1String("schedule_entry")) title = QStringLiteral("高等数学");
        else title = QStringLiteral("考研");
        QTest::newRow(qPrintable(kind)) << kind << title;
    }
}

void TrashServiceTests::deletingEachKindMovesItIntoTheTrash()
{
    // 产品保证：用户删掉七类内容（专注与休息各算一类）时，删除前的完整内容先进废纸篓，原记录随即消失。
    // 数据让「只存标题」或「存了却没删原记录」的实现得到不同结果：payload 里的关键字段逐一核对。
    QFETCH(QString, kind);
    QFETCH(QString, title);
    const int id = seedKind(kind);
    QVERIFY(id > 0);
    const QString origin = syncIdOf(tableOf(kind), id);
    QVERIFY(!origin.isEmpty()); // 前提：原记录有同步身份，废纸篓才能靠它去重
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);

    QSignalSpy changed(TrashService::instance(), &TrashService::trashChanged);
    QVERIFY(deleteKind(kind, id));

    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE id = %2").arg(tableOf(kind)).arg(id)), 0);
    QCOMPARE(changed.count(), 1);
    QString gotKind, gotTitle, gotOrigin;
    const QJsonObject p = payloadOfLast(&gotKind, &gotTitle, &gotOrigin);
    QCOMPARE(gotKind, kind);
    QCOMPARE(gotTitle, title);
    QCOMPARE(gotOrigin, origin);
    QCOMPARE(p.value(QStringLiteral("v")).toInt(), 1);
    QVERIFY(!QDateTime::fromString(value(QStringLiteral("SELECT deleted_at FROM trash_items")).toString(),
                                   Qt::ISODateWithMs).isNull());

    const QString catSync = syncIdOf(QStringLiteral("categories"), m_category);
    if (kind == QLatin1String("task")) {
        QCOMPARE(p.value(QStringLiteral("category_sync_id")).toString(), catSync);
        QCOMPARE(p.value(QStringLiteral("category_name")).toString(), QStringLiteral("数学"));
        QCOMPARE(p.value(QStringLiteral("estimated_minutes")).toInt(), 45);
        QCOMPARE(p.value(QStringLiteral("notes")).toString(), QStringLiteral("带书"));
        QCOMPARE(p.value(QStringLiteral("date")).toString(), QStringLiteral("2026-10-03"));
        QCOMPARE(p.value(QStringLiteral("completed")).toInt(), 1);
        QCOMPARE(p.value(QStringLiteral("completion_note")).toString(), QStringLiteral("做完了"));
        QCOMPARE(p.value(QStringLiteral("created_at")).toString(), QStringLiteral("2026-10-01T08:00:00"));
    } else if (kind == QLatin1String("focus_session")) {
        QCOMPARE(p.value(QStringLiteral("task_title")).toString(), QStringLiteral("线性代数 第 4 讲"));
        QVERIFY(!p.value(QStringLiteral("task_sync_id")).toString().isEmpty());
        QCOMPARE(p.value(QStringLiteral("start_time")).toString(), QStringLiteral("2026-10-03T14:05:00.000"));
        QCOMPARE(p.value(QStringLiteral("end_time")).toString(), QStringLiteral("2026-10-03T14:50:00.000"));
        QCOMPARE(p.value(QStringLiteral("duration")).toInt(), 2700);
        QCOMPARE(p.value(QStringLiteral("pomodoro_completed")).toInt(), 1);
        QCOMPARE(p.value(QStringLiteral("category_sync_id")).toString(), catSync);
        QCOMPARE(p.value(QStringLiteral("category_color_snapshot")).toString(), QStringLiteral("#d4a574"));
    } else if (kind == QLatin1String("rest_session")) {
        QCOMPARE(p.value(QStringLiteral("duration")).toInt(), 900);
        QCOMPARE(p.value(QStringLiteral("manual")).toInt(), 1);
    } else if (kind == QLatin1String("knowledge_gap")) {
        QCOMPARE(p.value(QStringLiteral("detail")).toString(), QStringLiteral("没吃透"));
        QCOMPARE(p.value(QStringLiteral("resolution")).toString(), QStringLiteral("想通了"));
        QCOMPARE(p.value(QStringLiteral("due_date")).toString(), QStringLiteral("2026-10-08"));
        QCOMPARE(p.value(QStringLiteral("resolved_at")).toString(), QStringLiteral("2026-10-05T10:00:00"));
        QVERIFY(!p.value(QStringLiteral("source_task_sync_id")).toString().isEmpty());
        QVERIFY(!p.value(QStringLiteral("linked_task_sync_id")).toString().isEmpty());
    } else if (kind == QLatin1String("memo")) {
        QCOMPARE(p.value(QStringLiteral("body")).toString(), QStringLiteral("第一行\n第二行"));
        QCOMPARE(p.value(QStringLiteral("category_sync_id")).toString(), catSync);
    } else if (kind == QLatin1String("routine")) {
        QCOMPARE(p.value(QStringLiteral("weekdays")).toInt(), 21);
        QCOMPARE(p.value(QStringLiteral("active")).toInt(), 0);
        // 没有收回过当日实例，生成戳保持原值。
        QCOMPARE(p.value(QStringLiteral("last_generated_date")).toString(), QStringLiteral("2026-10-05"));
    } else if (kind == QLatin1String("schedule_entry")) {
        QCOMPARE(p.value(QStringLiteral("location")).toString(), QStringLiteral("教三 204"));
        QCOMPARE(p.value(QStringLiteral("start_minutes")).toInt(), 840);
        QCOMPARE(p.value(QStringLiteral("week_parity")).toInt(), 1);
    } else {
        QCOMPARE(p.value(QStringLiteral("target_date")).toString(), QStringLiteral("2026-12-19"));
    }
}

void TrashServiceTests::blankMemoIsNotTrashedAndBodyLineBecomesTitle()
{
    // 产品保证：完全空白的备忘录删除时不进废纸篓；标题空白但有正文时，废纸篓里的标题取正文第一行。
    const int blank = insert(QStringLiteral(
        "INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
        "VALUES ('  ', ' \n\t', NULL, 1, '2026-10-01T08:00:00.000Z', '2026-10-01T08:00:00.000Z')"));
    QVERIFY(blank > 0);
    QVERIFY(MemoService::instance()->deleteMemo(blank));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM memos WHERE id = %1").arg(blank)), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);

    const int bodyOnly = insert(QStringLiteral(
        "INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
        "VALUES ('', '英语作文\r\n第二行', NULL, 1, '2026-10-01T08:00:00.000Z', '2026-10-01T08:00:00.000Z')"));
    QVERIFY(MemoService::instance()->deleteMemo(bodyOnly));
    QString title;
    payloadOfLast(nullptr, &title);
    QCOMPARE(title, QStringLiteral("英语作文")); // 行尾的 \r 不进标题
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
}

void TrashServiceTests::failedTrashWriteRollsBackTheDeletion_data()
{
    QTest::addColumn<QString>("kind");
    QTest::addColumn<QString>("failureText");
    QTest::newRow("task") << QStringLiteral("task") << QString();
    QTest::newRow("focus_session") << QStringLiteral("focus_session") << QStringLiteral("记录不存在、正在进行中或删除失败");
    QTest::newRow("rest_session") << QStringLiteral("rest_session") << QStringLiteral("记录不存在、正在进行中或删除失败");
    QTest::newRow("knowledge_gap") << QStringLiteral("knowledge_gap") << QStringLiteral("删除失败");
    QTest::newRow("memo") << QStringLiteral("memo") << QStringLiteral("删除备忘录失败");
    QTest::newRow("routine") << QStringLiteral("routine") << QString();
    QTest::newRow("schedule_entry") << QStringLiteral("schedule_entry") << QStringLiteral("删除课程失败");
    QTest::newRow("countdown_goal") << QStringLiteral("countdown_goal") << QStringLiteral("删除目标失败");
}

void TrashServiceTests::failedTrashWriteRollsBackTheDeletion()
{
    // 产品保证：写废纸篓失败时删除整体回滚、报删除失败——宁可删不掉，也不能删了却没进废纸篓。
    // 这里用测试专用的触发器让 trash_items 的任何插入都失败（真实环境里磁盘满、表损坏会有同样效果）；
    // 先让任务带着一条专注记录，证明「解除关联」这类后续写入也没有留下。
    QFETCH(QString, kind);
    QFETCH(QString, failureText);
    const int id = seedKind(kind);
    QVERIFY(id > 0);
    int attached = -1;
    if (kind == QLatin1String("task")) {
        attached = insertFocus(id, QStringLiteral("2026-10-03T09:00:00.000"), QStringLiteral("2026-10-03T09:30:00.000"), 1800);
        QVERIFY(attached > 0);
    }
    QSignalSpy gapFail(KnowledgeGapService::instance(), &KnowledgeGapService::operationFailed);
    QSignalSpy memoFail(MemoService::instance(), &MemoService::operationFailed);
    QSignalSpy scheduleFail(ScheduleService::instance(), &ScheduleService::operationFailed);
    QSignalSpy goalFail(CountdownService::instance(), &CountdownService::operationFailed);
    QSignalSpy trashSignal(TrashService::instance(), &TrashService::trashChanged);
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER test_block_trash BEFORE INSERT ON trash_items "
                                "BEGIN SELECT RAISE(ABORT, 'trash blocked'); END")));

    QVERIFY(!deleteKind(kind, id));

    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE id = %2").arg(tableOf(kind)).arg(id)), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QCOMPARE(trashSignal.count(), 0);
    if (kind == QLatin1String("task")) {
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE id = %1 AND task_id = %2")
                           .arg(attached).arg(id)), 1);
    }
    if (kind == QLatin1String("focus_session") || kind == QLatin1String("rest_session")) {
        QCOMPARE(FocusHistoryService::instance()->lastError(), failureText);
    }
    const QList<QSignalSpy*> spies = {&gapFail, &memoFail, &scheduleFail, &goalFail};
    const QStringList kinds = {QStringLiteral("knowledge_gap"), QStringLiteral("memo"),
                               QStringLiteral("schedule_entry"), QStringLiteral("countdown_goal")};
    for (int i = 0; i < spies.size(); ++i) {
        if (kinds.at(i) == kind) {
            QCOMPARE(spies.at(i)->count(), 1);
            QVERIFY2(spies.at(i)->first().first().toString().contains(failureText),
                     qPrintable(spies.at(i)->first().first().toString()));
        } else {
            QCOMPARE(spies.at(i)->count(), 0);
        }
    }

    // 回滚后事务已收尾、服务可继续使用：撤掉故障再删一次应当成功并进废纸篓。
    QVERIFY(exec(QStringLiteral("DROP TRIGGER test_block_trash")));
    QVERIFY(deleteKind(kind, id));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
}

void TrashServiceTests::failedDeletionAfterTrashWriteRemovesTheTrashRow_data()
{
    QTest::addColumn<QString>("kind");
    for (const QString& kind : kAllKinds) {
        QTest::newRow(qPrintable(kind)) << kind;
    }
}

void TrashServiceTests::failedDeletionAfterTrashWriteRemovesTheTrashRow()
{
    // 产品保证：废纸篓已写入但随后的删除失败时，整体回滚——不能留下一条「已删除」的废纸篓记录，
    // 而原记录其实还在（恢复它会得到重复内容）。触发器让原表的删除失败，此时废纸篓写入已经成功过一次。
    QFETCH(QString, kind);
    const int id = seedKind(kind);
    QVERIFY(id > 0);
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER test_block_delete BEFORE DELETE ON %1 "
                                "BEGIN SELECT RAISE(ABORT, 'delete blocked'); END").arg(tableOf(kind))));

    QVERIFY(!deleteKind(kind, id));

    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE id = %2").arg(tableOf(kind)).arg(id)), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);

    QVERIFY(exec(QStringLiteral("DROP TRIGGER test_block_delete")));
    QVERIFY(deleteKind(kind, id));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
}

void TrashServiceTests::routineReclaimedInstanceIsNotTrashed()
{
    // 产品保证：删除例行时被系统「收回」的当日实例不进废纸篓（那是系统自己的删除），
    // 只有例行本身进；收回过实例的例行，生成戳在废纸篓里存空。
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), m_category));
    const int routineId = value(QStringLiteral("SELECT id FROM routines WHERE title = '背单词'")).toInt();
    QVERIFY(routineId > 0);
    RoutineManager::instance()->materializeToday();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_id = %1").arg(routineId)), 1);
    QCOMPARE(value(QStringLiteral("SELECT last_generated_date FROM routines WHERE id = %1").arg(routineId)).toString(),
             today());

    QVERIFY(RoutineManager::instance()->deleteRoutine(routineId));

    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '背单词'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE kind = 'task'")), 0);
    const QJsonObject p = payloadOfLast();
    QVERIFY(p.contains(QStringLiteral("last_generated_date")));
    QVERIFY(p.value(QStringLiteral("last_generated_date")).isNull());
}

void TrashServiceTests::cleanupOfInvalidSessionsIsNotTrashed()
{
    // 产品保证：专注历史的「清理无效记录」（不足 3 分钟、本来就不计入的记录）是系统清理，不进废纸篓。
    const int task = insertTask(QStringLiteral("任务"), QStringLiteral("2026-10-03"));
    QVERIFY(insertFocus(task, QStringLiteral("2026-10-03T09:00:00.000"), QStringLiteral("2026-10-03T09:01:00.000"), 60) > 0);
    QCOMPARE(FocusHistoryService::instance()->invalidSessionCount(), 1);
    QCOMPARE(FocusHistoryService::instance()->cleanupInvalidSessions(), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
}

// ───────────────────────── 恢复 ─────────────────────────

void TrashServiceTests::restoreRebuildsEachKindWithItsOriginalFields_data()
{
    QTest::addColumn<QString>("kind");
    for (const QString& kind : kAllKinds) {
        QTest::newRow(qPrintable(kind)) << kind;
    }
}

void TrashServiceTests::restoreRebuildsEachKindWithItsOriginalFields()
{
    // 产品保证：恢复后每一类的业务字段与删除前逐列一致，废纸篓里那一行消失，
    // 恢复出来的是新记录（新编号、新同步身份），因为原身份已作废。
    QFETCH(QString, kind);
    const int id = seedKind(kind);
    QVERIFY(id > 0);
    const QString table = tableOf(kind);
    const QVariantMap before = row(table, id, compareColumns(kind));
    QVERIFY(!before.isEmpty());
    const QString oldSync = syncIdOf(table, id);
    QVERIFY(deleteKind(kind, id));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);

    const QVariantMap result = TrashService::instance()->restoreItem(lastTrashId());
    QVERIFY2(result.value(QStringLiteral("ok")).toBool(), qPrintable(result.value(QStringLiteral("error")).toString()));
    QCOMPARE(result.value(QStringLiteral("kind")).toString(), kind);

    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    const int newId = value(QStringLiteral("SELECT id FROM %1 ORDER BY id DESC LIMIT 1").arg(table)).toInt();
    QVERIFY(newId > id);
    QCOMPARE(row(table, newId, compareColumns(kind)), before);
    const QString newSync = syncIdOf(table, newId);
    QVERIFY(!newSync.isEmpty());
    QVERIFY(newSync != oldSync);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE id > %2").arg(table).arg(id)), 1);
}

void TrashServiceTests::restoredTaskGoesToTheEndOfItsOriginalDay()
{
    // 产品保证：恢复的任务回到原日期并排在那天最后，不插回原位置（原位置的序号可能已被别的任务占用）。
    // 数据：原日期有序号 1、2（被删的原序号 2）、5 的任务，另一天有更大的序号 99；
    // 插回原位置的实现得到 2，取全表最大值的实现得到 100，只有「当天最大值 + 1」得到 6。
    const QString day = QStringLiteral("2026-10-03");
    insertTask(QStringLiteral("甲"), day, 1);
    const int victim = insertTask(QStringLiteral("乙"), day, 2);
    insertTask(QStringLiteral("丙"), day, 5);
    insertTask(QStringLiteral("别的一天"), QStringLiteral("2026-10-04"), 99);
    QVERIFY(TaskManager::instance()->deleteTask(victim));

    const QVariantMap result = TrashService::instance()->restoreItem(lastTrashId());
    QVERIFY(result.value(QStringLiteral("ok")).toBool());
    QCOMPARE(value(QStringLiteral("SELECT display_order FROM tasks WHERE title = '乙'")).toInt(), 6);
    QCOMPARE(value(QStringLiteral("SELECT date FROM tasks WHERE title = '乙'")).toString(), day);
}

void TrashServiceTests::restoredTaskReattachesOnlyUnclaimedSessionsAndGaps()
{
    // 产品保证：恢复任务时，删除时挂在它上面、现在仍然没有归属的专注记录与知识缺口接回来；
    // 期间被改挂到别的任务的不动。数据：三条专注记录（一条留空、一条改挂他处、一条仍空）
    // 和三个缺口关联位，不判断「仍为空」的实现会把改挂的也抢回来。
    const QString day = QStringLiteral("2026-10-03");
    const int task = insertTask(QStringLiteral("原任务"), day, 1, m_category);
    const int other = insertTask(QStringLiteral("别的任务"), day, 2);
    const int s1 = insertFocus(task, QStringLiteral("2026-10-03T08:00:00.000"), QStringLiteral("2026-10-03T08:30:00.000"), 1800);
    const int s2 = insertFocus(task, QStringLiteral("2026-10-03T09:00:00.000"), QStringLiteral("2026-10-03T09:30:00.000"), 1800);
    const int s3 = insertFocus(task, QStringLiteral("2026-10-03T10:00:00.000"), QStringLiteral("2026-10-03T10:30:00.000"), 1800);
    const int gapSource = insert(QStringLiteral(
        "INSERT INTO knowledge_gaps (title, source_task_id, created_at, updated_at) "
        "VALUES ('来源缺口', %1, '2026-10-01T00:00:00', '2026-10-01T00:00:00')").arg(task));
    const int gapLinked = insert(QStringLiteral(
        "INSERT INTO knowledge_gaps (title, linked_task_id, created_at, updated_at) "
        "VALUES ('关联缺口', %1, '2026-10-01T00:00:00', '2026-10-01T00:00:00')").arg(task));
    const int gapMoved = insert(QStringLiteral(
        "INSERT INTO knowledge_gaps (title, source_task_id, created_at, updated_at) "
        "VALUES ('改挂缺口', %1, '2026-10-01T00:00:00', '2026-10-01T00:00:00')").arg(task));
    QVERIFY(TaskManager::instance()->deleteTask(task));
    // 前提：删除后它们都脱钩了。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE task_id IS NULL")), 3);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM knowledge_gaps WHERE source_task_id IS NULL AND linked_task_id IS NULL")), 3);
    // 期间用户把 s2 改挂到别的任务、gapMoved 的来源也改挂他处。
    QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET task_id = %1 WHERE id = %2").arg(other).arg(s2)));
    QVERIFY(exec(QStringLiteral("UPDATE knowledge_gaps SET source_task_id = %1 WHERE id = %2").arg(other).arg(gapMoved)));

    const QVariantMap result = TrashService::instance()->restoreItem(lastTrashId());
    QVERIFY2(result.value(QStringLiteral("ok")).toBool(), qPrintable(result.value(QStringLiteral("error")).toString()));
    const int newTask = value(QStringLiteral("SELECT id FROM tasks WHERE title = '原任务'")).toInt();
    QVERIFY(newTask > 0 && newTask != task);
    QCOMPARE(value(QStringLiteral("SELECT task_id FROM focus_sessions WHERE id = %1").arg(s1)).toInt(), newTask);
    QCOMPARE(value(QStringLiteral("SELECT task_id FROM focus_sessions WHERE id = %1").arg(s2)).toInt(), other);
    QCOMPARE(value(QStringLiteral("SELECT task_id FROM focus_sessions WHERE id = %1").arg(s3)).toInt(), newTask);
    QCOMPARE(value(QStringLiteral("SELECT source_task_id FROM knowledge_gaps WHERE id = %1").arg(gapSource)).toInt(), newTask);
    QCOMPARE(value(QStringLiteral("SELECT linked_task_id FROM knowledge_gaps WHERE id = %1").arg(gapLinked)).toInt(), newTask);
    QCOMPARE(value(QStringLiteral("SELECT source_task_id FROM knowledge_gaps WHERE id = %1").arg(gapMoved)).toInt(), other);
}

void TrashServiceTests::restoredMemoRoutineAndCountdownGoToTheEnd()
{
    // 产品保证：备忘录回到原科目排在那一科最后，例行排在例行列表最后，倒计时排在最后。
    // 数据：被删项的原序号都小于现存最大值，插回原位置的实现得到不同的序号。
    insert(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                          "VALUES ('旧一', 'a', %1, 1, '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')").arg(m_category));
    const int memo = insert(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                          "VALUES ('旧二', 'b', %1, 2, '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')").arg(m_category));
    insert(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                          "VALUES ('旧五', 'c', %1, 5, '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')").arg(m_category));
    insert(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                          "VALUES ('未分类', 'd', NULL, 40, '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')"));
    const int routine = insert(QStringLiteral("INSERT INTO routines (title, active, display_order, weekdays) VALUES ('例行甲', 1, 1, 127)"));
    insert(QStringLiteral("INSERT INTO routines (title, active, display_order, weekdays) VALUES ('例行乙', 1, 7, 127)"));
    const int goal = insert(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES ('目标甲', '2026-12-01', 0, '2026-09-01T00:00:00', '2026-09-01T00:00:00')"));
    insert(QStringLiteral("INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
                          "VALUES ('目标乙', '2026-12-02', 4, '2026-09-01T00:00:00', '2026-09-01T00:00:00')"));
    CountdownService::instance()->reload();

    QVERIFY(MemoService::instance()->deleteMemo(memo));
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QCOMPARE(value(QStringLiteral("SELECT sort_order FROM memos WHERE title = '旧二'")).toInt(), 6);
    // 更新时间是恢复的此刻，不是原来的 2026-10-01。
    QVERIFY(value(QStringLiteral("SELECT updated_at FROM memos WHERE title = '旧二'")).toString()
            != QStringLiteral("2026-10-01T00:00:00.000Z"));

    QVERIFY(RoutineManager::instance()->deleteRoutine(routine));
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QCOMPARE(value(QStringLiteral("SELECT display_order FROM routines WHERE title = '例行甲'")).toInt(), 8);

    QVERIFY(CountdownService::instance()->deleteGoal(goal));
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QCOMPARE(value(QStringLiteral("SELECT display_order FROM countdown_goals WHERE name = '目标甲'")).toInt(), 5);
}

void TrashServiceTests::deletedCategoryFallsBackToNoneAndMergedCategoryFollowsTheSurvivor()
{
    // 产品保证：科目已删除的内容恢复后进未分类（任务的科目名文本一并清空，同删科目的做法）；
    // 科目被同名合并掉的，顺着合并记录跟到留下的那个科目。
    const int doomed = insertCategory(QStringLiteral("将被删"), QStringLiteral("#111111"));
    const int merged = insertCategory(QStringLiteral("将被合并"), QStringLiteral("#222222"));
    const int survivor = insertCategory(QStringLiteral("留下的"), QStringLiteral("#333333"));
    const QString mergedSync = syncIdOf(QStringLiteral("categories"), merged);
    const QString survivorSync = syncIdOf(QStringLiteral("categories"), survivor);
    QVERIFY(!mergedSync.isEmpty() && !survivorSync.isEmpty());

    const int taskDoomed = insertTask(QStringLiteral("科目被删的任务"), QStringLiteral("2026-10-03"), 1, doomed);
    const int memoDoomed = insert(QStringLiteral(
        "INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
        "VALUES ('科目被删的备忘', 'x', %1, 1, '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z')").arg(doomed));
    const int taskMerged = insertTask(QStringLiteral("科目被合并的任务"), QStringLiteral("2026-10-03"), 2, merged);
    // 前提：任务文本科目非空，恢复后必须被清掉才说明处理了。
    QCOMPARE(value(QStringLiteral("SELECT category FROM tasks WHERE id = %1").arg(taskDoomed)).toString(),
             QStringLiteral("将被删"));
    QVERIFY(TaskManager::instance()->deleteTask(taskDoomed));
    QVERIFY(MemoService::instance()->deleteMemo(memoDoomed));
    QVERIFY(TaskManager::instance()->deleteTask(taskMerged));

    QVERIFY(CategoryManager::instance()->deleteCategory(doomed));
    // 手工模拟「同名合并」：被合并方的行没了，留一条 merge 删除记录指向留下的那个（同 SyncStore 的做法）。
    QVERIFY(exec(QStringLiteral("DELETE FROM categories WHERE id = %1").arg(merged)));
    QVERIFY(exec(QStringLiteral(
        "INSERT OR REPLACE INTO sync_tombstones (tbl, sync_id, v_time, v_device, kind, merged_into, deleted_at) "
        "VALUES ('categories', :id, 1, 'dev', 'merge', :into, 1)"),
        {{QStringLiteral("id"), mergedSync}, {QStringLiteral("into"), survivorSync}}));

    const QList<int> trashIds = {
        value(QStringLiteral("SELECT id FROM trash_items WHERE title = '科目被删的任务'")).toInt(),
        value(QStringLiteral("SELECT id FROM trash_items WHERE title = '科目被删的备忘'")).toInt(),
        value(QStringLiteral("SELECT id FROM trash_items WHERE title = '科目被合并的任务'")).toInt()};
    for (const int trashId : trashIds) {
        QVERIFY(trashId > 0);
        const QVariantMap result = TrashService::instance()->restoreItem(trashId);
        QVERIFY2(result.value(QStringLiteral("ok")).toBool(), qPrintable(result.value(QStringLiteral("error")).toString()));
    }
    QVERIFY(value(QStringLiteral("SELECT category_id FROM tasks WHERE title = '科目被删的任务'")).isNull());
    QVERIFY(value(QStringLiteral("SELECT category FROM tasks WHERE title = '科目被删的任务'")).isNull());
    QVERIFY(value(QStringLiteral("SELECT category_id FROM memos WHERE title = '科目被删的备忘'")).isNull());
    QCOMPARE(value(QStringLiteral("SELECT category_id FROM tasks WHERE title = '科目被合并的任务'")).toInt(), survivor);
    QCOMPARE(value(QStringLiteral("SELECT category FROM tasks WHERE title = '科目被合并的任务'")).toString(),
             QStringLiteral("留下的"));
}

void TrashServiceTests::restoredRoutineGeneratesTodayOnlyWhenItsInstanceWasReclaimed()
{
    // 产品保证：例行恢复后，当天实例的去留与「停用后再启用」同一套语义：
    // ① 删除时收回过当天没动过的实例 → 恢复后当天补生成一条；
    // ② 用户先删了当天实例再删例行 → 恢复后当天不生成；
    // ③ 当天实例做过（完成）因而留下 → 恢复后当天不生成第二条。
    RoutineManager* manager = RoutineManager::instance();

    // ① 收回过
    QVERIFY(manager->addRoutine(QStringLiteral("例行收回"), m_category));
    int routine = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行收回'")).toInt();
    manager->materializeToday();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_id = %1").arg(routine)), 1);
    QVERIFY(manager->deleteRoutine(routine));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '例行收回'")), 0);
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    int restored = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行收回'")).toInt();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_id = %1 AND date = '%2'").arg(restored).arg(today())), 1);

    // ② 用户先删了当天实例
    QVERIFY(manager->addRoutine(QStringLiteral("例行删过"), m_category));
    routine = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行删过'")).toInt();
    manager->materializeToday();
    const int instance = value(QStringLiteral("SELECT id FROM tasks WHERE routine_id = %1").arg(routine)).toInt();
    QVERIFY(instance > 0);
    QVERIFY(TaskManager::instance()->deleteTask(instance));
    QVERIFY(manager->deleteRoutine(routine));
    const int trashRoutine = value(QStringLiteral("SELECT id FROM trash_items WHERE kind = 'routine' AND title = '例行删过'")).toInt();
    QVERIFY(TrashService::instance()->restoreItem(trashRoutine).value(QStringLiteral("ok")).toBool());
    restored = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行删过'")).toInt();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_id = %1").arg(restored)), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '例行删过'")), 0);

    // ③ 当天实例做过
    QVERIFY(manager->addRoutine(QStringLiteral("例行做过"), m_category));
    routine = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行做过'")).toInt();
    manager->materializeToday();
    QVERIFY(exec(QStringLiteral("UPDATE tasks SET completed = 1 WHERE routine_id = %1").arg(routine)));
    QVERIFY(manager->deleteRoutine(routine));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '例行做过'")), 1); // 留下成了普通任务
    const int trashDone = value(QStringLiteral("SELECT id FROM trash_items WHERE kind = 'routine' AND title = '例行做过'")).toInt();
    QVERIFY(TrashService::instance()->restoreItem(trashDone).value(QStringLiteral("ok")).toBool());
    restored = value(QStringLiteral("SELECT id FROM routines WHERE title = '例行做过'")).toInt();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_id = %1").arg(restored)), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '例行做过'")), 1);
}

void TrashServiceTests::restoredGeneratedInstanceIsAPlainTaskAndNotGeneratedAgain()
{
    // 产品保证：例行生成的当日实例被删后恢复，成为普通任务（不再属于例行），
    // 之后再生成当日例行也不会冒出第二条。
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("每日例行"), m_category));
    manager->materializeToday();
    const int instance = value(QStringLiteral("SELECT id FROM tasks WHERE title = '每日例行'")).toInt();
    QCOMPARE(value(QStringLiteral("SELECT routine_generated FROM tasks WHERE id = %1").arg(instance)).toInt(), 1);
    QVERIFY(TaskManager::instance()->deleteTask(instance));
    QCOMPARE(payloadOfLast().value(QStringLiteral("routine_generated")).toInt(), 1); // 前提：删的是例行实例

    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '每日例行'")), 1);
    QCOMPARE(value(QStringLiteral("SELECT routine_generated FROM tasks WHERE title = '每日例行'")).toInt(), 0);
    QVERIFY(value(QStringLiteral("SELECT routine_id FROM tasks WHERE title = '每日例行'")).isNull());

    manager->materializeToday();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '每日例行'")), 1);
}

void TrashServiceTests::restoreRefusesWhenTheTimeIsOccupied_data()
{
    QTest::addColumn<QString>("kind");
    QTest::addColumn<QString>("occupant");
    QTest::addColumn<QString>("conflict");
    QTest::addColumn<QString>("message");
    QTest::newRow("focus-vs-focus") << "focus" << "focus" << "focus" << "这段时间已有别的专注记录";
    QTest::newRow("focus-vs-rest") << "focus" << "rest" << "rest" << "这段时间已有休息记录";
    QTest::newRow("focus-vs-running-focus") << "focus" << "running" << "focus" << "这段时间已有别的专注记录";
    QTest::newRow("focus-vs-running-rest") << "focus" << "activeRest" << "rest" << "这段时间有正在进行的休息";
    QTest::newRow("rest-vs-focus") << "rest" << "focus" << "focus" << "这段时间已有别的专注记录";
    QTest::newRow("rest-vs-rest") << "rest" << "rest" << "rest" << "这段时间已有休息记录";
}

void TrashServiceTests::restoreRefusesWhenTheTimeIsOccupied()
{
    // 产品保证：恢复专注/休息记录前重新检查时间冲突（专注、休息、正在进行的计时都算占用），
    // 被占用就拒绝并说清是哪一类占着，废纸篓里那一项留着，也不会多出一条新记录。
    // 占用区间只与被删记录相交一小段，边界相接（不相交）的情形在最后作为对照必须能恢复。
    QFETCH(QString, kind);
    QFETCH(QString, occupant);
    QFETCH(QString, conflict);
    QFETCH(QString, message);
    const bool focus = kind == QLatin1String("focus");
    const int id = seedKind(focus ? QStringLiteral("focus_session") : QStringLiteral("rest_session"));
    QVERIFY(id > 0);
    const QString table = focus ? QStringLiteral("focus_sessions") : QStringLiteral("rest_sessions");
    // 被删记录：专注 14:05–14:50，休息 21:10–21:25。占用方与它重叠一小段。
    const QString start = focus ? QStringLiteral("2026-10-03T14:05:00.000") : QStringLiteral("2026-10-03T21:10:00.000");
    QVERIFY(deleteKind(focus ? QStringLiteral("focus_session") : QStringLiteral("rest_session"), id));
    const QDateTime s = QDateTime::fromString(start, Qt::ISODateWithMs);
    const QString overlapStart = s.addSecs(-300).toString(Qt::ISODateWithMs);
    const QString overlapEnd = s.addSecs(300).toString(Qt::ISODateWithMs);

    int occupantId = -1;
    if (occupant == QLatin1String("focus")) {
        occupantId = insertFocus(0, overlapStart, overlapEnd, 600);
    } else if (occupant == QLatin1String("rest")) {
        occupantId = insertRest(overlapStart, overlapEnd, 600);
    } else if (occupant == QLatin1String("running")) {
        occupantId = insertFocus(0, overlapStart, QString(), 0); // 进行中：end_time 为空，占用到「现在」
    } else {
        // 进行中的休息只存在于活动状态快照里。
        occupantId = insert(QStringLiteral(
            "INSERT INTO active_focus_state (singleton_id, session_id, task_id, task_title, elapsed_seconds, "
            "mode, phase, target_seconds, completed_pomodoros, updated_at, start_time) "
            "VALUES (1, NULL, NULL, '', 600, 0, 2, 0, 0, :u, :s)"),
            {{QStringLiteral("u"), overlapEnd}, {QStringLiteral("s"), overlapStart}});
    }
    QVERIFY(occupantId > 0);
    const int focusRows = count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions"));
    const int restRows = count(QStringLiteral("SELECT COUNT(*) FROM rest_sessions"));
    const int trashId = lastTrashId();
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);

    const QVariantMap result = TrashService::instance()->restoreItem(trashId);
    QVERIFY(!result.value(QStringLiteral("ok")).toBool());
    QCOMPARE(result.value(QStringLiteral("conflict")).toString(), conflict);
    QCOMPARE(result.value(QStringLiteral("error")).toString(), message);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), focusRows);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM rest_sessions")), restRows);

    // 对照：占用方挪到被删记录结束之后紧邻（区间相接、不相交）时恢复成功。
    const QDateTime end = QDateTime::fromString(
        focus ? QStringLiteral("2026-10-03T14:50:00.000") : QStringLiteral("2026-10-03T21:25:00.000"), Qt::ISODateWithMs);
    if (occupant == QLatin1String("focus") || occupant == QLatin1String("running")) {
        QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET start_time = :s, end_time = :e WHERE id = :id"),
                     {{QStringLiteral("s"), end.toString(Qt::ISODateWithMs)},
                      {QStringLiteral("e"), end.addSecs(600).toString(Qt::ISODateWithMs)},
                      {QStringLiteral("id"), occupantId}}));
    } else if (occupant == QLatin1String("rest")) {
        QVERIFY(exec(QStringLiteral("UPDATE rest_sessions SET start_time = :s, end_time = :e WHERE id = :id"),
                     {{QStringLiteral("s"), end.toString(Qt::ISODateWithMs)},
                      {QStringLiteral("e"), end.addSecs(600).toString(Qt::ISODateWithMs)},
                      {QStringLiteral("id"), occupantId}}));
    } else {
        QVERIFY(exec(QStringLiteral("DELETE FROM active_focus_state")));
    }
    const QVariantMap retry = TrashService::instance()->restoreItem(trashId);
    QVERIFY2(retry.value(QStringLiteral("ok")).toBool(), qPrintable(retry.value(QStringLiteral("error")).toString()));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE start_time = :s").arg(table), {{QStringLiteral("s"), start}}), 1);
}

void TrashServiceTests::unknownKindOrFuturePayloadCannotBeRestored()
{
    // 产品保证：更新版本新增的类型、或更高的内容格式，旧版能列出来但不能恢复，
    // 提示「需要更新应用后才能恢复」，并且这一项原样留在废纸篓里。
    const QString now = utcText(QDateTime::currentDateTime());
    const int unknown = insertTrashRow(QStringLiteral("gizmo"), QStringLiteral("o1"), QStringLiteral("新类型"),
                                       QStringLiteral("{\"v\":1}"), now);
    const int future = insertTrashRow(QStringLiteral("task"), QStringLiteral("o2"), QStringLiteral("新格式"),
                                      QStringLiteral("{\"v\":2,\"title\":\"x\",\"date\":\"2026-10-03\"}"), now);
    const QVariantMap listed = TrashService::instance()->readItems();
    QVERIFY(listed.value(QStringLiteral("ok")).toBool());
    for (const QVariant& item : listed.value(QStringLiteral("items")).toList()) {
        QVERIFY(!item.toMap().value(QStringLiteral("restorable")).toBool());
        QCOMPARE(item.toMap().value(QStringLiteral("blockedReason")).toString(), QStringLiteral("needsUpdate"));
    }
    QCOMPARE(listed.value(QStringLiteral("items")).toList().size(), 2);
    for (const int id : {unknown, future}) {
        const QVariantMap result = TrashService::instance()->restoreItem(id);
        QVERIFY(!result.value(QStringLiteral("ok")).toBool());
        QCOMPARE(result.value(QStringLiteral("error")).toString(), QStringLiteral("这一项需要更新应用后才能恢复"));
    }
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 2);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
}

void TrashServiceTests::alreadyGoneItemIsReported()
{
    // 产品保证：另一台设备刚恢复或删掉了这一项时，再恢复/再彻底删除要如实说「这一项已经不在废纸篓里了」，
    // 并且不会恢复出第二份。
    const int id = seedKind(QStringLiteral("task"));
    QVERIFY(TaskManager::instance()->deleteTask(id));
    const int trashId = lastTrashId();
    QVERIFY(TrashService::instance()->restoreItem(trashId).value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);

    const QString gone = QStringLiteral("这一项已经不在废纸篓里了");
    const QVariantMap again = TrashService::instance()->restoreItem(trashId);
    QVERIFY(!again.value(QStringLiteral("ok")).toBool());
    QCOMPARE(again.value(QStringLiteral("error")).toString(), gone);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    const QVariantMap deleted = TrashService::instance()->deleteItem(trashId);
    QVERIFY(!deleted.value(QStringLiteral("ok")).toBool());
    QCOMPARE(deleted.value(QStringLiteral("error")).toString(), gone);
}

void TrashServiceTests::restoreEmitsRefreshSignalsForWhatChanged()
{
    // 产品保证：恢复任务后任务列表刷新；真的接回了专注记录时历史也刷新；
    // 没有专注记录可接回时不发多余的历史信号。
    const int plain = insertTask(QStringLiteral("没有专注的任务"), QStringLiteral("2026-10-03"));
    QVERIFY(TaskManager::instance()->deleteTask(plain));
    QSignalSpy tasks(TaskManager::instance(), &TaskManager::tasksChanged);
    QSignalSpy history(FocusHistoryService::instance(), &FocusHistoryService::historyChanged);
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QVERIFY(tasks.count() >= 1);
    QCOMPARE(history.count(), 0);

    const int withSession = insertTask(QStringLiteral("有专注的任务"), QStringLiteral("2026-10-03"));
    QVERIFY(insertFocus(withSession, QStringLiteral("2026-10-03T08:00:00.000"), QStringLiteral("2026-10-03T08:30:00.000"), 1800) > 0);
    QVERIFY(TaskManager::instance()->deleteTask(withSession));
    tasks.clear();
    QVERIFY(TrashService::instance()->restoreItem(lastTrashId()).value(QStringLiteral("ok")).toBool());
    QVERIFY(tasks.count() >= 1);
    QCOMPARE(history.count(), 1);
}

// ───────────────────────── 列表、去重、清理 ─────────────────────────

void TrashServiceTests::readItemsOrdersNewestFirstAndDescribesEachItem()
{
    // 产品保证：列表按删除时刻从新到旧，同一时刻按编号大的在前；每项给出类型、标题、本地逻辑删除日、
    // 还剩天数、科目现名与颜色（专注记录在科目不在时退回快照）和按类型的结构化要点。
    // 插入顺序故意与期望顺序相反，并构造一对同刻的行检验兜底排序。
    const QDateTime base = QDateTime(QDate(2026, 10, 6), QTime(12, 0));
    TrashService::instance()->setNowForTesting(base);
    const QString catSync = syncIdOf(QStringLiteral("categories"), m_category);
    const int oldest = insertTrashRow(QStringLiteral("countdown_goal"), QStringLiteral("g1"), QStringLiteral("最旧"),
                                      QStringLiteral("{\"v\":1,\"target_date\":\"2026-12-19\"}"),
                                      utcText(base.addDays(-3)));
    const int tieLow = insertTrashRow(QStringLiteral("task"), QStringLiteral("t1"), QStringLiteral("同刻先插"),
                                      QStringLiteral("{\"v\":1,\"date\":\"2026-10-03\",\"completed\":1,\"estimated_minutes\":30,\"category_sync_id\":\"%1\"}").arg(catSync),
                                      utcText(base.addDays(-1)));
    const int tieHigh = insertTrashRow(QStringLiteral("focus_session"), QStringLiteral("f1"), QStringLiteral("同刻后插"),
                                       QStringLiteral("{\"v\":1,\"start_time\":\"2026-10-03T14:05:00.000\",\"end_time\":\"2026-10-03T14:50:00.000\","
                                                      "\"duration\":2700,\"mode\":1,\"task_title\":\"原任务\",\"category_sync_id\":\"gone\","
                                                      "\"category_name_snapshot\":\"快照科目\",\"category_color_snapshot\":\"#abcdef\"}"),
                                       utcText(base.addDays(-1)));
    const int newest = insertTrashRow(QStringLiteral("memo"), QStringLiteral("m1"), QStringLiteral("最新"),
                                      QStringLiteral("{\"v\":1,\"category_sync_id\":\"gone\"}"), utcText(base));
    const QVariantMap result = TrashService::instance()->readItems();
    QVERIFY(result.value(QStringLiteral("ok")).toBool());
    const QVariantList items = result.value(QStringLiteral("items")).toList();
    QCOMPARE(items.size(), 4);
    QCOMPARE(items.at(0).toMap().value(QStringLiteral("id")).toInt(), newest);
    QCOMPARE(items.at(1).toMap().value(QStringLiteral("id")).toInt(), tieHigh);
    QCOMPARE(items.at(2).toMap().value(QStringLiteral("id")).toInt(), tieLow);
    QCOMPARE(items.at(3).toMap().value(QStringLiteral("id")).toInt(), oldest);

    const QVariantMap task = items.at(2).toMap();
    QCOMPARE(task.value(QStringLiteral("kind")).toString(), QStringLiteral("task"));
    QCOMPARE(task.value(QStringLiteral("deletedDate")).toString(), QStringLiteral("2026-10-05"));
    QCOMPARE(task.value(QStringLiteral("remainingDays")).toInt(), 29);
    QCOMPARE(task.value(QStringLiteral("originSyncId")).toString(), QStringLiteral("t1"));
    QCOMPARE(task.value(QStringLiteral("categoryName")).toString(), QStringLiteral("数学"));
    QCOMPARE(task.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#d4a574"));
    QVERIFY(task.value(QStringLiteral("restorable")).toBool());
    QCOMPARE(task.value(QStringLiteral("blockedReason")).toString(), QString());
    QCOMPARE(task.value(QStringLiteral("details")).toMap().value(QStringLiteral("estimatedMinutes")).toInt(), 30);
    QCOMPARE(task.value(QStringLiteral("details")).toMap().value(QStringLiteral("completed")).toBool(), true);
    QCOMPARE(task.value(QStringLiteral("deletedAt")).toString(), utcText(base.addDays(-1)));

    const QVariantMap focus = items.at(1).toMap();
    QCOMPARE(focus.value(QStringLiteral("categoryName")).toString(), QStringLiteral("快照科目"));
    QCOMPARE(focus.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#abcdef"));
    QCOMPARE(focus.value(QStringLiteral("details")).toMap().value(QStringLiteral("durationSeconds")).toInt(), 2700);
    QCOMPARE(focus.value(QStringLiteral("details")).toMap().value(QStringLiteral("taskTitle")).toString(), QStringLiteral("原任务"));

    const QVariantMap memo = items.at(0).toMap();
    QCOMPARE(memo.value(QStringLiteral("categoryName")).toString(), QString()); // 非专注记录科目不在时给空串
    QCOMPARE(memo.value(QStringLiteral("remainingDays")).toInt(), 30);
    QVERIFY(memo.value(QStringLiteral("details")).toMap().isEmpty());
}

void TrashServiceTests::twinsSharingAnOriginAreListedOnceAndHandledTogether()
{
    // 产品保证：同一条原记录在废纸篓里有多行时，列表里只列最新的一条；恢复或彻底删除时多行一起处理，不留下分身。
    // 废纸篓记录的身份由原记录推出，两台设备各写的同一条通常合成一行；多行只会出现在身份退回随机的情形
    // （这个身份在本机已被占用、或已有它的删除记录）。这里靠「第一行占住推出的身份」造出这种情形。
    const QDateTime base = QDateTime::currentDateTime();
    const QString payload = QStringLiteral("{\"v\":1,\"title\":\"同一任务\",\"date\":\"2026-10-03\"}");
    const int older = insertTrashRow(QStringLiteral("task"), QStringLiteral("same"), QStringLiteral("较旧"), payload, utcText(base.addSecs(-60)));
    const int newer = insertTrashRow(QStringLiteral("task"), QStringLiteral("same"), QStringLiteral("较新"), payload, utcText(base));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'same'")), 2);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE sync_id = 'trash-same'")), 1);
    insertTrashRow(QStringLiteral("task"), QString(), QStringLiteral("无身份甲"), payload, utcText(base));
    insertTrashRow(QStringLiteral("task"), QString(), QStringLiteral("无身份乙"), payload, utcText(base));
    QVERIFY(older < newer);
    QVariantList items = TrashService::instance()->readItems().value(QStringLiteral("items")).toList();
    int same = 0;
    for (const QVariant& item : items) {
        if (item.toMap().value(QStringLiteral("originSyncId")).toString() == QLatin1String("same")) {
            ++same;
            QCOMPARE(item.toMap().value(QStringLiteral("title")).toString(), QStringLiteral("较新"));
        }
    }
    QCOMPARE(same, 1);
    QCOMPARE(items.size(), 3); // 空 origin 的两行互不去重

    QVERIFY(TrashService::instance()->deleteItem(older).value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'same'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 2);

    const int a = insertTrashRow(QStringLiteral("task"), QStringLiteral("twin"), QStringLiteral("甲"), payload, utcText(base.addSecs(-60)));
    insertTrashRow(QStringLiteral("task"), QStringLiteral("twin"), QStringLiteral("乙"), payload, utcText(base));
    const QVariantMap restored = TrashService::instance()->restoreItem(a);
    QVERIFY2(restored.value(QStringLiteral("ok")).toBool(), qPrintable(restored.value(QStringLiteral("error")).toString()));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'twin'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

void TrashServiceTests::deleteItemAndEmptyTrashRemoveRows()
{
    // 产品保证：彻底删除只删这一项，清空删光并报告数量；两者都发 trashChanged。
    const QString payload = QStringLiteral("{\"v\":1}");
    const QString now = utcText(QDateTime::currentDateTime());
    const int a = insertTrashRow(QStringLiteral("memo"), QStringLiteral("a"), QStringLiteral("A"), payload, now);
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("b"), QStringLiteral("B"), payload, now);
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("c"), QStringLiteral("C"), payload, now);
    QSignalSpy changed(TrashService::instance(), &TrashService::trashChanged);
    QVERIFY(TrashService::instance()->deleteItem(a).value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 2);
    QCOMPARE(changed.count(), 1);
    const QVariantMap emptied = TrashService::instance()->emptyTrash();
    QVERIFY(emptied.value(QStringLiteral("ok")).toBool());
    QCOMPARE(emptied.value(QStringLiteral("count")).toInt(), 2);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QCOMPARE(changed.count(), 2);
}

void TrashServiceTests::retentionKeepsDay29AndPurgesDay30()
{
    // 产品保证：保留期 30 天——逻辑日 D 删除的，D+29 还在（还剩 1 天），D+30 被清掉。
    const QString payload = QStringLiteral("{\"v\":1}");
    const QDateTime deleted(QDate(2026, 10, 1), QTime(12, 0));
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("x"), QStringLiteral("到期测试"), payload, utcText(deleted));
    QSignalSpy changed(TrashService::instance(), &TrashService::trashChanged);

    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 10, 30), QTime(12, 0)));
    QCOMPARE(TrashService::instance()->readItems().value(QStringLiteral("items")).toList().first().toMap()
                 .value(QStringLiteral("remainingDays")).toInt(), 1);
    QCOMPARE(TrashService::instance()->purgeExpired(), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 1);
    QCOMPARE(changed.count(), 0); // 没删东西不发信号

    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 10, 31), QTime(12, 0)));
    QCOMPARE(TrashService::instance()->purgeExpired(), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QCOMPARE(changed.count(), 1);
}

void TrashServiceTests::retentionFollowsTheLogicalDayBoundary()
{
    // 产品保证：保留期按逻辑日算——日界点 4:00 之前删除的算前一天。
    // 数据：同一个自然日 10-02 里凌晨 3:59 和 4:00 各删一条（逻辑日分别是 10-01 与 10-02）。
    // 在 10-31 中午，3:59 那条已满 30 天被清掉、4:00 那条还剩 1 天；按自然日算的实现会两条都留着。
    // 再把「现在」推到 11-01 的 3:59（逻辑日仍是 10-31）与 4:00（逻辑日 11-01）：4:00 那条在前者还在、后者被清掉。
    const QString payload = QStringLiteral("{\"v\":1}");
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("early"), QStringLiteral("日界前"), payload,
                   utcText(QDateTime(QDate(2026, 10, 2), QTime(3, 59))));
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("late"), QStringLiteral("日界后"), payload,
                   utcText(QDateTime(QDate(2026, 10, 2), QTime(4, 0))));
    QCOMPARE(AppSettings::instance()->dayStartHour(), 4);

    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 10, 31), QTime(12, 0)));
    QCOMPARE(TrashService::instance()->purgeExpired(), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'early'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'late'")), 1);

    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 11, 1), QTime(3, 59)));
    QCOMPARE(TrashService::instance()->purgeExpired(), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'late'")), 1);
    TrashService::instance()->setNowForTesting(QDateTime(QDate(2026, 11, 1), QTime(4, 0)));
    QCOMPARE(TrashService::instance()->purgeExpired(), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
}

void TrashServiceTests::readItemsFailsLoudlyWhenDatabaseIsClosed()
{
    // 产品保证：读取失败不当成「废纸篓是空的」——返回 ok=false 和原因，items 为空，也不发信号。
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("a"), QStringLiteral("A"), QStringLiteral("{\"v\":1}"),
                   utcText(QDateTime::currentDateTime()));
    QSignalSpy changed(TrashService::instance(), &TrashService::trashChanged);
    DatabaseManager::instance()->close();
    const QVariantMap result = TrashService::instance()->readItems();
    QVERIFY(!result.value(QStringLiteral("ok")).toBool());
    QVERIFY(!result.value(QStringLiteral("error")).toString().isEmpty());
    QVERIFY(result.value(QStringLiteral("items")).toList().isEmpty());
    QCOMPARE(changed.count(), 0);
}

void TrashServiceTests::failedAssociationLookupFailsTheDeletion()
{
    // 产品保证：删除任务时查关联（挂在它上面的知识缺口）的 SQL 失败，不能当成「没有关联」照常写入——
    // 那会让恢复时少接回关联而无人察觉。查询失败时删除整体失败：任务还在、废纸篓没有新行。
    const int task = insertTask(QStringLiteral("有关联的任务"), QStringLiteral("2026-10-03"));
    QVERIFY(insert(QStringLiteral("INSERT INTO knowledge_gaps (title, source_task_id, created_at, updated_at) "
                                  "VALUES ('关联缺口', %1, '2026-10-01T00:00:00', '2026-10-01T00:00:00')").arg(task)) > 0);
    // 测试专用：把 knowledge_gaps 改名，让 capture 里查缺口关联的语句确实执行失败（表不存在）；用完立刻改回。
    QVERIFY(exec(QStringLiteral("ALTER TABLE knowledge_gaps RENAME TO kg_tmp")));
    const bool deleted = TaskManager::instance()->deleteTask(task);
    QVERIFY(exec(QStringLiteral("ALTER TABLE kg_tmp RENAME TO knowledge_gaps")));

    QVERIFY(!deleted);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE id = %1").arg(task)), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    // 改回后恢复正常：同一任务可以删除并带着关联进废纸篓。
    QVERIFY(TaskManager::instance()->deleteTask(task));
    QCOMPARE(payloadOfLast().value(QStringLiteral("gap_source_sync_ids")).toArray().size(), 1);
}

void TrashServiceTests::corruptPayloadIsReportedAsCorruptedAndNotAsNeedingUpdate()
{
    // 产品保证：内容损坏（不是合法 JSON、不是对象、日期无效）的废纸篓项恢复时报「内容已损坏」，
    // 而不是误报成「需要更新应用」；列表里也标成内容损坏；行仍在，也不会插出空日期的任务。
    const QString now = utcText(QDateTime::currentDateTime());
    const QStringList payloads = {
        QStringLiteral("not json {"), QStringLiteral("[1,2]"),
        QStringLiteral("{\"v\":1,\"title\":\"坏日期\",\"date\":\"2026-13-45\"}"),
        QStringLiteral("{\"v\":1,\"title\":\"无日期\"}")};
    QList<int> ids;
    for (const QString& payload : payloads) {
        const int id = insertTrashRow(QStringLiteral("task"), QString(), QStringLiteral("损坏项"), payload, now);
        QVERIFY(id > 0);
        ids.append(id);
        const QVariantMap result = TrashService::instance()->restoreItem(id);
        QVERIFY(!result.value(QStringLiteral("ok")).toBool());
        QCOMPARE(result.value(QStringLiteral("error")).toString(), QStringLiteral("这一项的内容已损坏，无法恢复"));
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE id = %1").arg(id)), 1);
    }
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);

    // 列表一侧：不是合法 JSON 对象的两行标成 corrupted（界面据此写原因），不能说成 needsUpdate。
    // 日期无效属于更细的损坏，列表不查，恢复时才报（上面已验）。
    QHash<int, QVariantMap> listed;
    for (const QVariant& item : TrashService::instance()->readItems().value(QStringLiteral("items")).toList()) {
        listed.insert(item.toMap().value(QStringLiteral("id")).toInt(), item.toMap());
    }
    QCOMPARE(listed.size(), payloads.size());
    for (qsizetype i = 0; i < 2; ++i) {
        const QVariantMap item = listed.value(ids.at(i));
        QVERIFY(!item.value(QStringLiteral("restorable")).toBool());
        QCOMPARE(item.value(QStringLiteral("blockedReason")).toString(), QStringLiteral("corrupted"));
        QCOMPARE(item.value(QStringLiteral("title")).toString(), QStringLiteral("损坏项")); // 标题照常列出，用户能认出并删掉它
    }
}

void TrashServiceTests::restoreFailsAsAWholeWhenReferenceLookupFails()
{
    // 产品保证：恢复时解析科目的查询本身失败，整体失败回滚，不能把科目当成「没有」而恢复出一条丢了科目的任务。
    // payload 里的科目 sync_id 在本机不存在，解析会继续去查合并记录（sync_tombstones）；
    // 测试专用：把它改名让这一查询失败，用完改回。
    const int id = insertTrashRow(QStringLiteral("task"), QStringLiteral("o"), QStringLiteral("引用科目的任务"),
                                  QStringLiteral("{\"v\":1,\"title\":\"引用科目的任务\",\"date\":\"2026-10-03\","
                                                 "\"category_sync_id\":\"ghost\"}"),
                                  utcText(QDateTime::currentDateTime()));
    QVERIFY(id > 0);
    QVERIFY(exec(QStringLiteral("ALTER TABLE sync_tombstones RENAME TO tomb_tmp")));
    const QVariantMap result = TrashService::instance()->restoreItem(id);
    QVERIFY(exec(QStringLiteral("ALTER TABLE tomb_tmp RENAME TO sync_tombstones")));
    QVERIFY(!result.value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE id = %1").arg(id)), 1);
    // 改回后同一项能恢复（科目找不到就归未分类）。
    QVERIFY(TrashService::instance()->restoreItem(id).value(QStringLiteral("ok")).toBool());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
}

void TrashServiceTests::expiredRowsAreHiddenAndFutureDeletionTimesAreClamped()
{
    // 产品保证：已到期但还没被清理的行不出现在列表里；另一台设备时钟偏快写出的「未来」删除时刻，
    // 剩余天数最多显示 30，不会出现「还剩 31 天」。不调用 purgeExpired，证明列表自己过滤。
    const QString payload = QStringLiteral("{\"v\":1}");
    const QDateTime now(QDate(2026, 10, 31), QTime(12, 0));
    TrashService::instance()->setNowForTesting(now);
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("expired"), QStringLiteral("已到期"), payload,
                   utcText(QDateTime(QDate(2026, 10, 1), QTime(12, 0))));
    insertTrashRow(QStringLiteral("memo"), QStringLiteral("future"), QStringLiteral("未来"), payload,
                   utcText(now.addDays(1)));
    const QVariantList items = TrashService::instance()->readItems().value(QStringLiteral("items")).toList();
    QCOMPARE(items.size(), 1);
    QCOMPARE(items.first().toMap().value(QStringLiteral("originSyncId")).toString(), QStringLiteral("future"));
    QCOMPARE(items.first().toMap().value(QStringLiteral("remainingDays")).toInt(), 30);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 2); // 行还在库里，只是不列出
}

// ───────────────────────── 迁移与契约 ─────────────────────────

void TrashServiceTests::upgradingFromV20AddsAnEmptyTrashAndKeepsData()
{
    // 产品保证：v20 的库（没有 trash_items、带用户数据）升级后版本为 21、有一张空的废纸篓表、
    // 原有数据不变，并且升级前先留了一份迁移快照。
    QVERIFY(insertTask(QStringLiteral("升级前任务"), QStringLiteral("2026-10-03"), 1, m_category) > 0);
    QVERIFY(exec(QStringLiteral("DROP TABLE trash_items")));
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 20")));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'trash_items'")), 0);
    const QDir dir(m_tempDir->path());
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const qsizetype snapshotsBefore = dir.entryList(pattern, QDir::Files).size();

    QVERIFY(DatabaseManager::instance()->createTables());

    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), 21);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 0);
    QVERIFY(DatabaseManager::trashSchemaIsValid(db()));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '升级前任务'")), 1);
    QCOMPARE(dir.entryList(pattern, QDir::Files).size(), snapshotsBefore + 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_trash_items_deleted'")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_trash_items_origin'")), 1);
}

void TrashServiceTests::brokenTrashSchemaIsRejected_data()
{
    QTest::addColumn<QString>("definition");
    const QString good = QStringLiteral(
        "id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL CHECK(length(kind) > 0), "
        "origin_sync_id TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL, "
        "deleted_at TEXT NOT NULL");
    QTest::newRow("missing-column") << QStringLiteral(
        "id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL CHECK(length(kind) > 0), "
        "origin_sync_id TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL, deleted_at TEXT NOT NULL");
    QTest::newRow("nullable-payload") << QString(good).replace(QStringLiteral("payload TEXT NOT NULL"), QStringLiteral("payload TEXT"));
    QTest::newRow("wrong-type") << QString(good).replace(QStringLiteral("deleted_at TEXT"), QStringLiteral("deleted_at INTEGER"));
    QTest::newRow("missing-check") << QString(good).replace(QStringLiteral(" CHECK(length(kind) > 0)"), QString());
    QTest::newRow("no-autoincrement-id") << QString(good).replace(QStringLiteral("INTEGER PRIMARY KEY AUTOINCREMENT"), QStringLiteral("INT PRIMARY KEY"));
    QTest::newRow("foreign-key") << good + QStringLiteral(", FOREIGN KEY (origin_sync_id) REFERENCES categories(sync_id)");
}

void TrashServiceTests::brokenTrashSchemaIsRejected()
{
    // 产品保证：废纸篓表结构不对（缺列、约束被改、多出外键）时启动拒绝，而不是带着坏表继续运行，
    // 让「找回」兜底静默失效。
    QFETCH(QString, definition);
    QVERIFY(exec(QStringLiteral("DROP TABLE trash_items")));
    QVERIFY(exec(QStringLiteral("CREATE TABLE trash_items (%1)").arg(definition)));
    QVERIFY(!DatabaseManager::trashSchemaIsValid(db()));
    QVERIFY(!DatabaseManager::instance()->createTables());
}

QTEST_MAIN(TrashServiceTests)
#include "TrashServiceTests.moc"
