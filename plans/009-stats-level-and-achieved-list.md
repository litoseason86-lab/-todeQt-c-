# Plan 009: 统计页等级与已达成列表（奖励机制·阶段 D 长期层）

> **Executor instructions**: 按步骤执行，逐步验证；触发 STOP conditions 立即停下报告。
> 完成后更新 `plans/README.md` 状态行。
>
> **Drift check（先跑这个）**：
> `grep -n "achievedAt" src/models/LongGoal.cpp` 必须命中；
> `grep -n "WeeklyReviewCard" qml/views/StatisticsView.qml` 必须命中（用于定位插入点参照）。

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: plans/006（消费 goalService 与其页面跳转；不依赖 007/008）
- **Category**: feature（奖励机制 阶段 D）
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **设计依据**: `docs/奖励机制实施方案.md` §一.4/§三-阶段D。维护者已拍板：**纳入本轮**。

## Why this matters

四层反馈金字塔的最顶层：把「完成过的目标」变成可回味的记忆锚点，而不只是消失的列表项。
TRACK 100 用成就树承载这一层——树已被审美红线否决（忌卡通/贴纸感），
保留的是两个真正有效的内核：**等级**（阈值 0/3/8/20/40，前密后疏，新手 3 个目标就升级）
和**可回味性**（每个已达成目标带完成日期，点开能回看）。
落点：统计页底部一个素卡片。

## Current state

### 数据（就绪，不改 C++）

`goalService.getGoals()` 每项含 `achieved`(bool)、`achievedAt`(datetime，可能无效)、
`title`、`categoryColor`。已达成列表 = `filter(g => g.achieved)`，按 `achievedAt` 倒序。

### 等级（纯前端派生，无新存储）

```js
// 阈值抄 TRACK 100（0/3/8/20/40），名称按本项目暖色语汇重写（可再改，先用这套）：
const LEVELS = [
    { lv: 1, min: 0,  name: "起步" },
    { lv: 2, min: 3,  name: "上路" },
    { lv: 3, min: 8,  name: "成习" },
    { lv: 4, min: 20, name: "丰收" },
    { lv: 5, min: 40, name: "燎原" }
]
function levelOf(n) { let c = LEVELS[0]; for (const x of LEVELS) if (n >= x.min) c = x; return c }
```

放 `qml/views/StatisticsFormat.js`（该页专属派生逻辑的既有归宿）。

### 插入点

`qml/views/StatisticsView.qml` 内容列的**底部**（`WeeklyReviewCard` 之后）。
该页有分段控件周/月切换——已达成卡片**不随周期切换变化**（长期层是累积的），
放在周期区块之外的页尾。头部版式红线：分段控件位置一根手指都不要碰。

### 卡片版式（素版）

```
┌ 已达成目标 ────────────────── LV.2 上路 ┐
│  ● 论文精读            7月14日          │
│  ● 日语五十音          6月30日          │
│  （空态：完成第一个长期目标后，这里会留下记录）│
└──────────────────────────────────────┘
```

`●` 用 `categoryColor` 色点；行点击 → 跳目标页（发信号，MainWindow 接去 goals 视图）。
等级徽标：`Theme.accentFill` 底 + `Theme.accentFillInk` 字，不放图标不放进度条
（升级的庆祝感交给数字变化本身；装饰先做最素版）。
折叠：≤5 条直接全显；>5 条默认显 5 + 「展开全部 N 项」。

## Commands you will need

同 plan 006（构建目录 `/tmp/pt-009`）。

## Scope

**In scope**：
- `qml/components/AchievedGoalsCard.qml`（新建）
- `qml/views/StatisticsView.qml`（页尾插卡 + 数据获取 + 跳转信号）
- `qml/views/StatisticsFormat.js`（levelOf）
- `qml/MainWindow.qml`（接跳转信号 → goals 视图；一行级改动）
- `resources/qml.qrc`（注册）
- `tests/qml/tst_goals_view.qml` 或统计页既有测试文件（追加用例）

**Out of scope**：
- 任何 C++。
- 统计页既有区块（周/月卡、图表、WeeklyReviewCard）—— 一行不动。
- 等级升级的弹窗/动效 —— 长期层是静水，不做即时庆祝（升级瞬间恰好也是达成弹窗
  出现的时刻，008 已覆盖那一下的情绪）。

## Git workflow

分支 `advisor/009-stats-level`；提交建议：`统计页新增已达成目标与等级卡片`。不 push。

## Steps

### Step 1: `levelOf` 入 StatisticsFormat.js + AchievedGoalsCard.qml

组件属性：`achievedGoals`（数组）、信号 `goalClicked(int goalId)`。
按版式实现；空态文案「完成第一个长期目标后，这里会留下记录」。

### Step 2: StatisticsView 接入

页尾插卡；`refresh()` 时（该页既有刷新时机）同步
`achievedGoals = goalService.getGoals().filter(...)`，按 achievedAt 倒序。
`Connections { target: goalService; onGoalsChanged: ... }`（enabled 绑 pageActive）。
`goalClicked` 上抛，MainWindow 接到后切 goals 视图。

### Step 3: 用例

1. 0 项 → 等级文案 `LV.1 起步`，空态文字非空。
2. 注入 3 项已达成 mock → `LV.2 上路`；列表首项是 achievedAt 最新的那条。
3. 注入 8 项 → `LV.3 成习`；默认渲染行数 ===5，展开后 ===8。
4. `levelOf` 纯函数直接断言 40 → lv5、39 → lv4（边界）。

**Verify**: QML 套件通过。

### Step 4: 视觉稿 + 全量

离屏渲染统计页尾卡片（3 项与 0 项各一张）存 `docs/设计稿/长期目标/实现-统计*.png`；
全量 `ctest` 12 套件通过。

## Done criteria

- [ ] 全量 12 套件通过
- [ ] `grep -n "levelOf" qml/views/StatisticsFormat.js` 命中
- [ ] `git diff qml/views/StatisticsView.qml` 中既有区块无改动（只有页尾新增）
- [ ] 等级边界用例（39/40）通过
- [ ] 视觉稿生成；`plans/README.md` 更新

## STOP conditions

- Drift check 失败。
- 统计页的既有测试因插卡而失败——先报告（可能是页面高度/滚动断言被影响）。
- 发现需要 C++ 改动。

## Maintenance notes

- 等级名称是占位定稿（起步/上路/成习/丰收/燎原），维护者可随时改字符串，阈值别动。
- 若未来目标数大（>40），「展开全部」列表考虑上限或分页——当前量级无需。
- 已达成列表的行点击目前只跳 goals 列表页；007 落地后可升级为直接开详情
  （`openGoal(goalId)`），一行改动，记在这里不强求本计划做。
