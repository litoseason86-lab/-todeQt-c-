# Plan 015: 把玻璃卡的白色描边换成对比细线，让卡片在亮壁纸上不再消失

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> grep -n "glassBorderContrast" qml/Theme.qml                 # 必须命中（令牌已存在）
> grep -n "border.color: Theme.glassBorder$" qml/components/GlassPanel.qml   # 必须命中（默认值待改）
> grep -rc "Theme.glassBorder\b" qml/ | grep -v ":0" | wc -l  # 记下当前使用点分布
> ```
>
> 第一条不命中说明 `glassBorderContrast` 令牌尚未落地 → STOP。

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED（改的是全应用每一张玻璃卡的描边，视觉影响面大但可逆）
- **Depends on**: none（`glassBorderContrast` 令牌已在目标页改造中落地）
- **Category**: bug / design-system
- **Planned at**: commit `2bee279` + 未提交的目标页改动，2026-07-27

## Why this matters

浅色主题的玻璃卡用两个都接近白色的值叠在一起：

- 卡底 `glassCard` = `rgba(255, 255, 250, 0.42)`
- 描边 `glassBorder` = `rgba(255, 255, 255, 0.65)`

壁纸主题里有四张是**近白的亮图**（`sword` 雪岭剑影、`pink` 樱粉、`jiangnan` 烟雨江南、`warm` 暖色）。
白底 + 白边压在近白壁纸上，卡片边界在物理上就不存在——不是"不够明显"，是**看不见**。
实测：雪岭壁纸下，目标列表卡的右半边完全溶进背景。

Apple 的浅色材质不用白边：顶部留一道白高光表现受光，四周是一道很淡的**深色**细线切断背景。
`Theme.glassBorderContrast` 已经按这个思路做好并在目标页验证通过，但**只铺了目标页**。
全应用还有 22 处在用白描边，其中大部分是同样浮在壁纸上的内容卡。

## Current state

### 令牌（已存在，本计划不改它的值）

`qml/Theme.qml`：

```qml
readonly property color glassBorder: darkMode
    ? Qt.rgba(1, 1, 1, 0.18)
    : Qt.rgba(1, 1, 1, 0.65)
// 内容卡专用分隔描边。glassBorder 浅色版是白的，压在亮壁纸（雪岭/樱粉这类近白图）
// 上会和近白的 glassCard 一起消失，卡片边界整个看不见。
readonly property color glassBorderContrast: darkMode
    ? Qt.rgba(1, 1, 1, 0.20)
    : Qt.rgba(90 / 255, 72 / 255, 48 / 255, 0.22)
```

注意暗色版两者几乎相同（0.18 vs 0.20）——**这个令牌实质是浅色模式的修复**，
暗色下换不换都一样。这是有意为之：暗底上深线才是隐形的，暗色模式本来就没坏。

### 关键杠杆点：`GlassPanel` 的默认值

`qml/components/GlassPanel.qml:25`：

```qml
Rectangle {
    id: root
    radius: Theme.radiusLg
    color: root.solidFallback ? Theme.glassSolidCard : Theme.glassCard
    border.color: Theme.glassBorder      // ← 这一行是全应用玻璃面板的默认描边
    border.width: 1
```

`GlassPanel` 的使用方（14 个文件）大多不覆盖 `border.color`，直接吃默认值。
**改这一处，比逐个去改 17 个调用点更省、更不容易漏。**

### 22 个使用点的分类（本计划的核心判断）

**不是所有都该改。** 按背景分三类：

**A 类 —— 浮在壁纸上的内容卡 / 控件（应改为 `glassBorderContrast`）**

| 文件:行 | 说明 |
|---|---|
| `qml/components/GlassPanel.qml:25` | **默认值，优先改这一处** |
| `qml/components/StatCard.qml:41` | 仪表盘统计卡 |
| `qml/components/ChartPie.qml:26` | 饼图卡 |
| `qml/components/ChartBar.qml:22` | 柱图卡 |
| `qml/components/FocusTimeline.qml:20` | 专注时间轴 |
| `qml/components/WeeklyReviewCard.qml:26` | 每周复盘卡 |
| `qml/components/AchievedGoalsCard.qml:44` | 已达成目标卡 |
| `qml/components/CountdownItem.qml:27` | 倒计时条目（悬停时走 accent，仅改非悬停分支） |
| `qml/views/MonthGoalView.qml:490` | 月历格 |
| `qml/views/TodayTaskView.qml:547` | 今日任务区块 |
| `qml/views/WeekPlanView.qml:489` | 周计划区块 |
| `qml/views/DashboardView.qml:802` | 仪表盘区块 |
| `qml/views/CountdownView.qml:116` | 倒计时英雄区（悬停走 accent） |
| `qml/MainWindow.qml:787` | 主窗口内的玻璃块 |
| `qml/components/FocusGoalStrip.qml:164` | 今日专注目标条（悬停走 accent） |
| `qml/components/DashboardTimerPanel.qml:229` | 仪表盘计时面板内块 |
| `qml/components/FocusGoalCard.qml:170` | 快捷填充 chip（悬停走 accent） |
| `qml/components/DailyFocusGoalEditor.qml:220` | 保存按钮（聚焦走 inkStrong） |

**B 类 —— 压在深色遮罩上的模态弹窗（保持白描边，不要动）**

| 文件:行 | 为什么不改 |
|---|---|
| `qml/components/SettingsDialog.qml:144` | 弹窗底是近实心浅色，背后是 `Theme.modalScrim` 深色遮罩。浅色弹窗 + 深色背景本来就有分离，白色棱边在这个语境下是**正确**的受光表现，换成深线反而脏 |
| `qml/components/GoalFormDialog.qml:192` | 同上 |
| `qml/views/GoalsView.qml:723` | 删除确认弹窗，同上 |
| `qml/components/MilestoneDialog.qml:71` | 里程碑弹窗，同上 |

**判定口径（执行者按这条判断，不要死记表格）**：
问"这个描边的背后是壁纸，还是 `modalScrim` 遮罩？"
背后是壁纸 → A 类改；背后是遮罩 → B 类不改。

### 已经改好的参照（照这个写法）

目标页的三张详情卡与两种卡片已经改完，可直接照抄：

```qml
// qml/components/GoalCard.qml
border.color: root.activeFocus ? Theme.focusRing
                               : (root.hovered ? Theme.accent : Theme.glassBorderContrast)
```

要点：**只替换"常态"那一支**。聚焦（`focusRing`）、悬停（`accent`）、危险（`dangerBorder`）
这些语义分支一律不动——它们本来就有足够对比。

### 项目约定

- 颜色只能用 `Theme.qml` 的语义令牌，禁止硬编码色值；状态不得只靠颜色表达。
- 注释用中文，解释「为什么」和「边界条件」。
- **QML 测试硬规则：绝不允许断言 `item.visible === true`**（离屏沙箱里可见性会级联）。
  用 `tryCompare` / `tryVerify`，不要用固定 `wait()`。

## Commands you will need

构建目录**必须在仓库外**，且**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**——
该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`。
（该选项是 cache 变量会粘住：**换构建目录时必须重新显式传**，否则复用旧目录的值。）

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-015 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-015 -j8` | exit 0 |
| 全量 | `cd /tmp/pt-015 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

### 离屏视觉走查（本计划必须做，判据是"看得见"而不是"编译过"）

```bash
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
  /Users/zerionlito/Qt/6.9.0/macos/bin/qml <harness>.qml
```

- **必须**是 `QSG_RHI_BACKEND=software`，不是 `QT_QUICK_BACKEND=software`——后者的
  `grabToImage()` 在离屏下返回 false。
- **已知陷阱**：`GlassPanel` 的落影走 `layer.enabled + MultiEffect`，在 software 后端下
  **会让整块面板不可见**。走查带落影的面板时，先临时把 `panelShadowEnabled: false`，
  否则你会误判成"面板消失了"。
- harness 里 import 需要 scheme：`import "file:///Users/zerionlito/code/番茄todo/qml"`。
- macOS 没有 `timeout`：后台跑 qml 进程，`sleep` 后 `kill`。

## Scope

**In scope**：
- `qml/components/GlassPanel.qml`（默认描边）
- 上表 A 类的其余 17 个文件（**只改常态那一支**）
- `tests/qml/tst_theme_tokens.qml`（新增令牌用途断言）

**Out of scope**（不许碰）：
- **B 类的 4 个弹窗** —— 见上表理由。
- **`Theme.glassBorder` 与 `glassBorderContrast` 的数值** —— 本计划是"把已验证的令牌铺开"，
  不是"调色"。改数值是设计决策，不是执行者能定的。
- **聚焦 / 悬停 / 危险分支** —— `focusRing`、`accent`、`dangerBorder`、`inkStrong` 一律保留。
- 目标页的 `GoalCard` / `GoalTile` / `GoalsView` 详情卡 —— 已经改完了。
- 任何 C++ 文件。

## Git workflow

- 分支：`advisor/015-glass-border-rollout`
- 中文提交信息，建议分两次：
  `玻璃面板默认描边改用对比细线` / `其余内容卡跟随对比描边`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先改 `GlassPanel` 默认值，量一下覆盖了多少

`qml/components/GlassPanel.qml:25` 改成 `Theme.glassBorderContrast`，并补注释说明
"默认给内容卡用对比细线；压在深色遮罩上的弹窗自己覆盖回 `glassBorder`"。

然后统计还剩多少个**显式**写了 `Theme.glassBorder` 的调用点：

```bash
grep -rn "Theme.glassBorder\b" qml/ | grep -v glassBorderContrast
```

**Verify**: `cmake --build /tmp/pt-015 -j8` → exit 0；全量 `ctest` → 14/14

### Step 2: A 类调用点逐个替换

按上表逐个改，**只改常态那一支**。带悬停/聚焦三元的（`CountdownItem`、`CountdownView`、
`FocusGoalStrip`、`FocusGoalCard`、`DailyFocusGoalEditor`）尤其小心，只动 `else` 那一支。

**Verify**:
```bash
grep -rn "Theme.glassBorder\b" qml/ | grep -v glassBorderContrast
```
→ 只剩 B 类那 4 处（SettingsDialog / GoalFormDialog / GoalsView 删除确认 / MilestoneDialog）

### Step 3: 离屏视觉走查（本计划的真正验收）

对**亮壁纸**（`sword`）和**暗壁纸**（`moon`）各渲染一遍下列页面，确认卡片边界可见：

1. 仪表盘（StatCard 若干 + 计时面板）
2. 今日任务（TaskItem 列表）
3. 数据统计（ChartPie / ChartBar / WeeklyReviewCard / AchievedGoalsCard）
4. 目标倒计时（CountdownItem）

**判据**：亮壁纸下，每张卡的四条边在**卡片压住壁纸最亮区域的那一段**仍然可辨。
改动前后各存一张，放 `docs/设计稿/玻璃描边/`。

**这一步不能省**：编译通过和测试通过都证明不了"边界看得见"，
而"看得见"正是本计划存在的唯一理由。

### Step 4: 用例锁定令牌用途

在 `tests/qml/tst_theme_tokens.qml` 追加：

1. `glassBorderContrast` 在浅色下的 alpha 与 RGB 不等于纯白
   （断言 `r < 0.5 && g < 0.5 && b < 0.5`，即它确实是深色线）
2. `GlassPanel` 的默认 `border.color` 等于 `Theme.glassBorderContrast`

第 2 条是防回归的关键：将来有人把默认值改回 `glassBorder` 会当场变红。

**先确认这两条在改动前是红的**，再确认改动后转绿。一条从没红过的测试证明不了什么。

**Verify**: 全量 `ctest` → 14/14

## Test plan

- 新增 2 条 `tst_theme_tokens.qml` 用例（令牌是深色线 / GlassPanel 默认值）
- 回归：现有 14 个 ctest 条目全绿，尤其 `tst_theme_tokens.qml`、`tst_dashboard_view.qml`、
  `tst_ui_optimization.qml` 这些会碰到玻璃令牌的
- 视觉走查 8 张截图（4 页 × 明暗），改动前后对比

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-015 && ctest --output-on-failure` → 14/14
- [ ] `grep -rn "Theme.glassBorder\b" qml/ | grep -v glassBorderContrast` → **只剩 4 行**，
      且都属于 B 类弹窗
- [ ] `grep -n "glassBorderContrast" qml/components/GlassPanel.qml` → 命中
- [ ] `git diff qml/` 中**没有**对 `focusRing` / `accent` / `dangerBorder` 分支的改动
- [ ] `Theme.qml` 里两个令牌的**数值**与改动前完全一致
- [ ] 8 张走查截图已生成；报告里写明"改动前后分别看到了什么"
- [ ] `plans/README.md` 中 015 的状态行已更新

## STOP conditions

停下报告，不要自行发挥：

- Drift check 不命中（令牌不存在 / GlassPanel 默认值已被改过）。
- 视觉走查发现某张卡改后**反而更糟**（例如原本压在深色区域、深线让它糊掉）——
  报告是哪张卡、哪个壁纸，不要自己发明第三个令牌。
- 你发现某处 `Theme.glassBorder` 既不属于 A 类也不属于 B 类（背后既不是壁纸也不是遮罩）——
  报告，让人来判断。
- 既有 QML 用例因描边改动变红。

## Maintenance notes

- 改完之后，**`Theme.glassBorder` 的语义收窄为"压在深色遮罩上的浅色弹窗棱边"**。
  值得在 `Theme.qml` 的注释里写清楚，否则下一个人还会拿它当通用卡片描边。
- 暗色模式下两个令牌几乎相同（0.18 / 0.20），所以本计划的视觉收益**几乎全在浅色模式**。
  走查时不要因为"暗色看不出区别"就以为没生效。
- 审查这个 PR 时该重点看：有没有误伤悬停/聚焦分支（那会让键盘可达性回退），
  以及 B 类 4 个弹窗是不是真的没被动。
