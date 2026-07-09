# 逻辑日界点（凌晨归属前一天）设计文档

日期：2026-07-07
状态：方向经问答确认（可配置、默认凌晨 4 点）

## 背景

用户考研自习常熬到凌晨 3 点。app 现在**全部按午夜 00:00 切天**（C++ `QDate::currentDate()` + SQLite `date(start_time)`；QML `new Date()`），导致凌晨 0-4 点的专注被算进"新的一天"，把一场连续自习劈成两天，污染今日专注时长、今日任务、结转、例行生成、专注历史/统计的按天分桶。

已确认决策：引入**可配置日界点**，默认凌晨 4 点——凌晨此点前的时间归前一天。你熬到 3 点、日界 4 点，3:59 前的专注都归前一天。

## 核心概念

**逻辑日**：给定时间戳 `ts`，其逻辑日 = `(ts − dayStartHour 小时).date()`。等价于：`ts` 的小时 < `dayStartHour` → 前一天，否则当天。
**逻辑今天** = 逻辑日(现在)。

`dayStartHour` 为整点（默认 4，合法范围 0–6；超范围回落 4）。

## 数据层（AppSettings 新属性）

沿用既有 Q_PROPERTY 模式：

- `Q_PROPERTY(int dayStartHour READ dayStartHour WRITE setDayStartHour NOTIFY dayStartHourChanged)`；
- QSettings 键 `logic/dayStartHour`，默认 `4`；
- setter clamp 到 [0,6]（越界回落 4）；同值不发信号、`sync()`。

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

**QML**：新建 `qml/LogicalDay.js`（`.pragma library`），`function today(dayStartHour)` 返回逻辑今天的 `yyyy-MM-dd`/Date；调用点传 `appSettings ? appSettings.dayStartHour : 4`。

## 改动映射（每个日界点 → 改法）

**SQL 分桶（专注 session 归日，问题核心）**——把 `date(start_time)` 改为带修饰符：

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| [StatisticsService.cpp:122-123](../../../src/services/StatisticsService.cpp#L122) | `date(start_time) >= :startDate AND date(start_time) <= :endDate` | `date(start_time, :dayShift) >= :startDate AND date(start_time, :dayShift) <= :endDate`，bind `:dayShift = LogicalDay::sqlShift(h)` |
| [StatisticsService.cpp:336-337](../../../src/services/StatisticsService.cpp#L336) | 同上（`f.start_time`） | 同上 |
| 其它按 `date(start_time)` 分组/计数的查询 | 逐一核查 | 同法加 `:dayShift`（实施时 `grep "date(.*start_time" src/` 全覆盖） |

C++ 侧日期提取（StatisticsService/TaskManager/ExportService 的 `dateTime.date()`）：**仅当该值是 session 时间戳**时改走 `LogicalDay::dateOf`；任务/目标的 date 字段是用户指派的日历日、不动（见下）。实施时逐处判定数据来源。

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

## 设置 UI

设置弹窗"偏好"段（提示音/减少动效之后）加一行"每日起始时间"：小时步进器（复用 FocusView 的 DurationStepper 组件！value 0–6，`namePrefix: "dayStart"`，副说明"凌晨此点前算前一天"），`adjusted` → `appSettingsRef.dayStartHour = v`。objectName `settingsDayStartStepper`。

## 无需 DB 迁移

focus_sessions 存时间戳、按天纯属聚合逻辑——改 SQL 修饰符即回溯生效，凌晨旧记录自动归前一天。任务/目标的 date 字段本就是逻辑日（用户指派），不动。零迁移、零数据风险。

## 可测性

- `LogicalDay` 纯函数：`dayStartHour` 作参数，单元测试穷举边界（3:59→前天、4:00→当天、hour=0 等于午夜、hour=6 等）；`sqlShift` 输出核对。
- 服务方法读 `AppSettings::instance()->dayStartHour()`：服务集成测试在默认 4 下用**构造的时间戳** session（如 01:00 的 session 应分桶到前一天、05:00 归当天）验证；需换 hour 的用例 `AppSettings::instance()->setDayStartHour(N)` 前置、cleanup 复位 4（单例改动本用例内自愈）。

## 测试策略

**C++（ServiceTests）**：

- `AppSettings.dayStartHour`：默认 4、clamp 越界回落、持久化、信号。
- `LogicalDay::today/dateOf/sqlShift`：边界穷举（用固定 QDateTime 注入 dateOf；today 用 dateOf 语义间接覆盖）。
- StatisticsService 分桶：插入 start_time 为"某日 01:00"的完成 session，`getDayStats(前一天)` 计入、`getDayStats(当天)` 不计入（默认 h=4）；05:00 的相反。
- TaskManager：getTodayTasks/结转在 h=4、凌晨"现在"下取逻辑今天（用可注入或依赖当前时间的边界说明——若难以控制"现在"，则以 LogicalDay::today 单测 + getTasksByDate(显式) 组合覆盖，避免测试依赖真实时钟）。
- RoutineManager.materializeToday：逻辑今天生成（同上，优先 LogicalDay 单测覆盖时钟依赖部分）。

**QML**：设置项步进器绑定/写入 `dayStartHour`；LogicalDay.js today 边界（传 mock 时间不现实——JS 依赖 `new Date()`，故只测"传入 dayStartHour 时的回拨算法"，用可注入的 now 参数版本：`today(dayStartHour, nowDate)`，生产用 `today(h, new Date())`）。

## 影响面与拆分

- C++：AppSettings（属性）、新增 LogicalDay.h、StatisticsService/TaskManager/RoutineManager（读设置 + 改 today/SQL）、可能 ExportService。
- QML：新增 LogicalDay.js、SettingsDialog（步进器行）、AddTaskDialog/MonthGoalView/TodayTaskView/EditTaskDialog/ExportDialog/CountdownView 的"今天"。
- 拆两份计划：
  - **计划一（核心 + 专注归日）**：AppSettings.dayStartHour + LogicalDay.h + StatisticsService（SQL 分桶 + today）+ 设置 UI 步进器。交付：专注时长/历史/统计按逻辑日归桶、可调日界点——**问题核心先解决**。
  - **计划二（任务/例行/QML 今天）**：TaskManager（今日任务 + 结转）、RoutineManager（例行）、QML 各"今天"、倒计时。交付：全 app "今天"统一到逻辑日。
