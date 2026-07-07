# 设置中心化 + 侧栏减负 + 减少动效 设计文档

日期：2026-07-07
状态：视觉方向经问答确认（#2 减动效+提示音进设置；#3 管理动作收进设置弹窗 + 删"三阶段"标签）

## 背景

qt-ui-design 审计（2026-07-07）指出两处 Warning：① 无 reduced-motion 通道（大量循环/位移动画，无障碍缺口）；② 侧栏 10 项 + 一个无功能的"三阶段"孤儿标签，超出 Miller ~7 舒适区。设置弹窗此前只有"背景主题"一栏，框架本就为"逐步收纳设置"预留。本设计把三件事一起做：设置弹窗升级为控制台、侧栏瘦身、引入减少动效。

已确认决策：

- **#2**：设置弹窗新增"减少动效"与"提示音"开关；番茄/休息时长仍留待机页情境设置（刻意高频就近，不搬）。
- **#3**：把"每日例行/科目管理/数据导出"从侧栏移入设置弹窗的"管理"段；删除无功能的"三阶段"标签。侧栏只留 6 视图导航 + 设置。

## 数据层（AppSettings 新属性）

新增 `reduceMotion`，完全对齐既有 `soundEnabled` 模式：

- `Q_PROPERTY(bool reduceMotion READ reduceMotion WRITE setReduceMotion NOTIFY reduceMotionChanged)`；
- QSettings 键 `appearance/reduceMotion`，默认 `false`；
- setter 同值不发信号、`sync()` 落盘（同 soundEnabled）。

`soundEnabled` 已存在，无需新增——设置弹窗的提示音开关与专注页 🔔 都绑它。

## 设置弹窗（三段式控制台）

[SettingsDialog.qml](../../../qml/components/SettingsDialog.qml) 在现有"背景主题"画廊之后、"关闭"按钮之前，插入两段：

```text
设置
  背景主题
    [6 张缩略图画廊 · 现有不动]
  偏好
    提示音            [Switch]   ← appSettingsRef.soundEnabled
    减少动效          [Switch]   ← appSettingsRef.reduceMotion
  管理
    每日例行              ›       → routineRequested()
    科目管理              ›       → categoryRequested()
    数据导出              ›       → exportRequested()
                        [关闭]
```

- **段标题**沿用现有"背景主题"那种 `fontSm/Bold/inkSoft` 小标题样式（偏好、管理）；
- **开关**：`QtQuick.Controls.Basic` 的 `Switch`，自定义 `indicator`（轨道 + 圆钮）贴合暖纸令牌（开=`Theme.accent` 轨、关=`Theme.surfaceSunken` 轨、钮=`Theme.surface`），与 app 既有自绘控件一致；`checked` 绑 `appSettingsRef.<key>`，`onToggled` 写 `appSettingsRef.<key> = checked`；缺 appSettingsRef（测试/降级）时只显示不写、不崩溃（同画廊守卫）；
- **管理行**：一行文字 + 右侧 `›`，整行可点，`MouseArea` → `root.close()` + `emit 对应信号`；
- 新增信号：`signal routineRequested`、`signal categoryRequested`、`signal exportRequested`；
- **objectName 层级**（测试入口，含自绘控件内部件以便校验令牌）：
  - 开关：`settingsSoundSwitch` / `settingsReduceMotionSwitch`（Switch 本体，测 `checked`）；各自 `indicator` 的轨道 `...SwitchTrack`、圆钮 `...SwitchThumb`（测轨/钮颜色是否在暖纸令牌体系内，例：`settingsSoundSwitchTrack`）；
  - 管理行：`settingsManageRoutine` / `settingsManageCategory` / `settingsManageExport`。

**高度与滚动策略**（三段化后内容变高，须防小窗口/测试 520px 溢出）：内容整体放进 `ScrollView`（`clip: true`，`contentWidth: availableWidth` 防横滚），竖向滚动条**直接复用** [WeekPlanView.qml:319](../../../qml/views/WeekPlanView.qml#L319) / [MonthGoalView.qml:680](../../../qml/views/MonthGoalView.qml#L680) 已有的暖色主题化 `ScrollBar.vertical` 写法（细、暖、hover/press 转 accent），不重新设计。Popup 高度封顶：

```qml
height: Math.min(contentColumn.implicitHeight,
                 parent ? parent.height - Theme.space32 * 2 : contentColumn.implicitHeight)
```

即内容不超窗按内容高、超窗封顶到 `parent.height - 64` 并内部滚动。关闭按钮加 `objectName: "settingsCloseButton"`（验收"可滚到关闭"时用 `findChild` 直接取，不靠遍历文本）。验收含：测试窗口 520px 高下不溢出、`settingsCloseButton` 可达。

## 侧栏瘦身（Sidebar）

[Sidebar.qml](../../../qml/components/Sidebar.qml)：

- 删除 3 个 SidebarItem（每日例行/科目管理/数据导出）及其 `signal dailyRoutineRequested`、`categoryManagementRequested`、`dataExportRequested`；
- 删除底部无功能的"三阶段" `Text` 标签；
- 保留"设置"SidebarItem 与 `signal settingsRequested`；
- 若 `categoryManagerRef`/`exportServiceRef` 属性在移除后确认无其它引用，一并删除（实施时 grep 核实，避免留死属性）；
- **旧测试同步**（否则新旧断言打架）：`tests/qml/tst_sidebar_ui_optimization.qml` 的 `test_dividerAndVersionStyles()`（`findText("三阶段")`）依赖已删标签，计划一必须删除或改写该用例；新增"三项管理入口与三阶段标签已不存在"的断言。

## MainWindow 接线迁移

[MainWindow.qml](../../../qml/MainWindow.qml)：

- Sidebar 实例上删除 `onDailyRoutineRequested`/`onCategoryManagementRequested`/`onDataExportRequested` 三个处理器（信号已不存在）；
- 把这三个入口迁到 `SettingsDialog` 实例：`onRoutineRequested: routineDialog.open()`、`onCategoryRequested: categoryDialog.open()`、`onExportRequested: exportDialog.open()`；
- `routineDialog`/`categoryDialog`/`exportDialog` 三个实例保持不动（只是打开入口从侧栏变成设置弹窗的管理行）；
- SettingsDialog 实例已注入 `appSettingsRef: root.appSettingsRef`，开关据此读写。

## 减少动效：机制与范围

**机制（reduceMotion 来源按组件既有注入方式取，别一律走全局）**——否则已有 `settings`/`appSettingsRef` 注入的组件在测试里还要再造全局 `appSettings`，白绕：

| 组件 | reduceMotion 取值 |
| --- | --- |
| MainWindow | `root.appSettingsRef && root.appSettingsRef.reduceMotion`（已有 `appSettingsRef`） |
| FocusView | `root.settings && root.settings.reduceMotion`（已有 `settings` 属性，现有测试全走 `settings: appSettingsMock`） |
| Sidebar / StatCard（无设置注入） | 全局守卫式只读属性（沿用 main.qml 的 `typeof appSettings` 模式） |

Sidebar/StatCard 各加一个**可注入属性**（非 readonly：默认绑定走全局守卫，测试可直接赋值，免造全局 `appSettings`）：

```qml
// qmllint disable unqualified
property bool reduceMotionActive:
    typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
// qmllint enable unqualified
```

生产环境该绑定成立（全局 `appSettings` 存在）；测试里 `sidebar.reduceMotionActive = true` / `statCard.reduceMotionActive = true` 直接置真，无需全局上下文。FocusView/MainWindow 直接用既有 `settings`/`appSettingsRef` 注入。

**门控范围**（非必要/循环/大位移；开启时改为瞬时）：

| 位置 | 动画 | reduceMotion 开启时 |
| --- | --- | --- |
| [MainWindow.qml:274](../../../qml/MainWindow.qml#L274) `viewFade` | 视图切换淡入淡出 | `switchToView` 走瞬时分支（完整状态复位，见下） |
| [Sidebar.qml:302](../../../qml/components/Sidebar.qml#L302) `pulseAnimation` | 侧栏状态 ● 循环脉冲 | `running: pulseRunning && !reduceMotionActive`；停时 `onRunningChanged`/既有 `onPulseRunningChanged` 把 opacity 复位 1 |
| [FocusView.qml:615](../../../qml/views/FocusView.qml#L615) completionBanner 闪烁 | "专注完成"横幅无限闪 | `running: completionBanner.visible && !reduceMotionActive`；停时 opacity 复位 1 |
| [StatCard.qml:102](../../../qml/components/StatCard.qml#L102) `valuePulse` | 数值变化跳动脉冲 | `onTextChanged`：`if (!reduceMotionActive) valuePulse.restart()` |

**MainWindow 瞬时切换必须完整复位状态、且分支必须在 `isSwitching` 早退之前**——否则"动画中途已开启 reduceMotion 再切页"会先命中现有 `if (isSwitching) { queuedView=…; return; }`，瞬时分支根本不执行、半切换态照旧。`switchToView(viewName)` 整体重排为：

```qml
function switchToView(viewName) {
    // 已在目标视图且未处于切换中：无操作（原早退判断，保留）。
    if (root.currentView === viewName && !root.isSwitching) {
        return;
    }

    // reduceMotion：瞬时切换 + 完整复位，必须在 isSwitching 早退之前，
    // 才能接住“动画中途开启减动效再切页”的场景。
    if (root.appSettingsRef && root.appSettingsRef.reduceMotion) {
        viewFade.stop();
        root.currentView = viewName;
        root.pendingView = viewName;
        root.queuedView = "";
        root.isSwitching = false;
        stackLayout.opacity = 1.0;
        return;
    }

    // 动画进行中：仅记最后一次请求，等本次切换结束再启动（原逻辑）。
    if (root.isSwitching) {
        root.queuedView = viewName;
        return;
    }

    root.isSwitching = true;
    root.pendingView = viewName;
    root.queuedView = "";
    viewFade.restart();
}
```

**动画测试入口**（现有动画多为内部 id，`findChild` 找不到；须暴露驱动属性，否则"门控断言"无从写起）：

| 组件 | 新增测试入口 |
| --- | --- |
| Sidebar `statusPulse`（已有 objectName `sidebarStatusPulse-<marker>`） | 加 `readonly property bool pulseAnimationRunning: pulseAnimation.running` |
| FocusView completionBanner | Rectangle 加 `objectName: "focusCompletionBanner"`；匿名 `OpacityAnimator on opacity` 提取为带 `id: completionBlink` 的具名动画；加 `readonly property bool blinkRunning: completionBlink.running` |
| StatCard 根（测试直接用实例 id `statCard`） | 加 `readonly property bool valuePulseRunning: valuePulse.running` |

**不门控**（属必要反馈或低风险微交互）：专注环进度动画（表达时间进度，是功能不是装饰）、70ms 悬停颜色/边框过渡、弹窗进出场 220ms scale/opacity（短、单次、非循环，是打开反馈）。范围保守，先覆盖最"晃眼"的循环/大位移。

## 错误处理

- appSettingsRef/appSettings 缺失：开关只显示不写、动画守卫求值 false 照常播放（降级不崩）；
- reduceMotion 开启时被停的循环动画须把受控属性复位到静止值（如 pulse 停时 opacity=1），避免停在半透明帧。

## 测试策略

**C++（ServiceTests，对齐 soundEnabled 既有用例）**：

- `reduceMotion` 默认 `false`；set 后 get 变、发 `reduceMotionChanged`；同值不重复发；重建实例持久化。

**QML**：

- **SettingsDialog**：
  - 提示音 Switch `checked` 反映 mock `soundEnabled`，点击后 mock 值翻转；
  - 减少动效 Switch 同理绑 `reduceMotion`；
  - 三个管理行点击各自 emit `routineRequested`/`categoryRequested`/`exportRequested`（SignalSpy）；
  - 缺 appSettingsRef 时渲染不崩、开关点击不写。
- **Sidebar**：`findChild` 找不到 例行/科目/导出 三项的 objectName（`sidebarItem-例`/`-科`/`-导`）与"三阶段"文本（改写旧 `test_dividerAndVersionStyles`）；`sidebarItem-设` 仍在；`settingsRequested` 仍可 emit。
- **减少动效门控**（断言驱动属性，不断言视觉；计划二）：
  - Sidebar：mock `focusTimerRef` 置运行中番茄（令 `statusGlyph==="●"`、`pulseRunning` 为真）。`sidebar.reduceMotionActive=false` 时 `findChild("sidebarStatusPulse-专").pulseAnimationRunning===true`；置 `sidebar.reduceMotionActive=true` 后转 `false`（直接赋属性，免造全局 appSettings）。
  - FocusView：`settings` 用既有 `appSettingsMock`（加 `reduceMotion` 属性）；置 `state="workDone"`（completionBanner 可见），`findChild("focusCompletionBanner").blinkRunning` 随 `appSettingsMock.reduceMotion` 由 `true`→`false`。
  - StatCard：`statCard.reduceMotionActive=true` 时改 `value`，断言 `statCard.valuePulseRunning===false`；置 `false` 后改 `value` 则 `valuePulseRunning===true`。
  - MainWindow：`appSettingsMock.reduceMotion=true` 后调 `switchToView("focus")`，断言 `currentView==="focus"` 立即成立且 `isSwitching===false`、`stackLayout.opacity===1.0`（未走淡入淡出）。
  - 遵守不断言 `visible===true`。

## 影响面与拆分

- C++：AppSettings（一个属性）。
- QML：SettingsDialog（三段重构 + 3 信号 + 2 开关）、Sidebar（删 3 项 + 标签 + 3 信号）、MainWindow（接线迁移）、4 处动画门控（MainWindow/Sidebar/FocusView/StatCard）。
- 实施计划拆两份：
  - **计划一（设置控制台 + 侧栏迁移）**：AppSettings.reduceMotion → SettingsDialog 三段（开关 + 管理行 + 信号）→ Sidebar 删项删标签 → MainWindow 接线迁移。交付：侧栏瘦身、设置弹窗成控制台、两个开关可存取（reduceMotion 此阶段仅存储、未接动画）。
  - **计划二（减少动效门控）**：4 处动画按范围表接 `reduceMotionActive`。依赖计划一的 `reduceMotion` 属性。交付：开关真正生效。
