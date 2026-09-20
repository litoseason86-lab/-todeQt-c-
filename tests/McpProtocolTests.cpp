#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QUuid>
#include <QtTest>

#include "../src/mcp/common/McpContracts.h"
#include "../src/mcp/common/McpPaths.h"

using McpContracts::Tool;

namespace {

// 递归检查 schema 只用了允许的关键字。properties 下面一层是字段名而不是关键字，要跳过。
void collectSchemaViolations(const QJsonObject& schema, const QString& path, QStringList& violations)
{
    const QStringList allowed = McpContracts::allowedSchemaKeywords();
    for (auto it = schema.constBegin(); it != schema.constEnd(); ++it) {
        const QString keyword = it.key();
        const QString here = path + QLatin1Char('/') + keyword;
        if (!allowed.contains(keyword)) {
            violations.append(here + QStringLiteral(" 使用了不允许的关键字"));
            continue;
        }
        if (keyword == QStringLiteral("properties")) {
            const QJsonObject properties = it.value().toObject();
            for (auto property = properties.constBegin(); property != properties.constEnd(); ++property) {
                collectSchemaViolations(property.value().toObject(),
                                        here + QLatin1Char('/') + property.key(), violations);
            }
        } else if (keyword == QStringLiteral("items")) {
            collectSchemaViolations(it.value().toObject(), here, violations);
        } else if (keyword == QStringLiteral("pattern")) {
            // 校验端会整体锚定；只有模式本身已经写成 ^...$ 时，这样做才与客户端的 ECMA 语义一致。
            const QString pattern = it.value().toString();
            if (!pattern.startsWith(QLatin1Char('^')) || !pattern.endsWith(QLatin1Char('$'))) {
                violations.append(here + QStringLiteral(" 没有显式锚定"));
            }
            if (!QRegularExpression(pattern).isValid()) {
                violations.append(here + QStringLiteral(" 不是合法的正则"));
            }
        } else if (keyword == QStringLiteral("required")) {
            const QJsonObject properties = schema.value(QStringLiteral("properties")).toObject();
            for (const QJsonValue& name : it.value().toArray()) {
                if (!properties.contains(name.toString())) {
                    violations.append(here + QStringLiteral(" 引用了不存在的字段 ") + name.toString());
                }
            }
        } else if (keyword == QStringLiteral("default")) {
            // 默认值自己必须满足所在字段的 schema，否则补齐缺省值后反而通不过校验。
            QJsonObject withoutDefault = schema;
            withoutDefault.remove(QStringLiteral("default"));
            if (!McpContracts::validateAgainstSchema(it.value(), withoutDefault).ok()) {
                violations.append(here + QStringLiteral(" 默认值不满足字段 schema"));
            }
        }
    }
}

QString newUuid()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QString sampleStateToken()
{
    return QStringLiteral("0123456789abcdef").repeated(4);
}

QJsonObject validCreateArguments()
{
    return QJsonObject{
        {QStringLiteral("title"), QStringLiteral("背单词")},
        {QStringLiteral("date"), QStringLiteral("2026-09-18")},
        {QStringLiteral("app_session_id"), newUuid()},
        {QStringLiteral("idempotency_key"), newUuid()},
    };
}

QJsonObject updateIdentity()
{
    return QJsonObject{
        {QStringLiteral("task_id"), 57},
        {QStringLiteral("expected_state_token"), sampleStateToken()},
        {QStringLiteral("app_session_id"), newUuid()},
    };
}

QJsonObject with(QJsonObject object, const QString& key, const QJsonValue& value)
{
    object.insert(key, value);
    return object;
}

McpContracts::ValidationResult validate(Tool tool, const QJsonObject& arguments)
{
    return McpContracts::validateToolArguments(tool, arguments);
}

bool hasError(const McpContracts::ValidationResult& result, const QString& field, const QString& reason)
{
    for (const McpContracts::FieldError& error : result.errors) {
        if (error.field == field && error.reason == reason) {
            return true;
        }
    }
    return false;
}

QString describe(const McpContracts::ValidationResult& result)
{
    QStringList parts;
    for (const McpContracts::FieldError& error : result.errors) {
        parts.append(error.field + QLatin1Char(':') + error.reason);
    }
    return parts.join(QStringLiteral(", "));
}

QJsonObject outputProperty(Tool tool, const QString& name)
{
    return McpContracts::contract(tool)
        .outputSchema.value(QStringLiteral("properties"))
        .toObject()
        .value(name)
        .toObject();
}

bool matchesOutput(Tool tool, const QJsonObject& result)
{
    return McpContracts::validateAgainstSchema(result, McpContracts::contract(tool).outputSchema).ok();
}

QJsonObject sampleTask()
{
    return QJsonObject{
        {QStringLiteral("task_id"), 57},
        {QStringLiteral("title"), QStringLiteral("复习线代：特征值")},
        {QStringLiteral("date"), QStringLiteral("2026-09-18")},
        {QStringLiteral("completed"), false},
        {QStringLiteral("category_id"), 0},
        {QStringLiteral("category_name"), QString()},
        // 旧库迁移按“预估番茄数 × 25”回填过分钟数，可能超过现在 1440 的写入上限，输出必须照样合法。
        {QStringLiteral("estimated_minutes"), 2475},
        {QStringLiteral("notes"), QStringLiteral("第一行\n第二行")},
        {QStringLiteral("display_order"), 3},
        {QStringLiteral("focused_seconds"), 1500},
        {QStringLiteral("focused_minutes"), 25},
        {QStringLiteral("valid_pomodoros"), 1},
        {QStringLiteral("state_token"), sampleStateToken()},
    };
}

QJsonObject sampleBusyBlockEntry()
{
    return McpContracts::makeBusyError({{McpContracts::BusyReason::Editing,
                                         QStringLiteral("today.edit_dialog"), 0}})
        .value(QStringLiteral("details"))
        .toObject()
        .value(QStringLiteral("blocks"))
        .toArray()
        .at(0)
        .toObject();
}

QJsonObject firstTextAsJson(const QJsonObject& result)
{
    const QString text = result.value(QStringLiteral("content"))
                             .toArray()
                             .at(0)
                             .toObject()
                             .value(QStringLiteral("text"))
                             .toString();
    return QJsonDocument::fromJson(text.toUtf8()).object();
}

// 根目录为 "/" 加 n 个字母时，socket 路径 "<根>/s" 的字节数是 n + 3。
QString asciiRootForSocketBytes(int socketBytes)
{
    return QLatin1Char('/') + QString(socketBytes - 3, QLatin1Char('a'));
}

} // namespace

class McpProtocolTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();

    // 工具清单
    void catalogHasTenFixedTools();
    void toolNamesFollowMcpNamingRules();
    void writeToolsDeclareSessionAndPermissionRules();
    void schemasUseOnlyPortableKeywords();
    void toolListJsonCarriesBothSchemas();

    // 协议版本
    void protocolVersionNegotiation_data();
    void protocolVersionNegotiation();

    // 参数校验
    void uuidV4Parsing_data();
    void uuidV4Parsing();
    void uuidPatternAgreesWithParser();
    void isoDateParsing_data();
    void isoDateParsing();
    void dateRangeIsInclusiveAndCapped();
    void unknownFieldsNullAndWrongTypesAreRejected();
    void integersRejectFractionsAndOutOfRange();
    void stateTokenMustBeLowercaseHex();
    void updateTaskNeedsAtLeastOneEditableField();
    void knowledgeGapDueFilterCombinations();
    void defaultsFillOnlyDeclaredFields();
    void stringLengthsCountCodePoints();

    // 错误与结果封装
    void noErrorIsAutoRetryable();
    void everyBusyReasonHasScopeAndNextAction();
    void busyErrorListsEveryBlock();
    void committedCreateReadFailureNeverClaimsFailure();
    void validationErrorCarriesFieldErrors();
    void successResultDuplicatesStructuredContentAsText();
    void errorResultHasNoStructuredContent();
    void sampleResultsMatchOutputSchemas();

    // 本机路径
    void pathsStayInsideInjectedRoot();
    void socketPathLimitCountsBytesNotCharacters();
    void invalidRootsAreRejectedWithoutSideEffects();
    void productionPathsRequireApplicationIdentity();
    void pathErrorDetailsOmitFullPath();

private:
    QString m_originalOrganization;
    QString m_originalApplication;
};

void McpProtocolTests::initTestCase()
{
    // 生产路径用例会切换到主应用的身份；打开测试模式，让 AppDataLocation 指向 ~/.qttest，
    // 即使将来有人在这里误建目录，也碰不到用户真实的数据目录。
    QStandardPaths::setTestModeEnabled(true);
    m_originalOrganization = QCoreApplication::organizationName();
    m_originalApplication = QCoreApplication::applicationName();
}

void McpProtocolTests::cleanupTestCase()
{
    QCoreApplication::setOrganizationName(m_originalOrganization);
    QCoreApplication::setApplicationName(m_originalApplication);
    QStandardPaths::setTestModeEnabled(false);
}

void McpProtocolTests::catalogHasTenFixedTools()
{
    const QList<McpContracts::ToolContract>& contracts = McpContracts::toolContracts();
    const QStringList expected{
        QStringLiteral("pomodoro_get_status"),
        QStringLiteral("pomodoro_list_categories"),
        QStringLiteral("pomodoro_list_tasks"),
        QStringLiteral("pomodoro_get_task"),
        QStringLiteral("pomodoro_get_focus_summary"),
        QStringLiteral("pomodoro_list_knowledge_gaps"),
        QStringLiteral("pomodoro_create_task"),
        QStringLiteral("pomodoro_update_task"),
        QStringLiteral("pomodoro_reschedule_task"),
        QStringLiteral("pomodoro_set_task_completed"),
    };
    QStringList actual;
    for (const McpContracts::ToolContract& item : contracts) {
        actual.append(item.name);
        // 按枚举取回的契约必须就是清单里的同一条，findTool 也要找回同一个对象。
        QCOMPARE(McpContracts::contract(item.tool).name, item.name);
        QCOMPARE(McpContracts::toolName(item.tool), item.name);
        QVERIFY(McpContracts::findTool(item.name) == &McpContracts::contract(item.tool));
    }
    QCOMPARE(actual, expected);
    // 首版不开放删除；未知名字返回空，由协议层报“未知工具”。
    QVERIFY(McpContracts::findTool(QStringLiteral("pomodoro_delete_task")) == nullptr);
}

void McpProtocolTests::toolNamesFollowMcpNamingRules()
{
    const QRegularExpression allowed(
        QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_.-]{1,128}")));
    QSet<QString> seen;
    for (const McpContracts::ToolContract& item : McpContracts::toolContracts()) {
        QVERIFY2(allowed.match(item.name).hasMatch(), qPrintable(item.name));
        QVERIFY(item.name.startsWith(QStringLiteral("pomodoro_")));
        QVERIFY2(!seen.contains(item.name), qPrintable(item.name));
        seen.insert(item.name);
        QVERIFY(!item.title.isEmpty());
        QVERIFY(!item.description.isEmpty());
    }
}

void McpProtocolTests::writeToolsDeclareSessionAndPermissionRules()
{
    const QList<Tool> writeTools{Tool::CreateTask, Tool::UpdateTask, Tool::RescheduleTask,
                                 Tool::SetTaskCompleted};
    for (const McpContracts::ToolContract& item : McpContracts::toolContracts()) {
        const bool isWrite = writeTools.contains(item.tool);
        QCOMPARE(item.access == McpContracts::ToolAccess::Write, isWrite);
        QCOMPARE(item.requiresSession, isWrite);
        QCOMPARE(item.requiresIdempotencyKey, item.tool == Tool::CreateTask);
        QCOMPARE(item.requiresStateToken, isWrite && item.tool != Tool::CreateTask);
        QCOMPARE(item.requiresAppConnection, item.tool != Tool::GetStatus);
        QCOMPARE(item.targetsExistingTask,
                 item.tool == Tool::GetTask || (isWrite && item.tool != Tool::CreateTask));

        // 契约里声明需要的字段，输入 schema 必须真的要求，不能只写在标志位上。
        const QJsonArray required = item.inputSchema.value(QStringLiteral("required")).toArray();
        QCOMPARE(required.contains(QStringLiteral("app_session_id")), item.requiresSession);
        QCOMPARE(required.contains(QStringLiteral("idempotency_key")), item.requiresIdempotencyKey);
        QCOMPARE(required.contains(QStringLiteral("expected_state_token")), item.requiresStateToken);
    }
}

void McpProtocolTests::schemasUseOnlyPortableKeywords()
{
    for (const McpContracts::ToolContract& item : McpContracts::toolContracts()) {
        QStringList violations;
        collectSchemaViolations(item.inputSchema, item.name + QStringLiteral("/inputSchema"), violations);
        collectSchemaViolations(item.outputSchema, item.name + QStringLiteral("/outputSchema"), violations);
        QVERIFY2(violations.isEmpty(), qPrintable(violations.join(QLatin1Char('\n'))));

        // MCP 要求两个 schema 的顶层都是对象；输入对象拒绝未知字段，并始终写出 properties。
        QCOMPARE(item.inputSchema.value(QStringLiteral("type")).toString(), QStringLiteral("object"));
        QCOMPARE(item.outputSchema.value(QStringLiteral("type")).toString(), QStringLiteral("object"));
        QVERIFY(item.inputSchema.contains(QStringLiteral("properties")));
        QCOMPARE(item.inputSchema.value(QStringLiteral("additionalProperties")), QJsonValue(false));
    }
}

void McpProtocolTests::toolListJsonCarriesBothSchemas()
{
    const QJsonArray tools = McpContracts::toolListJson();
    const QList<McpContracts::ToolContract>& contracts = McpContracts::toolContracts();
    QCOMPARE(tools.size(), contracts.size());
    const QStringList expectedKeys{QStringLiteral("annotations"), QStringLiteral("description"),
                                   QStringLiteral("inputSchema"), QStringLiteral("name"),
                                   QStringLiteral("outputSchema"), QStringLiteral("title")};
    for (qsizetype index = 0; index < tools.size(); ++index) {
        const QJsonObject tool = tools.at(index).toObject();
        const McpContracts::ToolContract& item = contracts.at(index);
        QCOMPARE(tool.keys(), expectedKeys);
        QCOMPARE(tool.value(QStringLiteral("name")).toString(), item.name);
        QCOMPARE(tool.value(QStringLiteral("inputSchema")).toObject(), item.inputSchema);
        QCOMPARE(tool.value(QStringLiteral("outputSchema")).toObject(), item.outputSchema);

        // 注解只是给客户端的提示（例如只读工具可少问一次确认），授权仍由主应用逐次检查。
        // 提示必须与真实能力一致：写工具不能自称只读，全部只访问本机应用、不接触外部世界。
        const QJsonObject annotations = tool.value(QStringLiteral("annotations")).toObject();
        const bool isWrite = item.access == McpContracts::ToolAccess::Write;
        QCOMPARE(annotations.value(QStringLiteral("readOnlyHint")), QJsonValue(!isWrite));
        QCOMPARE(annotations.value(QStringLiteral("openWorldHint")), QJsonValue(false));
        if (isWrite) {
            // 四个写工具都按幂等键或目标状态执行，同样的参数重复调用不会产生额外效果。
            QCOMPARE(annotations.value(QStringLiteral("idempotentHint")), QJsonValue(true));
            // 只有新建是纯增加；另外三个会改写已有任务的字段。
            QCOMPARE(annotations.value(QStringLiteral("destructiveHint")),
                     QJsonValue(item.tool != Tool::CreateTask));
        } else {
            QVERIFY(!annotations.contains(QStringLiteral("destructiveHint")));
            QVERIFY(!annotations.contains(QStringLiteral("idempotentHint")));
        }
    }
}

void McpProtocolTests::protocolVersionNegotiation_data()
{
    QTest::addColumn<QString>("requested");
    QTest::addColumn<QString>("expected");

    QTest::newRow("首选版本") << QStringLiteral("2025-11-25") << QStringLiteral("2025-11-25");
    QTest::newRow("兼容版本") << QStringLiteral("2025-06-18") << QStringLiteral("2025-06-18");
    QTest::newRow("更早的版本") << QStringLiteral("2024-11-05") << QStringLiteral("2025-11-25");
    QTest::newRow("未实现的新版本") << QStringLiteral("2099-01-01") << QStringLiteral("2025-11-25");
    QTest::newRow("空字符串") << QString() << QStringLiteral("2025-11-25");
}

void McpProtocolTests::protocolVersionNegotiation()
{
    QFETCH(QString, requested);
    QFETCH(QString, expected);
    QCOMPARE(McpContracts::negotiateProtocolVersion(requested), expected);
    QCOMPARE(McpContracts::preferredProtocolVersion(), QStringLiteral("2025-11-25"));
}

void McpProtocolTests::uuidV4Parsing_data()
{
    QTest::addColumn<QString>("text");
    QTest::addColumn<bool>("valid");

    QTest::newRow("小写 v4") << QStringLiteral("3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a") << true;
    QTest::newRow("大写 v4") << QStringLiteral("3F2B8C1E-9D4A-4B6F-8A2C-1E5D7F9B0C3A") << true;
    QTest::newRow("变体位 b") << QStringLiteral("3f2b8c1e-9d4a-4b6f-bA2c-1e5d7f9b0c3a") << true;
    QTest::newRow("常见 v1 示例") << QStringLiteral("123e4567-e89b-12d3-a456-426614174000") << false;
    QTest::newRow("nil") << QStringLiteral("00000000-0000-0000-0000-000000000000") << false;
    QTest::newRow("变体位错误") << QStringLiteral("3f2b8c1e-9d4a-4b6f-7a2c-1e5d7f9b0c3a") << false;
    QTest::newRow("花括号") << QStringLiteral("{3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a}") << false;
    QTest::newRow("URN") << QStringLiteral("urn:uuid:3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a") << false;
    QTest::newRow("前导空格") << QStringLiteral(" 3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a") << false;
    QTest::newRow("结尾换行") << QStringLiteral("3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a\n") << false;
    QTest::newRow("没有连字符") << QStringLiteral("3f2b8c1e9d4a4b6f8a2c1e5d7f9b0c3a") << false;
    QTest::newRow("连字符错位") << QStringLiteral("3f2b8c1e9-d4a-4b6f-8a2c-1e5d7f9b0c3a") << false;
    QTest::newRow("非十六进制") << QStringLiteral("3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3g") << false;
}

void McpProtocolTests::uuidV4Parsing()
{
    QFETCH(QString, text);
    QFETCH(bool, valid);

    const QByteArray bytes = McpContracts::parseUuidV4(text);
    QCOMPARE(!bytes.isEmpty(), valid);
    if (valid) {
        QCOMPARE(bytes.size(), 16);
        // 16 字节按 RFC 4122 的网络字节序排列，和 Qt 的解析结果互相印证。
        QCOMPARE(QUuid::fromRfc4122(bytes), QUuid::fromString(text));
    }
}

void McpProtocolTests::uuidPatternAgreesWithParser()
{
    const QJsonObject keySchema = McpContracts::contract(Tool::CreateTask)
                                      .inputSchema.value(QStringLiteral("properties"))
                                      .toObject()
                                      .value(QStringLiteral("idempotency_key"))
                                      .toObject();
    const QStringList samples{
        QStringLiteral("3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a"),
        QStringLiteral("3F2B8C1E-9D4A-4B6F-8A2C-1E5D7F9B0C3A"),
        QStringLiteral("123e4567-e89b-12d3-a456-426614174000"),
        QStringLiteral("00000000-0000-0000-0000-000000000000"),
        QStringLiteral("3f2b8c1e-9d4a-4b6f-7a2c-1e5d7f9b0c3a"),
        QStringLiteral("{3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a}"),
        QStringLiteral("3f2b8c1e-9d4a-4b6f-8a2c-1e5d7f9b0c3a\n"),
    };
    // schema 里的 pattern 给客户端看，执行端再用解析器复核：两者对同一输入必须给出同样结论。
    for (const QString& sample : samples) {
        QCOMPARE(McpContracts::validateAgainstSchema(QJsonValue(sample), keySchema).ok(),
                 !McpContracts::parseUuidV4(sample).isEmpty());
    }
    // 大小写不同的同一个键归一为同样的 16 字节，去重时不会被当成两个键。
    QCOMPARE(McpContracts::parseUuidV4(samples.at(0)), McpContracts::parseUuidV4(samples.at(1)));
}

void McpProtocolTests::isoDateParsing_data()
{
    QTest::addColumn<QString>("text");
    QTest::addColumn<bool>("valid");

    QTest::newRow("闰日") << QStringLiteral("2024-02-29") << true;
    QTest::newRow("平年二月二十九") << QStringLiteral("2023-02-29") << false;
    QTest::newRow("月份越界") << QStringLiteral("2026-13-01") << false;
    QTest::newRow("月份少写一位") << QStringLiteral("2026-9-01") << false;
    QTest::newRow("带时间") << QStringLiteral("2026-09-01T00:00:00") << false;
    QTest::newRow("结尾换行") << QStringLiteral("2026-09-01\n") << false;
    QTest::newRow("前导空格") << QStringLiteral(" 2026-09-01") << false;
    QTest::newRow("斜杠分隔") << QStringLiteral("2026/09/01") << false;
    QTest::newRow("空字符串") << QString() << false;
}

void McpProtocolTests::isoDateParsing()
{
    QFETCH(QString, text);
    QFETCH(bool, valid);

    QCOMPARE(McpContracts::parseIsoDate(text).has_value(), valid);
    // 经工具参数校验时结论相同：格式不对由 pattern 拦下，格式对但日历上不存在由语义校验拦下。
    const QJsonObject arguments{{QStringLiteral("start_date"), text}, {QStringLiteral("end_date"), text}};
    QCOMPARE(validate(Tool::GetFocusSummary, arguments).ok(), valid);
}

void McpProtocolTests::dateRangeIsInclusiveAndCapped()
{
    const auto range = [](const QString& start, const QString& end) {
        return QJsonObject{{QStringLiteral("start_date"), start}, {QStringLiteral("end_date"), end}};
    };

    // 31 个逻辑日含首尾：1 月 1 日到 31 日正好 31 天。
    QVERIFY(validate(Tool::GetFocusSummary,
                     range(QStringLiteral("2026-01-01"), QStringLiteral("2026-01-31"))).ok());
    QVERIFY(validate(Tool::ListTasks,
                     range(QStringLiteral("2025-12-15"), QStringLiteral("2026-01-14"))).ok());
    QVERIFY(validate(Tool::ListTasks,
                     range(QStringLiteral("2026-02-01"), QStringLiteral("2026-02-01"))).ok());

    const McpContracts::ValidationResult tooLong = validate(
        Tool::GetFocusSummary, range(QStringLiteral("2026-01-01"), QStringLiteral("2026-02-01")));
    QVERIFY2(hasError(tooLong, QStringLiteral("end_date"), QStringLiteral("date_range_too_long")),
             qPrintable(describe(tooLong)));

    const McpContracts::ValidationResult reversed = validate(
        Tool::ListTasks, range(QStringLiteral("2026-02-02"), QStringLiteral("2026-02-01")));
    QVERIFY2(hasError(reversed, QStringLiteral("end_date"), QStringLiteral("date_order")),
             qPrintable(describe(reversed)));
}

void McpProtocolTests::unknownFieldsNullAndWrongTypesAreRejected()
{
    const QJsonObject base = validCreateArguments();
    QVERIFY2(validate(Tool::CreateTask, base).ok(), qPrintable(describe(validate(Tool::CreateTask, base))));

    const McpContracts::ValidationResult unknown =
        validate(Tool::CreateTask, with(base, QStringLiteral("priority"), 2));
    QVERIFY2(hasError(unknown, QStringLiteral("priority"), QStringLiteral("unknown_field")),
             qPrintable(describe(unknown)));

    // null 不能被当成“不改”或“清空”。
    const McpContracts::ValidationResult nullNotes =
        validate(Tool::CreateTask, with(base, QStringLiteral("notes"), QJsonValue(QJsonValue::Null)));
    QVERIFY2(hasError(nullNotes, QStringLiteral("notes"), QStringLiteral("null_not_allowed")),
             qPrintable(describe(nullNotes)));

    // 字符串形式的数字不做隐式转换。
    const McpContracts::ValidationResult stringNumber =
        validate(Tool::CreateTask, with(base, QStringLiteral("category_id"), QStringLiteral("3")));
    QVERIFY2(hasError(stringNumber, QStringLiteral("category_id"), QStringLiteral("type")),
             qPrintable(describe(stringNumber)));

    // 布尔值不能用 0/1 代替。
    const QJsonObject completed = with(updateIdentity(), QStringLiteral("completed"), 1);
    const McpContracts::ValidationResult numericBool = validate(Tool::SetTaskCompleted, completed);
    QVERIFY2(hasError(numericBool, QStringLiteral("completed"), QStringLiteral("type")),
             qPrintable(describe(numericBool)));

    QJsonObject missingKey = base;
    missingKey.remove(QStringLiteral("idempotency_key"));
    const McpContracts::ValidationResult missing = validate(Tool::CreateTask, missingKey);
    QVERIFY2(hasError(missing, QStringLiteral("idempotency_key"), QStringLiteral("required")),
             qPrintable(describe(missing)));

    // 读工具同样拒绝 null 与未知字段。
    const QJsonObject listArguments{{QStringLiteral("start_date"), QStringLiteral("2026-09-01")},
                                    {QStringLiteral("end_date"), QStringLiteral("2026-09-07")},
                                    {QStringLiteral("limit"), QJsonValue(QJsonValue::Null)}};
    QVERIFY(hasError(validate(Tool::ListTasks, listArguments), QStringLiteral("limit"),
                     QStringLiteral("null_not_allowed")));
    QVERIFY(hasError(validate(Tool::GetStatus, QJsonObject{{QStringLiteral("verbose"), true}}),
                     QStringLiteral("verbose"), QStringLiteral("unknown_field")));
    QVERIFY(validate(Tool::GetStatus, QJsonObject()).ok());
}

void McpProtocolTests::integersRejectFractionsAndOutOfRange()
{
    const QJsonObject identity = updateIdentity();
    const auto estimate = [&identity](const QJsonValue& value) {
        return validate(Tool::UpdateTask, with(identity, QStringLiteral("estimated_minutes"), value));
    };

    QVERIFY(hasError(estimate(30.5), QStringLiteral("estimated_minutes"), QStringLiteral("type")));
    QVERIFY(hasError(estimate(-1), QStringLiteral("estimated_minutes"), QStringLiteral("minimum")));
    QVERIFY(hasError(estimate(1441), QStringLiteral("estimated_minutes"), QStringLiteral("maximum")));
    QVERIFY(estimate(1440).ok());
    QVERIFY(estimate(0).ok());
    // JSON Schema 里小数部分为 0 的数就是整数，与客户端校验器的结论保持一致。
    QVERIFY(estimate(30.0).ok());

    const auto taskId = [&identity](const QJsonValue& value) {
        return validate(Tool::UpdateTask,
                        with(with(identity, QStringLiteral("task_id"), value), QStringLiteral("title"),
                             QStringLiteral("新标题")));
    };
    QVERIFY(hasError(taskId(0), QStringLiteral("task_id"), QStringLiteral("minimum")));
    QVERIFY(hasError(taskId(2147483648.0), QStringLiteral("task_id"), QStringLiteral("maximum")));
    // 超出双精度可精确表示的整数：接受就可能把编号悄悄改成另一个数。
    QVERIFY(hasError(taskId(9007199254740993.0), QStringLiteral("task_id"), QStringLiteral("type")));
    QVERIFY(taskId(2147483647).ok());
}

void McpProtocolTests::stateTokenMustBeLowercaseHex()
{
    const QJsonObject identity = with(updateIdentity(), QStringLiteral("title"), QStringLiteral("新标题"));
    QVERIFY(validate(Tool::UpdateTask, identity).ok());

    const QJsonObject upper = with(identity, QStringLiteral("expected_state_token"), sampleStateToken().toUpper());
    QVERIFY(hasError(validate(Tool::UpdateTask, upper), QStringLiteral("expected_state_token"),
                     QStringLiteral("pattern")));
    const QJsonObject shortToken = with(identity, QStringLiteral("expected_state_token"), QStringLiteral("abc"));
    QVERIFY(hasError(validate(Tool::UpdateTask, shortToken), QStringLiteral("expected_state_token"),
                     QStringLiteral("pattern")));
}

void McpProtocolTests::updateTaskNeedsAtLeastOneEditableField()
{
    const McpContracts::ValidationResult identityOnly = validate(Tool::UpdateTask, updateIdentity());
    QVERIFY2(hasError(identityOnly, QString(), QStringLiteral("update_fields_required")),
             qPrintable(describe(identityOnly)));

    // 清空备注、清除预计用时、清除科目都算提供了字段。
    QVERIFY(validate(Tool::UpdateTask, with(updateIdentity(), QStringLiteral("notes"), QString())).ok());
    QVERIFY(validate(Tool::UpdateTask, with(updateIdentity(), QStringLiteral("estimated_minutes"), 0)).ok());
    QVERIFY(validate(Tool::UpdateTask, with(updateIdentity(), QStringLiteral("category_id"), 0)).ok());

    // 日期和完成状态走专门的工具。
    QVERIFY(hasError(validate(Tool::UpdateTask,
                              with(updateIdentity(), QStringLiteral("date"), QStringLiteral("2026-09-18"))),
                     QStringLiteral("date"), QStringLiteral("unknown_field")));
}

void McpProtocolTests::knowledgeGapDueFilterCombinations()
{
    const auto gaps = [](const QJsonObject& arguments) { return validate(Tool::ListKnowledgeGaps, arguments); };
    const QJsonObject unresolved{{QStringLiteral("status"), QStringLiteral("unresolved")}};

    QVERIFY(gaps(unresolved).ok());
    QVERIFY(hasError(gaps(QJsonObject()), QStringLiteral("status"), QStringLiteral("required")));
    QVERIFY(hasError(gaps(with(unresolved, QStringLiteral("status"), QStringLiteral("pending"))),
                     QStringLiteral("status"), QStringLiteral("enum")));

    // 未排期与到期区间互相矛盾。
    const QJsonObject conflict = with(with(unresolved, QStringLiteral("due_state"), QStringLiteral("unscheduled")),
                                      QStringLiteral("due_from"), QStringLiteral("2026-09-01"));
    QVERIFY(hasError(gaps(conflict), QStringLiteral("due_state"), QStringLiteral("due_bounds_conflict")));

    const QJsonObject reversed = with(with(unresolved, QStringLiteral("due_from"), QStringLiteral("2026-09-10")),
                                      QStringLiteral("due_to"), QStringLiteral("2026-09-01"));
    QVERIFY(hasError(gaps(reversed), QStringLiteral("due_to"), QStringLiteral("date_order")));

    // 到期区间不受任务列表 31 天的限制。
    const QJsonObject wide = with(with(unresolved, QStringLiteral("due_from"), QStringLiteral("2026-01-01")),
                                  QStringLiteral("due_to"), QStringLiteral("2026-12-31"));
    QVERIFY(gaps(wide).ok());

    // 逾期：逻辑今日前一天作上界，只看有到期日的条目。
    const QJsonObject overdue = with(with(unresolved, QStringLiteral("due_state"), QStringLiteral("scheduled")),
                                     QStringLiteral("due_to"), QStringLiteral("2026-09-16"));
    QVERIFY(gaps(overdue).ok());

    QVERIFY(hasError(gaps(with(unresolved, QStringLiteral("due_from"), QStringLiteral("2026-02-30"))),
                     QStringLiteral("due_from"), QStringLiteral("invalid_date")));
    QVERIFY(hasError(gaps(with(unresolved, QStringLiteral("after_id"), -1)), QStringLiteral("after_id"),
                     QStringLiteral("minimum")));
    QVERIFY(hasError(gaps(with(unresolved, QStringLiteral("limit"), 101)), QStringLiteral("limit"),
                     QStringLiteral("maximum")));
    QVERIFY(gaps(with(unresolved, QStringLiteral("search_text"), QString())).ok());
}

void McpProtocolTests::defaultsFillOnlyDeclaredFields()
{
    const QJsonObject create = McpContracts::applySchemaDefaults(Tool::CreateTask, validCreateArguments());
    QCOMPARE(create.value(QStringLiteral("notes")), QJsonValue(QString()));
    QCOMPARE(create.value(QStringLiteral("estimated_minutes")).toInteger(), 0);
    QCOMPARE(create.value(QStringLiteral("category_id")).toInteger(), 0);
    QCOMPARE(create.value(QStringLiteral("title")).toString(), QStringLiteral("背单词"));

    // 显式给出的值不被默认值覆盖。
    const QJsonObject explicitNotes = McpContracts::applySchemaDefaults(
        Tool::CreateTask, with(validCreateArguments(), QStringLiteral("notes"), QStringLiteral("第 3 单元")));
    QCOMPARE(explicitNotes.value(QStringLiteral("notes")).toString(), QStringLiteral("第 3 单元"));

    // 修改任务没有默认值：补齐之后“没提供”仍然是“没提供”。
    const QJsonObject update = with(updateIdentity(), QStringLiteral("title"), QStringLiteral("新标题"));
    QCOMPARE(McpContracts::applySchemaDefaults(Tool::UpdateTask, update), update);

    const QJsonObject list = McpContracts::applySchemaDefaults(
        Tool::ListTasks, QJsonObject{{QStringLiteral("start_date"), QStringLiteral("2026-09-01")},
                                     {QStringLiteral("end_date"), QStringLiteral("2026-09-07")}});
    QCOMPARE(list.value(QStringLiteral("completion_state")).toString(), QStringLiteral("any"));
    QCOMPARE(list.value(QStringLiteral("limit")).toInteger(), McpContracts::kDefaultListLimit);

    const QJsonObject gaps = McpContracts::applySchemaDefaults(
        Tool::ListKnowledgeGaps, QJsonObject{{QStringLiteral("status"), QStringLiteral("all")}});
    QCOMPARE(gaps.value(QStringLiteral("due_state")).toString(), QStringLiteral("any"));
    QCOMPARE(gaps.value(QStringLiteral("after_id")).toInteger(), 0);
    QCOMPARE(gaps.value(QStringLiteral("limit")).toInteger(), McpContracts::kDefaultListLimit);
    QVERIFY(!gaps.contains(QStringLiteral("due_from")));
    QVERIFY(!gaps.contains(QStringLiteral("category_id")));
}

void McpProtocolTests::stringLengthsCountCodePoints()
{
    const char32_t grinning = U'\U0001F600';
    const QString oneEmoji = QString::fromUcs4(&grinning, 1);
    const QString hundredEmoji = oneEmoji.repeated(McpContracts::kTaskTitleMaxLength);
    // 100 个 emoji 按码点是 100，按 UTF-16 单元是 200。schema 口径与客户端校验器一致按码点计；
    // 业务语义校验额外按 UTF-16 限制，在进入服务前拒绝超限。
    QCOMPARE(hundredEmoji.size(), 200);
    const auto args = with(validCreateArguments(), QStringLiteral("title"), hundredEmoji);
    QVERIFY(McpContracts::validateAgainstSchema(args, McpContracts::contract(Tool::CreateTask).inputSchema).ok());
    QVERIFY(hasError(validate(Tool::CreateTask, args), QStringLiteral("title"), QStringLiteral("utf16_length")));
    for (const Tool tool : {Tool::CreateTask, Tool::UpdateTask}) {
        const auto base = tool == Tool::CreateTask ? validCreateArguments() : updateIdentity();
        QVERIFY(hasError(validate(tool, with(base, QStringLiteral("title"), QStringLiteral(" \t\n　"))),
                         QStringLiteral("title"), QStringLiteral("blank_title")));
        QVERIFY(validate(tool, with(base, QStringLiteral("title"), oneEmoji.repeated(50))).ok());
        QVERIFY(hasError(validate(tool, with(base, QStringLiteral("title"), oneEmoji.repeated(51))),
                         QStringLiteral("title"), QStringLiteral("utf16_length")));
        QVERIFY(validate(tool, with(base, QStringLiteral("notes"), oneEmoji.repeated(1000))).ok());
        QVERIFY(hasError(validate(tool, with(base, QStringLiteral("notes"), oneEmoji.repeated(1001))),
                         QStringLiteral("notes"), QStringLiteral("utf16_length")));
    }
    QVERIFY(hasError(validate(Tool::CreateTask, with(validCreateArguments(), QStringLiteral("title"),
                                                     hundredEmoji + oneEmoji)),
                     QStringLiteral("title"), QStringLiteral("max_length")));
    QVERIFY(hasError(validate(Tool::CreateTask, with(validCreateArguments(), QStringLiteral("title"), QString())),
                     QStringLiteral("title"), QStringLiteral("min_length")));
}

void McpProtocolTests::noErrorIsAutoRetryable()
{
    const QStringList expectedNames{
        QStringLiteral("APP_UNAVAILABLE"),      QStringLiteral("MCP_DISABLED"),
        QStringLiteral("PERMISSION_DENIED"),    QStringLiteral("APP_BUSY"),
        QStringLiteral("NOT_FOUND"),            QStringLiteral("VALIDATION_ERROR"),
        QStringLiteral("STATE_CONFLICT"),       QStringLiteral("RESULT_LIMIT_EXCEEDED"),
        QStringLiteral("SESSION_EXPIRED"),      QStringLiteral("IDEMPOTENCY_CONFLICT"),
        QStringLiteral("WRITE_CAPACITY_REACHED"), QStringLiteral("DATABASE_ERROR"),
        QStringLiteral("OUTCOME_UNKNOWN"),      QStringLiteral("IPC_PATH_INVALID"),
    };
    QStringList names;
    for (McpContracts::ErrorCode code : McpContracts::allErrorCodes()) {
        const QString name = McpContracts::errorCodeName(code);
        names.append(name);
        QVERIFY2(!McpContracts::errorRetryable(code), qPrintable(name));
        QVERIFY2(!McpContracts::errorNextAction(code).isEmpty(), qPrintable(name));

        const QJsonObject error = McpContracts::makeError(code, QStringLiteral("说明"));
        QCOMPARE(error.value(QStringLiteral("code")).toString(), name);
        QCOMPARE(error.value(QStringLiteral("message")).toString(), QStringLiteral("说明"));
        QCOMPARE(error.value(QStringLiteral("retryable")), QJsonValue(false));
        QCOMPARE(error.value(QStringLiteral("next_action")).toString(), McpContracts::errorNextAction(code));
        QVERIFY(!error.contains(QStringLiteral("details")));
    }
    QCOMPARE(names, expectedNames);
}

void McpProtocolTests::everyBusyReasonHasScopeAndNextAction()
{
    using McpContracts::BlockScope;
    using McpContracts::BusyReason;

    QStringList names;
    for (BusyReason reason : McpContracts::allBusyReasons()) {
        names.append(McpContracts::busyReasonName(reason));
        QVERIFY(!McpContracts::busyReasonRetryable(reason));
        QVERIFY(!McpContracts::busyReasonNextAction(reason).isEmpty());
    }
    QCOMPARE(names, (QStringList{QStringLiteral("editing"), QStringLiteral("dragging"),
                                 QStringLiteral("pending_delete"), QStringLiteral("backup_restore"),
                                 QStringLiteral("shutting_down")}));

    QCOMPARE(McpContracts::busyReasonScope(BusyReason::Editing), BlockScope::AllWrites);
    QCOMPARE(McpContracts::busyReasonScope(BusyReason::Dragging), BlockScope::AllWrites);
    QCOMPARE(McpContracts::busyReasonScope(BusyReason::PendingDelete), BlockScope::Task);
    QCOMPARE(McpContracts::busyReasonScope(BusyReason::BackupRestore), BlockScope::AllData);
    QCOMPARE(McpContracts::busyReasonScope(BusyReason::ShuttingDown), BlockScope::AllData);
}

void McpProtocolTests::busyErrorListsEveryBlock()
{
    using McpContracts::BusyReason;

    const QJsonObject error = McpContracts::makeBusyError(
        {{BusyReason::Editing, QStringLiteral("today.edit_dialog"), 0},
         {BusyReason::PendingDelete, QStringLiteral("main.pending_delete"), 42}});
    QCOMPARE(error.value(QStringLiteral("code")).toString(), QStringLiteral("APP_BUSY"));
    QCOMPARE(error.value(QStringLiteral("retryable")), QJsonValue(false));

    const QJsonArray blocks =
        error.value(QStringLiteral("details")).toObject().value(QStringLiteral("blocks")).toArray();
    QCOMPARE(blocks.size(), 2);

    const QJsonObject editing = blocks.at(0).toObject();
    QCOMPARE(editing.value(QStringLiteral("reason")).toString(), QStringLiteral("editing"));
    QCOMPARE(editing.value(QStringLiteral("scope")).toString(), QStringLiteral("all_writes"));
    QCOMPARE(editing.value(QStringLiteral("source")).toString(), QStringLiteral("today.edit_dialog"));
    QVERIFY(editing.value(QStringLiteral("task_id")).isNull());
    QCOMPARE(editing.value(QStringLiteral("next_action")).toString(),
             McpContracts::busyReasonNextAction(BusyReason::Editing));

    const QJsonObject pending = blocks.at(1).toObject();
    QCOMPARE(pending.value(QStringLiteral("reason")).toString(), QStringLiteral("pending_delete"));
    QCOMPARE(pending.value(QStringLiteral("scope")).toString(), QStringLiteral("task"));
    QCOMPARE(pending.value(QStringLiteral("task_id")).toInteger(), 42);

    // 同一组阻断条目也出现在状态查询结果里，必须满足那里的 schema。
    const QJsonObject blockSchema = outputProperty(Tool::GetStatus, QStringLiteral("app"))
                                        .value(QStringLiteral("properties"))
                                        .toObject()
                                        .value(QStringLiteral("blocks"))
                                        .toObject()
                                        .value(QStringLiteral("items"))
                                        .toObject();
    for (const QJsonValue& block : blocks) {
        QVERIFY(McpContracts::validateAgainstSchema(block, blockSchema).ok());
    }
}

void McpProtocolTests::committedCreateReadFailureNeverClaimsFailure()
{
    const QJsonObject error = McpContracts::makeCommittedCreateReadFailure(57);
    QCOMPARE(error.value(QStringLiteral("code")).toString(), QStringLiteral("DATABASE_ERROR"));
    QCOMPARE(error.value(QStringLiteral("retryable")), QJsonValue(false));

    const QJsonObject details = error.value(QStringLiteral("details")).toObject();
    QCOMPARE(details.value(QStringLiteral("created_task_id")).toInteger(), 57);
    QCOMPARE(details.value(QStringLiteral("creation_committed")), QJsonValue(true));

    const QString message = error.value(QStringLiteral("message")).toString();
    QCOMPARE(message, QStringLiteral("任务已创建，读取当前数据失败"));
    QVERIFY(!message.contains(QStringLiteral("创建失败")));

    // 通用的数据库错误提示不够：必须明确沿用原键，否则模型会换新键再建一条。
    const QString nextAction = error.value(QStringLiteral("next_action")).toString();
    QVERIFY(nextAction.contains(QStringLiteral("原 idempotency_key")));
    QVERIFY(nextAction.contains(QStringLiteral("不要换新键")));
    QVERIFY(nextAction != McpContracts::errorNextAction(McpContracts::ErrorCode::DatabaseError));
}

void McpProtocolTests::validationErrorCarriesFieldErrors()
{
    const McpContracts::ValidationResult result = validate(Tool::CreateTask, QJsonObject());
    QVERIFY(!result.ok());

    const QJsonObject error = McpContracts::makeValidationError(result);
    QCOMPARE(error.value(QStringLiteral("code")).toString(), QStringLiteral("VALIDATION_ERROR"));
    const QJsonArray fieldErrors =
        error.value(QStringLiteral("details")).toObject().value(QStringLiteral("field_errors")).toArray();
    QCOMPARE(fieldErrors.size(), result.errors.size());
    for (const QJsonValue& value : fieldErrors) {
        const QJsonObject fieldError = value.toObject();
        QCOMPARE(fieldError.value(QStringLiteral("reason")).toString(), QStringLiteral("required"));
        QVERIFY(!fieldError.value(QStringLiteral("field")).toString().isEmpty());
        QVERIFY(!fieldError.value(QStringLiteral("message")).toString().isEmpty());
    }
}

void McpProtocolTests::successResultDuplicatesStructuredContentAsText()
{
    const QJsonObject structured{{QStringLiteral("task"), sampleTask()}};
    const QJsonObject result = McpContracts::makeToolSuccessResult(structured);

    QCOMPARE(result.value(QStringLiteral("isError")), QJsonValue(false));
    QCOMPARE(result.value(QStringLiteral("structuredContent")).toObject(), structured);

    const QJsonArray content = result.value(QStringLiteral("content")).toArray();
    QCOMPARE(content.size(), 1);
    QCOMPARE(content.at(0).toObject().value(QStringLiteral("type")).toString(), QStringLiteral("text"));
    const QString text = content.at(0).toObject().value(QStringLiteral("text")).toString();

    // 文本是同一份完整 JSON，而不是摘要：只读 content 的客户端也能拿到编号与状态令牌继续写入。
    QCOMPARE(firstTextAsJson(result), structured);
    QVERIFY(text.contains(sampleStateToken()));
    QVERIFY(text.contains(QStringLiteral("\"task_id\":57")));
}

void McpProtocolTests::errorResultHasNoStructuredContent()
{
    const QJsonObject error =
        McpContracts::makeError(McpContracts::ErrorCode::StateConflict, QStringLiteral("任务已被修改"));
    const QJsonObject result = McpContracts::makeToolErrorResult(error);

    QCOMPARE(result.value(QStringLiteral("isError")), QJsonValue(true));
    QVERIFY(!result.contains(QStringLiteral("structuredContent")));
    const QJsonObject parsed = firstTextAsJson(result);
    QCOMPARE(parsed, error);
    QCOMPARE(parsed.value(QStringLiteral("retryable")), QJsonValue(false));
}

void McpProtocolTests::sampleResultsMatchOutputSchemas()
{
    const QJsonObject task = sampleTask();
    QVERIFY(matchesOutput(Tool::GetTask, QJsonObject{{QStringLiteral("task"), task}}));

    const auto createResult = [](const QString& state, const QJsonValue& currentTask, bool replayed) {
        return QJsonObject{{QStringLiteral("created_task_id"), 57},
                           {QStringLiteral("current_state"), state},
                           {QStringLiteral("replayed"), replayed},
                           {QStringLiteral("task"), currentTask}};
    };
    QVERIFY(matchesOutput(Tool::CreateTask, createResult(QStringLiteral("present"), task, false)));
    QVERIFY(matchesOutput(Tool::CreateTask,
                          createResult(QStringLiteral("deleted"), QJsonValue(QJsonValue::Null), true)));
    QVERIFY(matchesOutput(Tool::CreateTask,
                          createResult(QStringLiteral("pending_delete"), QJsonValue(QJsonValue::Null), true)));
    QVERIFY(!matchesOutput(Tool::CreateTask,
                           createResult(QStringLiteral("gone"), QJsonValue(QJsonValue::Null), true)));

    for (Tool writeTool : {Tool::UpdateTask, Tool::RescheduleTask, Tool::SetTaskCompleted}) {
        QVERIFY(matchesOutput(writeTool,
                              QJsonObject{{QStringLiteral("changed"), false}, {QStringLiteral("task"), task}}));
    }

    const QJsonObject offline{
        {QStringLiteral("connected"), false},
        {QStringLiteral("helper_version"), QStringLiteral("0.1.0")},
        {QStringLiteral("bridge_protocol_version"), McpContracts::kBridgeProtocolVersion},
        {QStringLiteral("unavailable_reason"), QStringLiteral("endpoint_unreachable")},
        {QStringLiteral("path_error"), QJsonValue(QJsonValue::Null)},
        {QStringLiteral("app"), QJsonValue(QJsonValue::Null)},
    };
    QVERIFY(matchesOutput(Tool::GetStatus, offline));
    QVERIFY(!matchesOutput(Tool::GetStatus, with(offline, QStringLiteral("unavailable_reason"),
                                                 QStringLiteral("app_not_running"))));

    const QJsonObject connected = with(
        with(offline, QStringLiteral("connected"), true), QStringLiteral("app"),
        QJsonObject{{QStringLiteral("app_version"), QStringLiteral("0.1.0")},
                    {QStringLiteral("access_enabled"), true},
                    {QStringLiteral("write_enabled"), false},
                    {QStringLiteral("app_session_id"), newUuid()},
                    {QStringLiteral("logical_today"), QStringLiteral("2026-09-17")},
                    {QStringLiteral("time_zone"), QStringLiteral("Asia/Shanghai")},
                    {QStringLiteral("day_start_hour"), 4},
                    {QStringLiteral("blocks"), QJsonArray{sampleBusyBlockEntry()}}});
    QVERIFY(matchesOutput(Tool::GetStatus,
                          with(connected, QStringLiteral("unavailable_reason"), QJsonValue(QJsonValue::Null))));

    QVERIFY(matchesOutput(Tool::ListCategories,
                          QJsonObject{{QStringLiteral("categories"),
                                       QJsonArray{QJsonObject{{QStringLiteral("category_id"), 1},
                                                              {QStringLiteral("name"), QStringLiteral("数学")},
                                                              {QStringLiteral("color"), QStringLiteral("#C8743C")},
                                                              {QStringLiteral("is_preset"), true}}}}}));

    QVERIFY(matchesOutput(Tool::ListTasks,
                          QJsonObject{{QStringLiteral("start_date"), QStringLiteral("2026-09-14")},
                                      {QStringLiteral("end_date"), QStringLiteral("2026-09-20")},
                                      {QStringLiteral("completion_state"), QStringLiteral("any")},
                                      {QStringLiteral("logical_today"), QStringLiteral("2026-09-17")},
                                      {QStringLiteral("count"), 1},
                                      {QStringLiteral("tasks"), QJsonArray{task}}}));

    const QJsonObject day{{QStringLiteral("date"), QStringLiteral("2026-09-17")},
                          {QStringLiteral("day_state"), QStringLiteral("in_progress")},
                          {QStringLiteral("focus_seconds"), 1500},
                          {QStringLiteral("focus_minutes"), 25},
                          {QStringLiteral("valid_pomodoros"), 1}};
    const QJsonObject category{{QStringLiteral("category_id"), 0},
                               {QStringLiteral("category_name"), QString()},
                               {QStringLiteral("focus_seconds"), 1500},
                               {QStringLiteral("focus_minutes"), 25}};
    QVERIFY(matchesOutput(Tool::GetFocusSummary,
                          QJsonObject{{QStringLiteral("start_date"), QStringLiteral("2026-09-17")},
                                      {QStringLiteral("end_date"), QStringLiteral("2026-09-17")},
                                      {QStringLiteral("logical_today"), QStringLiteral("2026-09-17")},
                                      {QStringLiteral("as_of"), QStringLiteral("2026-09-17T21:30:00+08:00")},
                                      {QStringLiteral("is_partial"), true},
                                      {QStringLiteral("total_focus_seconds"), 1500},
                                      {QStringLiteral("total_focus_minutes"), 25},
                                      {QStringLiteral("valid_pomodoros"), 1},
                                      {QStringLiteral("days"), QJsonArray{day}},
                                      {QStringLiteral("categories"), QJsonArray{category}}}));

    const QJsonObject gap{{QStringLiteral("gap_id"), 12},
                          {QStringLiteral("title"), QStringLiteral("泰勒展开余项")},
                          {QStringLiteral("status"), QStringLiteral("open")},
                          {QStringLiteral("priority"), 1},
                          {QStringLiteral("category_id"), 0},
                          {QStringLiteral("category_name"), QString()},
                          {QStringLiteral("due_date"), QJsonValue(QJsonValue::Null)},
                          {QStringLiteral("linked_task_id"), QJsonValue(QJsonValue::Null)},
                          {QStringLiteral("linked_task_open"), false}};
    const QJsonObject gapPage{{QStringLiteral("status"), QStringLiteral("unresolved")},
                              {QStringLiteral("due_state"), QStringLiteral("unscheduled")},
                              {QStringLiteral("logical_today"), QStringLiteral("2026-09-17")},
                              {QStringLiteral("has_more"), true},
                              {QStringLiteral("next_after_id"), 12},
                              {QStringLiteral("gaps"), QJsonArray{gap}}};
    QVERIFY(matchesOutput(Tool::ListKnowledgeGaps, gapPage));
    QVERIFY(matchesOutput(Tool::ListKnowledgeGaps,
                          with(with(gapPage, QStringLiteral("has_more"), false), QStringLiteral("next_after_id"),
                               QJsonValue(QJsonValue::Null))));
}

void McpProtocolTests::pathsStayInsideInjectedRoot()
{
    // 文件系统根下不可写的虚构目录：既保证路径不存在，也保证测试不可能真的建出它。
    const QString root = QStringLiteral("/pomodoro-mcp-test-root-that-does-not-exist//mcp/");
    const McpPaths::Resolution resolution = McpPaths::resolveForRoot(root);
    QVERIFY(resolution.ok());

    const QString cleanRoot = QStringLiteral("/pomodoro-mcp-test-root-that-does-not-exist/mcp");
    QCOMPARE(resolution.paths.rootDirectory, cleanRoot);
    QCOMPARE(resolution.paths.socketPath, cleanRoot + QStringLiteral("/s"));
    QCOMPARE(resolution.paths.credentialPath, cleanRoot + QStringLiteral("/key"));
    QCOMPARE(resolution.paths.discoveryPath, cleanRoot + QStringLiteral("/endpoint.json"));
    QCOMPARE(resolution.socketPathBytes, QFile::encodeName(resolution.paths.socketPath).size());
    // 路径计算不创建目录。
    QVERIFY(!QFileInfo::exists(cleanRoot));
}

void McpProtocolTests::socketPathLimitCountsBytesNotCharacters()
{
    QCOMPARE(McpPaths::kMaxSocketPathBytes, 103);

    const QString asciiLimit = asciiRootForSocketBytes(103);
    const McpPaths::Resolution fits = McpPaths::resolveForRoot(asciiLimit);
    QVERIFY(fits.ok());
    QCOMPARE(fits.socketPathBytes, 103);

    const McpPaths::Resolution overflow = McpPaths::resolveForRoot(asciiRootForSocketBytes(104));
    QCOMPARE(overflow.error, McpPaths::PathError::SocketPathTooLong);
    QCOMPARE(overflow.socketPathBytes, 104);
    // 出错时不给半截路径，调用方没法拿它去 listen/connect。
    QVERIFY(overflow.paths.socketPath.isEmpty());

    // 中文路径：字符数远没到上限，UTF-8 字节数已经超了。
    const QString chineseRoot = QStringLiteral("/tmp/") + QString(32, QChar(u'番'));
    const McpPaths::Resolution chineseFits = McpPaths::resolveForRoot(chineseRoot);
    QVERIFY(chineseFits.ok());
    QCOMPARE(chineseFits.socketPathBytes, 103);

    const QString chineseOverflowRoot = chineseRoot + QLatin1Char('a');
    QVERIFY(chineseOverflowRoot.size() + 2 < McpPaths::kMaxSocketPathBytes);
    const McpPaths::Resolution chineseOverflow = McpPaths::resolveForRoot(chineseOverflowRoot);
    QCOMPARE(chineseOverflow.error, McpPaths::PathError::SocketPathTooLong);
    QCOMPARE(chineseOverflow.socketPathBytes, 104);
}

void McpProtocolTests::invalidRootsAreRejectedWithoutSideEffects()
{
    const auto expectError = [](const QString& root, McpPaths::PathError error, const QString& reason) {
        const McpPaths::Resolution resolution = McpPaths::resolveForRoot(root);
        QCOMPARE(resolution.error, error);
        QVERIFY(!resolution.ok());
        QVERIFY(resolution.paths.rootDirectory.isEmpty());
        QVERIFY(resolution.paths.socketPath.isEmpty());
        QCOMPARE(McpPaths::pathErrorReason(resolution.error), reason);
    };

    expectError(QString(), McpPaths::PathError::EmptyRoot, QStringLiteral("empty_root"));
    expectError(QStringLiteral("relative/mcp"), McpPaths::PathError::RelativeRoot,
                QStringLiteral("relative_root"));
    expectError(QStringLiteral("/tmp/mcp") + QChar(u'\0') + QStringLiteral("hidden"),
                McpPaths::PathError::EmbeddedNul, QStringLiteral("embedded_nul"));
    expectError(asciiRootForSocketBytes(200), McpPaths::PathError::SocketPathTooLong,
                QStringLiteral("path_too_long"));
}

void McpProtocolTests::productionPathsRequireApplicationIdentity()
{
    // 两个名字分别单独出错：只校验其中一个的实现，会在另一个出错时悄悄算出别的目录。
    // 第二种正是辅助程序最可能犯的错——沿用自己的可执行文件名当应用名。
    QCoreApplication::setOrganizationName(QStringLiteral("SomebodyElse"));
    QCoreApplication::setApplicationName(McpPaths::applicationName());
    QCOMPARE(McpPaths::resolveProduction().error, McpPaths::PathError::IdentityNotApplied);

    QCoreApplication::setOrganizationName(McpPaths::organizationName());
    QCoreApplication::setApplicationName(QStringLiteral("PomodoroTodoMcp"));
    QCOMPARE(McpPaths::resolveProduction().error, McpPaths::PathError::IdentityNotApplied);

    McpPaths::applyApplicationIdentity();
    QCOMPARE(QCoreApplication::organizationName(), QStringLiteral("PomodoroTodo"));
    QCOMPARE(QCoreApplication::applicationName(), QStringLiteral("PomodoroTodo"));

    const McpPaths::Resolution resolution = McpPaths::resolveProduction();
    if (resolution.error == McpPaths::PathError::SocketPathTooLong) {
        // 主目录很长的机器上，测试模式下的路径可能超长；这时只要求如实报超长。
        QVERIFY(resolution.socketPathBytes > McpPaths::kMaxSocketPathBytes);
        return;
    }
    QVERIFY(resolution.ok());
    QVERIFY2(resolution.paths.rootDirectory.endsWith(QStringLiteral("/PomodoroTodo/PomodoroTodo/mcp")),
             qPrintable(resolution.paths.rootDirectory));
    QVERIFY(resolution.paths.socketPath.endsWith(QStringLiteral("/mcp/s")));
    QVERIFY(!QFileInfo::exists(resolution.paths.rootDirectory));
}

void McpProtocolTests::pathErrorDetailsOmitFullPath()
{
    const QString privateRoot = QStringLiteral("/Users/someone-private/") + QString(120, QLatin1Char('x'));
    const McpPaths::Resolution tooLong = McpPaths::resolveForRoot(privateRoot);
    const QJsonObject details = McpPaths::pathErrorDetails(tooLong);
    QCOMPARE(details.value(QStringLiteral("reason")).toString(), QStringLiteral("path_too_long"));
    QCOMPARE(details.value(QStringLiteral("actual_bytes")).toInteger(), tooLong.socketPathBytes);
    QCOMPARE(details.value(QStringLiteral("max_bytes")).toInteger(), McpPaths::kMaxSocketPathBytes);
    QVERIFY(!QJsonDocument(details).toJson().contains("someone-private"));

    const QJsonObject relative = McpPaths::pathErrorDetails(McpPaths::resolveForRoot(QStringLiteral("relative")));
    QCOMPARE(relative.value(QStringLiteral("reason")).toString(), QStringLiteral("relative_root"));
    QVERIFY(relative.value(QStringLiteral("actual_bytes")).isNull());
    QVERIFY(relative.value(QStringLiteral("max_bytes")).isNull());

    // 两种 details 都要能直接放进状态查询结果的 path_error。
    const QJsonObject pathErrorSchema = outputProperty(Tool::GetStatus, QStringLiteral("path_error"));
    QVERIFY(McpContracts::validateAgainstSchema(details, pathErrorSchema).ok());
    QVERIFY(McpContracts::validateAgainstSchema(relative, pathErrorSchema).ok());
}

QTEST_GUILESS_MAIN(McpProtocolTests)

#include "McpProtocolTests.moc"
