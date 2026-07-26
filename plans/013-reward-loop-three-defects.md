# Plan 013: 修奖励回路刚上线就带的三个缺陷（粒子被遮挡 / 失败态伪装成空态 / 复选框绑定断裂）

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> 本仓库有一批**尚未提交**的工作区改动（长期目标与奖励机制功能），本计划针对的正是这批代码，
> `git diff <SHA>..HEAD` 形式的漂移检查在这里无效。改用 grep 判据：
>
> ```bash
> grep -n "goalRewardParticles" qml/MainWindow.qml                      # 必须命中
> grep -n "goalsEmptyState" qml/views/GoalsView.qml                     # 必须命中
> grep -n "goalLongTermCheck" qml/components/GoalFormDialog.qml         # 必须命中
> grep -n "test_reduceMotionCreatesNoRewardParticles" tests/qml/tst_mainwindow_ui_optimization.qml  # 必须命中
> ```
>
> 任一不命中 → STOP，报告实际看到的内容。

## Status

- **Priority**: P1
- **Effort**: S-M
- **Risk**: LOW（三处都是局部 QML 修复，无 C++ 改动，无数据改动）
- **Depends on**: none（可与 plans/010-012 并行）
- **Category**: bug
- **Planned at**: commit `43ba2ee`（+ 未提交工作区），2026-07-26

## Why this matters

长期目标 + 奖励机制刚落地，测试全绿。但有三个缺陷是**测试结构本身看不见**的：

1. **庆祝粒子一个像素也没到过屏幕上。** 三条奖励通道（音效 / 弹窗 / 粒子）里的粒子，
   被它自己要装饰的那个弹窗完全盖住了。每次庆祝都在付出对象创建 + 800ms 动画的代价，
   渲染在没人看得见的地方。之所以没被发现，是因为**唯一那条粒子测试测的是反面**
   （减少动效时粒子数为 0），从来没有一条测试问过「正常情况下粒子出现了吗」。

2. **数据库出错时，目标页告诉用户「你还没有目标」。** 同一批代码里，统计页把这件事
   做对了，还写了注释说明为什么；目标页做反了。用户的长期目标看起来像是被清空了，
   页面还热情地邀请他「新建目标」。

3. **「长期目标」复选框第一次被点击后，就和它控制的截止日期字段失去同步。**
   Qt Quick Controls 的经典双向绑定断裂：用户点一下 checkbox，声明式绑定被永久摧毁，
   之后每次打开表单，复选框显示的是上一次的残留状态，而它下面的截止日期输入框
   显示的是正确状态——两者当场自相矛盾。

三个都小、都便宜、都在刚交付的功能里。

## Current state

### 缺陷 1：粒子被弹窗遮挡

`qml/MainWindow.qml:841-846`——粒子层是 MainWindow 根 `Item` 的普通子项：

```qml
CompletionParticles {
    id: rewardParticles
    objectName: "goalRewardParticles"
    anchors.fill: parent
    z: 110
}
```

`qml/components/MilestoneDialog.qml` 是一个 **`Popup`**，且 `modal: true`（:22），
还带自定义 `Overlay.modal` 遮罩（:60-61）。

Qt Quick Controls 的 `Popup` 渲染在**窗口的 overlay 层**上，那一层整体位于窗口
contentItem **之上**。`z: 110` 只在 MainWindow 的兄弟节点之间排序，**跨不过这个边界**。

迸发原点（`qml/MainWindow.qml:251-255`）：

```qml
Qt.callLater(function() {
    if (root.activeMilestoneDialog === dialog)
        rewardParticles.burst(dialog.x + dialog.width / 2,
                              dialog.y + dialog.height / 2)
})
```

即弹窗正中心。而 `qml/components/CompletionParticles.qml:29` 的
`var travelDistance = 38`——粒子全程只飞 38 像素，整个轨迹都在弹窗矩形内部。
所以不是「被遮罩压暗」，是**被弹窗本体完全盖住**。

`CompletionParticles` 组件本身是好的，另一处用法（`qml/components/TaskItem.qml:285`，
任务完成时的庆祝）工作正常——那里没有弹窗压在上面。

### 缺陷 2：目标页把查询失败渲染成空态

`qml/views/GoalsView.qml:76-83`：

```qml
function refresh() {
    if (!root.goalServiceRef || !root.goalServiceRef.getGoals)
        return
    root.errorText = ""
    root.goals = root.goalServiceRef.getGoals() || []      // ← 失败时得到 []
    if (root.detailOpen)
        root.refreshDetail()
}
```

`GoalService` 报告查询失败的方式是「返回空列表 + 同步发 `operationFailed` 信号」。
`GoalsView` 的处理器（`:208-214`）会把 `errorText` 设好，所以**错误提示是显示得出来的**，
但 `root.goals` 已经被无条件赋成 `[]`，于是空态也同时出现：

```qml
// qml/views/GoalsView.qml:393-397
objectName: "goalsEmptyState"
...
visible: root.goalsCount === 0        // ← 没有考虑 errorText
```

结果：用户同时看到「目标数据加载失败」和「没有进行中的目标 / 新建目标」。

**同一批代码里的正确写法**在 `qml/views/StatisticsView.qml:397-410`，
连注释都写好了理由：

```qml
function refreshAchievedGoals() {
    root.achievedGoalsError = ""
    ...
    const allGoals = root.goalServiceRef.getGoals() || []
    // C++ 服务以"空数组 + operationFailed"报告查询失败；失败时保留旧数据，
    // 不能把数据库故障伪装成"用户还没有达成目标"。
    if (root.achievedGoalsError.length > 0)
        return
    ...
}
```

第二处同源问题在 `refreshDetail()`（`qml/views/GoalsView.qml:130-140`）：

```qml
var loaded = root.goalServiceRef.getGoal(root.openGoalId)
if (!loaded || Number(loaded.id || -1) <= 0) {
    if (root.errorText.length === 0)
        root.errorText = qsTr("目标不存在或已被删除")
    root.closeGoal()          // ← 无论是"真删了"还是"查询失败"都把用户踢出详情页
    return
}
```

`getGoal` 对「目标已删除」和「SQL 失败」返回同样的空 map，区别只在于后者会发
`operationFailed`。所以数据库临时出错（备份进行中、恢复中）会把正在看详情的用户踹回列表。

### 缺陷 3：复选框绑定断裂

`qml/components/GoalFormDialog.qml:319-325`：

```qml
CheckBox {
    objectName: "goalLongTermCheck"
    Layout.leftMargin: Theme.space16
    text: qsTr("长期目标（不设截止日期）")
    checked: root.longTerm          // ← 声明式绑定
    onToggled: root.longTerm = checked
}
```

Qt Quick Controls 在用户交互时**直接写 `checked` 属性**，这会永久摧毁
`checked: root.longTerm` 这条绑定。而 `root.longTerm` 有两个写入点：

- `:87` `openForAdd()` → `root.longTerm = true`
- `:99` `openForEdit()` → `root.longTerm = deadlineField.text.length === 0`

用户点过一次复选框之后，这两处赋值**再也不会更新复选框的显示**。
与此同时 `:335` 的 `deadlineField.enabled: !root.longTerm` **仍然跟随** `root.longTerm`，
`submit()`（`:130`）也仍然按 `root.longTerm` 分支。

于是表单会出现这种自相矛盾的状态：复选框「长期目标（不设截止日期）」处于勾选，
它正下方的截止日期输入框却是可编辑的、还填着日期。用户按看到的状态去操作，
就可能存下与他意图相反的设置。

**没有任何测试碰过 `goalLongTermCheck` 或 `goalDeadlineField`。**

### 项目约定（违反即缺陷）

- 颜色只能用 `Theme.qml` 的语义令牌，禁止硬编码色值；状态不得只靠颜色表达。
- 动效必须支持 `reduceMotion`，且**无限循环动画和装饰粒子必须真正停止**，
  不是把 `duration` 归零。`CompletionParticles.burst()` 已经做对了（直接不创建对象），
  你的改动**不能破坏这一点**。
- **QML 测试硬规则：绝不允许断言 `item.visible === true`**（离屏沙箱里可见性会级联，
  结果不可靠）。用 `tryCompare` / `tryVerify`，不要用固定 `wait()`。
- 注释用中文，解释「为什么」和「边界条件」。跨层调用、信号传播、动画状态机属于必须注释的类别。

## Commands you will need

构建目录**必须在仓库外**，且**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-013 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-013 -j8` | exit 0 |
| QML 测试 | `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` | 通过 |
| 全量 | `cd /tmp/pt-013 && ctest --output-on-failure` | `100% tests passed ... out of 12` |

## Scope

**In scope**：
- `qml/MainWindow.qml` — 粒子层的宿主与迸发原点
- `qml/views/GoalsView.qml` — 失败态处理
- `qml/components/GoalFormDialog.qml` — 复选框绑定
- `tests/qml/tst_mainwindow_ui_optimization.qml` — 粒子正向用例
- `tests/qml/tst_goals_view.qml` — 失败态与复选框用例

**Out of scope**（看着相关也不许碰）：
- **任何 C++ 文件。** 本计划零 C++ 改动。若你认为必须改 `GoalService` 才能区分
  「已删除」和「查询失败」——**STOP 并报告**，不要动手（见 Step 3 的替代做法）。
- `qml/components/CompletionParticles.qml` —— 组件本身是对的，另一个调用方
  （`TaskItem.qml:285`）依赖它现在的行为。**特别是 `:21` 那个 `reduceMotion` 早退，
  一个字都不要改。**
- `qml/components/MilestoneDialog.qml` 的**视觉设计** —— 素版是刻意的定案
  （不用绿色、不用 emoji、不用图章）。你可以为了粒子宿主调整它的结构，
  但不许加装饰元素。
- `qml/views/StatisticsView.qml` —— 它是本计划要照抄的正确范例，不是要改的对象。

## Git workflow

- 分支：`advisor/013-reward-loop-fixes`
- 中文提交信息，建议按缺陷分 3 次提交：
  `奖励粒子改挂 overlay,不再被里程碑弹窗遮挡` /
  `目标页不再把查询失败显示成"还没有目标"` /
  `长期目标复选框改为显式赋值,避免绑定被首次点击摧毁`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先写一条会红的粒子正向用例

**先写测试，确认它红，再修**——否则你无法证明修复真的起了作用。

在 `tests/qml/tst_mainwindow_ui_optimization.qml` 追加（紧挨既有的
`test_reduceMotionCreatesNoRewardParticles`，`:493`）：

```js
function test_milestoneParticlesAreVisibleAboveDialog() {
    // 反面用例（reduceMotion 下粒子数为 0）已存在。这条守的是正面：
    // 正常情况下粒子必须真的创建出来，且它的宿主要在弹窗之上，
    // 否则整条庆祝通道等于没有实现。
}
```

设 `appSettings.reduceMotion = false`，触发一次里程碑，`tryVerify` 粒子数 > 0。

**光断言粒子数不够**——改动前粒子数本来就 > 0（它们被创建了，只是看不见）。
所以这条用例还必须锁住**层级**：断言粒子的宿主项不是 MainWindow 的普通子项。
具体断言方式取决于你在 Step 2 选的宿主，先按 Step 2 定下来的形态写。

**Verify**: `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure`
→ 新用例**红**（这一步期望失败）

### Step 2: 让粒子渲染在弹窗之上

两个可选做法，**推荐第一个**：

**做法 A（推荐）**：把 `rewardParticles` 的宿主改成窗口 overlay。
在 `qml/MainWindow.qml` 里 `import QtQuick.Controls` 之后可以用 `Overlay.overlay`
作为父项。要点：
- `parent: Overlay.overlay`，并让它 `anchors.fill: parent`
- 迸发坐标要换算到 overlay 坐标系（弹窗本身也在 overlay 里，
  所以 `dialog.x/y` 大概率可以直接用，但**必须实际验证**，不要假设）
- `CompletionParticles` 已经 `enabled: false`，不会拦输入，这一点不用额外处理

**做法 B（备选）**：把粒子层放进 `MilestoneDialog` 组件内部，
置于它的背景之上、内容之下或之上。这样天然在同一层级。
代价是 `MilestoneDialog` 从「纯展示」变成「自带效果」，
且 `dialog.destroy()` 时粒子会被一起销毁（要确认动画不会因此中途消失报警告）。

无论选哪个，都要加中文注释说明**为什么**不能用 `z` 解决：

```qml
// Popup 渲染在窗口 overlay 层，那一层整体位于 contentItem 之上，
// 所以 MainWindow 内部的 z 值再高也压不过弹窗。粒子必须与弹窗同层才看得见。
```

顺带检查迸发原点：现在是弹窗正中心，而粒子只飞 38 像素——
即使层级修好，粒子也全程在弹窗矩形内。**层级修好之后粒子会盖在弹窗内容上**，
这是可接受的（这就是庆祝效果该有的样子），但你要实际看一眼渲染结果再定。
若观感不佳，允许把原点改到弹窗边缘（例如顶边中点），**不允许**为此加大 `travelDistance`
（那是 `CompletionParticles` 的组件级配置，会同时影响任务完成的粒子）。

**Verify**: Step 1 的用例转**绿**；且
`cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 全过
（既有的 `test_reduceMotionCreatesNoRewardParticles` 必须仍然绿）

### Step 3: 目标页失败态照抄统计页的正确做法

`qml/views/GoalsView.qml` 的 `refresh()`——照 `StatisticsView.qml:397-410` 的结构改：
调用 `getGoals()` 后先看 `root.errorText`，非空就**保留旧数据直接返回**，不要赋 `[]`。

空态可见性（`:397`）加上错误条件：

```qml
visible: root.goalsCount === 0 && root.errorText.length === 0
```

`refreshDetail()`（`:130-140`）：区分两种空 map。
**不许改 C++**，用 QML 侧能拿到的信息区分：
`operationFailed` 会把 `errorText` 设成非空，而「目标真的被删了」不会发这个信号。
所以在 `refresh` 开头清空 `errorText` 之后：

- `errorText` 非空 → 是查询失败 → **保留详情页**，只显示错误
- `errorText` 为空且返回空 map → 目标确实没了 → 保持现在的行为（提示 + `closeGoal()`）

加中文注释说明这个区分依据，因为它依赖「C++ 侧同步发信号」这个不显然的时序：

```qml
// getGoal 对"已删除"和"查询失败"都返回空 map，只有后者会同步发 operationFailed。
// 所以此处用 errorText 是否被信号处理器填过来区分：数据库临时故障不该把用户踢出详情页。
```

**Verify**: `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 全过

### Step 4: 目标页失败态用例

在 `tests/qml/tst_goals_view.qml` 追加，用既有的 goalService mock：

1. mock 的 `getGoals` 返回 `[]` 并同步发 `operationFailed` → 断言
   `errorText` 非空、**且空态组件不显示**、**且 `goals` 保留了先前的数据**
2. 详情页打开状态下 `getGoal` 返回 `{}` 并发 `operationFailed` → 断言 `openGoalId` **未变**
3. 详情页打开状态下 `getGoal` 返回 `{}` **不**发信号（真删除）→ 断言 `openGoalId === -1`

**硬规则**：第 1 条不许写成 `compare(emptyState.visible, true/false)` 那种依赖
可见性级联的断言。改为断言驱动可见性的那个**条件表达式**的输入
（`goalsCount`、`errorText.length`），或给空态加一个 `readonly property bool shouldShow`
并断言它。

**Verify**: `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 3 条新用例通过

### Step 5: 修复复选框绑定

`qml/components/GoalFormDialog.qml`。推荐做法：**让复选框成为唯一事实源**。

```qml
CheckBox {
    id: longTermCheck
    objectName: "goalLongTermCheck"
    text: qsTr("长期目标（不设截止日期）")
    // 不写 checked: root.longTerm —— Controls 在用户点击时会直接写 checked，
    // 那会永久摧毁这条声明式绑定，导致之后 openForAdd/openForEdit 的赋值
    // 再也更新不了复选框显示，而截止日期字段却仍跟随，两者当场矛盾。
}
```

然后把 `root.longTerm` 改成派生属性：

```qml
readonly property bool longTerm: longTermCheck.checked
```

`openForAdd()`（`:87`）和 `openForEdit()`（`:99`）改成**显式赋值复选框**：
`longTermCheck.checked = true` / `longTermCheck.checked = (deadlineField.text.length === 0)`。

`:130` 的 `submit()` 和 `:335` 的 `deadlineField.enabled` 不用改——
它们读 `root.longTerm`，现在这个值直接来自复选框，永远同步。

**注意赋值顺序**：`openForEdit` 里读的是 `deadlineField.text`，
所以必须**先**给 `deadlineField.text` 赋值，**再**算 `longTermCheck.checked`。
去确认现有代码的顺序，别改坏它。

**Verify**: `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 全过

### Step 6: 复选框用例

在 `tests/qml/tst_goals_view.qml` 追加一条**能复现原缺陷**的用例：

```js
function test_longTermCheckStaysInSyncAfterUserToggle() {
    // 复现路径：打开表单 → 用户点一次复选框（这一下会摧毁声明式绑定）→
    // 关闭 → 用相反状态的目标重新 openForEdit → 复选框必须显示新状态。
}
```

序列：`openForAdd()` → 断言 `checked === true` → 模拟用户点击（调 `toggle()` 或
`longTermCheck.checked = !longTermCheck.checked` 后手动触发 `toggled`，
用哪种取决于你的实现，选能真实模拟用户交互的那种）→
`openForEdit(带截止日期的目标)` → 断言 `longTermCheck.checked === false`
**且** `root.longTerm === false` **且** `deadlineField.enabled === true`。

改动前这条必红，改动后必绿。**先确认它红。**

**Verify**: `cd /tmp/pt-013 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 通过

### Step 7: 全量回归

**Verify**:
```
cd /tmp/pt-013 && ctest --output-on-failure
grep -rn "compare(.*\.visible, true)\|visible === true" tests/qml/    # 期望：无输出
git diff --stat src/                                                   # 期望：无输出（零 C++ 改动）
```

## Test plan

- **新增**：粒子正向用例（层级 + 数量），3 条目标页失败态用例，1 条复选框同步用例
- **回归**：`test_reduceMotionCreatesNoRewardParticles` 等 6 条既有奖励用例必须原样通过
- 范式：`tests/qml/tst_mainwindow_ui_optimization.qml:447-543` 的既有奖励用例组
- 每条新用例都要**先确认它在修复前是红的**，再确认修复后转绿。
  一条从来没红过的测试，证明不了它在守护什么。

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-013 && ctest --output-on-failure` → 12/12 通过
- [ ] `git diff --stat src/` → **无输出**（零 C++ 改动）
- [ ] `grep -rn "visible === true\|\.visible, true)" tests/qml/` → 无输出
- [ ] `grep -n "checked: root.longTerm" qml/components/GoalFormDialog.qml` → **无输出**
- [ ] `grep -n "root.errorText.length === 0" qml/views/GoalsView.qml` → 命中（空态守卫）
- [ ] 粒子正向用例存在，且你在报告里写明「修复前它是红的」
- [ ] `qml/components/CompletionParticles.qml` 未被修改
- [ ] `plans/README.md` 中 013 的状态行已更新

## STOP conditions

停下报告，不要自行发挥：

- Drift check 判据不命中。
- 你认为必须修改 `GoalService`（C++）才能区分「已删除」和「查询失败」。
  Step 3 给了纯 QML 的区分办法；若你验证后确认那个办法不成立，报告原因，不要动 C++。
- 做法 A 的坐标换算试不通，且做法 B 会破坏 `MilestoneDialog` 的素版设计。
- 既有的 6 条奖励用例中任何一条因你的改动变红。
- 你发现修复复选框需要改 `submit()` 的存盘逻辑 —— 那说明存盘逻辑另有问题，报告。

## Maintenance notes

- **粒子层级这个坑会重现。** 任何将来「在弹窗上做视觉效果」的需求都会撞上
  「Popup 在 overlay 层、`z` 跨不过去」这件事。修好之后，那段中文注释就是留给下一个人的路标。
- **「先写会红的测试」是本计划的方法论重点。** 这三个缺陷都是在测试全绿的情况下交付的，
  原因就是测试只测了反面（粒子为 0）、只测了成功路径（查询没失败）、
  完全没测某个控件（复选框）。审查这个 PR 时该问的是：新加的每条用例，
  在修复前真的会红吗？
- 本计划**没有**处理的两个同源小问题，已记录在 `plans/README.md`：
  `MilestoneDialog` 里 `Theme.inkStrong` / `Theme.inkSoft` 用在了 `accentFill` 底色上
  （令牌与背景不匹配），以及目标热力图只用透明度深浅表达番茄数量、
  没有任何非颜色通道（违反「状态不得只靠颜色表达」）。两者都值得做，但属于设计令牌与
  可访问性专项，塞进本计划会让 scope 失控。
</content>
