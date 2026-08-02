# Plan 025: 建立 QML 渲染性能测量工装（后续性能计划的前置）

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- CMakeLists.txt qml tests
> ls /Users/zerionlito/Qt/6.9.0/macos/bin/qmlprofiler   # 必须存在
> grep -n "POMODORO_TODO_ENABLE_QML_DEBUG" CMakeLists.txt  # 必须命中
> ls tests/perf 2>/dev/null                              # 应当不存在（本计划新建）
> ```

## Status

- **Priority**: P1（本批次内）
- **Effort**: M
- **Risk**: LOW（只新增文件与一个可选 ctest 条目，不改产品代码）
- **Depends on**: none
- **Blocks**: plans/026、027、028、030 的量化验收
- **Category**: tooling / perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

四轮审计都记着同一句话：**QML 渲染性能从未实测**。因此每一条 UI 性能结论都只能标成
「静态推断」，包括「每行任务多占一个 FBO」「侧栏磨砂每帧重采样」这类听起来很确定的说法——
其中「侧栏每帧重采样」在第五轮已被证明是**错的**（壁纸是静态的，`live` 的语义是"源变才更新"）。

没有工装的代价不是「不知道有多快」，而是**分不清真问题和假问题**，于是要么不敢动，
要么照着错误推断去改。本计划不修任何性能问题，它只让后面的计划能拿数字说话。

## Current state

### 已验证可用的离屏测量配方

```bash
QML_DISABLE_DISK_CACHE=1 QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software \
QT_QUICK_CONTROLS_STYLE=Basic QT_LOGGING_RULES="qt.scenegraph.time.renderloop=true" \
  /Users/zerionlito/Qt/6.9.0/macos/bin/qml <harness>.qml
```

数 `Frame rendered` 行数即可判断「是否有东西在空转」。已用它测出：
`TaskItem` / `FocusTimeline` / `CountdownItem` / `GlassPanel` 单独实例化 5 秒各只有 2 帧（无空转）；
`StatCard` 5 秒和 15 秒都是 40 帧（一次性入场动画，会收敛）。

**三条硬约束（写进 harness 注释，否则下一个人会重新踩）**：

1. **必须 `QSG_RHI_BACKEND=software`**，不是 `QT_QUICK_BACKEND=software`——后者的
   `grabToImage()` 在离屏下返回 false。
2. **`GlassPanel` 的落影走 `layer.enabled` + `MultiEffect`，在 software 后端下渲染为空**，
   面板会整块看不见。任何 harness 都要把 `panelShadowEnabled: false`，否则会误判。
3. harness 里 import 需要 URL scheme：`import "file:///Users/zerionlito/code/番茄todo/qml"`。
   macOS 没有 `timeout`：后台跑 qml 进程，`sleep` 后 `kill`。

### qmlprofiler 的现状

`/Users/zerionlito/Qt/6.9.0/macos/bin/qmlprofiler` **存在**。但它需要应用带
`-qmljsdebugger=port:<N>,block` 启动，而该钩子由 CMake 选项
`POMODORO_TODO_ENABLE_QML_DEBUG` 控制、**默认 OFF**（`CMakeLists.txt:124` 附近）。

**注意项目红线**：`AGENTS.md` 规定后台验证不得弹出应用窗口，禁止 `open`、
禁止直接运行 `.app`。因此 qmlprofiler 的**真机 GPU 采样不在本计划范围内**——
本计划只做到「离屏帧计数 + 可复现的 harness」，并把 GPU 采样的操作步骤写成文档，
留给人在需要时手动执行。

### 项目约定

- 构建目录必须在仓库外；**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**，
  该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`。
  它是 cache 变量会粘住，**换构建目录必须重新传**。
- 注释用中文，解释「为什么」和「边界条件」。
- QML 测试硬规则：**绝不允许断言 `item.visible === true`**；用 `tryCompare` 不用固定 `wait()`。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-025 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 全量 | `cd /tmp/pt-025 && ctest --output-on-failure` | `100% tests passed ... out of 14`（新增条目后为 15） |

## Scope

**In scope**：
- `tests/perf/bench_task_list.qml`（新建）
- `tests/perf/bench_page_switch.qml`（新建）
- `tests/perf/README.md`（新建：怎么跑、怎么读数、三条硬约束、qmlprofiler 手动步骤）
- `CMakeLists.txt`（**只新增**一个可选 ctest 条目，见 Step 4）

**Out of scope**（不许碰）：
- **任何产品代码**（`qml/`、`src/`）—— 本计划一行都不改。发现性能问题只记录，不修。
- `qt_add_qml_module` 迁移 —— 会改动全部 67 个文件的 import URL 和入口路径，
  属于独立的高风险改造，不在本计划。
- 把 `POMODORO_TODO_ENABLE_QML_DEBUG` 默认值改成 ON —— 默认关是对的。

## Git workflow

- 分支：`advisor/025-perf-harness`
- 中文提交信息：`新增 QML 渲染性能测量工装`
- **不要 push，不要开 PR。**

## Steps

### Step 1: `tests/perf/bench_task_list.qml`

用合成模型实例化 N 个 `TaskItem`（N 由 `property int rowCount: 30` 控制），
放进一个 `ListView`。**不接任何真实服务**——`TaskItem` 需要的服务引用用
`QtObject` mock 顶上（照 `tests/qml/tst_goals_view.qml` 里 mock 的写法）。

顶部注释必须写明上面那三条硬约束。

它要能回答的问题：`reuseItems` 开/关、`layer.enabled` 开/关时，
构建 N 行分别产生多少帧、耗时多少（用 `Date.now()` 打点，`console.info` 输出）。

**Verify**: 按配方跑起来，输出里能看到行数与耗时；进程能被 `kill` 干净退出。

### Step 2: `tests/perf/bench_page_switch.qml`

实例化 `MainWindow` 的 `StackLayout` 结构（或直接实例化两三个大视图），
用 `Timer` 轮换 `currentIndex`，打点每次切换的耗时。

若实例化 `MainWindow` 需要的服务 mock 过多而不现实，**退而求其次**：
分别单独实例化 `DashboardView` / `StatisticsView` / `FocusView`，各自计时构建耗时。
**这种退让必须写进 `tests/perf/README.md`**，说明它测的是「单页构建成本」
而不是「切换成本」，不要让读数被误解。

**Verify**: 能输出每个视图的构建耗时。

### Step 3: `tests/perf/README.md`

内容至少包含：
- 完整的运行命令（含全部环境变量）
- 三条硬约束（software RHI / GlassPanel 落影不渲染 / import 需要 scheme）
- 怎么读 `Frame rendered` 计数：**持平 = 一次性动画，持续增长 = 空转**
- qmlprofiler 的手动步骤，并明确标注「需要可见窗口，不得在自动流程里执行」
- 已知基线数字（跑一次记下来），供后续对比

### Step 4: 注册一个**不参与默认门禁**的 ctest 条目

性能数字在不同机器上不稳定，**绝不能**拿它当红绿门禁。
用 `add_test` 注册后加标签排除：

```cmake
add_test(NAME QmlPerfBench COMMAND ...)
set_tests_properties(QmlPerfBench PROPERTIES
    LABELS "perf"
    DISABLED TRUE   # 默认不跑；需要时用 ctest -R QmlPerfBench 手动触发
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QSG_RHI_BACKEND=software;QT_QUICK_CONTROLS_STYLE=Basic"
)
```

**若 `DISABLED TRUE` 会让 `ctest` 的总数从 14 变成 15 并显示为 skipped**，那是预期行为，
在报告里写明即可。若它反而让全量变红 → 改成完全不注册 ctest 条目，只留文档命令。

**Verify**: `cd /tmp/pt-025 && ctest --output-on-failure` → 原有 14 条全绿

## Test plan

本计划产出的是工装本身，不产出断言。验收靠：
- 两个 harness 都能跑出数字
- 原有 14 个 ctest 条目不受影响
- `tests/perf/README.md` 里记下的基线数字，后续计划能复现

## Done criteria

- [ ] `cd /tmp/pt-025 && ctest --output-on-failure` → 原有 14 条全部通过
- [ ] `ls tests/perf/` → 三个文件都在
- [ ] 两个 harness 各自跑通，报告里贴出实际输出
- [ ] `git diff --stat qml/ src/` → **无输出**（零产品代码改动）
- [ ] `tests/perf/README.md` 里写了三条硬约束和基线数字
- [ ] `plans/README.md` 中 025 的状态行已更新

## STOP conditions

- Drift check 失败（qmlprofiler 不存在 / `tests/perf` 已存在）。
- harness 里实例化 `TaskItem` 或视图需要 mock 的服务超过 5 个 —— 说明耦合比预期深，
  报告实际需要什么，不要硬写一个几百行的 mock。
- 你发现必须修改产品代码才能测 —— 报告，不要改。
- 注册 ctest 条目导致全量变红且无法用 `DISABLED` 解决。

## Maintenance notes

- 这套工装的价值在于**它测的是相对变化**，不是绝对性能。跨机器比绝对值没有意义，
  同机器上改动前后比才有意义。README 要把这句话写在最前面。
- plans 026/027/028/030 的验收都应引用本工装的读数。若那些计划落地时工装已经失修，
  先修工装再改性能——否则又会回到「靠推断改性能」的老路。
- 未做的部分（诚实记录）：真实 GPU 帧时、FBO 分配量、Retina DPR 下的纹理内存，
  都需要可见窗口，本计划按项目红线没有做。
