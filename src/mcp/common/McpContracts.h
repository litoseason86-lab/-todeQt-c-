#ifndef MCPCONTRACTS_H
#define MCPCONTRACTS_H

#include <QByteArray>
#include <QDate>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QString>
#include <QStringList>
#include <QtGlobal>

#include <optional>

// 外部 AI 接入（MCP）的共享契约，辅助程序与主应用各编入一份（方案见 plans/047）。
//
// 工具清单、参数 schema、参数校验、错误码与重试语义只在这里定义一次：
// 辅助程序用它回答 tools/list，主应用用同一份定义校验真实调用。两边各写一套规则，
// 就会出现“清单上声明了、执行时却不校验”或反过来的分叉。
//
// 这里只允许纯计算：不访问数据库、不读写文件、不依赖业务单例、SQL 或 QML。
namespace McpContracts {

// —— 协议版本 ——

// 首选版本排第一。客户端请求其中之一就原样返回；请求其他版本时按 MCP 协商规则返回首选版本，
// 由客户端决定是否继续——不能回显一个我们并未实现的版本。
QStringList supportedProtocolVersions();
QString preferredProtocolVersion();
QString negotiateProtocolVersion(const QString& requestedVersion);

// 辅助程序与主应用之间的私有协议版本。它不是标准 MCP transport，版本不一致时明确提示
// 重启主应用或客户端（部署后旧进程可能仍在运行），不尝试兼容。
constexpr int kBridgeProtocolVersion = 1;

// —— 资源与查询上限 ——

constexpr qint64 kMaxRequestBytes = 64 * 1024;
// 按完整序列化消息计算，structuredContent 与文本里的同一份 JSON 都算在内。
constexpr qint64 kMaxResponseBytes = 1024 * 1024;
constexpr int kMaxConnections = 8;
constexpr int kMaxQueuedRequestsPerConnection = 16;
constexpr int kConnectTimeoutMs = 2000;
constexpr int kHandshakeTimeoutMs = 5000;
constexpr int kToolTimeoutMs = 10000;

constexpr int kDefaultListLimit = 50;
constexpr int kMaxListLimit = 100;
// 任务列表与专注统计的日期区间上限（含首尾的逻辑日数）。
constexpr int kMaxDateRangeDays = 31;
// 每个应用会话最多登记的成功创建数，满了只拒绝新的创建，不驱逐旧记录。
constexpr int kCreateRegistryCapacity = 10000;

// 现有服务的编号参数是 int，对外的编号上限与之对齐。
constexpr qint64 kMaxEntityId = 2147483647;

// 与 TaskManager 的同名上限相同。辅助程序不能包含业务服务头文件，所以这里另存一份，
// 由只编入主应用的 McpToolDispatcher.cpp 用 static_assert 核对，两边改漏一处就编译失败。
// 注意口径：JSON Schema 的长度按 Unicode 码点计，TaskManager 按 UTF-16 单元计；
// schema 保持标准口径，共享语义校验额外检查 UTF-16 上限，保证调用服务前返回参数错误。
constexpr int kTaskTitleMaxLength = 100;
constexpr int kTaskNotesMaxLength = 2000;
constexpr int kTaskEstimatedMinutesMax = 24 * 60;
// 与 AppSettings::normalizeDayStartHour 的合法区间一致。
constexpr int kDayStartHourMin = 0;
constexpr int kDayStartHourMax = 6;
// 与 KnowledgeGapService 的优先级区间一致：0 低、1 中（默认）、2 高。
constexpr int kGapPriorityMin = 0;
constexpr int kGapPriorityMax = 2;
constexpr int kSearchTextMaxLength = 100;

// —— 工具 ——

enum class Tool {
    GetStatus,
    ListCategories,
    ListTasks,
    GetTask,
    GetFocusSummary,
    ListKnowledgeGaps,
    CreateTask,
    UpdateTask,
    RescheduleTask,
    SetTaskCompleted
};

enum class ToolAccess {
    Read,
    // 需要用户在设置中开启任务写入；主应用每次实际执行前重查，不信任清单或辅助程序的判断。
    Write
};

struct ToolContract
{
    Tool tool = Tool::GetStatus;
    QString name;
    QString title;
    QString description;
    ToolAccess access = ToolAccess::Read;
    // 除状态查询外都需要连上已开启接入的主应用；状态查询离线时如实报告“未连接”。
    bool requiresAppConnection = true;
    // 写入必须带应用会话编号：会话在启动、恢复开始、关闭接入时轮换，旧请求据此失效。
    bool requiresSession = false;
    // 只有创建任务需要幂等键，另外三个写工具按目标状态重试。
    bool requiresIdempotencyKey = false;
    // 修改已有任务必须带最近读取到的状态令牌。
    bool requiresStateToken = false;
    // 以某条已有任务为目标：该任务处于撤销删除窗口时返回 APP_BUSY。
    bool targetsExistingTask = false;
    QJsonObject inputSchema;
    QJsonObject outputSchema;
};

// 固定的 10 个工具。清单不随权限或主应用是否在线变化：未开写权限时写工具照常公布，
// 调用时返回 PERMISSION_DENIED。
const QList<ToolContract>& toolContracts();
const ToolContract& contract(Tool tool);
const ToolContract* findTool(const QString& name);
QString toolName(Tool tool);
// tools/list 结果里的 tools 数组。
QJsonArray toolListJson();

// 输入/输出 schema 允许使用的关键字：draft-07 与 2020-12 共有，另加两个注解关键字。
// 不写 $schema；不用 format（各校验器实现不一）。
QStringList allowedSchemaKeywords();

// —— 结果分支里的枚举值 ——

enum class CreateState { Present, Deleted, PendingDelete };
QString createStateName(CreateState state);

enum class DayState { Complete, InProgress, Future };
QString dayStateName(DayState state);

// 状态查询在未连接时说明原因。endpoint_unreachable 同时覆盖“应用没启动”和“接入没开启”：
// 辅助程序无法区分两者，也不能猜。
enum class UnavailableReason {
    EndpointUnreachable,
    PathInvalid,
    BridgeVersionMismatch,
    AuthenticationFailed,
    HandshakeFailed
};
QString unavailableReasonName(UnavailableReason reason);

// —— 错误契约 ——

enum class ErrorCode {
    AppUnavailable,
    McpDisabled,
    PermissionDenied,
    AppBusy,
    NotFound,
    ValidationError,
    StateConflict,
    ResultLimitExceeded,
    SessionExpired,
    IdempotencyConflict,
    WriteCapacityReached,
    DatabaseError,
    OutcomeUnknown,
    IpcPathInvalid
};

QList<ErrorCode> allErrorCodes();
QString errorCodeName(ErrorCode code);
// retryable 的含义是“客户端可以不改请求、不等外部状态确认、不需要用户操作就自动重发”。
// 首版不给任何错误这种许可，全部为 false；调用点不能自行改判。
bool errorRetryable(ErrorCode code);
QString errorNextAction(ErrorCode code);

enum class BusyReason { Editing, Dragging, PendingDelete, BackupRestore, ShuttingDown };

// 阻断的影响范围：all_data 连读取也暂停（恢复、退出），all_writes 只挡新写入，
// task 只影响某一条任务（撤销删除窗口中的任务）。
enum class BlockScope { AllData, AllWrites, Task };

QList<BusyReason> allBusyReasons();
QString busyReasonName(BusyReason reason);
BlockScope busyReasonScope(BusyReason reason);
QString blockScopeName(BlockScope scope);
bool busyReasonRetryable(BusyReason reason);
QString busyReasonNextAction(BusyReason reason);

struct BusyBlock
{
    BusyReason reason = BusyReason::Editing;
    // 稳定的来源标识，例如 "today.edit_dialog"；不含对象地址或凭据。
    QString source;
    // 0 表示不针对单条任务。
    qint64 taskId = 0;
};

struct FieldError
{
    // 出错字段名，嵌套时用 "/" 连接；空串表示整个参数对象。
    QString field;
    // 稳定原因标识，例如 unknown_field、null_not_allowed、invalid_date。
    QString reason;
    QString message;
};

struct ValidationResult
{
    QList<FieldError> errors;

    bool ok() const { return errors.isEmpty(); }
};

// 错误对象固定为 {code, message, retryable, next_action, details?}。
QJsonObject makeError(ErrorCode code, const QString& message,
                      const QJsonObject& details = QJsonObject());
QJsonObject makeValidationError(const ValidationResult& result);
// 多个阻断原因全部列出，每项带范围、来源、任务编号与各自的下一步。
QJsonObject makeBusyError(const QList<BusyBlock>& blocks);
// 任务已经提交、只是读回当前数据失败：不能描述成创建失败，否则模型会换新键再建一条。
QJsonObject makeCommittedCreateReadFailure(qint64 createdTaskId);

// tools/call 的结果封装。成功时 structuredContent 与文本里是同一份完整 JSON——
// 只把 content 交给模型的客户端也能拿到编号、会话与状态令牌。
QJsonObject makeToolSuccessResult(const QJsonObject& structuredContent);
// 失败时只放文本里的错误 JSON，不提供 structuredContent：官方 TS SDK 客户端只要看到
// structuredContent 就按成功 schema 校验，业务错误会被 schema 错误遮住。
QJsonObject makeToolErrorResult(const QJsonObject& error);

// JSON-RPC 协议层错误码。JSON 解析失败、未知方法或工具、tools/call 请求外壳不合法走这里；
// 工具参数不合法是工具执行错误，走 isError 结果。
namespace JsonRpcError {
constexpr int ParseError = -32700;
constexpr int InvalidRequest = -32600;
constexpr int MethodNotFound = -32601;
constexpr int InvalidParams = -32602;
constexpr int InternalError = -32603;
} // namespace JsonRpcError

// —— 参数校验 ——

// 按 allowedSchemaKeywords() 这组关键字的语义校验。整数与 JSON Schema 一致：
// 小数部分为 0 的数算整数，超出 ±(2^53-1) 精确表示范围的一律拒绝。
ValidationResult validateAgainstSchema(const QJsonValue& value, const QJsonObject& schema);

// 先按工具的输入 schema 校验，通过后再做不依赖数据的语义校验：日历上真实存在的日期、
// 区间先后与长度、到期筛选的组合、修改至少一个字段、UUID v4 复核。
// 需要查数据的校验（科目是否存在、任务是否存在）在主应用执行时进行。
ValidationResult validateToolArguments(Tool tool, const QJsonObject& arguments);

// 把输入 schema 里声明了 default 的缺省字段补齐，其余字段保持缺省。
// 修改任务的字段没有默认值，所以“没提供”在补齐后仍然是“没提供”。
QJsonObject applySchemaDefaults(Tool tool, QJsonObject arguments);

// 严格的 YYYY-MM-DD，并且必须是日历上真实存在的日期。
std::optional<QDate> parseIsoDate(const QString& text);

// UUID v4 的标准 8-4-4-4-12 形式，十六进制大小写均可；版本位必须为 4，变体位为 8/9/a/b。
// 花括号、URN、前后空白、nil 与其他版本都拒绝。成功返回 16 字节，失败返回空。
// 注意：格式合法不代表键是随机生成的，也识别不出模型重复使用同一个示例。
QByteArray parseUuidV4(const QString& text);

} // namespace McpContracts

#endif // MCPCONTRACTS_H
