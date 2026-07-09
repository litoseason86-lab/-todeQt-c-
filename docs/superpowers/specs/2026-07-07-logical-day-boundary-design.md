# 逻辑日界点（凌晨归属前一天）设计文档

日期：2026-07-07
状态：方向经问答确认（可配置、默认凌晨 4 点）；规格 v6（补失效机制四缺口：定时器构造即排期 / 跨日补例行 / StatisticsView 时间源改逻辑今天 / MonthGoalView 全"今天"入口 + 当前期跟随）

## 背景

用户考研自习常熬到凌晨 3 点。app 现在**全部按午夜 00:00 切天**（C++ `QDate::currentDate()` + SQLite `date(start_time)`；QML `new Date()`），导致凌晨 0-4 点的专注被算进"新的一天"，把一场连续自习劈成两天，污染今日专注时长、今日任务、结转、例行生成、专注历史/统计的按天分桶。

已确认决策：引入**可配置日界点**，默认凌晨 4 点——凌晨此点前的时间归前一天。你熬到 3 点、日界 4 点，3:59 前的专注都归前一天。

## 核心概念

**逻辑日**：给定时间戳 `ts`，其逻辑日 = `(ts − dayStartHour 小时).date()`。等价于：`ts` 的小时 < `dayStartHour` → 前一天，否则当天。
**逻辑今天** = 逻辑日(现在)。

`dayStartHour` 为整点（默认 4，合法范围 0–6）。

## 数据层（AppSettings 新属性）

沿用既有 Q_PROPERTY 模式：

- `Q_PROPERTY(int dayStartHour READ dayStartHour WRITE setDayStartHour NOTIFY dayStartHourChanged)`；
- QSettings 键 `logic/dayStartHour`，默认 `4`；
- **归一化（不是 clamp）**：非 0–6 的值一律**回落 4**（`99→4`、`-1→4`，而非 `99→6`）。`getter` 与 `setter` **都归一化**——坏的持久化值可能早已写进 ini，getter 必须在读取时归一，否则 `99` 会漏进服务和 QML。setter 写入前归一 + 同值不发信号 + `sync()`。
- 抽一个私有静态 `normalizeDayStartHour(int)`：`(h >= 0 && h <= 6) ? h : 4`，getter/setter 共用。

## 核心助手（单一来源，可测）

**C++**：新建 `src/services/LogicalDay.h`（纯自由函数，`dayStartHour` 作参数——保证纯函数可单测，不在函数内读单例）：

```cpp
namespace LogicalDay {
// 某时间戳的逻辑日（唯一算法所在）。
inline QDate dateOf(const QDateTime& ts, int dayStartHour) {
    return ts.addSecs(-dayStartHour * 3600).date();
}
// 逻辑今天：薄包装，不复制算法——单一来源。
inline QDate today(int dayStartHour) {
    return dateOf(QDateTime::currentDateTime(), dayStartHour);
}
// 距下一个逻辑日界点的毫秒数（供刷新定时器；纯函数、可单测）。
inline qint64 msUntilNextBoundary(const QDateTime& now, int dayStartHour) {
    QDateTime boundary(now.date(), QTime(dayStartHour, 0));
    if (now >= boundary) boundary = boundary.addDays(1);
    return now.msecsTo(boundary);
}
// SQLite date() 修饰符：date(start_time, sqlShift(h)) 即按逻辑日取日期。
inline QString sqlShift(int dayStartHour) {
    return QStringLiteral("-%1 hours").arg(dayStartHour);
}
}
```

服务在调用点读 `AppSettings::instance()->dayStartHour()` 传入（服务因此新增对 AppSettings 的依赖，`#include "AppSettings.h"`）。

**QML**：新建 `qml/LogicalDay.js`（`.pragma library`），**两个明确返回类型的函数**（避免调用方各自处理导致散乱）+ **可注入 now**（便于测试，不硬依赖 `new Date()`）：

```js
// nowDate 为 Date；生产调用传 new Date()，测试传固定 Date。
function todayDate(dayStartHour, nowDate) {
    var d = new Date(nowDate.getTime() - dayStartHour * 3600 * 1000);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()); // 归零到当天 0 点
}
function todayIso(dayStartHour, nowDate) {
    var d = todayDate(dayStartHour, nowDate);
    var m = d.getMonth() + 1, day = d.getDate();
    return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
}
```

调用点取 hour **必须在调用点就地写守卫**（不封装 helper——若写成 `resolveHour(appSettings)`，`appSettings` 在参数求值阶段就 ReferenceError，函数内的 `typeof` 救不了；封装反而诱导"假安全"代码）。每个调用点固定写法（配 `// qmllint disable unqualified`，同 main.qml 先例）：

```qml
// qmllint disable unqualified
var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
// qmllint enable unqualified
var iso = LogicalDay.todayIso(h, new Date())   // 或 todayDate(h, new Date())
```

**需要 Date 的**（AddTaskDialog.selectedDate、MonthGoalView 初始日）用 `todayDate`；**需要 ISO 字符串的**（TodayTaskView 结转、EditTaskDialog"今天"、ExportDialog 范围）用 `todayIso`。二者不混用一个函数。

## 改动映射（每个日界点 → 改法）

**SQL 分桶（专注 session 归日，问题核心——所有对 focus_sessions 时间戳取日期的地方必须同口径，漏一处就"总时长按 4 点、次数/有效天数/历史按 0 点"打架）**。把每处 `date(<表>.start_time)` 改为 `date(<表>.start_time, <shift>)`，`shift = LogicalDay::sqlShift(h)`（named 绑定用 `:dayShift`，positional `?` 用把 shift 值前插到参数列表）。**WHERE 里的、SELECT/DISTINCT/AS 里的都要改**（返回/分组的日期也须是逻辑日）：

| 位置 | 现状片段 | 改为 | 计划 |
| --- | --- | --- | --- |
| [StatisticsService.cpp:122-123](../../../src/services/StatisticsService.cpp#L122) calculateTotalDuration | `date(start_time) >= :startDate … <= :endDate` | 两处加 `, :dayShift` | 一 |
| [StatisticsService.cpp:336-337](../../../src/services/StatisticsService.cpp#L336) 趋势/分类 | `date(f.start_time) …` | 同上 | 一 |
| [StatisticsService.cpp:484-486](../../../src/services/StatisticsService.cpp#L484) getFocusSessionCount | `date(start_time) >= … <= …` | 两处加 `, :dayShift` | 一 |
| [StatisticsService.cpp:615-618](../../../src/services/StatisticsService.cpp#L615) getUniqueFocusDates | `SELECT DISTINCT date(start_time) … WHERE date(start_time) …` | **SELECT 与 WHERE 三处**都加 `, :dayShift`（有效专注天数按逻辑日去重） | 一 |
| [FocusHistoryService.cpp:48/60/184](../../../src/services/FocusHistoryService.cpp#L164) querySessions 及其调用 | SELECT `date(fs.start_time) AS session_date` + WHERE `date(fs.start_time) >= ?…`（**positional**） | **改用命名占位符**（见下"querySessions 重构"），避免 positional bind 顺序脆弱 | 一 |
| [ExportService.cpp:238-239](../../../src/services/ExportService.cpp#L238) 导出范围 | `date(f.start_time) >= :startDate … <= :endDate` | 两处加 `, :dayShift`——**导出与 UI 统计同口径，按逻辑日**（明确决策，非"可能"） | 一 |

实施时 `grep -rn "date(.*start_time" src/` 全覆盖核对（含 getDayTotalDuration 等），确保无遗漏。

**querySessions 重构（回应 positional bind 顺序脆弱）**：[querySessions](../../../src/services/FocusHistoryService.cpp#L164) 现在 SQL 全是 positional `?`、循环 `bindValue(index, ...)`。加 SELECT 的 shift 后位置会错位。**改为命名占位符**——`:shift` 命名后在 SELECT 与 WHERE 各处复用、只 bind 一次，彻底消除顺序问题：

- 签名改 `querySessions(const QString& whereClause /* 用命名占位符 */, const QVariantMap& namedBinds)`；
- 内部：`query.bindValue(":shift", LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()))` + 遍历 `namedBinds` 逐一 `bindValue(key, value)`；SELECT 改 `date(fs.start_time, :shift) AS session_date`；
- getMonthSessions：whereClause = `"date(fs.start_time, :shift) >= :startDate AND date(fs.start_time, :shift) < :endDate"`，namedBinds `{":startDate": start, ":endDate": nextMonthStart}`；
- getDaySessions：whereClause = `"date(fs.start_time, :shift) = :date"`，namedBinds `{":date": date}`。

C++ 侧 `dateTime.date()` 形式的日期提取（StatisticsService:40/53、TaskManager:32/45、ExportService:38/51）：这些是"把某字段转 QDate"的通用解析器，**入参可能是 session 时间戳也可能是任务的 date 字段**——不在解析器内改，而是在 SQL 层（上表）统一处理 session 归日；任务/目标 date 字段本就是逻辑日、不动。

**"今天"改逻辑今天**：

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| [StatisticsService.cpp:173](../../../src/services/StatisticsService.cpp#L173) getTodayStats | `getDayStats(QDate::currentDate())` | `getDayStats(LogicalDay::today(h))` |
| [StatisticsService.cpp:244-245,424,538](../../../src/services/StatisticsService.cpp#L244) 本周/趋势的 today | `QDate::currentDate()` | `LogicalDay::today(h)` |
| [TaskManager.cpp:352](../../../src/services/TaskManager.cpp#L352) getTodayTasks | `getTasksByDate(QDate::currentDate())` | `getTasksByDate(LogicalDay::today(h))` |
| [TaskManager.cpp:471,502](../../../src/services/TaskManager.cpp#L471) 结转 overdue "today" | `QDate::currentDate()` | `LogicalDay::today(h)` |
| [RoutineManager.cpp:255](../../../src/services/RoutineManager.cpp#L255) materializeToday | `QDate::currentDate()` | `LogicalDay::today(h)` |

**QML 默认"今天"改逻辑今天**（按上节就地守卫取 `h`，再 `LogicalDay.todayDate(h, new Date())` 或 `todayIso(h, new Date())`）：

| 位置 | 用途 |
| --- | --- |
| AddTaskDialog `selectedDate`（69） | 新任务默认日期 |
| MonthGoalView `currentYear/currentMonth/selectedDay`（15-17） | 月历初始定位 |
| TodayTaskView 结转横幅 `todayIso` | 与 overdue 判定一致 |
| EditTaskDialog 今天/明天/后天 chip 的"今天"（isoWithOffset(0)） | 编辑日期快捷项 |
| ExportDialog 快捷"本周/本月/今天"锚点 | 导出范围 |
| **WeekPlanView `weekStart: mondayOf(new Date())`（13）** | 本周起点——改 `mondayOf(LogicalDay.todayDate(h, new Date()))` |
| **WeekPlanView `isTodayIndex`（96-102，`new Date()`）** | "今天"高亮——与逻辑今天比 |
| **WeekPlanView `isPastIndex`（105+）** | 过去日判定——与逻辑今天比 |
| **WeekPlanView"本周"按钮 / 回到本周** | 重置 weekStart 到 `mondayOf(逻辑今天)` |
| **StatisticsView `refreshCurrentDateSnapshot`（127-131）/ `currentDateProvider` 默认** | 快照默认取 `LogicalDay.todayDate(h, new Date())` 而非 `new Date()`——**只订阅 changed 不改时间源没意义**（见下失效节） |
| **MonthGoalView"本月"按钮（301）** | `var today = LogicalDay.todayDate(h, new Date())` 后 `setMonth(...)` |
| **MonthGoalView 日历"今天"高亮 `todayCell`（494-496）** | `var today = LogicalDay.todayDate(h, new Date())` 后比对 |

**WeekPlanView 必须纳入**——否则凌晨 0–4 点：今日任务页认为"还是昨天"、周计划页却认为"已是今天"，两页自相矛盾（正是此前"本周页面"问题的根源）。放计划二。

**每个视图内所有"今天"入口必须一次改齐——初始值、按钮、单元格高亮都要**（漏一处就页内自相矛盾）：MonthGoalView 除初始 `currentYear/currentMonth/selectedDay`（15-17）外，"本月"按钮（301）与日历 `todayCell` 高亮（494-496）都读 `new Date()`，凌晨窗口会出现"初始选中昨天、点本月跳今天、今天高亮也是今天"三者打架，必须同改。StatisticsView 的时间源是 `refreshCurrentDateSnapshot`/`currentDateProvider`（不是散落的 `new Date()`），把默认快照改成逻辑今天即可全页跟随。

**目标倒计时"还有 N 天"是 C++ 算的，不能只改 QML**（QML 只展示）。有两条路径，且 **model 层不得反向依赖 AppSettings 单例**（`src/models` 依赖 `src/services` 会污染模型测试/复用/序列化）——把设置依赖挡在 service 层，用注入基准日：

**两条 daysRemaining 路径**（核实过代码，都要走同一注入基准日 `m_referenceDate`，否则列表更新了顶部横幅还是旧天数）：① 顶部横幅 `primaryGoal().daysRemaining` 经 [goalToVariantMap:381](../../../src/services/CountdownService.cpp#L381) → `goal.daysRemaining()`；② 列表 [CountdownModel:34](../../../src/models/CountdownModel.cpp#L34) DaysRemainingRole → `goal.daysRemaining()`。

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| [CountdownGoal.cpp:86](../../../src/models/CountdownGoal.cpp#L86) `daysRemaining()`（纯值对象，src/models） | 内部读 `QDate::currentDate()` | 改为纯函数 `daysRemainingFrom(const QDate& baseDate) const`（`= baseDate.daysTo(m_targetDate)`），**删掉读单例的 daysRemaining()**（其调用点见下两行；无残留调用后编译才过） |
| [CountdownModel.cpp:34](../../../src/models/CountdownModel.cpp#L34) DaysRemainingRole | `goal.daysRemaining()` | `goal.daysRemainingFrom(m_referenceDate)`；Model 新增 `QDate m_referenceDate`（默认 `QDate::currentDate()`）+ `setReferenceDate(QDate)`（更新 + 对 DaysRemainingRole 发 `dataChanged`）。**不依赖 AppSettings** |
| [CountdownService.cpp:381](../../../src/services/CountdownService.cpp#L381) goalToVariantMap | `goal.daysRemaining()` | `goal.daysRemainingFrom(m_referenceDate)`（service 持有 `m_referenceDate`） |
| [CountdownService.cpp:239](../../../src/services/CountdownService.cpp#L239) calculateDaysRemaining（若仍被调用） | `QDate::currentDate().daysTo(...)` | `m_referenceDate.daysTo(...)`；若已无调用则删除 |
| **CountdownService 新增私有 `syncReferenceDate()`** | — | `m_referenceDate = LogicalDay::today(AppSettings::instance()->dayStartHour()); m_model.setReferenceDate(m_referenceDate); updatePrimaryGoal();`（后者触发 `primaryGoalChanged`）。**调用时机**：构造函数（[27](../../../src/services/CountdownService.cpp#L27)，在首次 loadGoals 前）、[loadGoals:299](../../../src/services/CountdownService.cpp#L299) 末尾、`AppSettings::dayStartHourChanged` 连接、逻辑日失效事件（见下节）。goalToVariantMap 与 model role 由此吃同一 `m_referenceDate`。 |

**明确不动**：`getTasksByDate(显式日期)`、任务/目标的 `date` 字段本身（用户指派的日历日，非时间戳）、周/月边界（由逻辑今天自然派生）。

## 逻辑日失效与刷新（否则改设置/跨日界后已打开页面显示旧数据）

现状：今日页只在任务/分类/专注/例行变化时刷新（[TodayTaskView.qml:34](../../../qml/views/TodayTaskView.qml#L34)）。改"每日起始时间"后，已打开的今日/周/月/统计/倒计时**不会自动重查**；应用从 3:59 挂到 4:00 也不刷新。需要统一的"逻辑日失效"契约：

- **新增 `LogicalDayService`**（C++ 单例，上下文属性 `logicalDayService`），信号 `changed()`，两个方法职责分明：
  - `scheduleNextBoundary()`（私有）：`m_timer.start(LogicalDay::msUntilNextBoundary(QDateTime::currentDateTime(), h))`（单次 QTimer）。**只排期、不发信号**。
  - `onInvalidate()`（槽）：`emit changed()` **然后** `scheduleNextBoundary()`（发信号后立刻重排下一界点）。
  - **构造时**：连接 `AppSettings::dayStartHourChanged` → `onInvalidate()`、`m_timer.timeout` → `onInvalidate()`，**然后立即调用一次 `scheduleNextBoundary()`**。这一步是关键——否则定时器要等第一次 `onInvalidate()` 才启动；用户若从不改设置，它永不启动、跨 4 点不会发 `changed()`。构造即排期保证"不改任何设置也能跨逻辑午夜自动刷新"。
- **跨逻辑日必须先补当日例行、再刷视图**（否则新逻辑日的例行任务尚未落库，视图刷新只拿到残缺数据）。现状 `RoutineManager::materializeToday()` 只在启动时调一次（[main.cpp:51](../../../src/main.cpp#L51)）。**在 main.cpp、QML 加载前**把 `LogicalDayService::changed` 连到 `RoutineManager::materializeToday()`——connect 先于 `engine.load(url)`，且 `materializeToday` 是直接连接、在 `changed()` 的同步派发中先于任何 QML 视图槽执行，保证"例行先生成、视图后刷新"。`materializeToday` 本就幂等（同日重复调不重复插），跨设置反复触发安全。
- **各视图/模型订阅** `logicalDayService.changed` 后各自重载：
  - TodayTaskView：`refresh()`；
  - WeekPlanView：重算 `weekStart`/今天/过去索引 + `refresh()`；
  - StatisticsView：`resetSelectedPeriodToCurrent()`（复用其"当前期跟随、历史期保留"逻辑——已在 [StatisticsView.qml:144](../../../qml/views/StatisticsView.qml#L144)），前提是时间源已改逻辑今天（见上 QML 映射表，仅订阅不改 `refreshCurrentDateSnapshot` 会刷成物理今天，与 `getTodayStats` 的逻辑今天打架）；
  - MonthGoalView：**同"当前期跟随、历史期保留"决策**——若当前正显示逻辑今天所在月，则更新 `currentYear/currentMonth/selectedDay` 到新逻辑今天；若在浏览历史月，仅 `refresh()` 保留浏览位置（照搬 StatisticsView 的 applyCurrentPeriodSelection/resetSelected 思路，不硬跳走用户）；
  - Countdown：服务侧 `syncReferenceDate` 已由 `dayStartHourChanged` 覆盖设置变更，跨边界再由 `changed` 触发一次 `syncReferenceDate`（在 CountdownService 内连接 `logicalDayService.changed`）。
- **QML 订阅守卫**：视图用 `Connections { target: typeof logicalDayService !== "undefined" ? logicalDayService : null; ignoreUnknownSignals: true; function onChanged() {…} }`。QML 测试单独实例化视图、无此上下文对象，直接引用会 ReferenceError；`typeof` 守卫 + `ignoreUnknownSignals` 让缺服务时安全降级（同现有 categoriesChanged 订阅先例）。
- **计划归属**：`LogicalDayService` + main.cpp 的 materializeToday 连接 + StatisticsView 订阅进**计划一**（设置在计划一就能改，统计与例行必须随改刷新）；Today/Week/Month/Countdown 订阅进**计划二**。
- **可测**：不依赖真实凌晨——`msUntilNextBoundary(固定 now, h)` 纯函数单测；构造即排期经"新建 LogicalDayService 后 `m_timer.isActive()` 为真"验证；`changed()` 响应经"改 `dayStartHour` → `changed` 发出 → 视图 refresh 被调/模型重载"验证（QML 用 mock service 直接 `changed()`）；**例行补齐**经"emit `changed` 后新逻辑日例行任务已落库且不重复"验证（C++，`materializeToday` 幂等性）。

## 设置 UI（objectName 契约写成可执行接口）

设置弹窗"偏好"段（提示音/减少动效/精简时钟字之后）加一行"每日起始时间"。**DurationStepper 根对象无 objectName**（[DurationStepper.qml](../../../qml/components/DurationStepper.qml)），`namePrefix` 只派生子控件名。契约如下，不要求改 DurationStepper：

- 外层行容器（仿现有 `settings*SwitchRow` 模式）objectName `settingsDayStartRow`，含标签"每日起始时间" + 副说明"凌晨此点前算前一天（4 = 凌晨4点）" + DurationStepper；
- DurationStepper：`from: 0`、`to: 6`、`value: appSettingsRef ? appSettingsRef.dayStartHour : 4`、`namePrefix: "settingsDayStart"` → 自动生成子控件 `settingsDayStartMinus` / `settingsDayStartValue` / `settingsDayStartPlus`；
- `onAdjusted: if (appSettingsRef) appSettingsRef.dayStartHour = newValue`；缺 appSettingsRef 时不写（同其它偏好守卫）。
- 测试入口：行 `settingsDayStartRow`、数值 `settingsDayStartValue`（断言显示当前小时）、加减 `settingsDayStartPlus`/`Minus`（点击后断言 mock.dayStartHour 变化）。

## 无需 DB 迁移

focus_sessions 存时间戳、按天纯属聚合逻辑——改 SQL 修饰符即回溯生效，凌晨旧记录自动归前一天。任务/目标的 date 字段本就是逻辑日（用户指派），不动。零迁移、零数据风险。

## 可测性

- **核心算法与真实时钟解耦**：`dateOf(const QDateTime& fixedNow, int h)` 是纯函数（穷举单测：3:59→前天、4:00→当天、hour=0 等于午夜、hour=6、跨月边界）；`today(int h)` 仅是 `dateOf(QDateTime::currentDateTime(), h)` 的薄包装。**不硬测真实凌晨**——算法正确性全靠 `dateOf` 覆盖。
- **服务的分桶完全可测且不依赖时钟**：插入 `start_time` 为固定时刻（如 `"2026-07-08 01:00:00"`）的 session，用**显式日期**查询验证——`getDayStats(2026-07-07)`（h=4）计入、`getDayStats(2026-07-08)` 不计入；`05:00` 的相反。次数/有效天数/历史/导出同法各测一条边界 session。这覆盖 SQL 修饰符正确性，是核心。
- **依赖真实"现在"的薄包装**（getTodayStats/getTodayTasks/materializeToday）：只验证"确实调用了逻辑日结果"——即断言其等价于 `getDayStats(LogicalDay::today(h))` 等，而非在测试里模拟真实凌晨。今天 = dateOf(now,h) 的算法正确性已由 dateOf 单测保证。
- 服务读 `AppSettings::instance()->dayStartHour()`；需换 hour 的用例 `setDayStartHour(N)` 前置、cleanup 复位（单例改动本用例内自愈）。

## 测试策略

**C++（ServiceTests）**：

- `AppSettings.dayStartHour`：默认 4；**归一化**——`setDayStartHour(99)` 后 get 返回 4、`setDayStartHour(-1)`→4、合法值 5 保留；**坏配置**——直接往 ini 写 `logic/dayStartHour=99` 后新建实例 getter 返回 4；持久化、信号。
- `LogicalDay::dateOf(fixedNow, h)`：边界穷举（3:59→前天、4:00→当天、h=0=午夜、h=6、跨月/跨年）；`sqlShift(h)` 输出核对（`sqlShift(4)=="-4 hours"`）。
- **StatisticsService 全部分桶入口各一条边界 session**（默认 h=4，均用显式日期查询、不依赖时钟）：`getDayStats`（总时长）、`getFocusSessionCount`（次数）、`getUniqueFocusDates`（有效天数）——01:00 的 session 归前一天、05:00 归当天。
- **FocusHistoryService**：getMonthSessions/getDaySessions/session_date 各验证凌晨 session 归逻辑日（同法，显式日期）。
- **ExportService**：导出范围按逻辑日过滤（01:00 session 落在前一天的范围内）。
- getTodayStats/getTodayTasks/materializeToday：验证等价于以 `LogicalDay::today(h)` 为日的对应查询（不模拟真实凌晨）。
- **倒计时（分层 + 双路径 + 通知）**：`CountdownGoal::daysRemainingFrom(base)` 纯函数（不读单例，model 测试不碰全局）；`CountdownModel::setReferenceDate` 后 DaysRemainingRole 随基准日变（发 dataChanged）；`syncReferenceDate` 后**同时断言** DaysRemainingRole、`primaryGoal().daysRemaining`、`primaryGoalChanged` 发出（三者同一基准日，防"列表更新了横幅没更新"）。
- **LogicalDayService**：`LogicalDay::msUntilNextBoundary(固定 now, h)` 纯函数穷举（now 在界点前/后、跨日）；**构造后定时器即启动**（新建实例后其内部 QTimer `isActive()` 为真——覆盖"不改设置也会排期"这一关键修复）；改 `dayStartHour` → `changed()` 发出（SignalSpy）；不测真实边界定时器等待。
- **跨逻辑日补例行**：连接 `LogicalDayService::changed` → `RoutineManager::materializeToday` 后，emit `changed` → 断言新逻辑日的例行任务已落库；再次 emit → 断言不重复插入（幂等）。
- **失效刷新（QML）**：mock `logicalDayService` 直接 emit `changed`，断言各视图重查（Today/Week/Month/Statistics）；**StatisticsView 时间源**：`currentDateProvider` 注入固定凌晨 1 点 Date（h=4）→ `refreshCurrentDateSnapshot` 后快照为前一逻辑日、`selectedDate` 落前一天（证明改了时间源、非仅订阅信号）。

**QML**：`LogicalDay.js` `todayDate/todayIso(dayStartHour, nowDate)` 用**固定 nowDate** 穷举边界（凌晨 1 点 h=4 → 前一天；两函数返回类型分别为 Date / ISO 串）；设置项 `settingsDayStartRow`/`settingsDayStartValue`/`settingsDayStartPlus` 绑定/写入 `dayStartHour`（点加断言 mock 变化、缺 ref 不写）。

## 影响面与拆分

- C++：AppSettings（属性 + 归一化）、新增 LogicalDay.h、**新增 LogicalDayService（失效信号 + 边界定时器，构造即排期）**、**main.cpp（changed → materializeToday 连接，QML 加载前）**、StatisticsService + **FocusHistoryService（querySessions 改命名占位符）+ ExportService**（SQL 分桶）、TaskManager/RoutineManager（today）、**倒计时（CountdownGoal 改 daysRemainingFrom 纯函数 + CountdownModel 注入 referenceDate + CountdownService syncReferenceDate）**。
- QML：新增 LogicalDay.js、SettingsDialog（步进器行）、AddTaskDialog/MonthGoalView（初始 + 本月按钮 + todayCell 高亮）/TodayTaskView/**WeekPlanView**/EditTaskDialog/ExportDialog 的"今天"、**StatisticsView 时间源改逻辑今天** + 各视图订阅 `logicalDayService.changed`（守卫 `typeof … : null` + `ignoreUnknownSignals`；倒计时是 C++）。
- 拆两份计划：
  - **计划一（核心 + 专注归日全口径一致 + 失效基建）**：AppSettings.dayStartHour（含归一化）+ LogicalDay.h + **LogicalDayService（构造即排期）** + **main.cpp 的 changed → materializeToday 连接** + **所有 focus_sessions 分桶入口**（StatisticsService 4 处 + FocusHistoryService querySessions 命名重构 + ExportService 1 处）+ StatisticsService 的 today + **StatisticsView 时间源改逻辑今天 + 订阅 changed** + 设置 UI 步进器。**FocusHistoryService/ExportService 必须与 StatisticsService 同批**——否则口径打架、假完成。交付：专注归日全口径统一、可调日界点、改设置即刷新统计、跨日界自动补例行。
  - **计划二（任务/例行/倒计时/周计划/QML 今天 + 各视图失效订阅）**：TaskManager（今日任务 + 结转）、RoutineManager（例行）、**倒计时（分层：CountdownGoal daysRemainingFrom 纯 + CountdownModel referenceDate + CountdownService syncReferenceDate + 三条 daysRemaining 路径同基准日 + primaryGoalChanged）**、QML 各"今天"（含 MonthGoalView 本月按钮/todayCell、WeekPlanView weekStart/isTodayIndex/isPastIndex/本周按钮）、Today/Week/Month/Countdown 订阅 `logicalDayService.changed`（含 Month/Stat 的"当前期跟随、历史期保留"决策）。交付：全 app "今天"统一到逻辑日、跨设置/跨日界自动刷新。
