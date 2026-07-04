# 专注计时 UX 重设计（8 项改进）设计文档

日期：2026-07-05
状态：已与用户逐段确认

## 背景与目标

以「每天打开这个 App 的考研用户」视角对专注计时链路（选任务 → 启动 → 计时 → 收尾）做了审计，找出 8 个会反复消耗用户时间的问题。本设计按优先级覆盖全部 8 项：

| # | 问题 | 方向 |
|---|---|---|
| ① | 任务列表点「开始专注」永远进自由模式，番茄要再切一次 | 记住上次模式，一键直达 |
| ② | 专注中切走页面后无任何持续状态提示 | 侧栏实时时间 + 窗口标题 |
| ③ | 不足 3 分钟的会话被静默丢弃 | 全局轻提示条告知 |
| ④ | 冲突时报错含糊（"请重试"） | 提示 + 自动跳转专注页 |
| ⑤ | 番茄预设时长不记忆 | QSettings 持久化 |
| ⑥ | 5 分钟自动完成任务的规则不可见 | 待机态一行说明文字 |
| ⑦ | 阶段结束只有窗口置前，无声音 | 可关闭的提示音 |
| ⑧ | 时长只有固定预设 | 「自定义」chip + SpinBox |

## 结构性决策：偏好存储（方案 A，已确认）

①⑤⑦ 都需要持久化用户偏好，项目此前没有任何设置存储机制。

**新建 `src/services/AppSettings`**（`QSettings` 薄封装），注册为 QML 上下文属性（与 `focusTimer`、`taskManager` 同模式）。

存储键（组 `focus/`）：

| 键 | 类型 | 默认值 | 含义 |
|---|---|---|---|
| `focus/lastMode` | int | 0 | 上次启动模式：0 自由 / 1 番茄 |
| `focus/workMinutes` | int | 25 | 上次专注时长（分钟） |
| `focus/breakMinutes` | int | 5 | 上次休息时长（分钟） |
| `focus/soundEnabled` | bool | true | 阶段完成提示音开关 |

- 属性带 NOTIFY 信号，QML 可直接绑定。
- C++ 测试注入独立临时配置文件（构造参数传路径），避免污染真实配置。
- QML 测试沿用现有做法：用 mock 对象替代真实服务。

否决的备选：QML `Settings` 类型（测试会读写真实配置文件，违反本项目测试隔离纪律）；SQLite 存偏好（4 个键不值得建表，且混淆业务数据与偏好）。

## ①⑤ 启动模式与时长记忆

**启动流程集中化**：今日/本周/月历三个视图的「开始专注」不再各自调 `focusTimer.startFocus`，统一上抛 `startFocus(taskId, title)` 信号，由 MainWindow 集中决策：

- `lastMode == 0`（自由）→ 行为与现状完全一致：`focusTimer.startFocus(...)` 立即正计时并切到专注页。
- `lastMode == 1`（番茄）→ **不启动计时器**，调用 FocusView 新增的 `enterPomodoroWithTask(taskId, title)`：切到专注页番茄待机态，任务已预载（`pomoTaskId`/`pomoTaskTitle`），时长为记住的值；用户按「开始专注」才真正启动。不偷跑，留出调整时长的机会。

**回写时机**：

- FocusView 成功启动自由专注 → `lastMode = 0`；成功启动番茄专注 → `lastMode = 1`。（以"实际启动"为准，只切标签页不回写。）
- `selectWorkMinutes`/`selectBreakMinutes`（含自定义值）→ 即时回写 `workMinutes`/`breakMinutes`。
- FocusView 初始化时从 AppSettings 读回 `selectedWorkMinutes`/`selectedBreakMinutes`。

## ② 全局运行状态

**侧栏**（`qml/components/Sidebar.qml`）：「专注计时」条目右侧新增状态区，直接绑定全局 `focusTimer`（已是上下文属性），随 `tick` 1Hz 刷新：

- 番茄模式运行中：脉动圆点 + 倒计时 `15:32`
- 自由模式运行中：脉动圆点 + 正计时 `00:32:14`
- 暂停：`⏸` + 冻结时间
- 空闲：状态区不显示

点击行为不变（本来就跳专注页）。时间文本用 `Theme.fontSm` + `Theme.accent`，不加阴影不加动画（除圆点脉动 opacity）。

**窗口标题**（`qml/main.qml`）：`title` 改为绑定表达式：

- 运行中：`15:32 · 番茄Todo`（自由模式 `00:32:14 · 番茄Todo`）
- 暂停：`⏸ 15:32 · 番茄Todo`
- 空闲：`番茄Todo`

时间格式化函数与侧栏共用逻辑（各自实现同一规则即可，规则：番茄 mm:ss，自由 hh:mm:ss）。

## ③④ 轻提示条与冲突处理

**Toast 组件**（新建 `qml/components/Toast.qml`）：

- MainWindow 顶层实例化一个，z 最高，底部居中浮现。
- `show(text)` 函数：显示 3 秒后自动退场；进出动画用 opacity + 位移，各 ≤200ms。
- 连续调用时重置计时并替换文本（不排队堆叠）。
- 各视图通过信号上抛触发，不直接引用组件。

**丢弃提示（③）**：`FocusTimer::completeFocusSession` 丢弃短会话的分支新增信号 `sessionDiscarded(int duration)`（只加信号，不改任何流程分支）。MainWindow 监听 → `showToast("本次专注不足 3 分钟，未计入记录")`。

**冲突处理（④）**：已有活动会话时点另一任务「开始专注」→ MainWindow 判断 `focusTimer.hasActiveSession || focusTimer.phase !== 0`：不启动、`showToast("已有专注进行中")` 并切到专注页，让用户现场决定。原 inline 错误"专注启动失败，请重试"在此路径不再出现（其他失败原因仍走 inline 错误）。

## ⑥ 规则透明化

`FocusTimer` 暴露两个常量 Q_PROPERTY（CONSTANT，数据源 `FocusSessionRules.h`）：

- `minimumValidMinutes` = 3
- `autoCompleteMinutes` = 5

专注页番茄待机态预设区下方加一行小字：**"满 5 分钟自动完成任务 · 不足 3 分钟不计入记录"**（文案从上述属性拼接，避免规则改了文案不同步）。样式 `Theme.inkMuted` + `Theme.fontSm`，不抢环形主体。

## ⑦ 提示音

- CMake 增加 `Qt6::Multimedia`。
- 音源：实施时用脚本合成 ≤1 秒双音 chime（wav），打进 qrc 资源，不引外部素材。
- `main.qml` 用 `SoundEffect`，挂在现有 `onPhaseCompleted` 处：`if (appSettings.soundEnabled) chime.play()`。窗口置前逻辑保留。
- 开关：专注页右上角小图标按钮（🔔/🔕），所有状态可见，绑定 `AppSettings.soundEnabled`，默认开。

## ⑧ 自定义时长

- 专注行预设加第 4 个 chip「自定义」；休息行加第 3 个（替换现有占位 Item）。
- 选中「自定义」→ 网格下方展开一行内联 `SpinBox`：专注 5–180 分、休息 1–60 分；改值即时生效并回写 AppSettings。
- **与⑤统一**：持久化存的一直是分钟数。重启后若存的值命中预设 → 高亮对应预设 chip；否则自动选中「自定义」chip，chip 文字显示实际值（如"90 分"）。
- `selectWorkMinutes`/`selectBreakMinutes` 的白名单校验改为范围校验（专注 5–180、休息 1–60）。

## 错误处理

- AppSettings 读失败 → 返回默认值，不阻塞启动。
- SoundEffect 加载失败 → 静默降级（仅置前），不弹错误。
- `enterPomodoroWithTask` 在已有活动会话时不可达（MainWindow 先判断冲突），防御性处理：若仍被调用则走现有 `toPomodoroTab(true)` 的停止逻辑。

## 测试策略

**C++（tests/ServiceTests.cpp 或新文件）**：

- AppSettings：临时配置文件读写往返、默认值、NOTIFY 信号。
- `sessionDiscarded`：QSignalSpy 验证短会话触发、正常会话不触发。
- `minimumValidMinutes`/`autoCompleteMinutes` 常量属性值。

**QML（tests/qml/）**：

- 侧栏状态区：mock focusTimer 驱动运行/暂停/空闲三态文本（断言 text 内容，不断言 visible===true——项目已知纪律）。
- FocusView `enterPomodoroWithTask`：进入待机态、任务预载、时长来自 mock 设置。
- MainWindow 启动决策：mock AppSettings 的 lastMode 分别为 0/1，验证调了 startFocus 还是 enterPomodoroWithTask；冲突路径验证 toast 文本与视图切换。
- Toast：show 后文本正确、3 秒后退场（用短超时注入测试）。
- 自定义时长：SpinBox 边界钳制（4→5、181→180）；重启恢复逻辑（存 90 → 自定义 chip 选中且显示"90 分"）。
- 声音开关：按钮切换回写 mock 设置；phaseCompleted 时按开关决定是否调 play（mock SoundEffect 不可行则只测开关状态本身）。

## 实施拆分建议

1. **计划一**：AppSettings 服务 + ①⑤（启动直达与记忆）+ ④（冲突处理，依赖集中决策点）。
2. **计划二**：②（侧栏+标题）+ ③（Toast + sessionDiscarded）。
3. **计划三**：⑥⑦⑧（文案、声音、自定义时长）。

每个计划独立可交付、可测试；顺序即优先级。
