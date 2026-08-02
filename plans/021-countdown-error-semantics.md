# Plan 021: 统一倒计时失败语义并让页面显示可恢复错误

> **Executor instructions**: 逐步执行。先让测试转红，再修服务与页面；完成后更新索引。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/CountdownService.h src/services/CountdownService.cpp qml/views/CountdownView.qml tests/CountdownServiceTests.cpp tests/CoreLogicTests.cpp tests/qml/tst_countdown_ui.qml
> ```

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

倒计时服务查询失败时保留旧 model 并发 `errorOccurred`，但页面完全不监听；初次加载失败会被渲染成“还没有目标”，删除和排序的 bool 返回值也被丢弃。用户看到的是合法空态或没有任何反馈，无法区分“没有数据”和“数据读写失败”。这不是文案问题，是错误状态在服务—页面边界被吞掉。

## Current state

- `CountdownService` 的失败 signal 名为 `errorOccurred`，而项目其他业务服务统一使用 `operationFailed`。
- databaseChanged 路径中 `initializeDatabase()` 失败只设 `m_databaseReady=false`，没有发错误。
- `loadGoals()` 查询失败时不替换 model，这是正确的“保留旧数据”语义，但没有成功重载 signal，也没有公开重试入口。
- `CountdownView.qml` 没有错误属性或 Connections；删除、上移、下移调用不检查 bool。
- 空态条件只有 `!root.primaryGoal()`，因此失败且 model 为空时必然显示“还没有目标倒计时”。
- 错误 UI 必须在有旧数据时作为持久 banner 出现，在无数据时替代空态，并提供可键盘操作的“重试”。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-021 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-021 --target CountdownServiceTests CoreLogicTests PomodoroTodo -j8` | exit 0 |
| 后端 | `cd /tmp/pt-021 && ctest -R '^(CountdownServiceTests|CoreLogicTests)$' --output-on-failure` | 2/2 通过 |
| QML | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml -import qml -import qml/components` | 通过 |
| 全量 | `cd /tmp/pt-021 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | 全部通过 |

## Suggested executor toolkit

- 使用 `qt-qml` 处理 Connections、状态属性和离屏测试。
- 使用 `qt-ui-design` 设计错误 banner/空态替代、44px 重试按钮与焦点可见性。

## Scope

**In scope**：`src/services/CountdownService.h/.cpp`、`qml/views/CountdownView.qml`、`tests/CountdownServiceTests.cpp`、`tests/CoreLogicTests.cpp`、`tests/qml/tst_countdown_ui.qml`。

**Out of scope**：数据库 schema；重做 CountdownDialog；清空旧 model；全局 toast 系统；自动无限重试；改变倒计时排序或逻辑日口径。

## Git workflow

- 分支：`advisor/021-countdown-error-semantics`
- 中文提交信息：`统一倒计时失败语义并提供重试`
- 不 push，不开 PR。

## Steps

### Step 1: 先补失败状态红灯测试

后端测试先把所有 `CountdownService::errorOccurred` spy 改为目标名 `operationFailed`，并增加：

- databaseChanged 后初始化失败发明确错误。
- `reload()` 查询失败返回 false、保留旧 model、发 operationFailed。
- 障碍移除后 `reload()` 返回 true、发 `goalsReloaded()`，model 与主目标更新。

QML fake service增加 `operationFailed(message)`、`goalsReloaded()`、`reload()` 计数及可控 bool 返回。用例覆盖：

- 无数据 + operationFailed：状态为 error，不是 empty，错误文字保留。
- 有旧数据 + operationFailed：列表数据不丢，错误 banner 同时存在。
- 重试成功：调用 reload 一次，收到 goalsReloaded 后清错。
- delete/reorder 返回 false：页面不静默，若 mock 不发 signal 则显示兜底错误。

为测试暴露 `readonly property bool showingErrorState` / `showingEmptyState` 与错误文本即可；禁止断言子项 `visible === true`，使用 `tryCompare`。

**Verify**：未改产品代码时，signal rename 导致编译红灯，QML 错误状态用例失败。

### Step 2: 统一服务失败与成功重载契约

在 `CountdownService`：

- 把 `errorOccurred` 重命名为 `operationFailed`，一次性更新所有生产/测试引用；`rg -n "errorOccurred" src qml tests` 最终不得命中 CountdownService 旧契约。
- 新增 `void goalsReloaded()`，仅在 `loadGoals()` 完整查询成功、model 与 primary goal 已同步后发出。
- 新增 `Q_INVOKABLE bool reload()`：调用 `ensureDatabaseReady()`/`loadGoals()`，成功 true、失败 false；避免递归双 load，明确拆分 ensure 与 reload 的调用关系。
- databaseChanged 的 initialize 失败必须发 `operationFailed("初始化倒计时数据库失败")`。
- 查询失败继续保留旧 model，不发 `goalsReloaded`。

注释说明“失败保留旧数据，成功 signal 才允许 UI 清除错误”。

**Verify**：后端测试全绿；旧 signal 的 rg 判据无匹配。

### Step 3: 页面建立持久、可恢复的错误状态

在 `CountdownView` 增加 `property string loadError` 和可测试 readonly 状态。Connections 监听：

- `onOperationFailed(message)`：保存非空错误，空 message 使用 `倒计时数据操作失败`。
- `onGoalsReloaded()`：清空错误。

所有 delete/reorder 调用先清空当前操作错误并检查 bool；若返回 false 且同步 signal 没给出文字，写精确兜底。不要假设失败 signal 总是同步。

UI 规则：

- 有旧数据：在标题下显示紧凑错误 banner，列表仍可见。
- 无数据且有错误：用错误卡替代“还没有目标”，包含错误文字与 `重试`。
- 无数据无错误：才显示原空态。
- 重试按钮调用 service.reload()，最小高度 44px、支持 Tab/Enter/Space、有焦点态；状态用文字/图标表达，不能只靠危险色。
- 新增字符串全部 `qsTr()`，颜色只用 Theme 令牌。

**Verify**：QML 定向用例通过；没有 `visible === true` 断言或固定新增 wait。

### Step 4: 全量回归与契约清理

运行：

```bash
rg -n "CountdownService::errorOccurred|onErrorOccurred" src qml tests
git diff --check
```

**Verify**：rg 无旧契约；定向和全量测试全绿；只改授权文件和索引。

## Test plan

- 初始化、读取、增删改、排序失败都走 operationFailed。
- reload 失败保留旧 model 且不发 goalsReloaded；成功才清错。
- 无数据错误不冒充空态；有旧数据错误不清空内容。
- delete/reorder 对“false 且无 signal”有 UI 兜底。
- 重试键盘可达且只调用一次。

## Done criteria

- [ ] CountdownService 不再暴露/使用 `errorOccurred`。
- [ ] `goalsReloaded` 只代表成功完成的 model 重载。
- [ ] 页面能区分 empty、stale-with-error、empty-with-error。
- [ ] 所有写操作检查 bool，重试可用且可键盘操作。
- [ ] 后端、QML、全量测试全绿，`git diff --check` 无输出。
- [ ] 021 状态行已更新。

## STOP conditions

- `errorOccurred` 已成为外部插件/公共 ABI，不能安全重命名。
- loadGoals 已被异步化，当前同步 signal/返回值契约不成立。
- 错误恢复需要 schema 修复或清空用户数据。
- 为显示错误必须重构整个页面导航。

## Maintenance notes

- reviewer 重点看“成功 signal 才清错”，否则一次失败后紧接着的任意 UI 操作可能把真实错误擦掉。
- 未来若把读取改为异步，`reload()` 应改成请求型 API，页面仍可保留本计划的三态模型。
