# Plan 030: 专注计时环从 Canvas 换成 Shape，消除动画期间的逐帧 JS 重绘

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- qml/components/FocusRing.qml qml/views/FocusView.qml
> head -8 qml/components/FocusRing.qml | grep -n "Canvas"      # 必须命中（待改）
> grep -n "preferredRendererType" qml/components/GoalProgressRing.qml  # 必须命中（参照件）
> grep -n "implicitWidth" qml/views/FocusView.qml | head       # 定位 :660 附近的动画
> ```

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED（`Canvas` 里有 `ctx.shadowBlur` 光晕，`Shape` 没有直接等价物）
- **Depends on**: plans/025（量化收益）
- **Category**: perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

`qml/components/FocusRing.qml` 是专注页的视觉主体，用 `Canvas` 绘制。
`Canvas` 的重绘是 **JS 执行 + CPU 逐像素光栅化 + 纹理上传**，全部在主线程。

它有五个 `requestPaint()` 触发源，其中两个是尺寸：

```qml
// qml/components/FocusRing.qml:23-27
onProgressChanged: requestPaint()
onRingColorChanged: requestPaint()
onShowPreviewChanged: requestPaint()
onWidthChanged: requestPaint()      // ← 这两个是问题所在
onHeightChanged: requestPaint()
```

而 `qml/views/FocusView.qml:660` 附近给它的 `implicitWidth` 加了 150ms 的 `Behavior`
（在 190 和 252 之间切换）。**于是每次展开/收起，环都会在约 9 帧里逐帧重新光栅化并重传纹理**，
最大 252×252 逻辑像素（Retina DPR 2 下每次上传约 1MB）。

非动画期间的成本是可以接受的：`progress` 由 1000ms 的计时器 tick 驱动
（`src/services/FocusTimer.cpp:20`），1Hz 重绘不是问题。**动画期间的逐帧重绘才是这条的全部内容。**

**项目已经为另一个环做过同样的判断**：`qml/components/GoalProgressRing.qml:5-8` 的注释写着
「用 Shape 避免 Canvas 的 JavaScript 绘制与纹理上传」。大环没跟上，仅此而已。

## Current state

### `FocusRing.qml` 的对外契约（改造必须原样保留）

```qml
Canvas {
    id: ring

    property real progress: 1.0       // 剩余时间占比：1=刚开始/已合拢，0=时间耗尽
    property color ringColor: Theme.accent
    property bool showPreview: false  // 待机态：只画一圈虚线预览，不画进度弧
    property bool dimmed: false       // 暂停态：整体降低不透明度，转由灰色轨道提示
    readonly property real strokeWidth: 14

    opacity: dimmed ? 0.38 : 1
    antialiasing: true

    Behavior on opacity {
        NumberAnimation { duration: Theme.reduceMotion ? 0 : 150 }
    }
```

组件头部注释明确了它的设计意图：**"进度/颜色/暂停/预览态全部由外部属性驱动，
自身不读取 root 状态——保持可复用、可测试（测试直接断言这几个绑定属性，不做像素级检查）"**。

**这四个属性 + `strokeWidth` 是对外契约，改造后必须逐字保留**，否则现有测试和
`FocusView` 的绑定都会断。

### 三段 `save()`/`restore()`，其中一段是难点

```
:47  ctx.save()
:49  ctx.shadowBlur = 14      ← 内层玻璃盘的光晕，Shape 没有直接等价物
:59  ctx.restore()
:62  ctx.save()  ... :71  ctx.restore()
:122 ctx.save()  ... :129 ctx.restore()
```

`ctx.shadowBlur = 14` 是**本计划最大的不确定性**。`Shape` 不提供绘制阴影。
可选替代：用一个额外的 `Rectangle` + `MultiEffect` 做光晕，或用径向渐变模拟。
**先读懂 `:47-59` 到底在画什么，再决定**——如果那段是"内层玻璃盘"而不是环本身，
它完全可以留在 `Canvas` 之外用普通 QML 元素实现。

### 参照件：`qml/components/GoalProgressRing.qml`

```qml
Shape {
    anchors.centerIn: parent
    width: root.ringSize
    height: root.ringSize
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        strokeColor: Theme.borderSubtle
        strokeWidth: root.strokeWidth
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
            centerX: root.ringSize / 2
            centerY: root.ringSize / 2
            radiusX: root.radius
            radiusY: root.radius
            startAngle: -90
            sweepAngle: 360
        }
    }
    // 第二条 ShapePath 画进度弧，sweepAngle 绑定百分比
}
```

它还记录了一条重要经验（`:5-8`）：**不要给 `sweepAngle` 加 `Behavior` 动画**——
在启用 delegate 复用的列表里会导致圆弧从上一项的进度 animate 过去。
`FocusRing` 不在复用列表里，但同样**不要加**：`progress` 每秒变一次，加动画只会让
数字与圆弧对不上。

### 项目约定

- 颜色只能用 `Theme.qml` 的语义令牌，禁止硬编码色值。
- 动效必须支持 `reduceMotion`；注释用中文，解释「为什么」和「边界条件」。
- QML 测试硬规则：**绝不允许断言 `item.visible === true`**；用 `tryCompare`。

## Commands you will need

构建目录必须在仓库外，**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**（cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-030 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| QML 测试 | `cd /tmp/pt-030 && ctest -R PomodoroTodoQmlTests --output-on-failure` | 通过 |
| 全量 | `cd /tmp/pt-030 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

### 离屏视觉走查（本计划必须做）

```bash
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
  /Users/zerionlito/Qt/6.9.0/macos/bin/qml <harness>.qml
```
- 必须是 `QSG_RHI_BACKEND=software`（不是 `QT_QUICK_BACKEND=software`）。
- harness import 需要 scheme：`import "file:///Users/zerionlito/code/番茄todo/qml"`。
- macOS 没有 `timeout`：后台跑、`sleep` 后 `kill`。
- **注意**：若光晕最终用 `MultiEffect` 实现，它在软件后端**渲染为空**——
  那部分无法离屏验证，如实报告。

## Scope

**In scope**：
- `qml/components/FocusRing.qml`（`Canvas` → `Shape`）
- `qml/views/FocusView.qml`（仅在必要时调整对 `FocusRing` 的使用；见 Out of scope）
- 对应的 `tests/qml/tst_focus_view.qml`（若断言涉及环）

**Out of scope**（不许碰）：
- **`FocusRing` 的四个对外属性与 `strokeWidth`** —— `progress`/`ringColor`/`showPreview`/
  `dimmed` 必须逐字保留，签名和语义都不许变。
- **`FocusView` 的计时逻辑与状态机** —— 那是核心路径，本计划只换一个绘制实现。
- **`FocusView.qml:660` 附近的尺寸动画本身** —— 见 Step 4：只有在 `Shape` 方案确实无法
  承受逐帧 resize 时才考虑动它，且要单独报告。
- 任何 C++ 文件。

## Git workflow

- 分支：`advisor/030-focus-ring-shape`
- 中文提交信息：`专注计时环改用 Shape 绘制`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先读懂现有 `onPaint`，把它拆成三层

完整读 `qml/components/FocusRing.qml` 的 `onPaint`（约 :29-135）。
在报告里写清楚三段 `save()`/`restore()` 各自画的是什么：
轨道？进度弧？内层玻璃盘？虚线预览？

**这一步不写代码。** 拆不清楚就直接 STOP——照着看不懂的绘制代码重写，
只会得到一个"看起来差不多"的环。

### Step 2: 用 `Shape` 重画轨道与进度弧

照 `GoalProgressRing.qml` 的结构。**不要**给 `sweepAngle` 加 `Behavior`。
`showPreview` 为真时画虚线预览——`ShapePath` 支持 `strokeStyle: ShapePath.DashLine`
和 `dashPattern`。

`dimmed` 走 `opacity`，保留现有的 `Behavior on opacity`（那是暂停态的淡入淡出，
和逐帧重绘无关，是好的）。

**Verify**: `ctest -R PomodoroTodoQmlTests` → 通过

### Step 3: 处理光晕（本计划的难点）

按 Step 1 的结论决定：
- 若 `ctx.shadowBlur = 14` 画的是**环本身的外发光** → 用 `MultiEffect` 或径向渐变模拟；
- 若画的是**内层玻璃盘** → 它本来就不属于"环"，用普通 `Rectangle` + 渐变实现，
  甚至可以留在 `FocusView` 里。

**若两种方案的视觉都明显不如现在，STOP 并报告**，附上对比图。
保留一个不好看的环比换掉一个好看的环更糟。

### Step 4: 量化并确认动画期间不再重绘

用 plans/025 的 harness：在 190↔252 之间切换 `implicitWidth`，
数动画期间的帧数与耗时，对比改动前后。**把数字写进报告。**

若 025 未落地：如实写"未能量化"，并给出结构性依据
（`Canvas` 的 `onWidthChanged: requestPaint()` 已消失）。

### Step 5: 视觉走查 + 全量

离屏渲染四个状态各一张：常态、暂停（`dimmed`）、待机预览（`showPreview`）、
接近耗尽（`progress` 趋近 0）。改动前后对比。

**Verify**: `cd /tmp/pt-030 && ctest --output-on-failure` → 14/14

## Test plan

- **回归优先**：`tests/qml/tst_focus_view.qml` 是主要安全网。组件头部注释说明测试
  "直接断言这几个绑定属性，不做像素级检查"——所以只要属性契约不变，用例应当全绿。
  **若它们红了，八成是你改了对外属性**。
- **新增**（可选，若能稳定断言）：`showPreview` 切换后进度弧的 `sweepAngle` 变化。
- 验收主要靠 Step 5 的视觉走查，不靠断言——环的正确性是视觉的。

## Done criteria

- [ ] `cd /tmp/pt-030 && ctest --output-on-failure` → 14/14
- [ ] `grep -c "Canvas" qml/components/FocusRing.qml` → **0**
- [ ] 四个对外属性（`progress`/`ringColor`/`showPreview`/`dimmed`）与 `strokeWidth` 签名未变
- [ ] `grep -n "Behavior on sweepAngle" qml/components/FocusRing.qml` → **无输出**
- [ ] 四个状态的改动前后视觉对比图已生成
- [ ] Step 4 的数字或"未能量化"声明已写进报告
- [ ] `plans/README.md` 中 030 的状态行已更新

## STOP conditions

- Step 1 读不懂现有绘制代码 —— 停下报告，不要猜着重写。
- 光晕的两种替代方案视觉都明显劣化 —— 停下报告并附对比图。
- 你发现要改 `FocusRing` 的对外属性才能用 `Shape` 实现 —— 停下报告。
  那意味着调用方 `FocusView` 也要改，超出本计划范围。
- `tst_focus_view.qml` 变红且原因不明。

## Maintenance notes

- 改完之后，**全项目不应再有用于动画内容的 `Canvas`**。
  `Canvas` 只适合一次性静态绘制；值得在 `AGENTS.md` 的 Qt/QML 规则里补一句。
- `GoalProgressRing` 和 `FocusRing` 改完后会有相当程度的结构重复（都是"轨道 + 进度弧"）。
  **本计划刻意不合并它们**：两者的尺寸、线宽、状态语义（预览/暂停）差异不小，
  过早抽象会得到一个参数比代码还多的组件。等第三个环出现时再谈合并。
- 审查这个 PR 时该重点看：对外属性是否逐字未变，以及 `sweepAngle` 有没有被人"顺手"
  加上动画——那正是 `GoalProgressRing` 踩过的坑。
