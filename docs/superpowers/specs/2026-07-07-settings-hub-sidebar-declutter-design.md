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
- **开关**：`QtQuick.Controls.Basic` 的 `Switch`，自定义 `indicator`（轨道 + 圆钮）贴合暖纸令牌（开=`Theme.accent` 轨、关=`Theme.surfaceSunken` 轨），与 app 既有自绘控件一致；`checked` 绑 `appSettingsRef.<key>`，`onToggled` 写 `appSettingsRef.<key> = checked`；缺 appSettingsRef（测试/降级）时只显示不写、不崩溃（同画廊守卫）；
- **管理行**：一行文字 + 右侧 `›`，整行可点，`MouseArea` → `root.close()` + `emit 对应信号`；
- 新增信号：`signal routineRequested`、`signal categoryRequested`、`signal exportRequested`；
- objectName：`settingsSoundSwitch`、`settingsReduceMotionSwitch`、`settingsManageRoutine`、`settingsManageCategory`、`settingsManageExport`（测试入口）。

## 侧栏瘦身（Sidebar）

[Sidebar.qml](../../../qml/components/Sidebar.qml)：

- 删除 3 个 SidebarItem（每日例行/科目管理/数据导出）及其 `signal dailyRoutineRequested`、`categoryManagementRequested`、`dataExportRequested`；
- 删除底部无功能的"三阶段" `Text` 标签；
- 保留"设置"SidebarItem 与 `signal settingsRequested`；
- 若 `categoryManagerRef`/`exportServiceRef` 属性在移除后确认无其它引用，一并删除（实施时 grep 核实，避免留死属性）。

## MainWindow 接线迁移

[MainWindow.qml](../../../qml/MainWindow.qml)：

- Sidebar 实例上删除 `onDailyRoutineRequested`/`onCategoryManagementRequested`/`onDataExportRequested` 三个处理器（信号已不存在）；
- 把这三个入口迁到 `SettingsDialog` 实例：`onRoutineRequested: routineDialog.open()`、`onCategoryRequested: categoryDialog.open()`、`onExportRequested: exportDialog.open()`；
- `routineDialog`/`categoryDialog`/`exportDialog` 三个实例保持不动（只是打开入口从侧栏变成设置弹窗的管理行）；
- SettingsDialog 实例已注入 `appSettingsRef: root.appSettingsRef`，开关据此读写。

## 减少动效：机制与范围

**机制**：`reduceMotion` 经上下文属性 `appSettings` 全局可达。每个含被门控动画的组件加一个守卫式只读属性（沿用 main.qml 既有 `typeof appSettings` 模式 + `// qmllint disable unqualified`）：

```qml
// qmllint disable unqualified
readonly property bool reduceMotionActive:
    typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
// qmllint enable unqualified
```

测试文件不注入 appSettings → 求值 `false` → 动画照常，测试不受影响。MainWindow 已有 `appSettingsRef`，直接用 `root.appSettingsRef && root.appSettingsRef.reduceMotion`，无需守卫。

**门控范围**（非必要/循环/大位移；开启时改为瞬时）：

| 位置 | 动画 | reduceMotion 开启时 |
| --- | --- | --- |
| [MainWindow.qml:274](../../../qml/MainWindow.qml#L274) `viewFade` | 视图切换淡入淡出 | `switchToView` 跳过 `viewFade.restart()`，直接置 `currentView`（瞬时切换） |
| [Sidebar.qml:302](../../../qml/components/Sidebar.qml#L302) `pulseAnimation` | 侧栏状态 ● 循环脉冲 | `running: pulseRunning && !reduceMotionActive`；停时 opacity 复位 1 |
| [FocusView.qml:615](../../../qml/views/FocusView.qml#L615) completionBanner 闪烁 | "专注完成"横幅无限闪 | `running: completionBanner.visible && !reduceMotionActive` |
| [StatCard.qml:102](../../../qml/components/StatCard.qml#L102) `valuePulse` | 数值变化跳动脉冲 | `onTextChanged`：`if (!reduceMotionActive) valuePulse.restart()` |

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
- **Sidebar**：`findChild` 找不到 例行/科目/导出 三项的 objectName（`sidebarItem-例`/`-科`/`-导`）与"三阶段"文本；`sidebarItem-设` 仍在；`settingsRequested` 仍可 emit。
- **减少动效门控**（断言驱动属性，不断言视觉）：注入 mock `appSettings.reduceMotion=true`，断言 Sidebar `reduceMotionActive===true` 且 `pulseAnimation.running===false`；MainWindow 注入后调 `switchToView`，断言 `currentView` 立即变（未走淡入淡出，`isSwitching` 不被置起或立即回落）。遵守不断言 `visible===true`。

## 影响面与拆分

- C++：AppSettings（一个属性）。
- QML：SettingsDialog（三段重构 + 3 信号 + 2 开关）、Sidebar（删 3 项 + 标签 + 3 信号）、MainWindow（接线迁移）、4 处动画门控（MainWindow/Sidebar/FocusView/StatCard）。
- 实施计划拆两份：
  - **计划一（设置控制台 + 侧栏迁移）**：AppSettings.reduceMotion → SettingsDialog 三段（开关 + 管理行 + 信号）→ Sidebar 删项删标签 → MainWindow 接线迁移。交付：侧栏瘦身、设置弹窗成控制台、两个开关可存取（reduceMotion 此阶段仅存储、未接动画）。
  - **计划二（减少动效门控）**：4 处动画按范围表接 `reduceMotionActive`。依赖计划一的 `reduceMotion` 属性。交付：开关真正生效。
