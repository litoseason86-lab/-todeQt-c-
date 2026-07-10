# 专注页全屏沉浸模式 — 设计文档

日期：2026-07-10
分支：main（实现阶段另起分支/工作树）
状态：设计已批准（含可视化伴随 UI 定稿），待写实现计划

## 背景与目标

专注页（[qml/views/FocusView.qml](../../../qml/views/FocusView.qml)）目前始终嵌在主窗口布局里：左侧 208px 侧栏 + 顶部窗口镶边都留在视野内，专注时干扰仍在。本次为专注页新增**全屏沉浸模式**：一键进入 macOS 原生全屏，屏幕上只留计时与任务名，操作按钮悬停浮现，营造「只剩这一件事」的沉浸感。

**不改** FocusView 的六态状态机、计时服务（FocusTimer）、会话落库逻辑。沉浸层是现有状态的**只读投影 + 动作转发**，不新增业务状态。

## 需求定稿（澄清与可视化伴随结论）

用户依次确定：

1. 窗口行为：**系统级全屏**（等同绿灯按钮，菜单栏/Dock 随系统收起）。
2. 沉浸内容：**极简 + 悬停显控**——平时只有计时（环/大数字）与任务名；鼠标移动浮现控制，3 秒无操作淡出。
3. 进入方式：**手动按钮**——专注页右上角 ⛶，与铃铛并排。
4. 实现方案：**方案 B · 独立沉浸层组件**（不在 FocusView 内叠沉浸开关，避免六态×沉浸组合爆炸）。
5. UI 布局经浏览器 mockup 确认（入口条／静止态／悬停态／完成态／自由模式五屏，见附录）。

## 架构总览

```text
main.qml (ApplicationWindow)
 ├─ 监听 focusImmersiveActive ⇄ Window.visibility 双向同步
 └─ MainWindow
     ├─ BackgroundWallpaper                    （沉浸时仍可见，材质延续）
     ├─ RowLayout [Sidebar | StackLayout]      （沉浸时 visible: false）
     ├─ FocusImmersiveOverlay                  （新增；沉浸时盖满窗口）
     └─ Toast                                  （声明在沉浸层之后，保持最顶）
```

- **唯一事实源**：`MainWindow.focusImmersiveActive: bool`。进入/退出全屏、层显隐、窗口 visibility 全部由它派生。
- 沉浸层直接坐在壁纸上（RowLayout 隐藏后无侧栏透底），底板沿用 `Theme.glassCard`，与专注页材质完全一致。

## 组件一：FocusView 入口按钮（唯一改动点 + 一处小提炼）

1. **⛶ 按钮**：右上角与现有 `soundToggleButton` 并排（其左侧），同尺寸同风格。
   - 显示条件：**计时进行中（含暂停）**——
     `state === "pomoWork" || state === "pomoBreak" || (state === "free" && timerBool("hasActiveSession"))`。
     待机/完成/未开始状态不显示（那些状态要么需要配置面板，要么即将离开专注页）。
   - 点击发出新信号 `immersiveRequested()`，自身不改任何状态。
2. **提炼 `endFreeFocus()`**：现有 `freeStopButton.onClicked` 里的内联结束逻辑（stopFocus → 清缓存 → focusEnded / 失败置 errorText）提炼为函数，原按钮改为调用它。沉浸层的自由模式「结束专注」复用同一函数，不复制逻辑。

## 组件二：FocusImmersiveOverlay（新增，qml/components/）

### 契约

```text
属性:  focusViewRef (必传)   — 读 state、调 togglePause/endPomodoro/startBreak/startPomodoro/endFreeFocus
       timerRef、settingsRef — 读计时数据与声音/动效/字体偏好
       active: bool          — 由 MainWindow 绑定 focusImmersiveActive
信号:  exitRequested()       — ✕ 按钮 / Esc 触发；由 MainWindow 归零事实源
```

沉浸层**不直接改** `focusImmersiveActive`，也不直接碰窗口——保持单向数据流：动作 → 信号 → MainWindow → 属性 → 绑定回层。

### 画面（按 focusViewRef.state 投影）

| 状态 | 中央内容 | 底部控制（浮现/常驻） |
| --- | --- | --- |
| `pomoWork` | FocusRing 放大约 340px，环内时间约 72px + 「剩余 · 共 N 分」，环下任务名 + 「专注中 / ⏸ 已暂停」 | 暂停/继续 + 结束（浮现） |
| `pomoBreak` | 同上，休息配色（`focusBreakAccent`） | 暂停/继续 + 跳过休息（浮现） |
| `free`（有会话） | 无环，超大 HH:MM:SS + 任务名 + 「专注进行中 / 已暂停」 | 暂停/继续 + 结束专注（浮现） |
| `workDone` | 「专注完成」横幅 + 绿色满环 + 任务名 | 开始休息 + 结束（**常驻**） |
| `breakDone` | 「休息结束」横幅 + 绿色满环 + 任务名 | 开始专注 + 结束（**常驻**） |

- 时间/文案复用 focusViewRef 已有函数（`primaryTimeText()`、`pomodoroStageText()` 等）通过引用调用，不复制格式化逻辑。（可行性依据：现有 UI 的每秒 tick 正是经这些函数建立绑定依赖；FocusView 隐藏后绑定与 Connections 照常求值。）
- FocusRing 绑定沿用现有函数：`progress: ringProgressFraction()`、`ringColor: ringColorForState()`、`dimmed: ringDimmed()`；`showPreview` 恒 false（沉浸中无待机态）。
- 按钮 enabled 与 FocusView 现有按钮一一对应，尤其 breakDone 的「开始专注」沿用 `canStartPomodoro()`——休息后任务上下文可能已丢，不能常亮。
- 沉浸层渲染 `focusViewRef.errorText`（时间下方小字，`Theme.danger` 色）：结束/开始休息等操作失败时不能静默——原页面的错误提示此刻被隐藏，用户看不见。
- 字体沿用 `Theme.fontFamilyClock` 与 `settings.slimClockFont` 细体开关；番茄环内时间的冒号淡化复用 `ringTimeMarkup()`（自由模式 HH:MM:SS 与现状一致，纯文本不淡化）。
- 右上角浮现组：✕ 退出全屏。（实现阶段定稿：原设计的 🔔 声音快捷开关移除——普通专注页已有同款开关，沉浸层保持极简，见提交 81ca7c8。）
- 防御：沉浸中 state 若意外落入 `pomoIdle`/`free` 无会话等「无可投影」状态，发 `exitRequested()` 自动退出，不呈现空画面。

### 悬停显控

- 全屏铺一个 `MouseArea { hoverEnabled: true; acceptedButtons: Qt.NoButton }`（点击穿透到按钮）；`onPositionChanged` → `controlsRevealed = true` 并重启 3 秒隐藏 Timer。
- `readonly property bool controlsPinned: 已暂停 || workDone || breakDone`——暂停和完成态控制**常驻**不淡出。
- 控制组 `opacity: (controlsRevealed || controlsPinned) ? 1 : 0`，约 180ms 淡入淡出；`settings.reduceMotion` 时禁用 Behavior 直接显隐。
- 光标随控制组隐藏：控制隐藏时 `cursorShape: Qt.BlankCursor`。

### 退出路径（全部收敛到同一事实源）

1. `Shortcut { sequence: "Esc"; enabled: active }` → `exitRequested()`；
2. ✕ 按钮 → `exitRequested()`；
3. 专注整体结束（`focusEnded`）→ MainWindow 先归零再切今日页（见组件三）；
4. 系统侧退出全屏（绿灯按钮/手势）→ main.qml 检测归零（见组件四）。

阶段完成（workDone/breakDone）**不退出**：用户点「开始休息/开始专注」留在沉浸内衔接下一段。

## 组件三：MainWindow 接线

- `property bool focusImmersiveActive: false`。
- `onImmersiveRequested`（来自 focusView）→ 置 true；`onExitRequested`（来自沉浸层）→ 置 false。
- 现有 `focusView.onFocusEnded` 改为：`focusImmersiveActive = false; switchToView("today")`——避免今日页卡在无侧栏全屏。
- RowLayout（侧栏+内容）`visible: !focusImmersiveActive`。
- 声明顺序：沉浸层放在 RowLayout 之后、Toast 之前（Toast 维持最顶；「不足 3 分钟未计入」的 toast 在退出沉浸后仍可见）。

## 组件四：main.qml 窗口联动（双向同步）

```text
property int preImmersiveVisibility: Window.Windowed
property bool enteringFullScreen: false        // 进入过渡护栏

进入（active → true）: 记录当前 visibility → enteringFullScreen = true → 置 Window.FullScreen
退出（active → false）: 若记录值为 FullScreen（用户原本就在原生全屏）→ 保持全屏只收覆盖层；
                        否则还原记录值（Windowed/Maximized）
onVisibilityChanged:    若 visibility === FullScreen → enteringFullScreen = false；
                        否则若 !enteringFullScreen 且 active 仍为 true → 归零 active（系统侧退出）
```

**进入过渡护栏**：macOS 全屏过渡是异步的，从 Maximized 进入时不保证不发中间 visibility 事件；`enteringFullScreen` 在首次观察到 FullScreen 之前屏蔽「系统侧退出」判定，防止进入动画途中被误判而自我取消。护栏不拦手动退出——Esc/✕ 走 active 归零路径，不依赖该判定。

**无环论证**：进入路径 visibility 变为 FullScreen 只清护栏，不满足归零条件；我方退出路径先归零 active 再改 visibility，handler 里 active 已 false；系统侧退出路径 visibility 先变，归零 active 后的还原写入是同值赋值，不再触发变化。

## 边界与错误处理

- 入口按钮只在计时进行中出现 → timer 为空/无会话时沉浸层不可达；层内所有 timer 读取仍沿用 FocusView 的空值防御风格。
- 会话被判无效丢弃（<3 分钟）走 `focusEnded` 路径 → 自动退出，无滞留。
- 阶段完成的置前提醒（raise/chime，main.qml 现有逻辑）在全屏下无害：窗口本就在最前，提示音照常。
- 窗口全屏状态不持久化（应用现在也不记窗口几何，超出范围）。
- 多显示器：跟随 macOS 原生全屏默认行为，不做特殊处理。

## 测试策略（tests/qml/tst_focus_immersive.qml）

**铁律：不断言 `item.visible === true`**（本项目 offscreen 测试下 effective visible 不可靠），全部断言底层状态属性/文案/信号。

方案 B 的隔离红利：沉浸层可用 mock 的 focusView 替身（QtObject：state 字符串 + 记录调用的函数）+ mock timer/settings 独立实例化测试。

覆盖点：

1. 状态投影：mock state 依次为五个可投影状态，断言阶段文案、按钮文案、常驻标志。
2. `controlsPinned`：暂停/完成态为 true，运行态为 false。
3. 隐藏计时：`controlsRevealed` 置位后强制触发 Timer，断言归 false；`reduceMotion` 分支不挂动画。
4. 动作转发：调用层内按钮 handler，断言 mock 收到 `togglePause`/`endPomodoro`/`startBreak`/`startPomodoro`/`endFreeFocus`。
5. 退出信号：Esc handler 与 ✕ handler 均发 `exitRequested`；无可投影状态自动发 `exitRequested`。
6. FocusView：⛶ 显示条件表达式（以 readonly bool 属性暴露供断言）、`immersiveRequested` 信号、`endFreeFocus()` 提炼后原按钮行为不变。
7. main.qml 联动逻辑若难以在 offscreen 驱动真实 visibility，把「进入/退出/系统退出/过渡护栏」的决策提炼为纯函数测试（含：`enteringFullScreen` 屏蔽期内的中间 visibility 事件不触发误退），实际窗口行为留给手动验证清单。

新文件注册进 CMakeLists（qml 模块 + 测试目标）。

## 改动面清单

| 文件 | 改动 |
| --- | --- |
| `qml/components/FocusImmersiveOverlay.qml` | **新增**（约 250-300 行） |
| `qml/views/FocusView.qml` | +⛶ 按钮、+`immersiveRequested()` 信号、提炼 `endFreeFocus()` |
| `qml/MainWindow.qml` | +属性、+层声明、RowLayout visible 绑定、`onFocusEnded` 补一行 |
| `qml/main.qml` | +visibility 双向同步 |
| `tests/qml/tst_focus_immersive.qml` | **新增**（qmltestrunner 按 `-input tests/qml` 目录自动发现，无需注册） |
| `resources/qml.qrc` | 注册 `FocusImmersiveOverlay.qml`（QML 经 qrc 打包，非 CMake 直列） |

## 明确不做（YAGNI）

- 不做「开始专注自动全屏」设置项（后续想要再加，入口逻辑已留好单点）。
- 不做应用内沉浸档位（仅系统级全屏一档）。
- 不做进入快捷键（仅按钮进入；Esc 退出）。
- 不改 FocusView 状态机、不动壁纸/玻璃体系、不做屏幕常亮控制。

## 附录：UI 定稿 mockup

可视化伴随会话产物（已确认）：`.superpowers/brainstorm/86852-1783685713/content/immersive-ui.html`
— 含入口条、沉浸静止态、悬停态、完成态、自由模式五屏，配色取自 Theme 真实令牌。
（本地产物，该目录在 .gitignore 内不入库；如需长期留档可另行拷贝。）
