# Plan 012: 让仪表盘的「今日专注番茄」真的显示番茄数

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> 本仓库有一批**尚未提交**的工作区改动，`git diff <SHA>..HEAD` 形式的漂移检查在这里无效。
> 改用 grep 判据：
>
> ```bash
> grep -n "今日专注番茄" qml/views/DashboardView.qml                    # 必须命中 1 行
> grep -n "getFocusSessionCount" src/services/StatisticsService.cpp     # 必须命中多行
> grep -n "validPomodoroCountExpr(const QString&" src/services/FocusSessionRules.h  # 必须命中 → plans/011 已落地
> ```
>
> **第三条不命中 = plans/011 尚未执行 → 直接 STOP。**
> 本计划要新增一个走「有效番茄唯一口径」的查询，必须建立在 011 收编完成之后，
> 否则你会成为第四份口径副本。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED（用户首页上的数字会变小；这是修正，但用户会察觉）
- **Depends on**: plans/011-valid-pomodoro-single-source-and-migration-safety.md
- **Category**: bug
- **Planned at**: commit `43ba2ee`（+ 未提交工作区），2026-07-26

## Why this matters

仪表盘首屏最显眼的那张卡写着「今日专注番茄 N 个」。它取的是 `sessionCount`，
而 `sessionCount` 的查询**既不过滤专注模式，也不过滤是否自然到点**——
只要一段专注超过 3 分钟就计一个。

具体后果：用户开一个 25 分钟番茄、在 24 分钟时手动停下，再用自由计时专注 40 分钟。
于是同一天、同一个应用里出现四个互相矛盾的数字：

| 位置 | 显示 | 依据 |
|---|---|---|
| 仪表盘「今日专注番茄」 | **2** | `getFocusSessionCount`，无 mode / 无 pomodoro_completed 过滤 |
| 任务行的「实际番茄」 | 0 | `FocusSessionRules`（唯一口径） |
| 每周复盘 | 0 | 同上 |
| 长期目标进度 | +0 | 同上 |

这是一个番茄工作法应用的**头号指标**。用户最可能盯着看的那个数字，
恰好是唯一一个不按项目自己定义的规则计算的。

诚实说明其中的历史成分：不过滤 `mode` 是**既有问题**（`getFocusSessionCount` 这个函数
在未提交的这批改动里根本没被碰过）；未提交的 v8 改动新增了 `pomodoro_completed` 维度，
把原有的差距**又拉大了一档**。修的是整个差距。

## Current state

### 数据链路（我已逐层追过，你可以直接信这条链）

```
qml/views/DashboardView.qml:407-408
    StatCard { title: "今日专注番茄"; value: String(Number(root.todayStats.sessionCount || 0)); unit: "个" }
        ↑ todayStats 来自 statisticsService.getTodayStats()
src/services/StatisticsService.cpp:191
    stats.insert(QStringLiteral("sessionCount"), getFocusSessionCount(date, date));
src/services/StatisticsService.cpp:517-525
    "SELECT COUNT(*) FROM focus_sessions "
    "WHERE date(start_time, :dayShift) >= :startDate "
    "AND date(start_time, :dayShift) <= :endDate "
    "AND end_time IS NOT NULL "
    "AND duration IS NOT NULL "
    "AND duration >= :minDuration"
    // ← 没有 mode 条件，没有 pomodoro_completed 条件
```

绑定 `:minDuration` 时用的是 `FocusSessionRules::kMinimumValidDurationSeconds`，
所以「3 分钟门槛」这一维是对的，缺的是另外两维。

### 对照：正确的口径长什么样

`src/services/FocusSessionRules.h` 的注释（唯一事实源，不要在别处复制）：

> 一条专注记录计入"实际番茄"，当且仅当：番茄工作模式、自然到点，
> 且时长达到有效专注门槛。手动停止只保留专注时长，不伪装成完整番茄。
> 自由计时只累计专注分钟，不折算番茄。

它提供两个函数（plans/011 之后都带别名参数）：
- `validPomodoroPredicate(alias)` → `"fs.pomodoro_completed = 1 AND fs.mode = 1 AND fs.duration >= 180"`
- `validPomodoroCountExpr(alias)` → `"SUM(CASE WHEN ... THEN 1 ELSE 0 END)"`

用法范例见 `src/services/GoalService.cpp:153`。

### `sessionCount` 的其它消费者（这些决定了修法）

`sessionCount` 不止仪表盘一处在用：

- `src/services/StatisticsService.cpp:425` — 周/月统计也调 `getFocusSessionCount`
- `src/services/StatisticsService.cpp:290`、`:327`、`:490` — 环比对比数据
- `qml/views/DashboardView.qml:691` — 传给 `FocusGoalStrip`（今日专注目标状态条）

**所以不能直接改 `getFocusSessionCount` 的语义**——那会同时改掉周报、月报和环比，
波及面远超本计划，而且「专注会话数」本身在某些位置可能正是想要的含义。

**选定的修法**：新增一个字段，不动老字段。老字段 `sessionCount` 保持「专注会话数」
的含义不变；新增 `pomodoroCount` 走唯一口径；仪表盘那张卡改绑新字段。
这样没有任何现存数字的含义发生改变，只有那张标签写着「番茄」的卡片开始名副其实。

### 项目约定

- **注释必须是中文**，解释「为什么」和「边界条件」。统计、日期、跨层调用属于必须注释的类别。
- QML 里颜色只能用 `Theme.qml` 的语义令牌，不许硬编码色值。
- 分层：`src/services` / `qml` / `tests` 职责不混。
- **QML 测试硬规则**：本项目的 QML 测试**绝不允许断言 `item.visible === true`**
  （在离屏沙箱里可见性会级联，结果不可靠）。用 `tryCompare` 而不是固定 `wait()`。

## Commands you will need

构建目录**必须在仓库外**，且**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-012 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-012 -j8` | exit 0 |
| C++ 测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-012/PomodoroTodoTests` | 全过 |
| QML 测试 | `cd /tmp/pt-012 && ctest -R PomodoroTodoQmlTests --output-on-failure` | 通过 |
| 全量 | `cd /tmp/pt-012 && ctest --output-on-failure` | `100% tests passed ... out of 12` |

## Scope

**In scope**：
- `src/services/StatisticsService.cpp` / `.h` — 新增 `getValidPomodoroCount(startDate, endDate)`，
  并在 `getTodayStats` 结果里加 `pomodoroCount` 键
- `qml/views/DashboardView.qml` — 那张卡改绑 `pomodoroCount`；`todayStats` 的默认对象加上新键
- `tests/ServiceTests.cpp` — 新查询的用例
- `tests/qml/tst_dashboard_view.qml` — 卡片绑定的用例

**Out of scope**（看着相关也不许碰）：
- **`getFocusSessionCount` 的 SQL** —— 一个字都不许改。它的语义（专注会话数）保持原样，
  周报、月报、环比全都继续用它。本计划是「新增正确的字段」，不是「改旧字段的含义」。
- 统计页（`qml/views/StatisticsView.qml`）—— 那里的周/月数字是否也该改口径，
  是另一个需要单独判断的问题，本计划不碰。
- `qml/components/FocusGoalStrip.qml` —— 它接的 `sessionCount` 是否该换成番茄数，
  取决于「今日专注目标」到底是按分钟还是按番茄计的产品定义。先去读它的实现；
  **若发现它其实是按分钟算目标、`sessionCount` 只是附带展示，就完全不要动它**，
  并在报告里说明。若发现它确实按番茄计目标 → 这是产品问题，STOP 并报告。
- `FocusSessionRules` 里的任何常量值。
- 任何迁移代码。

## Git workflow

- 分支：`advisor/012-dashboard-pomodoro-count`
- 中文提交信息，例如：`仪表盘今日番茄改用有效番茄唯一口径`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 新增 `getValidPomodoroCount`

在 `src/services/StatisticsService.cpp` 里紧挨 `getFocusSessionCount` 新增一个同形状的函数，
SQL 用 `FocusSessionRules::validPomodoroPredicate(QStringLiteral("fs"))`：

```cpp
// 与 getFocusSessionCount 的区别：那个数的是"专注会话数"（含自由计时与手动停止），
// 这个数的是"有效番茄数"——口径来自 FocusSessionRules，与任务行、每周复盘、
// 长期目标进度完全一致。仪表盘上标着"番茄"的卡片必须用这一个。
int StatisticsService::getValidPomodoroCount(const QDate& startDate, const QDate& endDate)
```

日期过滤照抄 `getFocusSessionCount` 的写法（`date(fs.start_time, :dayShift)` +
`LogicalDay::sqlShift(AppSettings::instance()->dayStartHour())`）——
逻辑日的处理必须与它逐字一致，否则会出现「番茄数和会话数按不同的日界点分组」这种
更难查的错。错误处理也照抄（`reportStatisticsFailure` + 返回 0）。

在 `.h` 里加声明，注意是否需要 `Q_INVOKABLE`（照 `getFocusSessionCount` 的处理方式）。

**Verify**: `cmake --build /tmp/pt-012 -j8` → exit 0

### Step 2: 把 `pomodoroCount` 放进 `getTodayStats`

`src/services/StatisticsService.cpp:191` 附近：

```cpp
stats.insert(QStringLiteral("sessionCount"), getFocusSessionCount(date, date));
stats.insert(QStringLiteral("pomodoroCount"), getValidPomodoroCount(date, date));
```

同时检查该文件里 `:95`、`:104` 那两处「零值默认 map」——
它们也要加上 `pomodoroCount` 为 0，否则查询失败时 QML 读到 `undefined`。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-012/PomodoroTodoTests` → 全过（此时还没新用例，只验证没弄坏既有的）

### Step 3: C++ 用例

在 `tests/ServiceTests.cpp` 新增：

```cpp
void ServiceTests::validPomodoroCountExcludesFreeTimerAndManualStops();
```

同一天插四条记录，断言 `getValidPomodoroCount` 与 `getFocusSessionCount` 的差异：

| 记录 | mode | pomodoro_completed | duration | 会话数 | 番茄数 |
|---|---|---|---|---|---|
| 完整番茄 | 1 | 1 | 1500 | 计 | 计 |
| 手动停止 | 1 | 0 | 1440 | 计 | 不计 |
| 自由计时 | 0 | 0 | 2400 | 计 | 不计 |
| 误触 | 1 | 0 | 100 | 不计 | 不计 |

断言 `getFocusSessionCount == 3` 且 `getValidPomodoroCount == 1`。
**两个都要断言**——只断言新函数的话，将来有人「顺手统一」改了旧函数，测试不会红。

再加一个逻辑日一致性用例：设 `dayStartHour = 4`，在 02:00 和 12:00 各插一个有效番茄，
断言两个函数对「今天」的归属判断完全一致。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-012/PomodoroTodoTests validPomodoroCount` → 2 passed

### Step 4: 仪表盘改绑

`qml/views/DashboardView.qml`：

1. `:30` 的 `todayStats` 默认对象加 `pomodoroCount: 0`
2. `:239` 附近另一处默认对象同样加上
3. `:407-408` 那张卡：`value: String(Number(root.todayStats.pomodoroCount || 0))`

**卡片标题、单位、副标题都不要改。** 标题「今日专注番茄」本来就是对的，
错的是它下面的数字；副标题「专注 X」显示的是总时长，与番茄数无关，保持原样。

**Verify**: `cd /tmp/pt-012 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 通过

### Step 5: QML 用例

`tests/qml/tst_dashboard_view.qml` 已有 mock 数据（`:52` 有 `sessionCount: 5`）
和断言（`:246`）。追加：

1. mock 里加 `pomodoroCount: 2`（**与 `sessionCount: 5` 刻意不同**，
   这样才能证明卡片绑的是新字段而不是碰巧相等）
2. 断言那张卡的显示文本是 `"2"` 而不是 `"5"`

用 `objectName` 定位那张 `StatCard`；若它当前没有 `objectName`，加一个
（例如 `objectName: "todayPomodoroCard"`）——这属于本计划的合理范围。

**硬规则提醒**：不许断言 `item.visible === true`；用 `tryCompare` 不用固定 `wait()`。

**Verify**: `cd /tmp/pt-012 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 通过

### Step 6: 全量回归

**Verify**:
```
cd /tmp/pt-012 && ctest --output-on-failure
grep -rn "180\|mode = 1" src/services/StatisticsService.cpp   # 期望：无输出（口径只能来自 FocusSessionRules）
```

## Test plan

- **新增 C++**：`validPomodoroCountExcludesFreeTimerAndManualStops`（四种记录，同时断言新旧两个函数）
  + 逻辑日一致性用例。范式照 `tests/ServiceTests.cpp` 里既有的统计类用例。
- **新增 QML**：仪表盘卡片绑定用例，mock 里让 `pomodoroCount ≠ sessionCount`。
  范式照 `tests/qml/tst_dashboard_view.qml:246`。
- **回归**：所有既有统计用例必须原样通过——它们保护的是 `getFocusSessionCount` 没被改动。

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-012 && ctest --output-on-failure` → 12/12 通过
- [ ] `grep -n "getValidPomodoroCount" src/services/StatisticsService.h` → 命中
- [ ] `grep -n "pomodoroCount" qml/views/DashboardView.qml` → 至少命中 3 行（两处默认对象 + 卡片绑定）
- [ ] `git diff src/services/StatisticsService.cpp` 中 **`getFocusSessionCount` 函数体无任何改动**
- [ ] `grep -rn "duration >= 180\|mode = 1" src/services/StatisticsService.cpp` → 无输出
- [ ] QML 用例里 mock 的 `pomodoroCount` 与 `sessionCount` 取值不同
- [ ] `plans/README.md` 中 012 的状态行已更新

## STOP conditions

停下报告，不要自行发挥：

- Drift check 判据不命中，特别是 plans/011 未落地（`validPomodoroCountExpr` 还没有别名参数）。
- 你读 `qml/components/FocusGoalStrip.qml` 后发现「今日专注目标」是**按番茄个数**设定目标的
  （而不是按分钟）——那么它接的 `sessionCount` 也是错的，但改它会改变用户已设定的目标的含义，
  属于产品决策。**报告，不要顺手改。**
- 既有的统计用例在你的改动后变红——你不该碰到它们。
- 你发现 `getTodayStats` 之外还有别的地方给仪表盘喂 `sessionCount`，且改法不明。

## Maintenance notes

- 现在 `StatisticsService` 同时有 `getFocusSessionCount`（会话数）和
  `getValidPomodoroCount`（番茄数）两个语义不同的计数。**任何新增的 UI 在选用之前
  必须先想清楚标签写的是"次"还是"番茄"**。审查触及统计的 PR 时，看到 `sessionCount`
  出现在一个写着「番茄」的标签旁边，就是回归。
- 统计页（周/月）目前仍然用 `getFocusSessionCount`。它那里的标签措辞是否与含义匹配，
  本计划**没有审查**，已记录在 `plans/README.md` 的待办里。若将来要一并修正，
  本计划新增的 `getValidPomodoroCount(startDate, endDate)` 已经支持任意日期区间，
  直接调用即可，不需要再写查询。
- 上线后用户会看到首页番茄数变小。这是修正而非退化，但值得在发布说明里写一句
  ——尤其是它与 v8「升级后手动停止不再算番茄」的变化叠加，两者会同时生效。
</content>
