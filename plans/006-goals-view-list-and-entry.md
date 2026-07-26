# Plan 006: 目标列表页 + 侧栏入口 + 新建/编辑表单（奖励机制·阶段 A）

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：本计划引用的 `src/services/GoalService.h` 在 `43ba2ee`
> 时是未跟踪新文件，`git diff` 无效。改用直接比对：
> `grep -n "void milestoneReached" src/services/GoalService.h` 必须能命中；
> `grep -n "case \"dashboard\":" qml/MainWindow.qml` 附近的 `viewIndex` 结构必须与
> 下面 "Current state" 摘录一致。不一致按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW-MED
- **Depends on**: none（服务层已就绪）
- **Category**: feature（奖励机制 阶段 A）
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **设计依据**: `docs/奖励机制实施方案.md` §三-阶段A；设计稿 `docs/设计稿/长期目标/01/03/09/10`

## Why this matters

长期目标的数据层（进度聚合、里程碑去重、完成预测）已完成并有 22 个单测，但
`goalService` 在 QML 中**零引用**——功能对用户完全不存在。本计划让它第一次出现在界面上：
侧栏一个「目标」入口、一个列表页（双版式可切换）、一个新建/编辑表单。
后续的 100 格详情页（007）和全局奖励回路（008）都挂在这一页之上。

已由维护者拍板、不再讨论的决定：双版式（列表+网格）+ 切换控件；**默认列表**；
头部左筛选右切换；列表行必须放下「62 / 100 番茄 · 照此速度还需 21 天」。

## Current state

### 服务层 API（`src/services/GoalService.h`，全部就绪，本计划只消费不修改）

```cpp
Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)        // 100
Q_PROPERTY(int maxTargetPomodoros READ maxTargetPomodoros CONSTANT) // 9999
Q_INVOKABLE bool addGoal(const QString& title, int categoryId, int targetPomodoros,
                         const QVariant& startDateValue, const QVariant& deadlineValue);
Q_INVOKABLE bool updateGoal(int goalId, ...同上...);
Q_INVOKABLE bool deleteGoal(int goalId);
Q_INVOKABLE bool reorderGoal(int fromIndex, int toIndex);
Q_INVOKABLE QVariantList getGoals();
Q_INVOKABLE QVariantMap getGoal(int goalId);
signals:
    void goalsChanged();
    void milestoneReached(int goalId, const QString& title, int percent);
    void operationFailed(const QString& message);
```

`getGoals()` 每项的键（`LongGoal::toVariantMap`）：
`id, title, categoryId, categoryName, categoryColor, targetPomodoros, startDate,
deadline(无效=长期), displayOrder, firedMilestones, achievedAt, createdAt,
doneCount, percent, achieved, forecastDays`。
`forecastDays`：`-1`=无法预测（隐藏该行文案）、`0`=已达成、`>0`=还需 N 天。

**科目必填**：`addGoal/updateGoal` 对 `categoryId <= 0` 直接返回 false 并发
`operationFailed("请先为目标选择科目")`。表单必须提供科目选择且不允许留空。

`goalService` 已在 `src/main.cpp:139` 注册为 context property。

### 视图路由（`qml/MainWindow.qml:102-120`）

```cpp
    function viewIndex(viewName) {
        switch (viewName) {
        case "focus":    return 1;
        case "week":     return 2;
        case "month":    return 3;
        case "stats":    return 4;
        case "countdown":return 5;
        case "dashboard":
            // 仪表盘追加在栈尾，避免挪动既有视图索引影响测试与切页逻辑。
            return 6;
        case "today":
        default:         return 0;
        }
    }
```

**规则**：新视图只能追加栈尾（`"goals"` → 7），StackLayout（:416 起）里对应位置
追加子项，**绝不挪动既有索引**。每个视图都带 `pageActive: root.currentView === "xxx"`。

### 侧栏（`qml/components/Sidebar.qml:171-175` 与内联组件 :190）

```qml
        SidebarItem {
            ...
            isActive: root.currentView === "countdown"
            onClicked: root.itemClicked("countdown")
        }
```

「目标」项加在「countdown（目标倒计时）」这一项之后，照抄 `SidebarItem` 用法。
图标用 `GlyphIcon`：`grid` 字形已有；**需新增 `list` 字形**（三横线 + 左侧点，
在 `qml/components/GlyphIcon.qml` 的 switch 里加一个 case，照既有 case 的画法）。
侧栏目标项本身的图标建议用 `target`（已有，靶心）。

### 设置持久化范式（`src/services/AppSettings.h/.cpp` 的 `sidebarVisible`）

新增 `goalViewMode`（QString，`"list"`/`"grid"`，默认 `"list"`）：
Q_PROPERTY + getter/setter + `goalViewModeChanged` 信号 + `writeValue` 落盘，
完整照抄 `sidebarVisible` 的四件套写法。非法值一律归一化为 `"list"`。

### 组件范式（写新 QML 前先读这几个）

- 卡片：`qml/components/StatCard.qml`（圆角/边框/`Theme.glassCard`/阴影 MultiEffect）
- 分段控件：`qml/components/SegmentedSwitch.qml`
- 弹出表单：`qml/components/AddTaskDialog.qml`（含科目选择、输入校验、`categoryManager` 用法）
- 圆环：`qml/components/FocusRing.qml`（Canvas 画法；列表小圆环可简化自绘）
- 版式定稿：`docs/设计稿/长期目标/01-列表-浅色.png`（列表+头部）、`09-列表网格-浅色.png`（网格）

### 仓库红线（摘自 `AGENTS.md` 与项目记忆，逐条遵守）

- 注释中文，解释为什么；Git 提交说明中文。
- 颜色只用 `Theme.*` 语义令牌；浅深主题都要可读。
- 动效尊重 `Theme.reduceMotion || appSettings.reduceMotion`（参照 `StatCard.qml:21` 的写法）。
- 毛玻璃只用于弹窗/工具栏；内容卡用 `Theme.glassCard` 半透明色块，禁止逐卡实时模糊。
- **QML 测试禁止断言 `item.visible === true`**（离屏级联判定不可靠），断言业务属性。

## Commands you will need

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置 | `cmake -B /tmp/pt-006 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0 |
| 构建 | `cmake --build /tmp/pt-006 -j8` | 退出码 0 |
| QML 测试 | `cd /tmp/pt-006 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest -R PomodoroTodoQmlTests --output-on-failure` | Passed |
| 全量 | `cd /tmp/pt-006 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed ... out of 12` |
| 离屏视觉稿 | 见 Step 6 | 生成 PNG |

`<Qt前缀>`：`ls ~/Qt` 或 `brew --prefix qt`。QML 源文件改动后测试从源码解析
（qmltestrunner -input），但 **qrc 内容变了必须重新构建**主程序目标。

## Scope

**In scope**：

- `qml/views/GoalsView.qml`（新建）
- `qml/components/GoalCard.qml`、`qml/components/GoalTile.qml`、`qml/components/GoalFormDialog.qml`（新建）
- `qml/components/GlyphIcon.qml`（只加 `list` 字形一个 case）
- `qml/components/Sidebar.qml`（只加一个 SidebarItem）
- `qml/MainWindow.qml`（viewIndex 加 case + StackLayout 追加子项）
- `src/services/AppSettings.h/.cpp`（只加 goalViewMode 四件套）
- `resources/qml.qrc`（注册新文件）
- `tests/qml/tst_goals_view.qml`（新建）
- `tests/ServiceTests.cpp` 若 AppSettings 相关测试需要补一条 goalViewMode 持久化用例（可选）

**Out of scope**：

- `src/services/GoalService.*` —— 服务层不改。
- 详情页 / 100 格 / 弹窗 / 音效 —— 007、008 的事。
- 其他视图的头部版式 —— 记忆红线：别"顺手修正"其它页头部控件位置。
- 拖拽排序的 UI —— `reorderGoal` 已就绪，但拖拽交互放到后续；本计划列表按 displayOrder 只读展示。
  （注意 plans/004 的维护提示：一旦列表有筛选，视图下标≠列表下标，未来做拖拽时必须映射。）

## Git workflow

- 分支：`advisor/006-goals-view`
- 每 Step 一次提交，说明用中文。建议：`新增目标列表页与侧栏入口` / `目标页双版式切换与持久化` / `新增目标表单与测试`
- 不 push、不开 PR。

## Steps

### Step 1: AppSettings 增加 `goalViewMode`

照 `sidebarVisible` 四件套。归一化：非 `"grid"` 一律回 `"list"`。

**Verify**: `cmake --build /tmp/pt-006 -j8` 退出码 0。

### Step 2: 共用卡片组件

`GoalCard.qml`（列表行，implicitHeight≈76）：左 44px 圆环（Canvas 自绘：底环
`Theme.borderSubtle`，进度弧 `achieved ? Theme.accentInk : Theme.accent`，居中百分比文字）、
中间标题 + 副行、右状态胶囊（进行中=`Theme.accentFill` 底，已达成=描边 `Theme.accentInk`）。
副行文案规则：

```
achieved  → "已达成 · " + Qt.formatDate(achievedAt, "M月d日")
否则      → doneCount + " / " + targetPomodoros + " 番茄"
            + (forecastDays > 0 ? " · 照此速度还需 " + forecastDays + " 天" : "")
```

`GoalTile.qml`（网格瓦片，160×158）：大圆环 72px 居中 + 标题 + 简短副行（不放预测）。
两者都接收整个 goal map（`property var goal`），从中取键；不各自查询。

**Verify**: 构建过 + Step 6 视觉稿里两种卡片渲染正确。

### Step 3: GoalsView 主页面

- 头部：标题「目标」+ 副标题「把长期投入折成 100 格，看得见才坚持得下去」；
  下一行左侧筛选胶囊（进行中/已达成/全部，默认**进行中**），右侧图标分段切换
  （list/grid 两段，绑定 `appSettings.goalViewMode`）。
- 内容：`viewMode === "list"` 时 Column/ListView 铺 GoalCard；`"grid"` 时
  GridLayout 3 列铺 GoalTile。数据 `property var goals: []`，
  `refresh()` 调 `goalService.getGoals()` 后按筛选过滤。
- 刷新时机：`Component.onCompleted`、`onPageActiveChanged`（pageActive 才刷）、
  `Connections { target: goalService; onGoalsChanged: refresh() }`（enabled 绑 pageActive）。
  参照 `MonthGoalView.qml` 开头 30 行的既有模式。
- 空态：居中文案 + 「新建目标」按钮。右上角常驻「新建」按钮。
- `operationFailed` → `root.errorText` 属性（MainWindow 的 toast 由 008 统一接，本期先
  页面内展示一行错误文字即可）。
- 点击卡片：暂发 `goalOpened(goalId)` 信号，本期无详情页，占位即可（007 接管）。

**Verify**: 构建过；Step 5 测试过。

### Step 4: 表单 + 路由 + 侧栏

- `GoalFormDialog.qml` 照 `AddTaskDialog.qml` 的骨架：标题输入
  （`maximumLength: goalService.maxTitleLength`）、科目选择（`categoryManager`，必选）、
  目标番茄数（1..maxTargetPomodoros 数字输入）、起始日期（默认今天，允许过去——
  帮助文案「填过去的日期可把已有专注记录计入进度」）、截止日期（可选，「长期目标」开关）。
  保存调 `goalService.addGoal/updateGoal`，返回 false 时不关窗、显示 `operationFailed` 文案。
- `MainWindow.qml`：`viewIndex` 加 `case "goals": return 7;`（注释：追加栈尾），
  StackLayout 尾部加 `GoalsView { pageActive: root.currentView === "goals" }`。
- `Sidebar.qml`：countdown 项后加「目标」SidebarItem（icon `target`，
  `onClicked: root.itemClicked("goals")`）。
- `GlyphIcon.qml` 加 `list` 字形。
- `resources/qml.qrc` 注册 4 个新 QML 文件（照既有 alias 格式）。

**Verify**: `cmake --build /tmp/pt-006 -j8` 退出码 0；
`grep -c "goals" qml/MainWindow.qml` ≥ 3。

### Step 5: QML 测试 `tests/qml/tst_goals_view.qml`

参照 `tst_countdown_ui.qml` 的骨架（mock 上下文对象注入）。用例：

1. 空列表 → 空态属性成立（断言 `goalsCount === 0` 与空态文字的 `text` 内容，**不断言 visible**）。
2. 注入两条 mock goals（一进行一达成）→ 默认筛选「进行中」只剩 1 条；切「全部」是 2 条。
3. 副行文案：forecastDays=21 时含「还需 21 天」；forecastDays=-1 时不含「还需」。
4. viewMode 切换：切到 grid 后 `goalViewMode` 属性为 "grid"（mock appSettings 对象）。
5. 表单校验：科目为空时保存被拒（mock goalService.addGoal 返回 false，断言窗未关/错误文案非空）。

mock goalService 用 QtObject 提供 `getGoals()` 返回预置数组 + `goalsChanged` 信号，
参照 `tst_focus_view.qml:133-160` 的 mock 写法。等待用 `tryCompare`，不用固定 `wait()`。

**Verify**:
`cd /tmp/pt-006 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest -R PomodoroTodoQmlTests --output-on-failure` → Passed（含新文件的全部用例）。

### Step 6: 离屏视觉稿 + 全量回归

用项目已有的离屏截图技法出两张图（列表/网格各一，浅色主题）供维护者验收：

```bash
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
  /Users/zerionlito/Qt/6.9.0/macos/bin/qml -I . <临时harness>.qml
```

harness 写在 scratchpad，注入 mock 数据渲染 `GoalsView`，`grabToImage` 存
`docs/设计稿/长期目标/实现-列表.png` 与 `实现-网格.png`。
（要点：必须 `QSG_RHI_BACKEND=software`；Loader 包 Item 防止 margins 被覆盖。）

**Verify**: 两张 PNG 存在且与定稿版式一致（人工比对）；
`cd /tmp/pt-006 && ctest` → `100% tests passed ... out of 12`。

## Done criteria

- [ ] 全量 12 套件通过
- [ ] `grep -rn "goalService" qml/ | wc -l` ≥ 5（不再是零引用）
- [ ] `grep -n "case \"goals\": return 7" qml/MainWindow.qml` 命中（或等价写法）
- [ ] `grep -n "goalViewMode" src/services/AppSettings.h` 命中
- [ ] `tests/qml/tst_goals_view.qml` 存在且 ≥ 5 个用例，全部使用 `tryCompare`/属性断言
- [ ] 两张实现视觉稿已生成
- [ ] 既有视图索引 0-6 未被改动（`git diff qml/MainWindow.qml` 中 viewIndex 只有新增行）
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- Drift check 失败（`viewIndex` 结构或 GoalService 签名与摘录不符）。
- `getGoals()` 返回的键与 "Current state" 列出的不一致（说明服务层又被改了）。
- 新增视图后任何**既有** QML 测试失败——先报告，不要为让它过而改既有测试。
- 表单需要的科目列表拿不到（`categoryManager` 上下文属性在测试环境不可用且 mock 不了）。
- 发现必须改 `GoalService.cpp` 才能完成本计划。

## Maintenance notes

- 007 会把 `goalOpened(goalId)` 接成页内详情；008 的弹窗「查看目标」也要跳这里。
- 视图切换按钮将来若加动画，记得走 reduceMotion。
- 拖拽排序未做：做的时候读 plans/004 维护提示（筛选下标映射陷阱）。
