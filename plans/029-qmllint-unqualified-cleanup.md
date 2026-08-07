# Plan 029: 消除 241 处 unqualified 访问，并把 qmllint 接成可用的门禁

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 0aa89af..HEAD -- qml
> /Users/zerionlito/Qt/6.9.0/macos/bin/qmllint -I qml qml/*.qml qml/views/*.qml \
>   qml/components/*.qml qml/components/settings/*.qml 2>&1 | grep -c "unqualified"
> grep -rl "pragma ComponentBehavior: Bound" qml/ | wc -l
> ```
>
> **基线已在 2026-08-07 于 commit `0aa89af` 重测**（原基线 241 是 2026-07-29 在 `52726d9`
> 用 Homebrew qmllint 测的，已作废）：
>
> - `[unqualified]` **250** 条（qmllint 总警告 258：另有 4 条 `[use-proper-function]`、4 条 `[missing-property]`）
> - QML 文件 **71** 个，其中 **21** 个已带 `pragma ComponentBehavior: Bound`
> - 集中度未变，前五名仍是视图文件：`DashboardView` 42 / `WeekPlanView` 38 /
>   `TodayTaskView` 38 / `MonthGoalView` 32 / `CountdownView` 31，合计 181 条（72%）
> - **退出码仍为 0**——这正是本计划要解决的「等于没有门禁」
>
> 工具改用目标 Qt SDK 自带的 `qmllint`（`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint`），
> 不要用 `/opt/homebrew/bin/qmllint`：本项目已明确 Homebrew Qt 不用于本仓库，两者版本不同、数字不可比。
>
> 基线数字与上面差距很大时先记下实测值，用实测值当基线，**不要硬凑**。

## Status

- **Priority**: P3
- **Effort**: M（机械改写，250 处横跨 71 个文件中的多数视图）
- **Risk**: MED（加 `pragma ComponentBehavior: Bound` 会改变名字解析，依赖外层 id 的地方会运行时报错）
- **Depends on**: none
- **Category**: tech-debt / perf
- **Planned at**: commit `52726d9`, 2026-07-29
- **基线重测**: commit `0aa89af`, 2026-08-07（数字见下表；仍未开工）

## Why this matters

实测（不是推断）：`qmllint` 在 **71** 个 QML 文件上报出 **250 条 `[unqualified]`**，
集中在五个视图文件（下表为 2026-08-07 在 `0aa89af` 上用 Qt 6.9.0 SDK 的 qmllint 重测；
括号里是 2026-07-29 的旧数，供对比——总量与集中度基本没变）：

| 文件 | 条数 |
|---|---|
| `qml/views/DashboardView.qml` | 42（旧 41） |
| `qml/views/WeekPlanView.qml` | 38 |
| `qml/views/TodayTaskView.qml` | 38 |
| `qml/views/MonthGoalView.qml` | 32 |
| `qml/views/CountdownView.qml` | 31（旧 25） |
| `qml/components/FocusTimeline.qml` | 13 |
| `qml/components/ColorPicker.qml` | 12 |
| `qml/components/CategoryDialog.qml` | 11 |

前五名合计 181 条，占全部的 72%——先做这五个文件就能拿到绝大部分收益。

两个代价：

1. **正确性**：unqualified 访问靠 `QQmlContext` 作用域链在运行时解析。
   本项目已经因此出过事——`GoalsView` 等文件不得不写 `// qmllint disable unqualified`
   来压警告，而那正是"依赖动态作用域"的地方，重构时最容易断。
2. **性能**：这类查找无法被 QML 脚本编译器做类型解析，绑定只能保持解释执行。
   典型例子是 `TaskItem.qml:32-36`——`layer.effect` 里的 `MultiEffect` 通过作用域链读
   `root.warmShadowColor` 等四个属性，而这些绑定**在每次悬停时逐行重新求值**。

而且 **qmllint 目前不是门禁**：`CMakeLists.txt` 与 `cmake/` 里没有任何 qmllint 引用，
文档里那条命令实测输出几百条诊断却 **exit 0**——在任何脚本里都和"干净"无法区分。
于是这个数字只会涨。

## Current state

### 两种解决手段

1. **加 `pragma ComponentBehavior: Bound`**（文件顶部一行）——
   让 delegate 内的名字绑定到声明它的组件，而不是运行时作用域。
   当前 67 个文件里只有约 24 个有它（`StatCard.qml:1`、`LiquidGlassBackdrop.qml:1`、
   `GoalCard.qml:1` 等）。
2. **给每处访问加显式限定**（`root.` / 具体 `id.`）。

两者要一起用：加了 pragma 而不限定，编译期会直接报错；只限定不加 pragma，
`Repeater`/`ListView` delegate 里的 `index`、`modelData` 仍是动态解析。

### 已有的正确范例

`qml/components/GoalCard.qml`（第 1 行 `pragma ComponentBehavior: Bound`，
delegate 里用 `required property var modelData`）和
`qml/views/GoalsView.qml`（`Repeater` 里 `required property int index` /
`required property string modelData`）都是改好之后该有的样子，直接照抄。

### 项目约定

- 注释用中文。本计划多数改动是机械限定，**不需要**加注释；
  只在"某处必须保留 unqualified"时写一句为什么。
- QML 测试硬规则：**绝不允许断言 `item.visible === true`**；用 `tryCompare`。

## Commands you will need

构建目录必须在仓库外，**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**（cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-029 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| lint 计数 | `/opt/homebrew/bin/qmllint -I qml qml/*.qml qml/views/*.qml qml/components/*.qml qml/components/settings/*.qml 2>&1 \| grep -c unqualified` | 逐步下降 |
| 全量 | `cd /tmp/pt-029 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

**注意**：`-I qml` 不能省，否则本地组件全部解析不出类型，警告数会失真。
`qml/components/settings/*.qml`（10 个文件）在项目现有文档的 lint 命令里是**漏掉的**，
本计划的命令已经补上。

## Scope

**In scope**：
- 按文件逐个消除 unqualified（优先上表前五个视图）
- 给处理完的文件加 `pragma ComponentBehavior: Bound`
- `CMakeLists.txt`（新增一个**可选**的 qmllint 目标，见 Step 4）
- 删除因此变得多余的 `// qmllint disable unqualified` 注释

**Out of scope**（不许碰）：
- **任何业务逻辑与视觉** —— 本计划只改名字怎么被解析，不改程序做什么。
  一次改动若同时改了行为，说明改错了。
- **把 qmllint 设成默认必过的门禁** —— 见 Step 4：先做成可选目标。
  241 → 0 之前就设成必过，只会让所有人都得先跳过它。
- `qt_add_qml_module` 迁移 —— 那会改动全部 import URL，属于独立的高风险改造。
- 任何 C++ 文件（`CMakeLists.txt` 除外）。

## Git workflow

- 分支：`advisor/029-qmllint-cleanup`
- **按文件分多次提交**，一个文件一次或几个相关文件一次。中文提交信息，
  例如 `仪表盘视图消除 unqualified 访问`。
  **不要把 43 个文件塞进一次提交**——出问题时无法二分定位。
- **不要 push，不要开 PR。**

## Steps

### Step 1: 记下真实基线，按文件排序

```bash
/opt/homebrew/bin/qmllint -I qml qml/*.qml qml/views/*.qml qml/components/*.qml \
  qml/components/settings/*.qml 2>&1 | grep "unqualified" -B1 \
  | grep -oE "qml/[a-zA-Z/]*\.qml" | sort | uniq -c | sort -rn
```

把这份清单贴进报告，作为进度对照。

### Step 2: 从前五个视图开始，一次一个文件

对每个文件：加显式限定 → 加 `pragma ComponentBehavior: Bound` →
`Repeater`/`ListView` delegate 里把隐式 `index`/`modelData` 改成
`required property`（照 `GoalsView.qml` 的写法）→ 编译 → 跑 QML 测试。

**每个文件独立验证，不要攒着一起跑。** 加 pragma 最容易在运行时炸
（`ReferenceError`），一次只动一个文件才能立刻定位。

**Verify（每个文件后）**：
`cmake --build /tmp/pt-029 -j8` → exit 0，且
`cd /tmp/pt-029 && ctest -R PomodoroTodoQmlTests --output-on-failure` → 通过

### Step 3: 处理剩余文件

同样的流程。若某处 unqualified **必须保留**（例如确实依赖注入的上下文属性，
且改造成本过高），**保留 `// qmllint disable unqualified` 并在旁边写一句中文说明为什么**，
然后在报告里列出所有这类豁免点。豁免是可以接受的，**没有解释的豁免不行**。

### Step 4: 把 qmllint 做成可选目标（不是必过门禁）

在 `CMakeLists.txt` 加一个自定义目标：

```cmake
# QML 静态检查。目前仍有存量告警，因此不挂进 ALL、也不做默认门禁；
# 清零之后再考虑加 --warnings=error 并接入 ctest。
add_custom_target(qmllint-check
    COMMAND <qmllint> -I ${CMAKE_CURRENT_SOURCE_DIR}/qml <所有 qml 文件>
    ...
)
```

**关键点**：
- 目标名不要挂 `ALL`；
- **不要**加 `--warnings=error`，除非计数真的到 0；
- qmllint 可执行文件路径要从 Qt 安装位置推导，不要硬编码 `/opt/homebrew`。

同时**更正文档**：`README.md:49` 那条 `pyside6-qmllint` 命令指向的工具本机没装，
且来自同一份 README 禁用的 PySide6 工具链；`docs/运行命令.md:93` 给的是另一条不兼容的命令，
两条都漏了 `qml/components/settings/*.qml`。**统一成一条**，指向新的 CMake 目标。

**Verify**: `cmake --build /tmp/pt-029 --target qmllint-check` 能跑出计数；
`cd /tmp/pt-029 && ctest --output-on-failure` → 14/14（新目标不影响默认门禁）

### Step 5: 全量回归

**Verify**:
```
cd /tmp/pt-029 && ctest --output-on-failure
```
→ 14/14，并在报告里给出最终的 unqualified 计数（从 241 降到了多少）

## Test plan

- **不新增用例**：本计划不改变任何行为，新增行为断言无从谈起。
- **回归是唯一安全网**：既有 14 个 ctest 条目，尤其 `PomodoroTodoQmlTests`
  （30 个 `tst_*.qml`）。加 `pragma ComponentBehavior: Bound` 的错误会表现为运行时
  `ReferenceError`，只有跑起来才会暴露——**所以每个文件都必须单独跑一次 QML 套件**。

## Done criteria

- [ ] `cd /tmp/pt-029 && ctest --output-on-failure` → 14/14
- [ ] unqualified 计数从 241 显著下降；报告里给出最终数字
- [ ] 所有保留的 `// qmllint disable unqualified` 旁边都有中文说明
- [ ] `cmake --build <dir> --target qmllint-check` 可用，且**未**挂进 `ALL`
- [ ] `README.md` 与 `docs/运行命令.md` 的 lint 命令已统一且可执行
- [ ] 提交是按文件分开的，不是一次性大提交
- [ ] `plans/README.md` 中 029 的状态行已更新

## STOP conditions

- 某个文件加 `pragma ComponentBehavior: Bound` 后出现 `ReferenceError`，
  且两次修复未解决 —— **回退该文件**，记进豁免清单，继续下一个。不要卡在一个文件上。
- 你发现消除某处 unqualified 需要改动组件的对外接口（新增属性、改信号签名）——
  停下报告。本计划是"只改名字解析"，改接口属于重构，超出范围。
- QML 套件在某个文件改完后变红且原因不明。
- 计数不降反升。

## Maintenance notes

- **清零之前 qmllint 不能设成必过门禁**，否则每个人都得先学会跳过它。
  路线是：本计划把 241 降到一个小数目 → 后续把剩余豁免逐个消掉 → 最后才加
  `--warnings=error` 并接进 ctest。这个顺序不要颠倒。
- `pragma ComponentBehavior: Bound` 应当成为**新文件的默认**。清理完之后值得在
  `AGENTS.md` 的 Qt/QML 规则里加一条。
- 本计划**不解决** QML 的 AOT 编译问题——项目用的是普通 `qml.qrc` + `QQmlApplicationEngine`，
  没有 `qt_add_qml_module`，因而没有 `qmlcachegen`。消除 unqualified 是那条路的前置条件，
  但迁移本身是另一件事，风险高得多。
