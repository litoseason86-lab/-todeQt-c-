# Plan 034: 把 44 个 QML 测试文件拆成独立 ctest 条目，让 `ctest -j` 真正并行

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行。每一步都要跑验证命令并确认预期结果，
> 再进入下一步。遇到 "STOP conditions" 里的任何一条，停下来汇报，不要自行发挥。
> 完成后更新 `plans/README.md` 里本计划那一行的状态——除非派发你的复核者说明索引由他维护。
>
> **Drift check（先跑这个）**：
> `git diff --stat b5a8836..HEAD -- CMakeLists.txt`
> 若有变化，先把下面 "Current state" 的摘录和实际代码逐条比对；对不上按 STOP condition 处理。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `b5a8836`，2026-08-14

## Why this matters

`tests/qml/` 下有 **44 个** `tst_*.qml`，但它们全部由**一条** ctest 条目
（`PomodoroTodoQmlTests`）里的单个 `qmltestrunner` 进程串行跑完。
后果是 `ctest -j` 对整个测试套件里最慢的那块**完全无效**。

实测数字（2026-08-14，本机 Qt 6.10.3）：

| 跑法 | 墙钟时间 |
|---|---|
| 现状：`ctest -j4`（QML 仍是单条目串行） | **57.05s**，其中 `PomodoroTodoQmlTests` 占 **56.16s** |
| 44 个文件各起一个 runner，`xargs -P8` | **24.8s** |

也就是说单这一处改动能把全量回归从 ~57s 压到 ~25s，**每次跑省 31 秒**。
对一个改一行就想跑一遍全量的项目，这是最划算的一笔。

改完之后的下界是最慢的单个文件——实测 `tst_ui_optimization.qml` 一个人就要
**20.17s**（其中 4.97s 是写死的 `wait()`）。本计划**不**处理那个文件，
但拆分之后它会第一次变得显眼，这是好事。

## Current state

唯一要改的文件是 `CMakeLists.txt`。

### 现在的 QML 测试条目（`CMakeLists.txt:726-736`）

```cmake
add_test(
    NAME PomodoroTodoQmlTests
    COMMAND Qt6::qmltestrunner -input ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml
)
set_tests_properties(PomodoroTodoQmlTests PROPERTIES
    # 测试固定离屏平台与 Basic 风格，后台验证不得创建真实应用窗口。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic"
)

# 每个 CTest 进程都需要 watchdog：QML runner 聚合全部文件，因此比单个业务/资产测试留出更宽余量。
set_tests_properties(PomodoroTodoQmlTests PROPERTIES TIMEOUT 180)
```

`-input` 指向**目录**时 `qmltestrunner` 会递归收集该目录下的 `tst_*.qml`；
指向**单个文件**时只跑那一个。后者正是本计划要用的形式——
上面表格里 24.8s 那一行就是这么测出来的，机制已验证可行。

### 附近的既有写法（可参考的 GLOB 用法，`CMakeLists.txt:691-693`）

```cmake
if(POMODORO_TODO_QMLLINT)
    file(GLOB_RECURSE POMODORO_TODO_QML_SOURCES
        "${CMAKE_CURRENT_SOURCE_DIR}/qml/*.qml")
```

本仓库已经在用 `file(GLOB...)` 收集 QML 文件，所以再用一次是符合既有风格的。

### 项目约定（必须遵守）

- 注释写「为什么」，用中文。上面那两段摘录就是范例。
- **后台验证不得创建真实应用窗口**——`QT_QPA_PLATFORM=offscreen` 是硬性要求，
  拆分后每一条新条目都必须带上同样的 `ENVIRONMENT`，一条都不能漏。
- 每个 ctest 条目都要有 watchdog `TIMEOUT`（这是既有约定，见第 735 行注释）。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 重新 configure | `cmake -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF -DCMAKE_PREFIX_PATH=~/Qt/6.10.3/macos` | exit 0 |
| 构建 | `cmake --build ~/pt-audit -j8` | exit 0 |
| 列出条目 | `cd ~/pt-audit && ctest -N` | 见各步骤 |
| 全量并行 | `cd ~/pt-audit && ctest -j8 --output-on-failure` | 全绿 |

**构建目录规则（`AGENTS.md` 明文规定）**：本机只允许 `~/pt-build`（部署）与
`~/pt-audit`（验证）两个构建目录。**本计划一律用 `~/pt-audit`**，不要新建一次性目录。

## Scope

**In scope**：
- `CMakeLists.txt`（只改第 726–736 行那一段）

**Out of scope**（看着相关也不要动）：
- **任何 `tests/qml/*.qml` 文件的内容。** 本计划只改调度方式，不动测试本身。
- **不要去优化 `tst_ui_optimization.qml` 的 4.97s 固定 `wait()`。**
  那是独立的一轮工作（拆分后它会成为新的瓶颈，但那时才该处理）。
- `QmlLintGate`、`QmlTextFormatGate` 两条门禁——它们是独立条目，与本计划无关。
- 其它 C++ 测试目标的 `TIMEOUT` 设置。

## Git workflow

- 分支：`advisor/034-split-qml-ctest`
- 提交信息用中文、说明「为什么」。参考 `git log --oneline -5`。
- **不要 push，不要开 PR**，除非派发你的人明确要求。

## Steps

### Step 1: 把单条目换成按文件生成的多条目

把 `CMakeLists.txt:726-736` 那一段替换成：用 `file(GLOB ... CONFIGURE_DEPENDS)`
收集 `${CMAKE_CURRENT_SOURCE_DIR}/tests/qml/tst_*.qml`，对每个文件
`add_test` 一条，名字形如 `QmlTest.<文件名去掉 tst_ 前缀和 .qml 后缀>`，
例如 `tests/qml/tst_focus_view.qml` → `QmlTest.focus_view`。

每条新条目都必须设置：

- `ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic"`
  （与原条目逐字一致，**一条都不能漏**）
- `TIMEOUT 120`（单文件比聚合跑得快，但 `tst_ui_optimization` 实测 20s，
  留足余量应对慢机器）

**`CONFIGURE_DEPENDS` 是必须的**：没有它，新增一个 `tst_*.qml` 文件后
CMake 不会重新 glob，新测试会**静默不被执行**——那比没拆更危险。
写一句注释说明这个理由。

同时保留一句注释说明为什么要按文件拆（单进程聚合导致 `ctest -j` 对
最慢的一块无效；实测 57s → 25s）。

**Verify**：
```bash
cmake -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF -DCMAKE_PREFIX_PATH=~/Qt/6.10.3/macos 2>&1 | tail -3
cd ~/pt-audit && ctest -N | tail -1
```
→ 条目总数应为 **62**（原 19 条 − 1 条聚合 + 44 条单文件 = 62）。
若不是 62，先数清楚 `ls tests/qml/tst_*.qml | wc -l` 是否仍为 44 再判断。

### Step 2: 确认旧的聚合条目已经消失

```bash
cd ~/pt-audit && ctest -N | grep -c PomodoroTodoQmlTests
```
→ `0`。若仍存在，说明新旧两套并存，全量时间会不降反升。

### Step 3: 确认全绿且确实变快

```bash
cd ~/pt-audit && time ctest -j8 --output-on-failure 2>&1 | tail -5
```

→ 必须满足两条：
- `100% tests passed, 0 tests failed out of 62`
- 墙钟时间 **< 35s**（现状 57s；实测目标 ~25s，留出机器差异余量）

若全绿但时间没有明显下降，**STOP 并汇报**——说明并行没有真正生效
（常见原因：条目名重复导致只生成了一条）。

### Step 4: 确认 offscreen 环境没有漏配

这一步很重要：漏配 `QT_QPA_PLATFORM=offscreen` 的条目会尝试拉起真实
cocoa 窗口，违反项目「后台验证不得弹窗」的红线，而且在无头环境下会挂住。

```bash
cd ~/pt-audit && ctest -N -V 2>&1 | grep -c "QT_QPA_PLATFORM=offscreen"
```
→ 应为 **44**（每个新条目一条）。若少于 44，找出漏掉的那些补上。

### Step 5: 确认新增测试文件能被自动收录

验证 `CONFIGURE_DEPENDS` 真的生效：

```bash
cp tests/qml/tst_immersion_sync.qml tests/qml/tst_zzz_globcheck.qml
cmake --build ~/pt-audit -j8 > /dev/null 2>&1
cd ~/pt-audit && ctest -N | grep -c "zzz_globcheck"
```
→ `1`。

然后**务必删掉这个临时文件并重新 configure**：

```bash
rm tests/qml/tst_zzz_globcheck.qml
cmake -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF -DCMAKE_PREFIX_PATH=~/Qt/6.10.3/macos > /dev/null
cd ~/pt-audit && ctest -N | tail -1
```
→ 回到 62 条。

若 Step 5 的 grep 输出 `0`，说明 `CONFIGURE_DEPENDS` 没生效
（某些生成器支持不完整）。这不是致命问题，但**必须在汇报里写明**，
并在 `CMakeLists.txt` 那段注释里记下「新增 QML 测试文件后需要手动重新 configure」。

## Test plan

本计划**不新增任何测试用例**——它改的是测试的调度方式，不是被测行为。

验证完全依赖既有测试全绿：拆分前后**通过的用例总数必须一致**。
拆分前先记录基线：

```bash
cd ~/pt-audit && ctest -R PomodoroTodoQmlTests -V 2>&1 | grep -E "^Totals" | awk '{p+=$2} END {print "baseline passed:", p}'
```

拆分后用同样方式对所有 `QmlTest.*` 条目求和，两个数字必须相等。
**数字对不上就是回归**（有文件没被收进来，或某个文件被跑了两次）。

## Done criteria

全部满足：

- [ ] `cd ~/pt-audit && ctest -N | tail -1` 显示 **62** 条
- [ ] `ctest -N | grep -c PomodoroTodoQmlTests` == 0
- [ ] `ctest -j8` → `100% tests passed, 0 tests failed out of 62`
- [ ] `ctest -j8` 墙钟时间 < 35s（汇报里写明实测数字）
- [ ] `ctest -N -V | grep -c "QT_QPA_PLATFORM=offscreen"` == 44
- [ ] 拆分前后 QML 通过用例总数一致（汇报里写明两个数字）
- [ ] `tests/qml/` 下没有遗留临时文件（`git status` 干净）
- [ ] 只有 `CMakeLists.txt` 被修改
- [ ] `plans/README.md` 对应状态行已更新

## STOP conditions

出现以下任一情况，停下汇报：

- "Current state" 的 CMake 摘录与实际文件对不上。
- 拆分后条目数不是 62，且你无法解释差值。
- 拆分后有任何用例变红——**不要通过调整 TIMEOUT 或跳过用例来「修好」它**。
  串行改并行暴露出的失败往往是测试之间共享了状态（例如都写
  `~/Library/Preferences/` 下同一个 plist），那是真问题，需要单独处理。
- 拆分前后通过用例总数不一致。
- 全量时间没有明显下降。

## Maintenance notes

- **给后续维护者**：拆分之后，全量时间的下界等于**最慢的单个文件**。
  当前是 `tst_ui_optimization.qml`（实测 20.17s，其中 4.97s 是写死的 `wait()`）。
  想继续压时间，下一步就是把那个文件里的固定 `wait()` 换成 `tryCompare`——
  全仓 QML 测试里共有 220 处 `wait()`、合计约 15.7 秒写死的睡眠。
- **复核时重点看**：每条新条目是否都带了 `offscreen` 环境变量（漏一条就会
  在无头环境下弹窗或挂住），以及 `CONFIGURE_DEPENDS` 是否在。
- **本计划刻意没做**：`tst_ui_optimization.qml` 的睡眠优化、
  测试间共享状态（写用户 plist）的清理。后者在拆成并行之后可能第一次显形——
  如果 Step 3 出现随机失败，那就是它，应当单独立项而不是塞进本计划。
