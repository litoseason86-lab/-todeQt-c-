#pragma once
#include <QObject>
#include <QDateTime>
#include <functional>
#include "McpCreateRegistry.h"
#include "../common/McpContracts.h"
#include "../../services/ServiceReadResult.h"

class TaskManager;
class CategoryManager;
class StatisticsService;
class KnowledgeGapService;
class TaskInteractionCoordinator;

// 这里只适配契约与服务结果；权限由控制器每次调用检查，SQL 留在业务服务。
class McpToolDispatcher : public QObject
{
    Q_OBJECT
public:
    struct Context { QString sessionId; QDateTime now; int dayStartHour; };
    using ContextProvider = std::function<Context()>;
    McpToolDispatcher(TaskManager* tasks, CategoryManager* categories, StatisticsService* statistics,
                      KnowledgeGapService* gaps, TaskInteractionCoordinator* interactions,
                      ContextProvider context, QObject* parent = nullptr);
    QJsonObject dispatch(McpContracts::Tool tool, const QJsonObject& arguments);
    QList<McpContracts::BusyBlock> blocks() const;
    void resetCreationSession() { m_created.clear(); }
private:
    McpCreateRegistry m_created;
    QJsonObject writeTask(McpContracts::Tool tool, const QJsonObject& args, const Context& context);
    QJsonObject createdResult(qint64 id, bool replayed, const Context& context);
    QJsonObject taskOutput(const QVariantMap& row, const QString& session) const;
    QJsonObject failure(ServiceReadError error) const;
    QJsonObject success(McpContracts::Tool tool, const QJsonObject& output) const;
    TaskManager* m_tasks;
    CategoryManager* m_categories;
    StatisticsService* m_statistics;
    KnowledgeGapService* m_gaps;
    TaskInteractionCoordinator* m_interactions;
    ContextProvider m_context;
};
