# 双模式专注：自由 + 番茄 · 设计

- 日期：2026-06-26
- 范围：专注计时 —— 在保留现有自由正计时的基础上，新增真正的番茄计时（倒计时 + 专注/休息循环）

## 背景与目标

App 名为「番茄Todo」，但当前 `FocusTimer` 只是**正计时秒表**（每秒 `++elapsedSeconds`），没有目标时长、倒计时、到点提醒、休息循环——违背番茄工作法「设定即忘、被动提醒」的核心。

**目标**：新增番茄模式（专注倒计时 → 到点提醒 → 休息倒计时 → 提醒 → 回到专注），同时**完整保留**现有自由正计时模式，用户在专注页切换。

## 关键决策（已与用户确认）

- **双模式**：自由专注（现状不变）+ 番茄（新增），FocusView 顶部切换。
- **到点手动转阶段**：倒计时到 0 → 提醒并停下 → 用户点「开始休息 / 开始专注」进入下一阶段（不自动空转，避免污染统计）。
- **固定预设时长**：专注 25 / 45 / 60 分，休息 5 / 10 分；进入番茄模式时选择。
- **提醒方式 = 仅视觉 + 窗口置前，无声音**（不引入 Qt6::Multimedia 等新依赖）。
- **不改数据库**：番茄的专注段照写 `focus_sessions`；休息段不写。

## 架构

扩展现有 `FocusTimer`（它已拥有 QTimer、会话存库、任务关联，是最自然的归宿），加「模式 + 阶段 + 目标时长」状态机。不新增服务、不改表结构。

### FocusTimer 接口新增（自由模式 API 全部保留，向后兼容）

新增属性（均 `Q_PROPERTY` + 对应 NOTIFY）：
- `int mode` —— 0=自由、1=番茄
- `int phase` —— 0=无、1=专注、2=休息
- `int targetSeconds` —— 当前阶段目标秒数（自由模式为 0）
- `int remainingSeconds` —— `max(0, targetSeconds - elapsedSeconds)`（番茄模式用于倒计时显示）

新增方法：
- `Q_INVOKABLE bool startPomodoroWork(int taskId, const QString& title, int workSeconds)` —— 开始一个专注段（番茄模式、phase=专注、target=workSeconds），建立 `focus_sessions` 行（与现有 `startFocus` 同路径）。
- `Q_INVOKABLE bool startBreak(int breakSeconds)` —— 开始休息段（番茄模式、phase=休息、target=breakSeconds、无任务），**不建立** `focus_sessions` 行。

复用现有方法：`pauseFocus / resumeFocus / stopFocus`（停止时按当前 phase 区分是否存库，见下）。现有 `startFocus(taskId, title)` 保留为自由模式入口，行为不变。

新增信号：
- `phaseCompleted(int phase)` —— 番茄模式下 `remainingSeconds` 归零时发出。QML 据此切到「完成」视觉态、置前窗口、弹出下一步按钮。

### tick 行为
- 自由模式：`++elapsedSeconds; emit tick();`（不变）。
- 番茄模式：`++elapsedSeconds; emit tick();` 同时若 `elapsedSeconds >= targetSeconds` → 停表、结算当前阶段（见下）、`emit phaseCompleted(phase)`。

## 状态机与存库（关键正确性）

- **专注段结束**（倒计时到 0，或用户提前「停止」）：把已用时长 `elapsedSeconds` 按现有规则结算——
  - `< 3 分钟`（`kMinimumValidDurationSeconds`）→ 丢弃，不写会话（沿用现有逻辑）。
  - 否则写入 `focus_sessions`（`saveFocusSession`）。
  - `>= 5 分钟`（`kAutoCompleteTaskDurationSeconds`）→ 自动完成关联任务（25/45/60 番茄必然达标）。
- **休息段结束**（到 0 或「停止 / 跳过休息」）：**不写任何会话**，直接复位，不触发任务完成。
- 自由模式 stop 的行为完全不变。
- 因此 `stopFocus` 内按 `phase` 分支：phase=休息 → 直接复位丢弃；其余 → 走现有结算路径。

## FocusView UI（专注页）

- **顶部模式切换**：分段控件「自由专注 | 番茄」。切到自由＝现状秒表，完全不变。
- **番茄 · 开始前**：显示任务名 + 预设选择（专注 25/45/60、休息 5/10，默认 25/5）+「开始专注」。
- **番茄 · 专注中**：大号等宽倒计时（Menlo），阶段标签「专注中」，「暂停 / 停止」。
- **番茄 · 专注到 0**：高亮「专注完成」横幅 + 倒计时显示 00:00 + 窗口置前；按钮「开始休息 / 结束」。
- **番茄 · 休息中**：倒计时 + 「休息中」标签 + 「跳过休息 / 停止」。
- **番茄 · 休息到 0**：高亮「休息结束」+ 窗口置前；按钮「开始专注 / 结束」。
- 文案主动语气；阶段用颜色 + 文字双标（专注=accent、休息=偏冷的图表蓝），不只靠颜色。

### 窗口置前
`phaseCompleted` 触发时，由 `main.qml` 的 `ApplicationWindow` 调 `raise()` + `requestActivate()` 把窗口拉到前台（QML 内建，无新依赖）。

## 边界与错误处理
- 番茄进行中切回「自由专注」标签：先按当前阶段规则结束当前番茄（专注段结算/休息段丢弃），再切模式。
- 暂停时不计 tick；恢复继续。
- DB 未开/写库失败：沿用 FocusTimer 现有容错（保留计时不丢、`qWarning`）。

## QML 实现约束（按 qt-qml 规范）
- **模式切换 + 预设档位用 Qt Quick Controls**：分段切换用 `TabBar`/`TabButton` 或 `ButtonGroup`+互斥 `Button`；预设档位用 `ButtonGroup`+`Button`（单选）。不用裸 `MouseArea` 自造选择/焦点/状态。
- **FocusView 六形态用 QML `states`/`State` 建模**（自由 / 番茄待机 / 专注中 / 专注完成 / 休息中 / 休息完成），按 `mode`+`phase`+完成标志切 state，避免一堆 `visible:` 绑定堆叠。
- **倒计时显示声明式绑定 `focusTimer.remainingSeconds`**（C++ NOTIFY 属性、单一数据源）；1Hz 的 MM:SS 格式化只用于该显示，不拿它驱动逐帧动画。
- **到点高亮/强调动画用 `Animator` 类**（`OpacityAnimator`/`ScaleAnimator`，跑渲染线程），不用 `NumberAnimation`。
- **窗口置前**：`main.qml` 用单个 `Connections { target: focusTimer; function onPhaseCompleted(phase){ raise(); requestActivate() } }`。
- **文案随项目惯例用裸中文字符串**（项目无 i18n/`.ts`），新代码不加 `qsTr()`，保持与既有 QML 一致；全局国际化另立项。
- **沿用项目 plain `import QtQuick.Controls`**（即便自定义 `background`/`contentItem`），与既有 QML 写法一致。
- **可访问性（`Accessible`/键盘焦点框）本期不做**，与现有界面保持一致；记为以后全局补齐。

## 测试
- **C++（ServiceTests，已 `#define private public` 可测内部）**：
  - 番茄专注段到达 target 自动结算并写会话、达标自动完成任务
  - 休息段结束不写任何 `focus_sessions`
  - 番茄专注段提前停在 <3 分钟被丢弃
  - `phaseCompleted` 在 `remainingSeconds` 归零时发出（用 QSignalSpy + 直接推进内部计数）
  - 自由模式 `startFocus/stopFocus` 回归不变
- **QML**：
  - MainWindow 注入的假 `focusTimer` 补齐新属性/方法（`mode/phase/targetSeconds/remainingSeconds/startPomodoroWork/startBreak/phaseCompleted`），保证既有用例不回归
  - 专注页模式切换显示对应控件、番茄倒计时显示格式

## 未来计划（v1 不做，下一迭代再加）
- **自定义任意时长**（用户已确认：保留为下次添加）——本期先用固定预设。
- 「今日完成 N 个番茄」计数。
- 每 4 个番茄一次长休息。

## 实现文件清单
- 服务：`src/services/FocusTimer.{h,cpp}`（加模式/阶段/目标状态机与新方法、信号）
- UI：`qml/views/FocusView.qml`（模式切换、预设、倒计时、阶段提醒态）、`qml/main.qml`（`phaseCompleted` → 窗口置前）
- 测试：`tests/ServiceTests.cpp`（扩展）、`tests/qml/tst_mainwindow_ui_optimization.qml`（假 focusTimer 补字段）
