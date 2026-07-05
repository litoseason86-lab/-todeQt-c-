# 番茄待机页渐进披露重设计 设计文档

日期：2026-07-05
状态：方案 A（胶囊渐进披露）已选定，视觉稿 `docs/superpowers/mockups/pomoidle-redesign.html`

## 背景

八项 UX 改进落地后实机审视 pomoIdle 态，发现配置区反客为主：预设两行 + SpinBox 行 + 规则行 + 按钮垂直堆 5 层，环被挤到上方留白。时长已有记忆，日常路径是"瞄一眼 → 开始"，配置不该常驻中央。另有四个连带问题：自定义值命中预设时出现重复 chip（如两个"60 分"）、信息三重冗余、原生灰白 SpinBox 撞主题、虚线预览环碎成米粒。

## 设计原则

**配置退场，行动登台**：收起态只剩 环 + 时长摘要胶囊 + 开始按钮；点胶囊才展开配置面板（渐进披露）。

## 收起态（默认，每次进入 pomoIdle 重置为收起）

自上而下：模式切换（不变）→ 任务标题/阶段（不变）→ 环（252px）→ **时长胶囊** → 开始按钮。

- **环预览改造**：删掉虚线米粒；画极淡实心轨道（`borderSubtle`，同进行态轨道）+ 顶部一小段强调弧（从 -90° 起约 15°，`accent` 色、45% 不透明度、圆头）——暗示"进度从这里开始画"。环心：大号时间 + 小字 caption（有任务："准备开始"；无任务："等待任务"）。
- **时长胶囊**（objectName `durationPill`）：圆角胶囊按钮，文字 `专注 X 分 · 休息 Y 分 ▾`，点击切换展开态。环下原"专注 X 分 · 休息 Y 分"caption 删除（消灭冗余）。
- **无任务指路**：`canStartPomodoro()` 为假时，开始按钮下方加一行微文案（objectName `noTaskHint`）："到今日任务里点「开始专注」即可带任务进入"（`inkMuted`、fontXs）。
- 规则说明行（⑥）从常驻移入展开面板下方——它在调时长时才相关。

## 展开态（`panelExpanded === true`）

- 环缩小到 190px 让位（`implicitWidth/Height` 加 150ms `Behavior`），胶囊高亮（`accentSoft` 底、`accentStrong` 边框、箭头转 ▴）。
- 面板（objectName `durationPanel`，`surfaceRaised` 圆角卡片）两行：
  - 专注行：chips `25 / 45 / 60`（裸数字）+ **暖纸步进器**（`− 值 +`）
  - 休息行：chips `5 / 10` + 步进器
- **步进器取代 SpinBox 与"自定义"chip**：
  - 结构：`−` 按钮、值域、`+` 按钮（objectName：`workStepperValue`/`workStepperMinus`/`workStepperPlus`，break 同形）。
  - 每次 ±1 分钟（长按不做，YAGNI）；范围仍为专注 5–180、休息 1–60，越界即禁用对应按钮。
  - 值 ≡ `selectedWorkMinutes`/`selectedBreakMinutes` 单一数据源；chips 的 `checked` 纯粹按值匹配（`selectedWorkMinutes === 25` 等）。步进器改出非预设值 → chips 全灭，**步进器本身就是"自定义"**；改回预设值 → 对应 chip 自动点亮。彻底消灭重复 chip 与 `workCustomSelected` 状态。
- 规则说明行（`ruleHintText`）显示在面板下方，仅展开态可见。
- 再点胶囊或成功启动专注 → 收起；离开 pomoIdle 态 → 收起。

## 其他连带

- 铃铛开关缩小淡化（透明底、hover 才显边框），位置不变。
- `workCustomSelected`/`breakCustomSelected` 属性与"自定义"chip、SpinBox 全部移除；持久化恢复逻辑简化为"读回值即可"（chips 按值自动匹配，不命中就都不亮）。

## 影响面

- 仅 `qml/views/FocusView.qml`（pomoIdle 相关部分）与 `tests/qml/tst_focus_view.qml`。
- 需要重写/替换的既有测试：`test_customChipAndSpinBoxBounds`、`test_restoreCustomDurationSelectsCustomChip`（改为步进器/胶囊断言）；`test_selectMinutesAcceptsRangeAndRejectsOutOfBounds` 不变；`test_presetButtonsUseWarmSelectedColor` 保留（chips 仍在，文字改裸数字）；`test_pomoIdleShowsRuleHint` 增加"仅展开态"前置。
- C++ 零改动；无数据迁移。

## 测试要点

- 胶囊文字随 `selectedWorkMinutes/selectedBreakMinutes` 变化。
- 点胶囊切换 `panelExpanded`；启动专注后 `panelExpanded` 复位 false。
- 步进器 ± 越界禁用（5/180、1/60 边界）；步进到 90 → chips 全灭；步进回 45 → chip 45 亮。
- 恢复：settings 90/10 → 胶囊显示"专注 90 分 · 休息 10 分"，无 chip 亮。
- 无任务 → `noTaskHint` 文本存在；有任务 → 文本为空或不存在（断言驱动属性，不断言 visible===true）。
