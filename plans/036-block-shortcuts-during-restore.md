# Plan 036: 恢复数据库期间统一阻断应用内快捷键、全局热键和直接动作分发

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按顺序执行并验证。命中 STOP condition 时停下汇报，不扩大实现范围。
> 完成后更新 `plans/README.md` 中本计划状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- qml/MainWindow.qml qml/components/AppShortcuts.qml tests/qml/tst_shortcuts.qml tests/qml/tst_mainwindow_ui_optimization.qml`
> 若动作分发、恢复遮罩或快捷键注册结构变化，先重核本计划再继续。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness / state isolation
- **Planned at**: commit `f8e3120`，2026-08-16

## 产品口径

`backupService.operationBlocksUi == true` 时，应用进入数据库替换临界区。此时所有会触发业务状态变更或页面切换的快捷动作
都必须无效：应用内 `Shortcut`、系统全局热键、以及对 `triggerShortcutAction()` 的直接调用都不能穿透。

只把视觉遮罩放到最上层不等于输入被阻断。快捷键不参与鼠标命中测试，全局热键甚至来自 C++ 信号。

## Current state

### 现有 suspended 只认 Controls Overlay（`MainWindow.qml:87-1041`）

```qml
readonly property bool overlayHoldsFocus: root.itemInsideOverlay(
    root.Window.window ? root.Window.window.activeFocusItem : null)

AppShortcuts {
    suspended: settingsDialog.recordingShortcut || root.overlayHoldsFocus
    onActionTriggered: function (actionId) {
        root.triggerShortcutAction(actionId)
    }
}
```

恢复遮罩却是普通 `Loader`，不属于 `Controls.Overlay.overlay`：

```qml
Loader {
    anchors.fill: parent
    z: 10000
    active: root.backupServiceRef && root.backupServiceRef.operationBlocksUi
    sourceComponent: BackupOperationOverlay { ... }
}
```

### 两条快捷键路径的守卫不对称（`AppShortcuts.qml:36-58`）

应用内 `Shortcut.enabled` 会读取 `!root.suspended`，但 `Connections.onGlobalActionTriggered` 当前直接发
`root.actionTriggered(actionId)`，不检查 `suspended`。

### 最终分发器没有临界区保护（`MainWindow.qml:437-462`）

`triggerShortcutAction(actionId)` 直接进入 switch，任何程序调用和全局信号都能绕过视觉遮罩。

## Scope

**In scope**：

- `qml/MainWindow.qml`
- `qml/components/AppShortcuts.qml`
- `tests/qml/tst_shortcuts.qml`
- `tests/qml/tst_mainwindow_ui_optimization.qml`
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不把恢复遮罩改造成 Controls Popup/Overlay；它的布局与视觉层级不需要重做。
- 不注销 macOS 全局热键，只丢弃临界区内收到的动作。
- 不改变恢复服务的 `operationBlocksUi` 生命周期。
- 不处理普通按钮/鼠标事件；现有全屏遮罩负责它们。

## QML 离屏测试红线（必须内联遵守）

- **禁止断言 `visible === true`。** 本项目用 `QT_QPA_PLATFORM=offscreen`，`visible` 会沿父级可见性链级联，
  不能稳定表达组件业务状态。改断言业务属性、控件 `enabled`、`Popup.opened`、模型内容或信号参数。
- **所有“今天/日期”都走逻辑日。** 使用测试现有的 `logicalDayService`、`logicalToday()` 或注入固定 ISO 日期；
  不直接用物理日 `new Date()` 推导今天，否则凌晨 `dayStartHour` 前会得到偶发失败。
- **不要等待或监听 `Popup.onClosed` 作为完成判据。** 离屏环境不保证投递该生命周期回调。
  直接调用被测请求/提交函数，并断言业务状态、`opened` 或控件状态；不要靠 `onClosed` SignalSpy 结束测试。

## Implementation

### Step 1: 先锁住 AppShortcuts 的全局信号出口

在 `tests/qml/tst_shortcuts.qml` 新增用例：

1. `suspended = true`；
2. 假 registry 发 `globalActionTriggered("global.focusToggle")`；
3. 断言 `actionTriggered` 的 SignalSpy 仍为 0；
4. 改回 false 再发一次，断言恰好收到 1 次且 actionId 正确。

在旧实现上先确认测试失败。随后让 `AppShortcuts.qml` 的全局信号回调也检查 `!root.suspended`。
应用内 `Shortcut.enabled` 的现有逻辑保持不变。

**Verify**：运行 `ctest --test-dir ~/pt-audit -R '^QmlTest.shortcuts$' --output-on-failure`
→ 旧实现先因 suspended 时仍收到信号而失败；加守卫后整组 0 failed。

### Step 2: 在 MainWindow 建立唯一的恢复输入守卫

增加只读属性，例如：

```qml
readonly property bool backupOperationBlocksInput: !!root.backupServiceRef
                                                   && root.backupServiceRef.operationBlocksUi
```

把它并入 `AppShortcuts.suspended`。注释明确：恢复期间数据库文件可能正在校验、快照或原子替换，
不能只依赖遮罩挡鼠标，因为 `Shortcut` 和系统热键不经过命中测试。

**Verify**：`rg -n "backupOperationBlocksInput|suspended:" qml/MainWindow.qml`
→ 属性定义与 `AppShortcuts.suspended` 各有命中，且后者包含该属性。

### Step 3: 最终动作分发器再次拒绝

在 `triggerShortcutAction()` 最前面检查 `backupOperationBlocksInput`，命中就直接 return。
这是必要的最后一道边界：它覆盖测试、未来调用者和任何绕过 `AppShortcuts` 的路径。

不要把 `textInputFocused` 混入这个最终守卫。文本输入状态只应限制需要让路的键，恢复状态则必须禁止全部业务动作，
两者语义不同。

**Verify**：`cmake --build ~/pt-audit -j8`
→ exit 0，无新 QML/C++ warning。

### Step 4: MainWindow 级回归测试

扩展 `tests/qml/tst_mainwindow_ui_optimization.qml` 的假服务，提供可切换的
`operationBlocksUi` 与 `operationText`：

- false 时，调用一个无破坏性的视图切换 action，断言正常生效。
- true 时，断言 `appShortcuts.suspended == true`。
- true 时直接调用 `triggerShortcutAction()`，断言当前视图不变。
- 再切回 false，断言动作恢复。

测试只验证状态和信号，不启动真实恢复，不弹出应用窗口。

**Verify**：运行
`ctest --test-dir ~/pt-audit -R '^QmlTest.(shortcuts|mainwindow_ui_optimization)$' --output-on-failure`
→ 两个条目通过；阻断前后视图断言均符合预期。

## Test plan

- `tst_shortcuts.qml` 锁住组件级全局信号守卫。
- `tst_mainwindow_ui_optimization.qml` 锁住恢复状态、suspended 绑定和最终分发器三层边界。
- false → true → false 都要测，防止恢复结束后快捷键永久失效。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit \
  -R '^QmlTest.(shortcuts|mainwindow_ui_optimization)$' --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：两组定向 QML 测试通过，全量测试通过，无新 qmllint warning。

## Done criteria

- 恢复遮罩激活时，应用内 Shortcut 全部 disabled。
- 同期到达的全局热键信号不再向外转发。
- 直接调用 `triggerShortcutAction()` 也无法穿透。
- 恢复结束后快捷键自动恢复，不需要重新注册全局热键。
- 新测试在旧实现上可证伪。

## STOP conditions

- `operationBlocksUi` 在真实数据库替换开始前会短暂回到 false，不能可靠表达完整临界区。
- 全局热键包含必须在恢复期间仍可执行的安全逃生动作；需要产品明确白名单，而不是自行猜测。
- 测试发现恢复遮罩并未挡住普通鼠标/键盘焦点事件；那是更大的输入隔离问题，需拆计划。

## Maintenance notes

- 新增任何绕过 `AppShortcuts` 的动作入口时，评审必须确认它最终经过 `triggerShortcutAction()` 或同等恢复守卫。
- `operationBlocksUi` 是业务临界区事实源；不要再从 Loader.active、z 值或焦点位置反推它。
- 真正需要“恢复期间仍可用”的逃生动作应建立显式白名单和测试，不能删除总守卫。

## Git workflow

- 建议分支：`advisor/036-block-shortcuts-during-restore`
- 建议提交：`修复数据库恢复期间快捷键穿透遮罩`
- 不 push、不创建 PR，除非维护者明确要求。
