# Plan 008: 全局奖励回路 —— 即时 Toast、里程碑/达成弹窗、粒子与音效（奖励机制·阶段 C）

> **Executor instructions**: 按步骤执行，逐步验证；触发 STOP conditions 立即停下报告。
> 完成后更新 `plans/README.md` 状态行。
>
> **Drift check（先跑这个）**：
> `grep -n "function openGoal" qml/views/GoalsView.qml`（007 已交付）、
> `grep -n "focusCompleted.*refreshMilestones" src/main.cpp -A 2 | grep connect` 或直接
> `grep -n "GoalService::refreshMilestones" src/main.cpp`（接线仍在）、
> `grep -n "function showToast" qml/MainWindow.qml`（:150 附近）。
> 任一不命中按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: M-L
- **Risk**: MED
- **Depends on**: plans/006、plans/007
- **Category**: feature（奖励机制 阶段 C —— 本轮核心）
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **设计依据**: `docs/奖励机制实施方案.md` §一.1/§三-阶段C；已拍板决策：即时层=全局 Toast，音效=新合成两个短音频

## Why this matters

这是整个奖励机制的**送达环节**。TRACK 100 的反馈发生在打卡的同屏同秒；我们的 +1
发生在专注结束，用户在专注页甚至沉浸全屏——所以反馈必须**事件驱动、全局送达**，
不依赖目标页开着。本计划的验收标准就是这句话的反面证明：
**目标页关着的状态下，完成一个跨里程碑的番茄，弹窗照常出现。**

分层强度（已定）：每个番茄 → 轻 toast「英语精读 +1 · 63/100」3 秒自散；
跨 25/50/75 → 三音上行 + 素版弹窗 + 定向粒子；100% → 四音上行 + 达成弹窗。
沉浸模式：压弹窗、保留音效，退出沉浸后补一条 toast。`reduceMotion`：无粒子、弹窗直显。
`soundEnabled` 关闭：全程静音。

## Current state

### 已就绪的链路（不改）

`src/main.cpp:125-126`：

```cpp
    QObject::connect(FocusTimer::instance(), &FocusTimer::focusCompleted,
                     GoalService::instance(), &GoalService::refreshMilestones);
```

`GoalService::milestoneReached(int goalId, const QString& title, int percent)` 信号：
每档只发一次（位掩码只增不减），一次跨多档只报最高档。percent ∈ {25,50,75,100}。

### 缺口 1：没有「+1」信号

`refreshMilestones` 只在**跨档**时发信号；日常推进静默。需要新增：

```cpp
signals:
    // 某目标的有效番茄数较上次刷新增加时发出；供全局轻提示使用。
    void goalProgressed(int goalId, const QString& title, int doneCount, int targetPomodoros);
```

**发射逻辑（写进 `refreshMilestones`，设计要点逐条实现）**：

- 成员 `QHash<int, int> m_lastDoneCounts;`（内存缓存，**不落库**——toast 是瞬时物，
  应用重启后丢失是正确行为）。
- 每次 `refreshMilestones` 遍历 goals 时：`doneCount > m_lastDoneCounts.value(id, -1)`
  且缓存中**已有**该 id → 发 `goalProgressed`；随后无条件更新缓存。
- **首次刷新（缓存里没有该 id）只写缓存不发信号**——否则应用启动后的第一个番茄会把
  所有既有进度轰成一排 toast。新建目标同理（addGoal 成功后它下次刷新才进缓存）。
- `databaseChanged` 的 lambda 里 `m_lastDoneCounts.clear()`（换库后旧缓存全部失效）。
- 删除目标时 `m_lastDoneCounts.remove(goalId)`。

### 缺口 2：音效资源与播放口

`src/services/PhaseSoundService.cpp` 现状：单资源 `:/sounds/phase-complete.wav`，
macOS 用 `afplay` detached 播放，`ensurePhaseCompleteFile()` 先拷到临时目录。
扩展方式：把 ensure 函数泛化成 `ensureSoundFile(resourcePath, fileName)`，新增

```cpp
Q_INVOKABLE bool playMilestoneChime();     // :/sounds/milestone.wav
Q_INVOKABLE bool playGoalAchievedChime();  // :/sounds/goal-achieved.wav
```

**音频合成**（无外部素材，脚本生成后作为资源提交）：Python 标准库 `wave`+`math`，
44100Hz/16bit/单声道，正弦波 + 指数衰减包络：

- `milestone.wav`：C5(523Hz)→E5(659Hz)→G5(784Hz)，每音 140ms、间隔 20ms，总长约 0.5s。
- `goal-achieved.wav`：C5→E5→G5→C6(1046Hz)，每音 160ms、间隔 30ms，总长约 0.75s。
- 峰值幅度 ≤ 0.3（短提示音不能炸耳）；首尾 5ms 线性淡入淡出防爆音。

脚本放 scratchpad 执行，产物写 `resources/sounds/`，在 `resources/qml.qrc` 按
既有格式注册（`<file alias="sounds/milestone.wav">sounds/milestone.wav</file>`）。

### 缺口 3：全局 UI 层

挂点事实：

- `qml/MainWindow.qml:150` `function showToast(message, actionText, actionCallback)`；
  Toast 组件在 :690。
- 沉浸态：`qml/MainWindow.qml:21` `property bool focusImmersiveActive: false`（权威标志）。
- 粒子：`qml/components/CompletionParticles.qml`（`burst(x, y)`，6 向定向迸发，自毁）。
- 目标页跳转：`root.currentView = "goals"` 等价于侧栏点击路径（复用 MainWindow 既有的
  切页函数，读 :61-99 的 `switchTo` 逻辑后接入，不要绕过切页动画状态机）。

### 弹窗设计（已定稿，`docs/设计稿/长期目标/06/08`）

素版：小字「里程碑/目标达成」→ 大号百分比（52/60px，`Theme.fontFamilyData`）→
目标名 → 副行（里程碑：`done / target 番茄，还剩 N 个`；达成：`累计 N 个番茄`）→
「继续」按钮 + 「查看目标」次按钮。达成态：底 `Theme.accentFill`、边 `Theme.accent`、
数字 `Theme.accentFillInk`。**不引入绿色、无 emoji、无图章。**

### 时序红线

`refreshMilestones` 由 `focusCompleted` **同步**驱动，弹窗/音效必须 `Qt.callLater`
级解耦，不得阻塞 FocusTimer 收尾链路（保存会话→自动完成任务→阶段协调器通知）。
QML 侧 `Connections` 的槽本身已是队列外调用，但槽内只做"记录状态 + callLater 展示"。

## Commands you will need

同 plan 006（构建目录 `/tmp/pt-008`）。C++ 侧单测：
`cmake --build /tmp/pt-008 --target GoalServiceTests -j8 && QT_QPA_PLATFORM=offscreen /tmp/pt-008/GoalServiceTests`

## Scope

**In scope**：
- `src/services/GoalService.h/.cpp`（goalProgressed 信号 + 缓存逻辑，**不动聚合 SQL**）
- `src/services/PhaseSoundService.h/.cpp`（两个新播放口 + ensure 泛化）
- `resources/sounds/milestone.wav`、`goal-achieved.wav`（新资源）+ `resources/qml.qrc`
- `qml/components/MilestoneDialog.qml`（新建）
- `qml/MainWindow.qml`（Connections on goalService + 弹窗/粒子挂载 + 沉浸压制逻辑）
- `tests/GoalServiceTests.cpp`（goalProgressed 用例）
- `tests/qml/tst_goals_view.qml` 或新建 `tst_milestone_dialog.qml`（弹窗用例）

**Out of scope**：
- `FocusTimer` / `main.cpp` 接线 —— 已就绪，不动。
- `refreshMilestones` 的位掩码语义 —— 只增不减，一行不动。
- `PhaseCompletionCoordinator.qml` —— 阶段完成通知与目标奖励是两条独立回路，不合并。
- 页面内格子 pop 动画 —— 决策 1 选了 A（仅全局 toast）。

## Git workflow

分支 `advisor/008-reward-loop`；提交建议：
`目标服务新增进度推进信号` / `合成里程碑与达成提示音` / `全局奖励回路:toast与里程碑弹窗`。不 push。

## Steps

### Step 1: `goalProgressed` 信号 + 缓存（C++ + 单测）

按 "缺口 1" 实现。单测追加 3 条（`QSignalSpy(goalService, &GoalService::goalProgressed)`）：

1. `firstRefreshSeedsCacheWithoutEmitting`：建目标、插 2 番茄、首次 `refreshMilestones()`
   → spy 为 0；再插 1 番茄、再刷 → spy 为 1 且参数 (goalId, title, 3, target)。
2. `progressRollbackDoesNotEmit`：删 1 条记录后刷新 → 不发；补回 → 发（回到峰值也算前进，
   与里程碑位掩码"不重弹"的语义不同——toast 是瞬时提示，重复出现无害且符合直觉）。
3. `databaseChangeClearsProgressCache`：手动触发 `databaseChanged` 后首刷不发。

**Verify**: `GoalServiceTests` 基线+3 全绿。

### Step 2: 合成音频 + PhaseSoundService 扩展

脚本合成两个 wav（参数见 "缺口 2"），注册 qrc，扩展服务。
中文注释说明频率序列与"与 phase-complete 区分稀有度"的意图。

**Verify**:
`python3 -c "import wave; [print(f, wave.open(f'resources/sounds/{f}').getnframes()) for f in ['milestone.wav','goal-achieved.wav']]"` 帧数 >0；
构建过；`grep -c "sounds/" resources/qml.qrc` 比改前 +2。
（可选人工：`afplay resources/sounds/milestone.wav` 听一次。）

### Step 3: `MilestoneDialog.qml`

按 "弹窗设计" 实现。属性：`goalTitle, percent, doneCount, targetCount, achieved`；
信号 `dismissed()`、`viewGoalRequested()`。`reduceMotion` 时无入场动画。
scrim 用 `Theme.modalScrim`，点击 scrim 等同「继续」。

### Step 4: MainWindow 接线（核心步）

```qml
    // 奖励回路的全局接收端：目标页开不开着都要送达（方案 §一.1 的组织原则）。
    Connections {
        target: typeof goalService === "undefined" ? null : goalService
        ignoreUnknownSignals: true
        function onGoalProgressed(goalId, title, done, target) {
            root.showToast(title + " +1 · " + done + "/" + target)
        }
        function onMilestoneReached(goalId, title, percent) {
            // 同步信号链上不做任何 UI；记下再 callLater 展示，绝不阻塞计时收尾。
            root.pendingMilestone = { goalId: goalId, title: title, percent: percent }
            Qt.callLater(root.presentPendingMilestone)
        }
    }
```

`presentPendingMilestone()`：

- 音效先行（不受沉浸影响）：`appSettings.soundEnabled` 时按 percent===100 分别调
  `phaseSoundService.playGoalAchievedChime() / playMilestoneChime()`。
- `focusImmersiveActive` 为真：**不弹窗**，暂存 `suppressedMilestone`；
  监听 `onFocusImmersiveActiveChanged` 变 false 时
  `showToast("✦ " + title + " 已达成 " + percent + "%")`（补告知，不补弹窗——
  沉浸结束时用户在收尾休息，弹窗打断感更强）。
- 否则弹 `MilestoneDialog`（percent、经 `goalService.getGoal(goalId)` 补 done/target）+
  `reduceMotion` 为假时 `CompletionParticles.burst(弹窗中心)`。
- `viewGoalRequested` → 关弹窗 → 切换到 goals 视图（走 MainWindow 既有切页函数）→
  `goalsView.openGoal(goalId)`。

### Step 5: QML 用例

mock goalService（QtObject + 两个信号）+ mock appSettings/phaseSoundService，用例：

1. `goalProgressed` → toast 文案含 "+1 · 3/100"（断言 Toast 的 label text 属性）。
2. `milestoneReached(percent=50)` 非沉浸 → 弹窗组件的 `percent===50`、`achieved===false`。
3. 沉浸态下 `milestoneReached` → 弹窗**不**创建（断言持有属性仍为 null），
   mock 音效对象的调用计数 ===1；退出沉浸 → toast 文案含 "50%"。
4. `reduceMotion` 下弹窗创建但粒子容器 `particleCount===0`。
5. percent=100 → `achieved===true` 且调用的是 achieved 音效 mock。

全部 `tryCompare`；不断言 visible。

**Verify**: QML 套件通过。

### Step 6: 端到端手工脚本 + 全量

真机验收路径（写进提交说明供维护者执行，自动化不覆盖真窗口）：
建一个 target=1 的目标 → 目标页**切走** → 跑完一个 5 分钟番茄 →
预期：toast「xxx +1 · 1/1」+ 四音 + 达成弹窗。
全量 `ctest` 12 套件通过。

## Done criteria

- [ ] 全量 12 套件通过；`GoalServiceTests` 基线+3
- [ ] `grep -n "goalProgressed" src/services/GoalService.h` 命中
- [ ] `grep -n "m_lastDoneCounts" src/services/GoalService.cpp` ≥ 3 处（读/写/清）
- [ ] `resources/sounds/milestone.wav` 与 `goal-achieved.wav` 存在且已入 qrc
- [ ] `grep -n "Qt.callLater" qml/MainWindow.qml` 命中（解耦到位）
- [ ] 沉浸压制用例通过（QML 用例 3）
- [ ] `plans/README.md` 更新

## STOP conditions

- Drift check 失败（006/007 未落地或接线被改）。
- `refreshMilestones` 的现有结构与 "缺口 1" 描述不符，无法只增不改地插入缓存逻辑。
- afplay 路径在测试机不可用导致音效口无法验证 —— 报告，不要引入 QtMultimedia
  （注释明确说了当前 Qt 安装缺该模块）。
- 弹窗展示引起任何既有 QML 测试超时/失败（可能是全局层 z 序或事件拦截）——先报告。
- 你发现需要改 `FocusTimer` 或 `PhaseCompletionCoordinator` 才能完成时序解耦。

## Maintenance notes

- **toast 与里程碑弹窗可能同秒到达**（跨档的那个番茄两者都触发）：Toast 的"连续 show
  只替换不排队"语义决定 toast 会被弹窗盖住视线，可接受；若维护者觉得吵，可在
  `presentPendingMilestone` 里跳过同目标的 toast——留作调优，不在本计划内。
- `goalProgressed` 的缓存是进程内的：崩溃恢复后首个番茄不 toast（缓存重播种），正确且无感。
- 将来若做"多目标同科目"，一个番茄会推进多个目标 → 多条 toast 连发；Toast 不排队
  意味着只见最后一条。到时再议合并文案。
