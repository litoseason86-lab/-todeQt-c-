# 047：MCP 外部 AI 管理接入

## 状态与目标

- **状态**：六阶段已完成并部署（2026-09-18），等待用户复核。实施分支 `work/20260917-mcp-stage2`，保留阶段 1 原有未提交改动；审计全量离屏回归 100/100 通过，官方 SDK 两版本与 Claude Code 全工具联调通过。已原子部署到 `/Applications/番茄Todo.app` 并校验两个二进制一致；未启动或结束生产 GUI、未改持久客户端配置、未提交 Git。接入默认关闭。
- **复核基线**：`71f511c`。计划复核时已核对当前源码、业务规则、协议文档及本机官方 TypeScript SDK 1.29.0 的结果校验行为；未访问真实业务数据库。阶段 1 起的构建与测试结果记在各阶段实施记录里；阶段 6 已完成隔离客户端联调，详见实施记录。
- **目标**：让支持本地 stdio MCP 的外部 AI 客户端读取番茄 Todo 数据，并按用户指令管理任务；应用继续负责数据校验、持久化与界面刷新。
- **完成场景**：查询本周任务与专注投入；新建明日任务；编辑预计用时与备注；调整日期；完成或重新打开任务；查询未解决知识缺口。
- **首版边界**：本机、单用户；数据操作要求主应用已运行并开启接入，初始化和工具发现不要求主应用在线。不内置模型或聊天界面，不配置模型密钥，不部署公网服务，不自动启动或前置主窗口。
- **暂不开放**：任务删除、批量事务操作、任务排序、知识缺口写入、课表/例行/长期目标写入、计时启停、专注历史修改、备份恢复、任意 SQL、文件读写与命令执行。后续按独立需求扩展。
- **与 046 的关系**：046 已落地（`14be410`），计划随后在 `71f511c` 删除，查阅留档用 `git show 14be410:plans/046-本周复盘落地.md`。当前显式复盘接口为 `getWeeklyReview(weekStart, logicalTodayIso)`；首版不暴露复盘，专注查询只提供统计事实。
- **文档入库状态**：复核时索引已跟踪，本文件仍未跟踪；后续提交计划时须把正文一并纳入，不能只提交指向正文的索引。本轮不执行提交。

## 已有基础与架构决策

### 已核对的入口

| 当前文件 | 已有能力 | 本计划的使用方式 |
| --- | --- | --- |
| `src/services/TaskManager.h` | `createTask` 返回新编号，任务查询、编辑、改期、设置完成状态及 `tasksChanged` | 所有任务读写复用服务；不按标题反查新任务 |
| `src/services/StatisticsService.h` | 日/周统计、科目统计、按任务的每日投入 | 输出结构化事实，沿用有效专注口径 |
| `src/services/KnowledgeGapService.h` | `listGaps`、`getGap`、查询失败信号 | 只读查询，不改变缺口的排期和状态 |
| `src/services/CategoryManager.h` | 科目列表与按编号查询 | 让 AI 使用真实科目编号，禁止猜测映射 |
| `src/services/LogicalDayService.*`、`LogicalDay.h` | 前者通过 `changed()` 通知逻辑日变化；后者负责日期计算 | 使用 `LogicalDay::today(AppSettings::instance()->dayStartHour())` 计算逻辑今日并返回日界设置 |
| `src/services/BackupService.h` | `operationBlocksUi`、恢复信号、退出处理 | MCP 在实际执行前检查阻断状态 |
| `src/services/SingleInstanceGuard.*` | `QLockFile` 排他锁及 `QLocalServer` 召回通道 | 保留原职责；MCP 使用独立端点 |
| `src/main.cpp` | 数据库初始化、计时恢复、例行生成、信号装配 | 服务就绪后启动接入，关闭数据库前停止接入 |
| `CMakeLists.txt`、`cmake/DeployLocalApp.cmake` | 已依赖 Qt Network；原子部署应用包 | 新增辅助程序目标，并纳入包内与部署校验 |

### 进程与分层

```text
外部 AI 客户端
    │ MCP / stdio（标准输入输出）
    ▼
PomodoroTodoMcp：独立 QCoreApplication 辅助程序
    │ 私有本地通信协议 / QLocalSocket
    ▼
主应用内 McpLocalServer + McpToolDispatcher
    │ 在现有服务所属线程内执行
    ▼
TaskManager / StatisticsService / KnowledgeGapService / CategoryManager
    │
    ├─ SQLite
    └─ 现有变化信号 → QML 刷新
```

1. 辅助程序采用 C++17、Qt Core/Network，随 `.app` 分发。运行时不额外要求 Node.js/Python；不链接 SQLite、不初始化业务服务、不获取主应用单实例锁。
2. MCP stdio 采用 UTF-8、逐行 JSON-RPC；日志写 stderr，stdout 只输出协议消息。外部传输遵循 [MCP stdio 规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)。
3. 主应用使用独立本地端点，不扩展现有 `activate\n` 协议。两个进程共用 `src/mcp/common` 中同一份静态工具契约；辅助程序的代码放 `src/mcp/helper`，主应用接入代码放 `src/mcp/bridge`。辅助程序负责协议生命周期、工具发现、转发和超时，权限判断与业务执行只在主应用完成。CMake 显式列出各目标源码：helper 只编入 helper/common，bridge 只编入主应用，禁止通过递归 glob 把业务依赖带进辅助程序。
4. 私有协议单独携带 `bridgeProtocolVersion`、连接认证、请求编号与应用会话编号；不能把私有通信格式宣传成另一个标准 MCP transport。
5. 主应用离线或未启用接入时，初始化和 `tools/list` 仍成功，始终公布固定的 10 个工具，不因权限隐藏工具。状态查询与数据调用按需尝试连接，成功后复用连接；断线后下次调用重新连接，不自动重放在途写入。无端点时数据调用返回 `APP_UNAVAILABLE`，状态工具仅报告“未连接”，不能猜测是应用没启动还是接入关闭。主应用上线后无需客户端刷新工具清单；不依赖轮询、动态清单或变化通知。
6. 主应用数据库初始化失败、启动恢复未结束时不发布可用端点；正常退出时先拒绝新请求、清理队列和连接，再关闭服务与数据库。辅助程序 stdin EOF 后自行退出，不结束主应用。
7. 主线程只进行有界请求处理，不使用阻塞式 socket 等待、嵌套事件循环或 `processEvents()`。服务只在自己的线程使用现有 SQLite 连接。

### MCP 兼容目标

首版支持 `2025-11-25` 与 `2025-06-18` 的 stdio 和 tools 公共子集，**不宣称它们是最新协议**。客户端请求这两个版本之一时返回原版本，否则按协商规则返回首选 `2025-11-25`，由客户端判断是否继续；不得回显尚未支持的版本。
处理 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call` 与取消通知。声明 `tools: {}`，不声明 `listChanged`，不发送 `notifications/tools/list_changed`；不声明 resources/prompts/sampling/远程 HTTP。初始化、未知方法、通知不回复与退出按 [生命周期规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) 验证。两个版本分别验证握手与工具调用，交付时记录实际客户端名称和版本。

## 首版工具与数据契约

所有工具使用 `pomodoro_` 前缀，英文稳定标识、中文说明。工具参数采用显式 JSON Schema，拒绝未知字段与类型隐式转换。工具列表的 schema 与执行校验共用契约定义，不能只校验清单、不校验调用。输入/输出 schema 不写 `$schema`，只使用 draft-07 与 2020-12 均支持的公共关键字（如 type、properties、required、additionalProperties、enum、数值/长度边界、items），不用方言专属关键字；兼容官方 TS SDK 1.29.0 默认 AJV 校验器及两版协议。

| 工具 | 核心输入 | 返回与服务映射 |
| --- | --- | --- |
| `pomodoro_get_status` | 无 | 应用连接状态、版本、可用权限、逻辑今日、时区、`day_start_hour`、`app_session_id`、当前阻断原因；连接不可用时只返回已知状态，不编造应用值 |
| `pomodoro_list_categories` | 无 | 科目编号/名称/颜色；`CategoryManager::getAllCategories` |
| `pomodoro_list_tasks` | `start_date`、`end_date`、可选完成状态、`limit` | 日期区间内任务，按日期/显示顺序/编号稳定排序；任务字段、预计分钟、实际有效投入、`state_token`；排除待撤销删除项 |
| `pomodoro_get_task` | `task_id` | 单任务完整数据及 `state_token`；`TaskManager::getTask` |
| `pomodoro_get_focus_summary` | `start_date`、`end_date` | 总有效专注秒数、展示分钟、有效番茄数、每日与科目分布、区间是否完整；使用 StatisticsService 聚合 |
| `pomodoro_list_knowledge_gaps` | 状态、可选科目/搜索词、`due_state`、可选 `due_from` / `due_to`、`after_id`、`limit` | 缺口编号、标题、排期、状态、关联任务及 `has_more` / `next_after_id`；列表不默认输出长详情；在 KnowledgeGapService 补充有界查询，保留现有 `listGaps` 兼容接口 |
| `pomodoro_create_task` | `title`、`date`、可选 `category_id` / `estimated_minutes` / `notes`、`app_session_id`、`idempotency_key` | 返回 `created_task_id`、`current_state`（present/deleted/pending_delete）、`task`（当前数据或 null）；首次成功为 present，重放使用原编号重读现状，不重复创建 |
| `pomodoro_update_task` | `task_id`、`expected_state_token`、`app_session_id`、待修改字段 | 仅允许 `title`、`category_id`、`estimated_minutes`、`notes`；在当前状态上合并字段调用 `updateTask`，缺省字段不变 |
| `pomodoro_reschedule_task` | `task_id`、`date`、`expected_state_token`、`app_session_id` | 日期已相同则不写；否则调用 `moveTaskToDate`，沿用目标日排序规则 |
| `pomodoro_set_task_completed` | `task_id`、布尔 `completed`、`expected_state_token`、`app_session_id` | 状态已相同则不写；否则调用 `setTaskCompleted`，不用“切换”操作 |

### 日期、查询与结果

- 日期严格使用有效的 `YYYY-MM-DD`。写入日期必须明确；AI 先通过状态工具获取逻辑今日再换算相对日期，服务端不猜自然语言。任务列表和专注统计的日期区间含首尾，首版最多 31 个逻辑日，更长区间分段查询；缺口的到期日筛选按下文规则和每页条数限量，不受 31 天限制。
- 每个请求只获取一次逻辑今日与日界设置，多段聚合共用；统计附带 `as_of` 和 `is_partial`，当前未结束日不伪装成完整日。不输出本周对上周整周的自动涨跌结论。
- 秒是统计精度，分钟沿用现有展示口径，不把番茄个数换算成真实投入；有效门槛、休息排除与跨日归属沿用现有规则。查询失败返回错误，不能变成零时长或空列表。
- 任务列表默认 50、最大 100 条，不提供游标或数据修订号。服务层按筛选条件读取 `limit + 1` 条检测溢出，待删过滤在限量之前完成；超过上限返回 `RESULT_LIMIT_EXCEEDED` 并提示缩小日期/筛选范围或提高 limit，不返回假装完整的截断列表、不先全表加载。这是 MCP 的有界查询限制，不等同于 UI 搜索“分批加载、最多 10000 条”的规则；31 天并不能保证行数少于上限。
- 知识缺口增加 `due_state: any|scheduled|unscheduled`（默认 any）；`due_from`、`due_to` 是可选且含首尾的有效日期，任一提供时只匹配有到期日条目，二者同时提供需 from ≤ to；unscheduled 与日期边界同时提供属于参数错误。逾期、今天、未来分别使用逻辑今日前一天、逻辑今日、后一天作为边界；未排期明确用 unscheduled，不能用空日期猜测。
- 日期筛选不能拆开超过 100 条的未排期缺口，因此仅缺口列表增加简单编号续查：`after_id` 默认 0，非负整数，按 `id > after_id ORDER BY id ASC LIMIT limit + 1` 在服务层执行，limit 默认 50、最大 100。返回前 limit 条，`has_more` 表明是否还有条目，`next_after_id` 有后续时为最后返回编号，否则为 null；继续查询保持原筛选条件。只使用单调编号，不引入不透明游标、修订号或快照。并发新建的较大编号可在后续页出现；已越过编号的条目若被改到筛选范围内，需从 0 重查，契约明确不承诺跨页快照一致性。即使所有缺口都未排期、同科目、同名，也能逐页查询。
- 标题、备注、预计分钟上限读取 TaskManager 常量。JSON 数字必须是规定范围内整数；非法日期、科目不存在、任务不存在都明确报错。任务查询支持同名任务，写入只认编号。
- 不直接把内部 QVariantMap 原样对外发布；适配为固定输出 schema。必要的限量查询与显式结果接口补在原服务层，MCP 调用通过返回值取得错误，不能发共享 `operationFailed` 污染当前页面。原 QML 接口保留兼容包装，由包装层按原规则发失败信号；成功写入仍发原变化信号。不得用 `QSignalBlocker` 屏蔽整个服务，也不得在 MCP 层补写 SQL。
- 成功结果同时返回满足工具 `outputSchema` 的 `structuredContent` 和一个完整序列化同一 JSON 的 TextContent，`isError: false`。文本必须包含编号、会话和状态令牌，不能只写简短摘要；符合 [MCP tools 规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)的文本兼容建议。
- 工具错误使用 `isError: true`，仅在 TextContent 中返回完整错误 JSON：`{code, message, retryable, next_action}`，可附 `details`，不提供 `structuredContent`，避免成功 schema 校验吞掉业务错误。`APP_BUSY` 的 details 必须带全部命中的阻断原因及对应来源（稳定来源标识、必要的任务编号），next_action 给出结束编辑/拖动、撤销或等待删除、等待恢复完成等具体动作。日期格式、字段类型、超范围等工具参数校验错误走这条路径；JSON 解析错误、未知方法/工具或不满足 `tools/call` 请求外壳的消息走协议错误。已知写工具无权限时返回 `PERMISSION_DENIED`，不能冒充未知工具。
- 首版稳定业务错误码：`APP_UNAVAILABLE`、`MCP_DISABLED`、`PERMISSION_DENIED`、`APP_BUSY`、`NOT_FOUND`、`VALIDATION_ERROR`、`STATE_CONFLICT`、`RESULT_LIMIT_EXCEEDED`、`SESSION_EXPIRED`、`IDEMPOTENCY_CONFLICT`、`WRITE_CAPACITY_REACHED`、`DATABASE_ERROR`、`OUTCOME_UNKNOWN`、`IPC_PATH_INVALID`。数据库错误不泄漏路径或原始 SQL；`MCP_DISABLED` 只用于主应用明确报告已关闭的场景，端点不可用时不猜测原因。

### 错误重试契约

`retryable` 明确表示“客户端可以在不改变请求、不等待外部状态确认、无需用户操作的情况下自动重发”，不表示“这个功能以后还能不能再调用”。首版不提供这种自动重发许可，以下业务错误一律为 false；接入控制器和辅助程序不根据错误码自发循环调用工具。用户完成操作或客户端确认前置条件改变后，可以按 next_action 发起后续调用，这不属于自动重发失败请求，也不要求为已授权动作再次弹确认。

| code | retryable | 固定 next_action 语义 |
| --- | --- | --- |
| APP_UNAVAILABLE | false | 请启动应用并启用接入，确认状态可用后再调用；不循环探测或自动启动 GUI |
| MCP_DISABLED | false | 请在应用中启用接入，再读取新的会话 |
| PERMISSION_DENIED | false | 请检查接入及任务写权限；未授权前不得重复写入 |
| APP_BUSY | false | 按下表具体原因处理；多个原因全部解除后再调用，不自动重发 |
| NOT_FOUND | false | 重新查询并确认任务编号，不按同名任务自行替换目标 |
| VALIDATION_ERROR | false | 按字段错误修改参数再调用；不能原样重发 |
| STATE_CONFLICT | false | 重新读取当前任务，核对操作目标后使用新的状态令牌 |
| RESULT_LIMIT_EXCEEDED | false | 缩小任务日期/筛选范围或在上限内提高 limit；响应字节超限则减少返回条数 |
| SESSION_EXPIRED | false | 重新获取会话并核实原操作结果；不能只替换会话后重放创建 |
| IDEMPOTENCY_CONFLICT | false | 核对是否误用了旧键；原请求重试恢复原参数，确属另一条有意创建才使用新键 |
| WRITE_CAPACITY_REACHED | false | 当前会话不接受新创建；先核实在途创建，再由用户关闭并重新启用接入建立新会话 |
| DATABASE_ERROR | false | 普通查询/未提交写入：查看应用错误，确认数据库可用后再调用；已提交创建的读回失败使用下文专门提示，绝不能显示“创建失败” |
| OUTCOME_UNKNOWN | false | 先查询核实结果；同一会话的创建沿用原键核实，不换新键再次创建；跨会话无法核实则说明结果未知 |
| IPC_PATH_INVALID | false | 停止连接并查看本机路径诊断；当前版本无法在该无效路径启用接入，不自动换目录或重复连接 |

| APP_BUSY 原因 | retryable | next_action 补充 |
| --- | --- | --- |
| editing | false | 完成或取消指定编辑入口后再调用 |
| dragging | false | 完成或取消当前拖动后再调用 |
| pending_delete | false | 等待该任务删除提交，或在应用中撤销删除，再核实任务状态 |
| backup_restore | false | 等待备份/恢复阻断结束并确认数据库可用；若会话变化，重新获取并核实原操作 |
| shutting_down | false | 等应用退出后手动重开并重新获取会话，不向退出中的应用重发 |

协议错误与断线没有 retryable 字段时也不视为 true；未取得响应的写入沿用 OUTCOME_UNKNOWN 的核实规则。上述字段只供客户端参考，不能声称能强制外部客户端遵守退避；服务端仍执行既有连接、队列与权限限制。

### 字段的缺省、清空与设值

| 字段 | 创建时缺省 | 更新时缺省 | 明确赋值规则 |
| --- | --- | --- | --- |
| `title` | 不允许，必填 | 保持原值 | 字符串，按现有服务规则规范化，规范化后为空则拒绝 |
| `notes` | 空字符串 | 保持原值 | `""` 清空，非空字符串设值，超过服务常量上限拒绝 |
| `estimated_minutes` | `0`，未设置 | 保持原值 | 整数 `0..kMaxEstimatedMinutes`；`0` 清除预计用时，负数/小数/超限拒绝 |
| `category_id` | `0`，无科目 | 保持原值 | `0` 清除科目，正整数必须指向现有科目，负数拒绝 |

写工具所有参数的显式 JSON `null` 均拒绝，不能借它表达“不改”；`update_task` 至少提供一个可修改字段。日期和完成状态分别走独立工具。适配层保留字段是否出现的信息，在当前任务上合并，不能把缺省值转换成空字符串或零。现有 C++ 服务的 null QString / 负预计分钟哨兵不直接暴露给 MCP；预计分钟服务层会夹紧，MCP 必须在调用前严格拒绝超限输入。

## 授权、并发与失败处理

### 授权与用户可见性

1. 默认关闭。设置 → 通用增加“外部 AI 接入”：启用/关闭接入、允许任务写入（默认关闭）、连接状态、复制辅助程序路径、最近操作反馈与当前阻断原因。阻断信息和 `get_status` 共用同一 C++ 状态源，区分“所有新写入受阻”与“仅任务 #N 待删除”，通过信号更新。复用现有设置组件与 Theme；不新建整页或聊天入口，不设置暗示逐客户端撤销能力的“撤销凭据”按钮。
2. 用户开启写入后，白名单任务操作不再逐条强制弹窗；外部客户端仍可按自己的策略询问。固定工具清单仅公开能力描述，不代表授权；主应用在每次实际执行时检查当前接入状态和写权限，不能信任工具 annotations，也不能只信辅助程序的检查结果。
3. 同用户本地 socket 配合随机接入凭据认证。运行目录设为 0700、凭据文件设为 0600；macOS 需验证实际 peer UID，不能仅假设 `UserAccessOption` 足够。平台身份检查放在 `src/platform/macos`。路径须检查所有者、符号链接与端点冲突，辅助程序不得删除服务端端点。
4. 凭据由主应用生成，辅助程序读取；不放进命令行、工具结果、客户端示例、日志、普通偏好或备份。发现文件只在启用接入后发布，不包含业务数据；关闭接入时停止监听、关闭已有连接、取消排队请求、移除发现/凭据文件并使会话失效。重新启用时生成新凭据与会话。
5. 首版信任边界是“用户授权的同一 macOS 账户”，不是每个 AI 客户端独立身份；同用户进程可读取凭据，`clientInfo.name` 只能显示、不能授权。需要逐客户端隔离时另做配对协议，不声称本版已提供。
6. 成功写入后沿现有信号刷新 UI，简短反馈写入设置中的接入状态区，不调用 `MainWindow.showToast` 或替换全局撤销提示。后者会提前提交待删除项，不能因 AI 操作剥夺用户剩余的撤销时间。
7. README 与接入说明改为准确的数据边界：“本地存储；用户启用外部 AI 接入后，所选客户端可能将返回数据发送到其模型服务。”辅助程序本身不调用模型 API。
8. 接入说明增加简短风险说明：任务备注、标题和知识缺口可能包含粘贴来的外部指令；模型可能把这些数据误当指令，尤其在已开写权限、客户端又不逐条确认时，可能错误创建、改名、改期或标记完成。首版没有删除工具仍不等于没有影响。文本保持业务数据字段，不拼入工具描述或系统指令；文档说明可保留只读或使用客户端写入确认，并明确 JSON 封装、白名单与 UUID 校验不能消除提示注入，不新增本轮范围外的审批流程。风险依据见 [MCP 官方说明](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/)。

### 本地路径与 socket 长度

- 在 `src/mcp/common/McpPaths.*` 统一计算路径，两端在计算前都显式设置与主应用一致的 organizationName/applicationName：`PomodoroTodo` / `PomodoroTodo`。不能让辅助程序用自身可执行文件名派生另一个 AppDataLocation。
- 生产根目录固定为 `QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)` 下的 `mcp`，socket 使用最短固定文件名 `s`，即 `<AppDataLocation>/mcp/s`；凭据为同目录 `key`，发现信息为 `endpoint.json`。目录与文件权限沿用 0700/0600。使用绝对路径，双方校验发现信息的端点与共同计算结果一致，不能接受任意外部端点覆盖。
- 路径构造不创建目录；主应用启用时才创建并校验所有者/符号链接。根路径为空、非绝对、含 NUL 或 socket 路径超长时返回 `IPC_PATH_INVALID`，不截断、不静默换目录、不尝试 listen/connect。helper 初始化和静态工具发现照常成功，get_status 报未连接并带路径错误原因，数据调用返回对应错误；主应用设置区显示接入失败而非终止整个应用。
- macOS 的 `sockaddr_un.sun_path` 是 104 字节数组，不是可以无条件放 104 个字符。本项目为结尾 NUL 保留一字节，按 `QFile::encodeName(absoluteSocketPath).size() + 1 <= 104` 校验，允许的路径载荷至多 103 字节；不能用 QString 字符数代替。依据已核对的本机 SDK 头文件及 [Apple un.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h)。common 内统一定义容量，macOS 编译时用系统头文件断言容量相符。
- 超长错误 details 只返回 `reason: path_too_long`、实际字节数及允许字节数；完整本机诊断路径只在应用设置区展示，不夹带凭据。测试注入的绝对路径也经过同一校验，不使用随机长目录碰运气；测试边界在隔离目录和纯路径计算用例中完成，不改用户目录。

### 编辑与待删除状态协调

- 阻断覆盖 TodayTaskView、WeekPlanView、DashboardView、TaskToolsDialog 内的 4 个 EditTaskDialog、今日/本周/仪表盘的 3 处行内重命名，以及今日拖动排序、本周拖动改期。编辑或拖动活动期间，外部新写入统一返回 `APP_BUSY`，避免改动另一任务也触发整表刷新、销毁输入行或使拖动集合过期。2 个 AddTaskDialog 不持有已有任务快照，不登记全局阻断；新增内容不能被列表刷新重置，并单独验证新增与 AI 写入并行可用。
- 编辑已有任务时，在同一个同步调用内先向 C++ 协调服务登记编辑阻断，再按编号读取最新任务用于回填；不能使用列表缓存作为最终编辑数据。读取失败则释放登记并停止打开。每个入口用独立登记标识，记录发起 `QObject`、原因和来源；C++ 以 `QPointer` 跟踪对象并连接 `destroyed` 自动释放，作为漏掉 QML 清理回调的兜底，不能持有悬空裸指针。
- 显式释放使用幂等的统一结束函数，覆盖保存成功、取消、Esc、外部点击关闭、页面退出及组件销毁；Popup 进入隐藏流程时（`aboutToHide`）也调用，不能只依赖 `onClosed`。拖动从开始登记到提交/取消完成后释放，不可在松手写库之前先释放。对象销毁兜底不代替“对象仍存活但弹窗已关闭”的正常释放；不得用固定超时清理仍在输入的登记。
- `APP_BUSY` 与状态区共同区分 `editing`、`dragging`、`pending_delete`、`backup_restore`、`shutting_down`，每项带影响范围、来源标识和必要的任务编号。编辑/拖动说明结束当前操作后重试，待删说明等待提交或在应用中撤销，恢复说明等待恢复结束，退出说明重开应用后重新获取会话。界面不显示凭据或对象地址，也不能只报一个无来源的“忙碌”。
- 行内编辑及拖动期间，已经排队或随后到来的列表刷新只记录待刷新状态，不重建当前行。开始时就处理既有 RefreshCoalescer 回调与完成动画延后刷新，结束后统一补刷；原有因待删/切页取消拖动的路径同步释放登记。编辑提交使用最新的未修改字段，不能用旧 modelData 回填科目或日期。QML 同步交互状态，最终授权与写入前检查在 C++。
- MainWindow 的待删除任务编号同步到 C++ 协调服务，创建隐藏状态时同步登记，撤销、提交完成/失败时同步解除。任务列表查询在限量前排除该编号，单任务查询和以该任务为目标的写入返回 `APP_BUSY`，不能让 AI 对已从界面隐藏的任务报告操作成功。
- 待删任务不阻断其他任务的操作，不由 MCP 提前提交删除。现有规则要求特定路径（新的删除、替换提示、备份、恢复、退出、补录/修改记录等）先提交，不能扩大成“任何写入前都提交”。历史专注统计在撤销窗口内保持持久化口径；不因为任务暂时隐藏而过滤历史会话。

### 本机授权策略与备份

- **固定选择不纳入恢复管理**：`mcp/` 既不加入 `AppSettings::ownedSettingGroups()`，也不加入 `BackupOperations::isLocalSettingKey()`。凭据仍是独立文件，不进入 QSettings；本机策略由接入控制器读写。
- 当前 `applySettingsSnapshot` 会先删除所有 `isLocalSettingKey` 键；`backup/` 能恢复回来依赖 `settingsWithLocalBackupPolicy` 对该前缀的显式搬运，不能只把 mcp/ 加入识别函数就照搬其结论。本方案保持这两个恢复函数的生产行为不变，让恢复/回滚既不删除也不写入 mcp/；不为 MCP 扩展搬运前缀。
- 备份导出不包含 `mcp/`；恢复输入忽略任何携带的 `mcp/` 键，不能由旧备份或手工构造的备份改变接入/写权限。
- 恢复成功及失败回滚后，mcp/ 现有键和值均保持不变；接入控制器重新同步状态时不得因不在 AppSettings 注册表内而写回默认关闭。恢复期间暂停数据访问并轮换会话、清理创建去重记录；恢复结束后重新读取状态。失败后若数据库不可用，继续拒绝数据访问。
- 验收同时覆盖导出、恢复输入和失败回滚，不能只证明备份里没有凭据文件。

### 重试与并发：首版采用应用会话内保证

- 每次写入携带 `app_session_id`，只有 `create_task` 还要求 UUID v4 `idempotency_key`。接受标准 8-4-4-4-12 连字符形式，十六进制大小写均可，版本位必须为 4，变体位为 8/9/a/b；不接受花括号、URN、前后空格、nil 或其他版本。schema 用公共 pattern 关键字约束并在执行端复核，转为 16 字节后比较；不能只依赖不同校验器对 `format: uuid` 的实现。格式依据见 [RFC 9562 §5.4](https://www.rfc-editor.org/rfc/rfc9562.html#section-5.4)。
- v4 格式不能证明随机性，也不能阻止模型反复使用同一个合法 v4 示例。工具说明仍要求每次有意创建生成新随机键、同次重试沿用原键；文档示例不提供可直接照抄的固定 UUID。会话由应用生成，启动、恢复开始、关闭接入时轮换并清理旧状态，辅助程序不能自动换会话重放。
- **创建去重由主应用完成**，按会话、幂等键及规范化创建参数摘要登记。参数缺省先按契约补齐再计算摘要。同键同参数返回原任务编号并重读当前数据，同键不同参数报 `IDEMPOTENCY_CONFLICT`；JSON-RPC 请求编号不能当幂等键。工具说明明确：同一次创建重试沿用键，另一条有意创建（包括同名同内容）必须用新键，禁止反复复制示例 UUID。
- 创建顺序：校验请求类型/字段结构及身份、当前权限、会话、恢复/退出阻断 → 查已成功的创建记录 → 新请求的编辑/拖动阻断、容量与业务校验 → 调用服务并登记成功编号。`APP_BUSY`、校验失败等不登记，忙碌解除且会话未变时原键可以重试；备份恢复或重启已轮换会话时，仍须重新核实。
- 重放命中后，任务仍存在则返回原 `created_task_id`、`current_state: present` 和重读的当前 task（含新状态令牌）；已删除则返回同一编号、`current_state: deleted`、`task: null`；正在撤销删除窗口则返回 `pending_delete` 与 null，不暴露暂时隐藏的内容。后三者都表达“原创建已成功”，不能因任务消失而再次创建。数据库查询失败另报 `DATABASE_ERROR`，不把读失败说成 deleted，也不清除去重记录；重放不是恢复旧任务内容。
- 每个会话最多 10,000 条记录，登记表只保留定长 UUID 键（16 字节）、规范化参数的 SHA-256 摘要（32 字节）和任务编号（qint64），会话编号保存在表级。禁止缓存标题、备注、参数原文、任务 JSON 或完整响应，删除“每条 64 KiB”的缓存设计。容量满只拒绝新的创建，重复键仍可重读当前数据，其他目标状态工具不受容量影响。调用创建前预留登记槽，成功后填写编号；失败撤销预留，不留下失败结果。关闭再启用可建立新会话，旧请求失效。
- 编辑、改期、设置完成状态不登记去重键。顺序固定为：参数结构与业务值校验 → 身份/权限/会话及恢复/退出/编辑/拖动/目标待删检查 → 读取当前任务 → 所有显式请求字段已达到目标则返回当前数据，不写库、不发变化信号 → 否则校验 `expected_state_token` 再执行。缺省字段不参与目标比较。只在不产生修改时允许忽略过期状态令牌，发生实际修改仍须通过并发检查。
- 改期日期已相同必须在调用 `moveTaskToDate` 前返回。现有该方法会重写 `display_order`，不能把直接重调视为无副作用重试。设置完成、编辑达到目标时同样不再调用写服务。新写入保持应用主线程串行，实际执行前重查权限和阻断，不能只在接收时检查。
- `state_token` 根据当前会话、任务编号、标题、科目编号及持久化科目文本、日期、完成状态、预计分钟和备注生成；排除实际投入、番茄累计等派生统计。预计分钟变化必须使令牌失效。读取、目标比较、状态校验与提交之间不允许事件循环重入。
- `createTask` 成功后立即登记真实编号与参数摘要；同一会话辅助程序崩溃、断线或应答丢失后可用原键取得原编号及当前状态。首次提交后重读失败，或重放已成功记录时重读失败，都返回 `DATABASE_ERROR`、`retryable: false`，details 必须带 `{created_task_id, creation_committed: true}`，并保留登记。message 明确“任务已创建，读取当前数据失败”，next_action 固定为“确认数据库可用后，用原键重试以取回数据，不要换新键”；不能把错误描述成创建未提交。未知是否提交时不编造编号，按 OUTCOME_UNKNOWN 处理。其他三个工具按目标状态重试。开始执行前取消不写，已提交后取消不能声称回滚。
- 若主应用崩溃发生在提交与应答之间，新进程的会话已改变，旧请求返回 `SESSION_EXPIRED`；**不承诺跨主应用崩溃的恰好一次执行**。桥接器不自动更换会话和键重试；客户端先查询核实，无法核实时报 `OUTCOME_UNKNOWN`，不能凭同名任务认定结果。
- 不为首版增加业务数据库迁移。若未来要求创建任务跨重启自动重试且不重复创建，需引入与业务写入同事务的持久命令记录，并同步备份恢复契约，不能拿单独 JSON 日志冒充原子性。

### 恢复、连接与资源限制

- 以 `BackupService::operationBlocksUi()` 为现有备份/恢复阻断依据，不能把所有 `busy()` 一律解释为不可读写。执行前和恢复开始时双重处理：队列中的数据请求失败退出，恢复期间只允许连接状态查询；静态工具发现仍由辅助程序提供。恢复结束后重新获取会话与任务状态。
- 首版限制：单请求 64 KiB、单响应 1 MiB、同时连接最多 8 个、每连接排队最多 16 个请求。响应上限按完整序列化消息计算，包含结构化数据与 JSON 文本两份内容；查询超限返回 `RESULT_LIMIT_EXCEEDED`，写入前保证成功响应在大小预算内且定长登记槽可用，不能提交后才截断关键编号。数量与字节上限同时生效，半包、粘包、无换行输入和慢读端不能导致无限缓存。
- 连接超时 2 秒、握手超时 5 秒、工具等待上限 10 秒；主应用执行前检查截止时间，过期未执行请求直接拒绝。已提交但失去应答时不盲目重发：创建保留原键核实，目标状态操作重读或按目标重试；应用会话变化时拒绝旧写入，不能自动替换令牌。
- 按请求编号路由返回，拒绝同连接重复的在途编号；未知通知忽略且不回复。辅助程序异常退出只断开该连接，不终止计时或主应用。
- 主应用与辅助程序私有协议版本不兼容时明确提示重启主应用/客户端。部署后旧进程可能仍在运行，不能假设磁盘上的新版本等于运行版本。

## 文件边界与分阶段实施

### 预期文件职责

以下按职责列出实施文件；阶段 1、2 已落地的文件见各自实施记录。后续涉及 QML 时使用 `qt-qml`、`qt-ui-design` Skill，涉及 CMake 时使用 `qt-cmake-project` Skill，沿用现有组件与分层；这是实施约束，不是阶段待办项。

| 文件/目录 | 职责 |
| --- | --- |
| `src/mcp/helper/main.cpp` | 无 GUI 辅助程序入口与退出 |
| `src/mcp/helper/McpStdioServer.*` | MCP 初始化、消息帧、请求路由、输出纪律 |
| `src/mcp/helper/McpBridgeClient.*` | 连接主应用、认证、超时与私有版本协商 |
| `src/mcp/common/McpContracts.*` | 共享 schema、消息边界和私有协议类型，不依赖业务单例、SQL 或 QML |
| `src/mcp/common/McpPaths.*` | 统一应用身份常量、绝对端点/凭据/发现文件路径与字节长度校验；路径计算无写盘副作用 |
| `src/mcp/bridge/McpAccessController.*` | 本机接入策略、凭据、会话与连接生命周期；只编入主应用 |
| `src/mcp/bridge/McpLocalServer.*` | 主进程端点、认证、连接与排队上限 |
| `src/mcp/bridge/McpToolDispatcher.*` | 白名单、参数/状态校验、服务调用与错误转换 |
| `src/mcp/bridge/McpCreateRegistry.*` | 定长 UUID/摘要/任务编号登记，不缓存响应 |
| `src/services/TaskInteractionCoordinator.*` | 编辑/拖动登记、QObject 销毁兜底、待删编号与阻断原因；不依赖 MCP 协议或具体 QML 类型 |
| `src/platform/macos/MacLocalPeerIdentity.*` | 获取本地 socket 对端 UID，隔离平台调用 |
| 现有 TaskManager、StatisticsService、KnowledgeGapService | 必要的限量查询及可靠错误返回，保留 QML 契约 |
| `src/main.cpp` | 显式依赖装配、启动就绪与退出顺序 |
| `qml/components/settings/SettingsGeneralPage.qml` | 接入开关与状态，沿用现有设置组件 |
| 现有 4 个编辑弹窗、3 处行内重命名、2 处拖动及 MainWindow 装配 | 同步交互/待删状态、同步重读、延后刷新；2 个新增弹窗只验证并行输入不丢失，不登记阻断 |
| 现有备份服务及其测试 | 保持 mcp/ 不在两份设置识别名单，验证导出/恢复/回滚均不碰本机策略；不扩展恢复搬运逻辑 |
| `CMakeLists.txt`、`cmake/DeployLocalApp.cmake` | 辅助程序目标、包内复制依赖与 staging 校验 |
| `tests/McpProtocolTests.cpp`、`McpServiceTests.cpp`、`McpIntegrationTests.cpp` | 协议、业务边界、双进程离屏测试 |
| `tests/qml/tst_mcp_settings.qml` 及相关任务交互用例 | 设置、焦点、编辑竞态、行内刷新与撤销窗口 |
| `tests/mcp-sdk/` 下的 package.json、package-lock.json 与验证脚本 | 独立可选 SDK 兼容验证，锁定 SDK 1.29.0 及依赖，不注册到默认 CTest |
| `.gitignore` | 已在阶段 1 添加 `/tests/mcp-sdk/node_modules/`，避免安装依赖污染未跟踪文件和提交 |
| `cmake/CheckMcpHelperLinks.cmake` | 阶段 1 新增的链接门禁脚本：读取辅助程序实际动态库依赖，出现 Qt Gui/Sql/Widgets/Concurrent/Qml*/Quick* 即失败 |
| `docs/MCP接入.md`、`docs/业务规则.md`、`README.md` | 接入入口、边界、错误排查与数据流向 |

### 阶段 1：文件框架与契约冻结

- [x] 以本次已核对的 `71f511c` 为起点；实施时若 HEAD 改变，只补查后续差异，不重复把 046 写成未落地工作。
- [x] 先创建所需类的声明、导入和最小构建目标，不混入数据查询或写入。
- [x] 将本文已定的 10 个静态工具、字段语义、结果分支、错误码、私有协议版本和权限/会话规则编码为共享契约，记录目标客户端实际版本。
- [x] 将已定的错误码/APP_BUSY 原因、retryable 和 next_action 映射及 UUID v4 校验编码进公共契约；不由调用点自由决定是否自动重试。
- [x] 按 common/McpPaths 的既定方案区分生产/测试路径，校验本机字节上限；测试不能默认连接生产端点。
- [x] 在创建 SDK 验证工作区之前为 `.gitignore` 添加 `/tests/mcp-sdk/node_modules/`，用 `git check-ignore` 验证该目录被忽略；只提交脚本、package.json 和锁文件，不提交 node_modules。
- [x] 验证框架可编译；helper 目标只包含 helper/common 并链接 Qt Core/Network，不引入 bridge、services、Qt Sql 或 QML；主应用编入 bridge/common 与已有服务。

**产物**：可编译框架与契约，无真实业务数据访问。

#### 阶段 1 实施记录（2026-09-17）

**落地内容**

- `src/mcp/common/McpContracts.*`：10 个工具的名称、中文说明、输入/输出 schema、读写与会话标志；协议版本协商；私有协议版本 `1`；资源与查询上限；14 个错误码与 5 种阻断原因的名称、`retryable`（全部 false，逐项写出）、`next_action`；错误对象与 tools/call 结果封装；按公共关键字子集执行的参数校验器、语义校验、默认值补齐；严格日期与 UUID v4 解析。
- `src/mcp/common/McpPaths.*`：应用身份常量、`<AppDataLocation>/mcp` 下的 `s` / `key` / `endpoint.json`、按 `QFile::encodeName` 字节数校验 socket 路径（`sun_path` 容量在编译期对照系统头文件断言）、不含完整路径的错误 details。
- 框架类（只有职责说明、导入与构造函数）：helper 侧 `McpStdioServer`、`McpBridgeClient`；bridge 侧 `McpAccessController`、`McpLocalServer`、`McpToolDispatcher`、`McpCreateRegistry`（含定长登记项结构）；`src/services/TaskInteractionCoordinator`。需要端点的三个类只能从构造函数注入路径，没有默认生产路径。
- `src/mcp/helper/main.cpp`：阶段 2 之前不假装可用，stdout 不写任何字节，stderr 说明后以退出码 2 结束。
- `src/main.cpp` 改用 `McpPaths::applyApplicationIdentity()` 设置应用身份，取值不变，两个进程共用一处定义。
- `McpToolDispatcher.cpp`（只编入主应用）用 `static_assert` 核对契约里的标题/备注/预计用时上限、缺口优先级区间和编号上限与服务层一致。
- CMake：主应用加入 common/bridge 与协调类；新增 `PomodoroTodoMcp`（只含 helper/common，链接 Qt Core/Network）、`McpProtocolTests`、`McpHelperLinkGate`。新目标使用 `qt_add_executable`；原有目标写法（`add_executable`、QML 经 qrc）不在本阶段范围，未改动。

**阶段 1 冻结的细节**（计划正文未写到具体名字、这次定下的部分）

- 任务列表筛选字段为 `completion_state`（any/open/completed，默认 any）。缺口列表 `status` 必填（all/unresolved/open/scheduled/resolved），`search_text` 至多 100 个码点、空串等同不筛选，匹配标题、详情和结论。
- `app_session_id` 与 `idempotency_key` 同为 UUID v4；`state_token` 为 64 位小写十六进制。对外编号上限 2147483647，与服务层 int 编号一致。
- 状态查询输出 `connected`、`helper_version`、`bridge_protocol_version`、`unavailable_reason`（endpoint_unreachable/path_invalid/bridge_version_mismatch/authentication_failed/handshake_failed 或 null）、`path_error`、`app`（未连接时为 null）。阻断条目为 `{reason, scope, source, task_id, next_action}`，`scope` 取 all_data（恢复、退出）、all_writes（编辑、拖动）、task（待删）。
- 专注统计按天给 `day_state`（complete/in_progress/future）；创建结果另带 `replayed`；三个目标状态写工具返回 `{changed, task}`；缺口列表输出同时回显筛选条件与 `logical_today`。
- 输入 schema 一律 `additionalProperties: false` 并写出 `properties`；输出 schema 不写 `additionalProperties`，也不给存量数据设上限（见下方旧数据发现）。

**验证**

- `McpProtocolTests` 56 项全过（含数据行与初始化/清理），覆盖清单与命名、schema 关键字白名单与锚定、schema 与解析器对同一 UUID 结论一致、日期与 31 天区间、未知字段/null/类型/整数精度、默认值只补声明字段、码点计长、错误码与阻断原因的重试语义、提交后读失败的文案与 details、成功结果文本即完整 JSON、失败结果无 structuredContent、样例结果满足输出 schema、路径 103/104 字节与中文路径边界、无效根目录、身份校验、details 不含完整路径。
- 变异验证（改源码→确认对象文件重编→跑测试→还原并再次确认重编与全过）：去掉正则整体锚定、socket 长度按字符计、只校验组织名、只校验应用名、完全不校验身份，5 条均被测出。首轮“只校验应用名”没被测出，原因是用例同时把两个名字改错；已改为两个名字分别单独出错后再验证。
- 辅助程序实测：stdout 0 字节，stderr 输出说明，退出码 2；`otool -L` 只有 QtNetwork、QtCore 与系统库。链接门禁对主程序运行时报出 QtGui/QtSql/QtQml/QtQuick 等违规，对辅助程序通过，对不存在的文件报错。
- `git check-ignore` 确认 `tests/mcp-sdk/node_modules/` 被忽略、`tests/mcp-sdk/package.json` 不被忽略。
- 全量离屏回归 96/96 通过（原 94 项加 `McpProtocolTests`、`McpHelperLinkGate`），全量构建零告警。构建目录 `~/pt-audit` 沿用其缓存中的 Release 配置，避免整仓重编；阶段 1 不涉及部署。

**联调客户端选择**（2026-09-17）：主验收客户端确定为 Claude Code，当前记录版本 2.1.274。它支持本地 stdio，命令行方式便于记录工具发现、调用结果与失败行为，且不要求打开桌面客户端窗口，参见 [官方 MCP 文档](https://code.claude.com/docs/en/mcp)。阶段 2 使用固定版本 SDK 与隔离测试宿主验证，不提前配置真实客户端；Claude Code 实际联调仍在阶段 6，执行时记录实际安装版本和协商出的协议版本，不能将当前记录视为已验证兼容。两个协议版本分别由独立 SDK 用例覆盖，不要求一个客户端同时协商两版。其他已记录候选为 Claude 桌面版 1.49585.0、Codex CLI 0.154.0；ChatGPT 26.908.70816 与 VS Code 1.137.0 未核实 stdio 支持，不作为本版验收前提。

**偏离与待办**

- `src/platform/macos/MacLocalPeerIdentity.*` 未在阶段 1 创建：它没有需要先行冻结的契约，空文件只会是噪音；与本地端点一起在阶段 2 创建并测试。
- 阶段 1 发现的旧数据约束：v10 迁移按“预估番茄数 × 25”回填预计用时，存量值可到 2475 分钟，超过写入上限 1440。输出 schema 因此不设上限；**阶段 4 合并修改字段时，未提供的预计用时与备注必须传服务层“保持不变”的哨兵（负数 / null QString），不能把读到的旧值原样传回，否则会被夹紧成 1440，悄悄改掉用户数据**。目标状态比较也要按存量真实值进行。
- schema 的长度按码点计，`TaskManager` 按 UTF-16 单元计；阶段 4 执行时仍须按服务口径复核，不能只依赖契约校验通过。

### 阶段 2：通信与授权基础

- [x] 完成 stdio 消息处理、初始化、探测、未知方法、通知、取消与 EOF。
- [x] 完成本地端点、凭据、对端身份、私有版本协商、会话和资源限制。
- [x] 两端共用路径构造并分别在 listen/connect 前校验；覆盖 103/104 字节边界、中文路径及空路径，路径失败只关闭接入能力、不关闭应用，也不使静态工具发现失败。
- [x] 实现两个 MCP 版本的握手与固定工具发现，状态/调用按需连接；离线清单不失败、不依赖清单变化通知。
- [x] 完成本机 `mcp/` 策略、恢复/退出阻断与会话轮换基础；只读权限下手工调用写工具返回 `PERMISSION_DENIED`。
- [x] 通过测试宿主注入端点；生产 UI 尚未接入时保持默认关闭，不能临时发布无认证业务接口。

**产物**：固定工具发现与通信可用，业务数据尚未开放；权限、恢复和退出门禁可独立测试。

#### 阶段 2 实施记录（2026-09-17）

**落地内容与具体约定**

- `helper/McpStdioDevice` 使用非阻塞标准输入输出与 `QSocketNotifier`；`common/McpJsonStream` 统一处理 UTF-8 换行帧、半包/粘包、非法 JSON 与请求结构错误、半包期限和输入/输出缓存上限。日志只走 stderr，EOF 取消待处理请求并有界排空 stdout。
- `helper/McpStdioServer` 支持两版初始化、初始化完成通知、ping、固定 10 工具发现、工具参数校验、调用、取消、未知方法与重复在途编号拒绝。取消不回复原请求、不声称回滚；字符串编号与数字编号分别路由。初始化等待上限为 5 秒。
- `helper/McpBridgeClient` 按需读取受保护的发现文件与凭据，进行私有协议版本 `1` 握手；连接/握手/调用期限分别为 2/5/10 秒。主应用离线或路径无效不影响初始化与工具发现。断线仅让后续独立调用重连，不重放在途请求；已发送写请求失去应答返回 `OUTCOME_UNKNOWN`。状态工具在离线时返回完整、符合 schema 的状态对象。
- 私有通道采用 `hello` / `call` / `result` / `cancel` 四种换行 JSON 帧；内部关联编号为字符串，独立于外部 JSON-RPC 编号。调用携带 `remaining_ms`，服务端按接收时剩余预算建立单调时钟期限，在真正执行前复核。`GetStatus` 的私有结果只含应用侧状态，辅助程序补入连接状态、辅助程序版本与路径诊断，再生成公共契约要求的完整结果。
- `common/McpEndpointFiles` 负责目录、凭据和发现文件的所有者/权限/符号链接检查；主应用持独立 `QLockFile` 后才清理自己拥有的旧端点。目录 `0700`、凭据及发现文件 `0600`；使用系统随机源产生 256 位凭据，辅助程序只读取、不清理端点。`platform/macos/MacLocalPeerIdentity` 使用 `getpeereid` 拒绝无法确定身份或不同 UID 的连接。
- `bridge/McpLocalServer` 限制 8 个连接、每连接 16 个排队请求、64 KiB 请求、1 MiB 完整响应与输出积压；在主线程逐项调度，执行前检查期限并重新进入授权层，不使用阻塞等待或嵌套事件循环。
- **103 字节实测修正**：Qt 的 `UserAccessOption` 会先在额外临时目录绑定 socket，使合法的 103 字节最终路径也失败。现在先验证根目录 `0700`，使用 `NoOptions` 直接绑定，再把 socket 收紧为 `0600`；父目录在此之前已经禁止其他用户访问。103 字节实际连接成功，104 字节在 listen/connect 前拒绝。依据：[Qt 6.10.3 本地服务实现](https://github.com/qt/qtbase/blob/v6.10.3/src/network/socket/qlocalserver_unix.cpp)。
- `bridge/McpAccessController` 使用本机键 `mcp/enabled` / `mcp/writeEnabled`，均默认 false，关闭系统全局偏好回退。运行时授权由控制器管理，每次分发重新检查；保存失败不新增授权，撤销立即生效并报告持久化失败。关闭接入删除发现文件和凭据，关闭连接并轮换会话；恢复开始轮换会话、拒绝排队数据请求，状态查询仍允许。
- `main.cpp` 装配逻辑日期/时区/日界状态，连接 `restoreStarted`、`operationBlocksUiChanged`、`restoreCompleted` 和退出信号。同步恢复可能没有 UI 阻断状态变化，因此完成信号也负责释放阻断。退出时 MCP 先于数据库停止；执行中同步关闭接入时先断线再延迟析构，避免销毁当前调用栈。
- 业务处理器仍未安装，已授权的数据工具明确返回 `APP_UNAVAILABLE`，details.reason 为 `stage_not_ready`；只读权限手工调用有效写请求返回 `PERMISSION_DENIED`。没有读取业务数据、增加写工具实现或接入 QML 设置。
- `McpTestHelper` 与正式辅助程序共用入口和传输源码，但仅测试目标编入 `MCP_TEST_HOST`，强制接受显式临时目录，缺少目录即退出；生产辅助程序没有测试目录覆盖参数。集成测试使用临时端点、临时 INI 与测试状态提供器，既不连接生产应用，也不接触真实业务数据。

**验证记录**

- 构建沿用 `~/pt-audit` 的 Release 配置，`POMODORO_TODO_DEPLOY_LOCAL=OFF`；主应用、辅助程序、测试宿主及测试目标全部构建通过，零编译告警。
- 全量离屏回归 97/97 通过；`McpProtocolTests` 56 项、`McpIntegrationTests` 37 项、`BackupServiceTests` 52 项通过，辅助程序链接门禁通过。
- 集成覆盖离线发现/后上线、两版协商、错误结果无 structuredContent、完整 JSON 文本、权限撤回、旧会话拒绝、恢复/退出、设置写盘失败、凭据及版本拒绝、端点占用、符号链接/权限拒绝、103/104 字节及中文/空路径、取消、重复编号、排队/连接上限、半包与握手期限、工具超时、断线结果未知且不重发、EOF 与执行中关闭接入。
- 在现有备份测试中断言所有 `mcp/` 键均不导出、两种本机授权状态恢复后不变、失败回滚仍保留本机授权；业务备份实现及两份设置名单均未修改。
- 一次中间回归中，备份测试在既有 `autoBackupRespectsIntervalAndRetention` 已报 PASS 后超时；随后单独整组重跑 52/52、全量回归均通过，未复现，不能据此声称已定位其原因。

**保留给后续阶段**

- 阶段 3 安装真实只读处理器与交互协调，阶段 4 才安装任务写入。阶段 5 接设置界面与状态提示，阶段 6 才做包内复制、真实客户端联调与部署。
- 本阶段未执行 npm 安装或 SDK 联调，未改变三个候选 AI 客户端的配置；不把隔离宿主测试当作真实客户端验收。

### 阶段 3：只读工具与 UI 协调

- [x] 依次接入状态/科目、任务、专注聚合、知识缺口；每个模块验证后再接下一项。
- [x] 在原服务层补齐有界查询与显式结果接口；MCP 错误不发共享失败信号，禁止接入层写 SQL。
- [x] 完成任务范围溢出检测、缺口到期日/未排期筛选与 after_id 续查、逻辑日快照、固定输出、状态令牌和输出上限。
- [x] 用相同临时数据验证 MCP 与服务直接调用的统计值一致，区分查询错误与空数据。
- [x] 完成绑定 QObject 的登记及待删协调，接通 4 个编辑弹窗、3 处行内编辑、2 处拖动和 MainWindow；同步登记再重读，交互结束后补刷。2 个新增弹窗不阻断。
- [x] 在只读阶段就验证对象销毁自动清理、幂等结束、阻断原因、待删过滤、错误隔离、旧缓存及排队刷新竞态；离屏测试直接覆盖结束函数和对象销毁，不以 onClosed 投递为前提。门禁通过前不进入写入阶段。

**产物**：只读闭环与完整交互阻断可用；写工具尚未开放，不能用“设置界面以后再接”跳过阻断依赖。

**阶段 3 实施记录（2026-09-18）**：新增服务层显式读取结果、有界查询和只读分发器；交互协调器绑定 QObject 生命周期，同步登记再读取，页面退出及弹窗隐藏释放。任务列表在限量前排除待删项，旧预计分钟输出不夹紧。新增 McpServiceTests，补充编辑弹窗和行内编辑的新鲜数据/释放测试。`~/pt-audit` Release 全量构建通过；全量离屏 CTest 98/98 通过，包含 QML lint 与辅助程序链接门禁。未部署、未启动生产应用、未配置客户端、未提交。

### 阶段 4：任务写入

- [x] 先完成仅存 UUID/摘要/编号的定长创建登记表与统一检查，再依次开放创建、编辑、改期和设置完成状态；确保不保留标题、备注或 JSON 缓存。
- [x] 明确目标已满足时不写库、不发信号；复用现有事务与排序，覆盖同日期改期、同状态完成与同值编辑的无副作用重试。
- [x] 验证失败后原键可重试、同名新建用新键、v4 格式及非 v4 拒绝、原任务修改/删除/待删后的重放、状态冲突、断线与登记容量耗尽；已达到目标的操作仍须通过权限、会话及忙碌检查。
- [x] 注入创建成功后重读失败及重放时重读失败：断言 details 含真实 created_task_id 与 creation_committed、retryable 为 false，提示沿用原键；恢复读取后原键只取回现状，不新建任务。
- [x] 核对活动任务的编辑/改期/完成与当前 UI 是否等价；若依赖专门协调器，复用或下沉该逻辑，不能另写计时规则。

**产物**：四个写工具满足授权与业务边界，不隐式启动、暂停或结束计时。

### 阶段 5：设置与生命周期收尾

- [x] 复用设置组件完成启用/关闭、写权限、连接状态、路径复制、最近操作及具体阻断来源；状态区与 APP_BUSY 使用同一原因集合，不新增玻璃效果、撤销凭据按钮或动态清单。
- [x] 联验编辑/拖动/待删/恢复阻断与退出顺序；验证新增弹窗打开时仍可外部写入且输入不丢。反馈仅更新接入状态区，不顶掉撤销 Toast、不抢焦点。
- [x] 验证键盘焦点、读屏名称、明暗主题和 reduceMotion；沿用信号刷新，不轮询。
- [x] 验证备份不含 `mcp/`、恢复输入忽略伪造权限键、成功恢复与失败回滚都保留本机策略，并使旧会话失效。

**产物**：用户能启用、限制和关闭接入，各入口遵守统一阻断规则；备份不能覆盖本机授权。

**阶段 4、5 实施记录（2026-09-18）**：四个任务写工具通过主应用执行，创建登记最多 10,000 项，仅保留 UUID、摘要及编号；目标已满足时不写库。新增提交事实返回，已提交后重读失败保留原编号；字段级服务调用保留缺省备注、旧预计分钟及历史科目文本。设置的数据页提供接入/写入开关、连接数、阻断说明、最近操作及路径复制，不触发全局 Toast。原有 FocusTimer 不参与这些写路径，与 UI 直接调用任务服务的行为一致，不隐式控制计时。专项测试覆盖容量、重放/删除/待删、忙碌后重试、冲突、故障注入、设置回滚、交互状态展示、拖动结束前持有阻断及延迟补刷；备份隔离回归通过。真实窗口 Esc/外部点击仍未人工验收，离屏只验证结束函数及连接关系。

### 阶段 6：打包、统一验收与文档

- [x] 包内固定路径为 `Contents/MacOS/PomodoroTodoMcp`；辅助程序更新必须触发重新打包与部署。
- [x] 校验 Qt 动态库与 rpath；辅助程序从应用包复制后的路径、非构建工作目录启动，无需开发 shell 环境变量和 Node/Python。沿用当前应用对本机 Qt 安装的依赖，不额外承诺无需 Qt 或可拷到其他机器运行。
- [x] staging 同时验证主程序和辅助程序存在且可执行，再进行原子 rename；保留失败回滚，不改成先删旧包。
- [x] 用独立协议实现或实际客户端分别验证两个协议版本的发现与调用，不能只用自写客户端测自写服务端。补充仅消费 TextContent 的读写闭环；SDK 校验按下文独立离线验证方式运行，不添加默认 CTest 或用户运行时依赖。
- [x] 写接入说明，配置指向 `/Applications/番茄Todo.app/Contents/MacOS/PomodoroTodoMcp`，不包含凭据、不自动启动主应用。补齐 socket 路径限制、关闭自动重发、v4 并不保证键唯一、外部文本提示注入风险；不新增逐条审批。兼容性按实测客户端名称/版本记录。
- [x] 最后统一检查导入、资源清单、调用关系、中文注释、链接与测试注册。

**产物**：可部署应用包、验收记录与接入说明。

**阶段 6 实施记录（2026-09-18）**

- `bundle-mcp-helper` 每次构建核对复制辅助程序，部署目标显式依赖它；staging 在挪走旧包前校验主程序与辅助程序均存在且可执行。新增 `DeployLocalAppTests`，缺 helper、helper 不可执行时旧包保持完整，正常部署两个二进制一起替换。原子切换及失败回滚路径保留。
- `McpCreateRegistry` 使用 `QHash<QUuid, Entry>`，Entry 是 32 字节数组摘要及 qint64 编号，不保留可变长参数或响应；关闭/恢复通过会话信号立即清空。首次提交后或重放时读取失败均保留创建事实；重放超大历史数据导致输出超限也保留编号及 `creation_committed`，不引导换键重建。
- SDK 工作区 `tests/mcp-sdk` 锁定官方 SDK 1.29.0 及传递依赖；已用完整本地缓存离线安装，`npm ci --offline` 复核通过。验证脚本不联网下载、不注册默认 CTest。`node_modules` 的忽略规则生效。
- 官方 SDK 默认 AJV 校验：2025-11-25、2025-06-18 各跑一轮，共 46 次工具调用；所有后续写请求只从 TextContent 提取编号、会话及令牌。覆盖创建重放、大小写 UUID 归一、原任务修改/删除/待删、编辑阻断、目标状态重试、冲突、权限撤销和会话失效。
- Claude Code **2.1.274** 实际协商 **2025-11-25**，10 次调用成功覆盖全部 10 个工具，完成创建 → 编辑备注/预计用时 → 改期 → 完成 → 按编号确认。使用临时配置、无窗口隔离宿主与合成数据，不读取真实业务数据库、不改持久配置；本次模型费用约 $0.112。日志只保留方法、协议版本和成功状态。
- `~/pt-audit` Release 全量构建通过；最终离屏 CTest **100/100**。其中 McpProtocolTests 56 项、McpIntegrationTests 38 项、McpServiceTests 14 项、BackupServiceTests 52 项（均含 QtTest 初始化/清理条目）。QML lint、链接门禁、包内发现和部署保护门禁通过。
- `~/pt-build` RelWithDebInfo 以 `deploy-local-app` 结束，**零编译告警**。正式包中的 helper 在无开发环境变量、非构建工作目录下分别协商两版并发现 10 个工具，stdout 无诊断杂音。`otool` 确认只链接 Qt Core/Network，rpath 为本机 Qt 6.10.3 库目录；不是跨机器独立分发包。
- 部署后两个 SHA-256 均与构建包一致：主程序 `ef76496f572e9931d5c401f24f2ea9eb34e5e08ce4507f727238e986bac7b61c`；辅助程序 `99dbceffb7f3e4dd042c5cd1db6e93b8117179e3913084b144fd54911ea3a09c`。旧应用进程 PID 31855 仍运行，未结束它；用户需退出重开应用，并重连客户端才能加载新版本。
- 接入与维护说明见 [MCP 接入](../docs/MCP接入.md)，业务规则、运行命令和 README 已同步。未执行 Git 提交；计划正文仍需与索引一并纳入后续提交。

**明确未验证项**：真实窗口 Esc/外部点击关闭及人工视觉验收未执行，遵守自动验证不拉起 GUI 的约束；离屏只证明统一结束入口、销毁兜底和刷新协调。Claude 桌面版、Codex CLI 未做兼容性承诺。生产真实数据库未参与联调，实际读写证据来自同业务服务的隔离宿主。

## 验收与交付

### 必须通过的场景

| 类别 | 验收证据 |
| --- | --- |
| 协议 | 两个版本分别验证握手与调用；未初始化调用、未知方法、错误 JSON、整数/字符串编号、通知不回复、EOF 退出、stdout 无日志 |
| 结果兼容 | 只读 TextContent 的客户端能完成写入；schema 只用公共关键字且不写 $schema；成功结构通过 SDK 默认 AJV 校验，失败无 structuredContent，不被 schema 错误遮蔽 |
| 资源 | 中文跨字节分片、粘包、无换行超长输入、非法 UTF-8、连接/队列/缓冲上限、慢客户端、断线清理 |
| 路径 | common 两端算出相同绝对路径；字符数与编码字节数不同的中文路径、空根路径、嵌入 NUL、103 字节通过/104 字节拒绝；拒绝后不创建端点、不截断或换目录，静态发现仍可用 |
| 重试契约 | 每个业务错误码和每种 APP_BUSY 原因均断言 retryable=false 及具体 next_action；多原因完整返回；客户端缺少重试字段时不被解释为可自动重发 |
| 权限 | 默认关闭；错误凭据、不同 UID、只读下写调用、关闭接入后的旧连接和排队调用均拒绝；公布工具不代表权限，日志和结果无凭据 |
| 生命周期 | 主应用未启动时仍发现全部工具，上线后无需刷新清单即可调用；初始化失败、恢复、退出、私有版本不匹配均报明确状态，不弹窗或启动第二实例 |
| 查询 | 空库与失败、同名任务、任务 limit 边界与超限拒绝、合法零值、非法日期、闰日、日界前后、跨月/年、科目删除后的历史数据；待删过滤先于限量 |
| 缺口查询 | 逾期/今天/未来/未排期、到期边界及非法组合；超过 100 条同科目同名未排期缺口可续查完；空末页、has_more、next_after_id 与新增/改筛选条件后的非快照行为 |
| 统计 | 番茄/自由计时混合、无任务会话、休息排除、当前未完整日、逻辑日归属，与原服务查询精确对账 |
| 创建 | 同会话同键只建一条、异参冲突、失败原键可重试；重放返回原编号及当前修改值/已删/待删状态；重读失败保留登记不重建；登记内容只有定长字段，满容量不缓存大文本 |
| 提交后读失败 | 首次创建和重放分别注入 DATABASE_ERROR，错误文本不得声称创建失败；details 保留真实 created_task_id/creation_committed，指示原键取回，读取恢复后任务总数不增加 |
| UUID | 接受大小写标准 v4 并归一为相同键；拒绝 v1、nil、变体位错误、花括号和空白；同一个合法 v4 重用仍按去重规则处理，不能宣称格式校验能识别随机性 |
| 字段语义 | 缺省不改、null 拒绝、空备注清空、零预计分钟/零科目清除；负数/小数/超限预计分钟拒绝，不能被服务层夹紧后报成功 |
| 修改 | 未提供字段不变；非法科目/超长备注不落库；实际写入检查状态冲突；同日期改期不重新排序；目标已满足不写库、不发刷新信号 |
| 重启与取消 | 旧会话拒绝；执行前取消不写；提交后断线不声称回滚；容量满不驱逐去重记录 |
| UI 编辑与拖动 | 4 个编辑弹窗、3 处行内编辑、2 处拖动阻断；2 个新增弹窗不阻断且输入保留；先登记再重读，排队刷新不丢输入；统一结束/重复释放/对象销毁兜底后不残留登记 |
| 阻断可见性 | APP_BUSY、get_status 和状态区同步给出原因、来源、影响范围及下一步；多个登记互不误清；所有登记释放后立即恢复写入 |
| UI 错误 | MCP 查询失败不触发共享 operationFailed、不使前台页面变成加载失败；成功变更信号仍正常刷新 |
| 撤销窗口 | 待删任务列表隐藏、单查/目标写入拒绝；修改另一任务不提交删除，反馈不替换撤销 Toast；历史专注统计不提前改变 |
| 恢复 | mcp/ 不进入 ownedSettingGroups 或 isLocalSettingKey；导出无 mcp/，伪造权限键忽略；分别验证同步/异步恢复成功后 mcp/ 键值不变、失败回滚不变；旧会话失效，测试不碰真实数据 |
| 分发 | 无需 Node/Python 或开发 shell，Qt 依赖沿用现有方案；独立客户端读写闭环；部署前后两个二进制哈希一致 |
| SDK 工作区 | git check-ignore 能匹配 tests/mcp-sdk/node_modules/，依赖目录不入库；默认 CTest 无 Node 依赖，单独 SDK 校验不联网安装 |

### 构建与部署约束

SDK 兼容验证采用独立可选脚本，不注册进默认 CTest。实施时先添加 `/tests/mcp-sdk/node_modules/` 忽略规则，再在 `tests/mcp-sdk` 提交 package.json 和 package-lock.json，SDK 精确锁定 `1.29.0`，传递依赖由锁文件固定。验证脚本启动前检查兼容 Node 及本地依赖；缺失则明确报告“未运行”，不能在线下载、执行 npx 自动安装或伪报通过。依赖准备单独完成；离线准备只允许使用完整本地缓存，不在测试过程中联网。交付兼容证据仍必须来自实际运行，默认 CTest 通过不等于 SDK 兼容已验证。

离屏 QML 验证不能依赖 `Popup.onClosed`。测试直接调用统一结束函数，覆盖重复释放、对象销毁、交互结束后的补刷，并核对关闭入口与函数的连接；真实窗口的 Esc/外部点击关闭路径仅在用户明确要求人工视觉验收时执行。没有实机证据时如实记录，不把直接调用函数的结果写成真实窗口路径已验证。

以下是各阶段的构建命令。验证构建自阶段 1 起每阶段执行（阶段 1 沿用 `~/pt-audit` 缓存中的 Release 配置，避免整仓重编）；交付构建只在阶段 6 部署时执行：

```bash
# 验证构建。
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B /Users/zerionlito/pt-audit \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /Users/zerionlito/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir /Users/zerionlito/pt-audit --output-on-failure

# 交付构建必须以 deploy-local-app 结束。
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B /Users/zerionlito/pt-build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPOMODORO_TODO_DEPLOY_LOCAL=ON
cmake --build /Users/zerionlito/pt-build --target deploy-local-app -j8
```

- 每阶段先跑相关用例，最后跑全量离屏回归，记录当次实际测试数，不把历史回归结果当成本次证据。
- 不修改仓库 `build/`，不新增一次性构建目录，不在 `/tmp` 构建 Qt 应用。
- 双进程测试使用专用 QCoreApplication 宿主和临时数据库；QML 使用离屏平台。自动联调禁止启动真实主应用窗口。
- 部署后分别比较构建包与 `/Applications/番茄Todo.app` 中两个可执行文件的 SHA-256。运行中的旧进程不等于磁盘新版本。
- 不结束已有进程、不自动启动 GUI；部署后提醒用户退出重开主应用、重连客户端，才能加载新的两个程序。
- 客户端配置与部署属于阶段 6；在那之前辅助程序不能配置到 AI 客户端（阶段 1 的辅助程序只输出说明后以非零码退出）。

### 完成条件

六阶段验收通过；固定工具发现、只读工具与四个任务写工具可用；文本客户端兼容、错误隔离、编辑/撤销协调、失败重试与本机权限备份边界均有证据；默认关闭与关闭接入有效；应用包携带辅助程序并完成部署校验；说明文档标注客户端版本、Qt 依赖、未验证项和数据流向。
计时控制、批量计划和知识缺口写入仍留在首版之外，不在收尾阶段临时扩展范围。

## 参考依据

- [MCP 2025-11-25：传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)：stdio 编码与输入输出。
- [MCP 2025-11-25：生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)：初始化、能力协商和退出。
- [MCP 2025-11-25：工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)：发现、调用和结果结构。
- [MCP 2025-06-18：工具](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)：首版兼容版本的结构化结果与文本兼容要求。
- [Apple un.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h)：macOS Unix socket 路径字段容量；本轮也核对了本机 SDK 头文件。
- [RFC 9562 §5.4](https://www.rfc-editor.org/rfc/rfc9562.html#section-5.4)：UUID v4 的版本与变体位。
- [MCP 官方：工具注解的能力边界](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/)：注解不能代替提示注入防护。
- [项目协作规则](../AGENTS.md)、[业务规则](../docs/业务规则.md)、[运行命令](../docs/运行命令.md)。

协议事实按上述固定版本核对；程序布局、工具范围、授权方式和资源上限是本项目的设计选择，不是 MCP 强制要求。
