# Plan 026: 给阴影 MultiEffect 设定 blurMax，停止为不存在的 32px 模糊预留纹理

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 0aa89af..HEAD -- qml   # 基线 2026-08-07 复核时更新
> grep -rn "blurMax" qml/          # 当前应只有 2 处：MainWindow.qml:455、LiquidGlassBackdrop.qml:193
> grep -rc "autoPaddingEnabled: true" qml/ | grep -v ":0" | wc -l   # 当前应为 14
> ```
>
> 数字对不上就先核对下文的使用点，明显不符按 STOP condition 处理。
>
> 2026-08-07 在 `0aa89af` 上重验：两个数字都没变，只有行号漂移
> ——侧栏 `MultiEffect` 由 `:443-449` 移到 **`MainWindow.qml:450-456`**（`blurMax: 48` 在 `:455`）。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW（只加属性，不碰 `layer.enabled`）
- **Depends on**: plans/025（用它的 harness 出改动前后读数；若 025 未落地，见 Step 4 的退让方案）
- **Category**: perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

Qt 的 `MultiEffect` 有两个互相牵连的属性：

- `blurMax` —— 模糊半径上限，**默认 32**
- `autoPaddingEnabled` —— 按 `blurMax` 给效果项四周预留 padding，**默认 true**

本项目 14 个文件开着 `autoPaddingEnabled: true` 做阴影，`shadowBlur` 取值都在 **0.14–0.35**，
即实际阴影半径约 `shadowBlur × blurMax` = **4.5–11px**。但**没有任何一处阴影设过 `blurMax`**
（全仓 `blurMax` 只出现 2 次，都不在阴影上）。于是纹理按 32px 预留，实际只用到 11px 以内。

后果按 Qt 文档的 padding 公式推算：一个 700×76 的任务行，纹理从 53,200 px 变成约 106,960 px，
**2 倍像素**；48×36 的删除按钮从 1,728 变成约 11,200，**6.5 倍**。而 `TaskItem` 的阴影参数
（`warmShadowOpacity` / `warmShadowBlur` / `warmShadowVerticalOffset`）全部随 hover 动画，
意味着这块被撑大的 layer **每次悬停都要重画**。

Qt 官方文档对 `blurMax` 的建议原文是：「The most optimal way to reduce shadow blurring is to
make `blurMax` smaller」。本计划就是执行这一条。

## Current state

### 典型现场：`qml/components/TaskItem.qml:17-37`

```qml
// MultiEffect 的阴影参数不直接承载动画，先放到 root 属性上过渡，再绑定给效果。
property color warmShadowColor: Theme.ink
property real warmShadowOpacity: root.compact ? (root.itemHovered ? 0.08 : 0.05)
                                              : (root.itemHovered ? 0.12 : 0.08)
property real warmShadowBlur: root.compact ? (root.itemHovered ? 0.16 : 0.12)
                                           : (root.itemHovered ? 0.25 : 0.18)
property real warmShadowVerticalOffset: ...
// 图层生命周期必须稳定：hover 事件分发期间切换 layer.enabled 会重建效果项，
// Qt Quick 此时仍在递归遍历命中树，可能继续访问已释放的 QQuickItem。
layer.enabled: true
layer.effect: MultiEffect {
    autoPaddingEnabled: true
    shadowEnabled: true
    shadowColor: root.warmShadowColor
    shadowOpacity: root.warmShadowOpacity
    shadowBlur: root.warmShadowBlur          // ← 0.12–0.25
    shadowHorizontalOffset: 0
    shadowVerticalOffset: root.warmShadowVerticalOffset
}
// ← 没有 blurMax，取默认 32
```

**最重要的一条约束就写在这段代码的注释里**：`layer.enabled` 的生命周期必须稳定，
hover 事件分发期间切换它会重入已释放的 `QQuickItem`。
**本计划绝不触碰 `layer.enabled`**，只加 `blurMax` 并重标 `shadowBlur`——这正是选它做第一个
性能计划的原因：拿到收益，同时完全绕开那个已知的崩溃面。

### 换算规则（照这个改，保证视觉不变）

当前实际半径 = `shadowBlur × 32`。设定新 `blurMax` 后要把 `shadowBlur` 重标：

```
新 blurMax   = ceil(当前 shadowBlur 最大取值 × 32)
新 shadowBlur = 当前 shadowBlur × 32 / 新 blurMax
```

以 `TaskItem` 为例：`shadowBlur` 最大 0.25 → 半径 8px → `blurMax: 8`，
`warmShadowBlur` 的四个分支各乘 `32/8 = 4`：0.12→0.48、0.16→0.64、0.18→0.72、0.25→1.0。
**`shadowBlur` 的取值范围是 0.0–1.0，重标后不得超过 1.0**——超了说明 `blurMax` 取小了。

### 14 个使用点

用这条命令拿到完整列表，逐个处理：

```bash
grep -rn "autoPaddingEnabled: true" qml/
```

已知的几处（`shadowBlur` 值）：`MainWindow.qml:775`（0.35）、`StatCard.qml:49`（属性绑定）、
`EditTaskDialog.qml:247`（0.20）、`FocusTimeline.qml:28`（0.14）、`CountdownDialog.qml:178`（0.20）、
`RoutineDialog.qml:205`（0.20）、`GlassPanel.qml:30-38`（0.14）、
`TaskItem.qml:29-37`（属性绑定）、`TaskItem.qml:657-664`（删除按钮）、
`TodayTaskView.qml:550-556`（0.14）、`MonthGoalView.qml:493-499`（0.14）。

**`GlassPanel.qml` 是共享组件**，改它会影响所有使用方——它的 `shadowBlur` 固定 0.14 → 半径 4.5px
→ `blurMax: 5`、`shadowBlur: 0.9`。

### 另一处同源问题：侧栏磨砂（本计划一并处理）

`qml/MainWindow.qml:443-449` 是**整背景模糊**（不是阴影）：

```qml
MultiEffect {
    blurEnabled: true
    blur: 0.9
    blurMax: 48          // ← 超过默认 32
    // autoPaddingEnabled 用默认 true
}
```

Qt 文档对 `autoPaddingEnabled` 写得很直白：「When applying the blur effect to the whole
background, remember to set `autoPaddingEnabled` false or the effect grows "outside" the
window / screen.」这里正是整背景模糊，却没关。推算：240×900 的侧栏条被 padding 到约
336×996，**多模糊约 55% 的像素**；而 `width` 带 280–320ms 展开动画并喂给 `sourceRect`，
这笔开销在整个动画期间每帧都付。

对照 `qml/components/LiquidGlassBackdrop.qml:155` 已经用 `textureSize` 封顶了纹理，
侧栏这处没有。

## Commands you will need

构建目录必须在仓库外，且**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（默认 ON 且部署目标挂在 `ALL`，不关会覆盖 `/Applications/番茄Todo.app`；它是 cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-026 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-026 -j8` | exit 0 |
| 全量 | `cd /tmp/pt-026 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

## Scope

**In scope**：
- 14 个带 `autoPaddingEnabled: true` 阴影的 QML 文件（只加 `blurMax` + 重标 `shadowBlur`）
- `qml/MainWindow.qml:443-449`（侧栏磨砂：加 `autoPaddingEnabled: false`，`blurMax` 48→32 并用
  `blurMultiplier` 补偿）
- `qml/MainWindow.qml:433-441`（给 `ShaderEffectSource` 加 `textureSize` 封顶，照
  `LiquidGlassBackdrop.qml:155` 的写法）

**Out of scope**（不许碰）：
- **`layer.enabled`** —— 一个字都不要动。`TaskItem.qml:26-27` 的注释说明了为什么：
  hover 事件分发期间切换它会重入已释放的 `QQuickItem`。这是本计划刻意绕开的崩溃面。
- **`shadowColor` / `shadowOpacity` / `shadowVerticalOffset`** —— 阴影的颜色与位置不变，
  本计划只动「模糊半径怎么算」。
- `LiquidGlassBackdrop.qml:193` 的 `blurMax: 32` —— 那是折射层不是阴影，已经是显式值。
- 任何 C++ 文件。

## Git workflow

- 分支：`advisor/026-shadow-blurmax`
- 中文提交信息，建议分两次：`阴影 MultiEffect 显式设定 blurMax` / `侧栏磨砂关闭自动 padding 并封顶纹理`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先改 `GlassPanel.qml`（共享组件，收益面最大）

`shadowBlur: 0.14` → `blurMax: 5` + `shadowBlur: 0.9`。加中文注释说明换算依据：

```qml
// blurMax 默认 32，而这里实际只需要 0.14×32≈4.5px 的阴影；
// autoPaddingEnabled 会按 blurMax 预留 padding，不设上限等于为用不到的 27px 白付纹理。
// 重标规则：blurMax = ceil(原 shadowBlur × 32)，shadowBlur = 原值 × 32 / 新 blurMax。
```

**Verify**: `cmake --build /tmp/pt-026 -j8` → exit 0；`ctest` → 14/14

### Step 2: 逐个处理其余 13 处阴影

对每一处：算出当前半径 → 定 `blurMax` → 重标 `shadowBlur`（含所有三元分支）。
`TaskItem.qml` 的 `warmShadowBlur` 有四个分支，四个都要乘同一个系数。

**Verify**: `grep -rn "autoPaddingEnabled: true" qml/` 的每一处附近都能看到 `blurMax`

### Step 3: 侧栏磨砂

`MainWindow.qml:443-449`：加 `autoPaddingEnabled: false`；`blurMax` 48→32，
用 `blurMultiplier` 补偿视觉强度（先试 1.5，以肉眼等效为准）。
`MainWindow.qml:433-441` 的 `ShaderEffectSource` 加 `textureSize`，照
`LiquidGlassBackdrop.qml:155` 的写法封顶。

**Verify**: `ctest` → 14/14

### Step 4: 视觉等效核对（本计划的真正验收）

**改动的全部前提是「视觉不变、只是不再浪费纹理」。必须证明视觉真的没变。**

用 plans/025 的 harness 或直接写离屏 harness，对**同一组件**改动前后各渲染一张，
肉眼比对阴影的浓淡与扩散范围。至少覆盖：`TaskItem`（悬停态与常态）、`StatCard`、
`GlassPanel`、侧栏磨砂。

**离屏陷阱**：`MultiEffect` 在 `QSG_RHI_BACKEND=software` 下渲染为空，
带落影的面板会整块看不见。所以**阴影的视觉比对无法在软件后端做**。
两个选择：
1. 若 025 已落地且提供了可用的比对方式，用它；
2. 否则**如实报告「阴影视觉比对未能离屏验证」**，并把改动前后的参数换算表写进报告，
   由人在真机上确认。**不要假装验证过。**

**Verify**: 报告里要么有比对图，要么有明确的「未能验证 + 换算表」

### Step 5: 全量回归

**Verify**:
```
cd /tmp/pt-026 && ctest --output-on-failure
grep -rn "autoPaddingEnabled: true" qml/ | wc -l    # 仍为 14（侧栏那处改成了 false，不计入）
grep -rn "blurMax" qml/ | wc -l                      # 应从 2 增至 15 左右
```

## Test plan

- 无新增断言：`blurMax`/`shadowBlur` 是视觉参数，断言具体数值只会变成同义反复。
- 回归：现有 14 个 ctest 条目全绿。注意 `tests/qml/tst_mainwindow_ui_optimization.qml`
  有断言动画 `duration` 的用例，本计划不碰 duration，应不受影响——若受影响说明改错了地方。
- 验收靠 Step 4 的视觉等效核对。

## Done criteria

- [ ] `cd /tmp/pt-026 && ctest --output-on-failure` → 14/14
- [ ] 每一处 `autoPaddingEnabled: true` 的阴影附近都有显式 `blurMax`
- [ ] 所有重标后的 `shadowBlur` 取值都在 0.0–1.0 之内
- [ ] `git diff qml/ | grep -c "layer.enabled"` → **0**（一处都没碰）
- [ ] `MainWindow.qml` 侧栏磨砂处有 `autoPaddingEnabled: false` 与 `textureSize`
- [ ] Step 4 的结论已如实写进报告（比对图或「未能验证」）
- [ ] `plans/README.md` 中 026 的状态行已更新

## STOP conditions

- Drift check 的数字与实际差距明显。
- 某处重标后 `shadowBlur` 必须大于 1.0 才能保持等效 —— 说明 `blurMax` 取小了，重算。
- 你发现要改 `layer.enabled` 才能拿到收益 —— **立即停下报告**，那条路有已知的重入崩溃风险，
  不是本计划能承担的。
- 视觉比对发现阴影明显变了（更硬/更淡/位置偏移）—— 报告是哪一处、参数是多少。
- 既有 QML 用例变红。

## Maintenance notes

- 改完之后，**新增任何阴影 `MultiEffect` 都必须显式写 `blurMax`**，否则又会回到默认 32。
  值得在 `GlassPanel.qml` 的头部注释里写一句，因为多数阴影是通过它来的。
- 更彻底的做法是把阴影参数收进一个共享组件（项目已有颜色/间距/圆角令牌，唯独阴影没有），
  但那是设计系统层面的改造，本计划刻意没有做——先拿到零风险的收益。
- 侧栏 `blurMultiplier` 的取值是肉眼调的，没有客观判据。若将来有人觉得磨砂变淡了，
  应该调 `blurMultiplier` 而不是把 `blurMax` 调回 48。
