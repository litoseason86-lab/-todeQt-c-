# 逻辑日界点（凌晨归属前一天）设计文档

日期：2026-07-07
状态：方向经问答确认（可配置、默认凌晨 4 点）

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
// 逻辑今天：现在回拨 dayStartHour 小时后的日历日。
inline QDate today(int dayStartHour) {
    return QDateTime::currentDateTime().addSecs(-dayStartHour * 3600).date();
}
// 某时间戳的逻辑日。
inline QDate dateOf(const QDateTime& ts, int dayStartHour) {
    return ts.addSecs(-dayStartHour * 3600).date();
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

调用点传 `appSettings ? appSettings.dayStartHour : 4` 与 `new Date()`。**需要 Date 的**（AddTaskDialog.selectedDate、MonthGoalView 初始日）用 `todayDate`；**需要 ISO 字符串的**（TodayTaskView 结转 todayIso、EditTaskDialog"今天"、ExportDialog 范围、倒计时天数基准）用 `todayIso`。二者不混用一个函数。

## 改动映射（每个日界点 → 改法）

**SQL 分桶（专注 session 归日，问题核心——所有对 focus_sessions 时间戳取日期的地方必须同口径，漏一处就"总时长按 4 点、次数/有效天数/历史按 0 点"打架）**。把每处 `date(<表>.start_time)` 改为 `date(<表>.start_time, <shift>)`，`shift = LogicalDay::sqlShift(h)`（named 绑定用 `:dayShift`，positional `?` 用把 shift 值前插到参数列表）。**WHERE 里的、SELECT/DISTINCT/AS 里的都要改**（返回/分组的日期也须是逻辑日）：

| 位置 | 现状片段 | 改为 | 计划 |
| --- | --- | --- | --- |
| [StatisticsService.cpp:122-123](../../../src/services/StatisticsService.cpp#L122) calculateTotalDuration | `date(start_time) >= :startDate … <= :endDate` | 两处加 `, :dayShift` | 一 |
| [StatisticsService.cpp:336-337](../../../src/services/StatisticsService.cpp#L336) 趋势/分类 | `date(f.start_time) …` | 同上 | 一 |
| [StatisticsService.cpp:484-486](../../../src/services/StatisticsService.cpp#L484) getFocusSessionCount | `date(start_time) >= … <= …` | 两处加 `, :dayShift` | 一 |
| [StatisticsService.cpp:615-618](../../../src/services/StatisticsService.cpp#L615) getUniqueFocusDates | `SELECT DISTINCT date(start_time) … WHERE date(start_time) …` | **SELECT 与 WHERE 三处**都加 `, :dayShift`（有效专注天数按逻辑日去重） | 一 |
| [FocusHistoryService.cpp:48](../../../src/services/FocusHistoryService.cpp#L48) getMonthSessions | `date(fs.start_time) >= ? AND date(fs.start_time) < ?` | 两处加 `, ?`（shift 值前插参数列表） | 一 |
| [FocusHistoryService.cpp:60](../../../src/services/FocusHistoryService.cpp#L60) getDaySessions | `date(fs.start_time) = ?` | 加 `, ?` | 一 |
| [FocusHistoryService.cpp:184](../../../src/services/FocusHistoryService.cpp#L184) session_date 列 | `date(fs.start_time) AS session_date` | 加 `, ?`（历史卡片/日历按逻辑日归组） | 一 |
| [ExportService.cpp:238-239](../../../src/services/ExportService.cpp#L238) 导出范围 | `date(f.start_time) >= :startDate … <= :endDate` | 两处加 `, :dayShift`——**导出与 UI 统计同口径，按逻辑日**（明确决策，非"可能"） | 一 |

实施时 `grep -rn "date(.*start_time" src/` 全覆盖核对，确保无遗漏。getDayTotalDuration 等若还有 `date(fs.start_time)` 一并纳入。

C++ 侧 `dateTime.date()` 形式的日期提取（StatisticsService:40/53、TaskManager:32/45、ExportService:38/51）：这些是"把某字段转 QDate"的通用解析器，**入参可能是 session 时间戳也可能是任务的 date 字段**——不在解析器内改，而是在 SQL 层（上表）统一处理 session 归日；任务/目标 date 字段本就是逻辑日、不动。

**"今天"改逻辑今天**：

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| [StatisticsService.cpp:173](../../../src/services/StatisticsService.cpp#L173) getTodayStats | `getDayStats(QDate::currentDate())` | `getDayStats(LogicalDay::today(h))` |
| [StatisticsService.cpp:244-245,424,538](../../../src/services/StatisticsService.cpp#L244) 本周/趋势的 today | `QDate::currentDate()` | `LogicalDay::today(h)` |
| [TaskManager.cpp:352](../../../src/services/TaskManager.cpp#L352) getTodayTasks | `getTasksByDate(QDate::currentDate())` | `getTasksByDate(LogicalDay::today(h))` |
| [TaskManager.cpp:471,502](../../../src/services/TaskManager.cpp#L471) 结转 overdue "today" | `QDate::currentDate()` | `LogicalDay::today(h)` |
| [RoutineManager.cpp:255](../../../src/services/RoutineManager.cpp#L255) materializeToday | `QDate::currentDate()` | `LogicalDay::today(h)` |

**QML 默认"今天"改逻辑今天**（`LogicalDay.today(appSettings.dayStartHour)`）：

| 位置 | 用途 |
| --- | --- |
| AddTaskDialog `selectedDate`（69） | 新任务默认日期 |
| MonthGoalView `currentYear/currentMonth/selectedDay`（15-17） | 月历初始定位 |
| TodayTaskView 结转横幅 `todayIso` | 与 overdue 判定一致 |
| EditTaskDialog 今天/明天/后天 chip 的"今天"（isoWithOffset(0)） | 编辑日期快捷项 |
| ExportDialog 快捷"本周/本月/今天"锚点 | 导出范围 |
| CountdownView/目标倒计时"还有 N 天" | 用逻辑今天（凌晨 2 点仍显示"昨天"的天数，与全 app 一致） |

**明确不动**：`getTasksByDate(显式日期)`、任务/目标的 `date` 字段本身（用户指派的日历日，非时间戳）、周/月边界（由逻辑今天自然派生）。

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

**QML**：`LogicalDay.js` `todayDate/todayIso(dayStartHour, nowDate)` 用**固定 nowDate** 穷举边界（凌晨 1 点 h=4 → 前一天；两函数返回类型分别为 Date / ISO 串）；设置项 `settingsDayStartRow`/`settingsDayStartValue`/`settingsDayStartPlus` 绑定/写入 `dayStartHour`（点加断言 mock 变化、缺 ref 不写）。

## 影响面与拆分

- C++：AppSettings（属性 + 归一化）、新增 LogicalDay.h、StatisticsService + **FocusHistoryService + ExportService**（SQL 分桶）、TaskManager/RoutineManager（today）。
- QML：新增 LogicalDay.js、SettingsDialog（步进器行）、AddTaskDialog/MonthGoalView/TodayTaskView/EditTaskDialog/ExportDialog/CountdownView 的"今天"。
- 拆两份计划：
  - **计划一（核心 + 专注归日全口径一致）**：AppSettings.dayStartHour（含归一化）+ LogicalDay.h + **所有 focus_sessions 分桶入口**（StatisticsService 4 处 + FocusHistoryService 3 处 + ExportService 1 处，见上表）+ StatisticsService 的 today + 设置 UI 步进器。**FocusHistoryService/ExportService 必须与 StatisticsService 同批**——否则总时长按 4 点、次数/有效天数/历史/导出按 0 点，口径打架、假完成。交付：专注归日全口径统一、可调日界点。
  - **计划二（任务/例行/QML 今天）**：TaskManager（今日任务 + 结转）、RoutineManager（例行）、QML 各"今天"（todayDate/todayIso）、倒计时。交付：全 app "今天"统一到逻辑日。
