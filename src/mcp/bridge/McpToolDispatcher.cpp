#include "McpToolDispatcher.h"

#include <limits>

#include "../../services/KnowledgeGapService.h"
#include "../../services/TaskManager.h"
#include "../common/McpContracts.h"

// 辅助程序不能包含业务服务头文件，共享契约里的上限只能另存一份。这个文件只编入主应用，
// 在这里逐项核对：服务改了上限而契约没跟上，编译当场失败，
// 不会出现“清单 schema 放行、服务执行拒绝”或反过来的分叉。
static_assert(McpContracts::kTaskTitleMaxLength == TaskManager::kMaxTitleLength,
              "McpContracts 的任务标题上限与 TaskManager 不一致");
static_assert(McpContracts::kTaskNotesMaxLength == TaskManager::kMaxNotesLength,
              "McpContracts 的任务备注上限与 TaskManager 不一致");
static_assert(McpContracts::kTaskEstimatedMinutesMax == TaskManager::kMaxEstimatedMinutes,
              "McpContracts 的预计用时上限与 TaskManager 不一致");
static_assert(McpContracts::kGapPriorityMin == KnowledgeGapService::kMinPriority
                  && McpContracts::kGapPriorityMax == KnowledgeGapService::kMaxPriority,
              "McpContracts 的知识缺口优先级区间与 KnowledgeGapService 不一致");
// 现有服务的编号参数都是 int，对外编号上限必须与之一致，否则大编号会在转换时被截断。
static_assert(McpContracts::kMaxEntityId == std::numeric_limits<int>::max(),
              "McpContracts 的编号上限与服务层 int 编号不一致");

#include "../../services/CategoryManager.h"
#include "../../services/StatisticsService.h"
#include "../../services/TaskInteractionCoordinator.h"
#include "../../services/LogicalDay.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonArray>

using namespace McpContracts;

McpToolDispatcher::McpToolDispatcher(TaskManager* tasks, CategoryManager* categories, StatisticsService* statistics,
                                   KnowledgeGapService* gaps, TaskInteractionCoordinator* interactions,
                                   ContextProvider context, QObject* parent)
    : QObject(parent), m_tasks(tasks), m_categories(categories), m_statistics(statistics), m_gaps(gaps),
      m_interactions(interactions), m_context(std::move(context)) {}

QList<BusyBlock> McpToolDispatcher::blocks() const
{
    QList<BusyBlock> result;
    for (const auto& entry : m_interactions->entries()) {
        const auto reason = entry.kind == TaskInteractionCoordinator::Editing ? BusyReason::Editing
            : entry.kind == TaskInteractionCoordinator::Dragging ? BusyReason::Dragging : BusyReason::PendingDelete;
        result.append({reason, entry.source, entry.taskId});
    }
    return result;
}
namespace {
// 编号与汉字之间留一个空格：“任务 #12 不存在”比“任务 #12不存在”好读。
QString joinPhrase(const QString& subject, const QString& predicate)
{
    const bool endsWithAscii = !subject.isEmpty() && subject.back().unicode() < 0x80 && subject.back().isLetterOrNumber();
    return endsWithAscii ? subject + QLatin1Char(' ') + predicate : subject + predicate;
}
}
QJsonObject McpToolDispatcher::failure(ServiceReadError error, const QString& subject) const
{
    switch (error) {
    case ServiceReadError::InvalidArgument:
        return makeToolErrorResult(makeError(ErrorCode::ValidationError, joinPhrase(subject, QStringLiteral("的查询参数不符合要求"))));
    case ServiceReadError::NotFound:
        return makeToolErrorResult(makeError(ErrorCode::NotFound, joinPhrase(subject, QStringLiteral("不存在"))));
    case ServiceReadError::LimitExceeded:
        return makeToolErrorResult(makeError(ErrorCode::ResultLimitExceeded, joinPhrase(subject, QStringLiteral("超过返回上限"))));
    case ServiceReadError::None:
    case ServiceReadError::Database:
        break;
    }
    return makeToolErrorResult(makeError(ErrorCode::DatabaseError, QStringLiteral("读取") + joinPhrase(subject, QStringLiteral("失败"))));
}
QJsonObject McpToolDispatcher::success(Tool tool, const QJsonObject& output) const
{
    const auto validation = validateAgainstSchema(output, contract(tool).outputSchema);
    if (!validation.ok()) {
        // 库里的数据本身超出了对外约定（例如旧备份或手工改库带回的非法日期）。整条拒绝而不是悄悄丢行，
        // 但要指出是哪几个字段：笼统的“读取失败”会让人以为数据库坏了，也没法去修。
        QJsonArray fields;
        for (const auto& fieldError : validation.errors) {
            if (!fields.contains(fieldError.field) && fields.size() < 5) fields.append(fieldError.field);
        }
        QStringList names;
        for (const auto& field : fields) names.append(field.toString());
        QJsonObject error = makeError(ErrorCode::DatabaseError,
            QStringLiteral("库中数据超出工具约定，无法按约定返回（%1）").arg(names.join(QStringLiteral("、"))),
            {{"reason", "stored_data_out_of_contract"}, {"fields", fields}});
        error.insert(QStringLiteral("next_action"),
                     QStringLiteral("数据库本身可用：请用户在番茄Todo 中检查并修正这些数据，不要反复重试同一查询。"));
        return makeToolErrorResult(error);
    }
    const auto result = makeToolSuccessResult(output);
    // 包含 JSON 文本副本；为外部编号和内部信封预留最坏 64 KiB，避免临界响应在转发时才超限。
    if (QJsonDocument(result).toJson(QJsonDocument::Compact).size() > kMaxResponseBytes - kMaxRequestBytes)
        return failure(ServiceReadError::LimitExceeded, QStringLiteral("这次结果"));
    return result;
}
QJsonObject McpToolDispatcher::taskOutput(const QVariantMap& row, const QString& session) const
{
    // 负的预计用时只可能来自旧备份或手工改库；服务层的写入口径本来就把负数当“未设置”，
    // 对外同样报 0，不能让一行旧数据违反输出约定、拖垮整页查询。
    QJsonObject task{{"task_id", row.value("id").toInt()}, {"title", row.value("title").toString()},
        {"date", row.value("date").toDate().toString(Qt::ISODate)}, {"completed", row.value("completed").toBool()},
        {"category_id", row.value("categoryId").toInt()}, {"category_name", row.value("categoryName").toString()},
        {"estimated_minutes", qMax(0, row.value("estimatedMinutes").toInt())}, {"notes", row.value("notes").toString()},
        {"display_order", row.value("displayOrder").toInt()}, {"focused_seconds", row.value("focusedSeconds").toLongLong()},
        {"focused_minutes", row.value("focusedMinutes").toLongLong()}, {"valid_pomodoros", row.value("actualPomodoros").toInt()}};
    // 令牌只覆盖可编辑持久字段；实际投入随计时增长不制造编辑冲突，预计分钟必须参与。
    const QJsonArray fields{session, task.value("task_id"), task.value("title"), task.value("date"), task.value("completed"),
        task.value("category_id"), row.value("persistedCategory").toString(), task.value("estimated_minutes"), task.value("notes")};
    task.insert("state_token", QString::fromLatin1(QCryptographicHash::hash(QJsonDocument(fields).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256).toHex()));
    return task;
}
QJsonObject McpToolDispatcher::dispatch(Tool tool, const QJsonObject& arguments)
{
    const auto validation = validateToolArguments(tool, arguments);
    if (!validation.ok()) return makeToolErrorResult(makeValidationError(validation));
    const auto args = applySchemaDefaults(tool, arguments);
    const auto context = m_context();
    if (contract(tool).access == ToolAccess::Write) return writeTask(tool, args, context);
    QList<BusyBlock> blocked;
    for (const auto& block : blocks()) {
        if (contract(tool).targetsExistingTask && block.reason == BusyReason::PendingDelete
            && block.taskId == args.value("task_id").toInt()) blocked.append(block);
    }
    if (!blocked.isEmpty()) return makeToolErrorResult(makeBusyError(blocked));
    const QDate today = LogicalDay::dateOf(context.now, context.dayStartHour);
    const QDate from = QDate::fromString(args.value("start_date").toString(), Qt::ISODate);
    const QDate to = QDate::fromString(args.value("end_date").toString(), Qt::ISODate);
    if (tool == Tool::ListCategories) {
        const auto result = m_categories->readCategories();
        if (!result.ok()) return failure(result.error, QStringLiteral("科目列表"));
        QJsonArray categories;
        for (const auto& value : result.value) {
            const auto row = value.toMap();
            categories.append(QJsonObject{{"category_id", row.value("id").toInt()}, {"name", row.value("name").toString()},
                                          {"color", row.value("color").toString()}, {"is_preset", row.value("isPreset").toBool()}});
        }
        return success(tool, {{"categories", categories}});
    }
    if (tool == Tool::GetTask) {
        const int id = args.value("task_id").toInt();
        const auto result = m_tasks->readTask(id);
        return result.ok() ? success(tool, {{"task", taskOutput(result.value, context.sessionId)}})
                           : failure(result.error, QStringLiteral("任务 #%1").arg(id));
    }
    if (tool == Tool::ListTasks) {
        const QString completion = args.value("completion_state").toString();
        const auto result = m_tasks->readTasks(from, to, completion == "any" ? -1 : completion == "completed" ? 1 : 0,
                                             args.value("limit").toInt(), m_interactions->pendingTaskIds());
        if (!result.ok()) return failure(result.error, QStringLiteral("该范围内的任务"));
        QJsonArray tasks;
        for (const auto& value : result.value) tasks.append(taskOutput(value.toMap(), context.sessionId));
        return success(tool, {{"start_date", from.toString(Qt::ISODate)}, {"end_date", to.toString(Qt::ISODate)},
                              {"completion_state", completion}, {"logical_today", today.toString(Qt::ISODate)},
                              {"count", tasks.size()}, {"tasks", tasks}});
    }
    if (tool == Tool::GetFocusSummary) {
        const auto result = m_statistics->readFocusSummary(from, to, context.dayStartHour);
        if (!result.ok()) return failure(result.error, QStringLiteral("专注统计"));
        QJsonArray days, categories;
        for (const auto& value : result.value.value("days").toList()) {
            const auto row = value.toMap();
            const QDate date = QDate::fromString(row.value("date").toString(), Qt::ISODate);
            const qint64 seconds = row.value("seconds").toLongLong();
            days.append(QJsonObject{{"date", date.toString(Qt::ISODate)}, {"day_state", date < today ? "complete" : date == today ? "in_progress" : "future"},
                                    {"focus_seconds", seconds}, {"focus_minutes", seconds / 60}, {"valid_pomodoros", row.value("pomodoros").toLongLong()}});
        }
        for (const auto& value : result.value.value("categories").toList()) {
            const auto row = value.toMap();
            const qint64 seconds = row.value("seconds").toLongLong();
            categories.append(QJsonObject{{"category_id", row.value("id").toInt()}, {"category_name", row.value("name").toString()},
                                          {"focus_seconds", seconds}, {"focus_minutes", seconds / 60}});
        }
        const qint64 seconds = result.value.value("seconds").toLongLong();
        return success(tool, {{"start_date", from.toString(Qt::ISODate)}, {"end_date", to.toString(Qt::ISODate)},
            {"logical_today", today.toString(Qt::ISODate)}, {"as_of", context.now.toOffsetFromUtc(context.now.offsetFromUtc()).toString(Qt::ISODateWithMs)},
            {"is_partial", to >= today}, {"total_focus_seconds", seconds}, {"total_focus_minutes", seconds / 60},
            {"valid_pomodoros", result.value.value("pomodoros").toLongLong()}, {"days", days}, {"categories", categories}});
    }
    if (tool == Tool::ListKnowledgeGaps) {
        KnowledgeGapService::ReadFilter filter;
        const QString status = args.value("status").toString();
        filter.status = status == "all" ? -1 : status == "unresolved" ? -2 : status == "open" ? 0 : status == "scheduled" ? 1 : 2;
        filter.categoryId = args.value("category_id").toInt();
        if (filter.categoryId > 0) {
            const auto category = m_categories->readCategory(filter.categoryId);
            if (!category.ok()) return failure(category.error, QStringLiteral("科目 #%1").arg(filter.categoryId));
        }
        filter.searchText = args.value("search_text").toString();
        filter.dueState = args.value("due_state").toString();
        filter.dueFrom = QDate::fromString(args.value("due_from").toString(), Qt::ISODate);
        filter.dueTo = QDate::fromString(args.value("due_to").toString(), Qt::ISODate);
        filter.afterId = args.value("after_id").toInt();
        filter.limit = args.value("limit").toInt();
        const auto result = m_gaps->readGaps(filter, today);
        if (!result.ok()) return failure(result.error, QStringLiteral("知识缺口"));
        QJsonArray gaps;
        for (int i = 0; i < qMin(filter.limit, int(result.value.size())); ++i) {
            const auto row = result.value.at(i).toMap();
            const QString due = row.value("dueDate").toString();
            const int linked = row.value("linkedTaskId").toInt();
            gaps.append(QJsonObject{{"gap_id", row.value("id").toInt()}, {"title", row.value("title").toString()},
                {"status", row.value("status").toInt() == 0 ? "open" : row.value("status").toInt() == 1 ? "scheduled" : "resolved"},
                {"priority", row.value("priority").toInt()}, {"category_id", row.value("categoryId").toInt()},
                {"category_name", row.value("categoryName").toString()}, {"due_date", due.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(due)},
                {"linked_task_id", linked > 0 ? QJsonValue(linked) : QJsonValue(QJsonValue::Null)}, {"linked_task_open", row.value("linkedTaskOpen").toBool()}});
        }
        const bool more = result.value.size() > filter.limit;
        return success(tool, {{"status", status}, {"due_state", filter.dueState}, {"logical_today", today.toString(Qt::ISODate)},
                              {"has_more", more}, {"next_after_id", more ? gaps.last().toObject().value("gap_id") : QJsonValue(QJsonValue::Null)}, {"gaps", gaps}});
    }
    return makeToolErrorResult(makeError(ErrorCode::AppUnavailable, QStringLiteral("状态查询由接入控制器处理")));
}
