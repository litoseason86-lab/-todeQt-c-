# Plan 023: 合并重复刷新信号并按事件循环批处理页面查询

> **Executor instructions**: 先用调用计数测试证明重复，再引入最小合并器。不要改变统计口径或完成动画时序。完成后更新索引。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/RoutineManager.cpp qml/components/RefreshCoalescer.qml qml/views/DashboardView.qml qml/views/TodayTaskView.qml qml/views/StatisticsView.qml resources/qml.qrc tests/ServiceTests.cpp tests/qml/tst_refresh_coalescer.qml tests/qml/tst_dashboard_view.qml tests/qml/tst_today_rollover.qml tests/qml/tst_statistics_logical_day.qml
> ```

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

一个业务动作会同步扇出多个失效信号：专注完成既发 `focusCompleted` 又间接触发 `tasksChanged`；换库既发 `databaseChanged`，CategoryManager 转发 `categoriesChanged`，RoutineManager 又直接监听两者。Dashboard、Today、Statistics 对每个 signal 都立即执行整页 SQL 刷新，导致同一事件循环重复查询和重建 model。目标不是少刷新，而是把同一批同步失效合成一次，同时保留跨事件循环的真实更新。

## Current state

- `RoutineManager` 同时连接 `CategoryManager::categoriesChanged` 和 `DatabaseManager::databaseChanged`；CategoryManager 本身已把 databaseChanged 转发为 categoriesChanged，所以换库会发两次 routinesChanged。
- `DashboardView`、`TodayTaskView` 分别监听 tasks/categories/focus/routines/logical-day 并直接 `refresh()`。
- `StatisticsView` 对 tasks/focus/categories/logical-day 也直接 `refresh()`；`goalsChanged` 只刷新 achieved goals，这个细粒度优化必须保留。
- Dashboard/Today 有 850ms `completionRefreshTimer` 保护任务完成动画。`completionRefreshDelayActive` 时 tasksChanged 当前被丢弃，timer 到点再刷新；本计划不能破坏这个边界。
- QML 资源由历史 `resources/qml.qrc` 管理，新增组件必须登记并通过 manifest test。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-023 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-023 --target PomodoroTodoTests QmlResourceManifestTests PomodoroTodo -j8` | exit 0 |
| 定向后端 | `cd /tmp/pt-023 && ctest -R '^(PomodoroTodoTests|QmlResourceManifestTests)$' --output-on-failure` | 2/2 通过 |
| 定向 QML | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_refresh_coalescer.qml -import qml -import qml/components` | 通过 |
| 全量 | `cd /tmp/pt-023 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | 全部通过 |

## Suggested executor toolkit

- 使用 `qt-qml`：`Qt.callLater` 生命周期、显式 id、Connections 与异步断言。
- 使用 `qt-ui-design` 仅核对“无视觉变化”；本计划不得新增 loading 动画或可见 UI。

## Scope

**In scope**：`src/services/RoutineManager.cpp`、`qml/components/RefreshCoalescer.qml`（新建）、`qml/views/DashboardView.qml`、`qml/views/TodayTaskView.qml`、`qml/views/StatisticsView.qml`、`resources/qml.qrc`、`tests/ServiceTests.cpp`、`tests/qml/tst_refresh_coalescer.qml`（新建）、`tests/qml/tst_dashboard_view.qml`、`tests/qml/tst_today_rollover.qml`、`tests/qml/tst_statistics_logical_day.qml`。

**Out of scope**：改变任何 SQL/统计口径；移除页面 active 守卫；调整 850ms 完成动画延迟；合并 `goalsChanged -> refreshAchievedGoals` 成整页刷新；加 debounce 毫秒等待；修改 FocusTimer/TaskManager signal；迁移 QML 资源系统。

## Git workflow

- 分支：`advisor/023-coalesce-refresh-signals`
- 中文提交信息：`合并页面重复刷新信号`
- 不 push，不开 PR。

## Steps

### Step 1: 创建合并器框架与调用计数红灯

先创建 `qml/components/RefreshCoalescer.qml` 与 `tests/qml/tst_refresh_coalescer.qml` 框架，并登记 qrc。根类型用 `QtObject`，公开：

- `property bool active: true`
- `property bool scheduled: false`（只供诊断/测试读取，调用方不得赋值）
- `signal triggered()`
- `function request()`
- `function cancel()`（使已排队回调失效，供完成动画定时刷新前消除尾随刷新）

在页面既有 mock 中给实际 refresh 会调用的 service getter 加计数。先写红灯：同一同步调用栈连续发 tasksChanged + focusCompleted + categoriesChanged，下一事件循环后整页 refresh 调用增量应为 1，而当前实现会大于 1。

另加 C++ 测试：一次 `DatabaseManager::initialize()` 引发的 `RoutineManager::routinesChanged` 增量必须恰好 1；当前直接+间接连接应为 2。测试需先确保 CategoryManager 与 RoutineManager 单例均已构造，避免连接建立时序造成假绿。

**Verify**：当前产品代码下测试按预期失败；若调用增量已经是 1，STOP 检查 signal 是否未连接或页面未 active。

### Step 2: 实现单事件循环合并器

`request()` 在未 scheduled 时置 true，并用 `Qt.callLater` 排队；回调先清 scheduled，再在 `active` 为 true 时发 `triggered()`。多次 request 只能排一个 callback；触发完成后的下一次 request 必须产生下一次 triggered。组件没有 Timer、固定等待、动画或视觉对象。

注意销毁安全：回调不能访问已经销毁的外部页面对象；只操作组件自身。若项目 Qt 版本下销毁后的 callLater callback 行为不安全，使用组件内 generation token/guard，不要改成毫秒 debounce。

**Verify**：组件测试覆盖同步 3 次→1 次、下一轮再请求→累计 2 次、active 在回调前变 false→不触发。

### Step 3: 去掉 RoutineManager 的重复数据库连接

删除 `DatabaseManager::databaseChanged -> routinesChanged` 直连，保留并注释 `CategoryManager::categoriesChanged -> routinesChanged`。CategoryManager 已完整转发换库事实，这条单链同时覆盖换库和 CRUD，避免双发。

不要删除 `#include DatabaseManager.h`，除非 rg 证明本文件其他实现完全不用它；按编译器实际需要处理，不做机械清理。

**Verify**：C++ 精确计数测试通过；科目增删改触发例行刷新既有测试仍通过。

### Step 4: 三个页面接入合并器

每页放一个 `RefreshCoalescer`，`active: root.pageActive`，`onTriggered: root.refresh()`。把同步数据失效 handler 改成 `request()`：

- Dashboard/Today：tasks、categories、focusCompleted、routines、logical-day。
- Statistics：tasks、focusCompleted、categories、logical-day。
- `goalsChanged` 继续直接 `refreshAchievedGoals()`。
- pageActive 从 false→true 的首刷继续直接执行，不延迟首屏。
- Dashboard/Today 在 `completionRefreshDelayActive` 时仍忽略 tasksChanged；850ms timer 到点的 refresh 保持直接执行并在执行前取消/消耗可能已排队的 request。为此给合并器增加 `cancel()` 或 generation 机制，防止 timer refresh 后紧跟一次旧 callback。
- 错误 signal 不进入合并器，仍即时写错误文本。

补中文注释说明“只合并同一事件循环的失效，不吞跨轮更新”。

**Verify**：三个页面的组合 signal 调用增量各为 1；分隔到两个 `Qt.callLater` 轮次的两次失效得到 2 次刷新；完成延迟测试仍保持 850ms 语义。

### Step 5: 全量回归与静态检查

运行全量后检查：

```bash
rg -n "on(TasksChanged|FocusCompleted|CategoriesChanged|RoutinesChanged)" qml/views/{DashboardView,TodayTaskView,StatisticsView}.qml
git diff --check
```

**Verify**：所有目标 handler 都请求合并或保留明确特殊分支；资源 manifest、QML、C++、全量测试全绿；无视觉变化。

## Test plan

- RefreshCoalescer：同轮合并、跨轮不吞、inactive 抑制、cancel 防旧回调。
- RoutineManager：换库恰好一次，科目 CRUD 仍一次。
- Dashboard/Today/Statistics：同轮多 signal 只一次 refresh，跨轮两次仍两次。
- Dashboard/Today：完成动画延迟不被提前刷新或尾随重复刷新破坏。
- QML 资源清单回归。

## Done criteria

- [ ] 换库只发一次 routinesChanged。
- [ ] 三页同一事件循环的多失效只做一次整页 refresh。
- [ ] 跨事件循环更新不被吞，pageActive 首刷不延迟。
- [ ] 完成动画 850ms 延迟和 achieved-goals 局部刷新保持原语义。
- [ ] 无新增 Timer/debounce/视觉效果。
- [ ] C++、QML、manifest、全量测试全绿，`git diff --check` 无输出。
- [ ] 023 状态行已更新。

## STOP conditions

- signal 已改为跨线程 queued connection，单事件循环假设不成立。
- 页面 refresh 有调用顺序依赖，合并后会改变用户可见数据语义。
- 850ms 完成动画无法在不修改 TaskItem 的情况下保持。
- Qt 版本的 `Qt.callLater` 无法安全处理组件销毁且没有局部 guard 方案。
- 修复要求改 SQL、FocusTimer 或 TaskManager。

## Maintenance notes

- 这不是 debounce。不要以后加 50/100ms 延迟“提高命中率”；那会增加 UI 延迟并掩盖 signal 风暴。
- reviewer 应核对 getter 调用计数，而不是只看帧率主观感觉。
