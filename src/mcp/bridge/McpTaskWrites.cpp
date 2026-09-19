#include "McpToolDispatcher.h"
#include "../../services/TaskManager.h"
#include "../../services/CategoryManager.h"
#include "../../services/TaskInteractionCoordinator.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QUuid>
#include <QJsonArray>
#include <limits>

using namespace McpContracts;

QJsonObject McpToolDispatcher::createdResult(qint64 id, bool replayed, const Context& context)
{
    if (id <= 0) return makeToolErrorResult(makeError(ErrorCode::OutcomeUnknown, QStringLiteral("创建已提交但编号不可用，请查询核实，勿换键重建")));
    QJsonValue task(QJsonValue::Null);
    QString state = QStringLiteral("pending_delete");
    if (!m_interactions->pendingTaskIds().contains(int(id))) {
        const auto current = m_tasks->readTask(int(id));
        if (current.error == ServiceReadError::NotFound) state = QStringLiteral("deleted");
        else if (!current.ok()) {
            auto error = makeError(ErrorCode::DatabaseError, QStringLiteral("任务已创建，读取当前数据失败"),
                                  {{"created_task_id", id}, {"creation_committed", true}});
            error.insert("next_action", QStringLiteral("确认数据库可用后，用原键重试以取回数据，不要换新键"));
            return makeToolErrorResult(error);
        } else {
            state = QStringLiteral("present");
            task = taskOutput(current.value, context.sessionId);
        }
    }
    const auto result = success(Tool::CreateTask, {{"created_task_id", id}, {"current_state", state}, {"replayed", replayed}, {"task", task}});
    if (!result.value("isError").toBool()) return result;
    // 原任务后来被导入超大内容时，重放也可能超出预算；仍须说明原创建已提交。
    auto error = QJsonDocument::fromJson(result.value("content").toArray().first().toObject().value("text").toString().toUtf8()).object();
    error.insert("details", QJsonObject{{"created_task_id", id}, {"creation_committed", true}});
    error.insert("next_action", QStringLiteral("原创建已成功，请核实原任务内容；需要重试时沿用原键，不要换新键"));
    return makeToolErrorResult(error);
}

QJsonObject McpToolDispatcher::writeTask(Tool tool, const QJsonObject& args, const Context& context)
{
    // 控制器是权限入口；此处再次核对会话，防止内部误装配绕过并发边界。
    if (args.value("app_session_id").toString() != context.sessionId)
        return makeToolErrorResult(makeError(ErrorCode::SessionExpired, QStringLiteral("应用会话已改变")));
    m_created.beginSession(context.sessionId);
    QByteArray key, digest;
    if (tool == Tool::CreateTask) {
        key = QUuid(args.value("idempotency_key").toString()).toRfc4122();
        auto normalized = args;
        normalized.remove("app_session_id");
        normalized.remove("idempotency_key");
        normalized.insert("title", args.value("title").toString().trimmed());
        digest = QCryptographicHash::hash(QJsonDocument(normalized).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256);
        const auto found = m_created.find(key);
        // 已提交的重放只读取原编号；用户正在编辑不应阻止模型核实创建结果。
        if (found.has_value()) {
            if (!found->matches(digest))
                return makeToolErrorResult(makeError(ErrorCode::IdempotencyConflict, QStringLiteral("该创建键已经用于不同参数")));
            return createdResult(found->taskId, true, context);
        }
    }
    QList<BusyBlock> blocked;
    for (const auto& block : blocks()) {
        if (block.reason != BusyReason::PendingDelete || (contract(tool).targetsExistingTask && block.taskId == args.value("task_id").toInt()))
            blocked.append(block);
    }
    if (!blocked.isEmpty()) return makeToolErrorResult(makeBusyError(blocked));
    QString requestedCategoryName;
    if (args.contains("category_id") && args.value("category_id").toInt() > 0) {
        const auto category = m_categories->readCategory(args.value("category_id").toInt());
        if (!category.ok()) return failure(category.error);
        requestedCategoryName = category.value.value("name").toString();
    }
    if (tool == Tool::CreateTask) {
        if (m_created.size() >= kCreateRegistryCapacity)
            return makeToolErrorResult(makeError(ErrorCode::WriteCapacityReached, QStringLiteral("本次会话创建登记已满")));
        // 正常字段受输入上限约束，历史科目名也计入完整响应预算，必须在提交之前拒绝超限。
        const QVariantMap previewRow{{"id", kMaxEntityId}, {"title", args.value("title").toString().trimmed()},
            {"date", QDate::fromString(args.value("date").toString(), Qt::ISODate)}, {"categoryId", args.value("category_id").toInt()},
            {"categoryName", requestedCategoryName}, {"estimatedMinutes", args.value("estimated_minutes").toInt()},
            {"notes", args.value("notes").toString()}, {"displayOrder", std::numeric_limits<int>::max()}};
        const auto preview = success(tool, {{"created_task_id", kMaxEntityId}, {"current_state", "present"},
            {"replayed", false}, {"task", taskOutput(previewRow, context.sessionId)}});
        if (preview.value("isError").toBool()) return preview;
        // 先分配登记槽，失败即移除；只保存定长摘要和编号，不缓存用户文本。
        if (!m_created.reserve(key, digest))
            return makeToolErrorResult(makeError(ErrorCode::WriteCapacityReached, QStringLiteral("无法预留创建登记")));
        bool committed = false;
        const int id = m_tasks->createTaskWithOutcome(args.value("title").toString(), args.value("date").toString(),
            args.value("category_id").toInt(), args.value("estimated_minutes").toInt(), args.value("notes").toString(), &committed);
        if (id <= 0) {
            if (!committed) m_created.remove(key);
            return committed ? makeToolErrorResult(makeError(ErrorCode::OutcomeUnknown, QStringLiteral("任务已提交但无法取得编号，请先查询核实")))
                             : failure(ServiceReadError::Database);
        }
        m_created.commit(key, id);
        return createdResult(id, false, context);
    }
    const int id = args.value("task_id").toInt();
    const auto current = m_tasks->readTask(id);
    if (!current.ok()) return failure(current.error);
    auto task = taskOutput(current.value, context.sessionId);
    bool changed = false;
    auto target = task;
    if (tool == Tool::UpdateTask) {
        for (const auto& field : {"title", "category_id", "estimated_minutes", "notes"}) {
            if (!args.contains(field)) continue;
            const QJsonValue value = QString::fromLatin1(field) == "title" ? QJsonValue(args.value(field).toString().trimmed()) : args.value(field);
            changed = changed || task.value(field) != value;
            target.insert(field, value);
        }
    } else {
        const QString field = tool == Tool::RescheduleTask ? QStringLiteral("date") : QStringLiteral("completed");
        changed = task.value(field) != args.value(field);
        target.insert(field, args.value(field));
    }
    if (tool == Tool::UpdateTask && args.contains("category_id")) target.insert("category_name", requestedCategoryName);
    if (tool == Tool::UpdateTask && args.contains("category_id") && args.value("category_id").toInt() == 0
        && !current.value.value("persistedCategory").toString().isEmpty()) changed = true;
    if (!changed) return success(tool, {{"changed", false}, {"task", task}});
    if (task.value("state_token") != args.value("expected_state_token"))
        return makeToolErrorResult(makeError(ErrorCode::StateConflict, QStringLiteral("任务已被修改，请重新读取后决定")));
    // 旧任务可能含较长历史文本；完整成功响应先校验预算，不能写完才发现编号/数据发不出去。
    const auto preview = success(tool, {{"changed", true}, {"task", target}});
    if (preview.value("isError").toBool()) return preview;
    bool ok = false;
    if (tool == Tool::UpdateTask) {
        // 缺省预计和备注必须传服务层“不改”哨兵，避免把旧版 2475 分钟夹成 1440。
        ok = m_tasks->updateTaskFields(id, target.value("title").toString(), target.value("category_id").toInt(), target.value("date").toString(),
            args.contains("estimated_minutes") ? args.value("estimated_minutes").toInt() : -1,
            args.contains("notes") ? args.value("notes").toString(QStringLiteral("")) : QString(), !args.contains("category_id"));
    } else if (tool == Tool::RescheduleTask) ok = m_tasks->moveTaskToDate(id, args.value("date").toString());
    else ok = m_tasks->setTaskCompleted(id, args.value("completed").toBool());
    if (!ok) return failure(ServiceReadError::Database);
    const auto result = m_tasks->readTask(id);
    return result.ok() ? success(tool, {{"changed", true}, {"task", taskOutput(result.value, context.sessionId)}}) : failure(result.error);
}
