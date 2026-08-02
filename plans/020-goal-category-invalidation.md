# Plan 020: 科目变更时刷新目标并阻止表单静默改绑

> **Executor instructions**: 按步骤执行并验证。完成后更新索引；遇到 STOP 条件不要把服务彼此耦合。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/GoalService.h src/services/GoalService.cpp src/main.cpp qml/components/GoalFormDialog.qml tests/GoalServiceTests.cpp tests/qml/tst_goals_view.qml
> ```

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

目标列表的科目名、颜色和进度依赖科目表，但 `GoalService` 不监听 `categoriesChanged`，所以改名、改色或删除科目后，已打开的目标页可能保持陈旧数据。更严重的是编辑目标时，如果原科目已被删除，表单会自动选中第一项；用户只改标题也会在无提示的情况下把目标改绑到无关科目。

## Current state

- `GoalService` 只监听 `DatabaseManager::databaseChanged` 和 `AppSettings::dayStartHourChanged`；两条路径都会清进度缓存并发 `goalsChanged()`。
- `CategoryManager` 已有 `categoriesChanged()`，由增删改成功后发出。
- `qml/views/GoalsView.qml:207-224` 在 pageActive 时监听 `goalsChanged()` 并刷新；缺的是后端失效信号。
- `GoalFormDialog.refreshCategories(selectedCategoryId)` 搜索不到 id 时无条件 `currentIndex = 0`：

  ```qml
  if (categoryCombo.currentIndex < 0 && root.categories.length > 0)
      categoryCombo.currentIndex = 0
  ```

- 表单自身已经监听 `categoriesChanged`，因此问题不是“列表不刷新”，而是刷新后的缺失选择被静默替换。
- 跨服务连接应在 `src/main.cpp` 装配；`GoalService` 不应 include `CategoryManager`。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-020 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-020 --target GoalServiceTests PomodoroTodo -j8` | exit 0 |
| 后端 | `cd /tmp/pt-020 && ctest -R '^GoalServiceTests$' --output-on-failure` | 1/1 通过 |
| QML | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_goals_view.qml -import qml -import qml/components` | 通过 |
| 全量 | `cd /tmp/pt-020 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | 全部通过 |

## Suggested executor toolkit

- 使用 `qt-qml` 处理 ComboBox 状态、绑定和 QML 测试。
- 使用 `qt-ui-design` 校验缺失科目错误文字、键盘焦点和非颜色提示。

## Scope

**In scope**：`src/services/GoalService.h/.cpp`、`src/main.cpp`、`qml/components/GoalFormDialog.qml`、`tests/GoalServiceTests.cpp`、`tests/qml/tst_goals_view.qml`。

**Out of scope**：修改 CategoryManager 的 CRUD；自动删除无科目目标；给目标自动改绑；修改目标 SQL 口径或 schema；重新设计整个表单；在 GoalService 构造函数中依赖 CategoryManager。

## Git workflow

- 分支：`advisor/020-goal-category-invalidation`
- 中文提交信息：`科目变更时刷新目标并阻止静默改绑`
- 不 push，不开 PR。

## Steps

### Step 1: 先补后端与表单红灯测试

在 `GoalServiceTests` 增加“科目数据失效会恰好发一次 `goalsChanged`”的用例。直接调用将新增的失效入口，避免单元测试伪造 main.cpp 装配。再断言该入口不发 `goalProgressed` 或 `milestoneReached`：改名/改色不是进度事件，不能制造奖励。

扩展 `tst_goals_view.qml` 的 CategoryManager mock：

- 编辑已有目标，删除当前选中科目并发 `categoriesChanged` 后，ComboBox 保持 `currentIndex == -1`，出现 `原科目已删除，请重新选择`，submit 返回 false。
- 同一情形不得自动选中剩余列表第 0 项。
- 新建目标仍允许默认选中第一项，避免退化现有快捷路径。
- 当前选中科目仍存在时，改名/改色刷新后仍保持同 id。

不断言 `visible === true`；暴露必要 readonly 测试属性或用 `findChild` 读取 index/error，并用 `tryCompare`。

**Verify**：API 未实现前后端测试编译失败，当前 QML 的“删除后 index=0”断言失败。

### Step 2: 增加无反向依赖的目标失效入口

在 `GoalService` 增加普通 public slot/方法 `invalidateCategoryData()`，不要标 `Q_INVOKABLE`。它只发一次 `goalsChanged()`。注释说明科目是目标聚合 SQL 的输入，改名、改色或删除后页面必须重查。

不要在这里清 `m_lastDoneCounts`：改名/改色不改变进度；删除后目标的 category_id 会变 NULL，无法继续累积，用户重新选择科目时 `updateGoal()` 已在提交后用新 `doneCount` 重建该目标基线。无条件清缓存反而会吞掉下一次真实 `+1` Toast。

在 `src/main.cpp` engine 加载前连接：

```cpp
QObject::connect(CategoryManager::instance(), &CategoryManager::categoriesChanged,
                 GoalService::instance(), &GoalService::invalidateCategoryData);
```

**Verify**：后端测试与应用目标编译通过；`GoalService.cpp` 不 include `CategoryManager.h`。

### Step 3: 区分“新建默认值”与“编辑缺失值”

把 `refreshCategories` 改为显式接收是否允许 fallback，例如 `refreshCategories(selectedCategoryId, allowFallback)`：

- `openForAdd()` 传 true；列表非空时可选第 0 项。
- `openForEdit()` 传 false；找不到原 id 时保持 -1 并设置精确错误文案。
- `onCategoriesChanged` 根据 `root.editing` 决定：编辑态缺失不 fallback；新建态可 fallback。
- 找到同 id 后清除“原科目已删除”这一特定错误，但不得清掉其他保存/数据库错误。
- submit 继续通过既有“请先为目标选择科目”校验挡住无选择保存，并把焦点移到 ComboBox。

所有文案 `qsTr()`；错误不能只靠边框颜色表达。

**Verify**：四个 QML 场景通过；现有目标页用例继续通过。

### Step 4: 全量回归和连接审计

**Verify**：定向及全量测试全绿；`rg -n "CategoryManager.*GoalService|invalidateCategoryData" src` 只显示 main 装配和服务声明/实现；`git diff --check` 无输出。

## Test plan

- 科目失效只发一次目标刷新，不制造奖励信号、不清掉无关进度基线。
- 编辑态当前科目删除：不自动改绑、明确错误、不能保存。
- 编辑态科目改名/改色：仍按 id 保持选择。
- 新建态：仍默认首项。
- 页面 active/inactive 的既有刷新规则不变。

## Done criteria

- [ ] CategoryManager 成功变更后 GoalService 发布一次目标失效。
- [ ] 科目改名/改色不清进度缓存、不制造奖励信号。
- [ ] GoalService 不依赖 CategoryManager 头文件或单例。
- [ ] 编辑缺失科目不再静默选第一项。
- [ ] 错误用文字表达且保存被阻止；新建流程无回归。
- [ ] 后端、QML、全量测试全绿，`git diff --check` 无输出。
- [ ] 020 状态行已更新。

## STOP conditions

- 科目变更信号签名或目标 SQL 已发生结构性变化。
- 修复需要修改目标表 schema 或自动改写用户目标。
- 只能通过 GoalService 直接持有 CategoryManager 才能实现。
- QML ComboBox 已被替换为不同选择组件，测试钩子不再适用。

## Maintenance notes

- reviewer 要确认这里不清全局进度缓存；重新绑定科目时 `updateGoal()` 已负责按新口径重建单目标基线。
- 未来若 UI 支持“无科目目标”，这条阻止保存的契约必须和 GoalService 输入校验一起调整，不能只改表单。
