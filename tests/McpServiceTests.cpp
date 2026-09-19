#include <QtTest>
#include "../src/mcp/bridge/McpToolDispatcher.h"
#include "../src/services/TaskInteractionCoordinator.h"
#include "../src/services/TaskManager.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/AppSettings.h"
#include <QTemporaryDir>
#include <QSettings>
#include <QSqlQuery>
#include <QSignalSpy>
#include <QJsonArray>
#include <QJsonDocument>
#include <QUuid>

using namespace McpContracts;
class McpServiceTests : public QObject
{
    Q_OBJECT
    QTemporaryDir preferences;
    std::unique_ptr<QTemporaryDir> data;
    std::unique_ptr<TaskInteractionCoordinator> interactions;
    std::unique_ptr<McpToolDispatcher> dispatcher;
    QString session;
    QJsonObject run(Tool tool, QJsonObject arguments = {}) { return dispatcher->dispatch(tool, arguments); }
    QJsonObject output(const QJsonObject& result) { return result.value("structuredContent").toObject(); }
    QString code(const QJsonObject& result) {
        return QJsonDocument::fromJson(result.value("content").toArray().first().toObject().value("text").toString().toUtf8()).object().value("code").toString();
    }
    QJsonObject range(int limit = 100) { return {{"start_date", "2026-09-17"}, {"end_date", "2026-09-17"}, {"limit", limit}}; }
    int task(const QString& title = QStringLiteral("同名任务")) {
        return TaskManager::instance()->createTask(title, QStringLiteral("2026-09-17"), 0, 30, QStringLiteral("备注"));
    }
private slots:
    void initTestCase()
    {
        QVERIFY(preferences.isValid());
        // AppSettings 单例也只落到临时 INI，整个测试不读取生产偏好或业务数据库。
        QCoreApplication::setOrganizationName("McpIsolatedTests");
        QCoreApplication::setApplicationName("McpServiceTests");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences.path());
        AppSettings::instance()->setDayStartHour(4);
    }
    void init()
    {
        data = std::make_unique<QTemporaryDir>();
        QVERIFY(DatabaseManager::instance()->initialize(data->filePath("test.sqlite")));
        session = QUuid::createUuid().toString(QUuid::WithoutBraces);
        interactions = std::make_unique<TaskInteractionCoordinator>(TaskManager::instance());
        dispatcher = std::make_unique<McpToolDispatcher>(TaskManager::instance(), CategoryManager::instance(), StatisticsService::instance(),
            KnowledgeGapService::instance(), interactions.get(), [this] {
                return McpToolDispatcher::Context{session, QDateTime::fromString("2026-09-18T02:00:00+08:00", Qt::ISODate), 4};
            });
    }
    void invalidTextReturnsValidationError()
    {
        const int id = task();
        const auto before = output(run(Tool::GetTask, {{"task_id", id}}));
        const char32_t codePoint = U'\U0001F600';
        const QString emoji = QString::fromUcs4(&codePoint, 1);
        for (const Tool tool : {Tool::CreateTask, Tool::UpdateTask}) {
            const QJsonObject base = tool == Tool::CreateTask ? createArgs() : QJsonObject{
                {"task_id", id}, {"app_session_id", session},
                {"expected_state_token", before.value("task").toObject().value("state_token")}};
            for (const auto& fields : {QJsonObject{{"title", "   "}}, QJsonObject{{"title", emoji.repeated(60)}},
                                       QJsonObject{{"notes", emoji.repeated(1500)}}}) {
                auto args = base;
                for (auto it = fields.begin(); it != fields.end(); ++it) args.insert(it.key(), it.value());
                QCOMPARE(code(run(tool, args)), QStringLiteral("VALIDATION_ERROR"));
            }
        }
        QCOMPARE(output(run(Tool::GetTask, {{"task_id", id}})), before);
        QCOMPARE(output(run(Tool::ListTasks, range())).value("count").toInt(), 1);
    }
    void cleanup() { dispatcher.reset(); interactions.reset(); DatabaseManager::instance()->close(); data.reset(); }
    QJsonObject createArgs() {
        return {{"title", "新任务"}, {"date", "2026-09-17"}, {"app_session_id", session},
                {"idempotency_key", QUuid::createUuid().toString(QUuid::WithoutBraces)}};
    }
    QJsonObject editArgs(int id) {
        return {{"task_id", id}, {"app_session_id", session},
                {"expected_state_token", output(run(Tool::GetTask, {{"task_id", id}})).value("task").toObject().value("state_token")}};
    }
    void serializedResponseBudget()
    {
        const int id = task();
        auto db = DatabaseManager::instance()->database();
        QSqlQuery query(db);
        query.prepare("UPDATE tasks SET notes=? WHERE id=?");
        query.addBindValue(QString(600000, QChar('x'))); query.addBindValue(id);
        QVERIFY(query.exec());
        QCOMPARE(code(run(Tool::GetTask, {{"task_id", id}})), QStringLiteral("RESULT_LIMIT_EXCEEDED"));
        // 目标写入也先核对完整响应预算，不能提交后才发现响应放不下。
        auto args = QJsonObject{{"task_id", id}, {"app_session_id", session}, {"title", "不应写入"},
                               {"expected_state_token", QString(64, QChar('a'))}};
        QCOMPARE(code(run(Tool::UpdateTask, args)), QStringLiteral("STATE_CONFLICT"));
        QCOMPARE(TaskManager::instance()->readTask(id).value.value("title").toString(), QStringLiteral("同名任务"));
    }
    void creationCapacityAndSession()
    {
        auto db = DatabaseManager::instance()->database();
        QVERIFY(db.transaction());
        const auto first = createArgs();
        QVERIFY(!run(Tool::CreateTask, first).value("isError").toBool());
        for (int i = 1; i < 10000; ++i) {
            const auto result = run(Tool::CreateTask, createArgs());
            QVERIFY2(!result.value("isError").toBool(), "创建登记未达到容量就失败");
        }
        QCOMPARE(code(run(Tool::CreateTask, createArgs())), QStringLiteral("WRITE_CAPACITY_REACHED"));
        QVERIFY(output(run(Tool::CreateTask, first)).value("replayed").toBool());
        QVERIFY(db.commit());
        session = QUuid::createUuid().toString(QUuid::WithoutBraces);
        QCOMPARE(code(run(Tool::CreateTask, first)), QStringLiteral("SESSION_EXPIRED"));
        QVERIFY(!run(Tool::CreateTask, createArgs()).value("isError").toBool());
    }
    void creationReplayAndBusyRetry()
    {
        auto args = createArgs();
        QObject owner; const int existing = task();
        QVERIFY(interactions->beginDrag(&owner, existing, "test.drag"));
        QCOMPARE(code(run(Tool::CreateTask, args)), QStringLiteral("APP_BUSY"));
        interactions->end(&owner);
        const auto first = output(run(Tool::CreateTask, args));
        const int id = first.value("created_task_id").toInt(); QVERIFY(id > existing);
        QVERIFY(!first.value("replayed").toBool());
        QVERIFY(TaskManager::instance()->updateTask(id, "新标题", 0, "2026-09-17"));
        QVERIFY(interactions->beginDrag(&owner, existing, "test.drag"));
        auto replay = output(run(Tool::CreateTask, args));
        QVERIFY(replay.value("replayed").toBool());
        QCOMPARE(replay.value("task").toObject().value("title").toString(), QStringLiteral("新标题"));
        interactions->end(&owner);
        interactions->setPendingDelete(&owner, id);
        replay = output(run(Tool::CreateTask, args));
        QCOMPARE(replay.value("current_state").toString(), QStringLiteral("pending_delete"));
        QVERIFY(replay.value("task").isNull());
        interactions->end(&owner);
        QVERIFY(TaskManager::instance()->deleteTask(id));
        replay = output(run(Tool::CreateTask, args));
        QCOMPARE(replay.value("current_state").toString(), QStringLiteral("deleted"));
        QCOMPARE(replay.value("created_task_id").toInt(), id);
        auto different = args; different.insert("title", "不同内容");
        QCOMPARE(code(run(Tool::CreateTask, different)), QStringLiteral("IDEMPOTENCY_CONFLICT"));
        args.insert("idempotency_key", QUuid::createUuid().toString(QUuid::WithoutBraces));
        QVERIFY(output(run(Tool::CreateTask, args)).value("created_task_id").toInt() > id);
    }
    void targetStateConflictAndLegacyFields()
    {
        const int id = task();
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("UPDATE tasks SET estimated_minutes=2475,category='旧科目文本',category_id=NULL WHERE id=%1").arg(id)));
        auto args = editArgs(id); args.insert("title", "修改标题");
        QSignalSpy changed(TaskManager::instance(), &TaskManager::tasksChanged);
        QSignalSpy failed(TaskManager::instance(), &TaskManager::operationFailed);
        auto result = output(run(Tool::UpdateTask, args));
        QVERIFY(result.value("changed").toBool());
        QCOMPARE(result.value("task").toObject().value("estimated_minutes").toInt(), 2475);
        QCOMPARE(result.value("task").toObject().value("notes").toString(), QStringLiteral("备注"));
        QCOMPARE(TaskManager::instance()->readTask(id).value.value("persistedCategory").toString(), QStringLiteral("旧科目文本"));
        QCOMPARE(changed.size(), 1);
        QVERIFY(!output(run(Tool::UpdateTask, args)).value("changed").toBool());
        QCOMPARE(changed.size(), 1);
        args.insert("title", "陈旧令牌的改动");
        QCOMPARE(code(run(Tool::UpdateTask, args)), QStringLiteral("STATE_CONFLICT"));
        args = editArgs(id); args.insert("notes", ""); args.insert("estimated_minutes", 0);
        result = output(run(Tool::UpdateTask, args));
        QCOMPARE(result.value("task").toObject().value("notes").toString(), QStringLiteral(""));
        QCOMPARE(result.value("task").toObject().value("estimated_minutes").toInt(), 0);
        args = editArgs(id); args.insert("date", "2026-09-17");
        const int before = changed.size();
        QVERIFY(!output(run(Tool::RescheduleTask, args)).value("changed").toBool());
        QCOMPARE(changed.size(), before);
        args.insert("date", "2026-09-18");
        QVERIFY(output(run(Tool::RescheduleTask, args)).value("changed").toBool());
        QVERIFY(!output(run(Tool::RescheduleTask, args)).value("changed").toBool());
        args = editArgs(id); args.insert("completed", true);
        QVERIFY(output(run(Tool::SetTaskCompleted, args)).value("changed").toBool());
        QVERIFY(!output(run(Tool::SetTaskCompleted, args)).value("changed").toBool());
        QCOMPARE(failed.size(), 0);
    }
    void committedCreationReadFailure()
    {
        auto args = createArgs();
        // 写服务同步发变化信号时关闭数据库，精确注入“已提交、重读失败”。
        const auto connection = connect(TaskManager::instance(), &TaskManager::tasksChanged, this, [] {
            DatabaseManager::instance()->close();
        });
        const auto result = run(Tool::CreateTask, args);
        disconnect(connection);
        QCOMPARE(code(result), QStringLiteral("DATABASE_ERROR"));
        const auto error = QJsonDocument::fromJson(result.value("content").toArray().first().toObject().value("text").toString().toUtf8()).object();
        const int id = error.value("details").toObject().value("created_task_id").toInt(); QVERIFY(id > 0);
        QVERIFY(error.value("details").toObject().value("creation_committed").toBool());
        QVERIFY(!error.value("retryable").toBool());
        QVERIFY(error.value("next_action").toString().contains(QStringLiteral("不要换新键")));
        QCOMPARE(code(run(Tool::CreateTask, args)), QStringLiteral("DATABASE_ERROR"));
        QVERIFY(DatabaseManager::instance()->initialize(data->filePath("test.sqlite")));
        const auto replay = output(run(Tool::CreateTask, args));
        QCOMPARE(replay.value("created_task_id").toInt(), id);
        QVERIFY(replay.value("replayed").toBool());
        QCOMPARE(output(run(Tool::ListTasks, range())).value("count").toInt(), 1);
    }
    void categoriesAndTaskContract()
    {
        const int a = task(), b = task(); QVERIFY(a > 0 && b > a);
        const auto categories = run(Tool::ListCategories);
        QVERIFY(!categories.value("isError").toBool());
        QVERIFY(validateAgainstSchema(output(categories), contract(Tool::ListCategories).outputSchema).ok());
        const auto result = run(Tool::ListTasks, range());
        QVERIFY(!result.value("isError").toBool());
        QCOMPARE(output(result).value("logical_today"), QJsonValue("2026-09-17"));
        const auto tasks = output(result).value("tasks").toArray(); QCOMPARE(tasks.size(), 2);
        QCOMPARE(tasks[0].toObject().value("task_id").toInt(), a); QCOMPARE(tasks[1].toObject().value("task_id").toInt(), b);
        QVERIFY(validateAgainstSchema(output(result), contract(Tool::ListTasks).outputSchema).ok());
        QCOMPARE(QJsonDocument::fromJson(result.value("content").toArray().first().toObject().value("text").toString().toUtf8()).object(), output(result));
    }
    void overflowAndPendingBeforeLimit()
    {
        const int a = task(); QVERIFY(a > 0); QVERIFY(task() > a);
        QCOMPARE(code(run(Tool::ListTasks, range(1))), QStringLiteral("RESULT_LIMIT_EXCEEDED"));
        QObject owner; interactions->setPendingDelete(&owner, a);
        const auto result = run(Tool::ListTasks, range(1)); QVERIFY(!result.value("isError").toBool());
        QCOMPARE(output(result).value("count").toInt(), 1);
        QCOMPARE(code(run(Tool::GetTask, {{"task_id", a}})), QStringLiteral("APP_BUSY"));
        QVERIFY(TaskManager::instance()->readTask(a).ok());
        interactions->end(&owner);
        QVERIFY(!run(Tool::GetTask, {{"task_id", a}}).value("isError").toBool());
        QCOMPARE(code(run(Tool::GetTask, {{"task_id", a + 100}})), QStringLiteral("NOT_FOUND"));
    }
    void latestReadAndOwnerLifetime()
    {
        const int id = task(); QVERIFY(id > 0);
        QObject* owner = new QObject;
        QVERIFY(TaskManager::instance()->updateTask(id, "最新标题", 0, "2026-09-18"));
        const auto latest = interactions->beginEdit(owner, id, "test.edit");
        QCOMPARE(latest.value("title").toString(), QStringLiteral("最新标题"));
        QVERIFY(interactions->refreshBlocked());
        const auto blocked = dispatcher->blocks(); QCOMPARE(blocked.size(), 1); QCOMPARE(blocked.first().source, QStringLiteral("test.edit"));
        delete owner; QVERIFY(!interactions->refreshBlocked());
        QObject live; QVERIFY(interactions->beginDrag(&live, id, "test.drag"));
        interactions->end(&live); interactions->end(&live); QVERIFY(!interactions->refreshBlocked());
        QVERIFY(interactions->beginEdit(&live, id + 999, "test.bad").isEmpty());
        QVERIFY(!interactions->refreshBlocked()); QVERIFY(!interactions->lastError().isEmpty());
    }
    void stateTokenInputs()
    {
        const int id = task(); QVERIFY(id > 0);
        const auto token = [&] { return output(run(Tool::GetTask, {{"task_id", id}})).value("task").toObject().value("state_token").toString(); };
        QString previous = token(); QCOMPARE(previous.size(), 64);
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("UPDATE tasks SET estimated_minutes = 2475 WHERE id = %1").arg(id)));
        QVERIFY(token() != previous); previous = token();
        QCOMPARE(output(run(Tool::GetTask, {{"task_id", id}})).value("task").toObject().value("estimated_minutes").toInt(), 2475);
        QVERIFY(query.exec(QStringLiteral("UPDATE tasks SET display_order = display_order + 1 WHERE id = %1").arg(id)));
        QCOMPARE(token(), previous);
        QVERIFY(query.exec(QStringLiteral("INSERT INTO focus_sessions(task_id,start_time,end_time,duration,mode,pomodoro_completed) "
                                          "VALUES(%1,'2026-09-17T10:00:00','2026-09-17T10:05:00',300,1,1)").arg(id)));
        QCOMPARE(token(), previous);
        session = QUuid::createUuid().toString(QUuid::WithoutBraces); QVERIFY(token() != previous);
    }
    void errorsStayOutOfUi()
    {
        QSignalSpy taskErrors(TaskManager::instance(), &TaskManager::operationFailed);
        QSignalSpy gapErrors(KnowledgeGapService::instance(), &KnowledgeGapService::operationFailed);
        QSignalSpy statErrors(StatisticsService::instance(), &StatisticsService::operationFailed);
        QSignalSpy categoryErrors(CategoryManager::instance(), &CategoryManager::operationFailed);
        DatabaseManager::instance()->close();
        QCOMPARE(code(run(Tool::ListCategories)), QStringLiteral("DATABASE_ERROR"));
        QCOMPARE(code(run(Tool::GetTask, {{"task_id", 1}})), QStringLiteral("DATABASE_ERROR"));
        QCOMPARE(code(run(Tool::ListTasks, range())), QStringLiteral("DATABASE_ERROR"));
        QCOMPARE(code(run(Tool::GetFocusSummary, {{"start_date", "2026-09-17"}, {"end_date", "2026-09-17"}})), QStringLiteral("DATABASE_ERROR"));
        QCOMPARE(code(run(Tool::ListKnowledgeGaps, {{"status", "unresolved"}})), QStringLiteral("DATABASE_ERROR"));
        QCOMPARE(taskErrors.size() + gapErrors.size() + statErrors.size() + categoryErrors.size(), 0);
    }
    void gapFiltersAndContinuation()
    {
        auto* gaps = KnowledgeGapService::instance();
        for (int i = 0; i < 103; ++i) QVERIFY(gaps->captureGap("同名缺口%_", 0, 0) > 0);
        auto result = output(run(Tool::ListKnowledgeGaps, {{"status", "unresolved"}, {"due_state", "unscheduled"}, {"search_text", "%_"}, {"limit", 100}}));
        QCOMPARE(result.value("gaps").toArray().size(), 100); QVERIFY(result.value("has_more").toBool());
        const int after = result.value("next_after_id").toInt(); QVERIFY(after > 0);
        result = output(run(Tool::ListKnowledgeGaps, {{"status", "unresolved"}, {"due_state", "unscheduled"}, {"after_id", after}}));
        QCOMPARE(result.value("gaps").toArray().size(), 3); QVERIFY(!result.value("has_more").toBool()); QVERIFY(result.value("next_after_id").isNull());
        const int scheduled = gaps->addGap("到期条目", 0, "详情", 1, "2026-09-17", 0); QVERIFY(scheduled > 0);
        result = output(run(Tool::ListKnowledgeGaps, {{"status", "unresolved"}, {"due_from", "2026-09-17"}, {"due_to", "2026-09-17"}}));
        QCOMPARE(result.value("gaps").toArray().size(), 1); QCOMPARE(result.value("gaps").toArray()[0].toObject().value("gap_id").toInt(), scheduled);
        QVERIFY(!result.value("gaps").toArray()[0].toObject().contains("detail"));
        QCOMPARE(code(run(Tool::ListKnowledgeGaps, {{"status", "all"}, {"category_id", 999999}})), QStringLiteral("NOT_FOUND"));
    }
    void focusRulesAndPartialDay()
    {
        const int id = task(); QVERIFY(id > 0);
        QSqlQuery query(DatabaseManager::instance()->database());
        // 02:00 仍属于前一逻辑日；179 秒与未结束记录都不进入统计，自由计时不折算番茄。
        QVERIFY(query.exec(QStringLiteral("INSERT INTO focus_sessions(task_id,start_time,end_time,duration,mode,pomodoro_completed) VALUES "
            "(%1,'2026-09-18T02:00:00','2026-09-18T02:05:01',301,1,1),"
            "(%1,'2026-09-17T12:00:00','2026-09-17T12:06:01',361,0,0),"
            "(%1,'2026-09-17T13:00:00','2026-09-17T13:02:59',179,1,1),"
            "(%1,'2026-09-17T14:00:00',NULL,600,1,0)").arg(id)));
        const auto result = run(Tool::GetFocusSummary, {{"start_date", "2026-09-16"}, {"end_date", "2026-09-18"}});
        QVERIFY(!result.value("isError").toBool());
        const auto summary = output(result); QCOMPARE(summary.value("total_focus_seconds").toInt(), 662);
        QCOMPARE(summary.value("total_focus_minutes").toInt(), 11); QCOMPARE(summary.value("valid_pomodoros").toInt(), 1);
        QVERIFY(summary.value("is_partial").toBool());
        const auto days = summary.value("days").toArray(); QCOMPARE(days.size(), 3);
        QCOMPARE(days[0].toObject().value("day_state"), QJsonValue("complete"));
        QCOMPARE(days[1].toObject().value("day_state"), QJsonValue("in_progress"));
        QCOMPARE(days[2].toObject().value("day_state"), QJsonValue("future"));
        QCOMPARE(StatisticsService::instance()->getDayStats(QDate(2026, 9, 17)).value("totalDuration").toInt(), 662);
        QCOMPARE(StatisticsService::instance()->getCategoryStats(QDate(2026,9,17),QDate(2026,9,17)).value("totalDuration").toInt(), 662);
    }
};
QTEST_GUILESS_MAIN(McpServiceTests)
#include "McpServiceTests.moc"
