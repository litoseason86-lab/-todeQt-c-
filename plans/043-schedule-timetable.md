# 043：待办课表页（每周固定时间表）

## 状态

- **状态**：已实施，全量 ctest 67/67 通过
- **优先级**：P1
- **执行分支**：`feature/weekly-todo-view`
- **边界**：课表项**不是任务**。它不写 `tasks`、不写 `focus_sessions`、不产生今日待办、
  不参与任何统计与目标进度。它是一张按星期几循环的时间表，只做展示与增删改。

## 需求来源与澄清

用户要的「待办」页用来显示**工作或学习课表**，不是现有的「本周计划」。
两者的根本差别在于数据的时间锚点：

| | 本周计划（`tasks`） | 待办课表（`schedule_entries`） |
| --- | --- | --- |
| 时间锚点 | 具体日期 `2026-09-02` | 星期几 + 时段 `周一 08:00–09:40` |
| 生命周期 | 做完就结束 | 每周循环，按周次生效 |
| 完成状态 | 有 | 无 |

现有 `routines`（每日例行）同样不能复用：它没有星期几、没有时段，语义是「每天都做」。

## 已确认的产品规则

1. **时间表示**：底层统一存起止时间（分钟数）。另提供一套可配置的**节次预设**用于快速填充，
   并支持两种显示模式切换——「时间轴」按真实时长成比例排布，「节次」按节次等高排布。
2. **周次**：每个课表项可填生效周次范围（如第 1–8 周）与单双周规则（每周／仅单周／仅双周）。
   需要「学期起始日」与「总周数」两项设置来把日期换算成周次。
3. **联动**：纯展示。不接专注计时，不生成任务。
4. **侧栏入口**：新增「待办」，现有「本周计划」暂时保留并存，由用户实际使用后再决定去留。

## 分层与职责

| 层 | 文件 | 责任 |
| --- | --- | --- |
| DB | `DatabaseManager` | 新增 `schedule_entries`、`schedule_periods` 两表，schema 升到 v13（纯新增，不改旧表） |
| 服务 | `src/services/ScheduleService.{h,cpp}` | 课表项与节次的增删改查、**按周次筛选**、时间冲突检测 |
| 换算 | `qml/ScheduleWeeks.js` | 日期 ↔ 周次的纯函数换算，与既有 `LogicalDay.js` 同构 |
| 视图 | `qml/views/SchedulePlanView.qml` | 周网格、周次导航、两种显示模式 |
| 弹窗 | `qml/components/ScheduleEntryDialog.qml` | 课表项增改 |
| 弹窗 | `qml/components/ScheduleSettingsDialog.qml` | 学期起始日、总周数、节次预设 |
| 设置 | `AppSettings` | `semesterStartDate`、`semesterWeeks`、`scheduleDisplayMode`、`scheduleShowWeekend` |

**分层要点**：C++ 只管存储与「给定周次筛选」，不关心今天是第几周；
日期→周次的换算全部在 QML 侧的 `ScheduleWeeks.js`。这样服务层无需依赖 `AppSettings`，
周次规则也能被 QML 测试直接覆盖。

## 数据结构

### `schedule_entries`

```sql
CREATE TABLE IF NOT EXISTS schedule_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
    location TEXT NOT NULL DEFAULT '',
    weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),   -- 1=周一 … 7=周日
    start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
    end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
    week_start INTEGER NOT NULL DEFAULT 1 CHECK(week_start >= 1),
    week_end INTEGER NOT NULL DEFAULT 30 CHECK(week_end >= 1),
    week_parity INTEGER NOT NULL DEFAULT 0 CHECK(week_parity IN (0, 1, 2)), -- 0每周 1单周 2双周
    category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK(end_minutes > start_minutes),
    CHECK(week_end >= week_start)
)
```

`end_minutes > start_minutes` 表示课表项不跨零点。课表场景不存在跨夜条目，
用 CHECK 挡住比在服务层反复判空更可靠。

### `schedule_periods`

```sql
CREATE TABLE IF NOT EXISTS schedule_periods (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period_index INTEGER NOT NULL UNIQUE CHECK(period_index >= 1),
    start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
    end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
    CHECK(end_minutes > start_minutes)
)
```

迁移时种入一套默认节次（上午 4 节、下午 4 节、晚上 3 节），用户可整表改写。

## 不变量

- 课表项与 `tasks`、`focus_sessions` 之间**没有任何外键或写入关系**。
  删除课表项不影响任何专注历史；删除科目只把 `category_id` 置空。
- 「按周次筛选」的判据是三段合取：`weekday` 命中、`week_start ≤ N ≤ week_end`、
  单双周奇偶命中。三者任一不满足即不出现在该周网格里。
- 冲突检测只做**提示**不做拦截：同一天两门课时间重叠是真实存在的情况
  （比如两个可选时段），强行拒绝会让用户录不进去。
- 节次预设整表替换必须在单个事务内完成，避免中途失败留下半张节次表。

## 分阶段执行

1. ~~DB 层：两张表 + `migrateToVersion13` + 默认节次种子 + CMake 注册。~~
2. ~~`ScheduleService`：CRUD、按周次查询、冲突检测；补 C++ 单测。~~
3. ~~QML 骨架：`ScheduleWeeks.js`、视图框架、侧栏入口、`MainWindow` 接线。~~
4. ~~网格渲染：时间轴模式与节次模式。~~
5. ~~弹窗：课表项增改、课表设置。~~
6. ~~验证：QML 测试、全量 `ctest`。~~

## 实施中发现并修正的问题

- **嵌套布局的 `Layout.fillHeight` 默认值**：布局类型（RowLayout/ColumnLayout）嵌在另一个
  布局里时该属性默认为 `true`，不是 `false`。课表列头因此和网格主体一起瓜分纵向空间，
  把整页撑成七根从上贯到底的大色条。列头与页头都必须显式写 `Layout.fillHeight: false`。
  离屏截图走查抓到了这个问题——它不会让任何测试转红，因为断言的是属性值而不是像素。
- **时间刻度的首个整点被切掉**：刻度文字以刻度线为中心，`08:00` 的上半截落在滚动区外。
  网格顶部留 `axisTopInset` 的空白，横线与列各自按需补上这段偏移。
- **对比度**：时间刻度最初用 `Theme.inkMuted`，夜间 3.95:1、日间 3.31:1，均低于 4.5:1。
  时刻是有意义的正文信息而非占位符，改用 `Theme.inkSoft`（该令牌按主题定义即为满足 AA）。
- **`ServiceTests` 里写死的 schema 版本**：`migrationV12...` 断言迁移后 `user_version == 12`，
  但 `createTables` 会把整条链跑到头。改为断言 `kCurrentSchemaVersion`，
  否则以后每加一次迁移都会误伤这条用例。
